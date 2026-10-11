import AppKit

@main enum DrawerPreviewTests {
    private static var assertions = 0
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError("FAIL: \(message)") }
    }
    static func main() {
        _ = NSApplication.shared
        for screen in [NSRect(x: 0, y: 40, width: 1440, height: 860),
                       NSRect(x: -1920, y: -200, width: 1920, height: 1200),
                       NSRect(x: 1500, y: 400, width: 800, height: 600)] {
            for edge in ClipboardDockEdge.allCases {
                for center in [0.0, 0.5, 1.0] {
                    let dock = ClipboardTabGeometry.layout(placement: ClipboardTabPlacement(edge: edge, center: center), in: screen)
                    let anchor = ClipboardDrawerPreviewAnchor(drawer: dock.expandedFrame, screen: screen, edge: edge)
                    check(screen.contains(anchor.frame) && !anchor.frame.isEmpty, "preview fits display at \(edge), \(center)")
                    check(!anchor.frame.intersects(dock.expandedFrame), "preview never covers drawer or tab at \(edge)")
                    let point = NSPoint(x: edge == .right ? anchor.frame.maxX + 4 : anchor.frame.minX - 4, y: anchor.frame.midY)
                    check(anchor.contains(point), "preview boundary includes traversable gap")
                }
            }
        }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let store = ClipboardStore(pasteboard: board, persistenceURL: nil)
        for text in ["Forest", "Ocean", "Sunset"] {
            board.clearContents(); board.setString(text, forType: .string); _ = store.saveNow()
        }
        store.cancelStaging()
        let panel = PreviewTestPanel(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        let drawerPanel = PreviewTestPanel(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        let magnet = ClipboardMagnetController(panel: panel, commandClickEnabled: false)
        let drawer = ClipboardDrawerController(store: store, magnetController: magnet, panel: drawerPanel, defaults: nil)
        defer { drawer.stop(); store.stop() }
        let entries = store.entries, order = entries.map(\.id)
        drawer.show(on: NSScreen.main!)
        drawer.browser.canvas.tiles[1].onHover?()
        check(store.stagedEntryID == nil && magnet.presentation == .hidden, "hover alone never activates or stages preview")
        let infoSize = NSSize(width: 360, height: 300), hoveredTile = drawer.browser.canvas.tiles[1]
        let card = drawerPanel.convertToScreen(hoveredTile.convert(hoveredTile.bounds, to: nil))
        if let info = ClipboardTileTooltip.shared.plannedFrame(for: hoveredTile, size: infoSize), let body = drawer.bodyFrame {
            check(!info.intersects(card) && !info.intersects(body), "a card's info opens beside the drawer, covering nothing in it")
            check(info.minY <= card.midY && info.maxY >= card.midY, "a card's info opens level with its card")
        } else { check(false, "a card's info has a place while the drawer is open") }
        drawer.browser.canvas.onPreview?(entries[1])
        check(magnet.drawerAnchor != nil && store.stagedEntryID == entries[1].id, "Space target opens drawer-anchored preview")
        check(ClipboardTileTooltip.shared.plannedFrame(for: hoveredTile, size: infoSize) == nil, "while Quick Look fills that room, a card's info waits")
        let originalFrame = magnet.frame
        let view = panel.contentView as! ClipboardCarouselView
        drawer.browser.canvas.tiles[2].onHover?()
        check(store.stagedEntryID == entries[2].id && view.entryID == entries[2].id, "hover updates clipboard and visible preview together")
        check(panel.contentView === view && magnet.frame == originalFrame, "hover retains remote view and stable drawer anchor")
        check(store.liftedEntryID == nil && store.entries.map(\.id) == order, "hover does not lift a slot or reorder history")
        let revision = board.changeCount
        drawer.browser.canvas.tiles[2].onHover?()
        check(board.changeCount == revision, "repeat hover on same card does not restage")
        check(drawer.contains(NSPoint(x: originalFrame.midX, y: originalFrame.midY)), "preview controls count as inside drawer")
        let settings = ClipboardRevealSettings(defaults: nil)
        settings.dismissalDelaySeconds = 0
        let edge = EdgeController(drawerController: drawer, settings: settings)
        edge.samplePointer(at: NSPoint(x: originalFrame.midX, y: originalFrame.midY))
        check(drawer.isVisible, "zero close delay still permits preview controls")
        drawer.hide(animated: false)
        check(magnet.presentation == .carousel && store.stagedEntryID == entries[2].id, "closing drawer retains item in medium cursor magnet")
        check(magnet.frame.width <= 420, "medium retains its size cap")
        drawer.browser.onHover?(entries[0])
        check(store.stagedEntryID == entries[2].id, "hidden drawer ignores stale hover callbacks")
        drawer.show(on: NSScreen.main!)
        check(magnet.drawerAnchor != nil && magnet.frame == originalFrame, "reopening reattaches preview to drawer")
        drawer.browser.canvas.onPreview?(entries[2])
        drawer.browser.onHover?(entries[1])
        check(store.stagedEntryID == nil && board.string(forType: .string) == "Sunset", "Space closes; hover during return animation cannot revive it")
        check(store.entries.map(\.id) == order, "whole preview sequence preserves order")
        drawer.browser.canvas.onPick?(entries[1])
        check(magnet.presentation == .small && store.liftedEntryID == entries[1].id, "pickup keeps small cursor anchor")
        drawer.browser.onHover?(entries[0])
        check(store.stagedEntryID == entries[1].id && magnet.presentation == .small, "hover cannot replace a picked-up item")
        store.cancelStaging()
        drawer.browser.canvas.onPreview?(entries[0])
        store.commitStagedPaste()
        drawer.browser.onHover?(entries[1])
        check(store.stagedEntryID == nil, "hover cannot revive consumed preview during paste animation")
        ClipboardDemo.seed(store, board: board)
        drawer.browser.tabs.selectedSegment = 1
        drawer.browser.update(entries: store.entries, attachedID: nil)
        let imageTiles = drawer.browser.canvas.tiles
        drawer.browser.canvas.onPreview?(imageTiles[0].entry)
        imageTiles[1].onHover?()
        check(store.stagedEntryID == imageTiles[1].entry.id && magnet.drawerAnchor != nil, "Images grid follows hover through same preview route")
        check(drawer.browser.canvas.tiles.filter(\.isChosen).count == 1, "live grid preview preserves one selection")
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let tab = descendants(drawerPanel.contentView!).compactMap { $0 as? ClipboardTabView }.first!
        let screen = NSScreen.main!.visibleFrame
        let retainedEntry = store.stagedEntryID
        tab.onInteractionBegan?(NSPoint(x: drawer.tabFrame!.midX, y: drawer.tabFrame!.midY))
        tab.onDrag?(NSPoint(x: screen.minX, y: screen.midY))
        check(drawer.tabPlacement.edge == .left && magnet.drawerAnchor?.edge == .left, "dragging moves the large anchor to the new edge")
        check(store.stagedEntryID == retainedEntry && !magnet.frame.intersects(drawer.bodyFrame!), "docking preserves previewed item without covering drawer")
        tab.onInteractionEnded?()
        magnet.onCancel?()
        drawer.browser.onHover?(imageTiles[0].entry)
        check(store.stagedEntryID == nil, "Escape or close prevents later hover reactivation")
        drawerOpeningChecks()
        searchUndoChecks()
        print("PASS: \(assertions) drawer-preview geometry/hover/lifecycle/opening assertions; named board, no input injection")
    }

    /// Every opening clears the drawer's search and chooses the newest entry in
    /// the tab it had (Al, 2026-10-10: a search left from before hid what he had
    /// just copied). Clearing happens as it opens, so nothing moves while it is open.
    private static func drawerOpeningChecks() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let store = ClipboardStore(pasteboard: board, persistenceURL: nil)
        func copy(_ text: String) { board.clearContents(); board.setString(text, forType: .string); _ = store.saveNow(); store.cancelStaging() }
        ["Forest walk", "Ocean swim", "Sunset walk"].forEach(copy)
        let magnet = ClipboardMagnetController(panel: PreviewTestPanel(contentRect: .zero, styleMask: [], backing: .buffered, defer: true),
                                               commandClickEnabled: false)
        let drawer = ClipboardDrawerController(store: store, magnetController: magnet,
                                               panel: PreviewTestPanel(contentRect: .zero, styleMask: [], backing: .buffered, defer: true),
                                               defaults: nil)
        defer { drawer.stop(); store.stop() }
        let browser = drawer.browser, search = browser.search
        func type(_ query: String) { search.stringValue = query; browser.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification)) }
        drawer.show(on: NSScreen.main!)
        browser.tabs.selectedSegment = ClipboardBrowserTab.text.rawValue
        browser.tabs.sendAction(browser.tabs.action!, to: browser.tabs.target)
        type("walk")
        let forest = store.entries.first { $0.title == "Forest walk" }!
        browser.canvas.choose(forest.id)
        check(browser.visibleEntries.map(\.title) == ["Sunset walk", "Forest walk"] && browser.canvas.selectedID == forest.id,
              "a search narrows the open drawer and an older match can be chosen")
        drawer.show(on: NSScreen.main!)
        check(search.stringValue == "walk" && browser.canvas.selectedID == forest.id, "an open that never closed keeps the search and the choice")
        browser.canvas.onPick?(forest)
        store.cancelStaging()
        drawer.hide(animated: false)
        copy("Harbor swim")
        let harbor = store.entries[0]
        drawer.show(on: NSScreen.main!)
        check(search.stringValue.isEmpty && browser.currentTab == .text, "reopening clears the search and keeps the tab")
        check(browser.visibleEntries.count == store.entries.filter { ClipboardBrowserTab.text.includes($0) }.count &&
              browser.visibleEntries.first === harbor && browser.canvas.selectedID == harbor.id,
              "the copy made while it was closed shows, newest and chosen")
        browser.canvas.choose(forest.id)
        drawer.hide(animated: false)
        drawer.show(on: NSScreen.main!)
        check(browser.canvas.selectedID == store.entries[0].id, "each opening chooses the newest entry, as the window does")

        let sunset = store.entries.first { $0.title == "Sunset walk" }!

        // Settings › Cursor magnets › From the drawer.
        drawer.pickupMagnet = { false }
        let ocean = store.entries.first { $0.title == "Ocean swim" }!
        drawer.browser.canvas.onPick?(ocean)
        check(store.stagedEntryID == nil && store.entries.first === ocean && board.string(forType: .string) == "Ocean swim",
              "with From the drawer off, picking a tile puts it on the clipboard and at the top, holding nothing")
        drawer.pickupMagnet = { true }
        drawer.browser.canvas.onPick?(forest)
        check(store.stagedEntryID == forest.id && store.heldMagnetSource == .drawer, "with From the drawer on, picking a tile holds it as before")
        drawer.releaseMagnet { $0 != .window }
        check(store.stagedEntryID == forest.id, "turning off another choice leaves the held tile alone")
        drawer.releaseMagnet { $0 != .drawer }
        check(store.stagedEntryID == nil && magnet.presentation == .hidden && board.string(forType: .string) == "Forest walk",
              "turning From the drawer off lets go of the tile, leaving it on the clipboard")

        // A Quick Look preview turns into a magnet when the drawer is touched; with drawer magnets off it closes.
        drawer.browser.canvas.onPreview?(sunset)
        check(magnet.isQuickLook && store.stagedEntryID == sunset.id, "Space on a tile opens Quick Look")
        drawer.pickupMagnet = { false }
        drawer.browser.onInteraction?()
        check(store.stagedEntryID == nil && magnet.presentation != .small && board.string(forType: .string) == "Forest walk",
              "with From the drawer off, touching the drawer closes the preview and gives back the clipboard")
        drawer.pickupMagnet = { true }
        drawer.browser.canvas.onPreview?(sunset)
        drawer.browser.onInteraction?()
        check(store.stagedEntryID == sunset.id && magnet.presentation == .small, "with it on, the preview turns into a magnet as before")
        store.cancelStaging()

        // A copy made elsewhere while Quick Look is open is never overwritten by the old clipboard.
        for magnetsOn in [false, true] {
            drawer.pickupMagnet = { magnetsOn }
            drawer.browser.canvas.onPreview?(sunset)
            board.clearContents(); board.setString("Fresh copy \(magnetsOn)", forType: .string); _ = store.saveNow()
            check(board.string(forType: .string) == "Fresh copy \(magnetsOn)" && store.entries.first?.title == "Fresh copy \(magnetsOn)",
                  "a copy made while Quick Look is open stays on the clipboard (drawer magnets \(magnetsOn ? "on" : "off"))")
            store.cancelStaging()
        }
        drawer.pickupMagnet = { true }
    }
}

