import AppKit

@main enum HistoryTests {
    private static var assertions = 0
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError("FAIL: \(message)") }
    }
    private static func key(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = [], characters: String = "") -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    static func main() {
        _ = NSApplication.shared
        let board = NSPasteboard.withUniqueName()
        let store = ClipboardStore(pasteboard: board, persistenceURL: nil)
        ClipboardDemo.seed(store, board: board)
        for text in ["Trip: pack a notebook", "Trip: book a room"] {
            board.clearContents(); board.setString(text, forType: .string); _ = store.saveNow()
        }
        board.clearContents()
        let rich = NSPasteboardItem()
        rich.setString("Rich note", forType: .string)
        rich.setData(Data("{\\rtf1\\ansi\\b Rich note}".utf8), forType: .rtf)
        board.writeObjects([rich]); _ = store.saveNow()
        store.cancelStaging()
        // Newest first: rich note, two trips, the seeded note, then three pictures.
        check(store.entries.count == 7 && store.entries[0].title == "Rich note", "fixture has seven entries, newest first")

        // The store: make current, and lend plain text for one paste.
        var staging: [String] = []
        store.onStagingChange = { staging.append(String(describing: $0).components(separatedBy: "(")[0]) }
        let room = store.entries[1], picture = store.entries[4]
        check(store.makeCurrent(room) && store.entries[0] === room && board.string(forType: .string) == "Trip: book a room", "make current writes the clipboard and promotes")
        check(store.stagedEntryID == nil && staging.isEmpty, "make current holds nothing and shows no magnet")
        store.selectForPaste(store.entries[2])
        check(store.liftedEntryID != nil && store.makeCurrent(room) && store.stagedEntryID == nil && staging.last == "invalidated", "make current ends an existing pickup")
        let richEntry = store.entries.first { $0.title == "Rich note" }!
        check(store.makeCurrent(richEntry) && board.data(forType: .rtf) != nil, "rich entry is on the clipboard in full")
        let countBefore = store.entries.count
        guard let loan = store.beginPlainTextPaste() else { fatalError("FAIL: plain loan begins") }
        check(board.string(forType: .string) == "Rich note" && board.data(forType: .rtf) == nil, "lent clipboard holds plain text only")
        check(board.pasteboardItems?.first?.types.contains(transient) == true, "lent copy is marked transient for clipboard managers")
        _ = store.saveNow()
        check(store.entries.count == countBefore && store.entries[0] === richEntry, "the lent text never becomes a history entry")
        store.endPlainTextPaste(loan + 1)
        check(board.data(forType: .rtf) == nil, "another loan's token does not end this one")
        store.endPlainTextPaste(loan)
        check(board.data(forType: .rtf) != nil && board.pasteboardItems?.first?.types.contains(transient) == false, "ending the loan restores the full item")
        check(store.makeCurrent(picture) && store.beginPlainTextPaste() != nil, "a picture lends too")
        check(board.string(forType: .string) == picture.metadata.pasteText && picture.metadata.pasteText.contains(" × "), "a picture pastes its facts as plain text")
        board.clearContents(); board.setString("Copied meanwhile", forType: .string)
        store.endPlainTextPaste()
        _ = store.saveNow()
        check(board.string(forType: .string) == "Copied meanwhile" && store.entries[0].title == "Copied meanwhile", "a newer copy wins over the returning loan")
        store.cancelStaging()
        board.clearContents()
        let secret = NSPasteboardItem()
        secret.setString("hunter2", forType: .string); secret.setData(Data(), forType: concealed)
        board.writeObjects([secret]); _ = store.saveNow()
        check(!store.entries.contains { $0.title == "hunter2" }, "concealed copies stay out of history")
        let secretLoan = store.beginPlainTextPaste()
        check(secretLoan != nil && board.string(forType: .string) == "hunter2" && board.pasteboardItems?.first?.types.contains(concealed) == true,
              "an untracked clipboard lends its own text, still concealed, not an older entry")
        store.endPlainTextPaste()
        check(board.string(forType: .string) == "hunter2" && !store.entries.contains { $0.title == "hunter2" }, "the untracked clipboard returns untouched")
        board.clearContents(); _ = store.saveNow()
        let top = store.entries[0]
        check(store.beginPlainTextPaste() != nil && board.string(forType: .string) == top.plainTextForPaste, "an empty clipboard takes the top entry")
        store.endPlainTextPaste()
        staging = []

        // Delivery: bring the destination forward when needed, then Paste.
        var front: pid_t? = 500, posted: [pid_t] = [], failures = 0, now = 0.0
        var scheduled: [() -> Void] = []
        var environment = ClipboardPaster.Environment()
        environment.frontmost = { front }
        environment.postPaste = { posted.append($0); return true }
        environment.schedule = { _, action in scheduled.append(action) }
        environment.now = { now }
        environment.failed = { failures += 1 }
        func runScheduled() { while !scheduled.isEmpty { scheduled.removeFirst()() } }
        let paster = ClipboardPaster(store: store, environment: environment)
        var activations = 0
        let ahead = ClipboardPaster.Target(pid: 500) { activations += 1 }
        let behind = ClipboardPaster.Target(pid: 900) { activations += 1; front = 900 }
        let stuck = ClipboardPaster.Target(pid: 901) { activations += 1 }
        let notebook = store.entries.first { $0.title == "Trip: pack a notebook" }!
        paster.paste(notebook, into: ahead)
        check(posted.isEmpty && scheduled.count == 1 && activations == 0, "the app in front is not activated; paste waits for its window")
        runScheduled()
        check(posted == [500] && board.string(forType: .string) == "Trip: pack a notebook" && store.entries[0] === notebook, "Paste goes to the app in front with the entry on the clipboard")
        paster.paste(room, into: behind); runScheduled()
        check(activations == 1 && posted == [500, 900], "another app is brought forward first")
        paster.paste(notebook, into: stuck)
        for _ in 0..<5 { now += 0.5; let pending = scheduled; scheduled = []; pending.forEach { $0() } }
        check(posted.count == 2 && failures == 1 && board.string(forType: .string) == "Trip: pack a notebook", "an app that never comes forward gets no Paste; the entry stays on the clipboard")
        paster.paste(room, into: nil)
        check(failures == 2 && board.string(forType: .string) == "Trip: book a room", "with nowhere to paste the entry still becomes current")
        front = 500
        _ = store.makeCurrent(richEntry)
        paster.paste(richEntry, into: ahead, plain: true)
        scheduled.removeFirst()()
        check(posted.last == 500 && board.data(forType: .rtf) == nil && board.string(forType: .string) == "Rich note", "plain paste sends Paste while the clipboard holds text only")
        runScheduled()
        check(board.data(forType: .rtf) != nil, "the full item returns after the plain paste")
        posted = []; failures = 0

        // The history window.
        let panel = HistoryTestPanel(contentRect: NSRect(x: 0, y: 0, width: 700, height: 440), styleMask: [], backing: .buffered, defer: true)
        let materializer = ClipboardMaterializer(root: FileManager.default.temporaryDirectory.appendingPathComponent("ClipEdge-history-tests-\(UUID().uuidString)"))
        defer { materializer.removeAll() }
        let previews = ClipboardPreviewService(materializer: materializer)
        let history = ClipboardHistoryController(store: store, paster: paster, previewService: previews, panel: panel)
        var prepared = 0, opened: [UUID] = []
        history.prepare = { prepared += 1; return ahead }
        history.openInPreview = { entry, done in opened.append(entry.id); done(nil) }
        history.sendSources = ClipboardSendTo.Sources(
            openers: { _ in [URL(fileURLWithPath: "/Applications/Preview.app"), URL(fileURLWithPath: "/System/Applications/Preview.app")] },
            running: { [ClipboardSendTo.RunningApp(pid: 900, name: "Notes", url: nil), ClipboardSendTo.RunningApp(pid: 500, name: "Zed", url: nil)] },
            pasteTarget: { pid in ClipboardPaster.Target(pid: pid) { front = pid } })
        let canvas = history.view.canvas, sendTo = history.view.sendTo, search = history.view.search
        @discardableResult func press(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = [], _ characters: String = "") -> Bool {
            history.handleKey(key(code, modifiers, characters: characters))
        }
        func type(_ query: String) { search.stringValue = query; history.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification)) }
        var typingInSearch: Bool { (panel.firstResponder as? NSTextView)?.delegate === search }
        let order = { store.entries.map(\.id) }
        check(!history.isVisible && history.selectedEntry == nil, "window starts closed")
        history.hotKeyPressed()
        check(history.isVisible && prepared == 1 && panel.isVisible && typingInSearch, "first press opens the window with the keyboard in its search field")
        check(history.selectedEntry === store.entries[0] && canvas.tiles.count == store.entries.count, "the newest entry is preselected")
        check(!canvas.acceptsFirstResponder && history.view.tabs.refusesFirstResponder && history.view.deleteAll.refusesFirstResponder, "clicking the list, tabs or buttons leaves the keyboard in the search field")
        check(history.view.countText.hasPrefix("\(store.entries.count) of \(store.entries.count) items"), "the count says how many items show")
        check(canvas.tiles.allSatisfy { $0.style == .compact }, "rows are compact")
        check(history.view.card.entryID == store.entries[0].id && history.view.card.edgeText.contains("words"), "the card shows the selection with its facts along the edge")
        history.hotKeyPressed()
        check(history.selectedEntry === store.entries[1] && history.view.card.entryID == store.entries[1].id, "a second press selects the next older entry")
        press(125); check(history.selectedEntry === store.entries[2], "Down selects the older entry")
        press(124); check(history.selectedEntry === store.entries[3], "Right also moves down")
        press(126); check(history.selectedEntry === store.entries[2], "Up selects the newer entry")
        press(123); check(history.selectedEntry === store.entries[1], "Left also moves up")
        for _ in 0..<(store.entries.count - 1) { history.hotKeyPressed() }
        check(history.selectedEntry === store.entries[0], "repeated presses wrap from the oldest back to the newest")
        press(126); check(history.selectedEntry === store.entries[0], "Up stops at the newest entry")
        check(history.view.footer.items.map(\.title) == ["Paste ⏎", "Plain text ⌃⌘⏎", "Copy ⌘C", "Send to ⇥", "Open in Preview ⌘O", "Delete ⌘⌫"], "every action button names its key")
        check(history.view.footer.hint.hasSuffix("esc closes"), "with no search, Esc closes")
        check(!press(0, [], "a") && !press(51) && !press(51, .option) && !press(123, .shift) && !press(124, .command), "letters, ⌫, ⌥⌫ and modified arrows go to the search field")
        check(press(48, .shift) && typingInSearch && !history.isSending, "⇧Tab does not move the keyboard out of the search field")

        // Typing searches; the newest match is selected as each letter lands.
        canvas.choose(store.entries[4].id)
        type("trip")
        let trips = store.entries.filter { $0.title.hasPrefix("Trip") }
        check(canvas.tiles.map(\.entry.id) == trips.map(\.id) && trips.count == 2, "typing shows only the matching entries")
        check(history.selectedEntry === trips[0] && history.view.countText.hasPrefix("2 of \(store.entries.count) items"), "the newest match is selected and counted")
        check(history.view.footer.hint.hasSuffix("esc clears search"), "with a search, Esc says it clears the search")
        press(125); check(history.selectedEntry === trips[1], "arrows move within the matches")
        history.hotKeyPressed(); check(history.selectedEntry === trips[0], "the shortcut wraps within the matches")
        type("no such words")
        check(canvas.tiles.isEmpty && history.view.emptyText == "No matching items" && history.selectedEntry == nil, "no matches says so")
        check(press(36) && history.isVisible && posted.isEmpty, "Return with nothing shown pastes nothing")
        press(53)
        check(history.isVisible && search.stringValue.isEmpty && canvas.tiles.count == store.entries.count, "Esc clears the search and keeps the window")
        check(history.selectedEntry === store.entries[0], "clearing the search selects the newest entry")

        // ⌘1–⌘3 choose the tab; the selection stays when it is still shown.
        let pictures = store.entries.filter(\.isImage)
        canvas.choose(pictures[1].id)
        check(press(19, .command, "2") && history.view.currentTab == .images, "⌘2 shows Images")
        check(canvas.tiles.map(\.entry.id) == pictures.map(\.id) && history.selectedEntry === pictures[1], "Images keeps the selected picture")
        check(press(20, .command, "3") && history.view.currentTab == .text && canvas.tiles.allSatisfy { !$0.entry.isImage }, "⌘3 shows Text")
        check(history.selectedEntry === canvas.tiles.first?.entry, "a tab without the selection selects its newest entry")
        type("trip"); check(canvas.tiles.count == 2, "search works within a tab")
        type("")
        history.view.tabs.selectedSegment = 1
        history.view.tabs.sendAction(history.view.tabs.action!, to: history.view.tabs.target)
        check(history.view.currentTab == .images && canvas.tiles.count == pictures.count, "clicking a tab does the same")
        press(18, .command, "1"); check(history.view.currentTab == .all && canvas.tiles.count == store.entries.count, "⌘1 shows everything again")
        history.close(); history.hotKeyPressed()
        check(history.view.currentTab == .all && search.stringValue.isEmpty && history.selectedEntry === store.entries[0], "each opening starts from All, no search, newest first")

        // A row that opens or scrolls under a still pointer must not take the selection.
        var pointer = NSPoint(x: 400, y: 300)
        history.view.pointer = { pointer }
        history.close(); history.hotKeyPressed()
        canvas.tiles[3].onHover?()
        check(history.selectedEntry === store.entries[0], "a row under the resting pointer does not replace the newest entry")
        history.hotKeyPressed(); canvas.tiles[5].onHover?()
        check(history.selectedEntry === store.entries[1], "stepping by keyboard is not undone by the row now under the pointer")
        press(125); canvas.tiles[5].onHover?()
        check(history.selectedEntry === store.entries[2], "arrow keys keep the selection under a still pointer")
        type("trip"); canvas.tiles[1].onHover?()
        check(history.selectedEntry === canvas.tiles[0].entry, "results that appear under a still pointer do not take the selection")
        type("")
        pointer.x += 3; canvas.tiles[5].onHover?()
        check(history.selectedEntry === store.entries[5], "once the pointer moves, hover selects")
        canvas.choose(store.entries[0].id)
        check(staging.isEmpty && store.stagedEntryID == nil, "browsing holds nothing and shows no magnet")

        // Return pastes into the app the window opened over.
        press(125); press(125)
        let chosen = history.selectedEntry!
        let beforePaste = order()
        press(36)
        check(!history.isVisible && !panel.isVisible, "Return closes the window")
        runScheduled()
        check(posted == [500] && store.entries[0] === chosen && board.string(forType: .string) == chosen.plainText, "Return pastes the selection and moves it to the top")
        check(order() == [chosen.id] + beforePaste.filter { $0 != chosen.id }, "only the pasted entry moves")
        check(!press(36), "keys do nothing once the window is closed")

        // ⌃⌘Return pastes plain text.
        history.hotKeyPressed()
        canvas.choose(richEntry.id)
        press(36, [.control, .command])
        scheduled.removeFirst()()
        check(!history.isVisible && posted.last == 500 && board.data(forType: .rtf) == nil && board.string(forType: .string) == "Rich note", "⌃⌘Return pastes text without its styling")
        runScheduled()
        check(board.data(forType: .rtf) != nil && store.entries[0] === richEntry, "afterwards the clipboard holds the full entry again")
        history.hotKeyPressed()
        canvas.choose(picture.id)
        press(36, [.control, .command])
        scheduled.removeFirst()()
        check(board.string(forType: .string) == picture.metadata.pasteText, "⌃⌘Return on a picture pastes its facts")
        runScheduled()
        check(board.string(forType: .string) == nil && store.entries[0] === picture, "the picture itself returns to the clipboard")
        history.hotKeyPressed()
        check(press(36, .command) && press(36, .option) && history.isVisible, "other Return chords do nothing")

        // ⌘C picks the entry up, as Return does in the drawer.
        let clipboardBefore = board.pasteboardItems?.first?.types ?? []
        let orderBefore = order()
        press(126); press(125); press(125)
        let lifted = history.selectedEntry!
        staging = []
        let pastesBefore = posted.count
        check(press(8, .command, "c") && !history.isVisible, "⌘C closes the window")
        check(store.liftedEntryID == lifted.id && board.string(forType: .string) == lifted.plainText && staging == ["pickedUp"], "⌘C puts it on the clipboard, held by the cursor magnet")
        check(order() == orderBefore && posted.count == pastesBefore && scheduled.isEmpty, "⌘C pastes nothing and moves nothing yet")
        store.cancelStaging()
        check(store.liftedEntryID == nil && board.pasteboardItems?.first?.types == clipboardBefore && order() == orderBefore, "Esc in another app brings back the previous clipboard")
        history.hotKeyPressed(); press(125); press(125)
        let kept = history.selectedEntry!
        press(8, .command, "c"); store.commitStagedPaste()
        check(store.entries[0] === kept && store.liftedEntryID == nil, "pasting it moves it to the top")
        staging = []

        // ⌘O opens the selection in Preview.
        history.hotKeyPressed()
        canvas.choose(picture.id)
        check(press(31, .command, "o") && opened == [picture.id] && !history.isVisible, "⌘O opens the selected item in Preview and closes the window")

        // Tab offers apps; ← and Esc go back.
        posted = []
        history.hotKeyPressed()
        type("trip")
        let sendEntry = history.selectedEntry!
        check(sendEntry.kind != .image && sendEntry.fileURLs.isEmpty, "fixture selection is plain text")
        press(48)
        check(history.isSending && panel.firstResponder === sendTo && !sendTo.isHidden && history.view.card.isHidden, "Tab opens Send to beside the selected row")
        check(!press(53) && history.isSending, "while choosing an app, the list's keys belong to Send to")
        check(sendTo.targets == [.paste(pid: 900, name: "Notes", app: nil), .paste(pid: 500, name: "Zed", app: nil)], "text can only be pasted into running apps")
        check(history.view.footer.items.map(\.title) == ["Send ⏎", "Back ←"], "Send to names its own keys")
        sendTo.keyDown(with: key(125)); check(sendTo.selected?.name == "Zed", "Down chooses the next app")
        sendTo.keyDown(with: key(125)); check(sendTo.selected?.name == "Zed", "Down stops at the last app")
        history.hotKeyPressed(); check(sendTo.selected?.name == "Notes", "the window's shortcut steps through apps and wraps")
        sendTo.keyDown(with: key(6, characters: "z")); check(sendTo.selected?.name == "Zed", "typing a name jumps to that app")
        sendTo.keyDown(with: key(123))
        check(!history.isSending && history.isVisible && typingInSearch && history.selectedEntry === sendEntry && !history.view.card.isHidden, "Left goes back to the same selected row")
        check(search.stringValue == "trip" && search.currentEditor()?.selectedRange == NSRange(location: 4, length: 0), "the search is kept, with the caret at its end")
        press(48); sendTo.keyDown(with: key(53))
        check(!history.isSending && history.isVisible && history.selectedEntry === sendEntry, "Esc goes back without closing the window")
        press(48); sendTo.keyDown(with: key(36)); runScheduled()
        check(!history.isVisible && store.entries[0] === sendEntry && board.string(forType: .string) == sendEntry.plainText, "Return sends: the entry becomes current and the window closes")
        check(posted == [900] && front == 900, "Send to brings the chosen app forward, then pastes")

        // A picture can also be opened in an app.
        history.hotKeyPressed()
        check(history.view.footer.items.count == 6, "reopening restores the browsing actions")
        canvas.choose(picture.id); press(48)
        check(sendTo.targets.count == 3 && sendTo.targets[0].isOpen && sendTo.targets[0].name == "Preview" && !sendTo.targets[1].isOpen, "a picture lists apps that open it first, one row per app")
        if case .open(_, let items) = sendTo.targets[0] { check(items.count == 1 && items[0].pathExtension == "tiff", "the picture is opened from a derived file") }
        sendTo.keyDown(with: key(53))

        // ⌘⌫ twice deletes; anything else keeps.
        canvas.choose(store.entries[2].id)
        let doomed = history.selectedEntry!, neighbour = store.entries[3]
        let countBeforeDelete = store.entries.count
        press(51, .command)
        check(canvas.armedID == doomed.id && store.entries.count == countBeforeDelete && canvas.selected?.isArmed == true, "first ⌘⌫ only arms the row")
        check(history.view.footer.hint.hasSuffix("esc keeps"), "while a delete waits, Esc says it keeps the item")
        press(53)
        check(canvas.armedID == nil && history.isVisible && store.entries.count == countBeforeDelete, "Esc keeps the row and the window")
        press(51, .command); press(125)
        check(canvas.armedID == nil && store.entries.count == countBeforeDelete, "moving away keeps the row")
        canvas.choose(doomed.id); press(51, .command); press(0, [], "a")
        check(canvas.armedID == nil && store.entries.count == countBeforeDelete, "typing keeps the row")
        canvas.choose(doomed.id)
        press(51, .command); press(51, .command)
        check(!store.entries.contains { $0 === doomed } && store.entries.count == countBeforeDelete - 1, "second ⌘⌫ deletes the entry")
        check(history.selectedEntry === neighbour && canvas.tiles.count == store.entries.count, "the next row takes the selection")

        // A copy arriving while the window is open keeps the selection.
        let held = history.selectedEntry!
        board.clearContents(); board.setString("Copied while open", forType: .string); _ = store.saveNow()
        check(canvas.tiles.first?.entry.title == "Copied while open" && history.selectedEntry === held, "a new copy joins the list without moving the selection")
        store.cancelStaging()
        press(53)
        check(!history.isVisible && !panel.isVisible, "Esc closes the window")
        history.show()
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: panel)
        check(!history.isVisible, "clicking elsewhere closes the window")

        // Placement and the Send to model.
        let small = NSRect(x: 100, y: 50, width: 500, height: 300)
        let fitted = ClipboardHistoryController.frame(in: small)
        check(small.contains(fitted) && fitted.width <= 500 - 16 && fitted.height <= 300 - 16, "the window never exceeds a small display")
        let large = ClipboardHistoryController.frame(in: NSRect(x: 0, y: 0, width: 1_800, height: 1_100))
        check(large.size == ClipboardHistoryController.preferredSize && abs(large.midX - 900) <= 1 && large.midY > 550, "on a large display it is centered, slightly above the middle")
        let both = URL(fileURLWithPath: "/Applications/Both.app"), onlyA = URL(fileURLWithPath: "/Applications/OnlyA.app")
        let a = URL(fileURLWithPath: "/tmp/a.pdf"), b = URL(fileURLWithPath: "/tmp/b.png")
        let sources = ClipboardSendTo.Sources(openers: { $0 == a ? [onlyA, both] : [both] }, running: { [] }, pasteTarget: { _ in nil })
        check(ClipboardSendTo.targets(opening: [a, b], sources: sources) == [.open(app: both, items: [a, b])], "several files list only apps that open all of them")
        check(ClipboardSendTo.targets(opening: [], sources: sources).isEmpty, "nothing to open and nothing running means no targets")
        let linkEntry = ClipboardEntry(fingerprint: "link", capturedAt: Date(), payloads: [ClipboardPayload(values: [(.string, Data("https://example.com/a".utf8))])],
                                       title: "https://example.com/a", detail: "example.com", kind: .link, thumbnail: nil)
        check(ClipboardSendTo.openItems(for: linkEntry, materializer: materializer) == [URL(string: "https://example.com/a")!], "a link is opened as its address")
        check(ClipboardSendTo.openItems(for: notebook, materializer: materializer).isEmpty, "plain text has nothing to open")

        // The drawer: Tab offers the same list beside the tile; ⌘⌫ asks to delete.
        let drawerPanel = HistoryTestPanel(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        let popoverPanel = HistoryTestPanel(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        let magnet = ClipboardMagnetController(panel: HistoryTestPanel(contentRect: .zero, styleMask: [], backing: .buffered, defer: true), commandClickEnabled: false)
        let drawer = ClipboardDrawerController(store: store, magnetController: magnet, panel: drawerPanel, defaults: nil,
                                               paster: paster, sendToPopover: ClipboardSendToPopover(panel: popoverPanel))
        defer { drawer.stop(); store.stop(); board.releaseGlobally() }
        drawer.sendSources = history.sendSources
        drawer.show(on: NSScreen.main!)
        let drawerCanvas = drawer.browser.canvas
        drawerPanel.makeFirstResponder(drawerCanvas)
        let tileEntry = drawerCanvas.selected!.entry
        drawerCanvas.keyDown(with: key(48))
        check(drawer.sendToPopover.isVisible && popoverPanel.firstResponder === drawer.sendToPopover.view, "Tab on a drawer tile opens Send to with the keyboard")
        check(!drawer.allowsAutomaticHiding && drawer.contains(NSPoint(x: popoverPanel.frame.midX, y: popoverPanel.frame.midY)), "the drawer stays open while Send to is showing")
        check(NSScreen.main!.visibleFrame.contains(popoverPanel.frame) && !popoverPanel.frame.intersects(drawer.bodyFrame!), "Send to sits beside the drawer, inside the display")
        drawer.sendToPopover.view.keyDown(with: key(123))
        check(!drawer.sendToPopover.isVisible && drawer.isVisible && drawerPanel.firstResponder === drawerCanvas && drawerCanvas.selected?.entry === tileEntry, "Left goes back to the same tile")
        drawerCanvas.keyDown(with: key(48)); drawer.sendToPopover.view.keyDown(with: key(53))
        check(!drawer.sendToPopover.isVisible && drawer.isVisible && drawer.allowsAutomaticHiding, "Esc goes back and the drawer closes normally again")
        drawerCanvas.keyDown(with: key(48))
        posted = []; front = 900
        drawer.sendToPopover.view.keyDown(with: key(36)); runScheduled()
        check(!drawer.isVisible && !drawer.sendToPopover.isVisible && posted == [900] && store.entries[0] === tileEntry, "Return sends from the drawer and closes it")
        drawer.show(on: NSScreen.main!)
        var deleteRequests: [UUID] = []
        drawerCanvas.onDelete = { deleteRequests.append($0.id) }
        drawerPanel.makeFirstResponder(drawerCanvas)
        let selectedTile = drawerCanvas.selected!.entry.id
        drawerCanvas.keyDown(with: key(51, .command)); drawerCanvas.keyDown(with: key(51))
        check(deleteRequests == [selectedTile, selectedTile], "⌘⌫ and ⌫ both ask to delete the selected tile")
        check(!drawer.handleDrawerKey(key(48)) && ClipboardTileTooltip.legendText.contains("Send to ← Tab") && ClipboardTileTooltip.legendText.contains("Delete ← ⌫ or ⌘⌫"), "the tile help lists Send to and both delete keys")
        let confirm = NSButton(title: "Delete Permanently", target: nil, action: nil)
        ClipboardDrawerController.acceptCommandDelete(confirm)
        check(confirm.performKeyEquivalent(with: key(51, .command, characters: "\u{7F}")) && !confirm.performKeyEquivalent(with: key(51, characters: "\u{7F}")) && !confirm.performKeyEquivalent(with: key(36, characters: "\r")),
              "the delete alert accepts a second ⌘⌫, and nothing plainer")

        // Facts along the edges of tiles and the tile help.
        let tile = drawerCanvas.tiles.first { $0.entry.kind == .text }!
        check(tile.tooltipDetails.contains("words") && tile.tooltipDetails.contains(tile.entry.fullDateTimeStamp) && tile.tooltipText.hasPrefix(tile.tooltipSummary), "tile help carries facts and the full date")
        let anchor = ClipboardDrawerPreviewAnchor(drawer: NSRect(x: 0, y: 100, width: 380, height: 700), screen: NSRect(x: 0, y: 0, width: 1_440, height: 900), edge: .left)
        let beside = anchor.frame(fitting: NSSize(width: 260, height: 300), centeredAtY: 880)
        check(beside.minX == 388 && beside.size == NSSize(width: 260, height: 300) && beside.maxY <= 892, "a companion beside the drawer follows its row and stays on the display")
        check(anchor.frame == anchor.frame(fitting: ClipboardDrawerPreviewAnchor.preferredSize), "the large preview keeps its own placement")

        // ⇧⌘⌫ twice deletes all history; anything else keeps it. Last: it empties the store.
        drawer.hide(animated: false)
        history.hotKeyPressed()
        let total = store.entries.count
        press(51, .command)
        check(press(51, [.shift, .command]) && history.isConfirmingDeleteAll && canvas.armedID == nil, "⇧⌘⌫ asks about everything, replacing a waiting row delete")
        check(!history.view.confirmation.isHidden && history.view.card.isHidden && history.view.confirmation.titleText == "Delete all \(total) clipboard items?" && store.entries.count == total,
              "the question takes the card's place; nothing is deleted yet")
        check(history.view.footer.hint.hasSuffix("esc keeps"), "while it waits, Esc says it keeps everything")
        press(53)
        check(!history.isConfirmingDeleteAll && history.isVisible && !history.view.card.isHidden && store.entries.count == total, "Esc keeps everything and the window")
        press(51, [.shift, .command]); press(0, [], "a")
        check(!history.isConfirmingDeleteAll && store.entries.count == total, "typing keeps everything")
        type("trip"); press(51, [.shift, .command])
        check(history.view.confirmation.titleText == "Delete all \(total) clipboard items?", "the question counts the whole history, not only the matches")
        type("")
        check(!history.isConfirmingDeleteAll, "changing the search keeps everything")
        history.view.deleteAll.performClick(nil)
        check(history.isConfirmingDeleteAll, "the Delete all button asks too")
        press(51, [.shift, .command])
        check(store.entries.isEmpty && history.isVisible && history.view.emptyText == "Copy something to begin" && history.view.countText.hasPrefix("0 of 0 items"),
              "the second ⇧⌘⌫ deletes everything; the window stays open and says so")
        check(press(51, [.shift, .command]) && !history.isConfirmingDeleteAll, "an empty history has nothing to delete")
        check(press(36) && press(8, .command, "c") && history.isVisible && store.liftedEntryID == nil, "Return and ⌘C on an empty history do nothing")
        recallChecks()
        check(ClipboardHistoryCommand.command(for: key(3, [.command], characters: "f")) == .find, "Command-F is the window's search key")
        check(ClipboardHistoryCommand.command(for: key(3, [.command, .shift], characters: "f")) == nil, "Shift-Command-F is left alone")
        print("PASS: \(assertions) history-window/paste/send-to/recall assertions; named board, injected delivery, no input injection")
    }

    /// The Reopen setting: using an entry remembers it with the tab and search
    /// that found it; the window and the drawer reopen there for a few minutes.
    private static func recallChecks() {
        let board = NSPasteboard.withUniqueName()
        let store = ClipboardStore(pasteboard: board, persistenceURL: nil)
        ClipboardDemo.seed(store, board: board)
        for text in ["Trip: pack a notebook", "Trip: book a room"] {
            board.clearContents(); board.setString(text, forType: .string); _ = store.saveNow()
        }
        store.cancelStaging()
        var clock = Date(timeIntervalSinceReferenceDate: 800_000_000), minutes = 5
        let memory = ClipboardRecallMemory(minutes: { minutes }, now: { clock })
        let panel = HistoryTestPanel(contentRect: NSRect(x: 0, y: 0, width: 700, height: 440), styleMask: [], backing: .buffered, defer: true)
        let materializer = ClipboardMaterializer(root: FileManager.default.temporaryDirectory.appendingPathComponent("ClipEdge-recall-tests-\(UUID().uuidString)"))
        defer { materializer.removeAll() }
        let history = ClipboardHistoryController(store: store, paster: ClipboardPaster(store: store, environment: .inert),
                                                 previewService: ClipboardPreviewService(materializer: materializer), recall: memory, panel: panel)
        history.prepare = { nil }
        history.openInPreview = { _, done in done(nil) }
        let search = history.view.search
        func type(_ query: String) { search.stringValue = query; history.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification)) }
        var selectedText: NSRange? { (panel.firstResponder as? NSTextView)?.selectedRange() }

        history.hotKeyPressed()
        check(search.stringValue.isEmpty && memory.last == nil, "with nothing used yet, the window opens fresh")
        type("trip")
        _ = history.handleKey(key(125))
        let trip = history.selectedEntry!
        _ = history.handleKey(key(31, .command, characters: "o"))
        check(!history.isVisible && memory.last?.entryID == trip.id && memory.last?.query == "trip" && memory.last?.tab == .all,
              "opening an entry remembers it with the tab and search that found it")
        clock += 60
        history.hotKeyPressed()
        check(search.stringValue == "trip" && history.selectedEntry === trip, "reopening starts on that search with the entry chosen")
        check(selectedText == NSRange(location: 0, length: 4), "the offered search is selected, so typing replaces it")
        type("t")
        check(search.stringValue == "t" && history.selectedEntry != nil, "typing starts a new search")
        history.close()

        history.hotKeyPressed(); type("")
        _ = history.handleKey(key(19, .command, characters: "2"))
        let picture = history.selectedEntry!
        _ = history.handleKey(key(8, .command, characters: "c"))
        store.cancelStaging()
        clock += 30
        history.hotKeyPressed()
        check(history.view.currentTab == .images && search.stringValue == picture.title && history.selectedEntry === picture,
              "an entry used without a search reopens on its tab and title")
        history.close()

        clock += 300
        history.hotKeyPressed()
        check(search.stringValue.isEmpty && history.view.currentTab == .all && history.selectedEntry === store.entries[0],
              "after the window of minutes, the window opens fresh")
        history.close()
        clock -= 290; minutes = 0
        check(memory.recall() == nil, "Off recalls nothing")
        minutes = 5
        check(memory.recall() != nil, "within the window, the memory answers")
        check(memory.recall(usedAfter: clock) == nil && memory.recall(usedAfter: clock - 3600) != nil,
              "a drawer closed after the use keeps its own search")

        // The drawer's browser reopens on the same memory.
        let browser = ClipboardBrowserView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        browser.update(entries: store.entries, attachedID: nil)
        memory.remember(trip, tab: .text, query: "  trip ")
        browser.restore(memory.recall()!)
        check(browser.currentTab == .text && browser.search.stringValue == "trip" && browser.canvas.selected?.entry === trip,
              "the drawer reopens on the remembered tab and search with the entry chosen")
        check(ClipboardRevealSettings(defaults: nil).recallMinutes == 5, "Reopen defaults to five minutes")
        let settings = ClipboardRevealSettings(defaults: nil)
        settings.recallMinutes = 7
        check(settings.recallMinutes == 5, "only the offered choices are kept")
        settings.recallMinutes = 0
        check(settings.recallMinutes == 0, "Off is a choice")
    }
}

private final class HistoryTestPanel: NSPanel {
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
