import Foundation
import Vision
import AppKit

// MARK: - Распознавание текста на картинке (Vision)

enum TextRecognition {
    private static let supportedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "tiff", "gif", "bmp"
    ]

    /// Только картинки поддерживаемых форматов — по расширению файла.
    static func isSupported(_ item: ShelfItem) -> Bool {
        supportedExtensions.contains(item.url.pathExtension.lowercased())
    }

    /// Распознаёт текст на картинке по `url`. Результат — на главном потоке.
    /// Пустой результат или любая ошибка → `nil`, ничего не падает.
    static func recognize(_ url: URL, completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let text = recognizeSync(url)
            DispatchQueue.main.async { completion(text) }
        }
    }

    private static func recognizeSync(_ url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            NSLog("Mantel: не удалось открыть картинку для распознавания: \(url.path)")
            return nil
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let wanted = ["ru-RU", "en-US"]
        if let available = try? VNRecognizeTextRequest.supportedRecognitionLanguages(
            for: request.recognitionLevel, revision: request.revision) {
            let availableSet = Set(available)
            let filtered = wanted.filter { availableSet.contains($0) }
            request.recognitionLanguages = filtered.isEmpty ? available : filtered
        } else {
            request.recognitionLanguages = wanted
        }

        if #available(macOS 13.0, *) {
            request.automaticallyDetectsLanguage = true
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            NSLog("Mantel: ошибка распознавания текста: \(error.localizedDescription)")
            return nil
        }

        guard let observations = request.results else { return nil }

        // Наблюдения уже приходят от Vision примерно в порядке чтения, но подстрахуемся
        // явной сортировкой сверху вниз (Vision использует нормализованные координаты
        // с началом в левом нижнем углу — поэтому сортируем по убыванию Y).
        let lines = observations
            .compactMap { observation -> (String, CGFloat)? in
                guard let candidate = observation.topCandidates(1).first,
                      candidate.confidence >= 0.3 else { return nil }
                return (candidate.string, observation.boundingBox.origin.y)
            }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }

        guard !lines.isEmpty else { return nil }
        let text = lines.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }
}