extension DrawerPreviewTests {
    /// Typing left in the search when the drawer closed is not undone against the next
    /// opening's empty search, which threw NSRangeException. The real window class,
    /// isolated, since its field editor shares the window's undo.
    static func searchUndoChecks() {
        let marker = "CLIPEDGE_TEST_PREVIEW_ROOT", previous = ProcessInfo.processInfo.environment[marker]
        setenv(marker, FileManager.default.temporaryDirectory.appendingPathComponent("ClipEdge-drawer-undo-\(UUID().uuidString)").path, 1)
        defer { if let previous { setenv(marker, previous, 1) } else { unsetenv(marker) } }
        let board = NSPasteboard.withUniqueName()
        let store = ClipboardStore(pasteboard: board, persistenceURL: nil)
        for text in ["Forest walk", "Ocean swim"] { board.clearContents(); board.setString(text, forType: .string); _ = store.saveNow(); store.cancelStaging() }
        let drawer = ClipboardDrawerController(store: store, defaults: nil)
        defer { drawer.stop(); store.stop(); board.releaseGlobally() }
        let browser = drawer.browser
        guard let panel = browser.window else { fatalError("FAIL: the drawer holds its browser") }
        drawer.show(on: NSScreen.main!)
        browser.focusSearch()
        (panel.firstResponder as? NSTextView)?.insertText("walk", replacementRange: NSRange(location: NSNotFound, length: 0))
        // Undo groups typing by run-loop pass; run one so the typing is a finished step.
        RunLoop.current.add(Timer(timeInterval: 0.01, repeats: false) { _ in }, forMode: .default)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        check(browser.search.stringValue == "walk" && panel.undoManager?.canUndo == true, "typing in the drawer's search can be undone while it is open")
        drawer.hide(animated: false)
        drawer.show(on: NSScreen.main!)
        browser.focusSearch()
        check(browser.search.stringValue.isEmpty && panel.undoManager?.canUndo == false, "reopening leaves no undo that would bring back an old search")
        let undo = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
                                    characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6)!
        check(panel.performKeyEquivalent(with: undo) && browser.search.stringValue.isEmpty, "⌘Z then leaves the empty search as it is")
        drawer.hide(animated: false)
    }
}

private final class PreviewTestPanel: NSPanel {
    private var fixtureVisible = false
    override var isVisible: Bool { fixtureVisible }
    override func orderFrontRegardless() { fixtureVisible = true }
    override func orderOut(_ sender: Any?) { fixtureVisible = false }
    override func makeKey() {}
    override func resignKey() {}
}
