import Foundation
import AppKit

// MARK: - Элемент полки

struct ShelfItem: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        case screenshot         // 📷 снимок экрана
        case screenRecording    // 🎬 запись экрана
        case audio              // 🎵 аудио (перетащено пользователем)
        case image              // 🖼 картинка (перетащена пользователем)
        case file               // 📄 прочее

        var badge: String {
            switch self {
            case .screenshot: return "📷"
            case .screenRecording: return "🎬"
            case .audio: return "🎵"
            case .image: return "🖼"
            case .file: return "📄"
            }
        }
    }

    let id: UUID
    var fileName: String        // имя файла внутри библиотеки
    var originalPath: String    // откуда взят
    var kind: Kind
    var addedAt: Date
    var byteSize: Int64
    var sourceInode: UInt64?    // для дедупликации

    var url: URL { Library.capturesDir.appendingPathComponent(fileName) }
    var thumbnailURL: URL { Library.thumbsDir.appendingPathComponent(id.uuidString + ".png") }
    var displayName: String { fileName }
}

// MARK: - Библиотека (индекс + файлы)

final class Library: ObservableObject {
    static let shared = Library()

    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ShelfTop", isDirectory: true)
    }()
    static let capturesDir = root.appendingPathComponent("Captures", isDirectory: true)
    static let thumbsDir   = root.appendingPathComponent("Thumbnails", isDirectory: true)
    static let indexURL    = root.appendingPathComponent("index.json")

    /// Новые — первыми.
    @Published private(set) var items: [ShelfItem] = []


    private init() {
        for dir in [Library.root, Library.capturesDir, Library.thumbsDir] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        load()
    }

    // MARK: индекс

    func load() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601   // симметрично save(): иначе индекс не читается
        guard let data = try? Data(contentsOf: Library.indexURL) else { return }
        let decoded: [ShelfItem]
        do { decoded = try dec.decode([ShelfItem].self, from: data) }
        catch { NSLog("ShelfTop: индекс не прочитан: %@", String(describing: error)); return }
        // выбрасываем записи, чей файл исчез
        let alive = decoded.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        items = alive.sorted { $0.addedAt > $1.addedAt }
        if alive.count != decoded.count { save() }
    }

    /// Пишем синхронно: индекс крохотный, а асинхронная запись терялась,
    /// если приложение завершалось сразу после добавления файла.
    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(items) else { return }
        try? data.write(to: Library.indexURL, options: .atomic)
    }

    // MARK: приём файлов

    /// Уже брали этот файл? (по inode исходника или по пути)
    func alreadyHave(inode: UInt64?, originalPath: String) -> Bool {
        items.contains { ($0.sourceInode != nil && $0.sourceInode == inode) || $0.originalPath == originalPath }
    }

    /// Кладёт файл в библиотеку. `move == true` — переносит (убирает с Рабочего стола),
    /// иначе копирует. Возвращает созданный элемент.
    @discardableResult
    func ingest(_ source: URL, kind: ShelfItem.Kind, move: Bool) -> ShelfItem? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return nil }
        let attrs = try? fm.attributesOfItem(atPath: source.path)
        let inode = (attrs?[.systemFileNumber] as? NSNumber)?.uint64Value
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        if alreadyHave(inode: inode, originalPath: source.path) { return nil }

        let dest = Library.uniqueDestination(for: source.lastPathComponent)
        do {
            if move { try fm.moveItem(at: source, to: dest) }
            else { try fm.copyItem(at: source, to: dest) }
        } catch {
            NSLog("ShelfTop: не смог принять %@: %@", source.path, error.localizedDescription)
            return nil
        }

        let item = ShelfItem(id: UUID(), fileName: dest.lastPathComponent,
                             originalPath: source.path, kind: kind, addedAt: Date(),
                             byteSize: size, sourceInode: inode)
        DispatchQueue.main.async {
            self.items.insert(item, at: 0)
            self.save()
            Thumbnailer.generate(for: item)
            NotificationCenter.default.post(name: .shelfDidAddItem, object: item)
        }
        return item
    }

    static func uniqueDestination(for name: String) -> URL {
        let fm = FileManager.default
        var candidate = capturesDir.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        repeat {
            let next = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = capturesDir.appendingPathComponent(next)
            n += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }

    // MARK: удаление

    func remove(_ item: ShelfItem, deleteFile: Bool = true) {
        NSLog("ShelfTop: удаление в Корзину — %@", item.fileName)
        if deleteFile { try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil) }
        try? FileManager.default.removeItem(at: item.thumbnailURL)
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear() {
        NSLog("ShelfTop: очистка полки, элементов: %d", items.count)
        for item in items {
            try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            try? FileManager.default.removeItem(at: item.thumbnailURL)
        }
        items.removeAll()
        save()
    }

    /// Автоочистка: удалить всё старше N дней (0 — выключено).
    func pruneOlderThan(days: Int) {
        guard days > 0 else { return }
        NSLog("ShelfTop: автоочистка старше %d дн.", days)
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        for item in items where item.addedAt < cutoff { remove(item) }
    }

    func reveal(_ item: ShelfItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }
}

extension Notification.Name {
    static let shelfDidAddItem = Notification.Name("by.maru.shelftop.didAddItem")
}
