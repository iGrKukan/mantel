import Foundation
import AppKit

/// «Сейчас играет» через AppleScript к «Музыке» (Apple Music) и Spotify —
/// запасной (а для App Store — единственный) источник, не требующий приватного
/// MediaRemote.framework. Работает в песочнице: нужны разрешения «Автоматизация»,
/// система один раз спросит их сама при первом обращении к каждому приложению.
///
/// Принципиально НЕ запускает «Музыку»/Spotify — если приложение не в списке
/// работающих, мы его вообще не трогаем (AppleScript-обращение к неоткрытому
/// приложению его запускает, это недопустимо).
enum ScriptedNowPlaying {

    struct Snapshot {
        var appBundleID: String
        var appName: String
        var title: String
        var artist: String
        var album: String
        var duration: Double     // секунды
        var elapsed: Double      // секунды
        var isPlaying: Bool
        var artworkURL: URL?     // Spotify отдаёт ссылку
        var artworkData: Data?   // Музыка отдаёт данные
    }

    enum Command { case playPause, next, previous }

    private static let spotifyBundleID = "com.spotify.client"
    private static let musicBundleID = "com.apple.Music"

    // NSAppleScript не потокобезопасен — все вызовы идут через одну последовательную очередь.
    private static let queue = DispatchQueue(label: "by.maru.ShelfTop.applescript")

    // Скрипты компилируются один раз и переиспользуются (компиляция NSAppleScript дорогая).
    private static var spotifySnapshotScript: NSAppleScript?
    private static var musicSnapshotScript: NSAppleScript?

    // Приложения, отказавшие в разрешении «Автоматизация» (ошибка -1743) — больше не спрашиваем
    // их в этом сеансе, чтобы не мигать системным диалогом на каждый опрос.
    private static var deniedBundleIDs = Set<String>()

    // MARK: - Публичное чтение состояния

    /// Синхронно (в вызывающей очереди — вызывающий сам должен быть на фоне) возвращает
    /// текущее «сейчас играет». Приоритет: играющий Spotify, иначе играющая «Музыка», иначе nil.
    static func snapshot() -> Snapshot? {
        queue.sync {
            if isRunning(spotifyBundleID), !deniedBundleIDs.contains(spotifyBundleID),
               let snap = spotifySnapshot(), snap.isPlaying {
                return snap
            }
            if isRunning(musicBundleID), !deniedBundleIDs.contains(musicBundleID),
               let snap = musicSnapshot(), snap.isPlaying {
                return snap
            }
            return nil
        }
    }

