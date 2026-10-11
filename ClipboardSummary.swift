import AppKit
import UniformTypeIdentifiers

enum ClipboardSummary {
    static func make(from payloads: [ClipboardPayload]) -> (
        title: String,
        detail: String,
        kind: ClipboardKind,
        thumbnail: NSImage?
    ) {
        let values = payloads.flatMap(\.values)

        let fileURLStrings = values.compactMap { value -> String? in
            guard value.type == .fileURL else { return nil }
            return String(data: value.data, encoding: .utf8)
        }
        if let fileURLString = fileURLStrings.first,
           let url = URL(string: fileURLString) {
            let count = fileURLStrings.count
            let detail = count > 1 ? "\(count) files" : url.deletingLastPathComponent().path
            // Resolving a cloud or disconnected-volume file can block. Start with
            // a type icon without touching its path; the inspector confirms images
            // and obtains the real preview off the main thread.
            let type = UTType(filenameExtension: url.pathExtension) ?? .data
            return (url.lastPathComponent, detail, .file, NSWorkspace.shared.icon(for: type))
        }

        if let image = values.lazy.compactMap({ value -> NSImage? in
            guard ClipboardFlavors.images.contains(value.type) else { return nil }
            return NSImage(data: value.data)
        }).first {
            let size = image.size
            let detail = "\(Int(size.width)) × \(Int(size.height)) image"
            return ("Image", detail, .image, image)
        }

        // Figma before plain text: a copy with an empty text flavor stays Figma
        // layers; one that carries text is titled by it and keeps what Figma said.
        if let html = values.first(where: { $0.type == .html })?.data {
            let text = values.first { $0.type == .string }.map { String(decoding: $0.data, as: UTF8.self) }
            let source = values.first { $0.type == ClipboardFlavors.sourceURL }.map { String(decoding: $0.data, as: UTF8.self) }
            if let copy = ClipboardFigmaCopy(html: html, sourceURL: source, elsewhere: .init(text: text)) {
                return (copy.title, copy.facts.joined(separator: " · "), .figma(copy), nil)
            }
        }

        if let string = values.lazy.compactMap({ value -> String? in
            guard value.type == .string else { return nil }
            return String(data: value.data, encoding: .utf8)
        }).first {
            let summary = text(string)
            return (summary.title, summary.detail, summary.kind, nil)
        }

        // Rich text alone reads as the text it holds, as it pastes.
        if let rich = ClipboardFlavors.richText(in: values) {
            let summary = text(rich)
            return (summary.title, summary.detail, summary.kind, nil)
        }

        if let data = values.first(where: { $0.type == .html })?.data, let html = ClipboardHTMLText(html: data) {
            let count = characters(html.text.count)
            // A lone address names its site, as a link does; it stays HTML so it pastes as its text.
            let detail = html.address.map { $0.host ?? ($0.scheme ?? "").uppercased() } ?? (html.isComplete ? count : "at least \(count)")
            // The scanner already collapsed spaces; a short head is enough for 90 characters.
            return (title(String(html.text.prefix(2_000))), detail, .html(html), nil)
        }

        // Name what the item holds: standard types first, a browser's private bookkeeping not at all.
        let typeNames = Set(values.map { $0.type.rawValue }).filter { !$0.hasPrefix("org.chromium.internal.") }
        let ordered = typeNames.sorted { a, b in
            let (aPublic, bPublic) = (a.hasPrefix("public."), b.hasPrefix("public."))
            return aPublic != bPublic ? aPublic : a < b
        }
        let detail = (ordered.isEmpty ? Set(values.map { $0.type.rawValue }).sorted() : ordered).prefix(2).joined(separator: ", ")
        return ("Clipboard item", detail, .other, nil)
    }

    /// A text item: its first 90 characters with spaces collapsed; a lone web or mail address is a link.
    private static func text(_ string: String) -> (title: String, detail: String, kind: ClipboardKind) {
        let display = normalized(string)
        if let url = address(normalized: display) {
            return (String(display.prefix(90)), url.host ?? (url.scheme ?? "").uppercased(), .link)
        }
        return (String(display.prefix(90)), characters(string.count), .text)
    }
    /// A text item's title, Figma text's too: its first 90 characters with spaces collapsed.
    static func title(_ string: String) -> String { String(normalized(string).prefix(90)) }
    /// The web or mail address `string` holds and nothing else.
    static func address(in string: String) -> URL? { address(normalized: normalized(string)) }
    /// URL(string:) encodes spaces, so "https://… and more words" would read as one
    /// address: a lone address has none.
    private static func address(normalized display: String) -> URL? {
        guard !display.contains(" "), let url = URL(string: display),
              let scheme = url.scheme, ["http", "https", "mailto"].contains(scheme) else { return nil }
        return url
    }
    private static func normalized(_ string: String) -> String {
        let collapsed = string.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? "Empty text" : collapsed
    }
    private static func characters(_ count: Int) -> String { count == 1 ? "1 character" : "\(count) characters" }
}

extension ClipboardHTMLText {
    /// The one web or mail address this HTML reads as, as rich and plain text can.
    /// Only a short, whole copy is looked at: a long one is never a lone address.
    var address: URL? { isComplete && text.utf8.count <= 8_192 ? ClipboardSummary.address(in: text) : nil }
}
