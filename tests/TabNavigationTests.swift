import AppKit

@main enum TabNavigationTests {
    private static var assertions = 0
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError("FAIL: \(message)") }
    }
    static func main() {
        _ = NSApplication.shared
        let board = NSPasteboard.withUniqueName()
        let store = ClipboardStore(pasteboard: board, persistenceURL: nil)
        ClipboardDemo.seed(store, board: board)
        for text in ["Trip: pack a notebook", "Trip: book a room"] {
            board.clearContents(); board.setString(text, forType: .string); _ = store.saveNow()
        }
        store.cancelStaging()
        let originalText = board.string(forType: .string), originalOrder = store.entries.map(\.id)
        let panel = NavigationTestPanel(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        let preview = NavigationTestPanel(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        let magnet = ClipboardMagnetController(panel: preview, commandClickEnabled: false)
        let drawer = ClipboardDrawerController(store: store, magnetController: magnet, panel: panel, defaults: nil)
        defer { drawer.stop(); store.stop(); board.releaseGlobally() }
        let browser = drawer.browser
        // The pointer moves onto every card it hovers.
        var moved = 0.0
        browser.canvas.pointer = { moved += 1; return NSPoint(x: moved, y: 0) }
        drawer.show(on: NSScreen.main!)
        func tab(_ index: Int) {
            browser.tabs.selectedSegment = index
            browser.tabs.sendAction(browser.tabs.action!, to: browser.tabs.target)
        }
        func search(_ query: String) {
            browser.search.stringValue = query
            browser.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        }
        func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = [], repeat repeating: Bool = false) -> Bool {
            drawer.handleDrawerKey(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: 0, context: nil, characters: code == 49 ? " " : "", charactersIgnoringModifiers: "", isARepeat: repeating, keyCode: code)!)
        }
        func matches(_ entry: ClipboardEntry, index: Int, count: Int) -> Bool {
            store.stagedEntryID == entry.id && store.carouselPosition?.index == index && store.carouselPosition?.count == count &&
            browser.canvas.selectedID == entry.id && (preview.contentView as? ClipboardCarouselView)?.entryID == entry.id && magnet.drawerAnchor != nil
        }
        check(!key(124), "without Quick Look, arrows retain ordinary canvas navigation")
        tab(ClipboardBrowserTab.images.rawValue)
        let images = browser.visibleEntries
        check(images.count == 3, "fixture has three image cards")
        check(key(49) && matches(images[0], index: 0, count: 3), "Space starts at visible selection, with filtered count")
        check(key(123) && matches(images[2], index: 2, count: 3), "Left wraps within Images, not to a text clip")
        check(key(124) && matches(images[0], index: 0, count: 3), "Right wraps within Images")
        check(key(125) && matches(images[1], index: 1, count: 3), "Down advances preview in reading order")
        check(key(126) && matches(images[0], index: 0, count: 3), "Up moves preview backwards")
        check(key(124, repeat: true) && matches(images[1], index: 1, count: 3), "held arrows continue browsing")
        check(!key(124, modifiers: .command) && store.stagedEntryID == images[1].id, "modified arrows are not stolen")
        (preview.contentView as! ClipboardCarouselView).onNavigate?(1)
        check(matches(images[2], index: 2, count: 3), "preview button uses same filtered sequence")
        drawer.quickLookNext()
        check(matches(images[0], index: 0, count: 3), "global shortcut inside drawer uses current tab")
        browser.canvas.tiles[1].onHover?()
        check(matches(images[1], index: 1, count: 3), "hover preserves filtered sequence")
        tab(ClipboardBrowserTab.text.rawValue)
        let text = browser.visibleEntries
        check(text.count == 3 && matches(text[0], index: 0, count: 3), "switching to Text keeps preview open on first text clip")
        check(key(123) && matches(text[2], index: 2, count: 3), "Text wraps without images")
        search("Trip")
        let trips = browser.visibleEntries
        check(trips.count == 2 && matches(trips[0], index: 0, count: 2), "search rebases visible preview and counter")
        check(key(126) && matches(trips[1], index: 1, count: 2), "filtered Text wraps through search matches only")
        search("notebook")
        check(matches(trips[1], index: 0, count: 1), "narrowing search retains a matching preview")
        check(key(124) && matches(trips[1], index: 0, count: 1), "one result stays selected")
        let editor = NSTextView()
        panel.contentView?.addSubview(editor); panel.makeFirstResponder(editor)
        check(!key(123) && !key(49), "search/editor retains arrows and Space")
        panel.makeFirstResponder(browser.canvas); editor.removeFromSuperview()
        search("no-matching-card")
        check(store.stagedEntryID == nil && store.carouselPosition == nil, "empty search closes preview without a hidden selected item")
        check(!key(49) && !key(124), "empty list does not revive preview")
        search(""); tab(0)
        check(key(49) && store.carouselPosition?.count == 6, "All restores full history scope")
        tab(ClipboardBrowserTab.images.rawValue)
        drawer.hide(animated: false)
        check(magnet.presentation == .carousel && store.carouselPosition?.count == 6, "closed drawer restores full-history medium carousel")
        drawer.show(on: NSScreen.main!)
        check(store.carouselPosition?.count == 3 && magnet.drawerAnchor != nil, "reopening reapplies Images scope")
        check(key(49, repeat: true) && magnet.isQuickLook, "Space autorepeat does not close preview")
        check(key(49) && store.stagedEntryID == nil, "second Space closes current preview")
        check(board.string(forType: .string) == originalText && store.entries.map(\.id) == originalOrder, "navigation/filtering restores clipboard and never reorders")
        tab(ClipboardBrowserTab.text.rawValue)
        drawer.quickLookNext()
        check(store.carouselPosition?.count == 3 && store.stagedEntryID == browser.canvas.selectedID, "global shortcut starts Text preview without Space")
        _ = browser.canvas.answer(.primary, browser.visibleEntries[1])
        let lifted = store.liftedEntryID
        tab(ClipboardBrowserTab.images.rawValue)
        check(store.liftedEntryID == lifted && magnet.presentation == .small, "tab changes do not replace a picked-up payload")
        testSingleKeys()
        testKeymapIsTheSource()
        testNonLatinLayouts()
        testStillPointer()
        print("PASS: \(assertions) tab/navigation assertions; named board, no input injection")
    }

    /// The drawer's single keys, through its panel as the keyboard delivers them: from the cards,
    /// 0–3 choose a tab and / puts the keyboard in the search, text selected; there, 1 and / are text.
    /// The tabs show their keys in full at the drawer's width. The history window keeps ⌘0–⌘3 and ⌘F.
    private static func testSingleKeys() {
        let board = NSPasteboard.withUniqueName()
        let store = ClipboardStore(pasteboard: board, persistenceURL: nil)
        ClipboardDemo.seed(store, board: board)
        // Enough text copies that the list scrolls well past one screen.
        for i in 0..<30 { board.clearContents(); board.setString("Review note \(i)", forType: .string); _ = store.saveNow() }
        store.cancelStaging()
        let panel = NavigationTestPanel(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        let magnet = ClipboardMagnetController(panel: NavigationTestPanel(contentRect: .zero, styleMask: [], backing: .buffered, defer: true), commandClickEnabled: false)
        let drawer = ClipboardDrawerController(store: store, magnetController: magnet, panel: panel, defaults: nil)
        defer { drawer.stop(); store.stop(); board.releaseGlobally() }
        let browser = drawer.browser
        drawer.show(on: NSScreen.main!)
        panel.contentView?.layoutSubtreeIfNeeded()
        func press(_ characters: String, _ code: UInt16, _ modifiers: NSEvent.ModifierFlags = []) {
            panel.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: panel.windowNumber,
                                             context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!)
        }
        let labels = browser.tabs.titles.map(\.plain)
        check(labels == ["All 0", "Text 1", "Images 2", "Other 3"], "the drawer's tabs read their keys: \(labels)")
        let spoken = (0..<browser.tabs.segmentCount).map { browser.tabs.label(forSegment: $0)! }
        check(spoken == ["All, 0", "Text, 1", "Images, 2", "Other, 3"], "VoiceOver reads each tab's name, then its key: \(spoken)")
        check(browser.tabs.fittingSize.width <= browser.tabs.frame.width && browser.tabs.frame.maxX + 8 <= browser.selectButton.frame.minX,
              "every tab's name and key cap fits whole at the drawer's width (\(browser.tabs.fittingSize.width) of \(browser.tabs.frame.width) points)")
        panel.makeFirstResponder(browser.canvas)
        for (character, code, tab) in [("2", UInt16(19), ClipboardBrowserTab.images), ("3", 20, .other), ("1", 18, .text), ("0", 29, .all)] {
            press(character, code)
            check(browser.currentTab == tab && panel.firstResponder === browser.canvas, "\(character) from the cards shows \(tab.title), and the cards keep the keyboard")
        }
        // A number key keeps the chosen card where it is still listed, and shows it, so Return or ⌫ acts on a card in view.
        let far = browser.canvas.tiles.last { ClipboardBrowserTab.text.includes($0.entry) }!
        browser.canvas.choose(far.entry.id)
        press("1", 18)
        check(browser.canvas.selectedID == far.entry.id && browser.canvas.visibleRect.contains(far.frame),
              "1 keeps a text card far down the list chosen, and in view (\(far.frame) in \(browser.canvas.visibleRect))")
        press("0", 29)
        check(browser.canvas.selectedID == far.entry.id && browser.canvas.visibleRect.contains(far.frame), "and 0 back to All keeps it in view")
        browser.search.stringValue = "pack"
        press("/", 44)
        let editor = panel.firstResponder as? NSTextView
        check(editor?.delegate === browser.search && editor?.selectedRange() == NSRange(location: 0, length: 4), "/ puts the keyboard in the search with its text selected")
        press("1", 18); press("/", 44); press(",", 43); press("3", 20)
        check(browser.search.stringValue == "1/,3" && browser.currentTab == .all && panel.firstResponder === editor, "in the search, 1, /, \",\" and 3 are text")
        panel.makeFirstResponder(browser.canvas)
        press("f", 3, .command)
        check((panel.firstResponder as? NSTextView)?.delegate === browser.search, "⌘F still goes to the search")
        // The history window's search always holds the keyboard: a bare 1 or f is text there; ⌘0–⌘3 and ⌘F act.
        func command(_ characters: String, _ code: UInt16, _ modifiers: NSEvent.ModifierFlags) -> ClipboardBrowserAction? {
            ClipboardKeymap.window.action(for: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                                                                  characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!)
        }
        check(command("1", 18, []) == nil && command("f", 3, []) == nil && command(",", 43, []) == nil, "in the history window, 1, f and \",\" are typing")
        check(command("0", 29, .command) == .tab(.all) && command("3", 20, .command) == .tab(.other) && command("f", 3, .command) == .find, "and ⌘0–⌘3 and ⌘F act")
    }
}

