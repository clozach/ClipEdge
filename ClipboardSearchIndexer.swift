import AppKit
import Vision
import CoreServices

/// Search data lives only in memory, and is derived again from retained payloads.
final class ClipboardSearchIndexer {
    private let queue = DispatchQueue(label: "ClipEdge.image-text", qos: .utility)

    func index(_ entry: ClipboardEntry, completion: @escaping (ClipboardSearchState) -> Void) {
        let urls = entry.fileURLs
        // Decode AppKit image representations on the main thread.
        let image = entry.isImage ? entry.thumbnail?.cgImage(forProposedRect: nil, context: nil, hints: nil) : nil
        queue.async {
            var parts: [String] = []
            var failure: String?
            for url in urls {
                if let item = MDItemCreate(nil, url.path as CFString),
                   let text = MDItemCopyAttribute(item, kMDItemTextContent) as? String {
                    parts.append(text)
                }
            }
            if let image {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.automaticallyDetectsLanguage = true
                do {
                    try VNImageRequestHandler(cgImage: image).perform([request])
                    parts.append(contentsOf: (request.results ?? []).compactMap { $0.topCandidates(1).first?.string })
                } catch { failure = error.localizedDescription }
            }
            let text = parts.joined(separator: "\n")
            let result: ClipboardSearchState = failure.map { .failed($0) } ?? .ready(text)
            DispatchQueue.main.async { completion(result) }
        }
    }
}
