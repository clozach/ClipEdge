import AppKit

/// The sample history: its place, the seed, hand edits, the store's switch and the Terminal
/// command. Named boards and temporary folders only; every byte is invented.
@main enum SampleHistoryTests {
    static var count = 0
    static func check(_ value: Bool, _ why: String) { count += 1; precondition(value, "FAIL: \(why)") }

    typealias Values = [(type: NSPasteboard.PasteboardType, data: Data)]
    static func record(_ values: Values, _ seconds: Double = 0) -> ClipboardHistoryFile.Record {
        let payloads = [ClipboardPayload(values: values)]
        return ClipboardHistoryFile.Record(fingerprint: ClipboardHistoryFile.fingerprint(for: payloads),
                                           capturedAt: Date(timeIntervalSince1970: 1_790_000_000 + seconds), payloads: payloads)
    }
    static func text(_ words: String) -> Values { [(.string, Data(words.utf8))] }
    static func entry(_ values: Values) -> ClipboardEntry { ClipboardHistoryFile.entry(record(values)) }
    static func titles(_ url: URL) -> [String] { ((try? ClipboardHistoryFile.read(url)) ?? nil ?? []).map { ClipboardHistoryFile.entry($0).title } }
    static func folder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clipedge-sample-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func main() {
        _ = NSApplication.shared
        places()
        seeding()
        edits()
        storeSwitch()
        command()
        menuTitles()
        print("PASS: \(count) sample-history assertions; named boards, temporary folders, invented copies")
    }

    static func places() {
        let base = URL(fileURLWithPath: "/tmp/ClipEdgeFixture", isDirectory: true)
        check(ClipboardHistorySource.real.url(in: base)?.path == "/tmp/ClipEdgeFixture/History.plist", "real history keeps its place")
        check(ClipboardHistorySource.sample.url(in: base)?.path == "/tmp/ClipEdgeFixture/Sample/History.plist", "sample sits in its own folder")
        check(ClipboardHistorySource.real.other == .sample && ClipboardHistorySource.sample.other == .real, "toggle")
        let defaults = UserDefaults(suiteName: "clipedge-sample-\(UUID().uuidString)")!
        check(ClipboardHistorySource.saved(in: defaults) == .real, "real by default")
        ClipboardHistorySource.sample.save(in: defaults)
        check(ClipboardHistorySource.saved(in: defaults) == .sample, "the choice persists")
        defaults.set("bogus", forKey: ClipboardHistorySource.defaultsKey)
        check(ClipboardHistorySource.saved(in: defaults) == .real, "an unknown value reads as real")
    }

    static func seeding() {
        let prose = (1...8).map { entry(text("Fixture sentence number \($0) has enough words to read as prose")) }
        let short = entry(text("two words"))
        let swatch = entry(text("#F6C0A6"))
        let links = (1...5).map { entry(text("https://example.com/fixture/\($0)")) }
        let figma = (1...5).map { entry(ClipboardWebCopies.figma(nodes: "1:\($0)|31|0|0")) }
        let pictures = (1...5).map { n -> ClipboardEntry in
            let image = NSImage(size: NSSize(width: 4 + n, height: 4))
            image.lockFocus(); NSColor.systemPink.setFill(); NSRect(x: 0, y: 0, width: 4 + n, height: 4).fill(); image.unlockFocus()
            return entry([(.tiff, image.tiffRepresentation!)])
        }
        let file = entry([(.fileURL, Data("file:///tmp/fixture.txt".utf8))])
        let app = entry(ClipboardWebCopies.appDataOnly)
        check(links.allSatisfy { $0.kind == .link }, "fixture links read as links")
        check(pictures.allSatisfy(\.isImage), "fixture pictures read as images")
        check(figma.allSatisfy { if case .figma = $0.kind { return true }; return false }, "fixture Figma copies read as Figma")
        check(ClipboardSampleHistory.isProse(prose[0]), "a sentence is prose")
        check(!ClipboardSampleHistory.isProse(short), "two words are not prose")
        check(!ClipboardSampleHistory.isProse(swatch), "a color is not prose")
        check(!ClipboardSampleHistory.isProse(links[0]), "a link is not prose")

        // Interleaved as a real history would be, newest first.
        var history: [ClipboardEntry] = [file, app, short, swatch]
        for i in 0..<8 {
            history.append(prose[i])
            if i < 5 { history += [links[i], figma[i], pictures[i]] }
        }
        let seeded = ClipboardSampleHistory.seed(from: history)
        let kinds = seeded.map { ClipboardSampleHistory.seedKind($0) ?? "?" }
        check(kinds.filter { $0 == "prose" }.count == 6, "six prose copies")
        check(kinds.filter { $0 == "figma" }.count == 4, "four Figma copies")
        check(kinds.filter { $0 == "link" }.count == 4, "four links")
        check(kinds.filter { $0 == "image" }.count == 4, "four pictures")
        check(!seeded.contains { $0 === file || $0 === app || $0 === short || $0 === swatch }, "files, app data and fragments stay out")
        let order = seeded.compactMap { picked in history.firstIndex { $0 === picked } }
        check(order == order.sorted(), "the real history's order is kept")
        check(seeded.first === prose[0] && seeded.contains { $0 === prose[5] } && !seeded.contains { $0 === prose[6] }, "the newest of each kind")
        check(ClipboardSampleHistory.seed(from: []).isEmpty, "an empty history seeds an empty sample")
    }