extension TabNavigationTests {
    /// Cards that appear or move under a still pointer never take the selection from the keyboard,
    /// in the drawer as in the window (Al, 2026-10-11: one rule, both containers).
    static func testStillPointer() {
        let board = NSPasteboard.withUniqueName()
        let store = ClipboardStore(pasteboard: board, persistenceURL: nil)
        ClipboardDemo.seed(store, board: board)
        for text in ["Trip: pack a notebook", "Trip: book a room"] { board.clearContents(); board.setString(text, forType: .string); _ = store.saveNow() }
        store.cancelStaging()
        let panel = NavigationTestPanel(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        let magnet = ClipboardMagnetController(panel: NavigationTestPanel(contentRect: .zero, styleMask: [], backing: .buffered, defer: true), commandClickEnabled: false)
        let drawer = ClipboardDrawerController(store: store, magnetController: magnet, panel: panel, defaults: nil)
        defer { drawer.stop(); store.stop(); board.releaseGlobally() }
        let cards = drawer.browser.canvas
        var pointer = NSPoint(x: 200, y: 300)
        cards.pointer = { pointer }
        drawer.show(on: NSScreen.main!)
        panel.makeFirstResponder(cards)
        let newest = cards.selected!.entry
        cards.tiles[3].onHover?()
        check(cards.selected?.entry === newest, "a card under the resting pointer does not take the newest card's place as the drawer opens")
        func press(_ code: UInt16) {
            cards.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                 characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!)
        }
        press(125); press(125)
        let stepped = cards.selected!.entry
        cards.tiles[5].onHover?()
        check(cards.selected?.entry === stepped, "the arrow keys' choice stays under a still pointer")
        drawer.browser.search.stringValue = "trip"; drawer.browser.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        let kept = cards.selected!.entry
        cards.tiles[1].onHover?()
        check(cards.selected?.entry === kept, "cards a search brings under a still pointer do not take the selection")
        pointer.x += 3
        cards.tiles[1].onHover?()
        check(cards.selected?.entry === cards.tiles[1].entry, "once the pointer moves, hover chooses, as in the window")
    }
    /// One keymap per container is the source of its keys and of every label naming them (Al,
    /// 2026-10-11: one component, many containers, differences only by injection). Every tab, and a
    /// key added to a keymap, reach that container's labels and handling with no other edit.
    static func testKeymapIsTheSource() {
        let board = NSPasteboard.withUniqueName()
        let store = ClipboardStore(pasteboard: board, persistenceURL: nil)
        ClipboardDemo.seed(store, board: board)
        store.cancelStaging()
        defer { store.stop(); board.releaseGlobally() }
        func event(_ characters: String, _ code: UInt16, _ modifiers: NSEvent.ModifierFlags = [], in window: NSWindow? = nil) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window?.windowNumber ?? 0, context: nil,
                             characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        }
        // One key of each reach, added alike to both keymaps: ⌃G acts anywhere, ⌃J anywhere but a
        // field being typed in, ⌃U only from the cards. Each shows a tab, so what acted is plain.
        let reaches: [(reach: ClipboardKeyReach, code: UInt16, tab: ClipboardBrowserTab)] = [(.anywhere, 5, .text), (.outsideText, 38, .images), (.cards, 32, .other)]
        let reachKeys = reaches.map { ClipboardKeyBinding(.code($0.code), .exactly([.control]), .tab($0.tab), $0.reach) }
        /// The reaches whose key acts with the keyboard where `place` puts it, each delivered as AppKit
        /// delivers it: the container's key monitor first, then the keyboard's holder (only the cards
        /// hold keys of their own, so nothing else is sent it and nothing beeps).
        func acting(_ list: ClipboardBrowserList, monitor: (NSEvent) -> Bool, in window: NSWindow, from place: () -> Void) -> [ClipboardKeyReach] {
            reaches.filter { key in
                list.choose(.all)
                place()
                let press = event("", key.code, .control, in: window)
                if !monitor(press), window.firstResponder === list.canvas { list.canvas.keyDown(with: press) }
                return list.tab == key.tab
            }.map(\.reach)
        }

