import SwiftUI
import AppKit
import Quartz
import UniformTypeIdentifiers

// MARK: - Содержимое полки

struct ShelfView: View {
    @ObservedObject var library = Library.shared
    @ObservedObject private var audio = AudioPlayerModel.shared
    @ObservedObject private var nowPlaying = NowPlayingModel.shared

    @State private var selection: Set<UUID> = []
    /// Версия миниатюры по id — растёт при .shelfThumbnailReady, заставляя карточку перерисоваться.
    @State private var thumbVersions: [UUID: Int] = [:]
    @State private var dropTargeted = false
    /// Когда в последний раз звучал звук — чтобы плеер не исчезал мгновенно на паузе.
    @State private var lastPlayingAt: Date?
    /// Тик раз в 5 с, чтобы вью пересчитала видимость плеера после паузы.
    @State private var visibilityTick = 0

    /// Индекс карточки, к которой сейчас "прибита" лента — двигается стрелками ‹ ›,
    /// используется и для позиции самодельной полосы прокрутки.
    @State private var anchorIndex: Int = 0
    @State private var shelfHovering = false
    /// Наведение на всю развёрнутую полку (включая её кромки) — показывает еле заметную
    /// «ручку» изменения размера у нижнего края.
    @State private var shelfBodyHovering = false

    @State private var uploadState: UploadState = .idle
    @State private var uploadError: String = ""
    @State private var uploadedCount: Int = 0
    @State private var uploadDestinationName: String = ""
    @State private var showUploadToast = false

    enum UploadState: Equatable { case idle, uploading, done, failed }

    private let cornerRadius: CGFloat = 26
    private let accent = Color(red: 0.65, green: 0.55, blue: 0.98)

    var body: some View {
        GeometryReader { geo in
            Group {
                if geo.size.height < 40 {
                    pill
                } else {
                    expandedBody
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            visibilityTick &+= 1
        }
        .onChange(of: nowPlaying.isPlaying) { playing in
            if playing { lastPlayingAt = Date() }
        }
        .onChange(of: audio.isPlaying) { playing in
            if playing { lastPlayingAt = Date() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .shelfThumbnailReady)) { note in
            guard let id = note.object as? UUID else { return }
            thumbVersions[id, default: 0] += 1
        }
        .onAppear { NowPlayingModel.shared.start() }
    }

    // MARK: свёрнутое состояние — тонкая пилюля

    private var pill: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.28))
                .frame(width: 110, height: 4)
                .padding(.top, 1)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: развёрнутое состояние

