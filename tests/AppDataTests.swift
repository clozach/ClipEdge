import AppKit
import PDFKit

/// App data (an app's own clipboard format) and the Other tab: recognition by
/// type, naming, pictures in any format, the four tabs on every kind, the
/// window's ⌘3, the drawer's tab rule, every surface, plain-text paste, search,
/// byte-for-byte write-back and launch timing. Made-up copies on named boards.
@main enum AppDataTests {
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
    private static func appData(_ entry: ClipboardEntry) -> ClipboardAppData? {
        if case .appData(let data) = entry.kind { return data }; return nil
    }
    private static func type(_ name: String) -> NSPasteboard.PasteboardType { NSPasteboard.PasteboardType(name) }
    private static func key(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = [], _ characters: String = "") -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }
    /// A picture in a format outside the old fixed set (PNG, TIFF, JPEG, GIF, PDF).
    private static let bmp: Data = {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .bmp, properties: [:])!
    }()
    private static let only = ClipboardWebCopies.appDataOnly
    private static let pictured = ClipboardWebCopies.appDataWithPicture
    private static let iWork = ClipboardWebCopies.iWorkWithPicture

    static func main() throws {
        _ = NSApplication.shared
        tableChecks()
        namingChecks()
        recognitionChecks()
        tabChecks()
        windowChecks()
        drawerChecks()
        try surfaceChecks()
        storeChecks()
        timingChecks()
        print("PASS: \(assertions) app-data and Other-tab assertions; made-up copies, named boards")
    }

    // MARK: Recognition

    /// One table: what ClipEdge reads, what a pasteboard adds, and everything else.
    private static func tableChecks() {
        typealias Role = ClipboardAppData.Role
        for known in ["public.utf8-plain-text", "public.utf16-external-plain-text", "public.rtf", "com.apple.flat-rtfd", "public.html", "com.apple.webarchive",
                      "public.png", "public.tiff", "public.jpeg", "com.compuserve.gif", "com.adobe.pdf", "public.heic", "com.microsoft.bmp", "public.file-url",
                      "public.url", "public.vcard", "com.apple.finder.node", "com.apple.icns", "CorePasteboardFlavorType 0x6675726C", "NSFilenamesPboardType",
                      // Declared text and document formats Quick Look is handed as typed files.
                      "net.daringfireball.markdown", "com.apple.property-list", "com.apple.ical.ics"] {
            check(ClipboardAppData.role(of: known) == .known, "\(known) is a format ClipEdge reads")
        }
        for bookkeeping in ["org.chromium.source-url", "org.chromium.internal.source-rfh-token", "org.chromium.web-custom-data", "org.nspasteboard.source",
                            "org.mozilla.custom-clipdata", "org.mozilla.file-urls",
                            "org.nspasteboard.TransientType", "com.apple.WebKit.custom-pasteboard-data", "com.apple.linkpresentation.metadata",
                            "com.apple.pasteboard.promised-file-url", "com.apple.pasteboard.promised-file-content-type", "com.apple.NSFilePromiseItemMetaData",
                            "NeXT smart paste pasteboard type", "dyn.ah62d4rv4gu8yc6durvwwaznwmuuha2pxsvw0e55bsmwca7d3sbwu"] {
            check(ClipboardAppData.role(of: bookkeeping) == .bookkeeping, "\(bookkeeping) is a pasteboard's bookkeeping")
        }
        for app in ["com.apple.iWork.pasteboard", "com.apple.iWork.TSPNativeData", "com.apple.notes.richtext", "com.bohemiancoding.sketch.clipboard",
                    "com.adobe.photoshop", "com.figma.layers", "com.clipedge.fixture.sketchlike", "com.tinycast.internal", "com.microsoft.Art--GVML-ClipFormat", "Opaque",
                    "com.apple.iwork.keynote.key", "com.microsoft.word.doc"] {
            check(ClipboardAppData.role(of: app) == .app, "\(app) is an app's own format")
        }
        check(ClipboardAppData(types: ["public.utf8-plain-text", "public.html", "org.chromium.source-url"]) == nil, "known and bookkeeping formats alone are not app data")
        check(ClipboardAppData(types: ["public.utf8-plain-text", "public.html", "org.mozilla.custom-clipdata"]) == nil, "text copied in Firefox, with its note of the page's custom types, is not app data")
        check(ClipboardAppData(types: ["public.utf8-plain-text", "net.daringfireball.markdown"]) == nil, "a declared text or document format beside text is not app data")
        check(ClipboardAppData(types: ["com.apple.photos.pasteboard", "com.apple.NSFilePromiseItemMetaData"])?.name == "Photos", "a file promise's note never names a copy; the app's own format does")
        check(ClipboardAppData(types: ["com.apple.WebKit.custom-pasteboard-data", "com.apple.linkpresentation.metadata"]) == nil, "bookkeeping alone is not app data")
        check(ClipboardAppData(types: []) == nil, "no formats, no app data")
        let notes = ClipboardAppData(types: ["com.apple.notes.richtext", "org.nspasteboard.source", "public.rtf", "public.utf8-plain-text"])
        check(notes?.name == "Notes" && notes?.formats == ["com.apple.notes.richtext", "public.rtf", "public.utf8-plain-text"],
              "app data lists every format but the bookkeeping, in the item's order (\(notes?.formats ?? []))")
        check(notes?.title == "Notes data" && notes?.formatsFact == "3 formats" && notes?.facts == ["Notes data", "3 formats"], "its title names the app; its facts count the formats")
        check(ClipboardAppData(types: ["com.clipedge.fixture.sketchlike"])?.formatsFact == "1 format", "one format reads in the singular")
        check(ClipboardAppData.explanation == "Pastes back into the app it came from, exactly as copied.", "the explanation as written")
    }

    /// Reverse DNS read as people would: the app's own label, its capitals kept.
    private static func namingChecks() {
        let names: [(String, String)] = [
            ("com.apple.iWork.pasteboard", "iWork"), ("com.apple.iWork.TSPNativeData", "iWork"), ("com.apple.notes.richtext", "Notes"),
            ("com.bohemiancoding.sketch.clipboard", "Sketch"), ("com.adobe.photoshop", "Photoshop"), ("com.figma.layers", "Layers"), ("com.figma.clipboard", "Figma"),
            ("com.clipedge.fixture.sketchlike", "Fixture"), ("com.apple.cocoa.pasteboard.color", "Cocoa"),
            // A label that is no word, or names no app, gives way to the vendor.
            ("com.microsoft.Art--GVML-ClipFormat", "Microsoft"), ("com.tinycast.internal", "Tinycast"), ("org.clipedge.fixture-opaque", "Clipedge"),
            ("com.example.pasteboard", "Example"), ("com.example.123", "Example"),
            // Nothing to read as a name.
            ("Opaque", "App"), ("com.---.9x", "App"), ("com.9lives", "App")
        ]
        for (type, name) in names { check(ClipboardAppData.name(forType: type) == name, "\(type) is named \(name) (got \(ClipboardAppData.name(forType: type)))") }
        check(ClipboardAppData(types: ["com.apple.notes.richtext", "com.apple.iWork.pasteboard"])?.name == "Notes", "several app formats: the first names the copy")
    }

    private static func recognitionChecks() {
        let alone = entry(only)
        guard let data = appData(alone) else { fatalError("FAIL: an app's own format alone is app data") }
        check(alone.title == "Fixture data" && alone.detail == "1 format" && data.formats == ["com.clipedge.fixture.sketchlike"], "titled by its app, counted by its formats (\(alone.title) · \(alone.detail))")
        check(alone.appData == data && alone.metadata.facts == ["1 format"] && alone.edgeText == "1 format", "the entry carries the same app data; its facts count the formats")
        check(alone.thumbnail == nil && alone.kind.iconName == "shippingbox" && NSImage(systemSymbolName: alone.kind.iconName, accessibilityDescription: nil) != nil,
              "app data without a picture shows a box symbol, available on this macOS")
        check(alone.readableText == nil && alone.swatchColor == nil && !alone.isImage, "it has no text to show and no picture")
        check(alone.plainTextForPaste == "Fixture data\ncom.clipedge.fixture.sketchlike", "a plain-text paste gives its name and formats, never a beep")
        check(alone.matches("Fixture data") && alone.matches("app data") && alone.matches("sketchlike"), "search finds it by name, 'app data' and format")

        let picture = entry(pictured)
        check(picture.kind == .image && picture.thumbnail != nil && picture.title == "Image" && picture.isImage, "app data with a PNG is a picture, thumbnail and all")
        check(picture.appData?.name == "Fixture" && picture.appData?.formats == ["com.clipedge.fixture.sketchlike", "public.png"], "and still carries its app data")
        check(picture.metadata.facts == ["96 × 64", ByteCountFormatter.string(fromByteCount: Int64(ClipboardWebCopies.picture.png.count), countStyle: .file), "PNG", "Fixture data", "2 formats"],
              "its facts: the picture's, then the app's name and format count (\(picture.metadata.facts))")
        check(picture.plainTextForPaste == picture.metadata.line && picture.plainTextForPaste.contains("Fixture data · 2 formats"), "⌃⌘V pastes its facts, as a picture's")
        check(picture.matches("Fixture") && picture.matches("sketchlike"), "search finds a picture by its app data")
        let keynote = entry(iWork)
        check(keynote.kind == .image && keynote.appData?.name == "iWork" && keynote.metadata.facts.suffix(3) == ["TIFF", "iWork data", "2 formats"],
              "an iWork-style copy with a TIFF is that picture, named iWork (\(keynote.metadata.facts))")

        let bookkeeping = entry(ClipboardWebCopies.bookkeepingOnly)
        check(bookkeeping.kind == .other && bookkeeping.appData == nil && bookkeeping.title == "Clipboard item", "a browser's and the pasteboard's notes alone are an unknown item, never app data")
        check(bookkeeping.metadata.facts.isEmpty && bookkeeping.metadata.site == "example.com" && bookkeeping.plainTextForPaste.isEmpty, "it keeps only the site it came from, and pastes nothing")
        check(entry([(.html, Data("<span style=\"color:red\"></span>".utf8))]).kind == .other, "HTML that strips to nothing stays an unknown item")
        let blankWithApp = entry([(.html, Data("<span></span>".utf8)), (ClipboardWebCopies.sketchLike, Data([1]))])
        check(appData(blankWithApp) != nil, "HTML that strips to nothing beside an app's format is that app's data")

        // Pictures in any format, however an app names them.
        let bitmap = entry([(type("com.microsoft.bmp"), bmp)])
        check(bitmap.kind == .image && bitmap.thumbnail != nil && bitmap.metadata.facts == ["48 × 32", ByteCountFormatter.string(fromByteCount: Int64(bmp.count), countStyle: .file), "BMP"] && bitmap.appData == nil,
              "a BMP is a picture with its own facts, not an unknown item (\(bitmap.metadata.facts))")
        check(entry([(type("com.clipedge.fixture.notapicture"), bmp)]).kind != .image, "a format that is not an image is not decoded as one")
        check(entry([(.png, Data([1, 2, 3])), (ClipboardWebCopies.sketchLike, Data([1]))]).kind != .image, "a picture that does not decode is not a picture")

        // Text or Figma layers beside an app's format keep their kind and add the app's facts.
        let note = entry([(.string, Data("Fixture note from an app".utf8)), (type("com.apple.notes.richtext"), Data([1]))])
        check(note.kind == .text && note.appData?.name == "Notes" && note.metadata.facts == ["5 words", "24 characters", "Notes data", "2 formats"],
              "text from an app keeps its counts and names the app after them (\(note.metadata.facts))")
        check(note.plainTextForPaste == "Fixture note from an app" && note.matches("Notes data"), "its words paste; search finds it by the app")
        let layers = entry(ClipboardWebCopies.figma())
        check(appData(layers) == nil && layers.appData == nil, "Figma layers from a browser carry only known and bookkeeping formats")
        check(entry(ClipboardWebCopies.html(ClipboardWebCopies.plainHTML)).appData == nil && entry(ClipboardWebCopies.chatReply).appData == nil, "web copies are not app data")
    }

    // MARK: Tabs

    private static func tabChecks() {
        typealias Tab = ClipboardBrowserTab
        check(Tab.allCases.map(\.title) == ["All", "Text", "Images", "Other"] && Tab.other.rawValue == 3, "four tabs, Other last")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ClipEdge-app-data-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("note.txt")
        try? Data("note".utf8).write(to: file)
        let cases: [(String, ClipboardEntry, Set<Tab>)] = [
            ("text", entry([(.string, Data("Fixture words".utf8))]), [.all, .text]),
            ("a link", entry([(.string, Data("https://example.com/fixture".utf8))]), [.all, .text]),
            ("HTML-only text", entry(ClipboardWebCopies.html(ClipboardWebCopies.plainHTML)), [.all, .text]),
            ("rich text", entry(ClipboardWebCopies.rtf("Fixture rich")), [.all, .text]),
            ("a picture", entry([(.png, ClipboardWebCopies.picture.png)]), [.all, .images]),
            ("a BMP picture", entry([(type("com.microsoft.bmp"), bmp)]), [.all, .images]),
            ("a Finder item", entry([(.fileURL, Data(file.absoluteString.utf8))]), [.all, .other]),
            ("Figma layers", entry(ClipboardWebCopies.figma()), [.all, .other]),
            ("a Figma cut", entry(ClipboardWebCopies.figma(nodes: "")), [.all, .other]),
            ("a Figma text layer", entry(ClipboardWebCopies.figma(text: "Fixture caption")), [.all, .text, .other]),
            ("app data", entry(only), [.all, .other]),
            ("app data with a picture", entry(pictured), [.all, .images, .other]),
            ("an iWork-style picture", entry(iWork), [.all, .images, .other]),
            ("text from an app", entry([(.string, Data("Fixture note".utf8)), (type("com.apple.notes.richtext"), Data([1]))]), [.all, .text, .other]),
            ("text copied in Firefox", entry([(.html, Data("<p>Fixture words</p>".utf8)), (type("org.mozilla.custom-clipdata"), Data([0, 1, 2])), (.string, Data("Fixture words".utf8))]), [.all, .text]),
            ("bookkeeping only", entry(ClipboardWebCopies.bookkeepingOnly), [.all, .other]),
            ("HTML with nothing to read", entry([(.html, Data("<span></span>".utf8))]), [.all, .other])
        ]
        for (name, entry, tabs) in cases {
            let shown = Set(Tab.allCases.filter { $0.includes(entry) })
            check(shown == tabs, "\(name) is listed under \(tabs.map(\.title).sorted()), not \(shown.map(\.title).sorted())")
        }
        let all = cases.map { $0.1 }
        check(Tab.other.visible(all, query: "sketchlike").map(\.title) == ["Fixture data", "Image"] && Tab.other.visible(all, query: "Notes data").map(\.title) == ["Fixture note"],
              "search within Other finds app data by format and by name, with or without a picture or text")
        check(Tab.images.visible(all, query: "iWork").count == 1 && Tab.text.visible(all, query: "iWork").isEmpty, "search stays within its tab")
    }

    // MARK: The history window

    private static func windowChecks() {
        check(ClipboardKeymap.window.action(for: key(20, .command, "3")) == .tab(.other), "⌘3 (by key position) chooses Other")
        check(ClipboardKeymap.window.action(for: key(29, .command, "0")) == .tab(.all) && ClipboardKeymap.window.action(for: key(18, .command, "1")) == .tab(.text), "⌘0 and ⌘1 choose theirs")
        check(ClipboardKeymap.window.action(for: key(20, [.command, .shift], "3")) == nil && ClipboardKeymap.window.action(for: key(21, .command, "4")) == nil, "⇧⌘3 and ⌘4 are not tabs")
        let view = ClipboardHistoryView(frame: NSRect(origin: .zero, size: ClipboardHistoryController.preferredSize))
        check(view.tabs.segmentCount == 4 && view.tabs.titles.map(\.plain) == ["All ⌘0", "Text ⌘1", "Images ⌘2", "Other ⌘3"], "the window's tabs carry their keys")
        // Publish's widest title, in the corner the tabs share their row with.
        let candidate = PublishCandidate(id: "fixture", version: "2.3.1", fingerprint: String(repeating: "a", count: 64),
                                         archiveSHA256: String(repeating: "b", count: 64), changes: "Fixture", previousVersion: "2.3")
        view.publishControl.apply(PublishState.ready(candidate, PublishDifference(latestVersion: "2.3", detail: "Fixture")).presentation)
        view.layoutSubtreeIfNeeded()
        check(view.tabs.frame.maxX + 8 <= view.publishControl.frame.minX && (0..<4).allSatisfy { view.tabs.width(forSegment: $0) >= view.tabs.titles[$0].size(font: view.tabs.font!).width + 2 * ClipboardTabBar.padding },
              "four labelled segments fit between the list and Publish at its widest, at the window's size, each sized to its whole label (\(view.tabs.frame.maxX) < \(view.publishControl.frame.minX))")
        let placeholder = view.search.placeholderHint.plain, room = (view.search.cell as! NSSearchFieldCell).searchTextRect(forBounds: view.search.bounds).width
        check(placeholder == "Search clipboard and image text  ⌘F" && (view.search.placeholderAttributedString?.size().width ?? .infinity) <= room,
              "the window's search names ⌘F, as the drawer's names F, whole at the window's size (\(room) points)")

        let board = NSPasteboard.withUniqueName()
        let store = ClipboardStore(pasteboard: board, persistenceURL: nil)
        func copy(_ values: Values) { board.clearContents(); board.writeObjects([ClipboardWebCopies.item(values)]); _ = store.saveNow() }
        copy([(.string, Data("Fixture words".utf8))]); copy([(.png, ClipboardWebCopies.picture.png)]); copy(only); copy(ClipboardWebCopies.figma()); copy(pictured)
        store.cancelStaging()
        let panel = WindowTestPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 470), styleMask: [], backing: .buffered, defer: true)
        let materializer = ClipboardMaterializer(root: ClipboardMaterializer.defaultRoot.deletingLastPathComponent().appendingPathComponent("ClipEdge-app-data-window-\(UUID().uuidString)"))
        defer { materializer.removeAll(); store.stop(); board.releaseGlobally() }
        let history = ClipboardHistoryController(store: store, paster: ClipboardPaster(store: store, environment: .inert),
                                                 previewService: ClipboardPreviewService(materializer: materializer), panel: panel)
        history.prepare = { nil }
        let canvas = history.view.canvas
        @discardableResult func press(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = [], _ characters: String = "") -> Bool {
            history.handleKey(key(code, modifiers, characters))
        }
        history.hotKeyPressed()
        let picture = store.entries[0], layers = store.entries[1], data = store.entries[2], plain = store.entries[3], words = store.entries[4]
        check(history.isVisible && canvas.tiles.count == 5, "the window opens on All with every entry")
        check(press(20, .command, "3") && history.view.currentTab == .other && canvas.tiles.map(\.entry.id) == [picture, layers, data].map(\.id),
              "⌘3 shows Other: the app data with a picture, the Figma layers and the app data, newest first")
        check(history.selectedEntry === picture && history.view.countText.hasPrefix("3 of 5 items"), "the selection stays when Other still shows it; the count line counts the tab")
        check(history.view.card.entryID == picture.id && history.view.card.bodyText == picture.appData!.summary && history.view.card.imageFrame != nil,
              "the card shows the picture with the app's name and where it pastes beneath")
        press(125); press(125)
        check(history.selectedEntry === data && history.view.card.bodyText.contains("Fixture data") && history.view.card.formatsText == "com.clipedge.fixture.sketchlike",
              "arrows reach the app data; its card lists its format")
        check(press(19, .command, "2") && history.view.currentTab == .images && canvas.tiles.map(\.entry.id) == [picture, plain].map(\.id) && history.selectedEntry === picture,
              "⌘2 shows both pictures, app data included, and selects its newest since the app data left")
        check(press(18, .command, "1") && canvas.tiles.map(\.entry.id) == [words.id], "⌘1 shows the words alone")
        press(20, .command, "3")
        history.view.search.stringValue = "sketchlike"; history.view.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        check(canvas.tiles.map(\.entry.id) == [picture, data].map(\.id) && history.selectedEntry === picture, "a search within Other finds the app data by format")
        press(53)
        check(history.view.currentTab == .other && canvas.tiles.count == 3, "Esc clears the search and keeps Other")
        history.view.tabs.selectedSegment = 3
        history.view.tabs.sendAction(history.view.tabs.action!, to: history.view.tabs.target)
        check(history.view.currentTab == .other, "clicking Other does the same")
        history.close(); history.hotKeyPressed()
        check(history.view.currentTab == .all, "each opening starts from All")
        history.close()
    }

    // MARK: The drawer

    private static func drawerChecks() {
        let board = NSPasteboard.withUniqueName()
        let store = ClipboardStore(pasteboard: board, persistenceURL: nil)
        func copy(_ values: Values) -> ClipboardEntry {
            board.clearContents(); board.writeObjects([ClipboardWebCopies.item(values)]); _ = store.saveNow(); store.cancelStaging()
            return store.entries[0]
        }
        func text(_ words: String) -> ClipboardEntry { copy([(.string, Data(words.utf8))]) }
        _ = text("Forest walk"); _ = copy([(.png, ClipboardWebCopies.picture.png)]); _ = copy(only); _ = copy(ClipboardWebCopies.figma())
        let magnet = ClipboardMagnetController(panel: DrawerTestPanel(contentRect: .zero, styleMask: [], backing: .buffered, defer: true), commandClickEnabled: false)
        let drawer = ClipboardDrawerController(store: store, magnetController: magnet,
                                               panel: DrawerTestPanel(contentRect: .zero, styleMask: [], backing: .buffered, defer: true), defaults: nil)
        defer { drawer.stop(); store.stop(); board.releaseGlobally() }
        let browser = drawer.browser
        check(browser.tabs.segmentCount == 4 && browser.tabs.titles.map(\.plain) == ["All 0", "Text 1", "Images 2", "Other 3"], "the drawer's tab control has Other after Text")
        func choose(_ tab: ClipboardBrowserTab) {
            browser.tabs.selectedSegment = tab.rawValue
            browser.tabs.sendAction(browser.tabs.action!, to: browser.tabs.target)
        }
        drawer.show(on: NSScreen.main!)
        browser.layoutSubtreeIfNeeded()
        check(browser.tabs.frame.width >= browser.tabs.fittingSize.width, "four segments fit the drawer's tab control (\(browser.tabs.frame.width) for \(browser.tabs.fittingSize.width))")
        choose(.other)
        let other = browser.visibleEntries
        check(other.map(\.title) == ["1 Figma layer from ClipEdge Fixture Board", "Fixture data"] && browser.zoom.isHidden && browser.columns == 1,
              "Other lists the Figma layers and the app data as rows, without the image zoom")
        func keyPress(_ code: UInt16) -> Bool {
            drawer.handleDrawerKey(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                    characters: code == 49 ? " " : "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!)
        }
        check(keyPress(49) && store.stagedEntryID == other[0].id && store.carouselPosition?.count == 2, "Space opens Quick Look within Other")
        check(keyPress(124) && store.stagedEntryID == other[1].id && keyPress(124) && store.stagedEntryID == other[0].id, "arrows wrap within Other's results")
        check(keyPress(49) && store.stagedEntryID == nil, "a second Space closes it")

        // The tab rule: a copy made while the drawer was closed that Other would hide opens on All.
        func reopen(copying copies: () -> ClipboardEntry) -> ClipboardEntry {
            drawer.hide(animated: false)
            let last = copies()
            drawer.show(on: NSScreen.main!)
            return last
        }
        func opened(on tab: ClipboardBrowserTab, choosing entry: ClipboardEntry, _ message: String) {
            check(browser.currentTab == tab && browser.search.stringValue.isEmpty && browser.canvas.selectedID == entry.id, message)
        }
        choose(.other)
        opened(on: .other, choosing: reopen { copy(iWork) }, "on Other, app data with a picture copied while closed keeps Other, that copy chosen")
        opened(on: .other, choosing: reopen { copy(ClipboardWebCopies.figma(nodes: "4:1|6|0|0")) }, "on Other, Figma layers keep Other")
        opened(on: .all, choosing: reopen { text("Ocean swim") }, "on Other, text copied while closed opens on All")
        choose(.other)
        opened(on: .all, choosing: reopen { copy([(.png, ClipboardWebCopies.picture.png), (.string, Data("x".utf8))]) }, "on Other, a plain picture opens on All")
        choose(.images)
        opened(on: .images, choosing: reopen { copy(pictured) }, "on Images, app data with a picture keeps Images")
        opened(on: .all, choosing: reopen { copy([(ClipboardWebCopies.sketchLike, Data([7]))]) }, "on Images, app data without one opens on All")
        choose(.text)
        opened(on: .all, choosing: reopen { copy([(ClipboardWebCopies.sketchLike, Data([8]))]) }, "on Text, app data opens on All")
        choose(.text)
        opened(on: .text, choosing: reopen { copy([(.string, Data("Fixture note".utf8)), (type("com.apple.notes.richtext"), Data([1]))]) }, "on Text, text from an app keeps Text")
        choose(.other)
        _ = reopen { store.entries[0] }
        check(browser.currentTab == .other, "on Other with nothing copied since closing, Other stays")
    }

    // MARK: Surfaces

    private static func surfaceChecks() throws {
        let alone = entry(only), picture = entry(pictured), data = alone.appData!
        // The history card: symbol, title and explanation, then every format on its own line, whole.
        let card = ClipboardHistoryCard(frame: NSRect(x: 0, y: 0, width: 420, height: 380))
        card.show(alone); card.layoutSubtreeIfNeeded()
        check(card.bodyText == data.summary && (card.imageFrame?.height ?? 999) <= 56 && card.linkText == nil && card.noteText == nil,
              "the card shows the symbol at its size, the title and the explanation")
        check(card.formatsText == "com.clipedge.fixture.sketchlike" && card.edgeText.contains("1 format"), "then the format, with the count along the edge")
        guard let frames = card.formatsFrame else { fatalError("FAIL: the formats show") }
        check(frames.visible.height >= frames.whole.height && frames.visible.minY > (card.imageFrame?.maxY ?? 0) && frames.visible.maxY <= 380 - 14,
              "one format shows whole, below the words and above the edge")
        let many = entry([(ClipboardWebCopies.sketchLike, Data([1]))] + (0..<40).map { (type("com.clipedge.fixture.format\($0)"), Data([2])) })
        card.show(many); card.layoutSubtreeIfNeeded()
        guard let long = card.formatsFrame else { fatalError("FAIL: a long list shows") }
        check(card.formatsText == many.appData!.formatList && card.formatsText!.components(separatedBy: "\n").count == 41 && long.whole.height > long.visible.height
              && long.visible.maxY <= 380 - 14 && card.bodyText.contains(ClipboardAppData.explanation) && card.formatsScrolledTo == .zero,
              "forty-one formats are all there, scrolling within the card from its first line, none cut short; the words above keep whole (scrolled to \(card.formatsScrolledTo.map(NSStringFromPoint) ?? "nil"))")
        card.show(picture); card.layoutSubtreeIfNeeded()
        check(card.bodyText == picture.appData!.summary && card.imageFrame != nil && card.formatsText == nil && card.edgeText.contains("Fixture data · 2 formats"),
              "a picture's card shows the picture, then the app's name and explanation, its facts along the edge")
        check(card.accessibilityLabel() == "Image. \(picture.appData!.summary) \(card.edgeText)", "a picture with app data is named with the app's note")
        card.show(entry([(.png, ClipboardWebCopies.picture.png)])); card.layoutSubtreeIfNeeded()
        check(card.bodyText.isEmpty && card.accessibilityLabel() == "Image. \(card.edgeText)", "a plain picture still needs no caption, and is named once")
        let words = entry([(.string, Data("Fixture words".utf8))])
        card.show(words); card.layoutSubtreeIfNeeded()
        check(card.accessibilityLabel() == "\(words.title). \(card.edgeText)", "a text copy's card is named by its title once, then its facts")

        // Quick Look gets text, Preview a page, both listing the formats; a picture stays a picture.
        let materializer = ClipboardMaterializer(root: ClipboardMaterializer.defaultRoot.deletingLastPathComponent().appendingPathComponent("ClipEdge-app-data-\(UUID().uuidString)"))
        defer { materializer.removeAll() }
        let quick = try materializer.urls(for: alone)
        let quickText = (try? String(contentsOf: quick[0], encoding: .utf8)) ?? ""
        check(quick.count == 1 && quick[0].lastPathComponent == "Fixture data.txt", "Quick Look gets a text card named for the app")
        for part in [data.title, "1 format", ClipboardAppData.explanation, "com.clipedge.fixture.sketchlike"] { check(quickText.contains(part), "Quick Look shows \(part)") }
        let page = try materializer.urls(for: alone, forPreviewApp: true)
        func squeezed(_ text: String) -> String { text.filter { !$0.isWhitespace } }
        check(page[0].lastPathComponent == "Fixture data.pdf" && squeezed(PDFDocument(url: page[0])?.string ?? "") == squeezed(quickText), "⌘O opens the same words as a page")
        let pictureFiles = try materializer.urls(for: picture)
        check(pictureFiles[0].lastPathComponent == "Clipboard.png", "a picture with app data previews as the picture")
        let bitmap = entry([(type("com.microsoft.bmp"), bmp)])
        let bitmapQuick = try materializer.urls(for: bitmap), bitmapPage = try materializer.urls(for: bitmap, forPreviewApp: true)
        check(bitmapQuick[0].lastPathComponent == "Clipboard.bmp" && bitmapPage[0].pathExtension == "bmp", "a picture in another format previews under its own extension")
        check(ClipboardSendTo.openItems(for: alone, materializer: materializer).isEmpty, "Send to › Open in has nothing to open; Paste into still lists apps")
        check(ClipboardSendTo.openItems(for: picture, materializer: materializer).count == 1, "a picture with app data opens as its picture")

        // The item's info: title and explanation, then the formats with the facts, in full.
        let tile = ClipboardTile(entry: alone, style: .row, keymap: .drawer)
        check(tile.tooltipSummary == data.summary && tile.tooltipDetails.hasPrefix("com.clipedge.fixture.sketchlike\n1 format\n"), "the info explains the data and leads its details with the format")
        let pictureTile = ClipboardTile(entry: picture, style: .row, keymap: .drawer)
        check(pictureTile.tooltipSummary == "Image\n\(ClipboardAppData.explanation)" && pictureTile.tooltipDetails.hasPrefix("com.clipedge.fixture.sketchlike\npublic.png\n"),
              "a picture's info says where it pastes and lists its formats")
        let info = ClipboardTileTooltip.content(for: ClipboardTile(entry: many, style: .row, keymap: .drawer).tooltipSummary, details: ClipboardTile(entry: many, style: .row, keymap: .drawer).tooltipDetails, keymap: .drawer, asker: nil)
        let facts = descendants(info).compactMap { $0 as? NSTextField }.first { $0.stringValue.contains("fixture.format39") }
        check(facts != nil && facts?.cell?.truncatesLastVisibleLine != true && (facts?.maximumNumberOfLines ?? 1) == 0, "the info wraps every format in full")

        // The held magnet: symbol, title and explanation, or the short note where that cannot fit.
        for budget in [350.0, 700.0] as [CGFloat] {
            let held = ClipboardAttachmentView.makeHeldPreview(for: alone, maximumAttachmentPixels: budget, holdingGlyphHeight: 25)
            held.view.layoutSubtreeIfNeeded()
            let labels = descendants(held.view).compactMap { $0 as? NSTextField }
            let note = labels.first { $0.stringValue == ClipboardAppData.explanation } ?? labels.first { $0.stringValue == ClipboardAppData.shortNote }
            check(labels.contains { $0.stringValue == data.title } && note != nil, "the held magnet (\(budget) px) shows the title and the explanation or its short note")
            if let note {
                let needed = note.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: note.frame.width, height: 10_000)).height
                check(note.frame.height + 1 >= needed, "the note is not cut short (\(note.frame.height) of \(needed))")
            }
        }
        let pictureHeld = ClipboardAttachmentView.makeHeldPreview(for: picture, maximumAttachmentPixels: 700, holdingGlyphHeight: 25)
        pictureHeld.view.layoutSubtreeIfNeeded()
        check(descendants(pictureHeld.view).contains { $0 is NSImageView } && descendants(pictureHeld.view).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("Fixture data") },
              "a picture's magnet shows the picture with the app named in its facts")
        // The facts wrap between words: the narrowest magnet never splits "iWork" over two lines.
        let narrow = ClipboardAttachmentView.makeHeldPreview(for: entry(iWork), maximumAttachmentPixels: 350, holdingGlyphHeight: 25)
        narrow.view.layoutSubtreeIfNeeded()
        let magnetFacts = descendants(narrow.view).compactMap { $0 as? NSTextField }.first { $0.stringValue.contains("iWork data") }!
        let style = magnetFacts.attributedStringValue.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        check(style?.lineBreakMode == .byWordWrapping, "the magnet's facts wrap between words")
        let storage = NSTextStorage(attributedString: magnetFacts.attributedStringValue)
        let manager = NSLayoutManager(), container = NSTextContainer(size: NSSize(width: magnetFacts.frame.width - 4, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container); storage.addLayoutManager(manager)
        var lines: [String] = []
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { _, _, _, glyphs, _ in
            lines.append((storage.string as NSString).substring(with: manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)))
        }
        check(lines.count >= 2 && lines.dropLast().allSatisfy { $0.last?.isWhitespace == true }, "laid out at its width, every line ends between words (\(lines))")
    }

    // MARK: The store: write-back, plain-text paste, launch

    private static func storeChecks() {
        let board = NSPasteboard.withUniqueName()
        let folder = ClipboardMaterializer.defaultRoot.deletingLastPathComponent().appendingPathComponent("ClipEdge-app-data-store-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder); board.releaseGlobally() }
        let history = folder.appendingPathComponent("History.plist")
        let store = ClipboardStore(pasteboard: board, persistenceURL: history)
        for values in [only, pictured, iWork, ClipboardWebCopies.bookkeepingOnly] {
            board.clearContents(); board.writeObjects([ClipboardWebCopies.item(values)]); _ = store.saveNow()
        }
        store.cancelStaging()
        let bookkeeping = store.entries[0], keynote = store.entries[1], picture = store.entries[2], alone = store.entries[3]
        check(appData(alone) != nil && picture.isImage && keynote.appData?.name == "iWork" && bookkeeping.kind == .other, "copies made on the clipboard are recognized")
        board.clearContents(); board.setString("something else", forType: .string)
        for (entry, values) in [(alone, only), (picture, pictured), (keynote, iWork)] {
            check(store.makeCurrent(entry), "\(entry.title) can be made current")
            check(board.pasteboardItems?.count == 1 && values.allSatisfy { board.data(forType: $0.type) == $0.data } && Set(board.pasteboardItems![0].types) == Set(values.map(\.type)),
                  "every format of \(entry.title) returns byte for byte, so its app gets it back")
        }
        check(store.makeCurrent(alone) && store.beginPlainTextPaste() != nil && board.string(forType: .string) == "Fixture data\ncom.clipedge.fixture.sketchlike",
              "⌃⌘V lends app data's name and formats")
        store.endPlainTextPaste()
        check(board.data(forType: ClipboardWebCopies.sketchLike) == only[0].data && board.string(forType: .string) == nil, "the app data returns whole after the plain paste")
        check(store.makeCurrent(picture) && store.beginPlainTextPaste() != nil && board.string(forType: .string) == picture.metadata.line, "a picture with app data lends its facts")
        store.endPlainTextPaste()
        check(store.makeCurrent(bookkeeping) && store.beginPlainTextPaste() == nil, "a copy with nothing to read lends nothing")
        store.cancelStaging()
        _ = store.saveNow()
        store.stop()

        let reopenedBoard = NSPasteboard.withUniqueName()
        let reopened = ClipboardStore(pasteboard: reopenedBoard, persistenceURL: history)
        reopened.start()
        defer { reopened.stop(); reopenedBoard.releaseGlobally() }
        check(reopened.entries.contains { appData($0)?.name == "Fixture" } && reopened.entries.filter { $0.isImage && $0.appData != nil }.count == 2,
              "saved app data is recognized again at the next launch")

        let demoBoard = NSPasteboard.withUniqueName()
        let demo = ClipboardStore(pasteboard: demoBoard, persistenceURL: nil)
        defer { demo.stop(); demoBoard.releaseGlobally() }
        ClipboardDemo.seed(demo, board: demoBoard)
        ClipboardDemo.seedWebCopies(demo, board: demoBoard)
        let added = demo.entries.prefix(ClipboardWebCopies.demo.count)
        check(added.filter { appData($0) != nil }.count == 1 && added.filter { $0.isImage && $0.appData != nil }.count == 2 && added.filter { $0.kind == .other }.count == 3,
              "the demo shows app data alone, two pictures with app data and a bookkeeping-only item")
    }

    /// Summaries run on the main thread at every copy and for every saved item at launch.
    private static func timingChecks() {
        let fifty = (0..<50).map { index -> Values in
            [(ClipboardWebCopies.sketchLike, Data(repeating: UInt8(index), count: 1 << 20)), (type("com.clipedge.fixture.second\(index)"), Data([1])),
             (NSPasteboard.PasteboardType("org.nspasteboard.source"), Data([2]))]
        }
        let started = ProcessInfo.processInfo.systemUptime
        let kinds = fifty.map { ClipboardSummary.make(from: [ClipboardPayload(values: $0)]).kind }
        let seconds = ProcessInfo.processInfo.systemUptime - started
        check(kinds.allSatisfy { if case .appData = $0 { return true }; return false } && seconds < 1, "fifty saved app-data copies of 1 MB summarize at launch in under a second (\(seconds) s)")
        let pictures = (0..<50).map { _ in iWork }
        let pictureStart = ProcessInfo.processInfo.systemUptime
        let pictureKinds = pictures.map { ClipboardSummary.make(from: [ClipboardPayload(values: $0)]).kind }
        let pictureSeconds = ProcessInfo.processInfo.systemUptime - pictureStart
        check(pictureKinds.allSatisfy { $0 == .image } && pictureSeconds < 1, "fifty iWork-style pictures summarize in under a second (\(pictureSeconds) s)")
    }

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}

private final class WindowTestPanel: NSPanel {
    private var fixtureVisible = false
    override var isVisible: Bool { fixtureVisible }
    override var isKeyWindow: Bool { true }
    override var canBecomeKey: Bool { true }
    override func orderFrontRegardless() { fixtureVisible = true }
    override func makeKeyAndOrderFront(_ sender: Any?) { fixtureVisible = true }
    override func orderOut(_ sender: Any?) { fixtureVisible = false }
    override func makeKey() {}
    override func resignKey() {}
}

private final class DrawerTestPanel: NSPanel {
    private var fixtureVisible = false
    override var isVisible: Bool { fixtureVisible }
    override var isKeyWindow: Bool { true }
    override func orderFrontRegardless() { fixtureVisible = true }
    override func orderOut(_ sender: Any?) { fixtureVisible = false }
    override func makeKey() {}
    override func resignKey() {}
}