    static func edits() {
        let a = record(text("Alpha fixture")), b = record(text("Bravo fixture")), c = record(text("Charlie fixture"))
        let added = ClipboardSampleHistory.adding(c, to: [a, b])
        check(added.map(\.fingerprint) == [c, a, b].map(\.fingerprint), "an added copy goes first")
        let again = ClipboardSampleHistory.adding(b, to: added)
        check(again.map(\.fingerprint) == [b, c, a].map(\.fingerprint), "adding a copy already there moves it, never twice")
        let full = (0..<ClipboardSampleHistory.capacity).map { record(text("Fixture \($0)")) }
        check(ClipboardSampleHistory.adding(c, to: full).count == ClipboardSampleHistory.capacity, "adding keeps the history's size")
        check(ClipboardSampleHistory.moving([a, b, c], from: 3, to: 1)?.map(\.fingerprint) == [c, a, b].map(\.fingerprint), "move up")
        check(ClipboardSampleHistory.moving([a, b, c], from: 1, to: 3)?.map(\.fingerprint) == [b, c, a].map(\.fingerprint), "move down")
        check(ClipboardSampleHistory.moving([a, b, c], from: 0, to: 2) == nil && ClipboardSampleHistory.moving([a, b, c], from: 1, to: 4) == nil, "positions run from 1")
        check(ClipboardSampleHistory.removing([a, b, c], at: 2)?.map(\.fingerprint) == [a, c].map(\.fingerprint), "remove")
        check(ClipboardSampleHistory.removing([a], at: 2) == nil, "remove out of range")
        check(ClipboardSampleHistory.menuLabel("Short") == "Short", "short labels stay whole")
        let long = ClipboardSampleHistory.menuLabel("A long fixture title that runs well past the menu's width")
        check(long.hasSuffix("…") && long.count <= 33 && !long.dropLast().hasSuffix(" "), "long labels cut at a word")
        check(ClipboardSampleHistory.menuLabel("First line\nsecond line") == "First line", "only the first line")
    }

