import AppKit

/// Точка входа. Без SwiftUI App-lifecycle — нужен полный контроль над NSApplication
/// (accessory-политика, статус-бар без окна при старте).
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private var statusItem: NSStatusItem?
    private var pruneTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Thumbnailer.regenerateMissing()
        Library.shared.pruneOlderThan(days: AppSettings.shared.autoPruneDays)
        // Автоочистка не только при старте: проверяем раз в час, пока приложение живёт.
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Library.shared.pruneOlderThan(days: AppSettings.shared.autoPruneDays)
        }
        ShelfController.shared.start()

        CaptureWatcher.shared.start(folders: AppSettings.shared.watchedFolders)
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged), name: .shelfSettingsChanged, object: nil)

        setupStatusItem()

#if APPSTORE
        // Mantel --grant-test <папка> — служебный режим только для APPSTORE-сборки:
        // прогоняет ту же цепочку, что кнопка «Разрешить…» в настройках (store → beginAccess →
        // перезапуск CaptureWatcher → обновление доступности), но без NSOpenPanel — панель
        // по ssh не нажать. Нужен, чтобы доказать в песочнице механику доступа на папке,
        // к которой у приложения и так есть право (например, собственный контейнер).
        if let idx = CommandLine.arguments.firstIndex(of: "--grant-test"), idx + 1 < CommandLine.arguments.count {
            runGrantTest(path: CommandLine.arguments[idx + 1])
        }
