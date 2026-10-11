import AppKit
import UniformTypeIdentifiers

/// What a copy is, decided once by ClipboardSummary. Equatable is declared:
/// cases that carry what was read about the copy lose the free conformance.
enum ClipboardKind: Equatable {
    case text, image, file, link
    /// Layers copied in Figma, which only Figma can paste back; a copy that
    /// carries text reads and pastes elsewhere as that text.
    case figma(ClipboardFigmaCopy)
    /// A copy with HTML and no plain text; this is the text it reads as.
    case html(ClipboardHTMLText)
    case other
    var iconName: String {
        switch self {
        case .text, .html: return "text.alignleft"
        case .image: return "photo"
        case .file: return "doc"
        case .link: return "link"
        case .figma: return "square.3.layers.3d"
        case .other: return "square.on.square"
        }
    }
}

struct ClipboardPayload {
    let values: [(type: NSPasteboard.PasteboardType, data: Data)]
}

enum ClipboardFlavors {
    /// Clipboard flavors treated as a picture.
    static let images: Set<NSPasteboard.PasteboardType> = [
        .png, .tiff, .pdf, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("com.compuserve.gif")
    ]
    /// The page a Chromium browser copied from. Its query can carry tokens, so
    /// only its host is ever shown.
    static let sourceURL = NSPasteboard.PasteboardType("org.chromium.source-url")

    /// The text of a rich-text flavor, RTF else RTFD, for a copy without plain text.
    static func richText(in values: [(type: NSPasteboard.PasteboardType, data: Data)]) -> String? {
        if let data = values.first(where: { $0.type == .rtf })?.data,
           let text = NSAttributedString(rtf: data, documentAttributes: nil)?.string { return text }
        if let data = values.first(where: { $0.type == .rtfd })?.data { return NSAttributedString(rtfd: data, documentAttributes: nil)?.string }
        return nil
    }
    /// "claude.ai" for a copy from https://claude.ai/…; nil for app:// and other schemes.
    static func sourceSite(in values: [(type: NSPasteboard.PasteboardType, data: Data)]) -> String? {
        guard let data = values.first(where: { $0.type == sourceURL })?.data,
              let url = URL(string: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host, !host.isEmpty else { return nil }
        return site(host)
    }
    /// A host as people say it: without "www.".
    static func site(_ host: String) -> String {
        let lower = host.lowercased()
        return lower.hasPrefix("www.") ? String(lower.dropFirst(4)) : lower
    }
}

final class ClipboardEntry {
    let id = UUID()
    let fingerprint: String
    var capturedAt: Date
    let payloads: [ClipboardPayload]
    let title: String
    let detail: String
    var kind: ClipboardKind
    /// A Finder item starts with a type icon; inspection supplies its real preview.
    var thumbnail: NSImage?
    var metadata = ClipboardMetadata()
    var searchIndex: ClipboardSearchState = .ready("")
    var searchGeneration: UInt64 = 0
    var recognizedText: String { if case .ready(let text) = searchIndex { return text }; return "" }

    init(fingerprint: String, capturedAt: Date, payloads: [ClipboardPayload], title: String,
         detail: String, kind: ClipboardKind, thumbnail: NSImage?) {
        self.fingerprint = fingerprint
        self.capturedAt = capturedAt
        self.payloads = payloads
        self.title = title
        self.detail = detail
        self.kind = kind
        self.thumbnail = thumbnail
        metadata = .immediate(for: self)
    }

    var values: [(type: NSPasteboard.PasteboardType, data: Data)] { payloads.flatMap(\.values) }
    var fileURLs: [URL] {
        values.filter { $0.type == .fileURL }.compactMap { String(data: $0.data, encoding: .utf8) }
            .compactMap(URL.init(string:)).filter(\.isFileURL)
    }
    /// The copy's own text flavors: plain text, else rich text.
    var plainText: String? {
        let strings = values.filter { $0.type == .string }.compactMap { String(data: $0.data, encoding: .utf8) }
        if !strings.isEmpty { return strings.joined(separator: "\n") }
        return ClipboardFlavors.richText(in: values)
    }
    /// The text a person reads in this item: its text flavors, the text of an
    /// HTML-only copy, or the text Figma layers carry. Layers without text have
    /// none to show; their link is a paste.
    var readableText: String? {
        switch kind {
        case .html(let html): return html.text
        case .figma(let copy): return copy.carriedText
        default: return plainText
        }
    }
    var isImage: Bool { kind == .image }
    /// The quiet line beside a title: facts and paths, or the summary's own detail.
    var edgeText: String { metadata.isEmpty ? detail : metadata.compact }
    /// What a plain-text paste inserts: the entry's text, else its facts and paths.
    /// Figma layers lend their text, else their link; an HTML-only copy its text, read in full.
    var plainTextForPaste: String {
        switch kind {
        case .figma(let copy): return copy.carriedText ?? copy.link.absoluteString
        case .html(let html):
            guard !html.isComplete, let data = values.first(where: { $0.type == .html })?.data else { return html.text }
            return ClipboardHTMLText.readable(data, limit: .max)
        default: return plainText ?? metadata.pasteText
        }
    }
    var dateTimeStamp: String { Self.stamp.string(from: capturedAt) }
    var fullDateTimeStamp: String { Self.fullStamp.string(from: capturedAt) }
    /// What search reads: the title, detail and text, image text, the date, and
    /// for Figma layers the file, editor and site even where the title is cut short.
    var searchText: String {
        var parts = [title, detail, plainText ?? "", recognizedText, fullDateTimeStamp]
        switch kind {
        case .html(let html): parts.append(html.text)
        case .figma(let copy): parts += copy.searchTerms
        default: break
        }
        return parts.joined(separator: "\n")
    }
    func matches(_ query: String) -> Bool {
        let text = searchText
        return query.split(whereSeparator: \.isWhitespace).allSatisfy { text.localizedStandardContains(String($0)) }
    }
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d · HH:mm:ss"
        return formatter
    }()
    private static let fullStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .long
        return formatter
    }()
}

enum ClipboardStagingChange {
    case pickedUp(ClipboardEntry), cancelled(ClipboardEntry), pasted(ClipboardEntry), invalidated
}

/// A stable traversal of the order at the first shortcut, independent of selection.
struct ClipboardCycle {
    private var snapshot: [UUID] = []
    private var index = -1
    var position: (index: Int, count: Int)? { index >= 0 && !snapshot.isEmpty ? (index, snapshot.count) : nil }
    mutating func reset() { snapshot = []; index = -1 }
    mutating func next(in entries: [ClipboardEntry]) -> ClipboardEntry? { move(1, in: entries) }
    mutating func select(_ id: UUID, in entries: [ClipboardEntry]) -> ClipboardEntry? {
        snapshot = entries.map(\.id)
        guard let found = snapshot.firstIndex(of: id) else { reset(); return nil }
        index = found
        return entries[found]
    }
    mutating func move(_ direction: Int, in entries: [ClipboardEntry]) -> ClipboardEntry? {
        if snapshot.isEmpty { snapshot = entries.map(\.id) }
        guard !snapshot.isEmpty else { return nil }
        for _ in snapshot.indices {
            index = index < 0 ? (direction < 0 ? snapshot.count - 1 : 0) : (index + (direction < 0 ? -1 : 1) + snapshot.count) % snapshot.count
            if let entry = entries.first(where: { $0.id == snapshot[index] }) { return entry }
        }
        reset(); return nil
    }
}

enum ClipboardSearchState {
    case pending, ready(String), failed(String)
}
