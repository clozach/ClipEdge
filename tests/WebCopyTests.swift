import AppKit
import PDFKit

/// Copies from web pages: Figma layers, HTML-only and rich-only text, and a
/// page's address. Every copy is made up (ClipboardWebCopies); named boards only.
@main enum WebCopyTests {
    private static var assertions = 0
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError("FAIL: \(message)") }
    }
    private typealias Values = ClipboardWebCopies.Values
    private static func entry(_ values: Values, at date: Date = Date()) -> ClipboardEntry {
        let summary = ClipboardSummary.make(from: [ClipboardPayload(values: values)])
        return ClipboardEntry(fingerprint: UUID().uuidString, capturedAt: date, payloads: [ClipboardPayload(values: values)],
                              title: summary.title, detail: summary.detail, kind: summary.kind, thumbnail: summary.thumbnail)
    }
    private static func figma(_ entry: ClipboardEntry) -> ClipboardFigmaCopy? {
        if case .figma(let copy) = entry.kind { return copy }; return nil
    }
    private static func html(_ entry: ClipboardEntry) -> ClipboardHTMLText? {
        if case .html(let text) = entry.kind { return text }; return nil
    }
    private static func text(_ html: String, limit: Int = ClipboardHTMLText.summaryLimit) -> String? {
        ClipboardHTMLText(html: Data(html.utf8), limit: limit)?.text
    }
    private static let key = ClipboardWebCopies.fileKey
    private static let page = "https://www.figma.com/design/\(key)/ClipEdge-Fixture-Board"

    static func main() throws {
        _ = NSApplication.shared
        figmaChecks()
        htmlChecks()
        entryChecks()
        try surfaceChecks()
        storeChecks()
        timingChecks()
        print("PASS: \(assertions) web-copy assertions (Figma layers, HTML-only and rich text, page addresses); made-up copies, named boards")
    }

    private static func figmaChecks() {
        let design = entry(ClipboardWebCopies.figma())
        guard let copy = figma(design) else { fatalError("FAIL: a Figma layer copy is recognized") }
        check(design.title == "1 Figma layer from ClipEdge Fixture Board", "one layer, named with its file (\(design.title))")
        check(copy.facts == ["Figma Design", "figma.com"] && design.metadata.facts == ["Figma Design", "figma.com"], "facts: the editor and the site, no path")
        check(design.edgeText == "Figma Design · figma.com", "the row's edge shows those facts, not type names")
        check(copy.link.absoluteString == page + "?node-id=1-2", "the link points at the copied layer (\(copy.link.absoluteString))")
        check(!copy.link.absoluteString.contains("t=") && !copy.link.absoluteString.contains("viewport") && !copy.link.absoluteString.contains("9-9"),
              "the link drops the share token and the viewport, and ignores the tab's lagging node-id")
        check(design.kind.iconName == "square.3.layers.3d" && NSImage(systemSymbolName: design.kind.iconName, accessibilityDescription: nil) != nil,
              "Figma layers show a layers symbol")
        check(copy.explanation == "Paste into Figma to get this layer back, editable. Other apps receive nothing from it; a plain-text paste gives a link to it instead.",
              "one layer: the explanation says what pastes where, naming no key that pastes the clipboard instead")
        check(copy.shortNote == "Paste into Figma. ⌃⌘V pastes a link." && copy.carriedText == nil, "the held magnet's short note may name ⌃⌘V: a held item is on the clipboard")

        let five = entry(ClipboardWebCopies.demo[1].values)
        check(five.title == "5 Figma layers from ClipEdge Fixture Board" && figma(five)?.layerCount == 5, "five layers are counted")
        check(figma(five)?.link.absoluteString == page + "?node-id=1-2", "several layers link to the first")
        check(figma(five)?.explanation == "Paste into Figma to get these layers back, editable. Other apps receive nothing from them; a plain-text paste gives a link to them instead.",
              "several layers: the explanation as written")

        let cut = entry(ClipboardWebCopies.figma(nodes: ""))
        check(cut.title == "Figma layers cut from ClipEdge Fixture Board" && figma(cut)?.layerCount == nil, "an empty selection is a cut")
        check(figma(cut)?.link.absoluteString == page, "a cut links to the file, with no layer to point at")
        check(figma(cut)?.explanation == "Cut from the file. Paste into Figma to put the layers back; a plain-text paste gives a link to the file."
              && figma(cut)?.shortNote == "Cut. Paste into Figma to put it back.", "a cut says it was cut and pastes back into Figma, claiming no only copy")

        let board = entry(ClipboardWebCopies.figma(editorType: "whiteboard", route: "board", nodes: "4:7|6|0|0"))
        check(board.metadata.facts == ["FigJam", "figma.com"] && figma(board)?.link.absoluteString == "https://www.figma.com/board/\(key)/ClipEdge-Fixture-Board?node-id=4-7",
              "FigJam copies say FigJam and link to the board")
        let bare = entry(ClipboardWebCopies.figma(source: false))
        check(bare.title == "1 Figma layer" && figma(bare)?.link.absoluteString == "https://www.figma.com/design/\(key)?node-id=1-2",
              "without the page's address: no file name, and a link without one")
        check(entry(ClipboardWebCopies.figma(nodes: "", source: false)).title == "Figma layers, cut", "a cut without a file name")
        for blank in ["", " \n\t "] {
            let emptyText = entry(ClipboardWebCopies.figma(text: blank))
            check(figma(emptyText)?.elsewhere == .nothing && emptyText.title == design.title, "an empty or blank text flavor is still Figma layers, never Empty text")
        }

        // A copy that carries text reads as that text and keeps what Figma said about it.
        let textLayer = entry(ClipboardWebCopies.figma(text: "  Fixture   caption\n"))
        guard let words = figma(textLayer) else { fatalError("FAIL: a text layer's copy is still Figma layers") }
        check(words.carriedText == "  Fixture   caption\n" && textLayer.title == "Fixture caption" && words.title == "Fixture caption",
              "a text layer's copy is titled by its words, spaces collapsed as a text item's are (\(textLayer.title))")
        check(words.facts == ["Figma text from ClipEdge Fixture Board", "Figma Design", "figma.com"] && textLayer.metadata.facts == words.facts
              && textLayer.edgeText == "Figma text from ClipEdge Fixture Board · Figma Design · figma.com", "its facts lead with where it came from")
        check(words.explanation == "Paste into Figma to get this layer back, editable. Other apps receive its text; Send to › Open in opens a link to it."
              && words.shortNote == "Paste into Figma for the layer. ⌃⌘V pastes its text.", "it says Figma gets the layer, other apps its text, and where the link is")
        check(words.link == copy.link && words.summary.hasPrefix("Fixture   caption\n"), "it keeps its link; its summary leads with its words")
        check(textLayer.matches("caption") && textLayer.matches("Fixture Board"), "a text layer's words and file are searchable")
        let long = String(repeating: "Fixture words ", count: 20)
        check(entry(ClipboardWebCopies.figma(text: long)).title == String(long.trimmingCharacters(in: .whitespaces).prefix(90)), "a long text's title is its first 90 characters")
        let fiveWords = entry(ClipboardWebCopies.figma(nodes: "1:2|23|0|0,1:3|23|0|0", text: "Two captions"))
        check(fiveWords.title == "Two captions" && figma(fiveWords)?.facts.first == "2 Figma layers from ClipEdge Fixture Board"
              && figma(fiveWords)?.explanation.contains("Other apps receive their text") == true && figma(fiveWords)?.shortNote == "Paste into Figma for the layers. ⌃⌘V pastes their text.",
              "several layers that carry text name their count in the facts")
        let cutWords = entry(ClipboardWebCopies.figma(nodes: "", text: "Cut caption"))
        check(cutWords.title == "Cut caption" && figma(cutWords)?.facts.first == "Figma layers cut from ClipEdge Fixture Board"
              && figma(cutWords)?.explanation == "Cut from the file. Paste into Figma to put the layers back; other apps receive their text. Send to › Open in opens a link to the file.",
              "a cut that carries text is titled by it and says it was cut")

        // Variables and copied properties are not layers: no claim about layers or a cut.
        let variable = entry(ClipboardWebCopies.figma(nodes: "", dataType: "variable"))
        check(variable.title == "Figma clipboard data from ClipEdge Fixture Board" && figma(variable)?.layerCount == nil
              && !(figma(variable)?.explanation.contains("cut") ?? true) && figma(variable)?.link.absoluteString == page,
              "a non-scene copy makes no claim about layers or a cut")
        check(figma(variable)?.explanation == "Paste into Figma to use it; a plain-text paste gives a link to the file." && "\(variable.kind)".contains("other data"),
              "a non-scene copy says to paste it into Figma")
        check(entry(ClipboardWebCopies.figma(dataType: "style_properties_fill")).title == "Figma clipboard data from ClipEdge Fixture Board",
              "node IDs on a non-scene copy are not read as layers")
        let noType = #"{"fileKey":"\#(key)","editorType":"design","environment":"www.figma.com","selectedNodeData":"1:2|0"}"#
        check(figma(entry(ClipboardWebCopies.figma(figmeta: Data(noType.utf8).base64EncodedString())))?.layerCount == 1, "a description without a dataType reads as layers")

        // Figma writes spaces as hyphens and " - " as "---".
        let dashed = figma(entry(ClipboardWebCopies.figma(slug: "Design-System---v2")))
        check(dashed?.fileName == "Design System - v2" && dashed?.title == "1 Figma layer from Design System - v2", "a file name's ' - ' comes back (\(dashed?.title ?? "nil"))")
        check(figma(entry(ClipboardWebCopies.figma(slug: "A--B")))?.fileName == "A B", "repeated hyphens read as one space")

        let routes: [(String, String, String)] = [("design", "Figma Design", "/design/"), ("whiteboard", "FigJam", "/board/"),
            ("slides", "Figma Slides", "/slides/"), ("dev_handoff", "Figma Dev Mode", "/design/"), ("sites", "Figma Sites", "/site/"),
            ("cooper", "Figma Buzz", "/buzz/"), ("figmake", "Figma Make", "/make/"), ("illustration", "Figma Draw", "/design/"),
            ("weave", "Figma", "/design/")]
        for (type, name, path) in routes {
            let made = figma(entry(ClipboardWebCopies.figma(editorType: type, source: false)))
            check(made?.editor.name == name && made?.link.path.hasPrefix(path) == true, "editor \(type) reads as \(name) and links under \(path)")
        }
        check(figma(entry(ClipboardWebCopies.figma(editorType: "dev_handoff", source: false)))?.link.query == "node-id=1-2&m=dev", "Dev Mode links open in Dev Mode")

        // Nothing is guessed: a damaged or foreign description is not Figma layers.
        let damaged = entry(ClipboardWebCopies.figma(figmeta: "not-base64-json"))
        check(damaged.kind == .other && damaged.title == "Clipboard item" && damaged.metadata.facts.isEmpty && damaged.metadata.site == "figma.com"
              && damaged.edgeText == "from figma.com" && damaged.plainTextForPaste.isEmpty,
              "a damaged description is an unknown item: only the site it came from, nothing about layers, and nothing to paste (\(damaged.metadata))")
        check(damaged.detail == "public.html, org.chromium.source-url", "an unknown item names its standard type first and hides Chromium's frame token (\(damaged.detail))")
        func meta(_ json: String) -> Values { ClipboardWebCopies.figma(figmeta: Data(json.utf8).base64EncodedString()) }
        let foreignHost = #"{"fileKey":"\#(key)","editorType":"design","environment":"figma.example.com","selectedNodeData":"1:2|0"}"#
        let shortKey = #"{"fileKey":"SHORT","editorType":"design","environment":"www.figma.com","selectedNodeData":"1:2|0"}"#
        let noIDs = #"{"fileKey":"\#(key)","editorType":"design","environment":"www.figma.com","selectedNodeData":",|9|0,"}"#
        let noSelection = #"{"fileKey":"\#(key)","editorType":"design","environment":"www.figma.com"}"#
        for (json, why) in [(foreignHost, "a host that is not Figma's"), (shortKey, "a malformed file key"), (noIDs, "a selection without layer IDs"), (noSelection, "no selection at all")] {
            check(figma(entry(meta(json))) == nil, "\(why) is not read as Figma layers")
        }
        let otherFile = ClipboardWebCopies.figma().map { value -> (type: NSPasteboard.PasteboardType, data: Data) in
            value.type == ClipboardFlavors.sourceURL ? (value.type, Data("https://www.figma.com/design/ANOTHERFILEKEY000000001/Other-Board".utf8)) : value
        }
        check(figma(entry(otherFile))?.fileName == nil, "another file's page does not name this copy")
        let foreignPage = ClipboardWebCopies.figma().map { value -> (type: NSPasteboard.PasteboardType, data: Data) in
            value.type == ClipboardFlavors.sourceURL ? (value.type, Data("https://example.com/design/\(key)/Lookalike-Board".utf8)) : value
        }
        check(figma(entry(foreignPage))?.fileName == nil, "a non-Figma page does not name this copy")
        let padded = Values([(.html, Data((String(repeating: " ", count: ClipboardFigmaCopy.markerWindow) + String(decoding: ClipboardWebCopies.figma()[0].data, as: UTF8.self)).utf8))])
        check(figma(entry(padded)) == nil, "a description that opens past the first 8 KB is not looked for")
        let many = (0..<1000).map { "188:\(100 + $0)|23|0|0" }.joined(separator: ",")
        let thousand = figma(entry(ClipboardWebCopies.figma(nodes: many)))
        check(thousand?.layerCount == 1000 && thousand?.link.query == "node-id=188-100", "a 1,000-layer copy, whose description runs past 8 KB, is still Figma layers")

        // The file key is the file's address: it never appears in a description.
        for shown in [String(describing: copy), String(reflecting: copy), "\(design.kind)", String(describing: Mirror(reflecting: design.kind).children.map(\.value))] {
            check(!shown.contains(key), "printing a Figma copy leaves out its file key (\(shown))")
        }
        var dumped = ""
        dump(design.kind, to: &dumped)
        check(!dumped.contains(key) && !dumped.isEmpty, "dumping a Figma copy leaves out its file key")
    }

    private static func htmlChecks() {
        check(text(ClipboardWebCopies.plainHTML) == "ClipEdge fixture & HTML-only copy", "tags, scripts and styles are dropped and entities decoded")
        check(text("&lt;tag&gt; &quot;q&quot; &#39;s&#39; &apos;a&apos; a&nbsp;b &#x263A; &#9731;") == "<tag> \"q\" 's' 'a' a b ☺ ☃", "common and numeric entities decode")
        check(text("&bogus; & alone &#0; &#xZZ;") == "&bogus; & alone &#0; &#xZZ;", "an unknown entity or a lone ampersand stays as written")
        check(text("<p>one</p><p>two</p><ul><li>a</li><li>b</li></ul>line<br>break<br><br>gap") == "one\ntwo\na\nb\nline\nbreak\n\ngap", "block tags and breaks become lines")
        check(text("<p>  spaced \n\t out  </p><div>\n</div><p>next</p>") == "spaced out\nnext", "runs of spaces collapse as a browser shows them")
        check(text("<pre>a\n  b</pre>after") == "a\n  b\nafter", "preformatted text keeps its spaces")
        check(text("<!-- hidden --><span title=\"a>b\" data-x='c>d'>shown</span>") == "shown", "comments are dropped and a quoted '>' does not end a tag")
        check(text("<SCRIPT type=x>bad()</SCRIPT ><Style>p{}</style><title>Tab</title>ok") == "ok", "scripts, styles and titles are dropped in any case")
        check(text("a < b and 3<4") == "a < b and 3<4", "a less-than sign that opens no tag is text")
        check(text("<p>naïve café 👩‍👩‍👧</p>") == "naïve café 👩‍👩‍👧", "characters beyond ASCII pass through")
        check(text("<!-- never closed <p>lost</p>") == nil && text("") == nil && text("<span></span> &nbsp; <br>") == nil, "nothing readable is no text at all")
        // A quote opens a value only after '=', as in a browser; an apostrophe in a bare value is just a letter.
        check(text("<p>start</p><img alt=Bob's>visible<p>it's end</p>") == "start\nvisible\nit's end", "an apostrophe in an unquoted value hides nothing")
        check(text("<a href=x title=it's>link</a> more text") == "link more text", "an unquoted value with an apostrophe ends at '>'")
        check(text("<span a = \"x>y\" b='c'>quoted</span>") == "quoted", "a quoted value after '=' and spaces may hold '>'")
        for empty in ["<p>one</p><!--><p>two</p>", "<p>one</p><!---><p>two</p>", "<p>one</p><!-- x --!><p>two</p>"] {
            check(text(empty) == "one\ntwo", "a comment ends where a browser ends it (\(empty))")
        }
        let utf16 = Data([0xFF, 0xFE]) + "<p>wide</p>".data(using: .utf16LittleEndian)!
        check(ClipboardHTMLText(html: utf16)?.text == "wide", "UTF-16 HTML with a byte-order mark reads")
        let cut = ClipboardHTMLText(html: Data("<p>ééé</p>".utf8), limit: 6)
        check(cut?.text == "é" && cut?.isComplete == false, "a limit inside a character drops the partial character (\(cut?.text ?? "nil"))")
        check(ClipboardHTMLText(html: Data("<p>ééé</p>".utf8))?.isComplete == true, "a short copy is read whole")
    }

    private static func entryChecks() {
        let page = entry(ClipboardWebCopies.html(ClipboardWebCopies.plainHTML))
        check(html(page)?.text == "ClipEdge fixture & HTML-only copy" && page.title == "ClipEdge fixture & HTML-only copy", "HTML-only text is titled by its words")
        check(page.detail == "33 characters" && page.metadata.facts == ["5 words", "33 characters"], "HTML-only text has word and character counts")
        check(page.readableText == "ClipEdge fixture & HTML-only copy" && page.plainText == nil, "its readable text comes from the HTML; it has no text flavor")
        check(page.plainTextForPaste == "ClipEdge fixture & HTML-only copy", "⌃⌘V pastes its words")
        check(page.kind.iconName == "text.alignleft" && page.matches("HTML-only fixture"), "it shows as text and its words are searchable")
        check(ClipboardBrowserTab.text.includes(page) && ClipboardBrowserTab.all.includes(page) && !ClipboardBrowserTab.images.includes(page), "it is listed under Text")
        let color = entry(ClipboardWebCopies.html("<span>#F6C0A6</span>"))
        check(color.swatchColor != nil && color.plainTextForPaste == "#F6C0A6", "an HTML-only color literal is a swatch and pastes as written")
        check(entry(ClipboardWebCopies.html("<span style=\"color:red\"></span>")).kind == .other, "HTML with nothing to read stays an unknown item")
        let picture = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!.representation(using: .png, properties: [:])!
        check(entry([(.html, Data("<img src=x><p>caption</p>".utf8)), (.png, picture)]).kind == .image, "a picture with HTML stays a picture")

        let rich = entry(ClipboardWebCopies.rtf("ClipEdge fixture rich note"))
        check(rich.kind == .text && rich.title == "ClipEdge fixture rich note" && rich.plainTextForPaste == "ClipEdge fixture rich note",
              "rich text alone reads and pastes as its text, not 'Clipboard item'")
        let note = NSAttributedString(string: "ClipEdge fixture RTFD note")
        guard let rtfd = note.rtfd(from: NSRange(location: 0, length: note.length), documentAttributes: [:]) else { fatalError("FAIL: RTFD fixture") }
        let flat = entry([(.rtfd, rtfd)])
        check(flat.kind == .text && flat.title == "ClipEdge fixture RTFD note", "RTFD alone reads as its text too")
        check(entry(ClipboardWebCopies.rtf("https://example.com/rich")).kind == .link, "a rich-text address is a link, as plain text is")

        let chat = entry(ClipboardWebCopies.chatReply)
        check(chat.kind == .text && chat.metadata.facts == ["7 words", "39 characters"] && chat.metadata.line == "7 words · 39 characters · from claude.ai",
              "a copy from a web page names its site after its facts (\(chat.metadata.line))")
        check(!chat.metadata.compact.contains("chat/") && !chat.metadata.compact.contains("https"), "never the page's full address")
        let app = entry(ClipboardWebCopies.html("<p>app page words</p>", source: "app://-/index.html"))
        check(html(app) != nil && !app.metadata.compact.contains("from"), "an app's built-in page names no site")
        let www = entry(ClipboardWebCopies.html("<p>words</p>", source: "https://www.Example.com/a?t=secret"))
        check(www.metadata.site == "example.com", "a site drops www. and keeps nothing of the address")
        let shot = entry([(.html, Data("<img src=x>".utf8)), (.png, picture), (ClipboardFlavors.sourceURL, Data("https://example.com/gallery".utf8))])
        check(shot.kind == .image && shot.metadata.site == "example.com" && shot.metadata.line.hasSuffix("· from example.com") && !shot.plainTextForPaste.contains("from"),
              "a picture from a page shows its site but never pastes it (\(shot.plainTextForPaste))")

        // A lone address in HTML reads as one, as rich and plain text do; it stays HTML so it pastes as written.
        let address = entry(ClipboardWebCopies.html("<a href=\"https://example.com/html\">https://example.com/html</a>"))
        check(html(address) != nil && address.detail == "example.com" && address.metadata.facts == ["example.com"] && address.plainTextForPaste == "https://example.com/html",
              "an HTML-only address names its site (\(address.detail))")
        let prose = "https://example.com/x and more words"
        check(entry(ClipboardWebCopies.html("<p>\(prose)</p>")).detail == "\(prose.count) characters", "an address followed by words is prose")
        check(entry([(.string, Data("https://example.com/x and more".utf8))]).kind == .text, "plain text that starts with an address and goes on is text, not a link")
        check(entry([(.string, Data(" https://de.wikipedia.org/wiki/Straße\n".utf8))]).kind == .link, "a lone address with letters beyond ASCII is still a link")

        let design = entry(ClipboardWebCopies.figma())
        let link = figma(design)!.link.absoluteString
        check(design.plainTextForPaste == link, "⌃⌘V pastes the link back to the layers")
        check(design.readableText == nil && design.swatchColor == nil, "Figma layers have no text to show and are never a swatch")
        let caption = entry(ClipboardWebCopies.figma(text: "Fixture caption"))
        check(caption.plainTextForPaste == "Fixture caption" && caption.readableText == "Fixture caption", "a text layer's copy pastes and reads as its text")
        check(ClipboardBrowserTab.text.includes(caption) && ClipboardBrowserTab.all.includes(caption) && !ClipboardBrowserTab.images.includes(caption),
              "a text layer's copy is listed under Text as well as All")
        check(entry(ClipboardWebCopies.figma(text: "#F6C0A6")).swatchColor == nil, "Figma text is not a swatch: its card keeps what Figma said")
        check(design.matches("Fixture Board") && design.matches("figma") && design.matches("Figma Design") && design.matches("figma.com"),
              "search finds Figma layers by file, Figma, editor and site")
        check(entry(ClipboardWebCopies.figma(editorType: "whiteboard", route: "board")).matches("FigJam"), "search finds FigJam copies by name")
        check(ClipboardBrowserTab.all.includes(design) && !ClipboardBrowserTab.text.includes(design) && !ClipboardBrowserTab.images.includes(design),
              "Figma layers without text are listed under All only")

        // A copy longer than the summary reads: honest counts, and ⌃⌘V reads it all.
        let tail = "ClipEdge fixture end marker"
        let long = "<p>" + String(repeating: "word ", count: (ClipboardHTMLText.summaryLimit / 5) + 10) + tail + "</p>"
        let big = entry(ClipboardWebCopies.html(long))
        check(html(big)?.isComplete == false && big.metadata.facts.allSatisfy { $0.hasPrefix("at least ") }, "a longer copy's counts are minimums")
        check(!big.readableText!.contains(tail) && big.plainTextForPaste.hasSuffix(tail), "⌃⌘V reads the whole copy, past the summary's limit")
    }

    private static func surfaceChecks() throws {
        let design = entry(ClipboardWebCopies.figma()), page = entry(ClipboardWebCopies.html(ClipboardWebCopies.plainHTML))
        let copy = figma(design)!
        // Send to: the link opens in apps that open it; text only pastes.
        let materializer = ClipboardMaterializer(root: FileManager.default.temporaryDirectory.appendingPathComponent("ClipEdge-web-copy-\(UUID().uuidString)"))
        defer { materializer.removeAll() }
        check(ClipboardSendTo.openItems(for: design, materializer: materializer) == [copy.link], "Figma layers open as their link")
        check(ClipboardSendTo.openItems(for: page, materializer: materializer).isEmpty, "HTML is never handed to a browser")
        let address = entry(ClipboardWebCopies.html("<a href=\"https://example.com/html\">https://example.com/html</a>"))
        check(ClipboardSendTo.openItems(for: address, materializer: materializer) == [URL(string: "https://example.com/html")!], "an HTML-only address opens as that address, never as HTML")
        let caption = entry(ClipboardWebCopies.figma(text: "Fixture caption"))
        check(ClipboardSendTo.openItems(for: caption, materializer: materializer) == [copy.link], "Send to › Open in still opens a text layer's link")
        let browser = URL(fileURLWithPath: "/Applications/Fixture Browser.app")
        let sources = ClipboardSendTo.Sources(openers: { $0 == copy.link ? [browser] : [] },
                                              running: { [ClipboardSendTo.RunningApp(pid: 42, name: "Notes", url: nil)] }, pasteTarget: { _ in nil })
        check(ClipboardSendTo.targets(opening: [copy.link], sources: sources) == [.open(app: browser, items: [copy.link]), .paste(pid: 42, name: "Notes", app: nil)],
              "Send to offers apps that open the link first, then paste rows")

        // Quick Look gets text, drawn in the current appearance; Preview gets a page. Never HTML.
        let figmaFiles = try materializer.urls(for: design)
        check(figmaFiles.count == 1 && figmaFiles[0].lastPathComponent == "Figma layer.txt", "one Figma layer previews as text, named in the singular")
        let quickCard = (try? String(contentsOf: figmaFiles[0], encoding: .utf8)) ?? ""
        for part in [design.title, "Figma Design · figma.com", copy.explanation, copy.link.absoluteString] {
            check(quickCard.contains(part), "Quick Look shows \(part)")
        }
        check(!quickCard.contains("t=fixture") && !quickCard.contains("viewport"), "Quick Look shows no share token or viewport")
        let opened = try materializer.urls(for: design, forPreviewApp: true)
        // A long line wraps on the page, so compare without spaces and line breaks.
        func squeezed(_ text: String) -> String { text.filter { !$0.isWhitespace } }
        let card = squeezed(opened.first.flatMap { PDFDocument(url: $0)?.string } ?? "")
        check(opened.count == 1 && opened[0].lastPathComponent == "Figma layer.pdf" && squeezed(quickCard) == card, "⌘O opens the same words as a page in Preview")
        let several = try materializer.urls(for: entry(ClipboardWebCopies.demo[1].values))
        let variablePreview = try materializer.urls(for: entry(ClipboardWebCopies.figma(nodes: "", dataType: "variable")))
        check(several.first?.lastPathComponent == "Figma layers.txt" && variablePreview.first?.lastPathComponent == "Figma data.txt",
              "several layers are named in the plural; a variable's copy is not called layers")
        let captionCard = try materializer.urls(for: caption)
        check(captionCard.first?.lastPathComponent == "Figma text.txt" && ((try? String(contentsOf: captionCard[0], encoding: .utf8)) ?? "").hasPrefix("Fixture caption\n\nFigma text from"),
              "a text layer's Quick Look leads with its words, then where they came from")
        let opaque = entry([(NSPasteboard.PasteboardType("org.clipedge.fixture-opaque"), Data([1]))])
        let (opaqueQuick, opaquePage) = (try materializer.urls(for: opaque), try materializer.urls(for: opaque, forPreviewApp: true))
        check(opaqueQuick.first?.pathExtension == "txt" && opaquePage.first?.pathExtension == "pdf", "an unknown item's inventory is text for Quick Look and a page for Preview")
        let quick = try materializer.urls(for: page)
        check(quick.count == 1 && quick[0].pathExtension == "txt" && (try? String(contentsOf: quick[0], encoding: .utf8)) == "ClipEdge fixture & HTML-only copy",
              "Quick Look shows an HTML-only copy's text")
        let preview = try materializer.urls(for: page, forPreviewApp: true)
        check(preview[0].pathExtension == "pdf" && PDFDocument(url: preview[0])?.string?.contains("HTML-only copy") == true, "⌘O shows it as a page of text")
        let folder = quick[0].deletingLastPathComponent()
        check(!((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).contains { $0.hasSuffix("html") }, "no HTML file is ever written")
        try materializer.remove(design)
        check(!FileManager.default.fileExists(atPath: figmaFiles[0].path) && !FileManager.default.fileExists(atPath: opened[0].path), "removing the item removes its text and its page")

        // The history card: a symbol at its own size, the title, the explanation and the link.
        let card2 = ClipboardHistoryCard(frame: NSRect(x: 0, y: 0, width: 420, height: 380))
        card2.show(design); card2.layoutSubtreeIfNeeded()
        check(card2.bodyText.contains(design.title) && card2.bodyText.contains(copy.explanation) && card2.linkText == copy.link.absoluteString,
              "the card shows the title, the explanation and the link")
        check(card2.bodyText.hasSuffix("⌃⌘⏎ pastes the link.") && card2.noteText == nil, "the card names the window's own plain-text key, not ⌃⌘V")
        check((card2.imageFrame?.height ?? 999) <= 56 && card2.edgeText.contains("Figma Design · figma.com"), "its symbol is not stretched; facts run along its edge")
        card2.show(caption); card2.layoutSubtreeIfNeeded()
        check(card2.bodyText == "Fixture caption" && card2.imageFrame == nil && card2.noteText == figma(caption)!.explanation + " ⌃⌘⏎ pastes the text."
              && card2.linkText == copy.link.absoluteString, "a text layer's card shows its words, then where its layers paste, then the link")
        card2.show(page); card2.layoutSubtreeIfNeeded()
        check(card2.bodyText == "ClipEdge fixture & HTML-only copy" && card2.imageFrame == nil && card2.linkText == nil && card2.noteText == nil,
              "an HTML-only copy fills the card with its text")
        card2.show(entry([(NSPasteboard.PasteboardType("org.clipedge.fixture-opaque"), Data([1]))])); card2.layoutSubtreeIfNeeded()
        check((card2.imageFrame?.height ?? 999) <= 56 && card2.bodyText == "Clipboard item", "an unknown item's symbol keeps its size too")

        // An item's info: title and explanation, then the link with the facts, in full.
        let tile = ClipboardTile(entry: design, style: .row)
        check(tile.tooltipSummary == copy.summary && tile.tooltipDetails.hasPrefix(copy.link.absoluteString + "\n"), "an item's info explains the layers and gives the link")
        check(ClipboardTile(entry: page, style: .row).tooltipSummary == "ClipEdge fixture & HTML-only copy", "an HTML-only copy's info shows its text")
        check(ClipboardTile(entry: caption, style: .row).tooltipText.hasPrefix("Fixture caption\n" + figma(caption)!.explanation), "a text layer's info shows its words and the explanation")

        // The held magnet: the symbol, title and explanation, whole, within the small magnet.
        for budget in [350.0, 700.0] as [CGFloat] {
            let held = ClipboardAttachmentView.makeHeldPreview(for: design, maximumAttachmentPixels: budget, holdingGlyphHeight: 25)
            held.view.layoutSubtreeIfNeeded()
            let labels = descendants(held.view).compactMap { $0 as? NSTextField }
            let room = budget / max(1, NSScreen.main?.backingScaleFactor ?? 1) >= 300
            let note = labels.first { $0.stringValue == (room ? copy.explanation : copy.shortNote) } ?? labels.first { $0.stringValue == copy.explanation }
            check(labels.contains { $0.stringValue == design.title } && note != nil, "the held magnet (\(budget) px) shows the title and the explanation, or a short note where it cannot fit")
            if let note {
                let needed = note.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: note.frame.width, height: 10_000)).height
                check(note.frame.height + 1 >= needed && note.frame.minY >= 0, "the explanation is not cut short (\(note.frame.height) of \(needed))")
            }
        }
        let text = ClipboardAttachmentView.makeHeldPreview(for: page, maximumAttachmentPixels: 350, holdingGlyphHeight: 25).view
        let pageLabel = descendants(text).compactMap { $0 as? NSTextField }.first { $0.stringValue == "ClipEdge fixture & HTML-only copy" }
        check(pageLabel?.cell?.truncatesLastVisibleLine == true, "an HTML-only copy's magnet shows its text, ending in … when cut short")
        let slug = "SwamiKKMembersLibraryWireframesAndPrototypesForReview"
        let longName = entry(ClipboardWebCopies.figma(slug: slug))
        let captionHeld = ClipboardAttachmentView.makeHeldPreview(for: caption, maximumAttachmentPixels: 700, holdingGlyphHeight: 25).view
        for (held, title) in [(ClipboardAttachmentView.makeHeldPreview(for: longName, maximumAttachmentPixels: 350, holdingGlyphHeight: 25).view, longName.title),
                              (captionHeld, "Fixture caption")] {
            let label = descendants(held).compactMap { $0 as? NSTextField }.first { $0.stringValue == title }
            check(label?.cell?.truncatesLastVisibleLine == true, "a magnet's title cut at two lines ends in …, so a shortened name never looks whole (\(title))")
        }
    }

    private static func storeChecks() {
        let board = NSPasteboard.withUniqueName()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ClipEdge-web-store-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder); board.releaseGlobally() }
        let history = folder.appendingPathComponent("History.plist")
        let store = ClipboardStore(pasteboard: board, persistenceURL: history)
        let values = ClipboardWebCopies.figma()
        board.clearContents(); board.writeObjects([ClipboardWebCopies.item(values)]); _ = store.saveNow()
        board.clearContents(); board.writeObjects([ClipboardWebCopies.item(ClipboardWebCopies.html(ClipboardWebCopies.plainHTML))]); _ = store.saveNow()
        store.cancelStaging()
        let layers = store.entries[1], page = store.entries[0]
        check(figma(layers) != nil && html(page) != nil, "copies made on the clipboard are recognized")
        board.clearContents(); board.setString("something else", forType: .string)
        check(store.makeCurrent(layers), "Figma layers can be made current")
        check(values.allSatisfy { board.data(forType: $0.type) == $0.data }, "every flavor returns byte for byte, so Figma gets its layers back")
        guard let loan = store.beginPlainTextPaste() else { fatalError("FAIL: Figma layers lend a plain-text copy") }
        check(board.string(forType: .string) == figma(layers)?.link.absoluteString && board.data(forType: .html) == nil, "⌃⌘V lends the link alone")
        store.endPlainTextPaste(loan)
        check(board.data(forType: .html) == values.first { $0.type == .html }?.data, "the layers return after the plain paste")
        check(store.makeCurrent(page) && store.beginPlainTextPaste() != nil && board.string(forType: .string) == "ClipEdge fixture & HTML-only copy",
              "an HTML-only copy lends its words")
        store.endPlainTextPaste()
        store.cancelStaging()

        // A text layer lends its words; a damaged Figma copy has nothing to lend.
        let captionValues = ClipboardWebCopies.figma(text: "Fixture caption")
        for values in [captionValues, ClipboardWebCopies.figma(figmeta: "not-base64-json")] {
            board.clearContents(); board.writeObjects([ClipboardWebCopies.item(values)]); _ = store.saveNow()
        }
        store.cancelStaging()
        let damaged = store.entries[0], caption = store.entries[1]
        check(store.makeCurrent(caption) && store.beginPlainTextPaste() != nil && board.string(forType: .string) == "Fixture caption" && board.data(forType: .html) == nil,
              "⌃⌘V lends a text layer's words, not its link")
        store.endPlainTextPaste()
        check(board.data(forType: .html) == captionValues.first { $0.type == .html }?.data, "the text layer returns whole for Figma")
        check(store.makeCurrent(damaged) && store.beginPlainTextPaste() == nil, "a copy ClipEdge cannot read pastes nothing, never the site it came from")
        store.cancelStaging()
        _ = store.saveNow()
        store.stop()

        let reopenedBoard = NSPasteboard.withUniqueName()
        let reopened = ClipboardStore(pasteboard: reopenedBoard, persistenceURL: history)
        reopened.start()
        defer { reopened.stop(); reopenedBoard.releaseGlobally() }
        check(reopened.entries.contains { figma($0) != nil && $0.title == layers.title } && reopened.entries.contains { html($0) != nil },
              "saved copies are recognized again at the next launch")

        // The demo's copies, on top of the fixed seed whose order tests and captures use.
        let demoBoard = NSPasteboard.withUniqueName()
        let demo = ClipboardStore(pasteboard: demoBoard, persistenceURL: nil)
        defer { demo.stop(); demoBoard.releaseGlobally() }
        ClipboardDemo.seed(demo, board: demoBoard)
        let seeded = demo.entries.map(\.title)
        ClipboardDemo.seedWebCopies(demo, board: demoBoard)
        check(Array(demo.entries.suffix(seeded.count).map(\.title)) == seeded, "the web copies sit above the seed, its order unchanged")
        let added = demo.entries.prefix(ClipboardWebCopies.demo.count)
        let kinds = added.map { entry -> String in
            switch entry.kind { case .figma: return "figma"; case .html: return "html"; case .text: return "text"; case .other: return "other"; default: return "?" }
        }
        check(kinds.filter { $0 == "figma" }.count == 7 && kinds.filter { $0 == "html" }.count == 2 && kinds.filter { $0 == "text" }.count == 2
              && kinds.filter { $0 == "other" }.count == 2, "the demo shows seven Figma copies (one a text layer), two HTML-only, two text and two unknown (\(kinds))")
        check(added.first?.metadata.site == "claude.ai" && zip(added, added.dropFirst()).allSatisfy { $0.capturedAt > $1.capturedAt },
              "the newest demo copy is the chat reply, and the copies keep fixed, increasing times")
    }

    /// Summaries run on the main thread at every copy and for every saved item at launch.
    private static func timingChecks() {
        var hugeFigma = ClipboardWebCopies.figma()
        let index = hugeFigma.firstIndex { $0.type == .html }!
        hugeFigma[index].data += Data(repeating: 0x41, count: 30 << 20)
        var started = ProcessInfo.processInfo.systemUptime
        let layers = ClipboardSummary.make(from: [ClipboardPayload(values: hugeFigma)])
        let figmaSeconds = ProcessInfo.processInfo.systemUptime - started
        check(layers.title.hasPrefix("1 Figma layer") && figmaSeconds < 0.2, "a 30 MB Figma copy is recognized without reading its buffer (\(figmaSeconds) s)")

        let long = ClipboardWebCopies.html("<div>" + String(repeating: "<p>Fixture paragraph with <b>bold</b> &amp; words.</p>\n", count: 160_000) + "</div>")
        started = ProcessInfo.processInfo.systemUptime
        let summary = ClipboardSummary.make(from: [ClipboardPayload(values: long)])
        let htmlSeconds = ProcessInfo.processInfo.systemUptime - started
        check(summary.title.hasPrefix("Fixture paragraph with bold & words.") && htmlSeconds < 1.5, "an 8 MB HTML-only copy is summarized from its first 2 MB quickly (\(htmlSeconds) s)")

        // Skipping a style, script or comment compares bytes in place, allocating nothing per byte
        // (about 3 ms optimized; these tests build unoptimized, so the bound is loose).
        let styled = ClipboardWebCopies.html("<style>" + String(repeating: "p { color: red; }\n", count: 100_000) + "</style><p>Fixture after style</p>")
        started = ProcessInfo.processInfo.systemUptime
        let afterStyle = ClipboardSummary.make(from: [ClipboardPayload(values: styled)])
        let styleSeconds = ProcessInfo.processInfo.systemUptime - started
        check(afterStyle.title == "Fixture after style" && styleSeconds < 0.5, "a copy opening with 2 MB of style is read past it quickly (\(styleSeconds) s)")

        let fifty = (0..<50).map { ClipboardWebCopies.html("<p>Fixture \($0)</p>" + String(repeating: "<span>filler text</span> ", count: 2_000)) }
        started = ProcessInfo.processInfo.systemUptime
        let kinds = fifty.map { ClipboardSummary.make(from: [ClipboardPayload(values: $0)]).kind }
        let launchSeconds = ProcessInfo.processInfo.systemUptime - started
        check(kinds.allSatisfy { if case .html = $0 { return true }; return false } && launchSeconds < 1, "fifty saved HTML-only copies summarize at launch in under a second (\(launchSeconds) s)")
    }

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