        // The drawer, given its keymap with one key added: K, a second key for the search.
        let drawerKeys = ClipboardKeymap(bindings: ClipboardKeymap.drawer.bindings + [ClipboardKeyBinding(.character("k"), .exactly([]), .find, .cards, "K")] + reachKeys)
        let panel = NavigationTestPanel(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        let magnet = ClipboardMagnetController(panel: NavigationTestPanel(contentRect: .zero, styleMask: [], backing: .buffered, defer: true), commandClickEnabled: false)
        let drawer = ClipboardDrawerController(store: store, magnetController: magnet, panel: panel, defaults: nil, keymap: drawerKeys)
        defer { drawer.stop() }
        let browser = drawer.browser
        drawer.show(on: NSScreen.main!)
        let drawerLabels = browser.tabs.titles.map(\.plain)
        check(drawerLabels == ClipboardBrowserTab.allCases.map { "\($0.title) \(drawerKeys.label(.tab($0))!)" }, "the drawer's tabs read its keymap's keys: \(drawerLabels)")
        check(browser.search.placeholderHint.plain.hasSuffix("  / or K") && ClipboardTileTooltip.legendText(drawerKeys, asker: nil).contains("Search ← / or K")
              && !browser.canvas.tiles.isEmpty && browser.canvas.tiles.allSatisfy { $0.accessibilityHelp() == ClipboardTileTooltip.legendText(drawerKeys, asker: nil, spoken: true) },
              "a key added to the drawer's keymap is named in its search, its card info and its cards' help")
        for tab in ClipboardBrowserTab.allCases.reversed() {
            panel.makeFirstResponder(browser.canvas)
            panel.sendEvent(event(tab.numberKey, tab.keyCodes.row, in: panel))
            check(browser.currentTab == tab, "\(tab.title)'s key in the drawer's keymap chooses it")
        }
        panel.makeFirstResponder(browser.canvas)
        panel.sendEvent(event("k", 40, in: panel))
        check((panel.firstResponder as? NSTextView)?.delegate === browser.search, "and K, added to the drawer's keymap, puts the keyboard in the search")
        let inDrawerSearch = acting(browser.list, monitor: drawer.handleDrawerKey, in: panel) { browser.list.focusSearch(selectingAll: false) }
        check(inDrawerSearch == [.anywhere], "from the drawer's search, only the key that acts anywhere acts (\(inDrawerSearch))")
        let offDrawerFields = acting(browser.list, monitor: drawer.handleDrawerKey, in: panel) { panel.makeFirstResponder(nil) }
        check(offDrawerFields == [.anywhere, .outsideText], "with the keyboard in neither its search nor its cards, the drawer answers the keys outside text too (\(offDrawerFields))")
        let onDrawerCards = acting(browser.list, monitor: drawer.handleDrawerKey, in: panel) { panel.makeFirstResponder(browser.canvas) }
        check(onDrawerCards == [.anywhere, .outsideText, .cards], "and from its cards, every reach (\(onDrawerCards))")
        drawer.hide(animated: false)

        // The window, given its keymap with one key added: ⌘Y, a second key for Open in Preview.
        let windowKeys = ClipboardKeymap(bindings: ClipboardKeymap.window.bindings
            + [ClipboardKeyBinding(.character("y"), .exactly([.command]), .open, .anywhere, "⌘Y", spoken: "Command-Y")] + reachKeys)
        let windowPanel = KeymapTestPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 470), styleMask: [], backing: .buffered, defer: true)
        let history = ClipboardHistoryController(store: store, paster: ClipboardPaster(store: store, environment: .inert),
                                                 previewService: drawer.previewService, panel: windowPanel, keymap: windowKeys)
        var opened: [UUID] = []
        history.prepare = { nil }
        history.openInPreview = { entry, done in opened.append(entry.id); done(nil) }
        history.hotKeyPressed()
        let windowLabels = history.view.tabs.titles.map(\.plain)
        check(windowLabels == ClipboardBrowserTab.allCases.map { "\($0.title) \(windowKeys.label(.tab($0))!)" }, "the window's tabs read its keymap's keys: \(windowLabels)")
        check(history.view.footer.items.contains { $0.title == "Open in Preview ⌘O or ⌘Y" && $0.help == "Open in the Preview app (Command-O or Command-Y)" },
              "a key added to the window's keymap is named on its footer button")
        for tab in ClipboardBrowserTab.allCases.reversed() {
            check(history.handleKey(event(tab.numberKey, tab.keyCodes.row, .command)) && history.view.currentTab == tab, "\(tab.title)'s key in the window's keymap chooses it")
        }
        let list = history.view.list
        let inWindowSearch = acting(list, monitor: history.handleKey, in: windowPanel) { list.focusHome(in: windowPanel) }
        check(inWindowSearch == [.anywhere], "from the window's search, only the key that acts anywhere acts, as in the drawer's (\(inWindowSearch))")
        let offWindowFields = acting(list, monitor: history.handleKey, in: windowPanel) { windowPanel.makeFirstResponder(nil) }
        check(offWindowFields == [.anywhere, .outsideText], "with the keyboard in no field, the keys outside text act too, as in the drawer (\(offWindowFields))")
        check(!list.canvas.acceptsFirstResponder, "the window's rows never hold the keyboard, so the cards' own keys never act there")
        list.focusHome(in: windowPanel)
        let chosen = history.selectedEntry!
        check(history.handleKey(event("y", 16, .command)) && opened == [chosen.id] && !history.isVisible, "and ⌘Y, added to the window's keymap, opens the selection in Preview")
    }
}

