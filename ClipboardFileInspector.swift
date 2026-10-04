import AppKit
import QuickLookThumbnailing

/// Disk facts and Quick Look thumbnails for copied Finder items, off the main
/// thread. Both are derived again after a restart; nothing is persisted.
final class ClipboardFileInspector {
    private let queue = DispatchQueue(label: "ClipEdge.file-facts", qos: .utility)

    func inspect(_ urls: [URL], wantsThumbnail: Bool, facts: @escaping (ClipboardMetadata) -> Void,
                 thumbnail: @escaping (NSImage) -> Void) {
        queue.async {
            let metadata = ClipboardMetadata.files(urls)
            DispatchQueue.main.async { facts(metadata) }
            guard wantsThumbnail, urls.count == 1, let url = urls.first else { return }
            // A real thumbnail only: the Finder icon is already the placeholder.
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 512, height: 512),
                                                       scale: 2, representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                guard let image = representation?.nsImage else { return }
                DispatchQueue.main.async { thumbnail(image) }
            }
        }
    }
}
