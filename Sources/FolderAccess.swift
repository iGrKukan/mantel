import Foundation

/// Доступ к папкам вне бандла приложения.
///
/// В песочнице (сборка APPSTORE) обычный путь-строка бесполезен после перезапуска —
/// доступ теряется. Вместо этого храним security-scoped bookmark (AppSettings.folderBookmarks)
/// и держим startAccessingSecurityScopedResource() открытым, пока приложение живёт.
///
/// Вне песочницы (обычная сборка) весь механизм вырождается в «путь → URL»: закладки
/// не нужны и ничего не меняют — см. ветку `#else` ниже.
enum FolderAccess {
#if APPSTORE
    /// URL, на которые сейчас удерживается startAccessingSecurityScopedResource, по пути.
    private static var activeURLs: [String: URL] = [:]
    private static let lock = NSLock()

    /// Сохраняет закладку для URL, выбранного пользователем (через NSOpenPanel).
    static func store(_ url: URL) {
        guard let data = try? url.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        else {
            NSLog("Mantel: не смог создать security-scoped bookmark для %@", url.path)
            return
        }
        var bookmarks = AppSettings.shared.folderBookmarks
        bookmarks[url.path] = data
        AppSettings.shared.folderBookmarks = bookmarks
    }

    /// Забывает закладку и, если доступ был открыт, закрывает его.
    static func forget(_ path: String) {
        lock.lock()
        let active = activeURLs.removeValue(forKey: path)
        lock.unlock()
        active?.stopAccessingSecurityScopedResource()

        var bookmarks = AppSettings.shared.folderBookmarks
        bookmarks.removeValue(forKey: path)
        AppSettings.shared.folderBookmarks = bookmarks
    }

    /// Разрешает закладку в URL без старта доступа. nil — закладки нет или она не читается.
    static func resolvedURL(for path: String) -> URL? {
        guard let data = AppSettings.shared.folderBookmarks[path] else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data, options: .withSecurityScope,
            relativeTo: nil, bookmarkDataIsStale: &stale)
        else { return nil }
        if stale { store(url) }   // закладка протухла — перезаписываем свежей тем же путём
        return url
    }

    /// Разрешает закладку и открывает доступ. Держит его открытым до endAccess/выхода
    /// из приложения — повторный вызов для того же пути просто возвращает тот же URL.
    @discardableResult
    static func beginAccess(_ path: String) -> URL? {
        lock.lock()
        if let existing = activeURLs[path] {
            lock.unlock()
            return existing
        }
        lock.unlock()

        guard let url = resolvedURL(for: path) else { return nil }
        guard url.startAccessingSecurityScopedResource() else {
            NSLog("Mantel: не смог начать доступ к %@", path)
            return nil
        }
        lock.lock()
        activeURLs[path] = url
        lock.unlock()
        return url
    }

    /// Закрывает доступ, открытый beginAccess.
    static func endAccess(_ url: URL) {
        lock.lock()
        if let key = activeURLs.first(where: { $0.value == url })?.key {
            activeURLs.removeValue(forKey: key)
        }
        lock.unlock()
        url.stopAccessingSecurityScopedResource()
    }

    /// Закрывает весь открытый доступ — звать на выходе из приложения.
    static func endAllAccess() {
        lock.lock()
        let urls = Array(activeURLs.values)
        activeURLs.removeAll()
        lock.unlock()
        urls.forEach { $0.stopAccessingSecurityScopedResource() }
    }

    /// Папки, которые сейчас отслеживаются (см. AppSettings), но не имеют рабочей закладки —
    /// для окна настроек: показать «доступ не выдан» и кнопку «Разрешить…».
    static var needsPermission: [String] {
        let settings = AppSettings.shared
        var paths: [String] = []
        if settings.watchDesktop { paths.append(("~/Desktop" as NSString).expandingTildeInPath) }
        if settings.watchScreenshotsFolder { paths.append(("~/Screenshots" as NSString).expandingTildeInPath) }
        paths.append(contentsOf: settings.extraFolders)
        paths.append(contentsOf: settings.mirrorFolders)
        if !settings.googleDriveDestination.isEmpty { paths.append(settings.googleDriveDestination) }
        return paths.filter { resolvedURL(for: $0) == nil }
    }
#else
    // Вне песочницы закладки не нужны: путь и так работает после перезапуска.
    static func store(_ url: URL) {}
    static func forget(_ path: String) {}
    static func resolvedURL(for path: String) -> URL? { URL(fileURLWithPath: path) }
    @discardableResult
    static func beginAccess(_ path: String) -> URL? { URL(fileURLWithPath: path) }
    static func endAccess(_ url: URL) {}
    static func endAllAccess() {}
    static var needsPermission: [String] { [] }
#endif
}