    private static func isRunning(_ bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    // MARK: - Spotify

    private static func spotifySnapshot() -> Snapshot? {
        if spotifySnapshotScript == nil {
            spotifySnapshotScript = compile("""
            tell application "Spotify"
                if player state is playing then
                    set trackName to name of current track
                    set trackArtist to artist of current track
                    set trackAlbum to album of current track
                    set trackDuration to duration of current track
                    set trackPosition to player position
                    set trackArtworkURL to artwork url of current track
                    return {"playing", trackName, trackArtist, trackAlbum, trackDuration, trackPosition, trackArtworkURL}
                else
                    return {"stopped", "", "", "", 0, 0, ""}
                end if
            end tell
            """, bundleID: spotifyBundleID)
        }
        guard let script = spotifySnapshotScript,
              let result = run(script, bundleID: spotifyBundleID) else { return nil }

        guard result.atIndex(1)?.stringValue == "playing" else { return nil }
        let title = result.atIndex(2)?.stringValue ?? ""
        guard !title.isEmpty else { return nil }
        let artist = result.atIndex(3)?.stringValue ?? ""
        let album = result.atIndex(4)?.stringValue ?? ""
        // Spotify отдаёт длительность трека в миллисекундах.
        let durationMs = result.atIndex(5)?.doubleValue ?? 0
        let position = result.atIndex(6)?.doubleValue ?? 0
        let artworkURLString = result.atIndex(7)?.stringValue ?? ""

        return Snapshot(
            appBundleID: spotifyBundleID,
            appName: "Spotify",
            title: title,
            artist: artist,
            album: album,
            duration: durationMs / 1000,
            elapsed: position,
            isPlaying: true,
            artworkURL: URL(string: artworkURLString),
            artworkData: nil
        )
    }

    // MARK: - Музыка (Apple Music)

    private static func musicSnapshot() -> Snapshot? {
        if musicSnapshotScript == nil {
            musicSnapshotScript = compile("""
            tell application "Music"
                if player state is playing then
                    set trackName to name of current track
                    set trackArtist to artist of current track
                    set trackAlbum to album of current track
                    set trackDuration to duration of current track
                    set trackPosition to player position
                    set artworkBytes to ""
                    try
                        set artworkBytes to raw data of artwork 1 of current track
                    end try
                    return {"playing", trackName, trackArtist, trackAlbum, trackDuration, trackPosition, artworkBytes}
                else
                    return {"stopped", "", "", "", 0, 0, ""}
                end if
            end tell
            """, bundleID: musicBundleID)
        }
        guard let script = musicSnapshotScript,
              let result = run(script, bundleID: musicBundleID) else { return nil }

        guard result.atIndex(1)?.stringValue == "playing" else { return nil }
        let title = result.atIndex(2)?.stringValue ?? ""
        guard !title.isEmpty else { return nil }
        let artist = result.atIndex(3)?.stringValue ?? ""
        let album = result.atIndex(4)?.stringValue ?? ""
        let duration = result.atIndex(5)?.doubleValue ?? 0
        let position = result.atIndex(6)?.doubleValue ?? 0
        let artworkData = result.atIndex(7)?.data

        return Snapshot(
            appBundleID: musicBundleID,
            appName: "Музыка",
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            elapsed: position,
            isPlaying: true,
            artworkURL: nil,
            artworkData: (artworkData?.isEmpty == false) ? artworkData : nil
        )
    }

    // MARK: - Команды управления

    static func sendCommand(_ command: Command) {
        queue.async {
            let verb: String
            switch command {
            case .playPause: verb = "playpause"
            case .next: verb = "next track"
            case .previous: verb = "previous track"
            }
            runFireAndForget(target: preferredRunningTarget(), verb: verb)
        }
    }

    static func seek(toSeconds seconds: Double) {
        queue.async {
            runFireAndForget(target: preferredRunningTarget(), verb: "set player position to \(seconds)")
        }
    }

    /// Тот же приоритет, что и при чтении: играющий Spotify, иначе играющая «Музыка».
    private static func preferredRunningTarget() -> String? {
        if isRunning(spotifyBundleID), !deniedBundleIDs.contains(spotifyBundleID),
           let snap = spotifySnapshot(), snap.isPlaying {
            return "Spotify"
        }
        if isRunning(musicBundleID), !deniedBundleIDs.contains(musicBundleID),
           let snap = musicSnapshot(), snap.isPlaying {
            return "Music"
        }
        return nil
    }

    private static func runFireAndForget(target: String?, verb: String) {
        guard let target else { return }
        let bundleID = target == "Spotify" ? spotifyBundleID : musicBundleID
        guard let script = compile("tell application \"\(target)\" to \(verb)", bundleID: bundleID) else { return }
        _ = run(script, bundleID: bundleID)
    }

    // MARK: - Компиляция и выполнение

    private static func compile(_ source: String, bundleID: String) -> NSAppleScript? {
        guard let script = NSAppleScript(source: source) else {
            NSLog("ShelfTop: не удалось создать AppleScript для %@", bundleID)
            return nil
        }
        var errorInfo: NSDictionary?
        guard script.compileAndReturnError(&errorInfo) else {
            NSLog("ShelfTop: ошибка компиляции AppleScript для %@: %@", bundleID, String(describing: errorInfo))
            return nil
        }
        return script
    }

    /// Выполняет скомпилированный скрипт. При отказе в разрешении (-1743) запоминает
    /// bundle id, чтобы больше не дёргать это приложение в текущем сеансе.
    private static func run(_ script: NSAppleScript, bundleID: String) -> NSAppleEventDescriptor? {
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let code = errorInfo[NSAppleScript.errorNumber] as? Int
            if code == -1743 {
                if !deniedBundleIDs.contains(bundleID) {
                    NSLog("ShelfTop: пользователь запретил автоматизацию для %@ — больше не опрашиваем в этом сеансе", bundleID)
                    deniedBundleIDs.insert(bundleID)
                }
            } else {
                NSLog("ShelfTop: ошибка AppleScript (%@): %@", bundleID, String(describing: errorInfo))
            }
            return nil
        }
        return result
    }
}
