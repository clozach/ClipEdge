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
        drawer.browser.canvas.onPreview?(entries[1])
        check(magnet.drawerAnchor != nil && store.stagedEntryID == entries[1].id, "Space target opens drawer-anchored preview")
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
        print("PASS: \(assertions) drawer-preview geometry/hover/lifecycle assertions; named board, no input injection")
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