extension TabNavigationTests {
    /// On a layout without Latin letters (Russian, Greek, Hebrew), each letter chord in both
    /// containers' keymaps is the key in its letter's place, as the drawer's F always was; a Latin
    /// layout still goes by the letter it types, so Dvorak's ⌘C is the key that types c.
    static func testNonLatinLayouts() {
        func press(_ typed: String, _ code: UInt16, _ modifiers: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                             characters: typed, charactersIgnoringModifiers: typed, isARepeat: false, keyCode: code)!
        }
        // What each layout types at A's, C's, F's and O's places.
        let layouts: [(name: String, a: String, c: String, f: String, o: String)] = [
            ("Russian", "ф", "с", "а", "щ"), ("Greek", "α", "ψ", "φ", "ο"), ("Hebrew", "ש", "ב", "כ", "ם")
        ]
        for layout in layouts {
            let window = ClipboardKeymap.window, drawer = ClipboardKeymap.drawer
            check(window.action(for: press(layout.f, 3, .command)) == .find, "\(layout.name): the window's ⌘F")
            check(window.action(for: press(layout.c, 8, .command)) == .pickUp, "\(layout.name): the window's ⌘C")
            check(window.action(for: press(layout.o, 31, .command)) == .open, "\(layout.name): the window's ⌘O")
            check(window.action(for: press(layout.a, 0, [.option, .command])) == .ask, "\(layout.name): the window's ⌥⌘A")
            check(drawer.action(for: press(layout.o, 31, .command)) == .open, "\(layout.name): the drawer's ⌘O")
            check(drawer.action(for: press(layout.a, 0, [.option, .command])) == .ask, "\(layout.name): the drawer's ⌥⌘A")
            check(drawer.action(for: press("/", 44, [])) == .find && drawer.action(for: press(layout.f, 3, .command)) == .find, "\(layout.name): the drawer's / and ⌘F")
        }
        // Dvorak types j at C's place and c at I's: the letter typed decides.
        check(ClipboardKeymap.window.action(for: press("j", 8, .command)) == nil && ClipboardKeymap.window.action(for: press("c", 34, .command)) == .pickUp,
              "on a Latin layout the letter typed decides, wherever its key is")

