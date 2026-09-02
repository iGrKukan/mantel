import Foundation
import AppKit

/// Выгрузка в Google Диск без OAuth и без сети: используем локально смонтированную
/// папку синхронизации официального приложения «Google Drive.app».
enum GoogleDrive {
    /// Корень «Мой диск». Порядок поиска: CloudStorage → /Volumes → ~/Google Drive.
    static var driveRoot: URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let driveNames = ["My Drive", "Мой диск"]

        // 1. ~/Library/CloudStorage/GoogleDrive-*/My Drive|Мой диск — основной путь на актуальных macOS.
        let cloudStorage = home.appendingPathComponent("Library/CloudStorage")
        if let entries = try? fm.contentsOfDirectory(at: cloudStorage, includingPropertiesForKeys: nil) {
            for dir in entries where dir.lastPathComponent.hasPrefix("GoogleDrive-") {
                for name in driveNames {
                    let candidate = dir.appendingPathComponent(name)
                    if fm.fileExists(atPath: candidate.path) { return candidate }
                }
            }
        }

        // 2. /Volumes — фиксированные пути, затем любой смонтированный том с нужной подпапкой.
        for path in ["/Volumes/GoogleDrive/My Drive", "/Volumes/GoogleDrive/Мой диск"] {
            if fm.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        }
        if let volumes = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: "/Volumes"), includingPropertiesForKeys: nil) {
            for volume in volumes {
                for name in driveNames {
                    let candidate = volume.appendingPathComponent(name)
                    if fm.fileExists(atPath: candidate.path) { return candidate }
                }
            }
        }

        // 3. ~/Google Drive (старый клиент).
        for candidate in [
            home.appendingPathComponent("Google Drive/My Drive"),
            home.appendingPathComponent("Google Drive/Мой диск"),
            home.appendingPathComponent("Google Drive"),
        ] {
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }

        return nil
    }

    static var isAvailable: Bool { driveRoot != nil }

    /// Итоговая папка назначения: явный путь из настроек (`AppSettings.googleDriveDestination`),
    /// если он задан и реально существует, иначе `driveRoot/googleDriveSubfolder` (старое поведение).
    static var destinationURL: URL? {
        let explicit = AppSettings.shared.googleDriveDestination
        if !explicit.isEmpty {
            let url = URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        guard let root = driveRoot else { return nil }
        return root.appendingPathComponent(AppSettings.shared.googleDriveSubfolder, isDirectory: true)
    }

    /// Подпапки первого уровня папки назначения, по имени, максимум `limit` штук —
    /// для панели «Куда положить» при перетаскивании на иконку Диска.
    static func subfolders(limit: Int = 6) -> [URL] {
        guard let dest = destinationURL,
              let accessibleDest = FolderAccess.beginAccess(dest.path),
              let entries = try? FileManager.default.contentsOfDirectory(
                at: accessibleDest, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }
        let dirs = entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        return dirs
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(limit)
            .map { $0 }
    }

    /// Копирует файлы в папку назначения (см. `destinationURL`), уникализируя имена
    /// при коллизии. Работает в фоне, completion вызывается на главном потоке.
    static func upload(_ items: [ShelfItem], completion: @escaping (Result<Int, Error>) -> Void) {
        upload(urls: items.map { $0.url }, completion: completion)
    }

    /// То же для произвольных файлов — например, перетащенных прямо на иконку Диска.
    static func upload(urls: [URL], completion: @escaping (Result<Int, Error>) -> Void) {
        guard let destDir = destinationURL else {
            DispatchQueue.main.async { completion(.failure(notFoundError)) }
            return
        }
        performUpload(urls: urls, to: destDir, completion: completion)
    }

    /// Выгрузка в явно указанную папку — например, конкретную подпапку, выбранную
    /// в панели «Куда положить» при наведении файлом на иконку Диска.
    static func upload(urls: [URL], to destination: URL, completion: @escaping (Result<Int, Error>) -> Void) {
        performUpload(urls: urls, to: destination, completion: completion)
    }

    private static var notFoundError: NSError {
        NSError(
            domain: "by.maru.mantel.googledrive", code: 1,
            userInfo: [NSLocalizedDescriptionKey: String(localized: "drive.error.notFound")])
    }

    private static func performUpload(urls: [URL], to destDir: URL, completion: @escaping (Result<Int, Error>) -> Void) {
        // В песочнице сюда мог прийти путь без открытого доступа (например, подпапка,
        // выбранная напрямую) — открываем его здесь же, а не полагаемся на то, что
        // кто-то уже открыл доступ к родителю.
        guard let accessibleDest = FolderAccess.beginAccess(destDir.path) else {
            DispatchQueue.main.async { completion(.failure(notFoundError)) }
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: accessibleDest, withIntermediateDirectories: true)
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }

            var copied = 0
            for url in urls {
                let dest = uniqueDestination(in: accessibleDest, for: url.lastPathComponent)
                do {
                    try fm.copyItem(at: url, to: dest)
                    copied += 1
                } catch {
                    NSLog("Mantel: не смог скопировать на Google Диск %@: %@", url.lastPathComponent, error.localizedDescription)
                }
            }
            DispatchQueue.main.async { completion(.success(copied)) }
        }
    }

    /// Открывает папку назначения в Finder (создаёт при отсутствии).
    static func openFolder() {
        guard let dest = destinationURL, let accessibleDest = FolderAccess.beginAccess(dest.path) else { return }
        try? FileManager.default.createDirectory(at: accessibleDest, withIntermediateDirectories: true)
        NSWorkspace.shared.open(accessibleDest)
    }

    private static func uniqueDestination(in dir: URL, for name: String) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        repeat {
            let next = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = dir.appendingPathComponent(next)
            n += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }
}