    private var expandedBody: some View {
        ZStack(alignment: .bottom) {
            HStack(spacing: 0) {
                if showPlayer {
                    playerColumn
                    divider
                }
                content
                divider
                actionColumn.frame(width: 48)
            }

            if showUploadToast {
                uploadToast
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(red: 0.085, green: 0.085, blue: 0.095))
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(dropTargeted ? accent : Color.white.opacity(0.08), lineWidth: dropTargeted ? 2 : 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 18, y: 6)
        .padding(.horizontal, 8)
        .padding(.bottom, 10)
        // Зоны захвата кромок — в прозрачном поле вокруг видимой карточки, поэтому не
        // перекрывают ни кнопки, ни ленту карточек, ни колесо мыши; ловят только мышь
        // у самого края панели (см. ShelfResizeCatcher ниже).
        .overlay(alignment: .leading) {
            ShelfResizeCatcher(edge: .left)
                .frame(width: 8)
                .frame(maxHeight: .infinity)
        }
        .overlay(alignment: .trailing) {
            ShelfResizeCatcher(edge: .right)
                .frame(width: 8)
                .frame(maxHeight: .infinity)
        }
        .overlay(alignment: .bottom) {
            ZStack {
                ShelfResizeCatcher(edge: .bottom)
                    .frame(maxWidth: .infinity)
                    .frame(height: 8)
                Capsule()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 44, height: 3)
                    .opacity(shelfBodyHovering ? 1 : 0)
                    .animation(.easeInOut(duration: 0.15), value: shelfBodyHovering)
                    .allowsHitTesting(false)
            }
        }
        .onHover { shelfBodyHovering = $0 }
        .contentShape(Rectangle())
        .onTapGesture { selection.removeAll() }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: handleDrop)
        .animation(.easeInOut(duration: 0.15), value: showUploadToast)
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
    }

    // MARK: карточки

    /// Ширина одной карточки с отступом — шаг ленты для навигации стрелками/колесом.
    private let cardStride: CGFloat = 112 + 10

    private var content: some View {
        Group {
            if library.items.isEmpty {
                emptyState
            } else {
                GeometryReader { geo in
                    let visibleCount = max(1, Int(geo.size.width / cardStride))
                    let totalCount = library.items.count
                    let overflow = totalCount > visibleCount

                    ScrollViewReader { proxy in
                        ZStack(alignment: .bottom) {
                            ScrollView(.horizontal, showsIndicators: true) {
                                LazyHStack(spacing: 10) {
                                    ForEach(library.items) { item in
                                        ShelfCardView(
                                            item: item,
                                            isSelected: selection.contains(item.id),
                                            thumbVersion: thumbVersions[item.id] ?? 0,
                                            onSelect: { isCommand in
                                                if isCommand {
                                                    if selection.contains(item.id) { selection.remove(item.id) }
                                                    else { selection.insert(item.id) }
                                                } else {
                                                    selection = [item.id]
                                                }
                                            },
                                            selectedURLsProvider: { selectedURLs(including: item) },
                                            onReveal: { for i in targetItems(including: item) { library.reveal(i) } },
                                            onUpload: { uploadSelected(targetItems(including: item)) },
                                            onDelete: {
                                                let victims = targetItems(including: item)
                                                for v in victims { library.remove(v) }
                                                selection.subtract(Set(victims.map { $0.id }))
                                            },
                                            onClearAll: { confirmClearAll() }
                                        )
                                        .id(item.id)
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                            }
                            // Переводит вертикальное колесо мыши в горизонтальную прокрутку —
                            // без этого лента не крутится обычной (не трекпад) мышью. Оверлей
                            // ПОВЕРХ ленты (не .background) — иначе NSScrollView перехватывает
                            // scrollWheel раньше нас; для остальных событий (клик/драг карточки)
                            // подложка прозрачна (см. hitTest в WheelCatcherView).
                            .overlay(WheelToHorizontal())

                            if overflow {
                                scrollTrack(visibleCount: visibleCount, totalCount: totalCount)
                                    .padding(.horizontal, 14)
                                    .padding(.bottom, 3)
                            }
                        }
                        .overlay(alignment: .leading) {
                            if overflow, shelfHovering, anchorIndex > 0 {
                                navArrow(system: "chevron.left") {
                                    jump(by: -visibleCount, visibleCount: visibleCount, totalCount: totalCount, proxy: proxy)
                                }
                                .padding(.leading, 6)
                            }
                        }
                        .overlay(alignment: .trailing) {
                            if overflow, shelfHovering, anchorIndex < totalCount - visibleCount {
                                navArrow(system: "chevron.right") {
                                    jump(by: visibleCount, visibleCount: visibleCount, totalCount: totalCount, proxy: proxy)
                                }
                                .padding(.trailing, 6)
                            }
                        }
                        .onHover { shelfHovering = $0 }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Сдвигает "прибитый" индекс на `delta` карточек и едет к нему.
    private func jump(by delta: Int, visibleCount: Int, totalCount: Int, proxy: ScrollViewProxy) {
        let newIndex = min(max(anchorIndex + delta, 0), max(0, totalCount - 1))
        anchorIndex = newIndex
        withAnimation(.easeOut(duration: 0.25)) {
            proxy.scrollTo(library.items[newIndex].id, anchor: .leading)
        }
    }

    private func navArrow(system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.black.opacity(0.55)))
        }
        .buttonStyle(.plain)
        .transition(.opacity)
    }

    /// Самодельная полоса прокрутки: ширина — доля видимых карточек, положение — от anchorIndex.
    private func scrollTrack(visibleCount: Int, totalCount: Int) -> some View {
        GeometryReader { geo in
            let trackWidth = geo.size.width
            let widthFraction = min(1, CGFloat(visibleCount) / CGFloat(max(totalCount, 1)))
            let thumbWidth = max(24, trackWidth * widthFraction)
            let maxOffset = max(0, trackWidth - thumbWidth)
            let positionFraction = totalCount > visibleCount
                ? CGFloat(anchorIndex) / CGFloat(totalCount - visibleCount)
                : 0
            Capsule()
                .fill(Color.white.opacity(0.22))
                .frame(width: thumbWidth, height: 3)
                .offset(x: maxOffset * min(max(positionFraction, 0), 1))
        }
        .frame(height: 3)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.25))
            Text(String(localized: "shelf.empty.hint"))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.35))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: правый столбик действий

    private var actionColumn: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 4)
            // Счётчик файлов полки — клик открывает саму папку полки в Finder, чтобы
            // до старых, уже проскроллившихся файлов всегда можно было добраться.
            Text("\(library.items.count)")
                .font(.system(size: 9, design: .rounded))
                .foregroundStyle(.white.opacity(0.4))
                .help(String(localized: "shelf.help.fileCount"))
                .onTapGesture { NSWorkspace.shared.open(Library.root) }
            HoverIconButton(system: "folder", help: String(localized: "action.showInFinder")) {
                for i in toolbarTargets { library.reveal(i) }
            }
            GoogleDriveButton(state: uploadState,
                              errorMessage: uploadError,
                              disabled: !GoogleDrive.isAvailable,
                              action: { uploadSelected(toolbarTargets) },
                              onDropURLs: { uploadURLs($0) },
                              onDropURLsTo: { urls, folder in uploadURLs(urls, to: folder) })
            HoverIconButton(system: "gearshape", help: String(localized: "shelf.help.settings")) {
                SettingsWindowController.shared.show()
            }
            HoverIconButton(system: "doc.on.doc", help: String(localized: "shelf.help.copyFile")) {
                copyToPasteboard(toolbarTargets)
            }
            HoverIconButton(system: "trash", help: String(localized: "action.delete")) {
                let victims = toolbarTargets
                for v in victims { library.remove(v) }
                selection.subtract(Set(victims.map { $0.id }))
            }
            HoverIconButton(system: "xmark.bin", help: String(localized: "action.clearAll")) {
                confirmClearAll()
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 8)
    }

    /// «Очистить всё» — необратимо на вид, поэтому спрашиваем. Файлы уходят в Корзину.
    private func confirmClearAll() {
        guard !library.items.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "alert.clearAll.title")
        alert.informativeText = String(format: String(localized: "alert.clearAll.message"), library.items.count)
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "alert.clearAll.confirmButton"))
        alert.addButton(withTitle: String(localized: "alert.clearAll.cancelButton"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            library.clear()
            selection.removeAll()
        }
    }

    // MARK: тост «выгружено на Google Диск»

    private var uploadToast: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color(red: 0.30, green: 0.78, blue: 0.45))
            Text(String(format: String(localized: "toast.uploaded.message"), uploadDestinationName, uploadedCount))
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(String(localized: "shelf.toast.openButton")) { GoogleDrive.openFolder() }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(accent)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.07)))
    }

    // MARK: мини-плеер — системное «сейчас играет» либо локальный аудиофайл полки

    private var currentAudioItem: ShelfItem? {
        library.items.first { $0.id == audio.currentItemID }
    }

    /// Что показывать в плеере: играющий трек, иначе первый аудиофайл полки.
    private var playerTrack: ShelfItem? {
        currentAudioItem ?? library.items.first { AudioPlayerModel.isAudio($0) }
    }

    /// Приоритет источника: системное «сейчас играет» (Spotify/Apple Music/браузер) —
    /// если оно недоступно, локальный аудиоплеер полки — если и его нет, колонки не будет.
    private var systemPlayerActive: Bool { nowPlaying.isAvailable }

    /// Плеер показываем только когда музыка реально звучит. После паузы держим
    /// колонку ещё минуту, чтобы можно было нажать «продолжить», потом убираем.
    private var isSoundActive: Bool {
        if nowPlaying.isAvailable && nowPlaying.isPlaying { return true }
        if audio.currentItemID != nil && audio.isPlaying { return true }
        if let last = lastPlayingAt, Date().timeIntervalSince(last) < 60 { return true }
        return false
    }

    private var showPlayer: Bool { isSoundActive }

    private var playerColumn: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                artwork
                VStack(alignment: .leading, spacing: 2) {
                    Text(playerTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(playerSubtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if systemPlayerActive, !nowPlaying.appName.isEmpty {
                        Text(nowPlaying.appName)
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.35))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                EqualizerView(isPlaying: systemPlayerActive ? nowPlaying.isPlaying : audio.isPlaying)
            }

            progressRow

            Spacer(minLength: 0)

            transportRow
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 300)
    }

    private var playerTitle: String {
        if systemPlayerActive { return nowPlaying.title }
        if currentAudioItem != nil, !audio.trackTitle.isEmpty { return audio.trackTitle }
        let name = playerTrack?.displayName ?? ""
        return (name as NSString).deletingPathExtension
    }

    private var playerSubtitle: String {
        if systemPlayerActive {
            return nowPlaying.artist.isEmpty ? timeShort(nowPlaying.duration) : nowPlaying.artist
        }
        if currentAudioItem == nil { return String(localized: "shelf.player.pressPlayHint") }
        return audio.trackArtist.isEmpty ? timeShort(audio.duration) : audio.trackArtist
    }

    private var playerArtworkImage: NSImage? {
        systemPlayerActive ? nowPlaying.artwork : audio.artwork
    }

    private var artwork: some View {
        ZStack {
            if let image = playerArtworkImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(
                    colors: [Color(red: 0.35, green: 0.30, blue: 0.55), Color(red: 0.18, green: 0.16, blue: 0.30)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note")
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var playerElapsed: Double { systemPlayerActive ? nowPlaying.elapsed : audio.currentTime }
    private var playerDuration: Double { systemPlayerActive ? nowPlaying.duration : audio.duration }

    private var progressRow: some View {
        HStack(spacing: 6) {
            Text(timeShort(playerElapsed))
                .font(.system(size: 10, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 34, alignment: .leading)

            ProgressBarView(progress: progressFraction) { fraction in
                if systemPlayerActive {
                    NowPlayingModel.shared.seek(fraction: fraction)
                } else {
                    AudioPlayerModel.shared.seek(fraction: fraction)
                }
            }

            Text("-" + timeShort(max(0, playerDuration - playerElapsed)))
                .font(.system(size: 10, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 34, alignment: .trailing)
        }
    }

    private var progressFraction: Double {
        playerDuration > 0 ? min(max(playerElapsed / playerDuration, 0), 1) : 0
    }

    private var transportRow: some View {
        HStack(spacing: 22) {
            Spacer(minLength: 0)
            Button {
                if systemPlayerActive { NowPlayingModel.shared.previous() }
                else { AudioPlayerModel.shared.previous() }
            } label: {
                Image(systemName: "backward.fill").font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)

            Button {
                if systemPlayerActive { NowPlayingModel.shared.togglePlayPause() }
                else if let item = currentAudioItem { AudioPlayerModel.shared.toggle(item) }
            } label: {
                Image(systemName: (systemPlayerActive ? nowPlaying.isPlaying : audio.isPlaying) ? "pause.fill" : "play.fill")
                    .font(.system(size: 22))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)

            Button {
                if systemPlayerActive { NowPlayingModel.shared.next() }
                else { AudioPlayerModel.shared.next() }
            } label: {
                Image(systemName: "forward.fill").font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            Spacer(minLength: 0)

            // «Стоп» есть только у локального аудиоплеера полки — у системного плеера
            // (Spotify и т.п.) осмысленной команды остановки нет, кнопку просто не показываем.
            if !systemPlayerActive {
            Button { AudioPlayerModel.shared.stop() } label: {
                Image(systemName: "stop.fill").font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    // MARK: приём файлов извне (drop внутрь полки)

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            handled = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                var url: URL?
                if let u = data as? URL { url = u }
                else if let d = data as? Data { url = URL(dataRepresentation: d, relativeTo: nil) }
                guard let fileURL = url else { return }
                DispatchQueue.main.async {
                    library.ingest(fileURL, kind: kindFor(fileURL), move: false)
                }
            }
        }
        return handled
    }

    private func kindFor(_ url: URL) -> ShelfItem.Kind {
        let ext = url.pathExtension.lowercased()
        let audioExts: Set<String> = ["mp3", "wav", "m4a", "aac", "flac", "aiff", "aif"]
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "tiff", "bmp", "webp"]
        if audioExts.contains(ext) { return .audio }
        if imageExts.contains(ext) { return .image }
        return .file
    }

    // MARK: выделение

    /// Элементы-цели действия: если item входит в текущее выделение — всё выделение, иначе только он.
    private func targetItems(including item: ShelfItem) -> [ShelfItem] {
        let ids = selection.contains(item.id) ? selection : [item.id]
        return library.items.filter { ids.contains($0.id) }
    }

    private func selectedURLs(including item: ShelfItem) -> [URL] {
        targetItems(including: item).map { $0.url }
    }

    private var toolbarTargets: [ShelfItem] {
        if !selection.isEmpty { return library.items.filter { selection.contains($0.id) } }
        if let first = library.items.first { return [first] }
        return []
    }

    // MARK: Google Диск

    /// Кладём сами файлы в буфер обмена: так их принимают AnyDesk (кнопка «файл»
    /// в окне сеанса) и обычная вставка в Finder.
    private func copyToPasteboard(_ items: [ShelfItem]) {
        guard !items.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(items.map { $0.url as NSURL })
    }

    /// Перетащили файлы прямо на иконку Диска — копируем их туда как есть.
    /// `to` — конкретная подпапка, выбранная в панели «Куда положить»; nil — папка по умолчанию.
    private func uploadURLs(_ urls: [URL], to destination: URL? = nil) {
        guard !urls.isEmpty else { return }
        uploadState = .uploading
        uploadDestinationName = (destination ?? GoogleDrive.destinationURL)?.lastPathComponent ?? ""
        if let destination {
            GoogleDrive.upload(urls: urls, to: destination) { result in
                DispatchQueue.main.async { finishUpload(result) }
            }
        } else {
            GoogleDrive.upload(urls: urls) { result in
                DispatchQueue.main.async { finishUpload(result) }
            }
        }
    }

    private func finishUpload(_ result: Result<Int, Error>) {
        switch result {
        case .success(let count):
            uploadState = .done
            uploadedCount = count
            showUploadToast = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if uploadState == .done { uploadState = .idle }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { showUploadToast = false }
        case .failure(let error):
            uploadError = error.localizedDescription
            uploadState = .failed
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if uploadState == .failed { uploadState = .idle }
            }
        }
    }

    private func uploadSelected(_ items: [ShelfItem]) {
        guard !items.isEmpty else { return }
        uploadState = .uploading
        uploadDestinationName = GoogleDrive.destinationURL?.lastPathComponent ?? ""
        GoogleDrive.upload(items) { result in
            DispatchQueue.main.async { finishUpload(result) }
        }
    }

    private func timeShort(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Эквалайзер мини-плеера

private struct EqualizerView: View {
    let isPlaying: Bool

    private let barCount = 5
    private let color = Color(red: 0.65, green: 0.55, blue: 0.98)

    var body: some View {
        Group {
            if isPlaying {
                TimelineView(.periodic(from: .now, by: 0.12)) { context in
                    bars(date: context.date)
                }
            } else {
                bars(date: nil)
            }
        }
        .frame(height: 16, alignment: .bottom)
    }

    private func bars(date: Date?) -> some View {
        HStack(alignment: .bottom, spacing: 2.5) {
            ForEach(0..<barCount, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: 2.5, height: barHeight(index: i, date: date))
            }
        }
    }

    private func barHeight(index: Int, date: Date?) -> CGFloat {
        guard let date else { return 3 }
        let t = date.timeIntervalSinceReferenceDate
        let phase = Double(index) * 1.3
        let speed = 3.2 + Double(index) * 0.4
        let wave = (sin(t * speed + phase) + 1) / 2
        return 4 + CGFloat(wave) * 12
    }
}

// MARK: - Интерактивная полоса прогресса

private struct ProgressBarView: View {
    let progress: Double
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.15))
                Capsule()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: max(0, geo.size.width * progress))
            }
            .frame(height: 4)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard geo.size.width > 0 else { return }
                        onSeek(min(max(value.location.x / geo.size.width, 0), 1))
                    }
            )
        }
        .frame(height: 4)
    }
}