        // Through the window itself, as the keyboard delivers them.
        let board = NSPasteboard.withUniqueName()
        let store = ClipboardStore(pasteboard: board, persistenceURL: nil)
        defer { store.stop(); board.releaseGlobally() }
        for text in ["Alder", "Birch"] { board.clearContents(); board.setString(text, forType: .string); _ = store.saveNow(); store.cancelStaging() }
        let panel = KeymapTestPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 470), styleMask: [], backing: .buffered, defer: true)
        let history = ClipboardHistoryController(store: store, paster: ClipboardPaster(store: store, environment: .inert),
                                                 previewService: ClipboardPreviewService(), panel: panel)
        var opened: [UUID] = []
        history.prepare = { nil }
        history.openInPreview = { entry, done in opened.append(entry.id); done(nil) }
        history.hotKeyPressed()
        history.view.search.stringValue = "a"
        check(history.handleKey(press("а", 3, .command)) && history.view.search.currentEditor()?.selectedRange == NSRange(location: 0, length: 1),
              "Russian ⌘F in the window selects the search's text")
        let chosen = history.selectedEntry!
        check(history.handleKey(press("щ", 31, .command)) && opened == [chosen.id] && !history.isVisible, "and Russian ⌘O opens the selection in Preview")
    }
}

private final class KeymapTestPanel: NSPanel {
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

private final class NavigationTestPanel: NSPanel {
    private var fixtureVisible = false
    override var isVisible: Bool { fixtureVisible }
    override var isKeyWindow: Bool { true }
    override func orderFrontRegardless() { fixtureVisible = true }
    override func orderOut(_ sender: Any?) { fixtureVisible = false }
    override func makeKey() {}
    override func resignKey() {}
}
