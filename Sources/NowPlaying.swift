import Foundation
import AppKit

/// Системное «сейчас играет» (Spotify, Apple Music, YouTube в браузере и т.п.).
///
/// Приватный MediaRemote.framework с macOS 15.4 доступен только бинарникам,
/// подписанным Apple — наше приложение линковать его напрямую не может.
/// Обходной путь (как у Droppy): системный /usr/bin/perl имеет нужные права,
/// он динамически грузит бандлённый MediaRemoteAdapter.framework и печатает
/// построчный JSON в stdout. Сам фреймворк лежит в Resources как есть,
/// в приложение НЕ линкуется — см. Vendor/mediaremote-adapter и project.yml.
/// Если адаптер однажды сломается (Apple закроет и этот путь) — просто
/// молчим (isAvailable = false), приложение не падает.
///
/// Второй источник — ScriptedNowPlaying (AppleScript к «Музыке»/Spotify), годный
/// для песочницы App Store. Для сборки APPSTORE используется он один; в обычной
/// сборке он подхватывается автоматически, если адаптер MediaRemote недоступен.
final class NowPlayingModel: ObservableObject {
    static let shared = NowPlayingModel()

    /// Какой источник данных сейчас активен.
    enum Source { case mediaRemote, appleScript }
    private(set) var source: Source = .mediaRemote

    @Published var isAvailable: Bool = false
    @Published var title: String = ""
    @Published var artist: String = ""
    @Published var appName: String = ""
    @Published var artwork: NSImage?
    @Published var isPlaying: Bool = false
    @Published var elapsed: Double = 0
    @Published var duration: Double = 0

    private var streamProcess: Process?
    private var stdoutPipe: Pipe?
    private var readBuffer = Data()
    private var tickTimer: Timer?
    private var started = false
    private var lastRestartAttempt = Date.distantPast

    // Точка отсчёта для плавной прокрутки elapsed между обновлениями потока.
    private var elapsedBase: Double = 0
    private var elapsedBaseTime = Date()

    // MARK: источник AppleScript (Музыка/Spotify)

    private var appleScriptPollGeneration = 0
    private var artworkCache: [String: NSImage] = [:]
    private var artworkLoadKey: String?

    private static let perl = "/usr/bin/perl"
    private static let resourcesRoot = Bundle.main.resourceURL?.appendingPathComponent("mediaremote-adapter")
    private static var scriptURL: URL? { resourcesRoot?.appendingPathComponent("bin/mediaremote-adapter.pl") }
    private static var frameworkURL: URL? { resourcesRoot?.appendingPathComponent("MediaRemoteAdapter.framework") }
    private static var testClientURL: URL? { resourcesRoot?.appendingPathComponent("MediaRemoteAdapterTestClient") }

