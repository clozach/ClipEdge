import AppKit
import PDFKit
import UniformTypeIdentifiers

/// Quick Look's typed files: which flavor is handed over as "Clipboard.<ext>",
/// in which order of preference, what keeps the text card or the picture, the
/// file's name, bytes, permissions and cleanup, the fact line on the card and
/// in the item's info, and a timing guard. Made-up copies only.
@main enum TypedPreviewTests {
    private static var assertions = 0
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError("FAIL: \(message)") }
    }
    private typealias Values = ClipboardWebCopies.Values
    private static func entry(_ values: Values) -> ClipboardEntry {
        let summary = ClipboardSummary.make(from: [ClipboardPayload(values: values)])
        return ClipboardEntry(fingerprint: UUID().uuidString, capturedAt: Date(), payloads: [ClipboardPayload(values: values)],
                              title: summary.title, detail: summary.detail, kind: summary.kind, thumbnail: summary.thumbnail)
    }
    private static func type(_ name: String) -> NSPasteboard.PasteboardType { NSPasteboard.PasteboardType(name) }
    private static let json = Data("{\"fixture\": [1, 2, 3]}".utf8)
    private static let markdown = Data("# Fixture\n\nmade-up words\n".utf8)
    private static let csv = Data("a,b\n1,2\n".utf8)
    private static let plist = Data("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>fixture</key><true/></dict></plist>".utf8)
    private static let swift = Data("let fixture = 1\n".utf8)
    private static let yaml = Data("fixture: 1\n".utf8)
    private static let rtf = ClipboardWebCopies.rtf("ClipEdge fixture rich note")[0].data
    private static let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"24\"><rect width=\"40\" height=\"24\" fill=\"#F6C0A6\"/></svg>".utf8)
    /// An SVG CoreSVG cannot draw: cut off before its closing tag.
    private static let truncated = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"24\"><rect width=\"40\" height=\"24\"/>".utf8)
    private static let words = Data("ClipEdge fixture words".utf8)

    static func main() throws {
        _ = NSApplication.shared
        choiceChecks()
        try fileChecks()
        try previewAppChecks()
        factChecks()
        timingChecks()
        print("PASS: \(assertions) typed-preview assertions; made-up copies")
    }

    // MARK: Which flavor, if any

    private static func choiceChecks() {
        func choice(_ values: Values) -> String? { ClipboardTypedPreview.choice(for: entry(values))?.fileName }
        check(choice([(type("public.json"), json)]) == "Clipboard.json", "a JSON-only copy is handed over as Clipboard.json")
        check(choice([(ClipboardWebCopies.sketchLike, Data([1])), (type("public.json"), json)]) == "Clipboard.json", "app data that also carries JSON is handed over as JSON")
        check(choice([(.rtf, rtf)]) == "Clipboard.rtf", "rich text alone is handed over as Clipboard.rtf")
        check(choice([(.string, words), (.rtf, rtf)]) == "Clipboard.rtf", "text with rich text gets the formatted file")
        check(choice([(.string, words), (.rtf, rtf), (type("public.json"), json)]) == "Clipboard.rtf", "rich text comes before JSON")
        check(choice([(.string, words), (type("public.json"), json)]) == "Clipboard.json", "text with JSON gets the JSON file")
        check(choice([(type("net.daringfireball.markdown"), markdown), (.string, markdown)]) == "Clipboard.md", "Markdown is handed over as Clipboard.md")
        check(choice([(type("public.comma-separated-values-text"), csv)]) == "Clipboard.csv", "CSV as Clipboard.csv")
        check(choice([(type("com.apple.property-list"), plist)]) == "Clipboard.plist", "a property list as Clipboard.plist")
        check(choice([(type("public.xml"), plist)]) == "Clipboard.xml", "XML as Clipboard.xml")
        check(choice([(type("public.json"), json), (type("net.daringfireball.markdown"), markdown)]) == "Clipboard.json", "JSON comes before Markdown")
        check(choice([(type("public.swift-source"), swift), (.string, swift)]) == "Clipboard.swift", "source code is handed over under its own extension")
        check(choice([(type("public.yaml"), yaml), (type("public.swift-source"), swift)]) == "Clipboard.swift", "source code comes before another declared type")
        check(choice([(type("public.yaml"), yaml)]) == "Clipboard.yml", "any other declared type with an extension is handed over")
        check(choice([(.html, Data(ClipboardWebCopies.plainHTML.utf8))]) == nil, "HTML is never a typed file")
        check(choice([(type("public.xhtml"), Data("<html/>".utf8)), (type("com.apple.webarchive"), Data([1]))]) == nil, "nor a web archive or XHTML")
        check(choice([(.html, Data(ClipboardWebCopies.plainHTML.utf8)), (type("public.json"), json)]) == "Clipboard.json", "HTML beside JSON: the JSON, never the HTML")
        check(choice([(.string, words)]) == nil && choice([(.string, Data("https://example.com/fixture".utf8))]) == nil, "plain text and a link keep the text card")
        check(choice([(type("public.plain-text"), words)]) == nil, "a plain-text flavor is the text card already")
        check(choice([(.png, ClipboardWebCopies.picture.png), (type("public.json"), json)]) == nil, "a picture beside JSON stays the picture")
        check(choice([(.pdf, Data([0x25, 0x50, 0x44, 0x46])), (.rtf, rtf)]) == nil, "a PDF stays the PDF")
        check(choice([(type("public.svg-image"), svg)]) == nil, "an SVG is a picture, not a typed file")
        check(choice(ClipboardWebCopies.appDataOnly) == nil, "undeclared app data alone has no typed file")
        check(choice(ClipboardWebCopies.figma()) == nil && choice(ClipboardWebCopies.figma(text: "Fixture caption")) == nil, "Figma copies keep their card")
        check(choice(ClipboardWebCopies.bookkeepingOnly) == nil, "bookkeeping alone has no typed file")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ClipEdge-typed-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("note.json")
        try? json.write(to: file)
        check(choice([(.fileURL, Data(file.absoluteString.utf8)), (type("public.json"), json)]) == nil, "a Finder item is handed over itself")
        let typed = ClipboardTypedPreview.choice(for: entry([(.rtf, rtf)]))!
        check(typed.type == .rtf && typed.ext == "rtf" && typed.formatName == "RTF" && typed.fact == "Quick Look shows its RTF format", "the choice names its flavor, extension and fact")
    }

    // MARK: The derived file

    private static func fileChecks() throws {
        let materializer = ClipboardMaterializer(root: ClipboardMaterializer.defaultRoot.deletingLastPathComponent().appendingPathComponent("ClipEdge-typed-\(UUID().uuidString)"))
        defer { materializer.removeAll() }
        func name(_ values: Values, forPreviewApp: Bool = false) -> String { (try? materializer.urls(for: entry(values), forPreviewApp: forPreviewApp))?[0].lastPathComponent ?? "" }
        let jsonOnly = entry([(type("public.json"), json)])
        let quick = try materializer.urls(for: jsonOnly)
        check(quick.count == 1 && quick[0].lastPathComponent == "Clipboard.json" && (try? Data(contentsOf: quick[0])) == json, "Quick Look gets Clipboard.json holding the flavor's bytes")
        let permissions = (try? FileManager.default.attributesOfItem(atPath: quick[0].path)[.posixPermissions] as? Int) ?? 0
        check(permissions == 0o600 && quick[0].deletingLastPathComponent().lastPathComponent == jsonOnly.id.uuidString,
              "the typed file is private (0600) in the entry's own folder")
        try materializer.remove(jsonOnly)
        check(!FileManager.default.fileExists(atPath: quick[0].path), "removing the entry removes its typed file")
        check(name([(ClipboardWebCopies.sketchLike, Data([1])), (type("public.json"), json)]) == "Clipboard.json", "app data with JSON previews as JSON, not as its text card")
        let richOnly = entry([(.rtf, rtf)])
        let rich = try materializer.urls(for: richOnly)
        check(rich[0].lastPathComponent == "Clipboard.rtf" && (try? Data(contentsOf: rich[0])) == rtf, "rich text alone gets Clipboard.rtf, the flavor byte for byte")
        check(name([(.string, words), (.rtf, rtf)]) == "Clipboard.rtf", "text with rich text gets the formatted file")
        check(name([(type("net.daringfireball.markdown"), markdown), (.string, markdown)]) == "Clipboard.md", "Markdown gets Clipboard.md")
        check(name([(.html, Data(ClipboardWebCopies.plainHTML.utf8))]) == "Clipboard.txt", "an HTML-only copy keeps the text card")
        check(name([(.png, ClipboardWebCopies.picture.png), (type("public.json"), json)]) == "Clipboard.png", "a picture with JSON stays the picture")
        check(name(ClipboardWebCopies.appDataOnly) == "Fixture data.txt", "undeclared app data keeps its text card")
        check(name(ClipboardWebCopies.figma()) == "Figma layer.txt", "Figma layers keep their card")
        check(name([(.string, words)]) == "Clipboard.txt", "plain text keeps the text card")
        let folder = rich[0].deletingLastPathComponent()
        let written = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        check(written == ["Clipboard.rtf"], "nothing else is written beside the typed file (\(written))")
        let flat = NSAttributedString(string: "ClipEdge fixture flat note").rtfd(from: NSRange(location: 0, length: 26), documentAttributes: [:])!
        check(name([(.rtfd, flat)]) == "Clipboard.txt", "RTFD alone keeps the text card: Quick Look has no single-file RTFD previewer")

        // SVG is drawn by Quick Look's web renderer: it is handed over as pixels.
        let vector = entry([(type("public.svg-image"), svg)])
        check(vector.kind == .image, "an SVG is a picture")
        let pixels = try materializer.urls(for: vector)
        let image = NSImage(contentsOf: pixels[0])
        check(pixels[0].lastPathComponent == "Clipboard.png" && image != nil, "Quick Look gets Clipboard.png for an SVG, never the SVG itself")
        let svgFiles = (try? FileManager.default.contentsOfDirectory(atPath: pixels[0].deletingLastPathComponent().path)) ?? []
        check(!svgFiles.contains { $0.hasSuffix("svg") } && (image?.size.width ?? 0) >= 40, "no SVG file is written, and the pixels are at least the picture's size")
        // An SVG CoreSVG cannot draw is never handed over as Clipboard.svg, which Quick Look would give its web renderer.
        for (label, bytes) in [("truncated", truncated), ("empty", Data())] {
            let broken = try materializer.urls(for: entry([(type("public.svg-image"), bytes)]))
            let files = (try? FileManager.default.contentsOfDirectory(atPath: broken[0].deletingLastPathComponent().path)) ?? []
            check(broken[0].lastPathComponent == "Clipboard formats.txt" && !files.contains { $0.hasSuffix("svg") }, "a \(label) SVG gets the inventory text, and no SVG file is written (\(files))")
        }
        let brokenBesideText = try materializer.urls(for: entry([(type("public.svg-image"), truncated), (.string, words)]))
        check(brokenBesideText[0].lastPathComponent == "Clipboard.txt", "a broken SVG beside text keeps the text card")
    }

    /// ⌘O: Preview opens pictures and PDFs; everything else is its page of text, as before.
    private static func previewAppChecks() throws {
        let materializer = ClipboardMaterializer(root: ClipboardMaterializer.defaultRoot.deletingLastPathComponent().appendingPathComponent("ClipEdge-typed-page-\(UUID().uuidString)"))
        defer { materializer.removeAll() }
        let rich = try materializer.urls(for: entry([(.rtf, rtf)]), forPreviewApp: true)
        check(rich[0].lastPathComponent == "Clipboard.pdf" && PDFDocument(url: rich[0])?.string?.contains("fixture rich note") == true, "⌘O on rich text opens its words as a page")
        let jsonPage = try materializer.urls(for: entry([(type("public.json"), json)]), forPreviewApp: true)
        check(jsonPage[0].pathExtension == "pdf" && PDFDocument(url: jsonPage[0])?.string?.contains("public.json") == true, "⌘O on a JSON-only copy opens its inventory as a page, as before")
        let picturePage = try materializer.urls(for: entry([(.png, ClipboardWebCopies.picture.png), (type("public.json"), json)]), forPreviewApp: true)
        check(picturePage[0].lastPathComponent == "Clipboard.png", "⌘O on a picture with JSON opens the picture")
        let vectorPage = try materializer.urls(for: entry([(type("public.svg-image"), svg)]), forPreviewApp: true)
        check(vectorPage[0].lastPathComponent == "Clipboard.png", "⌘O on an SVG opens its pixels")
        let brokenPage = try materializer.urls(for: entry([(type("public.svg-image"), truncated)]), forPreviewApp: true)
        check(brokenPage[0].lastPathComponent == "Clipboard formats.pdf", "⌘O on a broken SVG opens its inventory as a page")
    }

    // MARK: The fact line

    private static func factChecks() {
        let rich = entry([(.string, words), (.rtf, rtf)]), plain = entry([(.string, words)]), picture = entry([(.png, ClipboardWebCopies.picture.png)])
        let card = ClipboardHistoryCard(frame: NSRect(x: 0, y: 0, width: 420, height: 380))
        card.show(rich); card.layoutSubtreeIfNeeded()
        check(card.edgeText.hasSuffix("\nQuick Look shows its RTF format") && card.edgeText.contains("words"), "the card says Quick Look shows the RTF format, after the facts")
        card.show(plain); card.layoutSubtreeIfNeeded()
        check(!card.edgeText.contains("Quick Look"), "plain text's card says nothing of the kind")
        card.show(picture); card.layoutSubtreeIfNeeded()
        check(!card.edgeText.contains("Quick Look"), "nor a picture's")
        let tile = ClipboardTile(entry: rich, style: .row, keymap: .drawer)
        let lines = tile.tooltipDetails.components(separatedBy: "\n")
        check(lines.dropLast().last == "Quick Look shows its RTF format" && lines.last == rich.fullDateTimeStamp, "the item's info carries the line before the date")
        check(!ClipboardTile(entry: plain, style: .row, keymap: .drawer).tooltipDetails.contains("Quick Look"), "plain text's info does not")
        check(rich.edgeText == rich.metadata.line, "the tile's own edge line stays the facts alone")
    }

    /// The choice runs for every card shown and every item's info; it must stay cheap.
    private static func timingChecks() {
        let many = (0..<200).map { index -> ClipboardEntry in
            entry([(type("com.clipedge.fixture.format\(index)"), Data([1])), (.string, words), (.rtf, rtf), (type("public.json"), json)]
                  + (0..<20).map { (type("com.clipedge.fixture.other\($0)"), Data([2])) })
        }
        let started = ProcessInfo.processInfo.systemUptime
        let choices = many.map { ClipboardTypedPreview.choice(for: $0)?.ext }
        let seconds = ProcessInfo.processInfo.systemUptime - started
        check(choices.allSatisfy { $0 == "rtf" } && seconds < 1, "two hundred choices over 24 flavors each take under a second (\(seconds) s)")
    }
}
