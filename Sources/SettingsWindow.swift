import SwiftUI
import AppKit

/// Окно настроек Mantel.
struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        Form {
#if APPSTORE
            // В песочнице Mantel не может сам взять ~/Desktop и ~/Screenshots — доступ
            // должен явно выдать пользователь через NSOpenPanel (см. FolderAccess).
            Section(String(localized: "settings.watching.title")) {
                trackedFolderRow(title: String(localized: "settings.watching.desktopLabel"), path: desktopPath, isOn: $settings.watchDesktop)
                trackedFolderRow(title: "~/Screenshots", path: screenshotsPath, isOn: $settings.watchScreenshotsFolder)
                Toggle(String(localized: "settings.watching.hotZone"), isOn: $settings.hotZoneEnabled)
            }
#else
            Section(String(localized: "settings.watching.title")) {
                Toggle(String(localized: "settings.watching.desktopToggle"), isOn: $settings.watchDesktop)
                Toggle(String(localized: "settings.watching.screenshotsToggle"), isOn: $settings.watchScreenshotsFolder)
                Toggle(String(localized: "settings.watching.hotZone"), isOn: $settings.hotZoneEnabled)
            }
#endif
            Section(String(localized: "settings.folders.title")) {
                Text(String(localized: "settings.folders.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if settings.mirrorFolders.isEmpty {
                    Text(String(localized: "settings.folders.empty"))
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
                Button(String(localized: "settings.folders.add")) { addMirrorFolder() }
                Toggle(String(localized: "settings.folders.moveToggle"), isOn: $settings.mirrorMovesFiles)
                Text(String(localized: "settings.folders.moveHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !settings.lastMirrorWarning.isEmpty {
                    Text(settings.lastMirrorWarning)
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }
            }
            Section(String(localized: "settings.shelf.title")) {
                Stepper(String(format: String(localized: "settings.shelf.widthStepper"), Int(settings.shelfWidth)),
                        value: $settings.shelfWidth, in: 480...1400, step: 40)
                Picker(String(localized: "settings.shelf.autoPrunePicker"), selection: $settings.autoPruneDays) {
                    Text(String(localized: "settings.shelf.prune.never")).tag(0)
                    Text(String(localized: "settings.shelf.prune.oneDay")).tag(1)
                    Text(String(localized: "settings.shelf.prune.threeDays")).tag(3)
                    Text(String(localized: "settings.shelf.prune.sevenDays")).tag(7)
                    Text(String(localized: "settings.shelf.prune.fourteenDays")).tag(14)
                    Text(String(localized: "settings.shelf.prune.thirtyDays")).tag(30)
                    Text(String(localized: "settings.shelf.prune.ninetyDays")).tag(90)
                }
                Text(autoPruneLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(String(localized: "settings.launch.title")) {
                Toggle(String(localized: "settings.launch.atLogin"), isOn: $settings.launchAtLogin)
            }
            Section(String(localized: "settings.drive.title")) {
                TextField(String(localized: "settings.drive.subfolderField"), text: $settings.googleDriveSubfolder)
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                    Text(destinationDisplayPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack {
                    Button(String(localized: "settings.drive.chooseFolder")) { chooseGoogleDriveDestination() }
                    Button(String(localized: "settings.drive.reset")) { settings.googleDriveDestination = "" }
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
                Button(String(localized: "action.openLibrary")) {
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
                Text(String(format: String(localized: "settings.watching.accessDenied"), title))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "settings.watching.grantButton")) { grantAccess(to: path) }
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
        panel.message = String(format: String(localized: "settings.watching.grantMessage"), (path as NSString).lastPathComponent)
        guard panel.runModal() == .OK, let url = panel.urls.first else { return }
        FolderAccess.store(url)
        // Закладка появилась — перезапускаем наблюдатель и обновляем это окно.
        NotificationCenter.default.post(name: .shelfSettingsChanged, object: nil)
        settings.objectWillChange.send()
    }
#endif

    private var autoPruneLabel: String {
        settings.autoPruneDays == 0
            ? String(localized: "settings.shelf.pruneLabel.off")
            : String(format: String(localized: "settings.shelf.pruneLabel.on"), settings.autoPruneDays)
    }

    private var driveStatus: String {
        if let root = GoogleDrive.driveRoot {
            return String(format: String(localized: "settings.drive.statusFound"), root.path, destinationDisplayPath)
        } else {
            return String(localized: "settings.drive.statusNotFound")
        }
    }

    /// Путь папки назначения, сокращённый через `~` — для строки под полем настроек.
    private var destinationDisplayPath: String {
        guard let dest = GoogleDrive.destinationURL else { return String(localized: "settings.drive.destinationUndetermined") }
        return (dest.path as NSString).abbreviatingWithTildeInPath
    }

    /// Предупреждение, если явно выбранная папка лежит вне корня Google Диска.
    private var destinationOutsideDriveWarning: String? {
        guard !settings.googleDriveDestination.isEmpty, let root = GoogleDrive.driveRoot else { return nil }
        let dest = (settings.googleDriveDestination as NSString).expandingTildeInPath
        guard !dest.hasPrefix(root.path) else { return nil }
        return String(localized: "settings.drive.outsideWarning")
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
        panel.prompt = String(localized: "settings.folders.addPrompt")
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
            w.title = String(localized: "settings.window.title")
            w.contentView = hosting
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
