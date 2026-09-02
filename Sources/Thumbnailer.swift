import Foundation
import AppKit
import QuickLookThumbnailing
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Генерация миниатюр

/// Создаёт PNG-миниатюры для элементов полки: картинки — через QuickLook,
/// видео — первый кадр через AVFoundation, аудио — обложка из метаданных (если есть).
enum Thumbnailer {

    private static let videoExts: Set<String> = ["mov", "mp4", "m4v", "avi"]
    private static let audioExts: Set<String> = ["mp3", "m4a", "aac", "wav", "flac", "aiff", "aif"]
    private static let imageExts: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "tiff", "tif", "bmp", "webp"]

    /// Запускает генерацию миниатюры в фоне. Не блокирует вызывающего.
    static func generate(for item: ShelfItem) {
        if FileManager.default.fileExists(atPath: item.thumbnailURL.path) { return }
        DispatchQueue.global(qos: .utility).async {
            makeThumbnail(for: item)
        }
    }

    /// Проходит по всем элементам библиотеки и досоздаёт отсутствующие миниатюры.
    static func regenerateMissing() {
        DispatchQueue.main.async {
            let items = Library.shared.items
            for item in items where !FileManager.default.fileExists(atPath: item.thumbnailURL.path) {
                generate(for: item)
            }
        }
    }

    // MARK: - Диспетчеризация по типу файла

    private static func makeThumbnail(for item: ShelfItem) {
        let ext = item.url.pathExtension.lowercased()
        if videoExts.contains(ext) {
            makeVideoThumbnail(for: item)
        } else if audioExts.contains(ext) {
            makeAudioThumbnail(for: item)
        } else if imageExts.contains(ext) {
            // картинки — через ImageIO: быстро, без XPC QuickLook (он падает на крупных PNG)
            if !makeImageIOThumbnail(for: item) { makeQuickLookThumbnail(for: item) }
        } else {
            // прочее (pdf, документы) — QuickLook, а если не вышло, иконка типа файла
            makeQuickLookThumbnail(for: item)
        }
    }

    /// Миниатюра картинки через ImageIO. true — файл записан.
    private static func makeImageIOThumbnail(for item: ShelfItem) -> Bool {
        guard let src = CGImageSourceCreateWithURL(item.url as CFURL, nil) else { return false }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 640,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return false }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        if savePNG(image, to: item.thumbnailURL) { notifyReady(item.id); return true }
        return false
    }

    private static func makeQuickLookThumbnail(for item: ShelfItem) {
        // NSScreen нужно читать на главном потоке
        let scale = DispatchQueue.main.sync { NSScreen.main?.backingScaleFactor ?? 2 }
        let size = CGSize(width: 320, height: 220)
        let request = QLThumbnailGenerator.Request(fileAt: item.url, size: size,
                                                     scale: scale,
                                                     representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumbnail, error in
            guard let thumbnail = thumbnail else {
                NSLog("ShelfTop: QuickLook не смог сделать миниатюру для %@: %@",
                      item.fileName, error?.localizedDescription ?? "-")
                // запасной вариант — крупная системная иконка типа файла
                DispatchQueue.main.async {
                    let icon = NSWorkspace.shared.icon(forFile: item.url.path)
                    icon.size = NSSize(width: 256, height: 256)
                    if savePNG(icon, to: item.thumbnailURL) { notifyReady(item.id) }
                }
                return
            }
            if savePNG(thumbnail.nsImage, to: item.thumbnailURL) {
                notifyReady(item.id)
            }
        }
    }

    private static func makeVideoThumbnail(for item: ShelfItem) {
        let asset = AVURLAsset(url: item.url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        func frame(at time: CMTime) -> CGImage? {
            try? generator.copyCGImage(at: time, actualTime: nil)
        }

        // сперва пробуем 0.5с, если кадр не достаётся — самое начало ролика
        let preferred = CMTime(seconds: 0.5, preferredTimescale: 600)
        guard let cgImage = frame(at: preferred) ?? frame(at: .zero) else {
            NSLog("ShelfTop: не смог извлечь кадр из %@", item.fileName)
            return
        }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        if savePNG(image, to: item.thumbnailURL) {
            notifyReady(item.id)
        }
    }

    private static func makeAudioThumbnail(for item: ShelfItem) {
        let asset = AVURLAsset(url: item.url)
        guard let artwork = asset.commonMetadata.first(where: { $0.commonKey == .commonKeyArtwork }),
              let data = artwork.dataValue,
              let image = NSImage(data: data) else {
            // обложки нет — UI сам нарисует иконку по типу, файл не создаём
            return
        }
        if savePNG(image, to: item.thumbnailURL) {
            notifyReady(item.id)
        }
    }

    // MARK: - Запись PNG

    @discardableResult
    private static func savePNG(_ image: NSImage, to url: URL) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: url, options: .atomic)
            return true
        } catch {
            NSLog("ShelfTop: не смог записать миниатюру %@: %@", url.path, error.localizedDescription)
            return false
        }
    }

    private static func notifyReady(_ id: UUID) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .shelfThumbnailReady, object: id)
        }
    }
}

extension Notification.Name {
    static let shelfThumbnailReady = Notification.Name("by.maru.shelftop.thumbReady")
}
