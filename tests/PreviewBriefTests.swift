import AppKit

/// "Ask for a preview": the vault found from the publisher tool and
/// refused elsewhere, slug rules, the brief's exact shape without any payload,
/// append-on-existing, the transient Copy prompt the store skips, the control
/// shown only in a maintainer copy, the form's keys, and both entry points.
/// Briefs go into a temporary vault, never the real one. Made-up copies only.
@main enum PreviewBriefTests {
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
    private static func key(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = [], _ characters: String = "") -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }
    private static let askKey = key(0, [.option, .command], "a")
    private static let fixedDay = Date(timeIntervalSince1970: 1_791_000_000)
    private static var day: String { ClipboardPreviewAsker.day(fixedDay) }

    /// A made-up vault: the folders the real one has, and nothing else.
    private static func makeVault() -> (vault: ClipboardPreviewBriefVault, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClipEdge-brief-vault-\(UUID().uuidString)", isDirectory: true)
        let tools = root.appendingPathComponent("projects/clipedge/src/tools", isDirectory: true)
        try! FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        try! Data("#!/bin/bash\n".utf8).write(to: tools.appendingPathComponent("publisher.sh"))
        return (ClipboardPreviewBriefVault(publisherTool: tools.appendingPathComponent("publisher.sh"))!, root)
    }

    static func main() {
        _ = NSApplication.shared
        vaultChecks()
        slugChecks()
        contentChecks()
        writeChecks()
        transientCopyChecks()
        windowChecks()
        drawerChecks()
        print("PASS: \(assertions) preview-brief assertions; a temporary vault, made-up copies")
    }

    // MARK: The vault

    private static func vaultChecks() {
        let (vault, root) = makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        check(vault.root.standardizedFileURL == root.standardizedFileURL && vault.name == root.lastPathComponent, "the vault is the tool's ancestor holding projects/clipedge/src, named by its folder")
        check(vault.contract(slug: "iwork").path == root.standardizedFileURL.appendingPathComponent("projects/clipedge-preview-iwork/AGENTS.md").path, "a brief lives at projects/clipedge-preview-<slug>/AGENTS.md")
        check(ClipboardPreviewBriefVault(publisherTool: URL(fileURLWithPath: "/tmp/elsewhere/tools/publisher.sh")) == nil, "a tool outside projects/clipedge/src names no vault")
        check(ClipboardPreviewBriefVault(publisherTool: root.appendingPathComponent("projects/clipedge/src/publisher.sh")) == nil, "nor one at the wrong depth")
        let hollow = FileManager.default.temporaryDirectory.appendingPathComponent("ClipEdge-hollow-\(UUID().uuidString)/projects/clipedge/src/tools/publisher.sh")
        check(ClipboardPreviewBriefVault(publisherTool: hollow) == nil, "a path whose source folder does not exist names no vault")
        check(ClipboardPreviewBriefVault(publisherTool: root.appendingPathComponent("projects/clipedge/src/tools/../tools/publisher.sh")) != nil, "a path with a dot-dot inside still resolves to the same vault")
    }

    // MARK: Slugs

    private static func slugChecks() {
        let cases: [(String, String)] = [("iWork", "iwork"), ("Notes", "notes"), ("Fixture", "fixture"), ("../../etc", "etc"), ("a/b c", "a-b-c"),
                                         ("..", "clipboard-item"), ("", "clipboard-item"), ("Ünïcode App", "n-code-app"), ("--x--", "x"),
                                         (String(repeating: "abcde-", count: 20), "abcde-abcde-abcde-abcde-abcde-abcde-abcd")]
        for (name, slug) in cases { check(ClipboardPreviewBrief.slug(name) == slug, "\(name) → \(slug) (got \(ClipboardPreviewBrief.slug(name)))") }
        check(ClipboardPreviewBrief.slug(String(repeating: "a", count: 100)).count == ClipboardPreviewBrief.slugLimit, "a long name is cut to the limit")
        check(ClipboardPreviewBrief.slug(for: entry(ClipboardWebCopies.appDataOnly)) == "fixture", "app data is named by its app")
        check(ClipboardPreviewBrief.slug(for: entry(ClipboardWebCopies.iWorkWithPicture)) == "iwork", "a picture with app data too")
        check(ClipboardPreviewBrief.slug(for: entry([(.png, ClipboardWebCopies.picture.png)])) == "image", "a plain picture is image")
        check(ClipboardPreviewBrief.slug(for: entry([(.string, Data("Fixture words".utf8))])) == "text", "text is text")
        check(ClipboardPreviewBrief.slug(for: entry([(.string, Data("https://example.com/fixture".utf8))])) == "text", "a link is text")
        check(ClipboardPreviewBrief.slug(for: entry(ClipboardWebCopies.figma())) == "figma", "Figma layers are figma")
        check(ClipboardPreviewBrief.slug(for: entry(ClipboardWebCopies.bookkeepingOnly)) == "clipboard-item", "a copy with nothing to read is clipboard-item")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ClipEdge-brief-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("fixture note.txt")
        try? Data("note".utf8).write(to: file)
        check(ClipboardPreviewBrief.slug(for: entry([(.fileURL, Data(file.absoluteString.utf8))])) == "file", "a Finder item is file")
        let (vault, root) = makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["../../etc", "a/b", "/", "..", "x\\y"] {
            let file = vault.contract(slug: ClipboardPreviewBrief.slug(name)).standardizedFileURL.path
            check(file.hasPrefix(vault.projects.standardizedFileURL.path + "/clipedge-preview-") && !file.contains("/../"), "\(name) cannot leave projects/ (\(file))")
        }
    }

    // MARK: The brief

    private static func contentChecks() {
        let data = entry([(ClipboardWebCopies.sketchLike, Data("clipedge-fixture-app-data".utf8) + Data(repeating: 0x5A, count: 40))])
        let brief = ClipboardPreviewBrief(entry: data, note: "  Show the layer's shape.  ")
        let document = brief.document(on: day)
        let frontmatter = """
        ---
        type: project
        aliases: [clipedge-preview-fixture]
        status: unstarted
        parked: \(day)
        created: \(day)
        bends_toward: [machines, programming]
        ---
        # A better preview for Fixture data in ClipEdge
        """
        check(document.hasPrefix(frontmatter + "\n"), "the brief opens with the project frontmatter and its title (\(document.prefix(260)))")
        for heading in ["## What was copied", "## The ask", "## Where the code lives", "## How to test", "## Definition of Done"] {
            check(document.contains("\n\(heading)\n"), "the brief has \(heading)")
        }
        let sections = document.components(separatedBy: "\n## ")
        check(sections.count == 6 && sections[1].hasPrefix("What was copied") && sections[2].hasPrefix("The ask") && sections[3].hasPrefix("Where the code lives")
              && sections[4].hasPrefix("How to test") && sections[5].hasPrefix("Definition of Done"), "in that order")
        check(sections[1].contains("- App: Fixture (its own clipboard format)") && sections[1].contains("- Formats (1):") && sections[1].contains("  `com.clipedge.fixture.sketchlike` · 65 bytes"),
              "it names the app and every format with its byte size")
        check(sections[1].contains("- Picture: no") && sections[1].contains("- Text: no") && sections[1].contains("- Quick Look today: ClipEdge's own text card"),
              "it says what is present and what Quick Look is handed today")
        check(sections[1].contains("title “Fixture data”, facts “1 format”") && sections[1].contains(ClipboardAppData.explanation), "it says what ClipEdge shows today")
        check(sections[2].hasPrefix("The ask\n\nShow the layer's shape.\n"), "Al's note is the ask, verbatim but for the spaces around it")
        check(!document.contains("clipedge-fixture-app-data") && !document.contains("ZZZZ"), "no payload bytes are in the brief")
        for name in ["ClipboardSummary.make", "ClipboardAppData", "ClipboardMaterializer.urls(for:)", "makePreview", "ClipboardHistoryCard", "ClipboardWebCopies", "AppDataTests"] {
            check(sections[3].contains(name), "the code map names \(name)")
        }
        check(sections[4].contains("ClipboardWebCopies") && sections[4].contains("--demo-web-copies") && sections[4].contains("AppDataTests") && sections[4].contains("projects/pixel-reveal/AGENTS.md § Recipe"),
              "how to test: a fixture, the suite, before/after captures")
        check(sections[5].contains("concepts/definition-of-done.md") && sections[5].contains("🏁"), "done is the vault's definition")
        check(document.hasSuffix("\n"), "the file ends with a newline")
        let silent = ClipboardPreviewBrief(entry: data, note: nil)
        check(silent.ask == ClipboardPreviewBrief.defaultAsk && ClipboardPreviewBrief(entry: data, note: "   ").ask == ClipboardPreviewBrief.defaultAsk, "without a note, the ask is the default sentence")
        let request = silent.request(on: day)
        check(request.hasPrefix("\n## Request on \(day)\n\n- App: Fixture") && request.contains("\n\(ClipboardPreviewBrief.defaultAsk)\n"), "a later request carries the formats and the note")

        // Nothing copied reaches a brief: not words, addresses, file names or keys.
        let words = ClipboardPreviewBrief(entry: entry([(.string, Data("ClipEdge secret fixture words".utf8))]), note: nil).document(on: day)
        check(words.contains("# A better preview for text copies in ClipEdge") && words.contains("- Text: yes (4 words · 29 characters)") && words.contains("- Quick Look today: a text card of its words"),
              "a text copy's brief counts its words")
        check(!words.contains("secret") && words.contains("title: its first words"), "and never quotes them")
        let link = ClipboardPreviewBrief(entry: entry([(.string, Data("https://secret-fixture.example/path".utf8))]), note: nil).document(on: day)
        check(!link.contains("secret-fixture") && !link.contains("example") && link.contains("title: the address, facts: its site"), "a link's brief holds no address or site")
        let layers = ClipboardPreviewBrief(entry: entry(ClipboardWebCopies.figma(text: "Fixture caption")), note: nil).document(on: day)
        check(layers.contains("# A better preview for Figma copies in ClipEdge") && !layers.contains(ClipboardWebCopies.fileKey) && !layers.contains(ClipboardWebCopies.fileName)
              && !layers.contains("Fixture caption") && !layers.contains("figma.com/"), "a Figma copy's brief holds no file key, file name, words or link")
        check(layers.contains("title: its words, facts: where the text came from (the file's name), then “Figma Design · figma.com”"), "a text layer's brief says its title is its words")
        check(ClipboardPreviewBrief(entry: entry(ClipboardWebCopies.figma(editorType: "whiteboard", route: "board")), note: nil).document(on: day).contains("facts “FigJam · figma.com”"),
              "a FigJam copy's brief names its editor")
        let unknown = ClipboardPreviewBrief(entry: entry([(.html, Data("<p></p>".utf8))]), note: nil)
        check(unknown.slug == "clipboard-item" && unknown.document(on: day).contains("# A better preview for Clipboard item copies in ClipEdge"),
              "a copy with nothing to read is headed in ClipEdge's words, its slug still the folder's")
        let page = ClipboardPreviewBrief(entry: entry(ClipboardWebCopies.chatReply), note: nil).document(on: day)
        check(!page.contains("claude.ai") && !page.contains("chat page"), "a web copy's brief holds neither its site nor its words")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ClipEdge-brief-secret-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("secret-fixture-name.txt")
        try? Data("note".utf8).write(to: file)
        let finder = ClipboardPreviewBrief(entry: entry([(.fileURL, Data(file.absoluteString.utf8))]), note: nil).document(on: day)
        check(!finder.contains("secret-fixture-name") && !finder.contains(folder.path) && finder.contains("- Quick Look today: the Finder item itself")
              && finder.contains("# A better preview for Finder item copies in ClipEdge"), "a Finder item's brief holds no name or path, and is headed as a Finder item")
        let picture = ClipboardPreviewBrief(entry: entry(ClipboardWebCopies.iWorkWithPicture), note: nil).document(on: day)
        check(picture.contains("# A better preview for iWork data in ClipEdge") && picture.contains("- Picture: yes (96 × 64)") && picture.contains("- Quick Look today: the picture")
              && picture.contains("captioned “iWork data”"), "a picture with app data: the app named, the picture noted")
        let typed = ClipboardPreviewBrief(entry: entry([(ClipboardWebCopies.sketchLike, Data([1])), (type("public.json"), Data("{}".utf8))]), note: nil).document(on: day)
        check(typed.contains("- Quick Look today: `Clipboard.json`, its JSON format, as a typed file") && typed.contains("`public.json` · 2 bytes"), "a typed handoff is named with its file")
    }

    // MARK: Writing

    private static func writeChecks() {
        let (vault, root) = makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        var asker = ClipboardPreviewAsker(vault: vault, pasteboard: NSPasteboard.withUniqueName())
        asker.now = { fixedDay }
        let data = entry(ClipboardWebCopies.appDataOnly)
        guard case .written(let first) = asker.write(data, note: "Show the shape.") else { fatalError("FAIL: the first brief is written") }
        let file = vault.contract(slug: "fixture")
        check(first.path == "projects/clipedge-preview-fixture/AGENTS.md" && first.url == file && !first.appended && first.sentence == "Brief written: projects/clipedge-preview-fixture/AGENTS.md",
              "the record names the brief's place in the vault")
        let written = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        check(written == ClipboardPreviewBrief(entry: data, note: "Show the shape.").document(on: day) && first.prompt == written, "the file is the brief, and the prompt is the file")
        check(first.obsidianURL.absoluteString == "obsidian://open?vault=\(vault.name)&file=projects/clipedge-preview-fixture/AGENTS", "the Obsidian link names the vault and the note without .md")
        check(ClipboardPreviewAsker.obsidianURL(vault: "my vault", path: "projects/clipedge-preview-x/AGENTS.md").absoluteString == "obsidian://open?vault=my%20vault&file=projects/clipedge-preview-x/AGENTS", "spaces are percent-encoded")

        let again = entry([(ClipboardWebCopies.sketchLike, Data([9])), (type("public.json"), Data("{}".utf8))])
        guard case .written(let second) = asker.write(again, note: "Now with JSON.") else { fatalError("FAIL: a second ask on the same app is written") }
        let appended = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        check(second.appended && second.sentence == "Request added to: projects/clipedge-preview-fixture/AGENTS.md" && second.url == file, "the same app's project gains a request")
        check(appended.hasPrefix(written) && appended.hasSuffix(ClipboardPreviewBrief(entry: again, note: "Now with JSON.").request(on: day)) && second.prompt == appended,
              "the first brief is kept whole and the request follows it; the prompt is the whole file")
        check(appended.components(separatedBy: "\n## Request on ").count == 2 && appended.contains("`public.json` · 2 bytes") && appended.contains("Now with JSON."), "with the new formats and note")
        check((try? FileManager.default.contentsOfDirectory(atPath: vault.projects.path))?.sorted() == ["clipedge", "clipedge-preview-fixture"], "no second project for the same app")

        guard case .written(let picture) = asker.write(entry([(.png, ClipboardWebCopies.picture.png)]), note: nil) else { fatalError("FAIL: a picture's brief is written") }
        check(picture.path == "projects/clipedge-preview-image/AGENTS.md" && FileManager.default.fileExists(atPath: vault.contract(slug: "image").path), "a plain picture's brief is its own project")

        try? FileManager.default.removeItem(at: vault.projects)
        guard case .failed(let sentence) = asker.write(data, note: nil) else { fatalError("FAIL: without a projects folder nothing is written") }
        check(sentence.contains("projects folder") && !FileManager.default.fileExists(atPath: file.path), "the failure is a sentence, and nothing was written outside projects/ (\(sentence))")
        besideChecks()
    }

    /// A request joins an open ClipEdge brief only; a closed one, or another project
    /// at the brief's place, is left as found and a dated brief is written beside it.
    private static func besideChecks() {
        let open = "---\ntype: project\naliases: [clipedge-preview-iwork]\nstatus: unstarted\nparked: 2026-10-11\n---\n# A brief\n"
        check(ClipboardPreviewAsker.isOpenBrief(open, alias: "clipedge-preview-iwork"), "an unstarted brief with its alias is open")
        check(ClipboardPreviewAsker.isOpenBrief(open.replacingOccurrences(of: "unstarted", with: "active"), alias: "clipedge-preview-iwork"), "so is an active one")
        for closed in ["completed", "abandoned"] {
            check(!ClipboardPreviewAsker.isOpenBrief(open.replacingOccurrences(of: "unstarted", with: closed), alias: "clipedge-preview-iwork"), "a \(closed) brief is closed")
        }
        check(!ClipboardPreviewAsker.isOpenBrief(open, alias: "clipedge-preview-iwork-2026-10-11"), "an alias is matched whole, never as a prefix of a dated sibling")
        check(!ClipboardPreviewAsker.isOpenBrief(open.replacingOccurrences(of: "clipedge-preview-iwork", with: "clipedge-preview-iwork-2026-10-11"), alias: "clipedge-preview-iwork"), "nor the other way round")
        check(ClipboardPreviewAsker.isOpenBrief(open.replacingOccurrences(of: "[clipedge-preview-iwork]", with: "[other, clipedge-preview-iwork]"), alias: "clipedge-preview-iwork"), "an alias among others counts")
        check(!ClipboardPreviewAsker.isOpenBrief("# No frontmatter\n", alias: "clipedge-preview-iwork") && !ClipboardPreviewAsker.isOpenBrief("---\nstatus: unstarted\n---\n", alias: "clipedge-preview-iwork"),
              "no frontmatter, or no alias, is not a ClipEdge brief")

        let (vault, root) = makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        var asker = ClipboardPreviewAsker(vault: vault, pasteboard: NSPasteboard.withUniqueName())
        asker.now = { fixedDay }
        let data = entry(ClipboardWebCopies.appDataOnly)
        let closedFile = vault.contract(slug: "fixture")
        let closedText = "---\ntype: project\naliases: [clipedge-preview-fixture]\nstatus: completed\n---\n# Done already\n"
        try! FileManager.default.createDirectory(at: closedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(closedText.utf8).write(to: closedFile)
        guard case .written(let beside) = asker.write(data, note: "Again.") else { fatalError("FAIL: a brief is written beside a completed one") }
        let sibling = vault.contract(slug: "fixture-\(day)")
        check(!beside.appended && beside.path == "projects/clipedge-preview-fixture-\(day)/AGENTS.md" && beside.url == sibling, "past a completed brief, a dated sibling is written (\(beside.path))")
        check((try? String(contentsOf: closedFile, encoding: .utf8)) == closedText, "the completed brief is left as found")
        let written = (try? String(contentsOf: sibling, encoding: .utf8)) ?? ""
        check(written.hasPrefix("---\ntype: project\naliases: [clipedge-preview-fixture-\(day)]\nstatus: unstarted\nparked: \(day)\n") && written.contains("`projects/clipedge-preview-fixture/AGENTS.md` already exists")
              && written == ClipboardPreviewBrief(entry: data, note: "Again.").document(on: day, project: "clipedge-preview-fixture-\(day)"), "the sibling is parked under its own alias and says why it stands beside")
        guard case .written(let again) = asker.write(data, note: "And again.") else { fatalError("FAIL: a second ask the same day is written") }
        check(again.appended && again.url == sibling && !FileManager.default.fileExists(atPath: vault.contract(slug: "fixture-\(day)-2").path), "a second ask the same day joins the sibling; no -2 folder")
        let foreign = vault.contract(slug: "image")
        let foreignText = "---\ntype: project\naliases: [pictures-elsewhere]\nstatus: active\n---\n# Someone else's project\n"
        try! FileManager.default.createDirectory(at: foreign.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(foreignText.utf8).write(to: foreign)
        guard case .written(let picture) = asker.write(entry([(.png, ClipboardWebCopies.picture.png)]), note: nil) else { fatalError("FAIL: a picture's brief is written beside another project") }
        check(!picture.appended && picture.path == "projects/clipedge-preview-image-\(day)/AGENTS.md" && (try? String(contentsOf: foreign, encoding: .utf8)) == foreignText,
              "another project at the brief's place is left alone and the brief goes beside it")
        let live = vault.contract(slug: "text")
        try! FileManager.default.createDirectory(at: live.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data("---\ntype: project\naliases: [clipedge-preview-text]\nstatus: active\n---\n# Being worked\n".utf8).write(to: live)
        guard case .written(let joined) = asker.write(entry([(.string, Data("Fixture words".utf8))]), note: nil) else { fatalError("FAIL: a request joins an active brief") }
        check(joined.appended && joined.url == live && (try? String(contentsOf: live, encoding: .utf8))?.contains("## Request on \(day)") == true, "an active brief takes the request")
    }

    // MARK: Copy prompt

    private static func transientCopyChecks() {
        let (vault, root) = makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let board = NSPasteboard.withUniqueName()
        let store = ClipboardStore(pasteboard: board, persistenceURL: nil)
        defer { store.stop(); board.releaseGlobally() }
        board.clearContents(); board.writeObjects([ClipboardWebCopies.item([(.string, Data("Fixture words".utf8))])]); _ = store.saveNow(); store.cancelStaging()
        let before = store.entries.map(\.id)
        var asker = ClipboardPreviewAsker(vault: vault, pasteboard: board)
        asker.now = { fixedDay }
        guard case .written(let record) = asker.write(store.entries[0], note: nil) else { fatalError("FAIL: the brief is written") }
        check(asker.copyPrompt(record), "Copy prompt writes the clipboard")
        check(board.string(forType: .string) == record.prompt && board.pasteboardItems?.first?.types.contains(type("org.nspasteboard.TransientType")) == true,
              "the prompt is on the clipboard, marked transient")
        _ = store.saveNow()
        check(store.entries.map(\.id) == before, "ClipEdge's own capture skips it: the history is unchanged")
        check(!store.entries.contains { $0.plainText?.contains("clipedge-preview") == true }, "and no entry holds the brief")
    }

    // MARK: The ⌥⌘\ window

    private static func windowChecks() {
        check(ClipboardKeymap.window.action(for: askKey) == .ask, "⌥⌘A is the ask")
        check(ClipboardKeymap.window.action(for: key(0, .command, "a")) == nil && ClipboardKeymap.window.action(for: key(0, [.option, .command, .shift], "a")) == nil, "⌘A and ⇧⌥⌘A are not")
        let (vault, root) = makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let board = NSPasteboard.withUniqueName()
        let store = ClipboardStore(pasteboard: board, persistenceURL: nil)
        func copy(_ values: Values) { board.clearContents(); board.writeObjects([ClipboardWebCopies.item(values)]); _ = store.saveNow() }
        copy([(.string, Data("Fixture words".utf8))]); copy(ClipboardWebCopies.appDataOnly)
        store.cancelStaging()
        let panel = WindowTestPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 470), styleMask: [], backing: .buffered, defer: true)
        let materializer = ClipboardMaterializer(root: ClipboardMaterializer.defaultRoot.deletingLastPathComponent().appendingPathComponent("ClipEdge-brief-window-\(UUID().uuidString)"))
        defer { materializer.removeAll(); store.stop(); board.releaseGlobally() }
        let history = ClipboardHistoryController(store: store, paster: ClipboardPaster(store: store, environment: .inert),
                                                 previewService: ClipboardPreviewService(materializer: materializer), panel: panel)
        history.prepare = { nil }
        let view = history.view, form = view.askView
        func press(_ event: NSEvent) -> Bool { history.handleKey(event) }
        var typingInSearch: Bool { (panel.firstResponder as? NSTextView)?.delegate === view.search }
        var typingNote: Bool { (panel.firstResponder as? NSTextView)?.delegate === form.note }

        // An ordinary copy: no asker, no button, the key does nothing.
        history.hotKeyPressed()
        check(!view.footer.items.map(\.title).contains { $0.hasPrefix("Ask for a preview") }, "without a maintainer vault the footer has no Ask for a preview")
        view.layoutSubtreeIfNeeded()
        // Seven buttons since Raw data ⌘I (2026-10-12): they share one row. With their keys in caps
        // (2026-10-16) the hint no longer fits beside them at 800 points and takes a short row of its own.
        let words = ceil(view.footer.hint.attributed(font: .systemFont(ofSize: 11), color: .labelColor).size().width)
        let buttonsEnd = view.footer.shownButtonFrames.map(\.maxX).max() ?? 0
        check(Set(view.footer.shownButtonFrames.map(\.minY)).count == 1 && view.footer.items.count == 7
              && view.footer.frame.height == ClipboardHistoryFooter.rowHeight + ClipboardHistoryFooter.hintRowHeight
              && view.footer.hintFrame.minY >= view.footer.shownButtonFrames.map(\.maxY).max()!
              && view.footer.hintFrame.width >= words && view.footer.bounds.contains(view.footer.hintFrame),
              "its seven buttons share one row, the hint whole beneath them (\(view.footer.hintFrame) for \(words); buttons end \(buttonsEnd) in \(view.footer.bounds.width))")
        check(press(askKey) && !history.isAsking && form.isHidden && view.showsCard && typingInSearch, "⌥⌘A does nothing there")
        history.close()

        // The maintainer copy.
        var opened: [URL] = []
        var asker = ClipboardPreviewAsker(vault: vault, pasteboard: board, open: { opened.append($0) })
        asker.now = { fixedDay }
        history.previewAsker = asker
        history.hotKeyPressed()
        let items = view.footer.items.map(\.title)
        check(items.last == "Ask for a preview ⌥⌘A" && items.count == 8, "a maintainer copy's footer ends with Ask for a preview and its key (\(items))")
        // Eight buttons do not fit on one row: the last goes on to a second, every title whole, and the
        // hint shows whole beside it or on a row of its own.
        func hintShowsWhole(_ moment: String) {
            view.layoutSubtreeIfNeeded()
            let words = ceil(view.footer.hint.attributed(font: .systemFont(ofSize: 11), color: .labelColor).size().width)
            let buttons = view.footer.shownButtonFrames
            check(view.footer.hintFrame.width >= words && view.footer.frame.maxY == view.bounds.maxY && view.flip.frame.maxY <= view.footer.frame.minY
                  && view.footer.bounds.contains(view.footer.hintFrame) && buttons.allSatisfy { view.footer.bounds.insetBy(dx: 8, dy: 0).contains($0) && !$0.intersects(view.footer.hintFrame) }
                  && Set(buttons.map(\.minY)).count == 2 && view.footer.frame.height >= ClipboardHistoryFooter.rowHeight + ClipboardHistoryFooter.buttonRowStep,
                  "\(moment), every button shows whole on two rows and the hint “\(view.footer.hintText)” whole beside or under them, the card above the footer (\(view.footer.hintFrame) for \(words))")
        }
        hintShowsWhole("with eight buttons")
        _ = press(key(51, .command))
        check(view.canvas.armedID != nil && !view.footer.hintText.lowercased().contains("esc"), "⌘⌫ arms the row; the footer explains no Esc")
        hintShowsWhole("while a delete waits")
        _ = press(key(53))
        view.search.stringValue = "fixture"; history.view.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        check(!view.footer.hintText.lowercased().contains("esc"), "a search leaves the hint without Esc")
        hintShowsWhole("while searching")
        _ = press(key(53))
        check(history.selectedEntry === store.entries[0] && store.entries[0].appData != nil, "the app data is selected")
        check(press(askKey) && history.isAsking && !form.isHidden && !view.showsCard && typingNote && form.stage == .asking,
              "⌥⌘A puts the form in the card's place with the keyboard in its field")
        check(form.shownButtons == ["Write brief ⌘⏎", "Cancel"] && form.note.placeholderString == "What should a better preview show?" && form.note.stringValue.isEmpty,
              "the form offers Write brief ⌘⏎ and Cancel over an empty field")
        check(view.footer.items.isEmpty && view.footer.hintText.isEmpty, "the footer defers to the form, explaining nothing about Esc")
        let editor = panel.firstResponder as! NSTextView
        check(form.control(form.note, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))) && history.isAsking, "a plain Return in the field writes nothing")
        check(!form.control(form.note, textView: editor, doCommandBy: #selector(NSResponder.moveRight(_:))), "other field commands are the field's")
        check(form.control(form.note, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))) && !history.isAsking && view.showsCard && typingInSearch,
              "Esc in the field goes back to the item, with the keyboard in the search")
        _ = press(askKey)
        check(form.control(form.note, textView: panel.firstResponder as! NSTextView, doCommandBy: #selector(NSResponder.moveLeft(_:))) && !history.isAsking, "Left in the empty field goes back")
        _ = press(askKey)
        form.note.stringValue = "Show the shape."
        check(!form.performKeyEquivalent(with: key(123)) && history.isAsking, "with words in the field, Left is the field's")
        check(!form.performKeyEquivalent(with: key(49, [], " ")) && history.isAsking && form.stage == .asking, "Space in the field is a space, not a button")
        check(form.performKeyEquivalent(with: key(53)) && !history.isAsking, "Esc as a key equivalent goes back too")
        _ = press(askKey)
        form.note.stringValue = "Show the shape."
        check(form.performKeyEquivalent(with: key(36, .command, "\r")) && history.isAsking, "⌘⏎ writes the brief and stays")
        guard case .written(let record) = form.stage else { fatalError("FAIL: the form shows the written brief") }
        let file = vault.contract(slug: "fixture")
        check(record.path == "projects/clipedge-preview-fixture/AGENTS.md" && FileManager.default.fileExists(atPath: file.path)
              && (try? String(contentsOf: file, encoding: .utf8))?.contains("Show the shape.") == true, "the brief is in the temporary vault with the note")
        check(form.resultText == "Brief written: projects/clipedge-preview-fixture/AGENTS.md" && form.shownButtons == ["Open in Obsidian ⌘⏎", "Copy prompt ⌥⌘C", "Back"] && form.copiedText == nil,
              "the form's place names the brief with Open in Obsidian ⌘⏎ and Copy prompt ⌥⌘C")
        check(panel.firstResponder === form && !typingNote, "the keyboard moves to the form")
        form.keyDown(with: key(49, [], " "))
        check(history.isAsking && form.stage == .written(record) && opened.isEmpty && board.string(forType: .string) == nil, "Space does nothing")
        check(form.performKeyEquivalent(with: key(8, [.option, .command], "с")) && board.string(forType: .string) == record.prompt
              && board.pasteboardItems?.first?.types.contains(type("org.nspasteboard.TransientType")) == true, "⌥⌘C copies the prompt, marked transient")
        check(form.copiedText == "Prompt copied. Paste it into a chat; ClipEdge keeps no copy." && history.isAsking, "and says so in place")
        _ = store.saveNow()
        check(store.entries.count == 2 && store.entries[0].appData != nil, "the store did not record the prompt")
        check(form.performKeyEquivalent(with: key(36, .command, "\r")) && opened == [record.obsidianURL] && history.isAsking, "⌘⏎ opens the brief in Obsidian")
        form.keyDown(with: key(53))
        check(!history.isAsking && view.showsCard && form.isHidden && typingInSearch && history.selectedEntry === store.entries[0], "Esc returns to the same item")
        _ = press(askKey)
        form.keyDown(with: key(36, .command, "\r"))
        if case .written = form.stage { form.keyDown(with: key(123)) }
        check(!history.isAsking && view.showsCard, "Left from the result goes back too")
        let before = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        check(before.components(separatedBy: "## Request on ").count == 2, "the second ask on the same app appended a request rather than a second project")
        view.footer.items.last?.action()
        check(history.isAsking && typingNote, "the footer button opens the form as the key does")
        history.close()
        check(!history.isVisible, "closing while asking closes the window")
        history.hotKeyPressed()
        check(!history.isAsking && view.showsCard, "the next opening starts on the card")
        history.close()
    }

    // MARK: The drawer

    private static func drawerChecks() {
        let (vault, root) = makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let board = NSPasteboard.withUniqueName()
        let store = ClipboardStore(pasteboard: board, persistenceURL: nil)
        board.clearContents(); board.writeObjects([ClipboardWebCopies.item(ClipboardWebCopies.appDataOnly)]); _ = store.saveNow(); store.cancelStaging()
        let magnet = ClipboardMagnetController(panel: DrawerTestPanel(contentRect: .zero, styleMask: [], backing: .buffered, defer: true), commandClickEnabled: false)
        let drawer = ClipboardDrawerController(store: store, magnetController: magnet,
                                               panel: DrawerTestPanel(contentRect: .zero, styleMask: [], backing: .buffered, defer: true), defaults: nil)
        defer { drawer.stop(); store.stop(); board.releaseGlobally() }
        // A card's help lists ⌥⌘A from its container's own asker, so the two cannot disagree.
        let listed = ClipboardPreviewAsker(vault: vault, pasteboard: board, open: { _ in })
        check(!ClipboardTileTooltip.rows(.drawer, asker: nil).contains { $0.0 == "Ask for a preview" } && !ClipboardTileTooltip.legendText(.drawer, asker: nil).contains("⌥⌘A"), "an ordinary copy's tile help has no such key")
        check(ClipboardTileTooltip.rows(.drawer, asker: listed).last! == ("Ask for a preview", "⌥⌘A") && ClipboardTileTooltip.legendText(.drawer, asker: listed).hasSuffix("Ask for a preview ← ⌥⌘A"), "a maintainer copy's tile help lists it")
        drawer.show(on: NSScreen.main!)
        func cardsHelp() -> [String] { drawer.browser.canvas.tiles.compactMap { $0.accessibilityHelp() } }
        check(!cardsHelp().isEmpty && cardsHelp().allSatisfy { !$0.contains("Ask for a preview") }, "without an asker, the drawer's cards say nothing of ⌥⌘A")
        drawer.browser.layoutSubtreeIfNeeded()
        check(drawer.browser.canvas.selected?.entry.appData != nil, "the app data is selected")
        check(!drawer.handleDrawerKey(askKey) && !drawer.askPopover.isVisible, "without a maintainer vault ⌥⌘A is not the drawer's")
        var asker = ClipboardPreviewAsker(vault: vault, pasteboard: board, open: { _ in })
        asker.now = { fixedDay }
        drawer.previewAsker = asker
        check(cardsHelp().allSatisfy { $0.hasSuffix("Ask for a preview: " + ClipboardKeymap.drawer.spoken(.ask)!) }, "given one, the drawer's cards list ⌥⌘A at once, with nothing else to set")
        drawer.previewAsker = nil
        check(cardsHelp().allSatisfy { !$0.contains("Ask for a preview") }, "and taking it away takes the key from their help")
        drawer.previewAsker = asker
        check(drawer.handleDrawerKey(askKey) && drawer.askPopover.isVisible, "with one, ⌥⌘A opens the ask beside the drawer")
        let form = drawer.askPopover.view
        check(form.stage == .asking && form.entry?.id == store.entries[0].id && form.frame.width == ClipboardPreviewAskPopover.width, "the panel holds the form for the selected tile")
        let screen = NSScreen.main!.visibleFrame
        let frame = drawer.askPopover.frame
        check(screen.contains(frame) && !frame.intersects(drawer.bodyFrame!) && abs(frame.midY - drawer.browser.screenFrame(for: store.entries[0].id)!.midY) <= frame.height / 2 + 1,
              "beside the drawer, level with the tile, inside the display (\(frame) vs \(drawer.bodyFrame!))")
        check(drawer.contains(NSPoint(x: frame.midX, y: frame.midY)) && !drawer.allowsAutomaticHiding, "the drawer counts the form as its own and stays open")
        let heightAsking = frame.height
        form.note.stringValue = "Show the shape."
        check(form.performKeyEquivalent(with: key(36, .command, "\r")) && drawer.askPopover.isVisible, "⌘⏎ writes the brief and the panel stays")
        guard case .written(let record) = form.stage else { fatalError("FAIL: the drawer's form shows the written brief") }
        check(record.path == "projects/clipedge-preview-fixture/AGENTS.md" && FileManager.default.fileExists(atPath: vault.contract(slug: "fixture").path), "the brief is in the temporary vault")
        check(drawer.askPopover.frame.height == form.fittingHeight(width: ClipboardPreviewAskPopover.width) && drawer.askPopover.frame.height != heightAsking,
              "the panel follows the form's new height")
        // Three buttons do not fit one 320-point row: they wrap, and the panel reaches the last row.
        func buttonsInside(_ moment: String) {
            form.layoutSubtreeIfNeeded()
            let shown = form.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }
            check(shown.count == 3 && shown.allSatisfy { $0.frame.maxX <= form.bounds.width - 16 && $0.frame.minX >= 16 } && shown.map(\.frame.maxY).max()! + 14 == drawer.askPopover.frame.height,
                  "\(moment), every button sits inside the panel's width, and the panel's height reaches the last row (\(shown.map { NSStringFromRect($0.frame) }))")
        }
        buttonsInside("once written")
        check(form.performKeyEquivalent(with: key(8, [.option, .command], "с")) && form.copiedText != nil && drawer.askPopover.isVisible, "⌥⌘C copies the prompt in the drawer too")
        check(drawer.askPopover.frame.height == form.fittingHeight(width: ClipboardPreviewAskPopover.width), "the panel grows to the copied line")
        buttonsInside("after Copy prompt")
        let copiedLabel = form.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == form.copiedText }!
        check(copiedLabel.frame.height >= copiedLabel.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: copiedLabel.frame.width, height: 10_000)).height && form.bounds.contains(copiedLabel.frame),
              "the copied line wraps to its words rather than being cut short (\(copiedLabel.frame))")
        check(form.performKeyEquivalent(with: key(53)) && !drawer.askPopover.isVisible && drawer.allowsAutomaticHiding, "Esc closes the form and gives the drawer back")
        check(drawer.handleDrawerKey(askKey) && drawer.askPopover.isVisible, "it can open again")
        drawer.hide(animated: false)
        check(!drawer.askPopover.isVisible, "hiding the drawer closes it")
    }
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
