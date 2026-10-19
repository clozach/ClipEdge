import AppKit

/// A self-contained request to an agent for a better preview of one kind of
/// copy: what was copied (formats and sizes, never content), what ClipEdge shows
/// today, Al's note, where the code lives, how to test and what done means.
struct ClipboardPreviewBrief: Equatable {
    /// "iwork", "image", "text": names the project clipedge-preview-<slug>.
    let slug: String
    let heading: String
    /// Bullets under "What was copied".
    let copied: [String]
    let ask: String

    static let defaultAsk = "A preview that shows what this copy holds."
    static let slugLimit = 40

    init(entry: ClipboardEntry, note: String?) {
        slug = Self.slug(for: entry)
        heading = entry.appData.map { "A better preview for \($0.name) data in ClipEdge" } ?? "A better preview for \(Self.kindTitle(entry.kind)) copies in ClipEdge"
        copied = Self.copied(entry)
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ask = trimmed.isEmpty ? Self.defaultAsk : trimmed
    }

    /// The app-data name, else the kind, as a folder name: lowercase letters and
    /// digits with hyphens between, at most 40 characters, never a path.
    static func slug(for entry: ClipboardEntry) -> String { slug(entry.appData?.name ?? kindWord(entry.kind)) }
    static func slug(_ name: String) -> String {
        var words: [String] = [], word = ""
        for character in name.lowercased() {
            if character.isASCII, character.isLetter || character.isNumber { word.append(character) }
            else if !word.isEmpty { words.append(word); word = "" }
        }
        if !word.isEmpty { words.append(word) }
        let joined = String(words.joined(separator: "-").prefix(slugLimit))
        let trimmed = joined.hasSuffix("-") ? String(joined.dropLast()) : joined
        return trimmed.isEmpty ? "clipboard-item" : trimmed
    }

    static func kindWord(_ kind: ClipboardKind) -> String {
        switch kind {
        case .image: return "image"
        case .text, .link, .html: return "text"
        case .figma: return "figma"
        case .file: return "file"
        case .appData(let data): return slug(data.name)
        case .other: return "clipboard-item"
        }
    }

    /// The kind as the heading names it, in ClipEdge's own words; kindWord stays the slug.
    static func kindTitle(_ kind: ClipboardKind) -> String {
        switch kind {
        case .image: return "image"
        case .text, .link, .html: return "text"
        case .figma: return "Figma"
        case .file: return "Finder item"
        case .appData(let data): return "\(data.name) data"
        case .other: return "Clipboard item"
        }
    }

    /// The whole project file, frontmatter first. `project` is the folder's name
    /// when the brief stands beside an earlier one at clipedge-preview-<slug>.
    func document(on day: String, project: String? = nil) -> String {
        let own = "clipedge-preview-\(slug)"
        let name = project ?? own
        let beside = name == own ? "" : " `projects/\(own)/AGENTS.md` already exists and is not an open ClipEdge brief, so this one stands beside it."
        return """
        ---
        type: project
        aliases: [\(name)]
        status: unstarted
        parked: \(day)
        created: \(day)
        bends_toward: [machines, programming]
        ---
        # \(heading)

        Asked from ClipEdge's *Ask for a preview* on \(day). Nothing copied is in this file: formats and sizes only.\(beside)

        ## What was copied

        \(copied.map { "- \($0)" }.joined(separator: "\n"))

        ## The ask

        \(ask)

        ## Where the code lives

        \(Self.codeMap.map { "- \($0)" }.joined(separator: "\n"))

        ## How to test

        - Add a synthetic fixture to `projects/clipedge/src/ClipboardWebCopies.swift` (every byte invented) and to `--demo-web-copies`; never a real clipboard capture.
        - Extend `projects/clipedge/src/tests/AppDataTests.swift` (or the suite nearest the surface) with checks that fail before the change and pass after; `bash tools/test.sh` from `projects/clipedge/src` must pass.
        - Capture before and after per `projects/pixel-reveal/AGENTS.md § Recipe` and build the project's changes deck.

        ## Definition of Done

        The vault's `concepts/definition-of-done.md`: the tests above, the reveal deck, the ClipEdge contract (`projects/clipedge/AGENTS.md`) and `CHANGES.md` reconciled, landed on main with a 🏁 commit.

        """
    }

    /// Appended to an existing project: the newer copy's shape and note.
    func request(on day: String) -> String {
        """

        ## Request on \(day)

        \(copied.map { "- \($0)" }.joined(separator: "\n"))

        \(ask)

        """
    }

