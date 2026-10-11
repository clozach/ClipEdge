import Foundation

/// Layers copied in Figma. The page puts them on the clipboard as HTML holding
/// two hidden parts: a short description of the copy (figmeta: base64 JSON)
/// and the layers themselves (a buffer only Figma reads). ClipEdge reads the
/// description and the page's address and never decodes the buffer, so this
/// stays cheap enough for every saved item at launch.
///
/// The file key is the file's address: it goes into the link and nowhere else,
/// and the descriptions below leave it out so it never reaches a log.
struct ClipboardFigmaCopy: Equatable {
    /// Figma's editor that made the copy (figmeta's editorType).
    enum Editor: Equatable {
        case design, figJam, slides, devMode, sites, buzz, make, draw, other

        init(editorType: String?) {
            switch editorType {
            case "design": self = .design
            case "whiteboard": self = .figJam
            case "slides": self = .slides
            case "dev_handoff": self = .devMode
            case "sites": self = .sites
            case "cooper": self = .buzz
            case "figmake": self = .make
            case "illustration": self = .draw
            default: self = .other
            }
        }
        var name: String {
            switch self {
            case .design: return "Figma Design"
            case .figJam: return "FigJam"
            case .slides: return "Figma Slides"
            case .devMode: return "Figma Dev Mode"
            case .sites: return "Figma Sites"
            case .buzz: return "Figma Buzz"
            case .make: return "Figma Make"
            case .draw: return "Figma Draw"
            case .other: return "Figma"
            }
        }
        /// The link's first path segment, and the mode an editor inside Design adds.
        /// Draw's `m=draw` follows Figma's desktop routing table (inferred, unpublished).
        var route: (segment: String, mode: String?) {
            switch self {
            case .design, .other: return ("design", nil)
            case .figJam: return ("board", nil)
            case .slides: return ("slides", nil)
            case .devMode: return ("design", "dev")
            case .sites: return ("site", nil)
            case .buzz: return ("buzz", nil)
            case .make: return ("make", nil)
            case .draw: return ("design", "draw")
            }
        }
    }

    /// Copied layers, at least one, by node ID; or a cut, whose layers no longer
    /// exist in the file, so there is nothing to point at.
    enum Selection: Equatable {
        case layers(first: String, more: [String])
        case cut
        /// figmeta's dataType names something other than layers (a variable,
        /// copied properties): unobserved, so no claim about layers or a cut.
        case otherData
    }

    /// What an app other than Figma receives when the whole copy is pasted.
    enum Elsewhere: Equatable {
        case nothing
        /// The copy's plain-text flavor, as it pastes; never empty or only spaces.
        case text(String)

        init(text: String?) {
            if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { self = .text(text) } else { self = .nothing }
        }
    }

    let editor: Editor
    /// The Figma host that made the copy, such as www.figma.com.
    let host: String
    /// The page address's name for the file; Figma writes spaces as hyphens.
    let slug: String?
    let selection: Selection
    let elsewhere: Elsewhere
    /// Back to the copied layers (the first, for several), or to the file after a cut.
    /// Built from scratch, so a share token, the viewport or anything else in
    /// the page's address never comes along.
    let link: URL

    /// Nil unless the HTML carries both Figma markers and a readable description;
    /// a damaged description is not guessed at.
    init?(html: Data, sourceURL: String?, elsewhere: Elsewhere) {
        guard let meta = Self.figmeta(in: html),
              let fileKey = meta["fileKey"] as? String, Self.isFileKey(fileKey),
              let host = (meta["environment"] as? String)?.lowercased(), Self.isFigmaHost(host) else { return nil }
        // Only a scene copy lists layers; a copy without a dataType is read as one.
        let selection: Selection
        if meta["dataType"] == nil || (meta["dataType"] as? String) == "scene" {
            guard let nodes = meta["selectedNodeData"] as? String, let layers = Self.selection(nodes) else { return nil }
            selection = layers
        } else { selection = .otherData }
        let editor = Editor(editorType: meta["editorType"] as? String)
        let slug = Self.slug(sourceURL: sourceURL, fileKey: fileKey)
        guard let link = Self.link(host: host, editor: editor, fileKey: fileKey, slug: slug, selection: selection) else { return nil }
        self.editor = editor
        self.host = host
        self.slug = slug
        self.selection = selection
        self.elsewhere = elsewhere
        self.link = link
    }

