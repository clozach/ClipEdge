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
        drawer.show(on: NSScreen.main!)
        func tab(_ index: Int) {
            browser.tabs.selectedSegment = index
            browser.tabs.sendAction(browser.tabs.action!, to: browser.tabs.target)
        }
        func search(_ query: String) {
            browser.search.stringValue = query
            browser.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
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
        tab(1)
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
        tab(2)
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
        tab(1)
        drawer.hide(animated: false)
        check(magnet.presentation == .carousel && store.carouselPosition?.count == 6, "closed drawer restores full-history medium carousel")
        drawer.show(on: NSScreen.main!)
        check(store.carouselPosition?.count == 3 && magnet.drawerAnchor != nil, "reopening reapplies Images scope")
        check(key(49, repeat: true) && magnet.isQuickLook, "Space autorepeat does not close preview")
        check(key(49) && store.stagedEntryID == nil, "second Space closes current preview")
        check(board.string(forType: .string) == originalText && store.entries.map(\.id) == originalOrder, "navigation/filtering restores clipboard and never reorders")
        tab(2)
        drawer.quickLookNext()
        check(store.carouselPosition?.count == 3 && store.stagedEntryID == browser.canvas.selectedID, "global shortcut starts Text preview without Space")
        browser.canvas.onPick?(browser.visibleEntries[1])
        let lifted = store.liftedEntryID
        tab(1)
        check(store.liftedEntryID == lifted && magnet.presentation == .small, "tab changes do not replace a picked-up payload")
        print("PASS: \(assertions) tab/navigation assertions; named board, no input injection")
    }
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
