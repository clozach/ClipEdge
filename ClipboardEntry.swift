import AppKit
import UniformTypeIdentifiers

enum ClipboardKind {
    case text, image, file, link, other
    var iconName: String {
        switch self {
        case .text: return "text.alignleft"
        case .image: return "photo"
        case .file: return "doc"
        case .link: return "link"
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
    var plainText: String? {
        let strings = values.filter { $0.type == .string }.compactMap { String(data: $0.data, encoding: .utf8) }
        if !strings.isEmpty { return strings.joined(separator: "\n") }
        if let data = values.first(where: { $0.type == .rtf })?.data {
            return NSAttributedString(rtf: data, documentAttributes: nil)?.string
        }
        return nil
    }
    var isImage: Bool { kind == .image }
    /// The quiet line beside a title: facts and paths, or the summary's own detail.
    var edgeText: String { metadata.isEmpty ? detail : metadata.compact }
    /// What a plain-text paste inserts: the entry's text, else its facts and paths.
    var plainTextForPaste: String { plainText ?? metadata.pasteText }
    var dateTimeStamp: String { Self.stamp.string(from: capturedAt) }
    var fullDateTimeStamp: String { Self.fullStamp.string(from: capturedAt) }
    func matches(_ query: String) -> Bool {
        let text = [title, detail, plainText ?? "", recognizedText, fullDateTimeStamp].joined(separator: "\n")
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