    static func storeSwitch() {
        let base = folder()
        defer { try? FileManager.default.removeItem(at: base) }
        let realURL = ClipboardHistorySource.real.url(in: base)!, sampleURL = ClipboardHistorySource.sample.url(in: base)!
        ClipboardHistoryFile.write([record(text("Real fixture two"), 2), record(text("Real fixture one"), 1)], to: realURL)
        ClipboardHistoryFile.write([record(text("Sample fixture"), 3)], to: sampleURL)
        let board = NSPasteboard(name: .init("clipedge-sample-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents(); board.setString("On the clipboard before launch", forType: .string)
        let store = ClipboardStore(pasteboard: board, persistenceURL: realURL)
        store.attachesCopiesToCursor = { false }
        store.start()
        defer { store.stop() }
        check(store.entries.map(\.title) == ["On the clipboard before launch", "Real fixture two", "Real fixture one"], "real history loads")
        var changes = 0
        store.onChange = { changes += 1 }

        board.clearContents(); board.setString("Held then put back", forType: .string)
        _ = store.saveNow()
        let held = store.entries[1]
        store.selectForPaste(held)
        check(board.string(forType: .string) == "Real fixture two" || store.stagedEntryID != nil, "an item is held")

        store.switchHistory(to: sampleURL)
        check(store.historyURL == sampleURL, "the store now saves to the sample")
        check(store.entries.map(\.title) == ["Sample fixture"], "the sample shows, without the clipboard's contents")
        check(store.stagedEntryID == nil, "nothing is held across the switch")
        check(board.string(forType: .string) == "Held then put back", "what was held goes back first")
        check(changes > 0, "the views hear of the switch")
        check(titles(realURL).first == "Held then put back", "the real history was saved on the way out")

        board.clearContents(); board.setString("Copied while the sample shows", forType: .string)
        _ = store.saveNow()
        check(store.entries.map(\.title) == ["Copied while the sample shows", "Sample fixture"], "a copy joins the sample")
        check(titles(sampleURL) == ["Copied while the sample shows", "Sample fixture"], "and is saved there")
        check(!titles(realURL).contains("Copied while the sample shows"), "the real history never sees it")
        _ = store.remove(store.entries[1])
        check(titles(sampleURL) == ["Copied while the sample shows"], "deleting edits the sample")

        store.switchHistory(to: realURL)
        check(store.entries.first?.title == "Held then put back" && store.entries.count == 4, "the real history comes back whole")
        check(titles(sampleURL) == ["Copied while the sample shows"], "the sample keeps its edits")

        let empty = base.appendingPathComponent("Empty/History.plist")
        store.switchHistory(to: empty)
        check(store.entries.isEmpty, "a history with no file starts empty")
    }

    static func command() {
        let base = folder()
        defer { try? FileManager.default.removeItem(at: base) }
        var lines: [String] = [], trashed: [URL] = [], showing = false
        let env = ClipboardSampleHistoryCommand.Environment(directory: base, sampleIsShowing: { showing },
            trash: { trashed.append($0); try FileManager.default.removeItem(at: $0) }, print: { lines.append($0) })
        let run = { (args: [String]) -> Int32 in lines = []; return ClipboardSampleHistoryCommand.run(args, environment: env) }
        let sampleURL = ClipboardHistorySource.sample.url(in: base)!
        ClipboardHistoryFile.write([
            record(text("Fixture prose one has six or more words")), record(text("https://example.com/fixture")),
            record([(.fileURL, Data("file:///tmp/fixture.txt".utf8))]), record(text("Fixture prose two has six or more words"))
        ], to: ClipboardHistorySource.real.url(in: base)!)

        check(run(["path"]) == 0 && lines == [sampleURL.path], "path")
        check(run(["list"]) == 0 && lines.first?.contains("empty") == true, "list before a seed")
        check(run(["seed"]) == 0 && lines.first == "Seeded 3 entries from the real history.", "seed takes prose and links, not files")
        check(titles(sampleURL).count == 3, "the seed is saved")
        check(run(["seed"]) == 1 && titles(sampleURL).count == 3, "a second seed needs --replace")
        check(run(["list"]) == 0 && lines.count == 3 && lines[1].hasPrefix("2\tlink\t"), "list numbers and kinds")
        check(run(["move", "3", "1"]) == 0 && titles(sampleURL).first?.hasPrefix("Fixture prose two") == true, "move")
        check(run(["move", "9", "1"]) == 1, "move out of range")
        check(run(["remove", "2"]) == 0 && titles(sampleURL).count == 2 && trashed.count == 1, "remove keeps the previous file in the Trash")
        showing = true
        check(run(["remove", "1"]) == 1 && titles(sampleURL).count == 2 && lines.first?.contains("Switch it to the real history") == true, "refuses while ClipEdge shows the sample")
        check(run(["list"]) == 0, "reading is always allowed")
        showing = false
        check(run(["seed", "--replace"]) == 0 && trashed.count == 2 && titles(sampleURL).count == 3, "--replace trashes the old sample")
        check(run([]) == 64 && run(["move", "1"]) == 64 && run(["dance"]) == 64, "malformed commands print the usage")
        // The sample lives in its store folder: an unreadable index is an unreadable sample.
        try? Data("not a plist".utf8).write(to: ClipboardHistoryFile.storeFolder(for: sampleURL).appendingPathComponent("Index.plist"))
        check(run(["list"]) == 1 && lines.first?.contains("could not be read") == true, "an unreadable sample is reported, not replaced")
    }

    static func menuTitles() {
        let newest = entry(text("A fixture paragraph that is far too long for a menu"))
        check(ClipboardSampleHistoryMenu.addTitle(onSample: false, newest: newest, inSample: { _ in false }) == "Add “A fixture paragraph that is far…” to Sample History", "Add names the item")
        check(ClipboardSampleHistoryMenu.addTitle(onSample: false, newest: newest, inSample: { _ in true }).hasSuffix("Is in Sample History"), "says when it is already there")
        check(ClipboardSampleHistoryMenu.addTitle(onSample: false, newest: nil, inSample: { _ in false }) == "Add Newest Item to Sample History", "empty history")
        check(ClipboardSampleHistoryMenu.addTitle(onSample: true, newest: newest, inSample: { _ in false }) == "Copy Something to Add It to Sample History", "while the sample shows")
    }
}