// MARK: - Круглая кнопка-иконка столбика действий

private struct HoverIconButton: View {
    let system: String
    let help: String
    var disabled: Bool = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 13))
                .foregroundStyle(disabled ? Color.white.opacity(0.25) : (hovering ? Color.white : Color.white.opacity(0.6)))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
        .onHover { hovering = $0 }
    }
}

// MARK: - Кнопка выгрузки на Google Диск (в стиле Droppy)

/// Трёхцветный треугольник Google Диска.
private struct DriveLogo: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let T = CGPoint(x: 0.50 * w, y: 0.06 * h)
            let L = CGPoint(x: 0.05 * w, y: 0.86 * h)
            let R = CGPoint(x: 0.95 * w, y: 0.86 * h)
            let mTL = CGPoint(x: (T.x + L.x) / 2, y: (T.y + L.y) / 2)
            let mTR = CGPoint(x: (T.x + R.x) / 2, y: (T.y + R.y) / 2)
            let mLR = CGPoint(x: (L.x + R.x) / 2, y: (L.y + R.y) / 2)
            let C = CGPoint(x: (T.x + L.x + R.x) / 3, y: (T.y + L.y + R.y) / 3)
            ZStack {
                poly([T, mTR, C, mTL]).fill(Color(red: 0.98, green: 0.74, blue: 0.02))   // жёлтый
                poly([mTR, R, mLR, C]).fill(Color(red: 0.20, green: 0.66, blue: 0.33))   // зелёный
                poly([mTL, C, mLR, L]).fill(Color(red: 0.26, green: 0.52, blue: 0.96))   // синий
            }
        }
    }

    private func poly(_ pts: [CGPoint]) -> Path {
        var p = Path()
        p.move(to: pts[0])
        for pt in pts.dropFirst() { p.addLine(to: pt) }
        p.closeSubpath()
        return p
    }
}

