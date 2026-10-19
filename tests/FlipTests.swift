import AppKit
import QuickLookUI

/// The card turned over to its raw data (Al, 2026-10-12), where it shows: ⌘I in the ⌥⌘\ window, its
/// corner magnet and footer item, the back following the selection, ⌥1–⌥9, ⌘C and ⌘A in its text,
/// typing going back to the search, Esc's rung, every opening on the front; I in the drawer turning
/// Quick Look or opening it turned, its arrows and copies, the medium cursor magnet staying on the
/// preview; Reduce Motion; light and dark. Named pasteboards and fixture panels only; keys go through
/// each container's own key path, and nothing is posted to the system.
@main enum FlipTests {
    private static var assertions = 0
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError("FAIL: \(message)") }
    }
    private static func key(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = [], _ characters: String = "", repeating: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: repeating, keyCode: code)!
    }
    /// The top-row digit keys by position: ⌥n copies flavor n.
    private static let digit: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
    private static func runLoop(_ seconds: TimeInterval = 0.05) {
        RunLoop.current.add(Timer(timeInterval: 0.01, repeats: false) { _ in }, forMode: .default)
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// A store on a named board: a few texts, then the newest, a web copy with its page's address, its
    /// frame token, HTML and text (invented, in the shape a Chromium browser leaves).
    private static func store(_ texts: [String]) -> (ClipboardStore, NSPasteboard) {
        let board = NSPasteboard.withUniqueName()
        let store = ClipboardStore(pasteboard: board, persistenceURL: nil)
        store.attachesCopiesToCursor = { false }
        for text in texts { board.clearContents(); board.setString(text, forType: .string); _ = store.saveNow(); store.cancelStaging() }
        board.clearContents()
        board.writeObjects([ClipboardWebCopies.item(ClipboardWebCopies.chatReply)])
        _ = store.saveNow()
        store.cancelStaging()
        return (store, board)
    }

    /// Work a turn leaves for later, run by hand.
    private final class Steps {
        var pending: [() -> Void] = []
        var delays: [TimeInterval] = []
        lazy var schedule: (TimeInterval, @escaping () -> Void) -> Void = { [unowned self] delay, work in
            self.delays.append(delay); self.pending.append(work)
        }
        func run() { while !pending.isEmpty { pending.removeFirst()() } }
    }

    private static func window(_ store: ClipboardStore) -> (ClipboardHistoryController, TestPanel) {
        let panel = TestPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 470), styleMask: [], backing: .buffered, defer: true)
        var environment = ClipboardPaster.Environment()
        environment.frontmost = { 500 }
        environment.postPaste = { _ in true }
        environment.schedule = { _, _ in }
        let history = ClipboardHistoryController(store: store, paster: ClipboardPaster(store: store, environment: environment),
                                                 previewService: ClipboardPreviewService(), panel: panel)
        history.prepare = { ClipboardPaster.Target(pid: 500) {} }
        history.openInPreview = { _, done in done(nil) }
        history.onError = { fatalError("FAIL: no action here should fail: \($0.localizedDescription)") }
        return (history, panel)
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .aqua)
        keymapChecks()
        windowChecks()
        windowEscapeLadder()
        windowEditingKeys()
        windowReadingByKey()
        windowAppearance(app)
        drawerChecks()
        drawerTurnLooks(app)
        app.appearance = nil
        print("Flip tests passed (\(assertions) assertions)")
    }

    // MARK: Keys

    private static func keymapChecks() {
        let window = ClipboardKeymap.window, drawer = ClipboardKeymap.drawer
        check(window.action(for: key(34, .command, "i")) == .flip && window.label(.flip) == "⌘I" && window.spoken(.flip) == "Command-I",
              "the window's ⌘I turns the card, named ⌘I and Command-I")
        check(window.action(for: key(34, [], "i")) == nil, "a bare I is typing in the window's search")
        check(drawer.action(for: key(34, [], "i")) == .flip && drawer.action(for: key(34, .command, "i")) == .flip && drawer.label(.flip) == "I",
              "the drawer's I (and ⌘I) on the cards, named I")
        check(drawer.action(for: key(34, [], "i"), reaching: [.anywhere, .outsideText]) == nil, "in the drawer's search I types")
        for number in 1...9 {
            let row = key(digit[number - 1], .option, "¡")
            check(window.action(for: row) == .copyFlavor(number) && drawer.action(for: row) == .copyFlavor(number),
                  "⌥\(number) copies flavor \(number) in both")
            check(window.label(.copyFlavor(number)) == "⌥\(number)" && window.spoken(.copyFlavor(number)) == "Option-\(number)"
                  && drawer.label(.copyFlavor(number)) == "⌥\(number)", "⌥\(number) is named ⌥\(number), Option-\(number)")
        }
        check(window.action(for: key(83, [.option, .numericPad], "1")) == .copyFlavor(1), "the keypad's ⌥1 copies flavor 1 too, unnamed")
        check(window.label(.copyFlavor(10)) == nil, "a tenth flavor has no key")
        check(drawer.action(for: key(18, .option, "¡"), reaching: [.anywhere]) == nil, "in the drawer's search ⌥1 types")
        check(drawer.action(for: key(29, [], "0")) == .tab(.all) && window.action(for: key(29, .command, "0")) == .tab(.all),
              "the tabs' digits keep their meaning")
        check(ClipboardBrowserAction.flip.waitsForNextPress && !ClipboardBrowserAction.copyFlavor(1).waitsForNextPress,
              "a held I waits for the next press; a held ⌥n need not")
        check(ClipboardTileTooltip.legendText(.drawer, asker: nil).contains("Raw data ← I"), "the card info lists I")
        // Reading the raw data by key: ⌘T or T, Page Up and Page Down.
        check(window.action(for: key(17, .command, "t")) == .selectRawText && window.label(.selectRawText) == "⌘T" && window.spoken(.selectRawText) == "Command-T",
              "the window's ⌘T reads the raw data's text")
        check(drawer.action(for: key(17, [], "t")) == .selectRawText && drawer.action(for: key(17, .command, "t")) == .selectRawText
              && drawer.label(.selectRawText) == "T" && drawer.action(for: key(17, [], "t"), reaching: [.anywhere, .outsideText]) == nil,
              "the drawer's T (and ⌘T) on the cards; in its search T types")
        for map in [window, drawer] {
            check(map.action(for: key(116)) == .pageUp && map.action(for: key(121)) == .pageDown && map.label(.pageUp) == "⇞"
                  && map.label(.pageDown) == "⇟" && map.spoken(.pageDown) == "Page Down", "Page Up and Page Down scroll the raw data in both, named ⇞ and ⇟")
        }
        check(drawer.action(for: key(121), reaching: [.anywhere]) == nil, "in the drawer's search Page Down is the search's")
        check(ClipboardBrowserAction.selectRawText.waitsForNextPress && !ClipboardBrowserAction.pageDown.waitsForNextPress,
              "a held ⌘T waits for the next press; a held Page Down keeps scrolling")
        check(ClipboardTileTooltip.legendText(.drawer, asker: nil).contains("Raw data's text ← T"), "the card info lists T")
        check(ClipboardRawDataView(keymap: .window).guideText == "⌘T selects text, again for the next  ·  ⇞ ⇟ scroll"
              && ClipboardRawDataView(keymap: .drawer).guideText == "T selects text, again for the next  ·  ⇞ ⇟ scroll",
              "the back says how each container's keys read it")
        let raw = ClipboardRawDataView(keymap: .window)
        let (store, board) = store([])
        defer { store.stop(); board.releaseGlobally() }
        raw.show(store.entries[0])
        check(raw.shownBlocks.map(\.button) == ["Copy ⌥1", "Copy ⌥2", "Copy ⌥3", "Copy ⌥4"], "the back's Copy buttons carry the keymap's keys")
    }

    // MARK: The window

    private static func windowChecks() {
        let (store, board) = store(["Alder", "Birch", "Cedar"])
        defer { store.stop(); board.releaseGlobally() }
        let (history, _) = window(store)
        let view = history.view, flip = view.flip, raw = view.raw, magnet = view.flipMagnet
        let steps = Steps()
        flip.after = steps.schedule
        flip.reducesMotion = { false }
        @discardableResult func press(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = [], _ characters: String = "") -> Bool {
            history.handleKey(key(code, modifiers, characters))
        }
        func type(_ query: String) { view.search.stringValue = query; view.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification)) }
        func footer(_ prefix: String) -> ClipboardHistoryFooter.Item? { view.footer.items.first { $0.title.hasPrefix(prefix) } }

        history.hotKeyPressed()
        let web = store.entries[0]
        check(history.selectedEntry === web && flip.side == .front && view.showsCard && !view.showsRawData && raw.isHidden,
              "the window opens on the card's front")
        check(footer("Raw data")?.title == "Raw data ⌘I" && footer("Raw data")?.help.hasSuffix("(Command-I)") == true,
              "the footer offers Raw data ⌘I")
        check(magnet.isHidden && !view.footer.hintText.lowercased().contains("esc"), "at rest the corner magnet hides, and the hint explains no Esc")
        view.hoverCard(true)
        view.layoutSubtreeIfNeeded()
        check(!magnet.isHidden && magnet.keyedTitle.plain == "Raw data ⌘I" && magnet.refusesFirstResponder && magnet.accessibilityLabel() == "Raw data, Command-I",
              "with the pointer over the card its magnet shows, Raw data ⌘I, never taking the keyboard")
        let content = flip.frame.insetBy(dx: 14, dy: 14), corner = magnet.frame
        check(abs(corner.maxY - (content.minY - 9)) < 0.5 && abs(corner.maxX - content.maxX) < 0.5,
              "it clings 9 points above the card's top-right corner, right edges aligned (\(corner) over \(content))")
        check(!corner.intersects(view.tabs.frame) && corner.minY >= view.publishControl.frame.maxY && corner.maxX <= view.publishControl.frame.maxX
              && !corner.intersects(view.search.frame) && corner.maxY <= content.minY,
              "below the tabs and Publish, neither above nor right of Publish, and over nothing the card shows (\(corner))")
        check(magnet.intrinsicContentSize.width + 6 <= corner.width, "its title shows whole")
        view.layoutSubtreeIfNeeded()
        let scrolling = view.convert(raw.scrollFrame, from: raw)
        check(scrolling.minY >= corner.maxY + 9 - 0.5 && abs(scrolling.minY - content.minY) < 0.5,
              "the back's text, scrolled up, stops 9 points short of the magnet (\(scrolling) under \(corner))")
        view.hoverCard(false)
        check(magnet.isHidden, "the pointer leaving hides it")

        // ⌘I: a rotation from snapshots, swapping halfway, landing on the back.
        check(press(34, .command, "i") && flip.side == .back && flip.turning == .turn && flip.turningImage != nil && steps.delays == [flip.duration / 2],
              "⌘I turns the card over, rotating from a snapshot")
        check(raw.entryID == web.id && raw.shownBlocks.count == 4 && raw.overviewText.contains(web.title),
              "the back reads the selected entry before the turn: its four flavors")
        // The rotation itself, as the turning layer runs it: a quarter turn about the vertical axis, in
        // perspective, over half of 0.35 s, the front's right edge going away; then the back comes round.
        let firstHalf = flip.turningRotation
        check(flip.duration == 0.35 && firstHalf?.keyPath == "transform.rotation.y" && firstHalf?.from == 0
              && abs((firstHalf?.to ?? 0) - .pi / 2) < 0.0001 && abs((firstHalf?.duration ?? 0) - 0.175) < 0.0001 && (firstHalf?.perspective ?? 0) < 0,
              "the front rotates a quarter turn about the vertical axis, in perspective, over 0.175 s (\(String(describing: firstHalf)))")
        steps.pending.removeFirst()()
        let secondHalf = flip.turningRotation
        check(flip.turningFace == .back && secondHalf?.keyPath == "transform.rotation.y" && abs((secondHalf?.from ?? 0) + .pi / 2) < 0.0001
              && secondHalf?.to == 0 && abs((secondHalf?.duration ?? 0) - 0.175) < 0.0001, "halfway, the back comes round from the other edge to face you")
        steps.run()
        check(flip.turning == nil && !raw.isHidden && view.card.isHidden && view.showsRawData, "the turn lands on the back")
        check(!magnet.isHidden && magnet.keyedTitle.plain == "Preview ⌘I" && footer("Preview")?.title == "Preview ⌘I" && footer("Raw data") == nil,
              "turned, its magnet stays, offering Preview ⌘I, as the footer does")
        check(!view.footer.hintText.lowercased().contains("esc"), "the hint never explains Esc: \(view.footer.hintText)")
        let blocks = raw.shownBlocks
        check(blocks.contains { $0.header.hasPrefix(ClipboardFlavors.sourceURL.rawValue) && $0.content == "https://claude.ai/chat/clipedge-fixture" }
              && blocks.contains { $0.header.hasPrefix("public.html") && $0.content == "<p>ClipEdge fixture reply from a chat page</p>" },
              "the back shows the page's whole address and the HTML as its source")

        // The back follows the selection, so one entry's raw data can be compared with the next's.
        check(press(125) && history.selectedEntry === store.entries[1] && raw.entryID == store.entries[1].id && view.showsRawData
              && raw.shownBlocks.contains { $0.content == "Cedar" }, "moving the selection shows the next entry's raw data, still turned")
        check(press(126) && raw.entryID == web.id, "and back")

        // ⌥n copies flavor n; the copy joins the history and the selection stays put.
        let flavors = ClipboardRawData(entry: web).flavors
        let html = flavors.first { $0.type == .html }!, token = flavors.first { $0.type == ClipboardWebCopies.frameToken }!
        var count = store.entries.count
        check(press(digit[html.number - 1], .option, "¡") && store.entries.count == count + 1
              && store.entries[0].plainText == "<p>ClipEdge fixture reply from a chat page</p>" && history.isVisible,
              "⌥\(html.number) copies the HTML flavor as its text, which joins the history, the window staying open")
        check(history.selectedEntry === web && raw.entryID == web.id && raw.copiedNumber == html.number
              && raw.button(of: html.number)?.keyedTitle.plain == "Copied ⌥\(html.number)", "the selection stays, and its button says Copied")
        count = store.entries.count
        check(press(digit[token.number - 1], .option, "¡") && store.entries[0].values.map(\.type) == [ClipboardWebCopies.frameToken]
              && store.entries[0].values.first?.data == Data(repeating: 8, count: 24), "the frame token copies as its own bytes, under its own type")
        count = store.entries.count
        check(press(digit[8], .option, "¡") && store.entries.count == count, "⌥9 with no ninth flavor copies nothing")
        // Turning back rotates the other way, the back's left edge going away.
        check(press(34, .command, "i") && flip.turningRotation?.keyPath == "transform.rotation.y" && flip.turningRotation?.from == 0
              && abs((flip.turningRotation?.to ?? 0) + .pi / 2) < 0.0001, "turning back rotates the other way (\(String(describing: flip.turningRotation)))")
        steps.run()
        press(34, .command, "i")
        steps.run()
        view.flipMagnet.performClick(nil)
        steps.run()
        check(flip.side == .front && !view.showsRawData && magnet.isHidden, "the magnet turns the card back; at rest it hides again")
        check(raw.entryID == nil && raw.shownBlocks.isEmpty && raw.raw == nil, "turned away, the back lets go of what it read (a deleted entry's bytes included)")
        check(!press(digit[0], .option, "¡") && store.entries.count == count, "on the front ⌥1 goes on to the search as typing")
        footer("Raw data")?.action()
        steps.run()
        check(flip.side == .back, "the footer's Raw data turns it too")

        // Reduce Motion: a short crossfade, no rotation.
        flip.reducesMotion = { true }
        check(press(34, .command, "i") && flip.side == .front && flip.turning == .crossfade && flip.turningImage == nil, "with Reduce Motion the turn crossfades")
        steps.run()
        check(flip.turning == nil && raw.isHidden && !view.card.isHidden, "and lands")
        flip.reducesMotion = { false }

        // A held ⌘I waits for the next press.
        check(history.handleKey(key(34, .command, "i", repeating: true)) && flip.side == .front && steps.pending.isEmpty, "⌘I held down does not flicker")

        // An empty list: nothing to turn to on the front; turned, its back shows nothing.
        press(34, .command, "i"); steps.run()
        type("no such clipboard words")
        check(history.selectedEntry == nil && raw.entryID == nil && view.showsRawData, "a search with no matches leaves the turned card empty")
        check(press(34, .command, "i") && flip.side == .front, "⌘I still turns it back")
        steps.run()
        check(press(34, .command, "i") && flip.side == .front, "and with nothing selected the front does not turn")
        type("")

        // Multi-select: the selection's actions take the card's place; the card keeps its side.
        press(34, .command, "i"); steps.run()
        press(1, .command, "s")
        check(view.list.marking.isOn && view.showsRawData, "with marking on and nothing marked, the turned card still shows")
        press(36)
        check(!view.showsCard && !view.selectionPanel.isHidden && magnet.isHidden && view.footer.items.isEmpty, "a mark puts the selection's actions in its place")
        check(press(34, .command, "i") && flip.side == .back && steps.pending.isEmpty, "⌘I then turns nothing: there is no card to turn")
        press(36)
        check(view.showsRawData && !magnet.isHidden, "with the last mark gone the card returns as it was, turned")
        press(1, .command, "s")

        // Every opening starts on the front.
        check(view.showsRawData && raw.entryID != nil, "turned, before closing")
        history.close()
        check(raw.entryID == nil && raw.shownBlocks.isEmpty, "closing lets go of the back's raw data, so nothing deleted meanwhile stays")
        history.hotKeyPressed()
        check(flip.side == .front && raw.entryID == nil && magnet.isHidden && !view.showsRawData, "every opening starts on the front")
        press(34, .command, "i"); steps.run()
        check(raw.entryID == history.selectedEntry?.id && raw.copiedNumber == nil, "the back reads afresh, nothing marked Copied")
        history.close()
    }

    /// Esc steps out one rung at a time: a waiting delete, the turned card, marking, the search, the window.
    private static func windowEscapeLadder() {
        let (store, board) = store(["Alder", "Birch", "Cedar"])
        defer { store.stop(); board.releaseGlobally() }
        let (history, _) = window(store)
        let view = history.view, flip = view.flip
        flip.reducesMotion = { true }
        let steps = Steps()
        flip.after = steps.schedule
        @discardableResult func press(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = [], _ characters: String = "") -> Bool {
            let handled = history.handleKey(key(code, modifiers, characters)); steps.run(); return handled
        }
        func type(_ query: String) { view.search.stringValue = query; view.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification)) }
        /// The hint names no Esc rung, whichever rung Esc is on (vault rule, 2026-10-16).
        func quietEsc() -> Bool { !view.footer.hintText.lowercased().contains("esc") }

        history.hotKeyPressed()
        type("e")
        press(34, .command, "i")
        press(51, .command)
        check(view.canvas.armedID != nil && view.showsRawData && quietEsc(), "a delete waits while the card is turned")
        check(press(53) && view.canvas.armedID == nil && view.showsRawData && store.entries.count == 4 && quietEsc(),
              "Esc first keeps what the delete asked about")
        check(press(53) && !view.showsRawData && view.search.stringValue == "e" && quietEsc(), "then turns the card back")
        check(press(53) && view.search.stringValue.isEmpty && quietEsc(), "then clears the search")
        check(press(53) && !history.isVisible, "then closes")

        history.hotKeyPressed()
        press(1, .command, "s")
        press(34, .command, "i")
        check(view.list.marking.isOn && view.showsRawData && quietEsc(), "turned while selecting")
        check(press(53) && !view.showsRawData && view.list.marking.isOn && quietEsc(), "Esc turns the card back before it ends selecting")
        check(press(53) && !view.list.marking.isOn && quietEsc(), "then ends selecting")
        check(press(53) && !history.isVisible, "then closes")
    }

    /// ⌘C and ⌘A in the back's text, and typing going back to the search.
    private static func windowEditingKeys() {
        let (store, board) = store(["Alder", "Birch", "Cedar"])
        defer { store.stop(); board.releaseGlobally() }
        let (history, panel) = window(store)
        let view = history.view, flip = view.flip, raw = view.raw
        flip.reducesMotion = { true }
        let steps = Steps()
        flip.after = steps.schedule
        @discardableResult func press(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = [], _ characters: String = "") -> Bool {
            let handled = history.handleKey(key(code, modifiers, characters)); steps.run(); return handled
        }
        var searchHolds: Bool { panel.firstResponder === view.search.currentEditor() && view.search.currentEditor() != nil }

        history.hotKeyPressed()
        check(searchHolds, "the search holds the keyboard")
        press(34, .command, "i")
        let web = store.entries[0]
        let html = ClipboardRawData(entry: web).flavors.first { $0.type == .html }!
        guard let text = raw.contentView(of: html.number) else { fatalError("FAIL: the HTML flavor has its text") }
        check(panel.makeFirstResponder(text) && raw.holdsKeyboard, "a click puts the keyboard in the back's text, to select")
        text.setSelectedRange(NSRange(location: 3, length: 7))
        let part = (text.string as NSString).substring(with: NSRange(location: 3, length: 7))
        var count = store.entries.count
        check(press(8, .command, "c") && history.isVisible && store.entries.count == count + 1 && store.entries[0].plainText == part,
              "⌘C with text selected there copies just that, as plain text, and the window stays (\(part))")
        check(history.selectedEntry === web && raw.selectedText == part, "the selection and the text's own selection stay")
        check(press(0, .command, "a") && text.selectedRange() == NSRange(location: 0, length: (text.string as NSString).length) && searchHolds == false,
              "⌘A selects all of that text, not the search's")
        count = store.entries.count
        check(press(8, .command, "c") && store.entries[0].plainText == html.copy.map { if case .text(let s) = $0 { return s }; return "" },
              "⌘C then copies all of it")

        // Typing goes back to the search, the letter with it.
        let letter = key(12, [], "q")
        check(!history.handleKey(letter) && searchHolds && !raw.holdsKeyboard, "a letter typed there goes on to the search, the keyboard with it")
        panel.firstResponder?.keyDown(with: letter)
        check((view.search.currentEditor() as? NSTextView)?.string == "q", "where it types")
        (view.search.currentEditor() as? NSTextView)?.string = ""
        view.search.stringValue = ""
        view.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        // The two copies just made are newest now: back to the web copy.
        view.canvas.choose(web.id)
        check(history.selectedEntry === web && view.showsRawData && raw.entryID == web.id, "back on the web copy, still turned")

        // The arrows are the text's while it holds the keyboard; moving the selection another way (the
        // window's shortcut, a click) rebuilds the back, and the keyboard leaves its text for the search.
        guard let again = raw.contentView(of: html.number) else { fatalError("FAIL: the HTML text is there again") }
        panel.makeFirstResponder(again)
        check(!history.handleKey(key(125)) && history.selectedEntry === web && raw.holdsKeyboard, "↓ in the text goes on to it, the selection staying")
        history.hotKeyPressed()
        check(searchHolds && history.selectedEntry !== web && raw.entryID == history.selectedEntry?.id,
              "moving the selection gives the keyboard back to the search")
        press(126)
        guard let third = raw.contentView(of: html.number) else { fatalError("FAIL: the HTML text is back") }
        panel.makeFirstResponder(third)
        check(press(34, .command, "i") && searchHolds && !view.showsRawData, "turning back does too")

        // Turned or not, ⌘C with nothing selected picks the entry up, as ever.
        press(34, .command, "i")
        guard let fourth = raw.contentView(of: html.number) else { fatalError("FAIL: the HTML text shows") }
        panel.makeFirstResponder(fourth)
        fourth.setSelectedRange(NSRange(location: 0, length: 0))
        check(press(8, .command, "c") && !history.isVisible && store.stagedEntryID == web.id, "with nothing selected ⌘C picks the entry up, closing the window")
        store.cancelStaging()
    }

    /// The back read by key: ⌘T from text to text, the arrows and ⇧ in it, Page Up and Page Down, Esc's
    /// rung back to the search; and a copy made from it that only re-dates its entry keeps what it shows.
    private static func windowReadingByKey() {
        let long = (1...240).map { "Line \($0) of a long plain fixture text" }.joined(separator: "\n")
        let (store, board) = store(["Alder", long])
        defer { store.stop(); board.releaseGlobally() }
        let (history, panel) = window(store)
        let view = history.view, flip = view.flip, raw = view.raw
        flip.reducesMotion = { true }
        let steps = Steps()
        flip.after = steps.schedule
        @discardableResult func press(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = [], _ characters: String = "") -> Bool {
            let handled = history.handleKey(key(code, modifiers, characters)); steps.run(); return handled
        }
        var searchHolds: Bool { panel.firstResponder === view.search.currentEditor() && view.search.currentEditor() != nil }
        guard let longEntry = store.entries.first(where: { $0.plainText == long }),
              let alder = store.entries.first(where: { $0.plainText == "Alder" }) else { fatalError("FAIL: the fixtures are in the history") }

        history.hotKeyPressed()
        view.canvas.choose(longEntry.id)
        check(!press(121) && raw.raw == nil, "on the front, Page Down goes on to the search")
        press(34, .command, "i")
        view.layoutSubtreeIfNeeded()
        check(view.showsRawData && view.footer.hintText.contains("⌘T selects text") && view.footer.hintText.contains("⇞ ⇟ scroll")
              && !view.footer.hintText.lowercased().contains("esc"), "turned, the hint says how to read it by key: \(view.footer.hintText)")
        check(raw.guideText?.hasPrefix("⌘T selects text") == true, "and so does the back")

        // Page Down and Page Up from the search: the column a screenful at a time.
        check(press(121) && raw.scrollOffset > 100 && searchHolds, "Page Down scrolls the back a screenful, the search keeping the keyboard (\(raw.scrollOffset))")
        check(press(116) && raw.scrollOffset == 0, "Page Up back to the top")

        // ⌘T: the overview, then each flavor's text, then round again.
        check(press(17, .command, "t") && panel.firstResponder === raw.overviewView && raw.holdsKeyboard, "⌘T puts the keyboard in the overview")
        check(press(17, .command, "t") && panel.firstResponder === raw.contentView(of: 1), "again, in the first flavor's text, its only one")
        check(press(17, .command, "t") && panel.firstResponder === raw.overviewView, "after the last, the overview again")
        press(17, .command, "t")
        guard let text = raw.contentView(of: 1) else { fatalError("FAIL: the long text shows") }
        runLoop()
        check(!view.footer.hintText.lowercased().contains("esc"), "the hint explains no Esc while the text holds the keyboard: \(view.footer.hintText)")

        // The arrows are the text's: ↓ moves its caret, ⇧↓ selects; the rows and the marks stay.
        let chosen = history.selectedEntry
        for event in [key(125), key(125, .shift), key(126, .shift), key(124), key(123, .shift), key(119)] {
            check(!history.handleKey(event) && history.selectedEntry === chosen && !view.list.marking.isOn && raw.holdsKeyboard,
                  "key \(event.keyCode)\(event.modifierFlags.contains(.shift) ? " with ⇧" : "") goes on to the text, not the rows or the marks")
        }
        // What the system's key bindings send for them (↓ moveDown:, ⇧↓ moveDownAndModifySelection:): the
        // text, never editable, still has a caret they move, drawn where it is.
        text.setSelectedRange(NSRange(location: 0, length: 0))
        let top = raw.caretRect
        check(top != nil && top!.width == 1 && top!.height > 8, "a caret shows at the text's start while it holds the keyboard (\(String(describing: top)))")
        text.doCommand(by: #selector(NSResponder.moveDown(_:)))
        let second = (text.string as NSString).range(of: "Line 2 ").location
        check(text.selectedRange() == NSRange(location: second, length: 0) && (raw.caretRect?.minY ?? 0) > (top?.minY ?? 0),
              "↓ moves the caret down a line, where it is drawn (\(text.selectedRange()))")
        text.doCommand(by: #selector(NSResponder.moveWordRight(_:)))
        check(text.selectedRange().location > second && text.selectedRange().length == 0, "⌥→ moves it a word on")
        text.doCommand(by: #selector(NSResponder.moveToLeftEndOfLine(_:)))
        check(text.selectedRange() == NSRange(location: second, length: 0), "⌘← back to the line's start")
        text.doCommand(by: #selector(NSResponder.moveDownAndModifySelection(_:)))
        text.doCommand(by: #selector(NSResponder.moveDownAndModifySelection(_:)))
        let picked = (text.string as NSString).substring(with: text.selectedRange())
        check(text.selectedRange().length > 0 && picked.hasPrefix("Line 2 ") && picked.contains("Line 3 ") && !picked.contains("Line 1 ")
              && raw.caretRect == nil, "⇧↓ selects from the caret, two lines (\(text.selectedRange()))")
        text.doCommand(by: #selector(NSResponder.moveLeft(_:)))
        check(text.selectedRange() == NSRange(location: second, length: 0), "← lets go of a selection at its start, as in any text")
        text.doCommand(by: #selector(NSResponder.moveDownAndModifySelection(_:)))
        text.doCommand(by: #selector(NSResponder.moveDownAndModifySelection(_:)))
        let count = store.entries.count
        check(press(8, .command, "c") && store.entries.count == count + 1 && store.entries[0].plainText == picked, "⌘C copies the lines selected by key")
        check(press(121) && raw.holdsKeyboard && raw.scrollOffset > 0, "Page Down scrolls while the text keeps the keyboard")
        check(press(53) && searchHolds && view.showsRawData && !raw.holdsKeyboard, "Esc gives the keyboard back to the search, the card still turned")
        runLoop()
        check(!view.footer.hintText.lowercased().contains("esc"), "and none once the search has it back: \(view.footer.hintText)")

        // A copy from the back that only re-dates its entry (all of a plain text) keeps what it shows.
        view.canvas.choose(alder.id)
        check(raw.entryID == alder.id, "the back follows the selection to a plain text")
        press(17, .command, "t"); press(17, .command, "t")
        guard let plain = raw.contentView(of: 1) else { fatalError("FAIL: the plain text shows") }
        check(press(0, .command, "a") && plain.selectedRange() == NSRange(location: 0, length: 5), "⌘A selects all of it")
        let entries = store.entries.count
        check(press(8, .command, "c") && store.entries.count == entries && store.entries[0] === alder,
              "⌘C of all of it is the same copy: the entry moves to the top, no new one")
        check(raw.entryID == alder.id && raw.contentView(of: 1) === plain && raw.holdsKeyboard && plain.selectedRange() == NSRange(location: 0, length: 5)
              && raw.overviewText.contains(alder.fullDateTimeStamp),
              "and the back keeps its text, its selection and the keyboard, its overview showing the new time")
        check(press(53) && press(53) && !view.showsRawData, "Esc, then Esc again turns the card back")
        history.close()
    }

    /// The turned card in light and dark: its boxes paint their ground in the window's appearance.
    private static func windowAppearance(_ app: NSApplication) {
        for theme in [NSAppearance.Name.aqua, .darkAqua] {
            app.appearance = NSAppearance(named: theme)
            let (store, board) = store(["Alder"])
            let (history, panel) = window(store)
            panel.appearance = NSAppearance(named: theme)
            let view = history.view
            view.flip.reducesMotion = { true }
            let steps = Steps()
            view.flip.after = steps.schedule
            history.hotKeyPressed()
            _ = history.handleKey(key(34, .command, "i")); steps.run()
            view.layoutSubtreeIfNeeded()
            let html = ClipboardRawData(entry: store.entries[0]).flavors.first { $0.type == .html }!
            let box = view.raw.contentView(of: html.number)?.superview as? ClipboardSurfaceView
            var expected: CGColor?
            NSAppearance(named: theme)!.performAsCurrentDrawingAppearance { expected = NSColor.textBackgroundColor.cgColor }
            let ground = box?.layer?.backgroundColor
            check(ground != nil && expected != nil && zip(ground!.components ?? [], expected!.components ?? []).allSatisfy { abs($0 - $1) < 0.02 },
                  "built in \(theme.rawValue), the back's boxes paint the \(theme.rawValue) text ground")
            check(view.raw.effectiveAppearance.name == theme && view.flipMagnet.effectiveAppearance.name == theme, "the back and its magnet follow the window's appearance")
            history.close()
            store.stop()
            board.releaseGlobally()
        }
        app.appearance = NSAppearance(named: .aqua)
    }

    // MARK: The drawer

    private static func drawerChecks() {
        let (store, board) = store(["Alder", "Birch", "Cedar"])
        defer { store.stop(); board.releaseGlobally() }
        let magnetPanel = TestPanel(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        let magnet = ClipboardMagnetController(panel: magnetPanel, commandClickEnabled: false)
        let drawerPanel = TestPanel(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        let selectionPanel = TestPanel(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        let drawer = ClipboardDrawerController(store: store, magnetController: magnet, panel: drawerPanel, defaults: nil, selectionPanel: selectionPanel)
        defer { drawer.stop() }
        let browser = drawer.browser, cards = browser.canvas
        var moved = 0.0
        cards.pointer = { moved += 1; return NSPoint(x: moved, y: 0) }
        drawer.show(on: NSScreen.main!)
        drawerPanel.makeFirstResponder(cards)
        func press(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = [], _ characters: String = "", repeating: Bool = false) {
            let event = key(code, modifiers, characters, repeating: repeating)
            if !drawer.handleDrawerKey(event) { cards.keyDown(with: event) }
        }
        func settle(_ carousel: ClipboardCarouselView) { for _ in 0..<40 where carousel.flip.turning != nil { runLoop() } }

        let chosen = cards.selected!.entry
        check(magnet.drawerCarousel == nil, "Quick Look is closed")
        press(34, [], "i")
        guard let carousel = magnet.drawerCarousel else { fatalError("FAIL: I opens Quick Look beside the drawer") }
        check(store.stagedEntryID == chosen.id && carousel.showsRawData && carousel.flip.turning == nil && carousel.raw.entryID == chosen.id,
              "I opens Quick Look on the chosen card, already turned to its raw data")
        check(!carousel.flipButton.isHidden && carousel.flipButton.keyedTitle.plain == "Preview I" && carousel.flipButton.accessibilityLabel() == "Preview, I"
              && carousel.raw.shownBlocks.first?.button == "Copy ⌥1", "its button offers Preview I; its copies carry the drawer's keys")
        carousel.layoutSubtreeIfNeeded()
        let buttonFrame = carousel.flipButton.frame
        let stamp = carousel.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == chosen.dateTimeStamp }
        check(carousel.bounds.contains(buttonFrame) && buttonFrame.maxX <= carousel.bounds.maxX - 33 && stamp.map { !$0.frame.intersects(buttonFrame) } == true
              && carousel.flipButton.intrinsicContentSize.width + 6 <= buttonFrame.width, "the button sits whole beside ×, after the date (\(buttonFrame))")
        check(carousel.flip.frame.maxY <= buttonFrame.minY && carousel.raw.frame.size == carousel.flip.frame.size,
              "the raw data takes the preview's place, under the controls")

        // I again: Quick Look shows the chosen card, so it turns. Its preview is another process's
        // drawing, so the turn crossfades.
        press(34, [], "i")
        check(carousel.flip.side == .front && carousel.flip.turning == .crossfade && carousel.flipButton.keyedTitle.plain == "Raw data I",
              "I turns it back, crossfading over Quick Look's own drawing")
        settle(carousel)
        check(carousel.flip.turning == nil && carousel.raw.isHiddenOrHasHiddenAncestor && !carousel.showsRawData, "and lands on the preview")
        press(34, .command, "i")
        settle(carousel)
        check(carousel.showsRawData, "⌘I turns it too")
        press(34, [], "i", repeating: true)
        check(carousel.showsRawData && carousel.flip.turning == nil, "I held down waits for the next press")

        // The arrows keep browsing; the back follows the entry.
        press(124)
        check(magnet.drawerCarousel === carousel && store.stagedEntryID != chosen.id && carousel.raw.entryID == store.stagedEntryID && carousel.showsRawData,
              "→ browses to the next card, its raw data showing")
        press(123)
        check(store.stagedEntryID == chosen.id && carousel.raw.entryID == chosen.id, "← back")

        // Quick Look showing another card than the chosen one: I opens it on the chosen card, turned.
        let other = cards.tiles[2].entry
        cards.choose(other.id, reveal: false)
        press(34, [], "i")
        check(store.stagedEntryID == other.id && magnet.drawerCarousel?.showsRawData == true && magnet.drawerCarousel?.raw.entryID == other.id,
              "with Quick Look on another card, I shows the chosen one, turned")
        press(34, [], "i")
        settle(magnet.drawerCarousel!)
        check(magnet.drawerCarousel?.showsRawData == false, "then turns it back")
        check(!drawer.handleDrawerKey(key(18, .option, "¡")), "on the preview ⌥1 is not the drawer's")

        // ⌥n copies a flavor through the history. The copy replaces what Quick Look put on the
        // clipboard, so the preview ends with it, as any copy ends it.
        cards.choose(chosen.id, reveal: false)
        press(34, [], "i")
        let flavors = ClipboardRawData(entry: chosen).flavors
        let html = flavors.first { $0.type == .html }!
        var count = store.entries.count
        press(digit[html.number - 1], .option, "¡")
        check(store.entries.count == count + 1 && store.entries[0].plainText == "<p>ClipEdge fixture reply from a chat page</p>"
              && magnet.drawerCarousel == nil && store.stagedEntryID == nil && drawer.isVisible,
              "⌥\(html.number) copies that flavor into the history; Quick Look ends, the drawer stays")
        count = store.entries.count
        press(digit[0], .option, "¡")
        check(store.entries.count == count, "with Quick Look closed ⌥1 copies nothing")

        // Text selected there: ⌘C copies just that, even with the keyboard in Quick Look's panel.
        cards.choose(chosen.id, reveal: false)
        press(34, [], "i")
        guard let turned = magnet.drawerCarousel, let text = turned.raw.contentView(of: html.number) else { fatalError("FAIL: Quick Look's raw data shows") }
        magnetPanel.makeFirstResponder(text)
        text.setSelectedRange(NSRange(location: 3, length: 7))
        let part = (text.string as NSString).substring(with: NSRange(location: 3, length: 7))
        count = store.entries.count
        press(8, .command, "c")
        check(store.entries.count == count + 1 && store.entries[0].plainText == part, "⌘C copies the text selected in Quick Look's raw data, not the card")
        // Any other key brings the keyboard back to the cards, where it acts.
        press(34, [], "i")
        guard let reopened = magnet.drawerCarousel, let again = reopened.raw.contentView(of: html.number) else { fatalError("FAIL: turned again") }
        magnetPanel.makeFirstResponder(again)
        check(reopened.raw.holdsKeyboard, "the raw data's text holds Quick Look's keyboard")
        // The key was on its way to Quick Look's panel: the drawer takes it whole, nothing falling
        // through to that panel, as the system would deliver it.
        check(drawer.handleDrawerKey(key(1, [], "s")) && !reopened.raw.holdsKeyboard && drawerPanel.firstResponder === cards && browser.list.marking.isOn,
              "S there gives the keyboard back to the cards and selects, the key acting on them")
        press(1, [], "s")
        magnetPanel.makeFirstResponder(reopened.raw.contentView(of: html.number))
        check(drawer.handleDrawerKey(key(7, [], "x")) && drawerPanel.firstResponder === cards && reopened.showsRawData,
              "a key the cards do not use also leaves the text, taken by the drawer and going no further")
        magnetPanel.makeFirstResponder(reopened.raw.contentView(of: html.number))
        check(!drawer.handleDrawerKey(key(124)) && !drawer.handleDrawerKey(key(125, .shift)) && store.stagedEntryID == chosen.id
              && reopened.raw.holdsKeyboard && !browser.list.marking.isOn,
              "→ and ⇧↓ there are the text's: they go on to it, Quick Look and the marks unmoved")
        check(magnet.shouldHandleEscape() == false, "Quick Look's panel holding the keyboard leaves Esc to the drawer, not to the held preview")
        check(drawer.handleDrawerKey(key(53)) && drawerPanel.firstResponder === cards && !reopened.raw.holdsKeyboard
              && magnet.drawerCarousel === reopened && reopened.showsRawData && store.stagedEntryID == chosen.id,
              "Esc there gives the keyboard back to the cards, Quick Look staying turned")
        check(drawer.handleDrawerKey(key(124)) && store.stagedEntryID != chosen.id && magnet.drawerCarousel?.raw.entryID == store.stagedEntryID,
              "→ from the cards then browses Quick Look")
        press(123)

        // T: the keyboard into Quick Look's raw data, by key: the overview, then each flavor's text.
        press(17, [], "t")
        check(magnetPanel.firstResponder === reopened.raw.overviewView && reopened.raw.holdsKeyboard, "T puts the keyboard in Quick Look's raw data, at its overview")
        check(drawer.handleDrawerKey(key(17, [], "t")) && magnetPanel.firstResponder === reopened.raw.contentView(of: 1), "T again: the first flavor's text")
        check(drawer.handleDrawerKey(key(17, [], "t", repeating: true)) && magnetPanel.firstResponder === reopened.raw.contentView(of: 1),
              "a held T waits for the next press")
        check(drawer.handleDrawerKey(key(121)) && reopened.raw.holdsKeyboard, "Page Down there scrolls, the text keeping the keyboard")

        // Quick Look following a hovered card, or turned back by its button, gives the keyboard back to
        // the cards as its raw data goes: never stranded in a panel whose text is gone.
        let hovered = cards.tiles.first { $0.entry.id != chosen.id }!
        hovered.onHover?()
        check(store.stagedEntryID == hovered.entry.id && reopened.raw.entryID == hovered.entry.id && !reopened.raw.holdsKeyboard
              && drawerPanel.firstResponder === cards && magnetPanel.firstResponder === magnetPanel,
              "hovering another card rebuilds Quick Look's raw data and gives the keyboard back to the cards")
        magnetPanel.makeFirstResponder(reopened.raw.contentView(of: 1))
        reopened.flipButton.performClick(nil)
        check(!reopened.raw.holdsKeyboard && drawerPanel.firstResponder === cards, "Preview I turning it back gives the keyboard back to the cards too")
        settle(reopened)
        check(reopened.raw.entryID == nil && reopened.raw.shownBlocks.isEmpty, "turned back, its raw data lets go of the entry")
        cards.choose(chosen.id, reveal: false)
        press(34, [], "i")
        check(reopened.showsRawData && reopened.raw.entryID == chosen.id, "turned again, it reads the entry afresh")

        // Text left selected there while the drawer takes the keyboard back by a click: the drawer's
        // search keeps its own ⌘A and ⌘C, the stale text answers neither.
        magnetPanel.makeFirstResponder(reopened.raw.contentView(of: html.number))
        reopened.raw.contentView(of: html.number)?.setSelectedRange(NSRange(location: 3, length: 7))
        magnetPanel.keyed = false
        // As a click puts it there: no keyboard move through the cards (which would hand Quick Look to the pointer).
        browser.list.search.focus(selectingAll: false)
        count = store.entries.count
        check(!drawer.handleDrawerKey(key(0, .command, "a")) && !drawer.handleDrawerKey(key(8, .command, "c")) && store.entries.count == count
              && reopened.raw.contentView(of: html.number)?.selectedRange() == NSRange(location: 3, length: 7),
              "with the drawer's search holding the keyboard, ⌘A and ⌘C are its own, not the text left selected in Quick Look")
        drawerPanel.keyed = false
        magnetPanel.keyed = true
        check(magnet.shouldHandleEscape() == false, "nor does Esc close Quick Look while its panel holds the keyboard")
        magnetPanel.makeFirstResponder(nil)
        check(drawer.handleDrawerKey(key(7, [], "x")) && drawerPanel.firstResponder === cards && magnetPanel.firstResponder === magnetPanel,
              "and with Quick Look's panel key but its text not, a key still comes back to the cards (\(String(describing: magnetPanel.firstResponder)))")
        drawerPanel.keyed = true
        drawerPanel.makeFirstResponder(cards)

        // Closing the drawer hands Quick Look to the pointer, where no key reaches it: it shows the preview.
        check(reopened.showsRawData, "still turned")
        drawer.hide(animated: false)
        let medium = magnetPanel.contentView as? ClipboardCarouselView
        check(magnet.presentation == .carousel && medium === reopened && magnet.drawerCarousel == nil, "the drawer closing makes it the medium cursor magnet")
        check(medium?.flip.side == .front && medium?.flipButton.isHidden == true && medium?.showsRawData == false,
              "which stays on the preview, with no turn button")
        store.cancelStaging()
        drawer.show(on: NSScreen.main!)
        drawerPanel.makeFirstResponder(cards)
        press(49)
        check(magnet.drawerCarousel != nil && magnet.drawerCarousel?.showsRawData == false && magnet.drawerCarousel?.flipButton.isHidden == false,
              "Space opens Quick Look on the preview side, its turn button showing")
        press(34, [], "i")
        let shown = magnet.drawerCarousel
        check(shown?.raw.entryID != nil, "turned, Quick Look's raw data reads the entry")
        magnet.hide()
        check(shown?.raw.entryID == nil && shown?.raw.shownBlocks.isEmpty == true, "hidden, Quick Look's raw data holds nothing of the entry")
        store.cancelStaging()

        // Quick Look holds its entry weakly: one deleted while it shows, or after, is not kept alive by it.
        weak var gone: ClipboardEntry?
        let loose: ClipboardCarouselView = autoreleasepool {
            let entry = ClipboardEntry(fingerprint: "fixture-weak", capturedAt: Date(), payloads: [ClipboardPayload(values: [(.string, Data("Gone soon".utf8))])],
                                       title: "Gone soon", detail: "Fixture", kind: .text, thumbnail: nil)
            gone = entry
            let view = ClipboardCarouselView(entry: entry, urls: [], position: 0, count: 1)
            view.allowsFlip = true
            view.turn(to: .back, animated: false)
            check(view.raw.entryID == entry.id, "turned, a loose Quick Look reads its entry")
            view.turn(to: .front, animated: false)
            return view
        }
        check(gone == nil && loose.raw.entryID == nil, "turned back and let go of elsewhere, the entry is freed: Quick Look keeps none of it")
        loose.turn(to: .back, animated: false)
        check(loose.raw.entryID == nil && loose.raw.shownBlocks.isEmpty, "turned again, there is nothing of it to show")
    }
}

extension FlipTests {
    /// The drawer's fixture: the drawer, Quick Look's magnet and the selection panel, on test panels.
    private static func drawerRig(_ store: ClipboardStore, appearance: NSAppearance? = nil)
        -> (ClipboardDrawerController, ClipboardMagnetController, TestPanel, TestPanel) {
        let magnetPanel = TestPanel(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        let drawerPanel = TestPanel(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        let selectionPanel = TestPanel(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        [magnetPanel, drawerPanel, selectionPanel].forEach { $0.appearance = appearance }
        let magnet = ClipboardMagnetController(panel: magnetPanel, commandClickEnabled: false)
        let drawer = ClipboardDrawerController(store: store, magnetController: magnet, panel: drawerPanel, defaults: nil, selectionPanel: selectionPanel)
        drawer.show(on: NSScreen.main!)
        drawerPanel.makeFirstResponder(drawer.browser.canvas)
        return (drawer, magnet, drawerPanel, magnetPanel)
    }

    /// Quick Look's turn beside the drawer: over a color swatch, which ClipEdge draws itself, it
    /// rotates, and with Reduce Motion it crossfades; its raw data in light and dark.
    static func drawerTurnLooks(_ app: NSApplication) {
        let (colors, colorBoard) = store(["#FF8800"])
        let (drawer, magnet, _, _) = drawerRig(colors)
        let cards = drawer.browser.canvas
        func press(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = [], _ characters: String = "") {
            let event = key(code, modifiers, characters)
            if !drawer.handleDrawerKey(event) { cards.keyDown(with: event) }
        }
        guard let color = colors.entries.first(where: { $0.swatchColor != nil }) else { fatalError("FAIL: the fixture has a color") }
        cards.choose(color.id, reveal: false)
        press(34, [], "i")
        guard let carousel = magnet.drawerCarousel else { fatalError("FAIL: I opens Quick Look turned") }
        let steps = Steps()
        carousel.flip.after = steps.schedule
        carousel.flip.reducesMotion = { false }
        carousel.layoutSubtreeIfNeeded()
        check(carousel.showsRawData && carousel.raw.entryID == color.id, "I opens Quick Look on the color, turned")
        press(34, [], "i")
        check(carousel.flip.turning == .turn && carousel.flip.turningImage != nil && steps.delays == [carousel.flip.duration / 2]
              && carousel.flip.turningRotation?.keyPath == "transform.rotation.y" && abs((carousel.flip.turningRotation?.to ?? 0) + .pi / 2) < 0.0001,
              "over a swatch, which ClipEdge draws itself, the turn rotates about the vertical axis")
        steps.run()
        check(carousel.flip.turning == nil && !carousel.showsRawData && carousel.raw.isHiddenOrHasHiddenAncestor, "and lands on the swatch")
        carousel.flip.reducesMotion = { true }
        press(34, [], "i")
        check(carousel.flip.turning == .crossfade && carousel.flip.turningImage == nil && carousel.showsRawData,
              "with Reduce Motion the drawer's turn crossfades")
        steps.run()
        check(carousel.flip.turning == nil && !carousel.raw.isHiddenOrHasHiddenAncestor && carousel.flip.front.isHidden, "and lands on the raw data")
        press(53)
        drawer.stop()
        colors.stop()
        colorBoard.releaseGlobally()

        for theme in [NSAppearance.Name.aqua, .darkAqua] {
            app.appearance = NSAppearance(named: theme)
            let (store, board) = store([])
            let (drawer, magnet, _, _) = drawerRig(store, appearance: NSAppearance(named: theme))
            if !drawer.handleDrawerKey(key(34, [], "i")) { drawer.browser.canvas.keyDown(with: key(34, [], "i")) }
            guard let carousel = magnet.drawerCarousel else { fatalError("FAIL: Quick Look opens turned in \(theme.rawValue)") }
            carousel.layoutSubtreeIfNeeded()
            let html = ClipboardRawData(entry: store.entries[0]).flavors.first { $0.type == .html }!
            let box = carousel.raw.contentView(of: html.number)?.superview as? ClipboardSurfaceView
            var expected: CGColor?
            NSAppearance(named: theme)!.performAsCurrentDrawingAppearance { expected = NSColor.textBackgroundColor.cgColor }
            let ground = box?.layer?.backgroundColor
            check(carousel.showsRawData && ground != nil && expected != nil
                  && zip(ground!.components ?? [], expected!.components ?? []).allSatisfy { abs($0 - $1) < 0.02 },
                  "built in \(theme.rawValue), Quick Look's raw data paints the \(theme.rawValue) text ground")
            check(carousel.raw.effectiveAppearance.name == theme && carousel.flipButton.effectiveAppearance.name == theme,
                  "its raw data and turn button follow the appearance")
            drawer.stop()
            store.stop()
            board.releaseGlobally()
        }
        app.appearance = NSAppearance(named: .aqua)
    }
}

private class TestPanel: NSPanel {
    private var fixtureVisible = false
    /// Whether it says it holds the keyboard; both a drawer's and Quick Look's do unless a check says otherwise.
    var keyed = true
    override var isVisible: Bool { fixtureVisible }
    override var isKeyWindow: Bool { keyed }
    override var canBecomeKey: Bool { true }
    override func orderFrontRegardless() { fixtureVisible = true }
    override func makeKeyAndOrderFront(_ sender: Any?) { fixtureVisible = true }
    override func orderOut(_ sender: Any?) { fixtureVisible = false }
    override func makeKey() {}
    override func resignKey() {}
}
