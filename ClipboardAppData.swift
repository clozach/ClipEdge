import Foundation
import UniformTypeIdentifiers

/// A copy carrying an app's own format: a pasteboard item with at least one
/// type outside the set ClipEdge reads and the bookkeeping a pasteboard adds
/// (Apple's word for a type is a UTI; ClipEdge says "format"). Such a copy
/// pastes back into its app byte for byte. ClipEdge names it by its type and
/// lists its formats, and never reads the data, so this stays cheap for every
/// saved item at launch.
struct ClipboardAppData: Equatable {
    /// "iWork", "Notes", "Sketch": the app's own label in its first type, else
    /// the vendor's, else "App".
    let name: String
    /// Every format the item carries, as the pasteboard names them, in the
    /// item's order; bookkeeping left out.
    let formats: [String]

    /// Nil unless at least one type is an app's own.
    init?(types: [String]) {
        guard let first = types.first(where: { Self.role(of: $0) == .app }) else { return nil }
        name = Self.name(forType: first)
        formats = types.filter { Self.role(of: $0) != .bookkeeping }
    }

    /// "Keynote data": what the item is called when nothing else in it reads.
    var title: String { "\(name) data" }
    var formatsFact: String { formats.count == 1 ? "1 format" : "\(formats.count) formats" }
    /// The quiet facts a copy that reads as something else (a picture, text) adds.
    var facts: [String] { [title, formatsFact] }
    /// The one explanation every surface shows: the history card, Quick Look,
    /// the held magnet and an item's info.
    static let explanation = "Pastes back into the app it came from, exactly as copied."
    /// For a small magnet without room for the explanation. A held item is on
    /// the clipboard, so here ⌃⌘V is the right key.
    static let shortNote = "Pastes back into its app. ⌃⌘V pastes its name and formats."
    /// The title over the explanation, where a surface lists the formats apart.
    var summary: String { "\(title)\n\(Self.explanation)" }
    var formatList: String { formats.joined(separator: "\n") }
    /// What a plain-text paste inserts for a copy with no picture: never a beep.
    var pasteText: String { ([title] + formats).joined(separator: "\n") }
    var searchTerms: [String] { [title, "app data"] + formats }

    // MARK: The known set

    /// What a type is to ClipEdge. Known: read by ClipEdge, or a standard
    /// public type. Bookkeeping: what a pasteboard or a browser adds beside
    /// a copy. App: an app's own format.
    enum Role: Equatable { case known, bookkeeping, app }

    /// Types ClipEdge reads, by name. Pictures and declared text are known by conformance below.
    static let knownTypes: Set<String> = [
        "public.utf8-plain-text", "public.utf16-external-plain-text", "public.utf16-plain-text", "com.apple.traditional-mac-plain-text",
        "public.rtf", "com.apple.flat-rtfd", "public.html", "com.apple.webarchive", "com.adobe.pdf",
        // A property list conforms only to public.data, and Quick Look is handed it as a typed file.
        "com.apple.property-list",
        "public.file-url", "public.url", "public.url-name", "com.apple.icns", "com.apple.finder.node",
        // Legacy names a Finder copy still carries beside its file URL.
        "NSFilenamesPboardType", "Apple files promise pasteboard type", "Apple URL pasteboard type", "WebURLsWithTitlesPboardType"
    ]
    /// Families ClipEdge reads: Apple's shared vocabulary (public.*) and Finder's
    /// own, plus the Carbon-era flavor codes a Finder copy still carries.
    static let knownPrefixes = ["public.", "com.apple.finder.", "CorePasteboardFlavorType "]
    /// What a pasteboard or a browser adds beside a copy; never an app's own.
    static let bookkeepingTypes: Set<String> = [
        "com.apple.WebKit.custom-pasteboard-data", "com.apple.linkpresentation.metadata", "NeXT smart paste pasteboard type",
        // AppKit writes this beside every file promise, outside the com.apple.pasteboard.* family.
        "com.apple.NSFilePromiseItemMetaData"
    ]
    /// Chromium's and Firefox's notes (a page's custom types, the frame, the
    /// address), nspasteboard.org's markers, file promises, and the dyn.* codes
    /// a pasteboard makes for a legacy name without a UTI.
    static let bookkeepingPrefixes = ["org.chromium.", "org.mozilla.", "org.nspasteboard.", "com.apple.pasteboard.", "dyn."]

    static func role(of type: String) -> Role {
        if bookkeepingTypes.contains(type) || bookkeepingPrefixes.contains(where: type.hasPrefix) { return .bookkeeping }
        if knownTypes.contains(type) || knownPrefixes.contains(where: type.hasPrefix) { return .known }
        // A picture in any format ClipEdge can decode is read, not app data; so is any
        // declared text: Markdown conforms to public.plain-text, an ICS event to public.text.
        if let declared = UTType(type), declared.conforms(to: .image) || declared.conforms(to: .text) { return .known }
        return .app
    }

    // MARK: Naming

    /// Labels that name no app: a type ending in them is named by its vendor.
    private static let genericLabels: Set<String> = ["internal", "pasteboard", "clipboard", "data", "private", "custom"]

    /// Reverse DNS read as people would: past the top level and the vendor,
    /// the next label is the app ("com.apple.iWork.pasteboard" → iWork), its
    /// own capitals kept and a lowercase one capitalized ("notes" → Notes).
    /// A label that is no word (hyphens, digits only) or names no app
    /// ("internal") gives way to the vendor; a type with no dots is "App".
    static func name(forType type: String) -> String {
        let labels = type.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return "App" }
        let vendor = labels[1]
        let app = labels.count >= 3 ? labels[2] : nil
        if let app, isWord(app), !genericLabels.contains(app.lowercased()) { return capitalized(app) }
        return isWord(vendor) ? capitalized(vendor) : "App"
    }
    private static func isWord(_ label: String) -> Bool {
        guard let first = label.first, first.isLetter else { return false }
        return label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
    private static func capitalized(_ label: String) -> String {
        label.contains(where: \.isUppercase) ? label : label.prefix(1).uppercased() + label.dropFirst()
    }
}
