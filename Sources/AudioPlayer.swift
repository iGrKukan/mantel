import Foundation
import AVFoundation
import AppKit

/// Проигрыватель аудио-элементов полки: play/pause/stop/seek/next/previous, прогресс по таймеру,
/// метаданные трека (обложка/название/исполнитель) для мини-плеера.
final class AudioPlayerModel: NSObject, ObservableObject {
    static let shared = AudioPlayerModel()

    @Published var currentItemID: UUID?
    @Published var isPlaying: Bool = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0

    @Published var trackTitle: String = ""
    @Published var trackArtist: String = ""
    @Published var artwork: NSImage?

    private var player: AVAudioPlayer?
    private var timer: Timer?

    private static let audioExtensions: Set<String> =
        ["mp3", "m4a", "aac", "wav", "aiff", "flac", "alac", "ogg", "opus", "wma"]

    static func isAudio(_ item: ShelfItem) -> Bool {
        audioExtensions.contains((item.fileName as NSString).pathExtension.lowercased())
    }

    private override init() { super.init() }

    /// Тот же элемент — пауза/возобновить; другой — начать заново.
    func toggle(_ item: ShelfItem) {
        guard Self.isAudio(item) else { return }

        if currentItemID == item.id, let player {
            if player.isPlaying {
                player.pause()
                isPlaying = false
                stopTimer()
            } else {
                player.play()
                isPlaying = true
                startTimer()
            }
            return
        }

        start(item)
    }

    /// Следующий аудио-элемент в Library.shared.items, по кругу.
    func next() {
        let audioItems = Library.shared.items.filter { Self.isAudio($0) }
        guard !audioItems.isEmpty else { return }
        guard let currentItemID, let idx = audioItems.firstIndex(where: { $0.id == currentItemID }) else {
            start(audioItems[0])
            return
        }
        start(audioItems[(idx + 1) % audioItems.count])
    }

    /// Если прошло больше 3 сек — перемотать текущий трек в начало, иначе предыдущий по кругу.
    func previous() {
        let audioItems = Library.shared.items.filter { Self.isAudio($0) }
        guard !audioItems.isEmpty else { return }

        if currentItemID != nil, currentTime > 3 {
            seek(fraction: 0)
            return
        }

        guard let currentItemID, let idx = audioItems.firstIndex(where: { $0.id == currentItemID }) else {
            start(audioItems[0])
            return
        }
        start(audioItems[(idx - 1 + audioItems.count) % audioItems.count])
    }

    func stop() {
        player?.stop()
        player = nil
        stopTimer()
        currentItemID = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        trackTitle = ""
        trackArtist = ""
        artwork = nil
    }

    func seek(fraction: Double) {
        guard let player, duration > 0 else { return }
        let t = min(max(fraction, 0), 1) * duration
        player.currentTime = t
        currentTime = t
    }

    /// Останавливает текущее воспроизведение (если есть) и начинает `item` заново.
    private func start(_ item: ShelfItem) {
        stop()
        do {
            let newPlayer = try AVAudioPlayer(contentsOf: item.url)
            newPlayer.delegate = self
            newPlayer.prepareToPlay()
            player = newPlayer
            currentItemID = item.id
            duration = newPlayer.duration
            currentTime = 0
            trackTitle = (item.fileName as NSString).deletingPathExtension
            trackArtist = ""
            newPlayer.play()
            isPlaying = true
            startTimer()
            loadMetadata(for: item)
        } catch {
            NSLog("ShelfTop: не смог воспроизвести %@: %@", item.fileName, error.localizedDescription)
        }
    }

    /// Читает название/исполнителя/обложку из общих метаданных файла в фоне; если их нет —
    /// остаются значения по умолчанию, выставленные в start() (имя файла, пустой исполнитель).
    private func loadMetadata(for item: ShelfItem) {
        let url = item.url
        let itemID = item.id
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let asset = AVURLAsset(url: url)
            var title: String?
            var artist: String?
            var image: NSImage?
            for meta in asset.commonMetadata {
                guard let key = meta.commonKey else { continue }
                switch key {
                case .commonKeyTitle:
                    title = meta.stringValue
                case .commonKeyArtist:
                    artist = meta.stringValue
                case .commonKeyArtwork:
                    if let data = meta.dataValue { image = NSImage(data: data) }
                default:
                    break
                }
            }
            DispatchQueue.main.async {
                guard let self, self.currentItemID == itemID else { return }
                if let title, !title.isEmpty { self.trackTitle = title }
                if let artist, !artist.isEmpty { self.trackArtist = artist }
                self.artwork = image
            }
        }
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let player else { return }
        currentTime = player.currentTime
    }
}

extension AudioPlayerModel: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.stop()
        }
    }
}
