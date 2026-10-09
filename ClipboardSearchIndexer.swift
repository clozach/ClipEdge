import AppKit
import Vision
import CoreServices

/// Search data lives only in memory, and is derived again from retained payloads.
final class ClipboardSearchIndexer {
    struct Environment {
        var fileText: (URL) -> String? = { url in
            guard let item = MDItemCreate(nil, url.path as CFString) else { return nil }
            return MDItemCopyAttribute(item, kMDItemTextContent) as? String
        }
        var recognize: (CGImage) throws -> String = { image in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            try VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }
    }

    private let queue = DispatchQueue(label: "ClipEdge.image-text", qos: .utility)
    private let environment: Environment

    init(environment: Environment = Environment()) {
        self.environment = environment
    }

    func index(_ entry: ClipboardEntry, image suppliedImage: CGImage? = nil,
               completion: @escaping (ClipboardSearchState) -> Void) {
        let urls = entry.fileURLs
        // File images arrive already decoded at full resolution. Never OCR a file's
        // type icon or Quick Look fallback. In-memory clipboard images stay unchanged.
        let image = suppliedImage ?? (urls.isEmpty && entry.isImage
            ? entry.thumbnail?.cgImage(forProposedRect: nil, context: nil, hints: nil) : nil)
        let environment = self.environment
        queue.async {
            var parts: [String] = []
            var failure: String?
            for url in urls {
                if let text = environment.fileText(url) {
                    parts.append(text)
                }
            }
            if let image {
                do {
                    parts.append(try environment.recognize(image))
                } catch { failure = error.localizedDescription }
            }
            let text = parts.joined(separator: "\n")
            let result: ClipboardSearchState = failure.map { .failed($0) } ?? .ready(text)
            DispatchQueue.main.async { completion(result) }
        }
    }
}