#endif

        // Mantel --add <файл> [...] — добавить файлы в полку копией (для скриптов и проверки).
        if let idx = CommandLine.arguments.firstIndex(of: "--add") {
            for path in CommandLine.arguments.dropFirst(idx + 1) {
                if path.hasPrefix("--") { break }
                let url = URL(fileURLWithPath: path)
                let ext = url.pathExtension.lowercased()
                let kind: ShelfItem.Kind
                if ["mp3", "m4a", "aac", "wav", "aiff", "aif", "flac"].contains(ext) { kind = .audio }
                else if ["png", "jpg", "jpeg", "heic", "gif", "tiff"].contains(ext) { kind = .image }
                else if ["mov", "mp4", "m4v"].contains(ext) { kind = .screenRecording }
                else { kind = .file }
                Library.shared.ingest(url, kind: kind, move: false)
            }
        }

        // Mantel --snapshot-settings <файл.png> — отрисовать окно настроек и выйти.
        if let idx = CommandLine.arguments.firstIndex(of: "--snapshot-settings"),
           idx + 1 < CommandLine.arguments.count {
            let out = URL(fileURLWithPath: CommandLine.arguments[idx + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                SettingsWindowController.shared.show()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    // Ищем окно настроек по styleMask (.titled — есть только у него; полка —
                    // безрамочная nonactivatingPanel), а не по заголовку — тот теперь
                    // локализован и не годится для сравнения по подстроке.
                    let settingsWindow = NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.titled) }
                        ?? NSApp.windows.filter { $0.isVisible && $0.frame.width > 300 }.last
                    if let view = settingsWindow?.contentView {
                        view.layoutSubtreeIfNeeded()
                        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                            view.cacheDisplay(in: view.bounds, to: rep)
                            if let png = rep.representation(using: .png, properties: [:]) {
                                try? png.write(to: out)
                                NSLog("Mantel: снимок настроек -> %@", out.path)
                            }
                        }
                    }
                    NSApp.terminate(nil)
                }
            }
        }

        // Служебный режим: Mantel --snapshot <файл.png> — отрисовать развёрнутую полку
        // в PNG и выйти. Нужен для проверки вёрстки, когда снимок экрана недоступен.
        if let idx = CommandLine.arguments.firstIndex(of: "--snapshot"),
           idx + 1 < CommandLine.arguments.count {
            let out = URL(fileURLWithPath: CommandLine.arguments[idx + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if let track = Library.shared.items.first(where: { AudioPlayerModel.isAudio($0) }) {
                    AudioPlayerModel.shared.toggle(track)
                }
                ShelfController.shared.show(animated: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    ShelfController.shared.show(animated: false)   // авто-сворачивание могло успеть сработать
                    ShelfController.shared.writeSnapshot(to: out)
                    NSApp.terminate(nil)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Закрываем весь security-scoped доступ, открытый FolderAccess.beginAccess
        // (в обычной сборке — no-op, там его и не было).
        FolderAccess.endAllAccess()
    }

    @objc private func settingsChanged() {
        // Список папок мог измениться — перезапускаем наблюдатель с актуальным списком.
        CaptureWatcher.shared.stop()
        CaptureWatcher.shared.start(folders: AppSettings.shared.watchedFolders)
    }

#if APPSTORE
    /// См. --grant-test выше: та же цепочка, что вызывает кнопка «Разрешить…» в разделе
    /// «Слежение» (SettingsWindow.grantAccess), но с готовым URL вместо результата NSOpenPanel.
    /// Пишет в NSLog каждый шаг — этим доказываем, что store→beginAccess→watch→UI работает
    /// внутри песочницы, не полагаясь на клик по панели (её по ssh не нажать).
    private func runGrantTest(path: String) {
        let url = URL(fileURLWithPath: path)
        NSLog("Mantel: --grant-test запуск для %@", url.path)

        FolderAccess.store(url)
        let bookmarkBytes = AppSettings.shared.folderBookmarks[url.path]?.count ?? -1
        NSLog("Mantel: --grant-test store() -> закладка под ключом \"%@\", %d байт", url.path, bookmarkBytes)

        let accessURL = FolderAccess.beginAccess(url.path)
        NSLog("Mantel: --grant-test beginAccess() -> startAccessingSecurityScopedResource = %@",
              accessURL != nil ? "true" : "false")

        // Та же цепочка, что и кнопка «Разрешить…»: кладём реально выбранный путь в «слот»
        // Рабочего стола — didSet у desktopAccessPath перезапустит CaptureWatcher сам.
        AppSettings.shared.watchDesktop = true
        AppSettings.shared.desktopAccessPath = url.path

        let watched = AppSettings.shared.watchedFolders
        NSLog("Mantel: --grant-test watcher перезапущен, папок к слежению: %d (%@)",
              watched.count, watched.map { $0.path }.joined(separator: ", "))

        NSLog("Mantel: --grant-test ключ хранения = \"%@\", ключ запроса CaptureWatcher (resolvedDesktopPath) = \"%@\", совпадают: %@",
              url.path, AppSettings.shared.resolvedDesktopPath,
              url.path == AppSettings.shared.resolvedDesktopPath ? "true" : "false")

        let pending = FolderAccess.needsPermission
        NSLog("Mantel: --grant-test needsPermission = %@",
              pending.isEmpty ? "пусто (доступ выдан)" : pending.joined(separator: ", "))
    }
#endif

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "tray.full", accessibilityDescription: "Mantel")
            image?.isTemplate = true
            button.image = image
        }
        item.menu = buildMenu()
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let toggleItem = NSMenuItem(title: String(localized: "menu.showShelf"), action: #selector(toggleShelf), keyEquivalent: "s")
        toggleItem.keyEquivalentModifierMask = [.command, .option]
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        let openLibraryItem = NSMenuItem(title: String(localized: "action.openLibrary"), action: #selector(openLibrary), keyEquivalent: "")
        openLibraryItem.target = self
        menu.addItem(openLibraryItem)

        let openDriveItem = NSMenuItem(title: String(localized: "menu.openDriveFolder"), action: #selector(openDriveFolder), keyEquivalent: "")
        openDriveItem.target = self
        openDriveItem.isEnabled = GoogleDrive.isAvailable
        menu.addItem(openDriveItem)

        let clearItem = NSMenuItem(title: String(localized: "menu.clearShelf"), action: #selector(clearShelf), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: String(localized: "menu.settings"), action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: String(localized: "menu.quit"), action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    @objc private func toggleShelf() { ShelfController.shared.toggle() }
    @objc private func openLibrary() { NSWorkspace.shared.open(Library.root) }
    @objc private func openDriveFolder() { GoogleDrive.openFolder() }
    @objc private func clearShelf() { Library.shared.clear() }
    @objc private func openSettings() { SettingsWindowController.shared.show() }
    @objc private func quit() { NSApp.terminate(nil) }
}
