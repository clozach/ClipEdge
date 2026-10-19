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
    /// An app's own format and nothing else readable; only that app can paste it.
    case appData(ClipboardAppData)
    /// Known formats that read as nothing (HTML that strips to nothing).
    case other
    var iconName: String {
        switch self {
        case .text, .html: return "text.alignleft"
        case .image: return "photo"
        case .file: return "doc"
        case .link: return "link"
        case .figma: return "square.3.layers.3d"
        case .appData: return "shippingbox"
        case .other: return "square.on.square"
        }
    }
}

struct ClipboardPayload {
    let values: [(type: NSPasteboard.PasteboardType, data: Data)]
}

enum ClipboardFlavors {
    /// A flavor read as a picture: PDF, or any format of image, however an
    /// app names it (Keynote's TIFF, a browser's WebP), when NSImage decodes it.
    static func isPicture(_ type: NSPasteboard.PasteboardType) -> Bool {
        type == .pdf || UTType(type.rawValue)?.conforms(to: .image) == true
    }
    /// The page a Chromium browser copied from. Its query can carry tokens, so
    /// only its host is ever shown.
    static let sourceURL = NSPasteboard.PasteboardType("org.chromium.source-url")

    /// The text of a rich-text flavor, RTF else RTFD, for a copy without plain text.
    /// A picture in it is an attachment character, which no one can read or want pasted.
    static func richText(in values: [(type: NSPasteboard.PasteboardType, data: Data)]) -> String? {
        let words: String?
        if let data = values.first(where: { $0.type == .rtf })?.data,
           let text = NSAttributedString(rtf: data, documentAttributes: nil)?.string { words = text }
        else if let data = values.first(where: { $0.type == .rtfd })?.data { words = NSAttributedString(rtfd: data, documentAttributes: nil)?.string }
        else { words = nil }
        return words?.replacingOccurrences(of: String(Character(UnicodeScalar(NSTextAttachment.character)!)), with: "")
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
    /// The app's own format this copy carries, whatever else it reads as (a
    /// picture, text); nil for a copy of known formats only. Read from the
    /// formats alone, so it always agrees with them.
    let appData: ClipboardAppData?
    var metadata = ClipboardMetadata()
    var searchIndex: ClipboardSearchState = .ready("")
    var searchGeneration: UInt64 = 0
    var recognizedText: String { if case .ready(let text) = searchIndex { return text }; return "" }
    /// Every format's bytes: what the item takes on disk, against the storage budget.
    var byteCount: Int64 { payloads.reduce(0) { $0 + $1.values.reduce(0) { $0 + Int64($1.data.count) } } }

    init(fingerprint: String, capturedAt: Date, payloads: [ClipboardPayload], title: String,
         detail: String, kind: ClipboardKind, thumbnail: NSImage?) {
        self.fingerprint = fingerprint
        self.capturedAt = capturedAt
        self.payloads = payloads
        self.title = title
        self.detail = detail
        self.kind = kind
        self.thumbnail = thumbnail
        appData = ClipboardAppData(types: payloads.flatMap(\.values).map(\.type.rawValue))
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
    /// Figma layers lend their text, else their link; an HTML-only copy its text, read
    /// in full; app data with nothing else readable, its name and formats.
    var plainTextForPaste: String {
        switch kind {
        case .figma(let copy): return copy.carriedText ?? copy.link.absoluteString
        case .html(let html):
            guard !html.isComplete, let data = values.first(where: { $0.type == .html })?.data else { return html.text }
            return ClipboardHTMLText.readable(data, limit: .max)
        case .appData(let data): return data.pasteText
        default: return plainText ?? metadata.pasteText
        }
    }
    /// Whether a plain-text paste inserts anything, as `plainTextForPaste` is not empty, without
    /// reading an HTML-only copy in full: its summary is never empty, and the rest only adds to it.
    var hasPlainTextForPaste: Bool {
        if case .html = kind { return true }
        return !plainTextForPaste.isEmpty
    }
    var dateTimeStamp: String { Self.stamp.string(from: capturedAt) }
    var fullDateTimeStamp: String { Self.fullStamp.string(from: capturedAt) }
    /// What search reads: the title, detail and text, image text, the date, for
    /// Figma layers the file, editor and site even where the title is cut short,
    /// and for app data its name and formats.
    var searchText: String {
        var parts = [title, detail, plainText ?? "", recognizedText, fullDateTimeStamp]
        switch kind {
        case .html(let html): parts.append(html.text)
        case .figma(let copy): parts += copy.searchTerms
        default: break
        }
        if let appData { parts += appData.searchTerms }
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
