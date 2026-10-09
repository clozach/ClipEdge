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
        if let text = entry.plainText ?? entry.values.first(where: { $0.type == .URL }).flatMap({ String(data: $0.data, encoding: .utf8) }) {
            if forPreviewApp { return [try textPDF(text, entry: entry, name: "Clipboard")] }
            return [try write(Data(text.utf8), to: folder.appendingPathComponent("Clipboard.txt"))]
        }
        // An unknown clipboard flavor has no universal renderer; retain a readable inventory.
        let description = entry.values.map { "\($0.type.rawValue): \($0.data.count) bytes" }.joined(separator: "\n")
        return [try textPDF("No system preview for this clipboard format.\n\n" + description, entry: entry, name: "Clipboard formats")]
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