    /// Approximate: Figma writes spaces as hyphens, so " - " arrives as "---" and is put back;
    /// any other hyphen reads as a space, a real one included.
    var fileName: String? {
        guard let slug else { return nil }
        let name = slug.components(separatedBy: "---")
            .map { $0.replacingOccurrences(of: "-", with: " ") }
            .joined(separator: " - ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return name.isEmpty ? nil : name
    }
    var site: String { ClipboardFlavors.site(host) }
    var layerCount: Int? { if case .layers(_, let more) = selection { return 1 + more.count }; return nil }
    /// The text other apps receive, as it pastes; nil when they receive nothing.
    var carriedText: String? { if case .text(let text) = elsewhere { return text }; return nil }

    private var from: String { fileName.map { " from \($0)" } ?? "" }
    /// What the copy is as Figma sees it: "1 Figma layer from …", "Figma layers cut from …".
    private var layersTitle: String {
        switch selection {
        case .layers(_, let more): return more.isEmpty ? "1 Figma layer\(from)" : "\(1 + more.count) Figma layers\(from)"
        case .cut: return fileName.map { "Figma layers cut from \($0)" } ?? "Figma layers, cut"
        case .otherData: return "Figma clipboard data\(from)"
        }
    }
    /// A copy that carries text is titled by its words, as a text item is.
    var title: String { carriedText.map(ClipboardSummary.title) ?? layersTitle }
    /// Where a copy titled by its words came from: "Figma text from …" for one layer.
    var origin: String {
        if carriedText != nil, case .layers(_, let more) = selection, more.isEmpty { return "Figma text\(from)" }
        return layersTitle
    }
    /// The quiet facts: where text came from, which editor, which site. Never a path or the file key.
    var facts: [String] { (carriedText == nil ? [] : [origin]) + [editor.name, site] }
    /// The one explanation every surface shows: the history card, Quick Look,
    /// the held magnet and an item's info. No key: ⌃⌘V pastes whatever is on
    /// the clipboard, which need not be the item on screen.
    var explanation: String {
        let carriesText = carriedText != nil
        switch selection {
        case .cut:
            return "Cut from the file. Paste into Figma to put the layers back; "
                + (carriesText ? "other apps receive their text. Send to › Open in opens a link to the file." : "a plain-text paste gives a link to the file.")
        case .otherData:
            return "Paste into Figma to use it; "
                + (carriesText ? "other apps receive its text. Send to › Open in opens a link to the file." : "a plain-text paste gives a link to the file.")
        case .layers(_, let more):
            let (layers, them, their) = more.isEmpty ? ("this layer", "it", "its") : ("these layers", "them", "their")
            return carriesText
                ? "Paste into Figma to get \(layers) back, editable. Other apps receive \(their) text; Send to › Open in opens a link to \(them)."
                : "Paste into Figma to get \(layers) back, editable. Other apps receive nothing from \(them); a plain-text paste gives a link to \(them) instead."
        }
    }
    /// For a small magnet without room for the explanation. A held item is on
    /// the clipboard, so here ⌃⌘V is the right key.
    var shortNote: String {
        let several = (layerCount ?? 1) > 1
        switch (selection, carriedText != nil) {
        case (.cut, false): return "Cut. Paste into Figma to put it back."
        case (.cut, true): return "Cut. Paste into Figma to put it back; ⌃⌘V pastes its text."
        case (.otherData, true): return "Paste into Figma to use it. ⌃⌘V pastes its text."
        case (.layers, true): return several ? "Paste into Figma for the layers. ⌃⌘V pastes their text." : "Paste into Figma for the layer. ⌃⌘V pastes its text."
        case (.layers, false), (.otherData, false): return "Paste into Figma. ⌃⌘V pastes a link."
        }
    }
    /// The words, else the title, over the explanation, where a surface shows the link apart.
    var summary: String { "\(carriedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? title)\n\(explanation)" }
    var searchTerms: [String] { [fileName ?? "", "Figma", editor.name, site] }

    // MARK: Reading the copy

    /// The description opens near the start and the layers follow it; the buffer can run to megabytes.
    static let markerWindow = 8 << 10
    /// The description grows by about 20 bytes per copied layer; this bounds it at about 50,000.
    static let figmetaLimit = 1 << 20

    private static func figmeta(in html: Data) -> [String: Any]? {
        let start = html.startIndex
        guard let open = html.range(of: Data("(figmeta)".utf8), in: start..<min(html.endIndex, start + markerWindow)),
              let close = html.range(of: Data("(/figmeta)".utf8), in: open.upperBound..<min(html.endIndex, open.upperBound + figmetaLimit)),
              html.range(of: Data("<!--(figma)".utf8), in: close.upperBound..<min(html.endIndex, close.upperBound + markerWindow)) != nil,
              let json = Data(base64Encoded: Data(html[open.upperBound..<close.lowerBound])) else { return nil }
        return (try? JSONSerialization.jsonObject(with: json)) as? [String: Any]
    }
    /// Figma's file keys are 22 to 128 letters and digits.
    private static func isFileKey(_ key: String) -> Bool {
        (22...128).contains(key.count) && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
    static func isFigmaHost(_ host: String) -> Bool {
        (host == "figma.com" || host.hasSuffix(".figma.com"))
            && host.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }
    /// One entry per top-level layer, `<node ID>|…`; only the ID is public. Empty means a cut.
    private static func selection(_ nodes: String) -> Selection? {
        if nodes.isEmpty { return .cut }
        let ids = nodes.split(separator: ",").compactMap { entry -> String? in
            let id = entry.prefix { $0 != "|" }.trimmingCharacters(in: .whitespaces)
            return id.isEmpty ? nil : id
        }
        guard let first = ids.first else { return nil }
        return .layers(first: first, more: Array(ids.dropFirst()))
    }
    /// The file's name segment, only from a Figma page address for this same file.
    /// Its node-id is not used: it is the tab's address, which lags the selection.
    private static func slug(sourceURL: String?, fileKey: String) -> String? {
        guard let sourceURL, let url = URL(string: sourceURL), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(), isFigmaHost(host) else { return nil }
        let segments = url.pathComponents.filter { $0 != "/" }
        guard segments.count >= 3, segments[1] == fileKey, !segments[2].isEmpty, !segments[2].contains("/") else { return nil }
        return segments[2]
    }
    private static func link(host: String, editor: Editor, fileKey: String, slug: String?, selection: Selection) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/" + ([editor.route.segment, fileKey] + (slug.map { [$0] } ?? [])).joined(separator: "/")
        var query: [URLQueryItem] = []
        if case .layers(let first, _) = selection { query.append(URLQueryItem(name: "node-id", value: first.replacingOccurrences(of: ":", with: "-"))) }
        if let mode = editor.route.mode { query.append(URLQueryItem(name: "m", value: mode)) }
        components.queryItems = query.isEmpty ? nil : query
        return components.url
    }
}

/// Printing a copy names what it is, never the file's address.
extension ClipboardFigmaCopy: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String {
        let what: String
        switch selection {
        case .layers(_, let more): what = more.isEmpty ? "1 layer" : "\(1 + more.count) layers"
        case .cut: what = "cut"
        case .otherData: what = "other data"
        }
        return "Figma copy (\(editor.name), \(what))"
    }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["editor": editor.name, "layers": layerCount as Any]) }
}