    private static let codeMap = [
        "`projects/clipedge/src/ClipboardSummary.swift` — `ClipboardSummary.make` decides what a copy is (its kind, title and detail) from its formats.",
        "`projects/clipedge/src/ClipboardAppData.swift` — `ClipboardAppData` names an app's own format and lists the formats a copy carries.",
        "`projects/clipedge/src/ClipboardMaterializer.swift` — `ClipboardMaterializer.urls(for:)` writes the derived file Quick Look and Preview are handed (`ClipboardTypedPreview` chooses a typed file).",
        "`projects/clipedge/src/ClipboardAttachmentView.swift` — `makePreview` builds the small cursor magnet's preview for each kind.",
        "`projects/clipedge/src/ClipboardHistoryParts.swift` — `ClipboardHistoryCard`, the ⌥⌘\\ window's reading-size card.",
        "`projects/clipedge/src/ClipboardWebCopies.swift` — the synthetic fixtures the demo and the tests share.",
        "`projects/clipedge/src/tests/AppDataTests.swift` — the app-data suite: recognition, tabs, every surface, write-back."
    ]

    /// Formats with their sizes, what is present, and what ClipEdge shows today.
    /// Never the copy's content: no words, addresses, file names or keys.
    private static func copied(_ entry: ClipboardEntry) -> [String] {
        var lines: [String] = []
        lines.append(entry.appData.map { "App: \($0.name) (its own clipboard format)" } ?? "App: none (no app's own format)")
        let values = entry.values
        lines.append("Formats (\(values.count)):")
        for value in values {
            lines.append("  `\(value.type.rawValue)` · \(ByteCountFormatter.string(fromByteCount: Int64(value.data.count), countStyle: .file))")
        }
        lines.append("Picture: " + (entry.isImage ? "yes (\(entry.metadata.facts.first ?? "a picture"))" : "no"))
        let text = entry.readableText.map { ClipboardMetadata.text($0).facts.joined(separator: " · ") }
        lines.append("Text: " + (text.map { "yes (\($0))" } ?? "no"))
        lines.append("Quick Look today: " + quickLookToday(entry))
        lines.append("ClipEdge shows today: " + shownToday(entry))
        return lines
    }

    private static func quickLookToday(_ entry: ClipboardEntry) -> String {
        if !entry.fileURLs.isEmpty { return "the Finder item itself" }
        if entry.values.contains(where: { ClipboardFlavors.isPicture($0.type) }) { return "the picture" }
        if let typed = ClipboardTypedPreview.choice(for: entry) { return "`\(typed.fileName)`, its \(typed.formatName) format, as a typed file" }
        switch entry.kind {
        case .figma: return "ClipEdge's own text card (title, facts, explanation and the link)"
        case .appData: return "ClipEdge's own text card (title, facts, explanation and the formats)"
        case .text, .link, .html: return "a text card of its words"
        case .image, .file: return "the picture"
        case .other: return "a list of its formats (no typed file)"
        }
    }

    private static func shownToday(_ entry: ClipboardEntry) -> String {
        let facts = entry.metadata.facts.joined(separator: " · ")
        if !entry.fileURLs.isEmpty { return "title: the file's name, facts “\(facts)”, card: its thumbnail or icon with its name" }
        switch entry.kind {
        case .appData(let data):
            return "title “\(data.title)”, facts “\(facts)”, card: a box symbol, “\(ClipboardAppData.explanation)” and every format on its own line"
        case .image:
            let caption = entry.appData.map { ", captioned “\($0.title)” and “\(ClipboardAppData.explanation)”" } ?? ""
            return "title “Image”, facts “\(facts)”, card: the picture\(caption)"
        // A lone address is a link however it arrived: its site is never written here.
        case .link: return "title: the address, facts: its site, card: the address"
        case .html(let html) where html.address != nil: return "title: the address, facts: its site, card: the address"
        case .text, .html: return "title: its first words, facts “\(facts)”, card: its words"
        case .figma(let copy):
            let shape = copy.carriedText == nil
                ? "title: how many Figma layers and the file's name, facts “\(copy.editor.name) · \(copy.site)”"
                : "title: its words, facts: where the text came from (the file's name), then “\(copy.editor.name) · \(copy.site)”"
            return "\(shape), card: an explanation and a link to the layers"
        case .file: return "title: the file's name, facts “\(facts)”, card: its thumbnail or icon with its name"
        case .other: return "title “Clipboard item”, facts “\(facts)”, card: a symbol"
        }
    }
}
