import AppKit
import UniformTypeIdentifiers

/// Which flavor Quick Look is handed as a typed file ("Clipboard.json"), so the
/// previewers already on the Mac draw it, in place of ClipEdge's text card.
/// Decided from the formats alone, so the card, the item's info and the derived
/// file agree. Never a picture or a PDF (those are pictures already), never a
/// type a web renderer would draw (HTML, a web archive, SVG), never plain text.
struct ClipboardTypedPreview: Equatable {
    let type: NSPasteboard.PasteboardType
    /// The declared type's own extension: "json", "rtf", "md".
    let ext: String
    var fileName: String { "Clipboard.\(ext)" }
    /// The format as the facts name it, in capitals like a picture's or a file's: "RTF", "JSON", "MD".
    var formatName: String { ext.uppercased() }
    /// The quiet line on the card and in the item's info.
    var fact: String { "Quick Look shows its \(formatName) format" }

    /// Rich text first, then text-like types people name by their extension,
    /// then source code, then any other declared type Quick Look can show.
    static let preferred: [NSPasteboard.PasteboardType] = [
        .rtf, .init("public.json"), .init("net.daringfireball.markdown"), .init("public.comma-separated-values-text"),
        .init("public.tab-separated-values-text"), .init("public.xml"), .init("com.apple.property-list")
    ]
    /// Quick Look draws these with a web renderer, which can load what the copy
    /// names; they keep the text card (HTML) or a rasterized picture (SVG).
    static let webRendered: Set<String> = ["public.html", "public.xhtml", "com.apple.webarchive", "public.svg-image"]
    /// The text card is plain text already; a plain-text flavor is never a typed file.
    static let plainTextTypes: Set<String> = ["public.plain-text", "public.text"]

    /// Nil for a Finder item, a picture or a PDF, and for a copy with no declared
    /// non-web type that has an extension: those keep today's previews.
    static func choice(for entry: ClipboardEntry) -> ClipboardTypedPreview? {
        guard entry.fileURLs.isEmpty else { return nil }
        let values = entry.values
        guard !values.contains(where: { ClipboardFlavors.isPicture($0.type) }) else { return nil }
        let types = values.map(\.type)
        for type in preferred where types.contains(type) {
            if let ext = fileExtension(of: type) { return ClipboardTypedPreview(type: type, ext: ext) }
        }
        let others = types.compactMap { type in fileExtension(of: type).map { (type, $0) } }
        if let code = others.first(where: { UTType($0.0.rawValue)?.conforms(to: .sourceCode) == true }) { return ClipboardTypedPreview(type: code.0, ext: code.1) }
        return others.first.map { ClipboardTypedPreview(type: $0.0, ext: $0.1) }
    }

    /// A declared type's own extension, or nil where Quick Look gets no typed file.
    static func fileExtension(of type: NSPasteboard.PasteboardType) -> String? {
        let id = type.rawValue
        guard !webRendered.contains(id), !plainTextTypes.contains(id), let declared = UTType(id), declared.isDeclared,
              !declared.conforms(to: .html), !declared.conforms(to: .image), !declared.conforms(to: .pdf),
              let ext = declared.preferredFilenameExtension, !ext.isEmpty else { return nil }
        return ext
    }
}