private struct GoogleDriveButton: View {
    let state: ShelfView.UploadState
    let errorMessage: String
    let disabled: Bool
    let action: () -> Void
    var onDropURLs: ([URL]) -> Void = { _ in }
    /// Дроп на конкретную подпапку в панели «Куда положить» — (файлы, папка).
    var onDropURLsTo: ([URL], URL) -> Void = { _, _ in }

    @State private var hovering = false
    @State private var spinning = false
    @State private var dropTargeted = false
    /// Когда в последний раз звучал звук — чтобы плеер не исчезал мгновенно на паузе.
    @State private var lastPlayingAt: Date?
    /// Тик раз в 5 с, чтобы вью пересчитала видимость плеера после паузы.
    @State private var visibilityTick = 0
    /// Держит панель «Куда положить» открытой, пока перетаскивание над ней (в т.ч. между строк).
    @State private var panelTargeted = false
    @State private var subfolders: [URL] = []

    private let accent = Color(red: 0.65, green: 0.55, blue: 0.98)

    /// Показываем панель, пока перетаскивание над иконкой или над самой панелью.
    private var showPanel: Bool { dropTargeted || panelTargeted }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: action) {
                ZStack {
                    Circle()
                        .fill(dropTargeted ? accent.opacity(0.35)
                              : (hovering && state == .idle ? accent.opacity(0.22) : Color.white.opacity(0.08)))
                        .frame(width: 30, height: 30)
                    Circle()
                        .strokeBorder(dropTargeted ? accent : Color.clear, lineWidth: 2)
                        .frame(width: 30, height: 30)
                    content
                }
            }
            .buttonStyle(.plain)
            .disabled(disabled || state == .uploading)
            .help(helpText)
            .onHover { hovering = $0 }
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                guard !disabled else { return false }
                loadDroppedURLs(providers) { onDropURLs($0) }
                return true
            }

            if showPanel, !disabled {
                destinationPanel
                    .offset(x: -44, y: 6)
                    .transition(.opacity)
                    .onAppear { subfolders = GoogleDrive.subfolders() }
            }
        }
        .animation(.easeInOut(duration: 0.15), value: showPanel)
    }

    /// Панель «Куда положить» — показывается под иконкой, пока файл тащат над ней.
    /// Верхняя строка — папка по умолчанию, ниже — подпапки первого уровня; каждая
    /// строка сама по себе цель дропа (бросил на строку → файл ушёл именно туда).
    private var destinationPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "shelf.drive.whereToPut"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)

            if !GoogleDrive.isAvailable {
                Text(String(localized: "shelf.drive.notConnected"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.5))
            } else {
                DestinationRow(
                    icon: "folder.fill",
                    name: GoogleDrive.destinationURL?.lastPathComponent ?? "Mantel",
                    subtitle: GoogleDrive.destinationURL.map { ($0.path as NSString).abbreviatingWithTildeInPath },
                    onDropURLs: { onDropURLs($0) }
                )
                if !subfolders.isEmpty {
                    Divider().background(Color.white.opacity(0.1))
                    ForEach(subfolders, id: \.self) { folder in
                        DestinationRow(icon: "folder", name: folder.lastPathComponent, subtitle: nil,
                                       onDropURLs: { onDropURLsTo($0, folder) })
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 230, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(red: 0.12, green: 0.12, blue: 0.13)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
        .onDrop(of: [.fileURL], isTargeted: $panelTargeted) { providers in
            loadDroppedURLs(providers) { onDropURLs($0) }
            return true
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle:
            DriveLogo()
                .frame(width: 16, height: 16)
                .opacity(disabled ? 0.3 : 1)
        case .uploading:
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(accent, lineWidth: 2)
                .frame(width: 14, height: 14)
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .onAppear {
                    spinning = false
                    withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                        spinning = true
                    }
                }
        case .done:
            Circle()
                .fill(Color(red: 0.30, green: 0.78, blue: 0.45))
                .frame(width: 26, height: 26)
                .overlay(
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                )
        case .failed:
            Circle()
                .fill(Color.red)
                .frame(width: 26, height: 26)
                .overlay(
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                )
        }
    }

    private var helpText: String {
        switch state {
        case .failed: return errorMessage
        case .idle: return disabled ? String(localized: "shelf.drive.notInstalled") : String(format: String(localized: "shelf.drive.uploadHelp"), destinationName)
        case .uploading, .done: return String(format: String(localized: "shelf.drive.uploadHelp"), destinationName)
        }
    }

    private var destinationName: String {
        GoogleDrive.destinationURL?.lastPathComponent ?? String(localized: "shelf.drive.fallbackFolderName")
    }
}

