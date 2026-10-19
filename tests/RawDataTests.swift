import AppKit
import QuickLookUI

/// The back of a flipped card: how each flavor reads (text or bytes), the hex dump, the
/// overview, item grouping, what Copy puts on the clipboard, the view (HTML never rendered,
/// nothing cut short at the window card's and the drawer Quick Look's sizes, light and dark)
/// and the flip between the two faces. Fixtures only: invented copies in the shapes real
/// ones take, on a named pasteboard; real clipboard history is never read.
@main enum RawDataTests {
    typealias Values = [(type: NSPasteboard.PasteboardType, data: Data)]
    private static var assertions = 0
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError("FAIL: \(message)") }
    }
    private static func settle(_ seconds: TimeInterval = 0.15) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    // MARK: Fixtures

    static let tokenType = NSPasteboard.PasteboardType("org.chromium.internal.source-rfh-token")
    static let unknown = NSPasteboard.PasteboardType("com.clipedge.fixture.unknown")
    static let utf16 = NSPasteboard.PasteboardType("public.utf16-plain-text")
    static let utf16External = NSPasteboard.PasteboardType("public.utf16-external-plain-text")
    /// A browser frame token's shape: 24 bytes, zeros and high bytes among them. Invented.
    static let token = Data([0x00, 0x9F, 0x3C, 0xFF, 0x10, 0x00, 0x00, 0x00, 0x7A, 0x01, 0xC2, 0x05,
                             0x00, 0x00, 0x00, 0x00, 0xE4, 0x11, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00])
    static let markup = "<meta charset='utf-8'><span style=\"color:#333\">Scroll sync fixture</span><script>alert(1)</script><a href=\"https://example.com\">link</a>"
    static let address = "https://example.com/kk-events-fixture?view=week&t=fixture"
    /// A web copy as a Chromium browser leaves it, in type-name order as ClipEdge captures it.
    static let webCopy: Values = [(tokenType, token), (ClipboardFlavors.sourceURL, Data(address.utf8)),
                                  (.html, Data(markup.utf8)), (.string, Data("Scroll sync fixture".utf8))]

    static func entry(_ payloads: [Values], fingerprint: String = "fixture-fingerprint") -> ClipboardEntry {
        let payloads = payloads.map(ClipboardPayload.init(values:))
        let summary = ClipboardSummary.make(from: payloads)
        return ClipboardEntry(fingerprint: fingerprint, capturedAt: Date(timeIntervalSince1970: 1_791_225_000), payloads: payloads,
                              title: summary.title, detail: summary.detail, kind: summary.kind, thumbnail: summary.thumbnail)
    }
    static func content(_ string: String, _ type: NSPasteboard.PasteboardType) -> ClipboardRawContent {
        ClipboardRawData.content(of: Data(string.utf8), type: type)
    }
    static func text(_ content: ClipboardRawContent) -> ClipboardRawText? { if case .text(let text) = content { return text }; return nil }
    static func bytes(_ content: ClipboardRawContent) -> ClipboardRawBytes? { if case .bytes(let bytes) = content { return bytes }; return nil }
    static func utf16(_ string: String, bigEndian: Bool = false, mark: Bool = false) -> Data {
        let body = string.data(using: bigEndian ? .utf16BigEndian : .utf16LittleEndian)!
        return mark ? Data(bigEndian ? [0xFE, 0xFF] : [0xFF, 0xFE]) + body : body
    }

    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .aqua)
        classification()
        hexDump()
        overviewAndItems()
        try copying()
        try view(app)
        flip(app)
        app.appearance = nil
        print("Raw data tests passed (\(assertions) assertions)")
    }

    // MARK: Text or bytes

    static func classification() {
        // The web copy that prompted this: the token is bytes, the rest is text.
        let token = bytes(ClipboardRawData.content(of: Self.token, type: tokenType))
        check(token?.head == Self.token && token?.totalBytes == 24 && token?.remaining == 0, "the 24-byte frame token reads as bytes, all shown")
        check(token?.pictureSize == nil && token?.isUndecodableText == false && token?.notes == [], "a token has no notes")
        check(ClipboardRawData.description(of: tokenType) == "the browser's token for the frame it was copied from", "the token's type is named")
        check(bytes(ClipboardRawData.content(of: Data(repeating: 7, count: 24), type: tokenType)) != nil, "a token of bell characters is still bytes")
        check(text(content(address, ClipboardFlavors.sourceURL))?.shown == address, "the source URL reads as text, whole, query and all")
        check(ClipboardRawData.description(of: ClipboardFlavors.sourceURL) == "the page it was copied from", "the source URL's type is named")
        check(text(content(markup, .html))?.shown == markup, "HTML reads as its markup")
        check(text(content("Scroll sync fixture", .string))?.encoding == .utf8, "plain text reads as UTF-8")
        check(ClipboardRawData.description(of: .html) == "HTML text", "UTType names HTML")
        check(ClipboardRawData.description(of: unknown) == nil, "an undeclared type has no name")

        // Rich text is its source.
        let rtf = ClipboardWebCopies.rtf("Fixture rich note")[0]
        check(text(ClipboardRawData.content(of: rtf.data, type: rtf.type))?.shown == "{\\rtf1\\ansi Fixture rich note}", "RTF reads as its source")

        // UTF-16: the plain-text type in host order without a mark, a mark wherever it leads.
        let greeting = "héllo 👋 wörld"
        let plain16 = text(ClipboardRawData.content(of: utf16(greeting), type: utf16))
        check(plain16?.shown == greeting && plain16?.encoding == .utf16(bigEndian: false) && plain16?.markLength == 0, "UTF-16 text without a mark is little-endian")
        let marked16 = text(ClipboardRawData.content(of: utf16(greeting, mark: true), type: utf16))
        check(marked16?.shown == greeting && marked16?.markLength == 2 && marked16?.shown.unicodeScalars.first != "\u{FEFF}", "a little-endian mark is read and dropped")
        let big16 = text(ClipboardRawData.content(of: utf16(greeting, bigEndian: true, mark: true), type: utf16))
        check(big16?.shown == greeting && big16?.encoding == .utf16(bigEndian: true), "a big-endian mark is honoured")
        check(text(ClipboardRawData.content(of: utf16(greeting, bigEndian: true), type: utf16External))?.shown == greeting, "external UTF-16 without a mark is big-endian")
        check(text(ClipboardRawData.content(of: utf16(greeting, mark: true), type: unknown))?.shown == greeting, "an undeclared type led by a UTF-16 mark reads as text")
        check(bytes(ClipboardRawData.content(of: utf16(greeting, mark: true) + Data([0x41]), type: unknown)) != nil, "an odd byte after a UTF-16 mark is not text")
        check(bytes(ClipboardRawData.content(of: Data([0x00, 0xD8, 0x41, 0x00]), type: utf16))?.isUndecodableText == true, "a lone surrogate is not UTF-16 text")
        let utf8Marked = text(ClipboardRawData.content(of: Data([0xEF, 0xBB, 0xBF]) + Data("Fixture".utf8), type: unknown))
        check(utf8Marked?.shown == "Fixture" && utf8Marked?.markLength == 3, "a UTF-8 mark is read and dropped")

        // Pictures are bytes, with their size.
        let png = ClipboardWebCopies.picture.png
        let picture = bytes(ClipboardRawData.content(of: png, type: .png))
        check(picture?.pictureSize == "96 × 64 pixels", "a PNG says its pixel size (\(picture?.pictureSize ?? "none"))")
        check(picture?.head.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]) && picture?.totalBytes == png.count, "a PNG's bytes start with its signature")
        check(bytes(ClipboardRawData.content(of: ClipboardWebCopies.picture.tiff, type: .tiff))?.pictureSize == "96 × 64 pixels", "a TIFF says its pixel size")
        check(bytes(ClipboardRawData.content(of: png, type: unknown))?.pictureSize == nil, "only picture types are decoded as pictures")

        // A Figma copy: its HTML is text with the description and buffer markers in it, verbatim.
        let figma = ClipboardWebCopies.figma()
        let figmaHTML = figma.first { $0.type == .html }!
        let figmaText = text(ClipboardRawData.content(of: figmaHTML.data, type: .html))
        check(figmaText?.shown == String(decoding: figmaHTML.data, as: UTF8.self) && figmaText?.shown.contains("(figmeta)") == true, "a Figma copy's HTML reads as its markup")
        check(bytes(ClipboardRawData.content(of: figma.first { $0.type == tokenType }!.data, type: tokenType)) != nil, "a Figma copy's frame token is bytes")

        // JSON and XML, declared or not; a binary property list is bytes.
        let json = #"{"fixture": true, "items": [1, 2, 3]}"#
        check(text(content(json, .init("public.json")))?.shown == json, "declared JSON is text")
        check(text(content(json, .init("com.clipedge.fixture.json")))?.shown == json, "undeclared JSON reads as text")
        let plist = #"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>Fixture</key><true/></dict></plist>"#
        check(text(content(plist, .init("com.apple.xml-property-list")))?.shown == plist, "an XML property list is text")
        let binaryPlist = try! PropertyListSerialization.data(fromPropertyList: ["Fixture": true], format: .binary, options: 0)
        check(bytes(ClipboardRawData.content(of: binaryPlist, type: .init("com.apple.property-list"))) != nil, "a binary property list is bytes")

        // Invalid UTF-8: bytes, and a text type that does not decode says so.
        let invalid = Data([0x41, 0xC3, 0x28, 0x42])
        check(bytes(ClipboardRawData.content(of: invalid, type: unknown))?.isUndecodableText == false, "undeclared invalid UTF-8 is plain bytes")
        let declaredInvalid = bytes(ClipboardRawData.content(of: invalid, type: .string))
        check(declaredInvalid?.isUndecodableText == true && declaredInvalid?.notes == ["Declared as text, but not valid UTF-8 or UTF-16."], "a text type that does not decode is bytes, and says why")

        // Control characters decide undeclared text; format characters (emoji joiners) do not.
        check(text(content("one\ttwo\r\nthree\n", unknown)) != nil, "tabs and line ends are text")
        check(text(content("👩‍👩‍👧 family", unknown))?.shown == "👩‍👩‍👧 family", "emoji joiners are text")
        check(bytes(content("bell\u{07}", unknown)) != nil && bytes(content("del\u{7F}", unknown)) != nil && bytes(content("nul\u{0}", unknown)) != nil, "other control characters make bytes")
        check(text(content("bell\u{07}", .string)) != nil, "a declared text type keeps its control characters as text")

        // Empty data.
        check(ClipboardRawData.content(of: Data(), type: .string) == .empty && ClipboardRawData.content(of: Data(), type: unknown) == .empty, "no bytes is empty, whatever the type")

        // Over the cap: the first 64 KB shown, at a character boundary, and the note.
        let big = "a" + String(repeating: "é", count: 1_499_999) + "z"
        let bigData = Data(big.utf8)
        check(bigData.count == 3_000_000, "the large fixture is 3 MB")
        let capped = text(ClipboardRawData.content(of: bigData, type: .string))
        check(capped?.shownBytes == 63_999 && capped?.shown.utf8.count == 63_999, "UTF-8 text stops before a character the cap would split (\(capped?.shownBytes ?? 0))")
        check(capped?.isWhole == false && capped?.capNote == "First 64 KB of 3 MB shown; Copy copies all.", "the note says how much shows (\(capped?.capNote ?? ""))")
        check(capped?.whole(of: bigData) == big, "Copy's text is all of it")
        let bigWaves = "a" + String(repeating: "👋", count: 20_000)
        let waves = text(ClipboardRawData.content(of: utf16(bigWaves), type: utf16))
        check(waves?.shownBytes == 63_998 && waves?.shown.unicodeScalars.allSatisfy({ $0 == "a" || $0 == "👋" }) == true, "UTF-16 text never splits a surrogate pair (\(waves?.shownBytes ?? 0))")
        check(text(ClipboardRawData.content(of: Data(String(repeating: "x", count: 64_000).utf8), type: .string))?.isWhole == true, "text exactly at the cap is whole")
        var lateControl = Data(String(repeating: "x", count: 2_000_000).utf8)
        lateControl[1_999_000] = 0x01
        check(bytes(ClipboardRawData.content(of: lateControl, type: unknown)) != nil, "a control character past the cap still makes undeclared data bytes")

        // Validity and control characters come from one pass over the bytes, never the whole text decoded:
        // valid exactly when Foundation reads the bytes, C0, DEL and C1 the control characters.
        let utf8Cases: [[UInt8]] = [[0xC0, 0xAF], [0xE0, 0x80, 0xAF], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80], [0xF5, 0x80, 0x80, 0x80],
                                    [0xE2, 0x82], [0x80], [0xC2], [0xEF, 0xBF, 0xBE], [0x00], [0xC2, 0x85], [0xE2, 0x82, 0xAC], [0xF0, 0x9F, 0x91, 0x8B],
                                    Array("plain ✓ text 👩‍👩‍👧 é".utf8), [0x41, 0xF0, 0x9F, 0x91]]
        for bytes in utf8Cases {
            check(ClipboardRawData.scan(Data(bytes), encoding: .utf8).valid == (String(data: Data(bytes), encoding: .utf8) != nil),
                  "UTF-8 \(bytes) is valid exactly when Foundation reads it")
        }
        let utf16Cases: [[UInt8]] = [[0x00, 0xD8, 0x41, 0x00], [0x00, 0xDC], [0x3D, 0xD8, 0x4B, 0xDC], [0xFE, 0xFF], [0x41, 0x00, 0x00, 0xD8], [0x41, 0x00, 0x85, 0x00]]
        for bytes in utf16Cases {
            check(ClipboardRawData.scan(Data(bytes), encoding: .utf16(bigEndian: false)).valid == (String(data: Data(bytes), encoding: .utf16LittleEndian) != nil),
                  "UTF-16 \(bytes) is valid exactly when Foundation reads it")
        }
        check(ClipboardRawData.scan(Data([0xC2, 0x85]), encoding: .utf8) == (true, true) && ClipboardRawData.scan(Data("a\tb\r\n".utf8), encoding: .utf8) == (true, false)
              && ClipboardRawData.scan(Data([0x7F]), encoding: .utf8) == (true, true) && ClipboardRawData.scan(Data([0x41, 0x00, 0x85, 0x00]), encoding: .utf16(bigEndian: false)) == (true, true),
              "C1, DEL and C0 but tab and line ends are control characters, in UTF-8 and UTF-16")
        check(bytes(content("next line\u{85}", unknown)) != nil, "a C1 control character makes undeclared data bytes")
        let roomy = Data(String(repeating: "Plain words in an app's own format, ", count: 120_000).utf8)
        let started = Date()
        let roomyText = text(ClipboardRawData.content(of: roomy, type: unknown))
        let took = Date().timeIntervalSince(started)
        check(roomyText?.shownBytes == ClipboardRawData.textCap && roomyText?.totalBytes == roomy.count && took < 2,
              "\(roomy.count.formatted()) undeclared bytes read as text, only the part shown decoded (\(String(format: "%.2f", took)) s)")
    }

    // MARK: Hex dump

    static func hexDump() {
        let twenty = Data(0..<20)
        let lines = ClipboardRawData.hexDump(twenty, bytesPerRow: 16).components(separatedBy: "\n")
        check(lines.count == 2, "20 bytes at 16 a row are two lines")
        check(lines[0] == "0000  00 01 02 03 04 05 06 07  08 09 0a 0b 0c 0d 0e 0f  |................|", "a full row: offset, two groups of eight, ASCII between bars (\(lines[0]))")
        check(lines[1].hasPrefix("0010  10 11 12 13 ") && lines[1].hasSuffix("  |....|"), "a short row: its bytes, then its ASCII")
        check(lines[0].firstIndex(of: "|").map { lines[0].distance(from: lines[0].startIndex, to: $0) }
              == lines[1].firstIndex(of: "|").map { lines[1].distance(from: lines[1].startIndex, to: $0) }, "the ASCII column stays in place on a short row")
        check(lines[0].count == ClipboardRawData.hexLineLength(bytesPerRow: 16) && ClipboardRawData.hexLineLength(bytesPerRow: 16) == 74, "a full row of 16 is 74 characters")
        let hello = ClipboardRawData.hexDump(Data("Hello, world!\n~\u{7F}".utf8), bytesPerRow: 8).components(separatedBy: "\n")
        check(hello == ["0000  48 65 6c 6c 6f 2c 20 77  |Hello, w|", "0008  6f 72 6c 64 21 0a 7e 7f  |orld!.~.|"], "8 a row; printable ASCII shows, the rest is a dot (\(hello))")
        check(hello[0].count == ClipboardRawData.hexLineLength(bytesPerRow: 8), "a row of 8 is as long as reckoned")
        check(ClipboardRawData.hexDump(Data(), bytesPerRow: 16).isEmpty, "no bytes, no lines")

        let long = Data((0..<600).map { UInt8($0 % 256) })
        let dumped = bytes(ClipboardRawData.content(of: long, type: unknown))
        check(dumped?.head.count == 512 && dumped?.remaining == 88 && dumped?.notes == ["… 88 more bytes"], "512 bytes are dumped and the rest counted")
        let rows = dumped?.dump(bytesPerRow: 16).components(separatedBy: "\n") ?? []
        check(rows.count == 32 && rows.last?.hasPrefix("01f0  ") == true, "the dump's last row starts at 0x1f0")
        check(bytes(ClipboardRawData.content(of: Data(repeating: 0, count: 512), type: unknown))?.notes == [], "exactly 512 bytes leaves nothing to count")
        check(bytes(ClipboardRawData.content(of: Data(repeating: 0, count: 513), type: unknown))?.notes == ["… 1 more byte"], "one more byte is singular")
        let pictureNotes = bytes(ClipboardRawData.content(of: ClipboardWebCopies.picture.png, type: .png))?.notes ?? []
        check(pictureNotes.last == "96 × 64 pixels", "a picture's size is among its notes (\(pictureNotes))")

        check(ClipboardRawDataView.bytesPerRow(fitting: 600) == 16 && ClipboardRawDataView.bytesPerRow(fitting: 300) == 8
              && ClipboardRawDataView.bytesPerRow(fitting: 120) == 4 && ClipboardRawDataView.bytesPerRow(fitting: 0) == 4, "the widest row that fits is chosen")
    }

    // MARK: Overview and items

    static func overviewAndItems() {
        let png = ClipboardWebCopies.picture.png
        let twoItems = entry([webCopy, [(.png, png)]], fingerprint: String(repeating: "ab", count: 32))
        let raw = ClipboardRawData(entry: twoItems)
        check(raw.items.count == 2 && raw.items.map(\.number) == [1, 2], "each pasteboard item is its own group")
        check(raw.items[0].flavors.map(\.number) == [1, 2, 3, 4] && raw.items[1].flavors.map(\.number) == [5], "flavors are numbered across the entry")
        check(raw.items[0].flavors.map(\.type) == webCopy.map(\.type), "flavors keep their stored order")
        let total = webCopy.reduce(0) { $0 + $1.data.count } + png.count
        check(raw.overview.itemCount == 2 && raw.overview.flavorCount == 5 && raw.overview.byteCount == total, "the overview counts items, flavors and bytes")
        check(raw.overview.fingerprint == twoItems.fingerprint && raw.overview.copied == twoItems.fullDateTimeStamp && raw.overview.title == twoItems.title, "the overview has the fingerprint, full copy time and title")
        check(raw.overview.rows.map(\.label) == ["Copied", "Kind", "Title", "Holds", "Size", "SHA-256"], "the overview's rows, in order")
        check(raw.overview.rows[3].value == "2 pasteboard items · 5 flavors", "the overview says how much it holds")
        check(raw.overview.rows[4].value == ClipboardRawData.size(total), "the overview's size is the total")
        check(ClipboardRawData(entry: entry([webCopy])).overview.rows[3].value == "1 pasteboard item · 4 flavors", "one item is singular")
        check(raw.flavors[1].details == ["the page it was copied from", ClipboardRawData.size(Data(address.utf8).count), "UTF-8"], "a text flavor's details: name, size, encoding")
        check(raw.flavors[0].details == ["the browser's token for the frame it was copied from", "24 bytes"], "a bytes flavor's details: name and size")

        check(ClipboardRawData.size(24) == "24 bytes" && ClipboardRawData.size(1) == "1 byte", "small sizes are exact")
        check(ClipboardRawData.size(3_000_000) == "3 MB (\(3_000_000.formatted()) bytes)", "large sizes give both forms (\(ClipboardRawData.size(3_000_000)))")

        // Kinds, in the words the card uses.
        check(ClipboardRawData.kindName(entry([webCopy])) == "Text", "a web copy with text is text")
        check(ClipboardRawData.kindName(entry([[(.png, png)]])) == "Picture", "a picture")
        check(ClipboardRawData.kindName(entry([ClipboardWebCopies.appDataWithPicture])) == "Picture, with Sketch data"
              || ClipboardRawData.kindName(entry([ClipboardWebCopies.appDataWithPicture])).hasPrefix("Picture, with "), "a picture with app data says so")
        check(ClipboardRawData.kindName(entry([ClipboardWebCopies.appDataOnly])).hasPrefix("App data ("), "app data alone")
        check(ClipboardRawData.kindName(entry([ClipboardWebCopies.figma()])) == "Figma copy (Figma Design)", "a Figma copy names its editor")
        check(ClipboardRawData.kindName(entry([ClipboardWebCopies.html(ClipboardWebCopies.plainHTML)])) == "HTML-only text", "HTML without plain text")
        check(ClipboardRawData.kindName(entry([[(.string, Data("https://example.com/a".utf8))]])) == "Link", "a link")
        check(ClipboardRawData.kindName(entry([ClipboardWebCopies.bookkeepingOnly])) == "Clipboard item", "nothing readable")
    }

    // MARK: Copy

    /// One item holding this type alone (the pasteboard's own list adds legacy aliases).
    static func only(_ board: NSPasteboard, _ type: NSPasteboard.PasteboardType) -> Bool {
        board.pasteboardItems?.count == 1 && board.pasteboardItems?.first?.types == [type]
    }

    static func copying() throws {
        let board = NSPasteboard(name: .init("ClipEdge-raw-data-tests-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let raw = ClipboardRawData(entry: entry([webCopy, [(.png, ClipboardWebCopies.picture.png)], [(unknown, Data())]]))
        func written(_ number: Int) -> Bool { raw.flavors[number - 1].copy?.write(to: board) == true }

        board.clearContents(); board.setString("earlier", forType: .string)
        check(written(1) && only(board, tokenType) && board.data(forType: tokenType) == token, "bytes copy as the original data under their own type, alone")
        check(board.string(forType: .string) == nil, "copying replaces what the clipboard held")
        check(written(2) && board.string(forType: .string) == address && only(board, .string), "the source URL copies as a plain string")
        check(written(3) && board.string(forType: .string) == markup && only(board, .string), "HTML copies as its markup, a plain string")
        check(written(5) && board.data(forType: .png) == ClipboardWebCopies.picture.png && only(board, .png), "a picture copies as its own bytes")
        check(raw.flavors[5].copy == nil, "an empty flavor has nothing to copy")
        check(raw.flavors[1].copy == .text(address) && raw.flavors[0].copy == .bytes(tokenType, token), "copy semantics as values")

        let greeting = "héllo 👋 wörld"
        let sixteen = ClipboardRawData(entry: entry([[(utf16, utf16(greeting, mark: true))]]))
        check(sixteen.flavors[0].copy?.write(to: board) == true && board.string(forType: .string) == greeting, "UTF-16 copies as the decoded text, not its bytes")

        let big = String(repeating: "Fixture line of text.\n", count: 140_000)
        let large = ClipboardRawData(entry: entry([[(.string, Data(big.utf8))]]))
        check(large.flavors[0].copy?.write(to: board) == true && board.string(forType: .string) == big, "a text over the cap copies whole (\(big.utf8.count) bytes)")
        check(ClipboardRawCopy.text("part").write(to: board) && board.string(forType: .string) == "part", "a selection copies as a plain string")
    }

    // MARK: The view

    static func host(_ view: NSView, size: NSSize) -> NSPanel {
        let panel = HiddenPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        view.frame = NSRect(origin: .zero, size: size)
        panel.contentView = view
        return panel
    }
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static func key(_ character: String, _ modifiers: NSEvent.ModifierFlags, code: UInt16, in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)!
    }

    static func view(_ app: NSApplication) throws {
        let board = NSPasteboard(name: .init("ClipEdge-raw-data-view-tests-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let png = ClipboardWebCopies.picture.png
        let sample = entry([webCopy, [(.png, png)]])
        let raw = ClipboardRawDataView(frame: .zero, pasteboard: board)
        var copied: [Int] = []
        raw.onCopy = { copied.append($0.number) }
        let panel = host(raw, size: NSSize(width: 470, height: 340))
        raw.show(sample)
        raw.layoutSubtreeIfNeeded()
        let blocks = raw.shownBlocks
        check(blocks.map(\.number) == [1, 2, 3, 4, 5] && blocks.map(\.button) == ["Copy ⌥1", "Copy ⌥2", "Copy ⌥3", "Copy ⌥4", "Copy ⌥5"], "every flavor has Copy with its key")
        check(blocks.allSatisfy { $0.help.contains("(Option-\($0.number))") }, "each button says its key in words")
        check(raw.itemHeadings == ["Item 1 of 2", "Item 2 of 2"], "several items are headed")
        check(raw.overviewText.contains("Copied\t\(sample.fullDateTimeStamp)") && raw.overviewText.contains("SHA-256\tfixture-fingerprint"), "the overview shows its rows")
        check(blocks[0].header == "\(tokenType.rawValue)  the browser's token for the frame it was copied from · 24 bytes", "a header: type, name, size (\(blocks[0].header))")
        check(blocks[0].content?.hasPrefix("0000  00 9f 3c ff 10 00 00 00") == true, "the token shows as a hex dump")
        check(blocks[4].notes == "… \((png.count - 512).formatted()) more bytes\n96 × 64 pixels" || (png.count <= 512 && blocks[4].notes == "96 × 64 pixels"), "the picture's notes: the rest counted, its size (\(blocks[4].notes ?? ""))")
        check(ClipboardRawDataView(frame: .zero).itemHeadings.isEmpty, "a fresh view shows nothing")

        // HTML is never rendered: the text storage holds the markup, character for character.
        let html = raw.contentView(of: 3)!
        check(html.string == markup && blocks[2].content == markup, "the HTML block holds its literal markup")
        check(!html.isRichText && !html.isEditable && html.isSelectable && !html.importsGraphics, "content views are plain, selectable and never editable")
        var rendered = false
        html.textStorage?.enumerateAttributes(in: NSRange(location: 0, length: html.textStorage?.length ?? 0)) { attributes, _, _ in
            if attributes[.link] != nil || attributes[.attachment] != nil { rendered = true }
        }
        check(!rendered, "no link or attachment was made from the markup")
        check(!descendants(raw).contains { NSStringFromClass(type(of: $0)).contains("WebView") }, "no web view anywhere")
        let figmaView = ClipboardRawDataView(frame: .zero, pasteboard: board)
        let figmaPanel = host(figmaView, size: NSSize(width: 470, height: 340))
        figmaView.show(entry([ClipboardWebCopies.figma()]))
        figmaView.layoutSubtreeIfNeeded()
        check(figmaView.shownBlocks.contains { $0.content?.contains("<span data-metadata=\"<!--(figmeta)") == true }, "a Figma copy's HTML shows its hidden description as markup")
        withExtendedLifetime(figmaPanel) {}

        // Copy by button, then by number; the button says what happened.
        raw.button(of: 2)!.performClick(nil)
        check(board.string(forType: .string) == address && copied == [2], "the button copies its flavor and tells the container")
        check(raw.shownBlocks.map(\.button) == ["Copy ⌥1", "Copied ⌥2", "Copy ⌥3", "Copy ⌥4", "Copy ⌥5"], "the copied flavor's button says so")
        check(raw.copyFlavor(number: 1) && board.data(forType: tokenType) == token && raw.copiedNumber == 1, "copying by number")
        check(raw.shownBlocks[1].button == "Copy ⌥2" && raw.shownBlocks[0].button == "Copied ⌥1", "only the last copy says Copied")
        check(!raw.copyFlavor(number: 6) && !raw.copyFlavor(number: 0) && copied == [2, 1], "no such flavor, no copy")
        raw.show(sample)
        check(raw.copiedNumber == nil && raw.shownBlocks[0].button == "Copy ⌥1", "a new show forgets the copy")

        // What a container keeps showing: the same entry copied again (only its time moves) keeps its
        // parts, *Copied* and the overview's new time; another entry starts over; nothing clears it.
        raw.copyFlavor(number: 2)
        let keptText = raw.contentView(of: 3)
        sample.capturedAt = sample.capturedAt.addingTimeInterval(3_600)
        raw.keepShowing(sample)
        check(raw.copiedNumber == 2 && raw.contentView(of: 3) === keptText && raw.overviewText.contains("Copied\t\(sample.fullDateTimeStamp)"),
              "the same entry copied again keeps its parts and *Copied*, its overview taking the new time")
        raw.keepShowing(entry([webCopy], fingerprint: "another"))
        check(raw.copiedNumber == nil && raw.contentView(of: 3) !== keptText && raw.shownBlocks.count == 4, "another entry starts over")
        raw.keepShowing(nil)
        check(raw.entryID == nil && raw.shownBlocks.isEmpty, "and nothing clears it")
        raw.show(sample)

        // Selection and its keys: just the selected part, as plain text.
        let plain = raw.contentView(of: 4)!
        check(panel.makeFirstResponder(plain), "a content view takes the keyboard when clicked")
        plain.setSelectedRange(NSRange(location: 7, length: 4))
        check(raw.selectedText == "sync", "the selection is read")
        check(raw.handleEditingKey(key("c", .command, code: 8, in: panel)) && board.string(forType: .string) == "sync" && only(board, .string), "⌘C copies just the selection")
        plain.setSelectedRange(NSRange(location: 3, length: 0))
        check(!raw.handleEditingKey(key("c", .command, code: 8, in: panel)), "⌘C with nothing selected is left to the container")
        check(raw.handleEditingKey(key("a", .command, code: 0, in: panel)) && plain.selectedRange() == NSRange(location: 0, length: (plain.string as NSString).length), "⌘A selects all of that text")
        check(!raw.handleEditingKey(key("v", .command, code: 9, in: panel)) && !raw.handleEditingKey(key("c", [], code: 8, in: panel)), "other keys are left alone")
        panel.makeFirstResponder(nil)
        check(!raw.handleEditingKey(key("c", .command, code: 8, in: panel)) && raw.selectedText == nil, "with the keyboard elsewhere, nothing is handled")

        // Keys come from the container; flavors past nine have none; an empty flavor cannot copy.
        let many: Values = (0..<11).map { (NSPasteboard.PasteboardType("com.clipedge.fixture.flavor\(String(format: "%02d", $0))"), $0 == 10 ? Data() : Data("value \($0)".utf8)) }
        let keyed = ClipboardRawDataView(frame: .zero, keys: { $0 <= 9 ? ClipboardKeyLabel(shown: "⌃\($0)", spoken: "Control-\($0)") : nil }, pasteboard: board)
        let keyedPanel = host(keyed, size: NSSize(width: 470, height: 340))
        keyed.show(entry([many]))
        keyed.layoutSubtreeIfNeeded()
        let keyedBlocks = keyed.shownBlocks
        check(keyedBlocks[0].button == "Copy ⌃1" && keyedBlocks[8].button == "Copy ⌃9" && keyedBlocks[0].help.contains("(Control-1)"), "the container's keys title the buttons")
        check(keyedBlocks[9].button == "Copy" && keyedBlocks[9].help.contains("Only the first nine flavors have keys"), "the tenth flavor has no key and says so")
        check(!keyedBlocks[10].isEnabled && keyedBlocks[10].content == nil && keyedBlocks[10].notes == "Empty: this flavor holds no bytes."
              && keyedBlocks[10].help.hasPrefix("Nothing to copy"), "an empty flavor shows no box and cannot copy, and says why")
        check(keyed.itemHeadings.isEmpty, "one item has no heading")
        withExtendedLifetime(keyedPanel) {}

        // A copy of many items (Finder's of many files): a batch of flavors built at once, the rest as the
        // column is scrolled near its end, each read only when built.
        let manyItems = (1...60).map { [(NSPasteboard.PasteboardType.string, Data("Item \($0) of a many-item fixture".utf8))] as Values }
        let batched = ClipboardRawDataView(frame: .zero, pasteboard: board)
        let batchedPanel = host(batched, size: NSSize(width: 470, height: 340))
        batched.show(entry(manyItems))
        batched.layoutSubtreeIfNeeded()
        let firstBatch = batched.shownBlocks.count
        check(firstBatch == ClipboardRawDataView.batch && batched.itemHeadings.count == firstBatch
              && batched.moreNote == "… \(60 - firstBatch) more flavors below, shown as you scroll.", "the first \(firstBatch) flavors are built, the rest counted")
        check(batched.raw?.flavors.prefix(firstBatch).allSatisfy(\.isRead) == true && batched.raw?.flavors.dropFirst(firstBatch).allSatisfy({ !$0.isRead }) == true,
              "only the flavors built have been read")
        check(batched.copyFlavor(number: 9) && board.string(forType: .string) == "Item 9 of a many-item fixture", "⌥9 reaches one of them")
        check(batched.copyFlavor(number: 50) && board.string(forType: .string) == "Item 50 of a many-item fixture", "Copy reaches a flavor not built yet too")
        var pages = 0
        while batched.moreNote != nil, pages < 200 {
            batched.page(.down)
            batched.layoutSubtreeIfNeeded()
            pages += 1
        }
        let builtFrames = descendants(batched).compactMap { $0 as? NSButton }.map(\.frame.minY)
        check(batched.shownBlocks.map(\.number) == Array(1...60) && batched.moreNote == nil && builtFrames == builtFrames.sorted(),
              "scrolling down builds the rest, in order, each below the last (\(pages) pages)")
        withExtendedLifetime(batchedPanel) {}

        // The 3 MB text: its first 64 KB, the note, and still quick enough to flip to.
        let big = "a" + String(repeating: "é", count: 1_499_999) + "z"
        let started = Date()
        raw.show(entry([[(.string, Data(big.utf8))]]))
        raw.layoutSubtreeIfNeeded()
        let elapsed = Date().timeIntervalSince(started)
        check(raw.shownBlocks[0].content?.utf8.count == 63_999 && raw.shownBlocks[0].notes == "First 64 KB of 3 MB shown; Copy copies all.", "a large text shows its first 64 KB and says so")
        check(elapsed < 2, "a 3 MB text shows in under two seconds (\(String(format: "%.2f", elapsed)) s)")
        check(raw.copyFlavor(number: 1) && board.string(forType: .string) == big, "and copies all of it")

        // Nothing cut short, in the window's card and in the drawer's Quick Look, light and dark.
        for theme in [NSAppearance.Name.aqua, .darkAqua] {
            app.appearance = NSAppearance(named: theme)
            for (place, size, perRow) in [("window card", NSSize(width: 470, height: 340), 8), ("drawer Quick Look", NSSize(width: 640, height: 520), 16)] {
                let built = ClipboardRawDataView(frame: .zero, pasteboard: board)
                let builtPanel = host(built, size: size)
                built.show(entry([webCopy, [(.png, png), (.tiff, ClipboardWebCopies.picture.tiff)], [(.rtf, Data("{\\rtf1\\ansi A long-enough rich text fixture so that its source wraps across several lines in the box at either size.}".utf8)), (unknown, Data())]]))
                settle(0.05)
                built.layoutSubtreeIfNeeded()
                expectLaidOut(built, "\(place), \(theme == .darkAqua ? "dark" : "light")", bytesPerRow: perRow)
                expectPainted(built, dark: theme == .darkAqua, "\(place) built \(theme == .darkAqua ? "dark" : "light")")
                // Switch appearance after building: the surfaces follow.
                let other: NSAppearance.Name = theme == .aqua ? .darkAqua : .aqua
                app.appearance = NSAppearance(named: other)
                settle(0.05)
                expectPainted(built, dark: other == .darkAqua, "\(place) switched to \(other == .darkAqua ? "dark" : "light")")
                app.appearance = NSAppearance(named: theme)
                settle(0.05)
                withExtendedLifetime(builtPanel) {}
            }
        }
        app.appearance = NSAppearance(named: .aqua)
        withExtendedLifetime(panel) {}
    }

    /// Every label shows all of its words, every button its whole title, every text all of its
    /// lines; a hex dump's rows never wrap; nothing reaches past the column or overlaps.
    static func expectLaidOut(_ view: ClipboardRawDataView, _ moment: String, bytesPerRow: Int) {
        let column = view.documentFrame
        check(abs(column.width - view.visibleWidth) < 0.5, "\(moment): the column is as wide as what shows, so nothing scrolls sideways")
        let scroller = descendants(view).compactMap { $0 as? NSScrollView }.first
        check(scroller?.hasHorizontalScroller == false, "\(moment): no sideways scroller")
        let parts = scroller?.documentView?.subviews.filter { !$0.isHidden } ?? []
        check(parts.count >= 10, "\(moment): the column holds its parts (\(parts.count))")
        var visible: [NSRect] = []
        for part in parts {
            check(part.frame.minX >= 0 && part.frame.maxX <= column.width + 0.5, "\(moment): \(type(of: part)) stays inside the column (\(part.frame))")
            visible.append(part.frame)
        }
        for (index, frame) in visible.enumerated() {
            for other in visible[(index + 1)...] where frame.intersects(other) {
                check(false, "\(moment): parts overlap (\(frame) and \(other))")
            }
        }
        for label in descendants(view).compactMap({ $0 as? NSTextField }) where !label.isHiddenOrHasHiddenAncestor {
            let needed = ceil(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.frame.width, height: 100_000)).height ?? 0)
            check(needed <= label.frame.height + 0.5, "\(moment): the label \"\(label.stringValue.prefix(40))\" shows all its lines (\(needed) > \(label.frame.height))")
        }
        for button in descendants(view).compactMap({ $0 as? NSButton }) where !button.isHiddenOrHasHiddenAncestor {
            check(button.frame.width >= button.intrinsicContentSize.width, "\(moment): \(button.title) shows its whole title")
        }
        var dumps = 0
        for text in descendants(view).compactMap({ $0 as? NSTextView }) where !text.isHiddenOrHasHiddenAncestor {
            guard let layout = text.layoutManager, let container = text.textContainer else { continue }
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container).height + text.textContainerInset.height * 2
            check(used <= text.frame.height + 0.5, "\(moment): a text view shows all of its lines (\(used) > \(text.frame.height))")
            guard text.string.hasPrefix("0000  ") else { continue }
            dumps += 1
            let rows = text.string.components(separatedBy: "\n")
            var fragments = 0
            layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, _, _ in fragments += 1 }
            check(fragments == rows.count, "\(moment): no hex row wraps (\(fragments) lines for \(rows.count) rows)")
            check(rows[0].count == ClipboardRawData.hexLineLength(bytesPerRow: bytesPerRow), "\(moment): the dump has \(bytesPerRow) bytes a row (\(rows[0].count) characters)")
        }
        check(dumps == 3, "\(moment): the token, the PNG and the TIFF are dumped (\(dumps))")
    }

    /// Each painted part (the content boxes) shows its ground in its own appearance, and the
    /// text inside reads against it.
    static func expectPainted(_ view: ClipboardRawDataView, dark: Bool, _ moment: String) {
        let isDark = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        check(isDark == dark, "\(moment): AppKit gave the view the \(dark ? "dark" : "light") appearance")
        let surfaces = descendants(view).compactMap { $0 as? ClipboardSurfaceView }.filter { !$0.isHiddenOrHasHiddenAncestor && $0 !== view }
        check(surfaces.count >= 6, "\(moment): each flavor with content has a box (\(surfaces.count))")
        for surface in surfaces {
            var fill: CGColor?
            surface.effectiveAppearance.performAsCurrentDrawingAppearance { fill = surface.surface.fill?.resolved.cgColor }
            let expected = fill.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }
            let actual = surface.layer?.backgroundColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }
            check(expected != nil && actual != nil && abs(expected!.redComponent - actual!.redComponent) < 0.02
                  && abs(expected!.greenComponent - actual!.greenComponent) < 0.02, "\(moment): a box paints its ground in its own appearance")
            let ground = luminance(actual)
            check(dark ? ground < 0.3 : ground > 0.9, "\(moment): a box's ground reads \(dark ? "dark" : "light") (\(ground))")
        }
        // The first box's text stands out from its ground.
        guard let box = surfaces.first else { return }
        let rep = box.bitmapImageRepForCachingDisplay(in: box.bounds)!
        box.cacheDisplay(in: box.bounds, to: rep)
        var values: [CGFloat] = []
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) { if let color = rep.colorAt(x: x, y: y) { values.append(luminance(color)) } }
        }
        let ground = luminance(box.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) })
        check(values.contains { abs($0 - ground) > 0.4 }, "\(moment): a box's text is legible on its ground")
    }
    static func luminance(_ color: NSColor?) -> CGFloat {
        guard let c = color?.usingColorSpace(.sRGB) else { return -1 }
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    }

    // MARK: The flip

    /// Work the flip schedules, run by hand.
    final class Steps {
        var pending: [(delay: TimeInterval, work: () -> Void)] = []
        func next() { pending.removeFirst().work() }
        func drain() { while !pending.isEmpty { next() } }
    }
    static func face(_ color: NSColor) -> ClipboardSurfaceView {
        let face = ClipboardSurfaceView(frame: .zero)
        face.surface = ClipboardSurface(fill: .init(color: color))
        return face
    }
    /// The snapshot's colour at its middle: red or blue.
    static func middle(_ image: NSImage?) -> NSColor? {
        guard let rep = image?.representations.first as? NSBitmapImageRep else { return nil }
        return rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB)
    }
    static func isRed(_ color: NSColor?) -> Bool { (color?.redComponent ?? 0) > 0.8 && (color?.blueComponent ?? 1) < 0.4 }
    static func isBlue(_ color: NSColor?) -> Bool { (color?.blueComponent ?? 0) > 0.8 && (color?.redComponent ?? 1) < 0.4 }

    static func flip(_ app: NSApplication) {
        // Which transition, as a table.
        check(ClipboardFlipView.transition(animated: true, reducesMotion: false, canDraw: true, snapshottable: true) == .turn, "a turn by default")
        check(ClipboardFlipView.transition(animated: true, reducesMotion: true, canDraw: true, snapshottable: true) == .crossfade, "Reduce Motion crossfades")
        check(ClipboardFlipView.transition(animated: true, reducesMotion: false, canDraw: true, snapshottable: false) == .crossfade, "a face that cannot be snapshotted crossfades")
        check(ClipboardFlipView.transition(animated: false, reducesMotion: false, canDraw: true, snapshottable: true) == .instant, "asked for at once, instant")
        check(ClipboardFlipView.transition(animated: true, reducesMotion: true, canDraw: false, snapshottable: true) == .instant, "not drawn anywhere, instant")

        // Quick Look's preview cannot be snapshotted; a hidden one does not count.
        let quickLook = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let preview = QLPreviewView(frame: quickLook.bounds, style: .normal)!
        quickLook.addSubview(preview)
        check(!ClipboardFlipView.drawsItself(quickLook) && !ClipboardFlipView.drawsItself(preview), "a face showing Quick Look's preview does not draw itself")
        preview.isHidden = true
        check(ClipboardFlipView.drawsItself(quickLook) && ClipboardFlipView.drawsItself(NSView()), "a hidden preview, or none, draws itself")

        // Outside a window: at once.
        let loose = ClipboardFlipView(front: face(.systemRed), back: face(.systemBlue))
        var landed: [ClipboardFlipView.Side] = []
        loose.onTurned = { landed.append($0) }
        check(loose.side == .front && !loose.front.isHidden && loose.back.isHidden, "a flip view starts on its front")
        loose.flip()
        check(loose.side == .back && loose.turning == nil && loose.front.isHidden && !loose.back.isHidden && landed == [.back], "outside a window it turns at once")

        // In a window: the rotation, from snapshots, swapping halfway.
        app.appearance = NSAppearance(named: .aqua)
        let flip = ClipboardFlipView(front: face(.systemRed), back: face(.systemBlue))
        let steps = Steps()
        flip.after = { delay, work in steps.pending.append((delay, work)) }
        flip.reducesMotion = { false }
        var began: [ClipboardFlipView.Side] = []
        var turned: [ClipboardFlipView.Side] = []
        flip.onTurn = { side in
            began.append(side)
            check(!(side == .back ? flip.front : flip.back).isHidden, "the keyboard can move before the outgoing face hides")
        }
        flip.onTurned = { turned.append($0) }
        let panel = host(flip, size: NSSize(width: 470, height: 340))
        flip.layoutSubtreeIfNeeded()
        check(flip.front.frame == flip.bounds && flip.back.frame == flip.bounds, "both faces fill the flip view")
        flip.flip()
        check(began == [.back] && flip.side == .back && flip.turning == .turn && flip.turningFace == .front, "a turn to the back begins with the front's snapshot")
        check(flip.front.isHidden && flip.back.isHidden, "while turning, neither face is live")
        check(flip.turningImage?.size == flip.bounds.size && isRed(middle(flip.turningImage)), "the first half shows the front (\(String(describing: middle(flip.turningImage))))")
        check(steps.pending.count == 1 && abs(steps.pending[0].delay - flip.duration / 2) < 0.001, "the swap waits half the turn")
        steps.next()
        check(flip.turningFace == .back && isBlue(middle(flip.turningImage)) && flip.turning == .turn, "halfway, the snapshot swaps to the back")
        check(steps.pending.count == 1 && turned.isEmpty, "the second half is under way")
        steps.next()
        check(flip.turning == nil && flip.turningImage == nil && flip.front.isHidden && !flip.back.isHidden && flip.back.alphaValue == 1 && turned == [.back], "the turn lands on the back")
        flip.flip()
        check(flip.turningFace == .back && isBlue(middle(flip.turningImage)), "turning back starts from the back")
        steps.drain()
        check(flip.side == .front && !flip.front.isHidden && flip.back.isHidden && turned == [.back, .front], "and lands on the front")

        // Reduce Motion: a crossfade, both faces drawn, then the outgoing one hides.
        flip.reducesMotion = { true }
        flip.flip()
        check(flip.turning == .crossfade && !flip.front.isHidden && !flip.back.isHidden && flip.turningImage == nil, "Reduce Motion crossfades, without a turning snapshot")
        check(steps.pending.count == 1 && abs(steps.pending[0].delay - flip.fadeDuration) < 0.001, "the crossfade is short")
        steps.next()
        check(flip.turning == nil && flip.front.isHidden && !flip.back.isHidden && flip.front.alphaValue == 1 && flip.back.alphaValue == 1, "the crossfade lands opaque on the back")
        flip.reducesMotion = { false }

        // A face that cannot be snapshotted crossfades too.
        flip.canSnapshot = { $0 !== flip.front }
        flip.flip()
        check(flip.turning == .crossfade, "an unsnapshottable face crossfades")
        steps.drain()
        check(flip.side == .front && !flip.front.isHidden, "and lands")
        flip.canSnapshot = ClipboardFlipView.drawsItself

        // A second flip mid-turn lands the first at once and turns back; the first's work does nothing.
        flip.flip()
        let stale = steps.pending
        steps.pending = []
        flip.flip()
        check(turned.last == .back, "the first turn landed on the back at once")
        check(flip.side == .front && flip.turning == .turn && flip.turningFace == .back, "the second turn heads to the front")
        stale.forEach { $0.work() }
        check(flip.turning == .turn && flip.turningFace == .back && flip.side == .front, "work left from the first turn does nothing")
        steps.drain()
        check(flip.side == .front && !flip.front.isHidden && flip.back.isHidden && flip.turning == nil, "the second turn lands on the front")

        // show(_:) is at once, mid-turn too: every opening starts on the front.
        flip.flip()
        flip.show(.front)
        check(flip.side == .front && flip.turning == nil && !flip.front.isHidden && flip.back.isHidden && flip.turningImage == nil, "show(.front) lands on the front at once")
        steps.drain()
        check(flip.side == .front && flip.turning == nil && !flip.front.isHidden, "nothing scheduled moves it after")
        flip.show(.front)
        check(flip.side == .front, "showing the side already showing changes nothing")

        // The snapshot is upright: a face red above and blue below turns that way up.
        let split = ClipboardSurfaceView(frame: .zero)
        split.surface = ClipboardSurface(fill: .init(color: .systemBlue))
        let upper = ClipboardSurfaceView(frame: .zero)
        upper.surface = ClipboardSurface(fill: .init(color: .systemRed))
        split.addSubview(upper)
        let upright = ClipboardFlipView(front: split, back: face(.systemBlue))
        upright.after = { delay, work in steps.pending.append((delay, work)) }
        upright.reducesMotion = { false }
        let uprightPanel = host(upright, size: NSSize(width: 200, height: 100))
        upright.layoutSubtreeIfNeeded()
        upper.frame = NSRect(x: 0, y: split.isFlipped ? 0 : 50, width: 200, height: 50)
        upright.flip()
        let rep = upright.turningImage?.representations.first as? NSBitmapImageRep
        check(isRed(rep?.colorAt(x: (rep?.pixelsWide ?? 0) / 2, y: 4)?.usingColorSpace(.sRGB))
              && isBlue(rep?.colorAt(x: (rep?.pixelsWide ?? 0) / 2, y: (rep?.pixelsHigh ?? 0) - 4)?.usingColorSpace(.sRGB)), "the turning snapshot is the right way up")
        steps.drain()
        withExtendedLifetime(uprightPanel) {}

        // Hidden (Send to has the card's place): at once.
        flip.isHidden = true
        flip.flip()
        check(flip.side == .back && flip.turning == nil && steps.pending.isEmpty, "a hidden flip view turns at once")
        flip.isHidden = false
        flip.show(.front)

        // The default scheduler: a real turn completes on the run loop.
        let real = ClipboardFlipView(front: face(.systemRed), back: ClipboardRawDataView(frame: .zero))
        real.reducesMotion = { false }
        (real.back as! ClipboardRawDataView).show(entry([webCopy]))
        let realPanel = host(real, size: NSSize(width: 470, height: 340))
        real.layoutSubtreeIfNeeded()
        real.flip()
        check(real.turning == .turn, "the raw data view can be snapshotted")
        // Polled, not timed: a busy machine delays both halves alike, and each half lasts 0.175 s.
        var backSnapshot: NSBitmapImageRep?
        let deadline = Date().addingTimeInterval(3)
        while real.turning != nil, Date() < deadline {
            if backSnapshot == nil, real.turningFace == .back { backSnapshot = real.turningImage?.representations.first as? NSBitmapImageRep }
            settle(0.01)
        }
        check(backSnapshot != nil, "halfway on the run loop, the back's snapshot shows")
        var shades = Set<Int>()
        if let backSnapshot {
            for y in stride(from: 0, to: backSnapshot.pixelsHigh, by: 6) {
                for x in stride(from: 0, to: backSnapshot.pixelsWide, by: 6) {
                    if let color = backSnapshot.colorAt(x: x, y: y), color.alphaComponent > 0.5 { shades.insert(Int(luminance(color) * 10)) }
                }
            }
        }
        check(shades.count >= 3, "the raw data's snapshot shows its text and boxes, not a blank (\(shades.count) shades)")
        check(real.side == .back && real.turning == nil && !real.back.isHidden && real.front.isHidden, "the turn landed on its own")
        withExtendedLifetime((panel, realPanel)) {}
    }
}

/// A real window that is never ordered on screen.
private final class HiddenPanel: NSPanel {
    private var fixtureVisible = false
    override var isVisible: Bool { fixtureVisible }
    override func orderFrontRegardless() { fixtureVisible = true }
    override func makeKeyAndOrderFront(_ sender: Any?) { fixtureVisible = true }
    override func orderOut(_ sender: Any?) { fixtureVisible = false }
    override func makeKey() {}
    override func resignKey() {}
}
