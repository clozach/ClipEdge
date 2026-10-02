import AppKit

/// Materializes files for the cursor carousel and opens payloads in Preview.
final class ClipboardPreviewService {
    let materializer = ClipboardMaterializer()
    func openInPreview(_ entry: ClipboardEntry, completion: @escaping (Error?) -> Void) {
        do {
            let urls = try materializer.urls(for: entry, forPreviewApp: true)
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else { throw PreviewError.cannotRender }
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                DispatchQueue.main.async { completion(error) }
            }
        } catch { completion(error) }
    }
}
