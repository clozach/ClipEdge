import AppKit

/// The deterministic screenplay. Every consequential change follows a measured click
/// or a key event received by the same native handler the application uses.
struct ReadmeStory {
    let drawer: ClipboardDrawerController
    let history: ClipboardHistoryController
    let drawerPanel: NSPanel
    let historyPanel: NSPanel
    let magnet: ClipboardMagnetController
    let store: ClipboardStore
    let board: NSPasteboard
    let image: ClipboardEntry
    let note: ClipboardEntry
    let file: ClipboardEntry
    let photo: Data
    let input: ReadmeInput

    func run() throws -> [String: Any] {
        input.cue("Click Images")
        ReadmeCapture.settle(0.7)
        try clickTab(.images, in: drawer.browser.tabs, label: "Click Images") {
            drawer.browser.currentTab == .images && drawer.browser.visibleEntries.map(\.id) == [image.id]
        }
        try input.key("Space\nPreview the photo", code: 49, modifiers: [], characters: " ", window: drawerPanel,
                      route: "ClipboardDrawerController.handleDrawerKey", hold: 1.7,
                      deliver: drawer.handleDrawerKey) {
            magnet.isQuickLook && store.stagedEntryID == image.id
        }
        try clickTab(.text, in: drawer.browser.tabs, label: "Click Text", hold: 1.8) {
            drawer.browser.currentTab == .text && drawer.browser.visibleEntries.count == 4 && store.stagedEntryID == note.id
        }
        try clickTab(.other, in: drawer.browser.tabs, label: "Click Other", hold: 2.0) {
            drawer.browser.currentTab == .other && drawer.browser.visibleEntries.map(\.id) == [file.id] && store.stagedEntryID == file.id
        }
        let drawerKey = ClipboardShortcut.defaultDrawer
        try input.key("\(drawerKey.displayString)\nClose the drawer", code: UInt16(drawerKey.keyCode), modifiers: drawerKey.modifiers,
                      characters: " ", window: drawerPanel, route: "fixture-local chord → ClipboardDrawerController.toggleFromCommand", hold: 1.0,
                      deliver: { event in
            guard matches(event, drawerKey) else { return false }
            drawer.toggleFromCommand(); return true
        }) { !drawer.isVisible && !drawer.isAnimating }
        let historyKey = ClipboardShortcut.history
        try input.key("\(historyKey.displayString)\nOpen history", code: UInt16(historyKey.keyCode), modifiers: historyKey.modifiers,
                      characters: "\\", window: historyPanel, route: "fixture-local chord → ClipboardHistoryController.hotKeyPressed", hold: 1.5,
                      deliver: { event in
            guard matches(event, historyKey) else { return false }
            history.hotKeyPressed(); return true
        }) { history.isVisible && history.holdsKeyboard && history.visibleEntries.count == 6 }
        try clickTab(.images, in: history.view.tabs, label: "Click Images", hold: 1.6) {
            history.visibleEntries.map(\.id) == [image.id] && history.selectedEntry?.id == image.id
        }
        try input.key("⌘C\nCopy the photo", code: 8, modifiers: [.command], characters: "c", window: historyPanel,
                      route: "ClipboardHistoryController.handleKey", hold: 0.2,
                      deliver: history.handleKey) {
            !history.isVisible && board.data(forType: .png) == photo
        }
        input.cue("Image copied")
        ReadmeCapture.settle(2.0)
        guard let tab = descendants(drawerPanel.contentView!).compactMap({ $0 as? ClipboardTabView }).first else {
            throw NSError(domain: "ReadmeStory", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing native edge tab"])
        }
        try input.click("Click the edge tab", view: tab, hold: 1.1) {
            drawer.isVisible && drawer.openingFraction > 0.99
        }
        try clickTab(.all, in: drawer.browser.tabs, label: "Click All", hold: 1.2) {
            drawer.browser.currentTab == .all && drawer.browser.visibleEntries.count == 6
        }
        input.cue("")
        ReadmeCapture.settle(1.3)
        return ["storySeconds": input.seconds, "copyPNGVerified": board.data(forType: .png) == photo,
                "actionsVerified": input.events.allSatisfy { ($0["verified"] as? Bool) == true && ($0["delivered"] as? Bool) == true }]
    }

    private func clickTab(_ tab: ClipboardBrowserTab, in tabs: ClipboardTabBar, label: String, hold: TimeInterval = 1.2,
                          verify: () -> Bool) throws {
        let index = tab.rawValue
        let leading = (0..<index).reduce(CGFloat(0)) { $0 + tabs.width(forSegment: $1) }
        let point = NSPoint(x: leading + tabs.width(forSegment: index) / 2, y: tabs.bounds.midY)
        try input.click(label, view: tabs, at: point, hold: hold, verify: verify)
    }
    private func matches(_ event: NSEvent, _ chord: ClipboardShortcut) -> Bool {
        event.keyCode == UInt16(chord.keyCode) && event.chordModifiers == chord.modifiers
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