    private init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(stopStream),
            name: NSApplication.willTerminateNotification, object: nil)
    }

    /// Разовый запуск: проверяет адаптер и, если жив, поднимает поток обновлений.
    /// Для сборки App Store (флаг APPSTORE) MediaRemote-адаптер даже не пробуем —
    /// сразу используем AppleScript. В обычной сборке — если адаптер недоступен,
    /// автоматически переключаемся на AppleScript вместо того, чтобы просто молчать.
    func start() {
        guard !started else { return }
        started = true

        startTicker()

#if APPSTORE
        source = .appleScript
        startAppleScriptPolling()
        return
#else
        guard let script = Self.scriptURL, let framework = Self.frameworkURL,
              FileManager.default.fileExists(atPath: script.path),
              FileManager.default.fileExists(atPath: framework.path) else {
            NSLog("ShelfTop: адаптер сейчас-играет не найден в Resources — переключаюсь на AppleScript")
            source = .appleScript
            startAppleScriptPolling()
            return
        }

        guard selfTest(script: script, framework: framework) else {
            NSLog("ShelfTop: self-test адаптера сейчас-играет провалился — переключаюсь на AppleScript")
            source = .appleScript
            startAppleScriptPolling()
            return
        }

        source = .mediaRemote
        startStream(script: script, framework: framework)
#endif
    }

    /// `test` — быстрая проверка, что MediaRemote вообще доступен процессу.
    /// Без тест-клиента (не должен пропасть, но на всякий случай) просто пробуем запустить поток.
    private func selfTest(script: URL, framework: URL) -> Bool {
        guard let testClient = Self.testClientURL,
              FileManager.default.fileExists(atPath: testClient.path) else { return true }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.perl)
        p.arguments = [script.path, framework.path, testClient.path, "test"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            NSLog("ShelfTop: не смог запустить self-test адаптера: %@", error.localizedDescription)
            return false
        }
    }

    private func startStream(script: URL, framework: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.perl)
        // --no-diff — каждая строка содержит полное состояние, не нужно накапливать дифф;
        // --debounce=180 — гасим всплески мелких обновлений (как у DroppyMediaHelper).
        p.arguments = [script.path, framework.path, "stream", "--no-diff", "--debounce=180"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.handleStreamExit() }
        }
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.consume(data)
        }
        do {
            try p.run()
            streamProcess = p
            stdoutPipe = pipe
        } catch {
            NSLog("ShelfTop: не смог запустить поток адаптера: %@", error.localizedDescription)
        }
    }

    /// Поток адаптера неожиданно умер — сбрасываем состояние и пробуем поднять заново,
    /// но не чаще раза в 5 секунд, чтобы не зациклиться.
    private func handleStreamExit() {
        streamProcess = nil
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        readBuffer.removeAll()
        resetToUnavailable()

        guard Date().timeIntervalSince(lastRestartAttempt) > 5 else { return }
        lastRestartAttempt = Date()
        guard let script = Self.scriptURL, let framework = Self.frameworkURL else { return }
        startStream(script: script, framework: framework)
    }

    @objc private func stopStream() {
        tickTimer?.invalidate()
        tickTimer = nil
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        streamProcess?.terminationHandler = nil
        streamProcess?.terminate()
        streamProcess = nil
        stdoutPipe = nil
        appleScriptPollGeneration += 1 // останавливает цикл опроса AppleScript, если он был запущен
    }

    // MARK: разбор построчного JSON

    private func consume(_ data: Data) {
        readBuffer.append(data)
        while let newline = readBuffer.firstIndex(of: 0x0A) {
            let lineData = readBuffer.subdata(in: readBuffer.startIndex..<newline)
            readBuffer.removeSubrange(readBuffer.startIndex...newline)
            guard !lineData.isEmpty else { continue }
            handleLine(lineData)
        }
    }

    private func handleLine(_ lineData: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let payload = obj["payload"] as? [String: Any] else { return }
        DispatchQueue.main.async { [weak self] in
            self?.apply(payload)
        }
    }

    private func apply(_ payload: [String: Any]) {
        guard let title = payload["title"] as? String, !title.isEmpty,
              let bundleId = payload["bundleIdentifier"] as? String,
              let playing = payload["playing"] as? Bool else {
            resetToUnavailable()
            return
        }

        isAvailable = true
        self.title = title
        artist = payload["artist"] as? String ?? ""
        isPlaying = playing
        duration = payload["duration"] as? Double ?? 0

        let newElapsed = payload["elapsedTime"] as? Double ?? 0
        elapsed = newElapsed
        elapsedBase = newElapsed
        elapsedBaseTime = Date()

        let ownerBundleId = (payload["parentApplicationBundleIdentifier"] as? String) ?? bundleId
        appName = Self.appName(forBundleID: ownerBundleId)

        if let mime = payload["artworkMimeType"] as? String, !mime.isEmpty,
           let base64 = payload["artworkData"] as? String,
           let data = Data(base64Encoded: base64) {
            artwork = NSImage(data: data)
        }
    }

    private func resetToUnavailable() {
        isAvailable = false
        isPlaying = false
        title = ""
        artist = ""
        appName = ""
        artwork = nil
        elapsed = 0
        duration = 0
    }

    private static func appName(forBundleID bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundleID.components(separatedBy: ".").last ?? bundleID
    }

    // MARK: источник AppleScript — опрос раз в секунду (раз в 3, если ничего не играет)

    private func startAppleScriptPolling() {
        appleScriptPollGeneration += 1
        scheduleAppleScriptPoll(generation: appleScriptPollGeneration, delay: 0)
    }

    private func scheduleAppleScriptPoll(generation: Int, delay: TimeInterval) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.appleScriptPollGeneration == generation else { return }
            let snap = ScriptedNowPlaying.snapshot()
            DispatchQueue.main.async { self.applyScripted(snap) }
            let nextDelay: TimeInterval = snap != nil ? 1.0 : 3.0
            self.scheduleAppleScriptPoll(generation: generation, delay: nextDelay)
        }
    }

    private func applyScripted(_ snap: ScriptedNowPlaying.Snapshot?) {
        guard let snap else {
            resetToUnavailable()
            return
        }

        isAvailable = true
        title = snap.title
        artist = snap.artist
        appName = snap.appName
        isPlaying = snap.isPlaying
        duration = snap.duration

        elapsed = snap.elapsed
        elapsedBase = snap.elapsed
        elapsedBaseTime = Date()

        loadArtworkIfNeeded(for: snap)
    }

    /// Обложку кэшируем по паре «исполнитель—название», чтобы не перезагружать её
    /// на каждый опрос. Spotify отдаёт ссылку (грузим сами), Музыка — сразу данные.
    private func loadArtworkIfNeeded(for snap: ScriptedNowPlaying.Snapshot) {
        let key = snap.artist + "—" + snap.title
        if let cached = artworkCache[key] {
            artwork = cached
            return
        }
        if let data = snap.artworkData, let image = NSImage(data: data) {
            artwork = image
            artworkCache[key] = image
            return
        }
        guard let url = snap.artworkURL else {
            artwork = nil
            return
        }
        guard artworkLoadKey != key else { return } // уже грузим эту же обложку
        artworkLoadKey = key
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.artworkLoadKey = nil
                guard let data, let image = NSImage(data: data) else {
                    if let error {
                        NSLog("ShelfTop: не смог загрузить обложку Spotify: %@", error.localizedDescription)
                    }
                    return
                }
                self.artworkCache[key] = image
                // применяем, только если пользователь всё ещё слушает тот же трек
                if key == self.artist + "—" + self.title {
                    self.artwork = image
                }
            }
        }.resume()
    }

    // MARK: плавный прогресс между обновлениями потока

    private func startTicker() {
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        guard isAvailable, isPlaying, duration > 0 else { return }
        let projected = elapsedBase + Date().timeIntervalSince(elapsedBaseTime)
        elapsed = min(duration, max(0, projected))
    }

    // MARK: управление — короткие запуски адаптера с командой `send`/`seek`

    private func sendCommand(_ id: Int) {
        guard isAvailable, let script = Self.scriptURL, let framework = Self.frameworkURL else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: Self.perl)
            p.arguments = [script.path, framework.path, "send", String(id)]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do {
                try p.run()
                p.waitUntilExit()
            } catch {
                NSLog("ShelfTop: команда сейчас-играет (%d) не выполнена: %@", id, error.localizedDescription)
            }
        }
    }

    func togglePlayPause() {
        switch source {
        case .mediaRemote: sendCommand(2) // kMRTogglePlayPause
        case .appleScript: ScriptedNowPlaying.sendCommand(.playPause)
        }
    }

    func next() {
        switch source {
        case .mediaRemote: sendCommand(4) // kMRNextTrack
        case .appleScript: ScriptedNowPlaying.sendCommand(.next)
        }
    }

    func previous() {
        switch source {
        case .mediaRemote: sendCommand(5) // kMRPreviousTrack
        case .appleScript: ScriptedNowPlaying.sendCommand(.previous)
        }
    }

    func seek(fraction: Double) {
        guard isAvailable, duration > 0 else { return }
        let target = min(max(fraction, 0), 1) * duration

        // Не ждём подтверждения от источника — двигаем локально сразу, для отзывчивости полосы.
        elapsedBase = target
        elapsedBaseTime = Date()
        elapsed = target

        switch source {
        case .mediaRemote:
            guard let script = Self.scriptURL, let framework = Self.frameworkURL else { return }
            let micros = Int(target * 1_000_000)
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: Self.perl)
                p.arguments = [script.path, framework.path, "seek", String(micros)]
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                try? p.run()
                p.waitUntilExit()
            }
        case .appleScript:
            ScriptedNowPlaying.seek(toSeconds: target)
        }
    }
}
