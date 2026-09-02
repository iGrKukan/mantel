import SwiftUI
import AppKit

/// Окно настроек ShelfTop.
struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        Form {
#if APPSTORE
            // В песочнице ShelfTop не может сам взять ~/Desktop и ~/Screenshots — доступ
            // должен явно выдать пользователь через NSOpenPanel (см. FolderAccess).
            Section("Слежение") {
                trackedFolderRow(title: "Рабочий стол", path: desktopPath, isOn: $settings.watchDesktop)
                trackedFolderRow(title: "~/Screenshots", path: screenshotsPath, isOn: $settings.watchScreenshotsFolder)
                Toggle("Раскрывать по наведению", isOn: $settings.hotZoneEnabled)
            }
#else
            Section("Слежение") {
                Toggle("Следить за Рабочим столом", isOn: $settings.watchDesktop)
                Toggle("Следить за ~/Screenshots", isOn: $settings.watchScreenshotsFolder)
                Toggle("Раскрывать по наведению", isOn: $settings.hotZoneEnabled)
            }
#endif
            Section("Папки-источники") {
                Text("Из этих папок в полку попадает любой файл, а не только снимки экрана.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if settings.mirrorFolders.isEmpty {
                    Text("Папки не выбраны")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(settings.mirrorFolders, id: \.self) { path in
                        HStack {
                            Image(systemName: "folder")
                            Text((path as NSString).abbreviatingWithTildeInPath)
                            Spacer()
                            Button {
                                settings.removeMirrorFolder(path)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                Button("Добавить папку…") { addMirrorFolder() }
                Toggle("Забирать файлы из папки (не копировать)", isOn: $settings.mirrorMovesFiles)
                Text("Выключено — файл копируется, оригинал остаётся на месте. Включено — файл переносится в полку, как это делается со снимками экрана.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !settings.lastMirrorWarning.isEmpty {
                    Text(settings.lastMirrorWarning)
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }
            }
            Section("Полка") {
                Stepper("Ширина полки: \(Int(settings.shelfWidth)) px",
                        value: $settings.shelfWidth, in: 480...1400, step: 40)
                Picker("Удалять файлы старше", selection: $settings.autoPruneDays) {
                    Text("Никогда").tag(0)
                    Text("1 дня").tag(1)
                    Text("3 дней").tag(3)
                    Text("7 дней").tag(7)
                    Text("14 дней").tag(14)
                    Text("30 дней").tag(30)
                    Text("90 дней").tag(90)
                }
                Text(autoPruneLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Запуск") {
                Toggle("Запускать при входе", isOn: $settings.launchAtLogin)
            }
            Section("Google Диск") {
                TextField("Имя подпапки по умолчанию", text: $settings.googleDriveSubfolder)
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                    Text(destinationDisplayPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack {
                    Button("Выбрать папку…") { chooseGoogleDriveDestination() }
                    Button("Сбросить") { settings.googleDriveDestination = "" }
                        .disabled(settings.googleDriveDestination.isEmpty)
                }
                if let warning = destinationOutsideDriveWarning {
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }
                Text(driveStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Открыть папку библиотеки") {
                    NSWorkspace.shared.open(Library.root)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 700)
    }

#if APPSTORE
    private var desktopPath: String { ("~/Desktop" as NSString).expandingTildeInPath }
    private var screenshotsPath: String { ("~/Screenshots" as NSString).expandingTildeInPath }

    /// Строка «папка захвата» в режиме App Store: пока доступа нет — кнопка «Разрешить…»
    /// вместо переключателя (в песочнице сами эти папки взять нельзя).
    @ViewBuilder
    private func trackedFolderRow(title: String, path: String, isOn: Binding<Bool>) -> some View {
        if FolderAccess.resolvedURL(for: path) != nil {
            Toggle(title, isOn: isOn)
        } else {
            HStack {
                Text("\(title) — доступ не выдан")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Разрешить…") { grantAccess(to: path) }
            }
        }
    }

    private func grantAccess(to path: String) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: path)
        panel.message = "Выбери папку «\((path as NSString).lastPathComponent)», чтобы ShelfTop мог за ней следить."
        guard panel.runModal() == .OK, let url = panel.urls.first else { return }
        FolderAccess.store(url)
        // Закладка появилась — перезапускаем наблюдатель и обновляем это окно.
        NotificationCenter.default.post(name: .shelfSettingsChanged, object: nil)
        settings.objectWillChange.send()
    }
#endif

    private var autoPruneLabel: String {
        settings.autoPruneDays == 0
            ? "Автоочистка выключена — полка хранит файлы, пока не удалишь вручную."
            : "Файлы старше \(settings.autoPruneDays) дн. отправляются в Корзину. Проверка при запуске и раз в час."
    }

    private var driveStatus: String {
        if let root = GoogleDrive.driveRoot {
            return "Google Диск найден: \(root.path). Файлы попадают в «\(destinationDisplayPath)»."
        } else {
            return "Google Диск не найден"
        }
    }

    /// Путь папки назначения, сокращённый через `~` — для строки под полем настроек.
    private var destinationDisplayPath: String {
        guard let dest = GoogleDrive.destinationURL else { return "не определена" }
        return (dest.path as NSString).abbreviatingWithTildeInPath
    }

    /// Предупреждение, если явно выбранная папка лежит вне корня Google Диска.
    private var destinationOutsideDriveWarning: String? {
        guard !settings.googleDriveDestination.isEmpty, let root = GoogleDrive.driveRoot else { return nil }
        let dest = (settings.googleDriveDestination as NSString).expandingTildeInPath
        guard !dest.hasPrefix(root.path) else { return nil }
        return "Папка вне Google Диска — файлы не будут синхронизированы"
    }

    private func chooseGoogleDriveDestination() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if let root = GoogleDrive.driveRoot {
            panel.directoryURL = root
        }
        guard panel.runModal() == .OK, let url = panel.urls.first else { return }
        FolderAccess.store(url)
        settings.googleDriveDestination = url.path
    }

    private func addMirrorFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Добавить"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            FolderAccess.store(url)
            settings.addMirrorFolder(url.path)
        }
    }
}

/// Одно окно настроек на всё приложение.
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    private init() {}

    func show() {
        if window == nil {
            let hosting = NSHostingView(rootView: SettingsView())
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 700),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false)
            w.title = "Настройки ShelfTop"
            w.contentView = hosting
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
