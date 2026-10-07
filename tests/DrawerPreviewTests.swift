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
        drawerRecallChecks()
        print("PASS: \(assertions) drawer-preview geometry/hover/lifecycle/recall assertions; named board, no input injection")
    }

    /// The drawer keeps its own search across reopening; a use made after it
    /// last closed (in the ⌥⌘\ window, say) replaces it within the minutes.
    private static func drawerRecallChecks() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let store = ClipboardStore(pasteboard: board, persistenceURL: nil)
        for text in ["Forest walk", "Ocean swim", "Sunset walk"] {
            board.clearContents(); board.setString(text, forType: .string); _ = store.saveNow()
        }
        store.cancelStaging()
        var clock = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let memory = ClipboardRecallMemory(minutes: { 5 }, now: { clock })
        let magnet = ClipboardMagnetController(panel: PreviewTestPanel(contentRect: .zero, styleMask: [], backing: .buffered, defer: true),
                                               commandClickEnabled: false)
        let drawer = ClipboardDrawerController(store: store, magnetController: magnet,
                                               panel: PreviewTestPanel(contentRect: .zero, styleMask: [], backing: .buffered, defer: true),
                                               defaults: nil, recall: memory)
        defer { drawer.stop(); store.stop() }
        let search = drawer.browser.search
        drawer.show(on: NSScreen.main!)
        search.stringValue = "walk"; drawer.browser.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        let forest = store.entries.first { $0.title == "Forest walk" }!
        drawer.browser.canvas.onPick?(forest)
        store.cancelStaging()
        check(memory.last?.entryID == forest.id && memory.last?.query == "walk", "picking a tile remembers it and the drawer's search")
        clock += 10; drawer.hide(animated: false)
        search.stringValue = "ocean"; drawer.browser.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        clock += 10; drawer.show(on: NSScreen.main!)
        check(search.stringValue == "ocean", "a use from before the drawer closed never replaces the search it kept")
        clock += 10; drawer.hide(animated: false)
        let sunset = store.entries.first { $0.title == "Sunset walk" }!
        clock += 10; memory.remember(sunset, tab: .text, query: "sunset")
        clock += 10; drawer.show(on: NSScreen.main!)
        check(search.stringValue == "sunset" && drawer.browser.currentTab == .text && drawer.browser.canvas.selected?.entry === sunset,
              "a later use elsewhere reopens the drawer on its tab and search, entry chosen")
        clock += 10; drawer.hide(animated: false)
        clock += 600; memory.remember(forest, tab: .all, query: "forest")
        clock += 301; drawer.show(on: NSScreen.main!)
        check(search.stringValue == "sunset", "an expired use leaves the drawer as it was")

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

private final class PreviewTestPanel: NSPanel {
    private var fixtureVisible = false
    override var isVisible: Bool { fixtureVisible }
    override func orderFrontRegardless() { fixtureVisible = true }
    override func orderOut(_ sender: Any?) { fixtureVisible = false }
    override func makeKey() {}
    override func resignKey() {}
}
