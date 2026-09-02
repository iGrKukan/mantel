import Foundation
import CoreServices
import AVFoundation

// MARK: - Слежение за папками захвата (скриншоты/записи экрана) и папками-источниками

/// Ловит появление файлов в заданных папках через FSEvents (без поллинга) и переносит
/// (или копирует) их в библиотеку через Library.shared.ingest.
///
/// Два независимых режима на одном общем FSEvents-потоке:
/// - «папки захвата» (Рабочий стол, ~/Screenshots, extraFolders) — только снимки/записи экрана;
/// - «папки-источники» (mirrorFolders) — любой файл первого уровня папки.
final class CaptureWatcher {
    static let shared = CaptureWatcher()

    private enum CaptureKind {
        case screenshot
        case screenRecording
    }

    /// Откуда пришёл кандидат — определяет правила классификации и move/copy.
    private enum SourceKind {
        case capture
        case mirror
    }

    private static let screenshotExts: Set<String> = ["png", "jpg", "jpeg", "heic"]
    private static let recordingExts: Set<String> = ["mov", "mp4", "m4v"]

    private static let mirrorAudioExts: Set<String> = ["mp3", "m4a", "aac", "wav", "aiff", "flac"]
    private static let mirrorImageExts: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "tiff"]
    private static let mirrorRecordingExts: Set<String> = ["mov", "mp4", "m4v"]

    /// Папка-источник больше этого числа файлов — отказываемся, чтобы не унести чужой архив.
    private static let maxMirrorFiles = 500

    /// Своя serial-очередь: на ней и события FSEvents, и поллинг дописи файла.
    private let queue = DispatchQueue(label: "by.maru.mantel.capturewatcher")
    private var streamRef: FSEventStreamRef?

    private var captureFolders: [URL] = []
    private var mirrorFolders: [URL] = []
    /// Пути папок верхнего уровня — по ним определяем, откуда пришёл файл в колбэке FSEvents.
    private var captureFolderPaths: Set<String> = []
    private var mirrorFolderPaths: Set<String> = []

    /// Пути, уже находящиеся в обработке — чтобы не запускать перенос дважды.
    private var inFlight: Set<String> = []
    private let inFlightLock = NSLock()

    private init() {}

    // MARK: - Публичное API

    /// Перезапускает поток на новом списке папок захвата. Папки-источники берутся
    /// отдельно из AppSettings — сигнатуру, которую зовёт AppDelegate, не трогаем.
    func start(folders: [URL]) {
        stop()
        // Доступ открываем ДО validateMirrorFolders — ей нужно читать содержимое папки
        // (посчитать файлы), а в песочнице contentsOfDirectory работает только внутри
        // уже открытого startAccessingSecurityScopedResource.
        let (capture, captureAccessWarnings) = resolveAccessibleFolders(folders)
        let (accessibleMirror, mirrorAccessWarnings) = resolveAccessibleFolders(AppSettings.shared.mirrorFolderURLs)
        let (mirror, mirrorValidationWarnings) = validateMirrorFolders(accessibleMirror)

        captureFolders = capture
        mirrorFolders = mirror
        captureFolderPaths = Set(captureFolders.map { $0.path })
        mirrorFolderPaths = Set(mirrorFolders.map { $0.path })

        let warnings = captureAccessWarnings + mirrorAccessWarnings + mirrorValidationWarnings
        DispatchQueue.main.async { AppSettings.shared.lastMirrorWarning = warnings.joined(separator: "\n") }

        let allFolders = captureFolders + mirrorFolders
        guard !allFolders.isEmpty else { return }
        scanExisting(captureFolders: captureFolders, mirrorFolders: mirrorFolders)
        startStream(for: allFolders)
    }

    func stop() {
        guard let ref = streamRef else { return }
        FSEventStreamStop(ref)
        FSEventStreamInvalidate(ref)
        FSEventStreamRelease(ref)
        streamRef = nil
    }

    // MARK: - Защита от глупости (папки-источники)

    /// Отбрасывает папки-источники, которые совпадают с домашней/корнем/Documents/Downloads
    /// целиком или содержат слишком много файлов. Пишет понятное предупреждение в настройки.
    /// Папки-источники, из которых при старте берём только свежие файлы (не всё подряд).
    private var mirrorSkipBulkPaths: Set<String> = []

    private func validateMirrorFolders(_ folders: [URL]) -> (accepted: [URL], warnings: [String]) {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL.path
        // Запрещаем только то, что заведомо утащит всё подряд.
        let forbidden: Set<String> = [home, "/"]
        // Большие и «живые» папки берём под наблюдение, но старое содержимое не переносим —
        // забираем только то, что появится дальше.
        let bulkySystemFolders: Set<String> = [
            (home as NSString).appendingPathComponent("Documents"),
            (home as NSString).appendingPathComponent("Downloads"),
            (home as NSString).appendingPathComponent("Desktop"),
        ]

        var warnings: [String] = []
        var accepted: [URL] = []
        var skipBulk: Set<String> = []
        for folder in folders {
            let path = folder.standardizedFileURL.path
            if forbidden.contains(path) {
                let msg = "Папка «\(path)» не подходит для зеркалирования — это системная папка целиком, выберите подпапку."
                NSLog("Mantel: %@", msg)
                warnings.append(msg)
                continue
            }
            let count = (try? fm.contentsOfDirectory(atPath: path))?.count ?? 0
            if bulkySystemFolders.contains(path) || count > Self.maxMirrorFiles {
                skipBulk.insert(path)
                let name = (path as NSString).lastPathComponent
                let msg = "Папка «\(name)»: старое содержимое (\(count) файлов) не переносится — в полку попадут только новые файлы."
                NSLog("Mantel: %@", msg)
                warnings.append(msg)
            }
            accepted.append(folder)
        }

        mirrorSkipBulkPaths = skipBulk
        return (accepted, warnings)
    }

    // MARK: - Доступ к папкам (security-scoped bookmarks в песочнице)

    /// Открывает доступ (см. FolderAccess) к каждой папке; недоступные пропускает вместо
    /// падения. Вне песочницы (`#if !APPSTORE`) FolderAccess.beginAccess — no-op, доступ
    /// есть всегда, warnings всегда пуст.
    private func resolveAccessibleFolders(_ folders: [URL]) -> (accessible: [URL], warnings: [String]) {
        var accessible: [URL] = []
        var warnings: [String] = []
        for folder in folders {
            if let url = FolderAccess.beginAccess(folder.path) {
                accessible.append(url)
            } else {
                let name = (folder.path as NSString).lastPathComponent
                let msg = "Папка «\(name)»: доступ не выдан — разреши её в настройках."
                NSLog("Mantel: %@", msg)
                warnings.append(msg)
            }
        }
        return (accessible, warnings)
    }

    // MARK: - FSEvents

    private func startStream(for folders: [URL]) {
        let pathsToWatch = folders.map { $0.path } as CFArray

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags: FSEventStreamCreateFlags =
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents) |
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer) |
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)

        let callback: FSEventStreamCallback = { (_, clientInfo, numEvents, eventPaths, _, _) in
            guard let clientInfo = clientInfo else { return }
            let watcher = Unmanaged<CaptureWatcher>.fromOpaque(clientInfo).takeUnretainedValue()
            guard let paths = unsafeBitCast(eventPaths, to: CFArray.self) as? [String] else { return }
            for path in paths {
                watcher.considerCandidate(path: path)
            }
        }

        guard let ref = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            flags
        ) else {
            NSLog("Mantel: не смог создать FSEventStream")
            return
        }

        FSEventStreamSetDispatchQueue(ref, queue)
        FSEventStreamStart(ref)
        streamRef = ref
    }

    // MARK: - Разовое сканирование при старте

    /// Подхватывает файлы, оставшиеся с прошлого раза.
    /// Папки захвата — только свежие (последние 5 минут), чтобы не унести старьё пользователя.
    /// Папки-источники — без ограничения по возрасту: пользователь сам выбрал папку целиком.
    private func scanExisting(captureFolders: [URL], mirrorFolders: [URL]) {
        let cutoff = Date().addingTimeInterval(-5 * 60)
        queue.async { [weak self] in
            guard let self = self else { return }
            for folder in captureFolders {
                guard let entries = try? FileManager.default.contentsOfDirectory(
                    at: folder,
                    includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for entry in entries {
                    let values = try? entry.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                    guard let created = values?.creationDate ?? values?.contentModificationDate,
                          created >= cutoff else { continue }
                    self.considerCandidate(path: entry.path)
                }
            }
            for folder in mirrorFolders {
                let skipOld = self.mirrorSkipBulkPaths.contains(folder.standardizedFileURL.path)
                guard let entries = try? FileManager.default.contentsOfDirectory(
                    at: folder,
                    includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for entry in entries {
                    if skipOld {
                        let values = try? entry.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                        guard let created = values?.creationDate ?? values?.contentModificationDate,
                              created >= cutoff else { continue }
                    }
                    self.considerCandidate(path: entry.path)
                }
            }
        }
    }

    // MARK: - Определение источника

    /// Папка захвата или папка-источник — по прямому родителю пути (без спуска в подпапки).
    private func sourceKind(for path: String) -> SourceKind? {
        let parent = (path as NSString).deletingLastPathComponent
        if captureFolderPaths.contains(parent) { return .capture }
        if mirrorFolderPaths.contains(parent) { return .mirror }
        return nil
    }

    // MARK: - Классификация

    /// true, если файл — точно мусор/временный (в обоих режимах), не проверяя дальше.
    private func isIgnorable(name: String, ext: String) -> Bool {
        if name.hasPrefix(".") { return true }               // скрытые, в т.ч. sandbox-временные ".Screenshot....sb-*"
        if name == ".DS_Store" { return true }
        if ["download", "crdownload", "part"].contains(ext) { return true }
        if name.contains(".sb-") { return true }              // "Screenshot ....png.sb-*"
        return false
    }

    /// Определяет, является ли файл скриншотом/записью экрана. nil — не трогать.
    private func classifyCapture(path: String) -> CaptureKind? {
        let name = (path as NSString).lastPathComponent
        let ext = (path as NSString).pathExtension.lowercased()

        // 1) Spotlight-метаданные (могут проставляться с задержкой)
        if let mdItem = MDItemCreate(nil, path as CFString) {
            if let flag = MDItemCopyAttribute(mdItem, "kMDItemIsScreenCapture" as CFString) as? NSNumber,
               flag.boolValue {
                return .screenshot
            }
            if let flag = MDItemCopyAttribute(mdItem, "kMDItemIsScreenRecording" as CFString) as? NSNumber,
               flag.boolValue {
                return .screenRecording
            }
            if MDItemCopyAttribute(mdItem, "kMDItemScreenCaptureType" as CFString) != nil {
                return Self.recordingExts.contains(ext) ? .screenRecording : .screenshot
            }
        }

        // 2) Фолбэк по имени файла
        let lower = name.lowercased()
        let looksLikeScreenshot = lower.hasPrefix("снимок экрана") || lower.hasPrefix("screenshot") || lower.hasPrefix("screen shot")
        let looksLikeRecording = lower.hasPrefix("запись экрана") || lower.hasPrefix("screen recording")

        if looksLikeRecording, Self.recordingExts.contains(ext) { return .screenRecording }
        if looksLikeScreenshot, Self.screenshotExts.contains(ext) { return .screenshot }

        return nil
    }

    /// Для папки-источника берём ЛЮБОЙ файл, вид — по расширению.
    private func classifyMirror(ext: String) -> ShelfItem.Kind {
        if Self.mirrorAudioExts.contains(ext) { return .audio }
        if Self.mirrorImageExts.contains(ext) { return .image }
        if Self.mirrorRecordingExts.contains(ext) { return .screenRecording }
        return .file
    }

    // MARK: - Обработка кандидата

    private func considerCandidate(path: String) {
        guard let source = sourceKind(for: path) else { return }

        let name = (path as NSString).lastPathComponent
        let ext = (path as NSString).pathExtension.lowercased()
        if isIgnorable(name: name, ext: ext) { return }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { return }

        let libraryKind: ShelfItem.Kind
        let move: Bool
        switch source {
        case .capture:
            guard let captureKind = classifyCapture(path: path) else { return }
            libraryKind = (captureKind == .screenshot) ? .screenshot : .screenRecording
            move = true
        case .mirror:
            libraryKind = classifyMirror(ext: ext)
            move = AppSettings.shared.mirrorMovesFiles
        }

        inFlightLock.lock()
        let alreadyInFlight = inFlight.contains(path)
        if !alreadyInFlight { inFlight.insert(path) }
        inFlightLock.unlock()
        if alreadyInFlight { return }

        waitUntilStable(path: path) { [weak self] stableURL in
            guard let self = self else { return }
            self.inFlightLock.lock()
            self.inFlight.remove(path)
            self.inFlightLock.unlock()

            guard let stableURL = stableURL else {
                NSLog("Mantel: файл не дописался за отведённое время: %@", (path as NSString).lastPathComponent)
                return
            }

            DispatchQueue.main.async {
                Library.shared.ingest(stableURL, kind: libraryKind, move: move)
            }
        }
    }

    /// Ждёт, пока файл перестанет дописываться: размер стабилен 3 замера подряд (каждые 0.5с) и > 0.
    /// Для видео дополнительно ждёт, пока в нём появится читаемая видеодорожка.
    /// Общий таймаут — 120с (по нему отказываемся; FSEvents позовёт нас снова при следующем событии).
    private func waitUntilStable(path: String, completion: @escaping (URL?) -> Void) {
        let deadline = Date().addingTimeInterval(120)
        var lastSize: Int64 = -1
        var stableCount = 0

        func poll() {
            guard FileManager.default.fileExists(atPath: path) else {
                completion(nil)
                return
            }
            if Date() > deadline {
                completion(nil)
                return
            }

            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
            let canRead = FileManager.default.isReadableFile(atPath: path)

            if canRead, size > 0, size == lastSize {
                stableCount += 1
            } else {
                stableCount = 0
            }
            lastSize = size

            guard stableCount >= 3 else {
                self.queue.asyncAfter(deadline: .now() + 0.5, execute: poll)
                return
            }

            // видео могло дозаписать заголовок ещё позже, чем стабилизировался размер
            let ext = (path as NSString).pathExtension.lowercased()
            if ext == "mov" || ext == "mp4" || ext == "m4v" {
                let asset = AVURLAsset(url: URL(fileURLWithPath: path))
                let hasVideoTrack = !asset.tracks(withMediaType: .video).isEmpty
                guard hasVideoTrack else {
                    self.queue.asyncAfter(deadline: .now() + 0.5, execute: poll)
                    return
                }
            }

            completion(URL(fileURLWithPath: path))
        }

        queue.async(execute: poll)
    }
}