/// Одна строка панели «Куда положить» — самостоятельная цель дропа: имя папки
/// (и путь мельче серым для папки по умолчанию), подсветка фиолетовым при наведении файла.
private struct DestinationRow: View {
    let icon: String
    let name: String
    let subtitle: String?
    let onDropURLs: ([URL]) -> Void

    @State private var targeted = false
    private let accent = Color(red: 0.65, green: 0.55, blue: 0.98)

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.7))
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(targeted ? accent.opacity(0.25) : Color.clear))
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            loadDroppedURLs(providers) { onDropURLs($0) }
            return true
        }
    }
}

/// Разбор перетащенных файлов из NSItemProvider — общий для иконки Диска и строк
/// панели «Куда положить».
private func loadDroppedURLs(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
    var urls: [URL] = []
    let group = DispatchGroup()
    for p in providers {
        group.enter()
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            if let url { urls.append(url) }
            group.leave()
        }
    }
    group.notify(queue: .main) { completion(urls) }
}

// MARK: - Карточка элемента

private struct ShelfCardView: View {
    let item: ShelfItem
    let isSelected: Bool
    let thumbVersion: Int
    let onSelect: (Bool) -> Void
    let selectedURLsProvider: () -> [URL]
    let onReveal: () -> Void
    let onUpload: () -> Void
    let onDelete: () -> Void
    let onClearAll: () -> Void

