import AppKit

/// Multi-select in the drawer and the ⌥⌘\ window (Al, 2026-10-12, in place of Delete all): the keys,
/// Select / Done, Return and clicks marking, the circles and their slide, the selection's actions
/// in the window's card place and beside the drawer, Esc's rung, and 🚨 above all that a delete
/// asks first and only ever removes cards still marked, still shown and still in the history.
/// Named pasteboards and fixture panels only; keys go through each container's own key path.
@main enum MultiSelectTests {
    private static var assertions = 0
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError("FAIL: \(message)") }
    }
    private static func key(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = [], _ characters: String = "") -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }
    /// The same key held down: the system's repeat of it.
    private static func held(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = [], _ characters: String = "") -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: true, keyCode: code)!
    }
    /// A made-up maintainer vault, so ⌥⌘A has somewhere it could write; nothing is written to it here.
    private static func makeAsker(_ board: NSPasteboard) -> (asker: ClipboardPreviewAsker, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClipEdge-multiselect-vault-\(UUID().uuidString)", isDirectory: true)
        let tools = root.appendingPathComponent("projects/clipedge/src/tools", isDirectory: true)
        try! FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        try! Data("#!/bin/bash\n".utf8).write(to: tools.appendingPathComponent("publisher.sh"))
        let vault = ClipboardPreviewBriefVault(publisherTool: tools.appendingPathComponent("publisher.sh"))!
        return (ClipboardPreviewAsker(vault: vault, pasteboard: board, open: { _ in }), root)
    }
    /// Every action whole and inside the panel's 14-point inset, every line of its words shown, its
    /// list of what is marked above the buttons, nothing overlapping, and the panel as tall as all that.
    private static func expectLaidOut(_ panel: ClipboardSelectionPanel, _ moment: String) {
        // Laid out as its window would be before it draws: the container places it, then it its parts.
        panel.window?.contentView?.layoutSubtreeIfNeeded()
        panel.layoutSubtreeIfNeeded()
        let inner = panel.bounds.insetBy(dx: 14, dy: 0)
        var frames: [NSRect] = []
        for shown in panel.shownButtons {
            guard let button = panel.button(shown.action) else { continue }
            check(button.frame.minX >= inner.minX - 0.5 && button.frame.maxX <= inner.maxX + 0.5 && button.frame.maxY <= panel.bounds.maxY + 0.5,
                  "\(moment): \(button.title) sits inside the panel (\(button.frame) in \(panel.bounds))")
            check(button.frame.width >= button.intrinsicContentSize.width, "\(moment): \(button.title) shows its whole title")
            frames.append(button.frame)
        }
        for label in panel.subviews.compactMap({ $0 as? NSTextField }) where !label.isHidden {
            let needed = ceil(label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.frame.width, height: 10_000)).height)
            check(needed <= label.frame.height + 0.5 && label.frame.maxX <= inner.maxX + 0.5,
                  "\(moment): \"\(label.stringValue.prefix(30))\" shows all its lines (\(needed) in \(label.frame.height))")
            frames.append(label.frame)
        }
        if !panel.listedTitles.isEmpty {
            check(panel.listFrame.maxX <= inner.maxX + 0.5 && panel.listFrame.height <= 132.5
                  && (panel.listContentHeight <= panel.listFrame.height + 0.5 || panel.listFrame.height >= 131.5),
                  "\(moment): the list shows every title whole, scrolling past its cap (\(panel.listFrame), \(panel.listContentHeight))")
            frames.append(panel.listFrame)
        }
        for (index, frame) in frames.enumerated() {
            for other in frames[(index + 1)...] where frame.intersects(other) { check(false, "\(moment): parts overlap (\(frame), \(other))") }
        }
        check(panel.fittingHeight(width: panel.bounds.width) <= panel.bounds.height + 0.5,
              "\(moment): the panel is as tall as it needs (\(panel.fittingHeight(width: panel.bounds.width)) in \(panel.bounds.height))")
    }
    private static func click(_ tile: ClipboardTile, _ modifiers: NSEvent.ModifierFlags = []) {
        tile.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
    }
    private static func store(_ texts: [String], seeded: Bool = false) -> (ClipboardStore, NSPasteboard) {
        let board = NSPasteboard.withUniqueName()
        let store = ClipboardStore(pasteboard: board, persistenceURL: nil)
        if seeded { ClipboardDemo.seed(store, board: board) }
        for text in texts { board.clearContents(); board.setString(text, forType: .string); _ = store.saveNow(); store.cancelStaging() }
        return (store, board)
    }
    static func runLoop(_ seconds: TimeInterval = 0.05) {
        RunLoop.current.add(Timer(timeInterval: 0.01, repeats: false) { _ in }, forMode: .default)
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    static func main() {
        _ = NSApplication.shared
        keymapChecks()
        storeChecks()
        bulkChecks()
        windowChecks()
        windowDeletionSafety()
        drawerChecks()
        drawerRungs()
        drawerDeletionSafety()
        tileChecks()
        print("PASS: \(assertions) multi-select assertions; named boards, fixture panels, keys through each container's own path")
    }

    // MARK: Keys

    private static func keymapChecks() {
        let window = ClipboardKeymap.window, drawer = ClipboardKeymap.drawer
        check(window.action(for: key(1, .command, "s")) == .selecting && window.action(for: key(0, [.shift, .command], "a")) == .markAll,
              "the window's ⌘S selects and ⇧⌘A selects all")
        check(window.action(for: key(0, .command, "a")) == nil, "⌘A stays the search's select-all in the window")
        check(window.action(for: key(126, .shift)) == .extendNewer && window.action(for: key(125, .shift)) == .extendOlder,
              "⇧↑ and ⇧↓ extend in the window")
        check(window.action(for: key(123, .shift)) == nil && window.action(for: key(124, .shift)) == nil, "⇧← and ⇧→ stay the search's in the window")
        check(drawer.action(for: key(1, [], "s")) == .selecting && drawer.action(for: key(0, [], "a")) == .markAll, "the drawer's S and A")
        check(drawer.action(for: key(126, .shift)) == .extendNewer && drawer.action(for: key(125, .shift)) == .extendOlder
              && drawer.action(for: key(123, .shift)) == .extendNewer && drawer.action(for: key(124, .shift)) == .extendOlder,
              "⇧ arrows extend in the drawer, the exact chord winning over the plain arrows' any-modifier binding")
        check(drawer.action(for: key(126, [])) == .previousRow && drawer.action(for: key(126, .option)) == .previousRow, "plain and other modified arrows still move")
        check(drawer.action(for: key(8, .command, "c")) == .pickUp, "⌘C picks up in the drawer's cards")
        check(drawer.label(.selecting) == "S" && window.label(.selecting) == "⌘S" && window.spoken(.markAll) == "Shift-Command-A",
              "Select's key is named from the keymap, in each container's words")
        let legend = ClipboardTileTooltip.legendText(.drawer, asker: nil)
        check(legend.contains("Select several ← S or ⌘click") && legend.contains("Select all ← A") && legend.contains("Select up or down ← ⇧↑ ⇧↓"),
              "the card info lists the drawer's selecting keys: \(legend)")
        check(ClipboardBrowserAction.delete.waitsForNextPress && ClipboardBrowserAction.markAll.waitsForNextPress && ClipboardBrowserAction.selecting.waitsForNextPress,
              "🚨 a held delete key waits for a second press, as Select and Select all do: a repeat is never one")
        let fresh = key(51, .command, "\u{7F}")
        check(ClipboardDrawerController.answerable(held(51, .command, "\u{7F}")) == nil && ClipboardDrawerController.answerable(fresh) === fresh,
              "the drawer's delete alert hears a second press of ⌘⌫, never the held first press's repeat")
        check(ClipboardMarkClick(.command) == .toggle && ClipboardMarkClick(.shift) == .range && ClipboardMarkClick([]) == nil
              && ClipboardMarkClick([.command, .shift]) == nil && ClipboardMarkClick(.option) == nil, "only ⌘-click and ⇧-click mark")
    }

    // MARK: Store, paste and bulk helpers

    private static func storeChecks() {
        let (store, board) = store(["Ash", "Beech", "Cedar"])
        defer { store.stop(); board.releaseGlobally() }
        let count = store.entries.count
        check(store.copyText("Ash\nBeech") && store.entries.count == count + 1 && store.entries[0].plainText == "Ash\nBeech"
              && board.string(forType: .string) == "Ash\nBeech", "copied text becomes the newest entry, as any copy does")
        store.cancelStaging()
        check(!store.copyText(""), "empty text copies nothing")
        let before = store.entries.count, top = store.entries[0]
        guard let loan = store.beginPlainTextPaste(lending: "lent words") else { fatalError("FAIL: a lent text begins") }
        check(board.string(forType: .string) == "lent words", "the clipboard is lent the given text")
        _ = store.saveNow()
        check(store.entries.count == before && store.entries[0] === top, "lent text never becomes a history entry")
        store.endPlainTextPaste(loan)
        check(board.string(forType: .string) == "Ash\nBeech", "afterwards what the clipboard held returns")
        let doomed = [store.entries[1], store.entries[3]], kept = [store.entries[0], store.entries[2]]
        check(store.remove(doomed) && store.entries.map(\.id) == kept.map(\.id), "several entries delete together, the rest kept in order")
        check(store.remove(doomed) && store.entries.count == 2, "deleting entries already gone is no error and touches nothing")
    }

    private static func bulkChecks() {
        let (store, board) = store(["One", "Two", "Three"])
        defer { store.stop(); board.releaseGlobally() }
        let shown = store.entries
        check(ClipboardBulkActions.text(shown) == "Three\nTwo\nOne", "the text is each card's, in the order shown, one per line")
        check(ClipboardBulkActions.unavailable(.delete, []) == "Nothing is selected." && ClipboardBulkActions.unavailable(.open, shown) == nil,
              "an action needs something selected")
        var opened: [String] = [], said: [Error] = []
        ClipboardBulkActions.open(shown, with: { entry, done in
            opened.append(entry.title)
            done(entry.title == "Two" ? nil : NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "no viewer"]))
        }, failed: { said.append($0) })
        let words = said.first?.localizedDescription ?? ""
        check(opened == ["Three", "Two", "One"] && said.count == 1, "Open in Preview opens each, in order, and says every failure once (\(said.count))")
        check(words.hasPrefix("2 of the 3 selected items could not be opened in Preview.") && words.contains("Three: no viewer") && words.contains("One: no viewer"),
              "the one alert names each item that failed and why: \(words)")
        said = []
        ClipboardBulkActions.open(shown, with: { _, done in done(nil) }, failed: { said.append($0) })
        check(said.isEmpty, "with nothing failing, nothing is said")

        // Whether a card has text, answered without reading an HTML-only copy in full, agrees with
        // the text a plain paste inserts, for every kind of copy; the panel's reasons read it once.
        func make(_ values: [(type: NSPasteboard.PasteboardType, data: Data)]) -> ClipboardEntry {
            let payloads = [ClipboardPayload(values: values)], summary = ClipboardSummary.make(from: payloads)
            return ClipboardEntry(fingerprint: UUID().uuidString, capturedAt: Date(), payloads: payloads, title: summary.title,
                                  detail: summary.detail, kind: summary.kind, thumbnail: summary.thumbnail)
        }
        let longHTML = make(ClipboardWebCopies.html("<p>" + String(repeating: "word ", count: 450_000) + "</p>"))
        guard case .html(let cut) = longHTML.kind, !cut.isComplete else { fatalError("FAIL: the long HTML copy is read in part") }
        let samples = [make([(.string, Data("words".utf8))]), make(ClipboardWebCopies.html(ClipboardWebCopies.plainHTML)), longHTML,
                       make(ClipboardWebCopies.figma()), make(ClipboardWebCopies.appDataOnly), make(ClipboardWebCopies.bookkeepingOnly),
                       make([(.png, ClipboardWebCopies.picture.png)]), make(ClipboardWebCopies.rtf("rich words"))]
        for sample in samples {
            check(sample.hasPlainTextForPaste == !sample.plainTextForPaste.isEmpty, "has text agrees with the text pasted for \(sample.title)")
        }
        let reasons = ClipboardBulkActions.reasons(ClipboardSelectionPanel.catalog, samples)
        check(ClipboardSelectionPanel.catalog.allSatisfy { reasons[$0] == ClipboardBulkActions.unavailable($0, samples) },
              "the panel's reasons, read once, are each action's own")
        check(ClipboardBulkActions.reasons(ClipboardSelectionPanel.catalog, []).values.allSatisfy { $0 == "Nothing is selected." }, "with nothing marked, nothing can act")
    }

    // MARK: The window

    private struct Window {
        let store: ClipboardStore, board: NSPasteboard, history: ClipboardHistoryController, panel: TestPanel
        var posted: [pid_t] = [], scheduled: [() -> Void] = [], opened: [UUID] = [], errors: [String] = []
    }

    private static func windowChecks() {
        let (store, board) = store(["Alder", "Birch", "Cedar", "Dogwood", "Elm", "Fir"], seeded: true)
        defer { store.stop(); board.releaseGlobally() }
        var posted: [pid_t] = [], scheduled: [() -> Void] = [], opened: [UUID] = [], errors: [String] = []
        var environment = ClipboardPaster.Environment()
        environment.frontmost = { 500 }
        environment.postPaste = { posted.append($0); return true }
        environment.schedule = { _, action in scheduled.append(action) }
        let panel = TestPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 470), styleMask: [], backing: .buffered, defer: true)
        let history = ClipboardHistoryController(store: store, paster: ClipboardPaster(store: store, environment: environment),
                                                 previewService: ClipboardPreviewService(), panel: panel)
        var target: ClipboardPaster.Target? = ClipboardPaster.Target(pid: 500) {}
        history.prepare = { target }
        history.openInPreview = { entry, done in opened.append(entry.id); done(nil) }
        history.onError = { errors.append($0.localizedDescription) }
        let (asker, vaultRoot) = makeAsker(board)
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        let view = history.view, list = view.list, rows = view.canvas, actions = view.selectionPanel
        @discardableResult func press(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = [], _ characters: String = "") -> Bool {
            history.handleKey(key(code, modifiers, characters))
        }
        func type(_ query: String) { view.search.stringValue = query; view.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification)) }
        func titles() -> [String] { actions.shownButtons.map(\.title) }

        history.hotKeyPressed()
        check(!list.marking.isOn && view.selectButton.keyedTitle.plain == "Select ⌘S" && !view.selectButton.isHidden, "the window opens with Select ⌘S, marking off")
        check(view.selectButton.refusesFirstResponder && view.selectButton.frame.maxX == view.search.frame.maxX
              && list.countLine.count.frame.maxX <= view.selectButton.frame.minX && !view.selectButton.frame.intersects(view.search.frame),
              "Select ends the count line's row under the search and leaves the keyboard in it")
        let count = list.countLine.count
        count.stringValue = "50 of 50 items · Some image text is unavailable"
        view.needsLayout = true; view.layoutSubtreeIfNeeded()
        check(count.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: count.frame.width, height: 1_000)).height <= count.frame.height
              && count.frame.maxY <= rows.enclosingScrollView!.frame.minY && count.frame.minY >= view.search.frame.maxY
              && count.frame.maxX <= view.selectButton.frame.minX,
              "the longest count line wraps beside Select rather than being cut short (\(count.frame))")
        view.update(entries: store.entries)
        check(press(1, .command, "s") && list.marking == .on(marked: [], anchor: nil), "⌘S turns marking on with nothing marked")
        check(view.selectButton.keyedTitle.plain == "Done ⌘S" && view.selectButton.accessibilityLabel() == "Done, Command-S", "Select reads Done, the same key")
        check(rows.tiles.allSatisfy { $0.showsCircle && $0.accessibilityValue() as? String == "not selected" }, "every row shows its circle and says it is not selected")
        check(view.showsCard && actions.isHidden, "with nothing marked, the card shows as usual")
        check(view.footer.items.isEmpty && view.footer.hintText == "⏎ or click selects  ·  ⇧⌘A all",
              "the footer says how to select, and nothing about Esc: \(view.footer.hintText)")
        let first = rows.tiles[0].entry, third = rows.tiles[2].entry, entriesBefore = store.entries.count
        check(press(36) && list.marking.marked == [first.id] && store.entries.count == entriesBefore && posted.isEmpty && history.isVisible,
              "Return marks the chosen row instead of pasting")
        check(!actions.isHidden && !view.showsCard && actions.headingText == "1 selected" && rows.tiles[0].accessibilityValue() as? String == "selected",
              "the selection's actions take the card's place, and the row says it is selected")
        check(titles() == ["Copy as text ⌘C", "Paste as text ⌃⌘⏎", "Open in Preview ⌘O", "Delete 1… ⌘⌫", "Select all ⇧⌘A"],
              "the window's actions, each with its key: \(titles())")
        check(actions.shownButtons.allSatisfy { $0.enabled } && actions.subviews.compactMap { $0 as? NSButton }.allSatisfy(\.refusesFirstResponder),
              "every action can act, and none takes the keyboard from the search")
        check(actions.listedTitles == "• \(first.title)", "the panel names what is marked, whole: \(actions.listedTitles)")
        check(rows.tiles[0].toolTip == rows.tiles[0].tooltipText && rows.tiles[1].toolTip == rows.tiles[1].tooltipText,
              "while marking, pointing at a row names it whole, the card that would show it being taken")
        expectLaidOut(actions, "the window's panel")
        let side = view.flip.frame
        check(actions.frame.minX >= side.minX && actions.frame.maxX <= side.maxX && actions.frame.minY >= side.minY && actions.frame.height > 60,
              "the panel sits in the card's place beside the list (\(actions.frame) in \(side))")
        rows.tiles[2].onPick?()
        check(list.marking.marked == [first.id, third.id] && actions.headingText == "2 selected", "a click on a row marks it too, in the list's order")
        rows.tiles[2].onPick?()
        check(list.marking.marked == [first.id], "a second click unmarks it")
        click(rows.tiles[3], .shift)
        check(list.marking.marked == [0, 2, 3].map { rows.tiles[$0].entry.id }, "⇧-click marks the range from the anchor (the row clicked last), keeping the rest")
        click(rows.tiles[2], .command)
        check(list.marking.marked == [0, 3].map { rows.tiles[$0].entry.id } && rows.selected === rows.tiles[2], "⌘-click unmarks one, choosing it")
        history.previewAsker = asker
        check(press(48) && !history.isSending && press(0, [.option, .command], "a") && !history.isAsking, "Tab and ⌥⌘A do nothing for a set, a maintainer copy's too")
        history.previewAsker = nil
        check(press(53) && !list.marking.isOn && rows.tiles.allSatisfy { !$0.showsCircle && $0.accessibilityValue() == nil && $0.toolTip == $0.tooltipText } && view.showsCard,
              "Esc ends selecting, every mark let go, the card back")
        check(view.footer.items.count == 7 && !view.footer.hintText.lowercased().contains("esc"), "the footer's actions come back")

        // ⌘-click from browsing turns marking on; ⇧↓ marks the chosen row and the next, choosing it.
        click(rows.tiles[4], .command)
        check(list.marking == .on(marked: [rows.tiles[4].entry.id], anchor: rows.tiles[4].entry.id), "⌘-click with marking off turns it on and marks that row")
        check(press(125, .shift) && list.marking.marked == rows.tiles[4...5].map(\.entry.id) && rows.selected === rows.tiles[5], "⇧↓ marks the next row and chooses it")
        check(press(126, .shift) && press(126, .shift) && list.marking.marked == rows.tiles[3...5].map(\.entry.id) && rows.selected === rows.tiles[3],
              "⇧↑ goes back, keeping the marks and adding the newer row")
        check(press(0, [.shift, .command], "a") && list.marking.marked.count == rows.tiles.count && titles().last == "Select none ⇧⌘A", "⇧⌘A marks every row shown")
        check(actions.listedTitles.components(separatedBy: "\n").count == rows.tiles.count, "the panel names every one of them")
        view.layoutSubtreeIfNeeded()
        expectLaidOut(actions, "the window's panel, every row marked")
        check(actions.frame.maxY <= view.flip.frame.maxY + 0.5, "and fits the card's place, its list scrolling (\(actions.frame) in \(view.flip.frame))")
        check(history.handleKey(held(0, [.shift, .command], "a")) && list.marking.marked.count == rows.tiles.count, "⇧⌘A held down does not let go of them again")
        check(press(0, [.shift, .command], "a") && list.marking.marked.isEmpty && list.marking.isOn && actions.isHidden, "and again unmarks them all, circles still showing")
        press(1, .command, "s")
        check(!list.marking.isOn, "Done turns marking off")

        // Copy as text: the marked rows' text, in the order shown, one copy; the window closes.
        press(1, .command, "s")
        rows.tiles[2].onPick?(); rows.tiles[0].onPick?()
        let marked = [rows.tiles[0].entry, rows.tiles[2].entry]
        check(press(8, .command, "c") && !history.isVisible, "⌘C with rows marked closes the window, as its ⌘C does")
        check(store.entries[0].plainText == "\(marked[0].plainTextForPaste)\n\(marked[1].plainTextForPaste)", "and copies their text, newest first, one per line")
        store.cancelStaging()
        history.hotKeyPressed()
        check(!list.marking.isOn && rows.tiles.allSatisfy { !$0.showsCircle }, "every opening starts with marking off")

        // Paste as text: lent for one paste into the app the window opened over.
        press(1, .command, "s"); press(36); press(125); press(36)
        let pasted = list.markedEntries
        let countBefore = store.entries.count
        check(press(36, [.control, .command]) && !history.isVisible, "⌃⌘⏎ with rows marked closes the window")
        scheduled.removeFirst()()
        check(posted == [500] && board.string(forType: .string) == ClipboardBulkActions.text(pasted), "and pastes their text there")
        while !scheduled.isEmpty { scheduled.removeFirst()() }
        check(store.entries.count == countBefore && board.string(forType: .string) != ClipboardBulkActions.text(pasted), "the pasted text never joins the history; the clipboard returns")
        target = nil
        history.hotKeyPressed(); press(1, .command, "s"); press(36)
        let paste = actions.shownButtons.first { $0.action == .plainPaste }!
        check(!paste.enabled && paste.help.hasPrefix("There is no app to paste into"), "with no app to paste into, Paste as text is dimmed and says why")
        check(press(36, [.control, .command]) && history.isVisible && list.marking.isOn, "and its key does nothing but beep")
        target = ClipboardPaster.Target(pid: 500) {}

        // Open in Preview: each, from the panel's button as from ⌘O.
        press(125); press(36)
        let toOpen = list.markedEntries.map(\.id)
        actions.button(.open)?.performClick(nil)
        check(opened == toOpen && !history.isVisible && errors.isEmpty, "Open in Preview opens each marked row and closes the window")

        // ⌘S held down does not flicker.
        history.hotKeyPressed()
        let heldS = held(1, .command, "s")
        press(1, .command, "s")
        check(history.handleKey(heldS) && list.marking.isOn && view.selectButton.keyedTitle.plain == "Done ⌘S", "⌘S held down: its repeat does not turn marking off")
        check(history.handleKey(heldS) && list.marking.isOn, "nor does the next one")
        press(1, .command, "s")
        history.close()

        // The panel's buttons answer as their keys do; Select toggles from its click too.
        history.hotKeyPressed()
        view.selectButton.performClick(nil)
        check(list.marking.isOn, "a click on Select turns marking on")
        press(36)
        actions.button(.markAll)?.performClick(nil)
        check(list.marking.marked.count == rows.tiles.count, "Select all marks every row")
        view.selectButton.performClick(nil)
        check(!list.marking.isOn && view.showsCard, "a click on Done ends it")

        // While a search hides a marked row, its mark goes; the actions act only on rows shown.
        press(1, .command, "s"); press(0, [.shift, .command], "a")
        type("birch")
        check(list.marking.marked == rows.tiles.map(\.entry.id) && rows.tiles.count == 1, "a search lets go of the marks it hides")
        type("")
        check(list.marking.marked.count == 1, "and clearing it does not bring them back")

        // ⌥⌘A with a maintainer's asker: nothing for a set, the form for the chosen row once marking is off.
        history.previewAsker = asker
        check(list.marking.isOn && press(0, [.option, .command], "a") && !history.isAsking, "with rows marked, ⌥⌘A asks nothing")
        list.endMarking()
        check(press(0, [.option, .command], "a") && history.isAsking, "with marking off, it asks about the chosen row, as ever")
        history.close()
        history.previewAsker = nil
    }

    /// 🚨 The window's delete: the first ⌘⌫ asks in the panel's heading and deletes nothing; a second
    /// deletes exactly the rows it asked about, only if they are still marked, shown and in the history.
    private static func windowDeletionSafety() {
        let (store, board) = store(["Alder", "Birch", "Cedar", "Dogwood", "Elm", "Fir", "Gum"], seeded: true)
        defer { store.stop(); board.releaseGlobally() }
        let panel = TestPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 470), styleMask: [], backing: .buffered, defer: true)
        let history = ClipboardHistoryController(store: store, paster: ClipboardPaster(store: store, environment: .inert),
                                                 previewService: ClipboardPreviewService(), panel: panel)
        history.prepare = { nil }
        let view = history.view, list = view.list, rows = view.canvas, actions = view.selectionPanel
        @discardableResult func press(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = [], _ characters: String = "") -> Bool {
            history.handleKey(key(code, modifiers, characters))
        }
        func type(_ query: String) { view.search.stringValue = query; view.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification)) }
        func ids() -> Set<UUID> { Set(store.entries.map(\.id)) }
        func mark(_ indices: [Int]) {
            if !list.marking.isOn { press(1, .command, "s") }
            for index in indices { rows.tiles[index].onPick?() }
        }

        history.hotKeyPressed()
        press(1, .command, "s")
        let total = ids()
        check(press(51, .command) && ids() == total && !history.isAskingToDeleteMarks, "with nothing marked, ⌘⌫ deletes nothing and asks nothing, even the chosen row")
        mark([1, 3])
        let doomed = list.markedEntries, next = rows.tiles[2].entry
        check(press(51, .command) && ids() == total && history.isAskingToDeleteMarks, "the first ⌘⌫ deletes nothing")
        check(history.handleKey(held(51, .command)) && history.handleKey(held(51, .command)) && ids() == total && history.isAskingToDeleteMarks,
              "🚨 ⌘⌫ held down deletes nothing: its repeats are not a second press, and the question stays")
        expectLaidOut(actions, "the window's panel asking")
        check(actions.headingText == "Delete 2 items permanently?" && actions.detailText == ClipboardDeletion.marked(count: 2).consequence
              && actions.keysText == "⌘⌫ again deletes" && actions.surface.rim == .systemRed,
              "it asks in the panel's heading, in red, with the consequence and its keys")
        check(actions.accessibilityLabel()?.hasSuffix("Command-Delete again deletes") == true, "VoiceOver hears the question and its keys in words")
        check(!view.footer.hintText.lowercased().contains("esc"), "the footer explains no Esc; the question beside the marks names its keys")
        press(53)
        check(!history.isAskingToDeleteMarks && list.marking.marked == doomed.map(\.id) && actions.headingText == "2 selected" && ids() == total,
              "Esc keeps them, still marked")
        press(51, .command); press(0, [], "x")
        check(!history.isAskingToDeleteMarks && ids() == total, "typing keeps them too")
        type("")
        press(51, .command); press(51, .command)
        check(ids() == total.subtracting(doomed.map(\.id)), "a second ⌘⌫ deletes exactly the marked rows")
        check(!list.marking.isOn && rows.selected?.entry === next && view.showsCard, "marking ends, and the row that moved into the first one's place is chosen")

        // A search between the presses: a marked row it hides is never deleted.
        let before = ids()
        mark([0, 1])
        let shownMark = rows.tiles[0].entry, hiddenMark = rows.tiles[1].entry
        press(51, .command)
        check(history.isAskingToDeleteMarks, "asking about two rows")
        type(shownMark.title)
        check(!history.isAskingToDeleteMarks && list.marking.marked == [shownMark.id], "a search that hides one lets go of the question and of the hidden mark")
        press(51, .command)
        check(ids() == before && history.isAskingToDeleteMarks && actions.headingText == "Delete 1 item permanently?", "so the next ⌘⌫ only asks again, about the one shown")
        press(51, .command)
        check(ids() == before.subtracting([shownMark.id]) && store.entries.contains { $0 === hiddenMark }, "and the next deletes it alone, never the hidden one")
        type("")

        // A tab between the presses.
        let afterSearch = ids()
        mark([0])
        press(51, .command)
        view.tabs.selectedSegment = ClipboardBrowserTab.images.rawValue
        view.tabs.sendAction(view.tabs.action!, to: view.tabs.target)
        check(!history.isAskingToDeleteMarks && list.marking.marked.isEmpty && list.marking.isOn, "a tab that hides the marked row lets go of it and the question")
        check(press(51, .command) && ids() == afterSearch && !history.isAskingToDeleteMarks, "and ⌘⌫ there deletes nothing (no marks), not the chosen picture")
        press(29, .command, "0")

        // An entry leaving the history between the presses.
        mark([0, 1, 2])
        let asked = list.markedEntries
        press(51, .command)
        _ = store.remove(asked[1])
        check(!history.isAskingToDeleteMarks && list.marking.marked == [asked[0].id, asked[2].id], "an entry leaving the history lets go of its mark and the question")
        press(51, .command)
        check(store.entries.contains { $0 === asked[0] } && store.entries.contains { $0 === asked[2] }, "so the next ⌘⌫ only asks again")
        press(51, .command)
        check(!store.entries.contains { $0 === asked[0] } && !store.entries.contains { $0 === asked[2] }, "and the one after deletes the two still marked")

        // Changing the marks between the presses, by click or key.
        mark([0, 1])
        press(51, .command)
        rows.tiles[2].onPick?()
        check(!history.isAskingToDeleteMarks, "marking another row lets go of the question")
        let kept = ids()
        press(51, .command); press(125, .shift)
        check(!history.isAskingToDeleteMarks && ids() == kept, "so does ⇧↓")

        // The panel's Delete button: twice, as the key.
        let toDelete = list.markedEntries.map(\.id)
        actions.button(.delete)?.performClick(nil)
        check(history.isAskingToDeleteMarks && ids() == kept, "Delete N… asks first")
        actions.button(.delete)?.performClick(nil)
        check(ids() == kept.subtracting(toDelete), "and its second click deletes them")

        // A row's own waiting delete lets go once marking starts.
        press(1, .command, "s"); press(1, .command, "s")
        let armedRow = rows.selected!.entry
        press(51, .command)
        check(rows.armedID == armedRow.id, "outside marking, ⌘⌫ arms the row as before")
        check(history.handleKey(held(51, .command)) && rows.armedID == armedRow.id && store.entries.contains { $0 === armedRow },
              "🚨 and a held ⌘⌫ never deletes the row it asks about")
        click(rows.tiles[0], .command)
        check(rows.armedID == nil && store.entries.contains { $0 === armedRow }, "a ⌘-click that starts marking lets go of the row's question")
        press(53); press(53)
        history.close()
    }

    // MARK: The drawer

    private static func drawerChecks() {
        let (store, board) = store(["Alder", "Birch", "Cedar", "Dogwood"], seeded: true)
        defer { store.stop(); board.releaseGlobally() }
        let magnetPanel = TestPanel(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        let magnet = ClipboardMagnetController(panel: magnetPanel, commandClickEnabled: false)
        let drawerPanel = TestPanel(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        let selectionPanel = KeyRecordingPanel(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        let askPopover = ClipboardPreviewAskPopover(panel: TestPanel(contentRect: .zero, styleMask: [], backing: .buffered, defer: true))
        let drawer = ClipboardDrawerController(store: store, magnetController: magnet, panel: drawerPanel, defaults: nil,
                                               askPopover: askPopover, selectionPanel: selectionPanel)
        defer { drawer.stop() }
        let (asker, vaultRoot) = makeAsker(board)
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        let browser = drawer.browser, list = browser.list, cards = browser.canvas, popover = drawer.selectionPopover, actions = popover.view
        var moved = 0.0
        cards.pointer = { moved += 1; return NSPoint(x: moved, y: 0) }
        drawer.show(on: NSScreen.main!)
        drawerPanel.makeFirstResponder(cards)
        func press(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = [], _ characters: String = "") {
            let event = key(code, modifiers, characters)
            if !drawer.handleDrawerKey(event) { cards.keyDown(with: event) }
        }
        check(browser.selectButton.keyedTitle.plain == "Select S" && browser.selectButton.frame.minX > browser.tabs.frame.maxX
              && abs(browser.selectButton.frame.maxX - (browser.bounds.width - 16)) < 1 && !browser.selectButton.refusesFirstResponder,
              "Select sits at the right of the tabs, where Clear… was, as a Tab stop")
        check(browser.tabs.fittingSize.width <= browser.tabs.frame.width, "every tab still fits whole beside Select")
        check(browser.tabs.nextKeyView === browser.selectButton && browser.selectButton.nextKeyView === drawer.header.settingsButton,
              "Tab goes tabs, Select, gear")
        let chosen = cards.selected!
        check(!chosen.subviews.compactMap { $0 as? NSButton }.allSatisfy(\.isHidden), "the chosen card shows its × and eye")
        press(1, [], "s")
        check(list.marking.isOn && browser.selectButton.keyedTitle.plain == "Done S" && drawerPanel.firstResponder === cards, "S turns marking on; the cards keep the keyboard")
        check(cards.tiles.allSatisfy(\.showsCircle) && chosen.subviews.compactMap { $0 as? NSButton }.allSatisfy(\.isHidden), "every card shows its circle; × and eye hide")
        check(!popover.isVisible, "with nothing marked, no panel")
        let held = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                    characters: "s", charactersIgnoringModifiers: "s", isARepeat: true, keyCode: 1)!
        cards.keyDown(with: held)
        check(list.marking.isOn && browser.selectButton.keyedTitle.plain == "Done S", "S held down: its repeat does not turn marking off")
        cards.keyDown(with: held)
        check(list.marking.isOn, "nor does the next one")
        press(36)
        check(list.marking.marked == [chosen.entry.id] && store.stagedEntryID == nil, "Return marks the chosen card instead of picking it up")
        check(popover.isVisible && actions.headingText == "1 selected" && !selectionPanel.tookKeyboard && drawerPanel.firstResponder === cards,
              "the panel shows beside the drawer, never taking the keyboard")
        check(actions.shownButtons.map(\.title) == ["Copy as text ⌘C", "Open in Preview ⌘O", "Delete 1… ⌫ or ⌘⌫", "Select all A"],
              "the drawer's actions are those its keymap has keys for: \(actions.shownButtons.map(\.title))")
        check(actions.listedTitles == "• \(chosen.entry.title)" && cards.tiles[1].toolTip == cards.tiles[1].entry.title,
              "it names what is marked, and pointing at a card names it whole")
        expectLaidOut(actions, "the drawer's panel")
        let body = drawer.bodyFrame!, frame = popover.frame, tab = drawer.tabFrame ?? .zero
        check(!frame.intersects(body) && !frame.intersects(tab) && NSScreen.main!.visibleFrame.contains(frame)
              && (frame.maxX <= body.minX || frame.minX >= body.maxX || frame.maxY <= body.minY),
              "it sits outside the drawer and its tab, inside the display (\(frame) beside \(body))")
        let select = browser.selectButton, selectTop = drawerPanel.convertToScreen(select.convert(select.bounds, to: nil)).maxY
        check(abs(frame.maxY - min(selectTop, NSScreen.main!.visibleFrame.maxY - 8)) <= 1, "its top is level with Select's, where the display allows (\(frame.maxY), \(selectTop))")
        check(drawer.contains(NSPoint(x: frame.midX, y: frame.midY)) && ClipboardTileTooltip.shared.isRoomTaken(), "it counts as inside the drawer, and card info waits for it")
        press(125, .shift)
        check(list.marking.marked.count == 2 && cards.selected === cards.tiles[1] && actions.headingText == "2 selected", "⇧↓ marks the next card; the panel follows")
        press(48)
        check(!drawer.sendToPopover.isVisible, "Tab (Send to) does nothing for a set")
        drawer.previewAsker = asker
        check(drawer.handleDrawerKey(key(0, [.option, .command], "a")) && !askPopover.isVisible, "nor does ⌥⌘A, a maintainer copy's included")
        drawer.previewAsker = nil

        // Quick Look's drawer magnet takes that room; the panel returns once it closes.
        press(49)
        check(magnet.drawerAnchor != nil && !popover.isVisible, "Space still previews, and the panel gives way to Quick Look")
        press(49)
        for _ in 0..<20 where magnet.drawerAnchor != nil { runLoop() }
        check(magnet.drawerAnchor == nil && popover.isVisible, "and comes back when Quick Look closes")

        // Copy as text: one copy, marking ends, the drawer stays.
        let marked = list.markedEntries
        actions.button(.pickUp)?.performClick(nil)
        check(store.entries[0].plainText == ClipboardBulkActions.text(marked) && !list.marking.isOn && !popover.isVisible && drawer.isVisible,
              "Copy as text puts their text on the clipboard as one copy, ends marking and keeps the drawer open")
        store.cancelStaging()

        // Open in Preview: each marked card, in the order shown, from the panel's button as from ⌘O, its
        // failures said once, together.
        var opened: [UUID] = [], said: [String] = [], failing = false
        drawer.openInPreview = { entry, done in
            opened.append(entry.id)
            done(failing ? NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "no viewer"]) : nil)
        }
        drawer.onError = { said.append($0.localizedDescription) }
        press(1, [], "s"); press(36); press(125, .shift)
        let toOpen = list.markedEntries.map(\.id)
        actions.button(.open)?.performClick(nil)
        check(toOpen.count == 2 && opened == toOpen && said.isEmpty && list.marking.isOn && drawer.isVisible,
              "Open in Preview opens each marked card, in the order shown, the drawer staying")
        opened = []
        failing = true
        press(31, .command, "o")
        check(opened == toOpen && said.count == 1 && said[0].hasPrefix("2 of the 2 selected items could not be opened in Preview."),
              "⌘O does the same, its failures said once: \(said)")
        press(1, [], "s")

        // The Images grid: circles over the pictures, ⇧→ across it, A for every one.
        let images = ClipboardBrowserTab.images.rawValue
        browser.tabs.selectedSegment = images
        browser.tabs.sendAction(browser.tabs.action!, to: browser.tabs.target)
        drawerPanel.makeFirstResponder(cards)
        press(1, [], "s")
        check(cards.tiles.allSatisfy { $0.showsCircle && $0.circleFrame == NSRect(x: 6, y: 6, width: 18, height: 18) },
              "image tiles show their circle 6 points in from the top-left corner")
        press(124, .shift)
        check(list.marking.marked == cards.tiles[0...1].map(\.entry.id), "⇧→ marks across the Images grid, as → steps")
        press(0, [], "a")
        check(list.marking.marked.count == cards.tiles.count, "A marks every image")

        // In the search, S and A are typing.
        list.focusSearch(selectingAll: false)
        check(!drawer.handleDrawerKey(key(1, [], "s")) && !drawer.handleDrawerKey(key(0, [], "a")) && list.marking.marked.count == cards.tiles.count,
              "with the keyboard in the search, S and A pass on to it as letters")
        drawerPanel.makeFirstResponder(cards)

        // Esc's rungs: marking, then the search, then the drawer.
        browser.search.stringValue = "x"
        press(53)
        check(!list.marking.isOn && drawer.isVisible && browser.search.stringValue == "x", "Esc ends marking first")
        press(53)
        check(browser.search.stringValue.isEmpty && drawer.isVisible, "then empties the search")
        press(1, [], "s"); press(36)
        check(popover.isVisible, "marked again")
        drawer.hide(animated: false)
        check(!popover.isVisible, "closing the drawer closes the panel")
        drawer.show(on: NSScreen.main!)
        check(!list.marking.isOn && !popover.isVisible, "and every opening starts with marking off")
        drawer.hide(animated: false)
    }

    /// The drawer's selection panel goes with the last mark, by Return or by A, marking staying on; Esc
    /// lets go of a held item (Quick Look's) before it ends marking, and the panel comes back as Quick Look goes.
    private static func drawerRungs() {
        let (store, board) = store(["Alder", "Birch", "Cedar"])
        defer { store.stop(); board.releaseGlobally() }
        let magnet = ClipboardMagnetController(panel: TestPanel(contentRect: .zero, styleMask: [], backing: .buffered, defer: true), commandClickEnabled: false)
        let drawerPanel = TestPanel(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        let drawer = ClipboardDrawerController(store: store, magnetController: magnet, panel: drawerPanel, defaults: nil,
                                               selectionPanel: KeyRecordingPanel(contentRect: .zero, styleMask: [], backing: .buffered, defer: true))
        defer { drawer.stop() }
        let list = drawer.browser.list, cards = drawer.browser.canvas, popover = drawer.selectionPopover
        var moved = 0.0
        cards.pointer = { moved += 1; return NSPoint(x: moved, y: 0) }
        drawer.show(on: NSScreen.main!)
        drawerPanel.makeFirstResponder(cards)
        func press(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = [], _ characters: String = "") {
            let event = key(code, modifiers, characters)
            if !drawer.handleDrawerKey(event) { cards.keyDown(with: event) }
        }

        press(1, [], "s"); press(36)
        check(popover.isVisible && list.marking.marked.count == 1, "one card marked: the panel shows")
        press(36)
        check(list.marking.isOn && list.marking.marked.isEmpty && !popover.isVisible, "letting go of the last mark closes it, marking staying on")
        press(0, [], "a")
        check(popover.isVisible && list.marking.marked.count == cards.tiles.count, "A marks every card: it shows")
        press(0, [], "a")
        check(list.marking.isOn && list.marking.marked.isEmpty && !popover.isVisible, "A again lets go of them all: it closes")

        // Esc's rungs with Quick Look holding an item: the item first, the marks kept.
        press(36); press(125, .shift)
        let marks = list.marking.marked
        press(49)
        check(magnet.drawerAnchor != nil && store.stagedEntryID != nil && !popover.isVisible, "Space previews, the panel out of Quick Look's way")
        press(53)
        check(store.stagedEntryID == nil && list.marking.isOn && list.marking.marked == marks, "Esc lets go of the held item first, every mark kept")
        for _ in 0..<20 where magnet.drawerAnchor != nil { runLoop() }
        check(magnet.drawerAnchor == nil && popover.isVisible && popover.view.headingText == "2 selected", "and the panel comes back as Quick Look goes")
        press(53)
        check(!list.marking.isOn && !popover.isVisible && drawer.isVisible, "the next Esc ends marking, closing the panel")
        drawer.hide(animated: false)
    }

    /// 🚨 The drawer's delete asks in its alert, with the count, and removes only cards still marked,
    /// still shown and still in the history once the alert is answered.
    private static func drawerDeletionSafety() {
        let (store, board) = store(["Alder", "Birch", "Cedar", "Dogwood", "Elm", "Fir"])
        defer { store.stop(); board.releaseGlobally() }
        let magnet = ClipboardMagnetController(panel: TestPanel(contentRect: .zero, styleMask: [], backing: .buffered, defer: true), commandClickEnabled: false)
        let drawerPanel = TestPanel(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        let drawer = ClipboardDrawerController(store: store, magnetController: magnet, panel: drawerPanel, defaults: nil)
        defer { drawer.stop() }
        let list = drawer.browser.list, cards = drawer.browser.canvas
        drawer.show(on: NSScreen.main!)
        drawerPanel.makeFirstResponder(cards)
        func press(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = [], _ characters: String = "") {
            let event = key(code, modifiers, characters)
            if !drawer.handleDrawerKey(event) { cards.keyDown(with: event) }
        }
        func ids() -> Set<UUID> { Set(store.entries.map(\.id)) }
        var questions: [(String, String)] = [], answer = false, meanwhile: () -> Void = {}
        drawer.confirmDeletion = { question, detail in questions.append((question, detail)); meanwhile(); return answer }

        press(1, [], "s")
        let total = ids()
        press(51)
        check(questions.isEmpty && ids() == total, "with nothing marked, ⌫ asks nothing and deletes nothing, not even the chosen card")
        press(36); press(125, .shift)
        let doomed = list.markedEntries
        press(51)
        check(questions.last?.0 == "Delete 2 items permanently?" && questions.last?.1.hasPrefix(ClipboardDeletion.marked(count: 2).consequence) == true
              && questions.last?.1.hasSuffix("⌘⌫ again deletes") == true, "the alert asks about the marked cards with their count and keys")
        check(ids() == total && list.marking.marked == doomed.map(\.id), "Cancel keeps them, still marked")
        answer = true
        let after = cards.tiles[2].entry
        press(51, .command)
        check(ids() == total.subtracting(doomed.map(\.id)) && !list.marking.isOn && cards.selected?.entry === after,
              "Delete Permanently deletes exactly them, ends marking, and chooses the card in the first one's place")

        // While the alert waits, one marked card leaves the history and a search hides another.
        press(1, [], "s"); press(0, [], "a")
        let marked = list.markedEntries
        meanwhile = {
            _ = store.remove(marked[0])
            drawer.browser.search.stringValue = marked[1].title
            drawer.browser.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        }
        check(marked.count == 4, "four cards marked")
        press(51)
        check(questions.last?.0 == "Delete 4 items permanently?", "asked about every marked card")
        check(store.entries.map(\.id) == [marked[2].id, marked[3].id],
              "only the card still marked and shown is deleted; the two the search hid stay (\(store.entries.map(\.title)))")
        drawer.hide(animated: false)
    }

    // MARK: The circles and their slide

    private static func tileChecks() {
        check(ClipboardTile.markSlide(onScreen: true, reduceMotion: false) == 0.2 && ClipboardTile.markSlide(onScreen: true, reduceMotion: true) == nil
              && ClipboardTile.markSlide(onScreen: false, reduceMotion: false) == nil, "the slide takes 0.2 s on screen, and none with Reduce Motion or off screen")
        let browser = ClipboardBrowserView(frame: NSRect(x: 0, y: 0, width: 390, height: 600))
        let host = TestPanel(contentRect: browser.frame, styleMask: [], backing: .buffered, defer: false)
        host.contentView = browser
        let entries = ["Ash", "Beech"].map { title in
            ClipboardEntry(fingerprint: title, capturedAt: Date(timeIntervalSince1970: 1_780_000_000),
                           payloads: [ClipboardPayload(values: [(.string, Data(title.utf8))])], title: title, detail: "Fixture", kind: .text, thumbnail: nil)
        }
        browser.update(entries: entries, attachedID: nil)
        let row = browser.canvas.tiles[0], frames = browser.canvas.tiles.map(\.frame)
        host.makeKeyAndOrderFront(nil)
        ClipboardTile.reduceMotion = { true }
        _ = browser.list.answer(.selecting, on: nil)
        check(row.showsCircle && row.markReveal == 1, "with Reduce Motion the circle shows at once, no slide")
        _ = browser.list.answer(.selecting, on: nil)
        check(!row.showsCircle && row.markReveal == 0, "and goes at once")
        ClipboardTile.reduceMotion = { false }
        _ = browser.list.answer(.selecting, on: nil)
        check(row.showsCircle && row.markReveal < 1 && (row.animation(forKey: "markReveal") as? CABasicAnimation) != nil,
              "on screen it slides, through the drawn offset's animation (\(row.markReveal) at the start)")
        for _ in 0..<12 where row.markReveal < 1 { runLoop() }
        check(row.markReveal == 1, "and arrives (\(row.markReveal))")
        check(browser.canvas.tiles.map(\.frame) == frames, "no card moves: the slide is drawn, not laid out")
        ClipboardTile.reduceMotion = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        check(row.circleFrame == NSRect(x: 11, y: 35, width: 18, height: 18), "a row's circle sits in its gutter, centred on it")

        // Painted: an unmarked ring on the card's ground; marked, the accent with a white check.
        func pixel(_ tile: ClipboardTile, at point: NSPoint) -> NSColor? {
            let rep = tile.bitmapImageRepForCachingDisplay(in: tile.bounds)!
            tile.cacheDisplay(in: tile.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / tile.bounds.width
            return rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.sRGB)
        }
        func distance(_ a: NSColor?, _ b: NSColor) -> CGFloat {
            guard let a, let b = b.usingColorSpace(.sRGB) else { return .infinity }
            return max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent), abs(a.blueComponent - b.blueComponent))
        }
        // A bitmap's color space shifts a color a little; each pixel must be far nearer its own color than the other.
        func close(_ a: NSColor?, _ b: NSColor, not other: NSColor) -> Bool { distance(a, b) < 0.15 && distance(a, b) < distance(a, other) / 2 }
        let center = NSPoint(x: row.circleFrame.midX - 4, y: row.circleFrame.midY - 4)
        var accent = NSColor.controlAccentColor, ground = NSColor.controlBackgroundColor
        row.effectiveAppearance.performAsCurrentDrawingAppearance {
            accent = NSColor.controlAccentColor.usingColorSpace(.sRGB)!
            ground = NSColor.controlBackgroundColor.usingColorSpace(.sRGB)!
        }
        check(close(pixel(row, at: center), ground, not: accent), "an unmarked circle is the card's ground inside its ring")
        browser.canvas.tiles[0].onPick?()
        check(row.isMarked && close(pixel(row, at: center), accent, not: ground), "a marked circle is filled with the accent (\(row.isMarked), \(String(describing: pixel(row, at: center))) for \(accent))")
        host.orderOut(nil)
    }
}

/// A fixture window that reports itself key and on screen without ever being ordered there.
private class TestPanel: NSPanel {
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

/// The drawer's selection panel: records whether anything gave it the keyboard.
private final class KeyRecordingPanel: TestPanel {
    private(set) var tookKeyboard = false
    override var isKeyWindow: Bool { false }
    override func makeKeyAndOrderFront(_ sender: Any?) { tookKeyboard = true; super.makeKeyAndOrderFront(sender) }
    override func makeKey() { tookKeyboard = true }
}
