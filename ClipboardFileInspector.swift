import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// File access stays off the main thread. Derived previews and facts are not persisted.
final class ClipboardFileInspector {
    struct FullImage {
        let preview: NSImage
        let pixels: CGImage?
    }

    enum Preview {
        case icon(NSImage)
        case image(FullImage)
        case thumbnail(NSImage)
    }

    struct Environment {
        var metadata: ([URL]) -> ClipboardMetadata = ClipboardMetadata.files
        var fullImage: (URL) -> FullImage? = ClipboardFileInspector.loadImage
        var icon: (URL) -> NSImage = { NSWorkspace.shared.icon(forFile: $0.path) }
        var thumbnail: (URL, @escaping (NSImage?) -> Void) -> Void = { url, completion in
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 512, height: 512),
                                                       scale: 2, representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                completion(representation?.nsImage)
            }
        }
    }

    // One unavailable file must not prevent another entry's preview from loading.
    private let queue = DispatchQueue(label: "ClipEdge.file-facts", qos: .utility, attributes: .concurrent)
    private let environment: Environment

    init(environment: Environment = Environment()) {
        self.environment = environment
    }

    func inspect(_ urls: [URL], facts: @escaping (ClipboardMetadata) -> Void,
                 preview: @escaping (Preview) -> Void) {
        let environment = self.environment
        queue.async {
            let metadata = environment.metadata(urls)
            DispatchQueue.main.async { facts(metadata) }
        }
        queue.async {
            guard let url = urls.first else { return }
            if urls.count == 1,
               UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true,
               let image = environment.fullImage(url) {
                // Keep the full image and OCR pixels, rather than a 512-point Quick Look copy.
                DispatchQueue.main.async { preview(.image(image)) }
                return
            }
            let icon = environment.icon(url)
            DispatchQueue.main.async { preview(.icon(icon)) }
            guard urls.count == 1 else { return }
            environment.thumbnail(url) { image in
                guard let image else { return }
                DispatchQueue.main.async { preview(.thumbnail(image)) }
            }
        }
    }

    private static func loadImage(_ url: URL) -> FullImage? {
        // Reading bytes here prevents an NSImage backed by a file URL from reopening
        // that file later while the UI draws or prepares OCR. Retain all representations.
        guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else { return nil }
        let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        return FullImage(preview: image, pixels: pixels)
    }
}