    @ObservedObject private var audio = AudioPlayerModel.shared
    @State private var isHovering = false

    private let size: CGFloat = 112
    private let cornerRadius: CGFloat = 14

    var body: some View {
        ZStack(alignment: .topLeading) {
            thumbnail.id(thumbVersion)

            // AppKit-слой снизу: клик/двойной клик/multi-drag. SwiftUI-контент рисуется
            // поверх и не мешает hit-тестингу самой карточки, но интерактивные кнопки
            // объявлены ПОСЛЕ него, чтобы получать клики первыми.
            DragCatcher(item: item, selectedURLsProvider: selectedURLsProvider, onClick: onSelect)

            bottomLabel
            badge

            if AudioPlayerModel.isAudio(item) && isHovering {
                audioOverlay
            }

            if isHovering {
                hoverControls
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(isSelected ? 0.9 : 0), lineWidth: 2)
        )
        .scaleEffect(isSelected ? 1.02 : 1.0)
        .animation(.spring(response: 0.25), value: isSelected)
        .contextMenu {
            Button(String(localized: "action.showInFinder"), action: onReveal)
            Button(String(localized: "shelf.context.copyFile")) {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects([item.url as NSURL])
            }
            Button(String(localized: "shelf.context.copyPath")) {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(item.url.path, forType: .string)
            }
            if GoogleDrive.isAvailable {
                Button(action: onUpload) {
                    Label(String(localized: "shelf.context.uploadToDrive"), systemImage: "icloud.and.arrow.up")
                }
            }
            Divider()
            Button(String(localized: "action.delete"), role: .destructive, action: onDelete)
            Button(String(localized: "action.clearAll"), role: .destructive, action: onClearAll)
        }
        .onHover { isHovering = $0 }
    }

    private var thumbnail: some View {
        Group {
            if let img = NSImage(contentsOf: item.thumbnailURL) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.06)
                    Image(systemName: symbolName)
                        .font(.system(size: 26))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .allowsHitTesting(false)
    }

