import Foundation
import ServiceManagement

extension Notification.Name {
    /// Список отслеживаемых папок изменился — CaptureWatcher нужно перезапустить.
    static let shelfSettingsChanged = Notification.Name("by.maru.mantel.settingsChanged")
}

/// Границы размера полки — общие для полей настроек и перетаскивания краёв мышью.
enum ShelfSizeLimits {
    static let minWidth: Double = 480
    static let maxWidth: Double = 1600
    static let minHeight: Double = 200
    static let maxHeight: Double = 600
    /// Размер по умолчанию — на него возвращает кнопка «Сбросить размер».
    static let defaultWidth: Double = 720
    static let defaultHeight: Double = 272
}

/// Настройки приложения. Хранятся в UserDefaults, читаются при старте (с дефолтами
/// через register(defaults:)), пишутся при каждом изменении.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Keys {
        static let watchDesktop = "watchDesktop"
        static let watchScreenshotsFolder = "watchScreenshotsFolder"
        static let extraFolders = "extraFolders"
        static let hotZoneEnabled = "hotZoneEnabled"
        static let shelfWidth = "shelfWidth"
        static let shelfHeight = "shelfHeight"
        static let autoPruneDays = "autoPruneDays"
        static let launchAtLogin = "launchAtLogin"
        static let googleDriveSubfolder = "googleDriveSubfolder"
        static let mirrorFolders = "mirrorFolders"
        static let mirrorMovesFiles = "mirrorMovesFiles"
        static let googleDriveDestination = "googleDriveDestination"
        static let folderBookmarks = "folderBookmarks"
    }

    @Published var watchDesktop: Bool {
        didSet {
            UserDefaults.standard.set(watchDesktop, forKey: Keys.watchDesktop)
            postFoldersChanged()
        }
    }
    @Published var watchScreenshotsFolder: Bool {
        didSet {
            UserDefaults.standard.set(watchScreenshotsFolder, forKey: Keys.watchScreenshotsFolder)
            postFoldersChanged()
        }
    }
    @Published var extraFolders: [String] {
        didSet {
            UserDefaults.standard.set(extraFolders, forKey: Keys.extraFolders)
            postFoldersChanged()
        }
    }
    @Published var hotZoneEnabled: Bool {
        didSet { UserDefaults.standard.set(hotZoneEnabled, forKey: Keys.hotZoneEnabled) }
    }
    @Published var shelfWidth: Double {
        didSet { UserDefaults.standard.set(shelfWidth, forKey: Keys.shelfWidth) }
    }
    @Published var shelfHeight: Double {
        didSet { UserDefaults.standard.set(shelfHeight, forKey: Keys.shelfHeight) }
    }
    @Published var autoPruneDays: Int {
        didSet { UserDefaults.standard.set(autoPruneDays, forKey: Keys.autoPruneDays) }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: Keys.launchAtLogin)
            applyLaunchAtLogin()
        }
    }
    @Published var googleDriveSubfolder: String {
        didSet { UserDefaults.standard.set(googleDriveSubfolder, forKey: Keys.googleDriveSubfolder) }
    }
    /// Явный путь папки назначения на Диске. Пустая строка — папка по умолчанию
    /// (`driveRoot/googleDriveSubfolder`), см. GoogleDrive.destinationURL.
    @Published var googleDriveDestination: String {
        didSet { UserDefaults.standard.set(googleDriveDestination, forKey: Keys.googleDriveDestination) }
    }
    /// Папки-источники: из них в полку попадает ЛЮБОЙ файл (не только снимки экрана).
    @Published var mirrorFolders: [String] {
        didSet {
            UserDefaults.standard.set(mirrorFolders, forKey: Keys.mirrorFolders)
            postFoldersChanged()
        }
    }
    /// false — файл из папки-источника копируется, true — переносится (как снимки экрана).
    @Published var mirrorMovesFiles: Bool {
        didSet { UserDefaults.standard.set(mirrorMovesFiles, forKey: Keys.mirrorMovesFiles) }
    }
    /// Предупреждение об отклонённой папке-источнике (пустая строка — предупреждений нет).
    @Published var lastMirrorWarning: String = ""

    /// Security-scoped bookmarks для доступа к папкам в песочнице (сборка APPSTORE):
    /// путь папки → bookmarkData(.withSecurityScope). Читает и пишет FolderAccess.
    /// Вне песочницы не используется, но хранится безусловно — при переключении
    /// сборки (APPSTORE/обычная) старые записи просто не мешают.
    var folderBookmarks: [String: Data] {
        get { UserDefaults.standard.dictionary(forKey: Keys.folderBookmarks) as? [String: Data] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Keys.folderBookmarks) }
    }

    /// Настройки жили в домене by.maru.ShelfTop — переносим один раз.
    private static func migrateOldDomain() {
        let d = UserDefaults.standard
        guard d.object(forKey: "migratedFromShelfTop") == nil else { return }
        if let old = UserDefaults(suiteName: "by.maru.ShelfTop")?.dictionaryRepresentation() {
            for key in [Keys.watchDesktop, Keys.watchScreenshotsFolder, Keys.extraFolders,
                        Keys.hotZoneEnabled, Keys.shelfWidth, Keys.autoPruneDays,
                        Keys.launchAtLogin, Keys.googleDriveSubfolder, Keys.googleDriveDestination,
                        Keys.mirrorFolders, Keys.mirrorMovesFiles] {
                if let value = old[key], d.object(forKey: key) == nil { d.set(value, forKey: key) }
            }
        }
        d.set(true, forKey: "migratedFromShelfTop")
    }

    /// Итоговый список папок для наблюдения: флаги + свои пути, с раскрытым `~`.
    var watchedFolders: [URL] {
        var paths: [String] = []
        if watchDesktop { paths.append("~/Desktop") }
        if watchScreenshotsFolder { paths.append("~/Screenshots") }
        paths.append(contentsOf: extraFolders)
        return paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    }

    /// Папки-источники с раскрытым `~`.
    var mirrorFolderURLs: [URL] {
        mirrorFolders.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    }

    private init() {
        AppSettings.migrateOldDomain()
        UserDefaults.standard.register(defaults: [
            Keys.watchDesktop: true,
            Keys.watchScreenshotsFolder: true,
            Keys.extraFolders: [String](),
            Keys.hotZoneEnabled: true,
            Keys.shelfWidth: ShelfSizeLimits.defaultWidth,
            Keys.shelfHeight: ShelfSizeLimits.defaultHeight,
            Keys.autoPruneDays: 0,
            Keys.launchAtLogin: false,
            Keys.googleDriveSubfolder: "Mantel",
            Keys.mirrorFolders: [String](),
            Keys.mirrorMovesFiles: false,
            Keys.googleDriveDestination: "",
        ])

        let d = UserDefaults.standard
        watchDesktop = d.bool(forKey: Keys.watchDesktop)
        watchScreenshotsFolder = d.bool(forKey: Keys.watchScreenshotsFolder)
        extraFolders = d.stringArray(forKey: Keys.extraFolders) ?? []
        hotZoneEnabled = d.bool(forKey: Keys.hotZoneEnabled)
        shelfWidth = d.double(forKey: Keys.shelfWidth)
        shelfHeight = d.double(forKey: Keys.shelfHeight)
        autoPruneDays = d.integer(forKey: Keys.autoPruneDays)
        launchAtLogin = d.bool(forKey: Keys.launchAtLogin)
        googleDriveSubfolder = d.string(forKey: Keys.googleDriveSubfolder) ?? "Mantel"
        mirrorFolders = d.stringArray(forKey: Keys.mirrorFolders) ?? []
        mirrorMovesFiles = d.bool(forKey: Keys.mirrorMovesFiles)
        googleDriveDestination = d.string(forKey: Keys.googleDriveDestination) ?? ""

        // Источник истины — сохранённая настройка: если пользователь включил автозапуск,
        // а система его не видит (переустановка приложения), регистрируем при старте.
        if (SMAppService.mainApp.status == .enabled) != launchAtLogin { applyLaunchAtLogin() }
    }

    /// Добавляет папку-источник, если она реально читается и ещё не добавлена.
    /// Сам путь тут — обычная строка; закладку для песочницы (сборка APPSTORE) сохраняет
    /// вызывающая сторона через FolderAccess.store до вызова этого метода (см. SettingsWindow).
    func addMirrorFolder(_ path: String) {
        guard (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil else {
            NSLog("Mantel: папка-источник не читается, не добавляю: %@", path)
            return
        }
        guard !mirrorFolders.contains(path) else { return }
        mirrorFolders.append(path)
    }

    func removeMirrorFolder(_ path: String) {
        mirrorFolders.removeAll { $0 == path }
    }

    private func postFoldersChanged() {
        NotificationCenter.default.post(name: .shelfSettingsChanged, object: nil)
    }

    private func applyLaunchAtLogin() {
        // Ничего не делаем, если система уже в нужном состоянии — иначе SMAppService
        // ругается «Operation not permitted» на холостом unregister при старте.
        let enabled = SMAppService.mainApp.status == .enabled
        guard enabled != launchAtLogin else { return }
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Mantel: не смог изменить запуск при входе: %@", error.localizedDescription)
        }
    }
}
