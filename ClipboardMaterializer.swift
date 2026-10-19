import AppKit
import CoreText
import UniformTypeIdentifiers

/// Private derived preview files. Never copies an original Finder file or indexes clipboard payloads.
final class ClipboardMaterializer {
    private let root: URL
    static var defaultRoot: URL {
        // Foundation's macOS temporaryDirectory ignores TMPDIR. Preparation
        // tests need an explicit namespace while the real app stays running.
        if let path = ProcessInfo.processInfo.environment["CLIPEDGE_TEST_PREVIEW_ROOT"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("ClipEdge-Previews", isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("ClipEdge-Previews", isDirectory: true)
    }
    /// For a process other than the app, such as a capture tool: a default materializer
    /// empties its root, and the default root is the running app's. Removing the
    /// returned folder at exit is the caller's.
    static func usePrivateRoot() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClipEdge-tool-previews-\(UUID().uuidString)", isDirectory: true)
        setenv("CLIPEDGE_TEST_PREVIEW_ROOT", root.path, 1)
        return root
    }
    /// A throwaway preferences suite for a test or a capture tool, named by a path
    /// under the private root: cfprefsd keeps an empty plist for every suite it has
    /// seen, and here that lands where the root's removal takes it, never in
    /// ~/Library/Preferences.
    static func privateSuiteName(_ prefix: String) -> String {
        let root = ProcessInfo.processInfo.environment["CLIPEDGE_TEST_PREVIEW_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent(prefix + UUID().uuidString).path
    }
    init(root: URL = ClipboardMaterializer.defaultRoot) {
        self.root = root
        // The app is single-instance. Old derived files have no value after restart.
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func urls(for entry: ClipboardEntry, forPreviewApp: Bool = false) throws -> [URL] {
        if !entry.fileURLs.isEmpty {
            if !forPreviewApp { return entry.fileURLs }
            return try entry.fileURLs.map { url in
                let type = UTType(filenameExtension: url.pathExtension)
                if type?.conforms(to: .image) == true || type?.conforms(to: .pdf) == true { return url }
                if type?.conforms(to: .text) == true {
                    let text = try String(contentsOf: url, encoding: .utf8)
                    return try textPDF(text, entry: entry, name: url.lastPathComponent)
                }
                throw PreviewError.unsupportedFile(url.lastPathComponent)
            }
        }
        let folder = try directory(for: entry)
        if let value = entry.values.first(where: { $0.type == .pdf }) {
            return [try write(value.data, to: folder.appendingPathComponent("Clipboard.pdf"))]
        }
        let imageTypes: [(NSPasteboard.PasteboardType, String)] = [(.png, "png"), (.tiff, "tiff"), (.init("public.jpeg"), "jpg"), (.init("com.compuserve.gif"), "gif")]
        for (type, ext) in imageTypes {
            if let value = entry.values.first(where: { $0.type == type }) {
                return [try write(value.data, to: folder.appendingPathComponent("Clipboard.\(ext)"))]
            }
        }
        // A picture in any other format an app names (WebP, BMP, HEIC), under its own extension.
        // Quick Look draws SVG with its web renderer, which can load what the picture names:
        // that one is handed over as pixels instead, and one that cannot be drawn is skipped.
        for value in entry.values where ClipboardFlavors.isPicture(value.type) {
            if UTType(value.type.rawValue)?.conforms(to: .svg) == true {
                if let pixels = Self.rasterized(value.data) { return [try write(pixels, to: folder.appendingPathComponent("Clipboard.png"))] }
                continue // never Clipboard.svg: Quick Look would hand it to its web renderer, which loads what the picture names
            }
            let ext = UTType(value.type.rawValue)?.preferredFilenameExtension ?? "img"
            return [try write(value.data, to: folder.appendingPathComponent("Clipboard.\(ext)"))]
        }
        // A declared format goes to Quick Look as a typed file, so the previewers on
        // this Mac draw it: formatted rich text, JSON, Markdown, an app's own documents.
        // Preview opens only pictures and PDFs, so ⌘O keeps its page of text.
        if !forPreviewApp, let typed = ClipboardTypedPreview.choice(for: entry),
           let value = entry.values.first(where: { $0.type == typed.type }) {
            return [try write(value.data, to: folder.appendingPathComponent(typed.fileName))]
        }
        // Figma layers have no picture ClipEdge can draw: their words or title,
        // what they are and the link back. Quick Look gets text, which it draws
        // in the current appearance; Preview gets a page.
        if case .figma(let copy) = entry.kind {
            let card = [copy.carriedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? copy.title,
                        copy.facts.joined(separator: " · "), copy.explanation, copy.link.absoluteString].joined(separator: "\n\n")
            let name: String
            switch copy.selection {
            case .layers(_, let more): name = more.isEmpty ? "Figma layer" : "Figma layers"
            case .cut: name = "Figma layers"
            case .otherData: name = "Figma data"
            }
            let file = copy.carriedText == nil ? name : "Figma text"
            if forPreviewApp { return [try textPDF(card, entry: entry, name: file)] }
            return [try write(Data(card.utf8), to: folder.appendingPathComponent(file + ".txt"))]
        }
        // App data with nothing else readable: what it is, where it pastes and
        // its every format, as text for Quick Look and a page for Preview.
        if case .appData(let data) = entry.kind {
            let card = [data.title, entry.metadata.lines.joined(separator: "\n"), ClipboardAppData.explanation, data.formatList].joined(separator: "\n\n")
            if forPreviewApp { return [try textPDF(card, entry: entry, name: data.title)] }
            return [try write(Data(card.utf8), to: folder.appendingPathComponent(data.title + ".txt"))]
        }
        // An HTML-only copy is shown as its text, never as HTML a renderer would load.
        if let text = entry.readableText ?? entry.values.first(where: { $0.type == .URL }).flatMap({ String(data: $0.data, encoding: .utf8) }) {
            if forPreviewApp { return [try textPDF(text, entry: entry, name: "Clipboard")] }
            return [try write(Data(text.utf8), to: folder.appendingPathComponent("Clipboard.txt"))]
        }
        // An unknown clipboard flavor has no universal renderer; retain a readable inventory,
        // as text for Quick Look (drawn in the current appearance) and a page for Preview.
        let description = "No system preview for this clipboard format.\n\n" + entry.values.map { "\($0.type.rawValue): \($0.data.count) bytes" }.joined(separator: "\n")
        if forPreviewApp { return [try textPDF(description, entry: entry, name: "Clipboard formats")] }
        return [try write(Data(description.utf8), to: folder.appendingPathComponent("Clipboard formats.txt"))]
    }
    func remove(_ entry: ClipboardEntry) throws {
        let folder = root.appendingPathComponent(entry.id.uuidString)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }
    func removeAll() { try? FileManager.default.removeItem(at: root) }
    private func directory(for entry: ClipboardEntry) throws -> URL {
        let directory = root.appendingPathComponent(entry.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory
    }
    /// A vector picture drawn to pixels at twice its size (at most 4096 across),
    /// so Quick Look's image previewer shows it and no web renderer is involved.
    private static func rasterized(_ data: Data) -> Data? {
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = min(2, 4096 / max(image.size.width, image.size.height))
        let (width, height) = (max(1, Int(image.size.width * scale)), max(1, Int(image.size.height * scale)))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
    private func write(_ data: Data, to url: URL) throws -> URL {
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        return url
    }
    private func textPDF(_ text: String, entry: ClipboardEntry, name: String) throws -> URL {
        let url = try directory(for: entry).appendingPathComponent(name + ".pdf")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { throw PreviewError.cannotRender }
        let attributed = NSAttributedString(string: text.isEmpty ? " " : text, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: mediaBox.insetBy(dx: 36, dy: 36), transform: nil)
        var offset = 0
        while offset < attributed.length {
            context.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: offset, length: 0), path, nil)
            CTFrameDraw(frame, context)
            let range = CTFrameGetVisibleStringRange(frame)
            context.endPDFPage()
            guard range.length > 0 else { throw PreviewError.cannotRender }
            offset += range.length
        }
        context.closePDF()
        return try write(data as Data, to: url)
    }
}

enum PreviewError: LocalizedError {
    case unsupportedFile(String), cannotRender
    var errorDescription: String? {
        switch self {
        case .unsupportedFile(let name): return "Preview cannot open \(name). Use Quick Look for this file."
        case .cannotRender: return "ClipEdge could not create this preview."
        }
    }
}