    private var bottomLabel: some View {
        VStack {
            Spacer()
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                    .frame(height: size * 0.55)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.displayName)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(timeString(item.addedAt))
                        .font(.system(size: 8.5))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 5)
            }
        }
        .allowsHitTesting(false)
    }

    private var badgeSymbol: String {
        switch item.kind {
        case .screenshot: return "camera.fill"
        case .screenRecording: return "video.fill"
        case .audio: return "music.note"
        case .image: return "photo.fill"
        case .file: return "doc.fill"
        }
    }

    private var badge: some View {
        Image(systemName: badgeSymbol)
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundStyle(.white.opacity(0.9))
            .frame(width: 16, height: 16)
            .background(Circle().fill(Color.black.opacity(0.55)))
            .padding(4)
            .allowsHitTesting(false)
    }

    private var audioOverlay: some View {
        ZStack {
            Color.black.opacity(0.35)
            Button { AudioPlayerModel.shared.toggle(item) } label: {
                Image(systemName: (audio.currentItemID == item.id && audio.isPlaying) ? "pause.fill" : "play.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .transition(.opacity)
    }

    private var hoverControls: some View {
        VStack {
            HStack(spacing: 6) {
                Spacer()
                hoverButton(system: "eye") { QuickLookHelper.shared.preview(urls: [item.url]) }
                hoverButton(system: "trash") { onDelete() }
            }
            .padding(6)
            Spacer()
        }
        .transition(.opacity)
    }

    private func hoverButton(system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 10))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.black.opacity(0.5)))
        }
        .buttonStyle(.plain)
    }

    private var symbolName: String {
        switch item.kind {
        case .image, .screenshot: return "photo"
        case .screenRecording: return "video.fill"
        case .audio: return "music.note"
        case .file: return "doc.fill"
        }
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}

// MARK: - AppKit-слой карточки: клик, двойной клик, multi-drag наружу

/// Прозрачный NSView поверх карточки. SwiftUI `.onDrag` умеет отдавать только один
/// провайдер, а для множественного выделения нужен полноценный NSDraggingSession —
/// поэтому клик/драг обрабатываются здесь, в AppKit.
private struct DragCatcher: NSViewRepresentable {
    let item: ShelfItem
    let selectedURLsProvider: () -> [URL]
    let onClick: (Bool) -> Void

    func makeNSView(context: Context) -> DragCatcherView {
        let view = DragCatcherView()
        view.item = item
        view.selectedURLsProvider = selectedURLsProvider
        view.onClick = onClick
        return view
    }

    func updateNSView(_ nsView: DragCatcherView, context: Context) {
        nsView.item = item
        nsView.selectedURLsProvider = selectedURLsProvider
        nsView.onClick = onClick
    }
}

private final class DragCatcherView: NSView, NSDraggingSource {
    var item: ShelfItem!
    var selectedURLsProvider: (() -> [URL])?
    var onClick: ((Bool) -> Void)?
    private var mouseDownPoint: NSPoint = .zero

    // Иначе первый клик по неактивной панели проглатывается системой.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        if event.clickCount == 2 {
            NSWorkspace.shared.open(item.url)
            return
        }
        onClick?(event.modifierFlags.contains(.command))
    }

    override func mouseDragged(with event: NSEvent) {
        let point = event.locationInWindow
        let dx = point.x - mouseDownPoint.x
        let dy = point.y - mouseDownPoint.y
        guard (dx * dx + dy * dy).squareRoot() > 4 else { return }

        let urls = selectedURLsProvider?() ?? [item.url]
        guard !urls.isEmpty else { return }

        ShelfController.shared.isDragging = true

        let localPoint = convert(mouseDownPoint, from: nil)
        let size = NSSize(width: 96, height: 96)
        let origin = NSPoint(x: localPoint.x - size.width / 2, y: localPoint.y - size.height / 2)

        let draggingItems: [NSDraggingItem] = urls.map { url in
            let dragItem = NSDraggingItem(pasteboardWriter: url as NSURL)
            let thumb = Library.shared.items.first(where: { $0.url == url })
                .flatMap { NSImage(contentsOf: $0.thumbnailURL) } ?? NSWorkspace.shared.icon(forFile: url.path)
            dragItem.setDraggingFrame(NSRect(origin: origin, size: size), contents: thumb)
            return dragItem
        }
        beginDraggingSession(with: draggingItems, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [] : .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        ShelfController.shared.isDragging = false
    }
}

// MARK: - Колесо мыши → горизонтальная прокрутка ленты

/// На обычной мыши (не трекпад) вертикальное колесо не крутит горизонтальный ScrollView —
/// это чинит только жест трекпада. Подложка перехватывает именно scrollWheel и двигает
/// NSScrollView напрямую; для любых других событий (клик, драг карточки) она прозрачна —
/// hitTest пропускает их дальше, к обычным карточкам под собой.
private struct WheelToHorizontal: NSViewRepresentable {
    func makeNSView(context: Context) -> WheelCatcherView { WheelCatcherView() }
    func updateNSView(_ nsView: WheelCatcherView, context: Context) {}
}

private final class WheelCatcherView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard NSApp.currentEvent?.type == .scrollWheel else { return nil }
        return super.hitTest(point)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let scrollView = Self.findScrollView(in: superview) else {
            super.scrollWheel(with: event)
            return
        }
        let delta = abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) ? event.scrollingDeltaY : event.scrollingDeltaX
        guard let doc = scrollView.documentView else { return }
        let clip = scrollView.contentView
        var origin = clip.bounds.origin
        origin.x = min(max(0, origin.x - delta), max(0, doc.frame.width - clip.bounds.width))
        clip.setBoundsOrigin(origin)
        scrollView.reflectScrolledClipView(clip)
    }

    private static func findScrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        for sub in view.subviews {
            if let sv = sub as? NSScrollView { return sv }
            if let found = findScrollView(in: sub) { return found }
        }
        return nil
    }
}

// MARK: - Перетаскивание краёв (изменение размера полки)

/// Какой край панели тянет зона захвата.
private enum ShelfResizeEdge {
    case left, right, bottom
}

/// Невидимая полоска у кромки полки — перетаскивание меняет ширину/высоту.
/// Ширина всегда растёт/уменьшается симметрично относительно центра экрана
/// (полка всегда «прибита» по центру сверху), поэтому и левый, и правый край
/// двигают ширину на удвоенное смещение мыши (см. ShelfResizeCatcherView).
private struct ShelfResizeCatcher: NSViewRepresentable {
    let edge: ShelfResizeEdge

    func makeNSView(context: Context) -> ShelfResizeCatcherView {
        let view = ShelfResizeCatcherView()
        view.edge = edge
        view.toolTip = String(localized: "shelf.resize.help")
        return view
    }

    func updateNSView(_ nsView: ShelfResizeCatcherView, context: Context) {
        nsView.edge = edge
    }
}

private final class ShelfResizeCatcherView: NSView {
    var edge: ShelfResizeEdge = .bottom

    private var startMouseLocation: NSPoint = .zero
    private var startWidth: CGFloat = 0
    private var startHeight: CGFloat = 0

    // Иначе первый клик по неактивной панели проглатывается системой (см. DragCatcherView).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        startMouseLocation = NSEvent.mouseLocation
        startWidth = CGFloat(AppSettings.shared.shelfWidth)
        startHeight = CGFloat(AppSettings.shared.shelfHeight)
        // На время изменения размера полка не должна сворачиваться от «мышь ушла».
        ShelfController.shared.isDragging = true
    }

    override func mouseDragged(with event: NSEvent) {
        let (w, h) = resizedSize(for: NSEvent.mouseLocation)
        ShelfController.shared.applySize(width: w, height: h, live: true)
    }

    override func mouseUp(with event: NSEvent) {
        let (w, h) = resizedSize(for: NSEvent.mouseLocation)
        let roundedWidth = w.rounded()
        let roundedHeight = h.rounded()
        AppSettings.shared.shelfWidth = Double(roundedWidth)
        AppSettings.shared.shelfHeight = Double(roundedHeight)
        ShelfController.shared.applySize(width: roundedWidth, height: roundedHeight, live: false)
        ShelfController.shared.isDragging = false
    }

    /// Новая ширина/высота для текущего положения мыши, зажатая в границах ShelfSizeLimits.
    private func resizedSize(for mouseLocation: NSPoint) -> (CGFloat, CGFloat) {
        let dx = mouseLocation.x - startMouseLocation.x
        let dy = mouseLocation.y - startMouseLocation.y

        var width = startWidth
        var height = startHeight
        switch edge {
        case .right:
            width = startWidth + dx * 2
        case .left:
            width = startWidth - dx * 2
        case .bottom:
            // Экранные координаты растут вверх — движение мыши вниз (dy < 0) должно
            // УВЕЛИЧИВАТЬ высоту.
            height = startHeight - dy
        }

        width = min(max(width, CGFloat(ShelfSizeLimits.minWidth)), CGFloat(ShelfSizeLimits.maxWidth))
        height = min(max(height, CGFloat(ShelfSizeLimits.minHeight)), CGFloat(ShelfSizeLimits.maxHeight))
        return (width, height)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let cursor: NSCursor = (edge == .bottom) ? .resizeUpDown : .resizeLeftRight
        addCursorRect(bounds, cursor: cursor)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }
}

// MARK: - Быстрый просмотр (QuickLook)

/// ВНИМАНИЕ: наша панель принципиально не становится key window (иначе ломается
/// перетаскивание наружу), а QLPreviewPanel обычно рассчитывает на key-состояние
/// хозяина. Если на практике панель не открывается/не обновляется — деградируем
/// на NSWorkspace.shared.open(url) прямо здесь.
final class QuickLookHelper: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLookHelper()
    private var urls: [URL] = []

    func preview(urls: [URL]) {
        guard !urls.isEmpty else { return }
        self.urls = urls
        guard let panel = QLPreviewPanel.shared() else {
            NSWorkspace.shared.open(urls[0])
            return
        }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls[index] as NSURL
    }
}
