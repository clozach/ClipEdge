import AppKit

/// ClipEdge's windows are nonactivating panels: one can hold the keyboard while another app is in
/// front, so a ClipEdge panel made or left key after the person has moved to another app takes their
/// typing. These fixtures share one keyboard among their panels, as the window server does, and post
/// no input: no window reaches the desktop, no app is activated, the clipboard is a named board.
@main enum KeyboardHandBackTests {
    private static var assertions = 0
    private static var failures: [String] = []
    private static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !value() { failures.append(message); FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8)) }
    }

    static func main() {
        _ = NSApplication.shared
        precondition(ClipboardWindow.isIsolatedTestRun, "run through tools/test.sh: fixture panels must stay off the desktop")
        ruleChecks()
        updateQuestionChecks()
        sendToChecks()
        drawerClosingChecks()
        clipEdgeInFrontChecks()
        quickLookHidingChecks()
        mediumMagnetChecks()
        settled()
        guard failures.isEmpty else { fatalError("\(failures.count) of \(assertions) keyboard hand-back assertions failed") }
        print("PASS: \(assertions) keyboard hand-back assertions; one shared fixture keyboard, no input posted")
    }

    /// One pass of the main run loop: a closing window's hold on the keyboard lets go.
    private static func settled() { wait(0.05) }
    /// The main run loop for `seconds`: Quick Look's magnet travelling back to its card ends after 0.28 s.
    private static func wait(_ seconds: TimeInterval) {
        RunLoop.current.add(Timer(timeInterval: 0.01, repeats: false) { _ in }, forMode: .default)
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// The rule itself: ClipEdge takes the keyboard back only from a window that still holds it.
    private static func ruleChecks() {
        typealias Rule = ClipboardKeyboardReturn
        check(Rule.after(.besideDrawer, holdingKeyboard: true) == .takeBack, "rule: a panel beside the drawer closing with the keyboard gives it to the drawer")
        check(Rule.after(.besideDrawer, holdingKeyboard: false) == .leave, "rule: one closed by a click elsewhere gives nothing back")
        check(Rule.after(.drawer(clipEdgeInFront: true), holdingKeyboard: true) == .takeBack, "rule: the drawer closing with ClipEdge in front hands the keyboard back")
        check(Rule.after(.drawer(clipEdgeInFront: false), holdingKeyboard: true) == .letGo, "rule: the drawer closing in the background lets go of it")
        check(Rule.after(.drawer(clipEdgeInFront: true), holdingKeyboard: false) == .leave
              && Rule.after(.drawer(clipEdgeInFront: false), holdingKeyboard: false) == .leave, "rule: a drawer without the keyboard gives and takes nothing")
        check(Rule.after(.quickLook(besideOpenDrawer: true), holdingKeyboard: true) == .takeBack, "rule: Quick Look beside the open drawer hiding with the keyboard gives it to the drawer")
        check(Rule.after(.quickLook(besideOpenDrawer: false), holdingKeyboard: true) == .letGo, "rule: Quick Look following the pointer hiding with it lets go")
        check(Rule.after(.quickLook(besideOpenDrawer: true), holdingKeyboard: false) == .leave
              && Rule.after(.quickLook(besideOpenDrawer: false), holdingKeyboard: false) == .leave, "rule: Quick Look without the keyboard gives and takes nothing")
    }

    // MARK: The first-launch update question

    /// Clicked, the question takes the keyboard; answering it must give it back to the app in front,
    /// not let AppKit hand it to the drawer (even collapsed), which would take the person's typing.
    private static func updateQuestionChecks() {
        settled()
        let world = KeyboardWorld()
        let drawer = world.panel("ClipEdge")
        var chosen: UpdatePreference?
        let question = UpdateConsentPanel { chosen = $0 }
        question.present()
        question.makeKey() // the person clicked it
        check(question.isVisible && question.isKeyWindow, "update question: a click gives it the keyboard")
        let answer = buttons(in: question.contentView).first { $0.keyEquivalent == "\r" }
        answer?.performClick(nil)
        check(chosen == .automatic && !question.isVisible && !question.isKeyWindow, "update question: Return's button answers and closes it")
        check(!drawer.canBecomeKey, "update question: as it closes holding the keyboard, no other ClipEdge window may take it (the keyboard gate)")
        settled()
        check(drawer.canBecomeKey, "update question: the next moment every window accepts the keyboard again")

        let unclicked = UpdateConsentPanel { chosen = $0 }
        unclicked.present()
        buttons(in: unclicked.contentView).first { $0.keyEquivalent == "\u{1b}" }?.performClick(nil)
        check(chosen == .manual && !unclicked.isVisible && drawer.canBecomeKey, "update question: answered without the keyboard, it gates nothing")

        // Clicked, then answered from the menu bar's Updates menu, as the question itself suggests: opening
        // that menu leaves the question key, and Update Automatically and Check for Updates Now close it.
        settled()
        chosen = nil
        let fromMenu = UpdateConsentPanel { chosen = $0 }
        fromMenu.present()
        fromMenu.makeKey()
        fromMenu.close() // what UpdateMenu's toggleAutomatic() and checkNow() call
        check(!fromMenu.isVisible && !fromMenu.isKeyWindow && chosen == nil, "update question: closed from the Updates menu, it leaves without answering itself")
        check(!drawer.canBecomeKey, "update question: closed from the Updates menu while holding the keyboard, no other ClipEdge window may take it")
        settled()
        check(drawer.canBecomeKey, "update question: after a close from the menu, every window accepts the keyboard again")
    }

    private static func buttons(in view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        return ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap { buttons(in: $0) }
    }

    // MARK: Send to and the preview ask beside the drawer

    /// Esc, Back or a send closes Send to holding the keyboard: the drawer's cards take it back.
    /// A click in another app closes it too, but that app keeps the keyboard. Another ClipEdge window
    /// stands first in AppKit's hand-off here, so only the drawer taking the keyboard back puts it there.
    private static func sendToChecks() {
        settled()
        let fixture = DrawerFixture(otherWindowFirst: true)
        defer { fixture.stop() }
        let (world, drawer) = (fixture.world, fixture.drawer)
        fixture.open()
        check(world.key === fixture.drawerPanel && world.clipEdgeInFront, "send to: the drawer opens with the keyboard")
        drawer.showSendTo(fixture.entry)
        check(drawer.sendToPopover.isVisible && world.key === fixture.sendToPanel, "send to: it opens with the keyboard")

        drawer.sendToPopover.view.onBack?()
        check(!drawer.sendToPopover.isVisible && world.key === fixture.drawerPanel, "send to: Back gives the keyboard back to the drawer's cards")

        drawer.showSendTo(fixture.entry)
        world.personClicksAnotherApp()
        check(!drawer.sendToPopover.isVisible, "send to: a click in another app closes it")
        check(world.key == nil && !world.clipEdgeInFront, "send to: the app clicked keeps the keyboard; the drawer does not take it back")

        world.personClicks(fixture.drawerPanel)
        drawer.showAskForPreview(fixture.entry)
        check(drawer.askPopover.isVisible && world.key === fixture.askPanel, "ask: it opens beside the drawer with the keyboard")
        drawer.askPopover.view.back()
        check(!drawer.askPopover.isVisible && world.key === fixture.drawerPanel, "ask: Back gives the keyboard back to the drawer's cards")
        drawer.showAskForPreview(fixture.entry)
        world.personClicksAnotherApp()
        check(!drawer.askPopover.isVisible && world.key == nil, "ask: a click in another app closes it, and that app keeps the keyboard")
    }

    // MARK: The drawer closing

    /// The drawer closes: with ClipEdge in front the keyboard goes back where it was; with ClipEdge in
    /// the background, whichever drawer window still holds it (the person clicked back into the drawer)
    /// lets go, so the collapsed tab never holds it.
    private static func drawerClosingChecks() {
        do { // Click another app, click back into the drawer's search, then leave.
            settled()
            let fixture = DrawerFixture()
            defer { fixture.stop() }
            let world = fixture.world
            fixture.open()
            world.personClicksAnotherApp()
            world.personClicks(fixture.drawerPanel)
            check(world.key === fixture.drawerPanel && !world.clipEdgeInFront, "drawer: clicked back into, it holds the keyboard with ClipEdge in the background")
            fixture.drawer.hide(animated: false)
            settled()
            check(fixture.drawerPanel.isVisible && fixture.drawer.tabFrame != nil, "drawer: closed, its tab stays on screen")
            check(world.key == nil && !world.clipEdgeInFront, "drawer: closed with ClipEdge in the background, the collapsed tab lets go of the keyboard")
        }
        // Hidden tab, closed without animation: ⌃⌘V's hide(animated: false), or Esc with Reduce Motion or a 0 s
        // close (animations are off in fixtures, as with Reduce Motion). The panel leaves the screen as it closes.
        for animated in [false, true] {
            settled()
            let fixture = DrawerFixture()
            defer { fixture.stop() }
            let world = fixture.world
            let how = animated ? "Esc without animation" : "⌃⌘V"
            fixture.drawer.applyAvailability(.hiddenTab)
            fixture.open()
            world.personClicksAnotherApp()
            world.personClicks(fixture.drawerPanel)
            check(world.key === fixture.drawerPanel && !world.clipEdgeInFront, "hidden tab (\(how)): clicked back into, the drawer holds the keyboard with ClipEdge in the background")
            fixture.drawer.hide(animated: animated)
            check((world.key == nil || world.key === fixture.drawerPanel) && !world.clipEdgeInFront,
                  "hidden tab (\(how)): closed in the background, no other ClipEdge window takes the keyboard")
            settled()
            check(!fixture.drawerPanel.isVisible && world.key == nil && !world.clipEdgeInFront,
                  "hidden tab (\(how)): a moment later the drawer is off the screen and the app in front has the keyboard")
        }
        do { // The same, opened over Settings: Settings must not take the keyboard from the app in front.
            settled()
            let fixture = DrawerFixture(overSettings: true)
            defer { fixture.stop() }
            let world = fixture.world
            fixture.open()
            check(world.key === fixture.drawerPanel, "drawer over Settings: it opens with the keyboard")
            world.personClicksAnotherApp()
            world.personClicks(fixture.drawerPanel)
            fixture.drawer.hide(animated: false)
            settled()
            check(world.key == nil && !world.clipEdgeInFront, "drawer over Settings: closed with ClipEdge in the background, neither Settings nor the tab takes the keyboard")
        }
        do { // Quick Look beside the drawer: the person clicked into its raw data, from another app.
            settled()
            let fixture = DrawerFixture()
            defer { fixture.stop() }
            let world = fixture.world
            fixture.open()
            _ = fixture.drawer.browser.canvas.answer(.quickLook, fixture.entry)
            check(fixture.magnet.drawerAnchor != nil && fixture.quickLookPanel.isVisible, "quick look: it opens beside the drawer")
            world.personClicksAnotherApp()
            world.personClicks(fixture.quickLookPanel)
            check(fixture.magnet.holdsKeyboard && !world.clipEdgeInFront, "quick look: clicked into, it holds the keyboard with ClipEdge in the background")
            fixture.drawer.hide(animated: false)
            settled()
            check(fixture.magnet.presentation == .carousel, "quick look: the drawer closed, it follows the pointer")
            check(world.key == nil && !world.clipEdgeInFront, "quick look: the drawer closed in the background, neither it nor the tab keeps the keyboard")
        }
        // A ClipEdge window opening as the drawer closes (the ⌥⌘\ window closes the drawer as it opens) keeps the
        // keyboard, with the tab showing or hidden.
        for availability in [ClipboardDrawerAvailability.visibleTab, .hiddenTab] {
            settled()
            let fixture = DrawerFixture()
            defer { fixture.stop() }
            let world = fixture.world
            let window = world.panel("ClipEdge History")
            let tab = availability.tabVisible ? "" : " (hidden tab)"
            fixture.drawer.applyAvailability(availability)
            fixture.open()
            world.personClicksAnotherApp()
            world.personClicks(fixture.drawerPanel)
            fixture.drawer.hide(animated: false)
            window.makeKeyAndOrderFront(nil)
            check(world.key === window, "opening as the drawer closes\(tab): the new window takes the keyboard at once")
            settled()
            check(world.key === window && fixture.drawerPanel.isVisible == availability.tabVisible,
                  "opening as the drawer closes\(tab): it keeps the keyboard, and the tab stays only if shown")
            window.orderOut(nil)
        }
        do { // Reopened before the moment passes, the drawer keeps the keyboard; after a let-go, it takes it again.
            settled()
            let fixture = DrawerFixture()
            defer { fixture.stop() }
            let world = fixture.world
            fixture.open()
            world.personClicksAnotherApp()
            world.personClicks(fixture.drawerPanel)
            fixture.drawer.hide(animated: false)
            fixture.open()
            settled()
            check(fixture.drawer.isVisible && world.key === fixture.drawerPanel, "reopened at once: the drawer keeps the keyboard")
            world.personClicksAnotherApp()
            world.personClicks(fixture.drawerPanel)
            fixture.drawer.hide(animated: false)
            settled()
            check(world.key == nil, "closed again: it lets go")
            fixture.open()
            check(world.key === fixture.drawerPanel && world.clipEdgeInFront, "after letting go, the drawer opens with the keyboard again")
        }
    }

    // MARK: ClipEdge in front

    /// With ClipEdge in front the drawer hands the keyboard back as before: to Settings it opened over,
    /// or to the app it opened over.
    private static func clipEdgeInFrontChecks() {
        do {
            settled()
            let fixture = DrawerFixture()
            defer { fixture.stop() }
            fixture.open()
            fixture.drawer.hide(animated: false)
            settled()
            check(fixture.returns == 1 && fixture.world.key == nil, "in front: closing gives the keyboard back to the app the drawer opened over")
            check(fixture.drawerPanel.isVisible && fixture.drawerPanel.canBecomeKey, "in front: the tab stays, and nothing gates the keyboard")
        }
        do {
            settled()
            let fixture = DrawerFixture(overSettings: true)
            defer { fixture.stop() }
            fixture.open()
            fixture.drawer.hide(animated: false)
            check(fixture.world.key === fixture.settingsPanel && fixture.returns == 0, "in front over Settings: closing gives Settings the keyboard back")
        }
        do { // Send to open as the drawer closes in front: the keyboard still goes back to the app.
            settled()
            let fixture = DrawerFixture()
            defer { fixture.stop() }
            fixture.open()
            fixture.drawer.showSendTo(fixture.entry)
            fixture.drawer.hide(animated: false)
            check(!fixture.drawer.sendToPopover.isVisible && fixture.returns == 1 && fixture.world.key == nil,
                  "in front with Send to open: closing closes it and gives the keyboard back to the app")
        }
    }

    // MARK: Quick Look hiding while it holds the keyboard

    /// Quick Look beside the drawer takes the keyboard for its raw data's text (T, or a click into the text
    /// from another app) and, as these fixtures model a click, when it is clicked. Then it hides holding it:
    /// ⌘C from that text, a copy in another app, or its × ends the preview. The drawer's cards take the
    /// keyboard back, as from any panel beside the drawer: never another ClipEdge window (one stands first in
    /// the modelled hand-off here), and ClipEdge stays in front or behind as it was.
    private static func quickLookHidingChecks() {
        enum Hold: String { case text = "its text", panel = "a click on it" }
        enum Path: String { case copyFromText = "⌘C from its text", copyElsewhere = "a copy in another app", close = "its ×" }
        for inFront in [true, false] {
            for hold in [Hold.text, .panel] {
                for path in [Path.copyFromText, .copyElsewhere, .close] where hold == .text || path != .copyFromText {
                    settled()
                    let fixture = DrawerFixture(otherWindowFirst: true)
                    defer { fixture.stop() }
                    let world = fixture.world
                    let how = "quick look (\(inFront ? "ClipEdge in front" : "from another app"), \(hold.rawValue), \(path.rawValue))"
                    fixture.open()
                    fixture.drawerPanel.makeFirstResponder(fixture.drawer.browser.canvas)
                    fixture.press(34, [], "i") // I: Quick Look beside the drawer, turned to the raw data
                    guard let carousel = fixture.magnet.drawerCarousel, carousel.showsRawData else {
                        check(false, "\(how): I opens Quick Look beside the drawer, turned"); continue
                    }
                    if !inFront { world.personClicksAnotherApp() }
                    switch (hold, inFront) {
                    case (.text, true): fixture.press(17, [], "t")
                    case (.text, false): world.personClicks(fixture.quickLookPanel); fixture.quickLookPanel.makeFirstResponder(carousel.raw.overviewView)
                    case (.panel, _): world.personClicks(fixture.quickLookPanel)
                    }
                    check(fixture.magnet.holdsKeyboard && carousel.raw.holdsKeyboard == (hold == .text) && world.clipEdgeInFront == inFront,
                          "\(how): its panel holds the keyboard")
                    switch path {
                    case .copyFromText:
                        carousel.raw.overviewView.setSelectedRange(NSRange(location: 0, length: 3))
                        check(fixture.drawer.handleDrawerKey(DrawerFixture.key(8, .command, "c")), "\(how): ⌘C is the text's")
                    case .copyElsewhere: fixture.copyElsewhere("Copied elsewhere")
                    case .close: carousel.onClose?(); wait(0.45)
                    }
                    check(fixture.magnet.drawerAnchor == nil, "\(how): Quick Look has gone")
                    check(world.key === fixture.drawerPanel && world.clipEdgeInFront == inFront,
                          "\(how): the drawer's cards take the keyboard back, no other ClipEdge window, ClipEdge where it was (\(world.holder))")
                    settled()
                    check(world.key === fixture.drawerPanel && world.clipEdgeInFront == inFront, "\(how): a moment later, still the cards'")
                }
            }
        }
    }

    /// The drawer closed, Quick Look follows the pointer (the medium cursor magnet). Clicked, as these fixtures
    /// model a click into its preview, its panel holds the keyboard; it hides holding it when Esc drops it, a
    /// copy in another app ends it, or the ⌥⌘\ window cancels it as it opens. No drawer is open to take the
    /// keyboard back: it lets go, the app in front keeps it, and ClipEdge is not brought to the front.
    private static func mediumMagnetChecks() {
        enum Path: String { case escape = "Esc", copyElsewhere = "a copy in another app", windowOpening = "the ⌥⌘\\ window opening" }
        for path in [Path.escape, .copyElsewhere, .windowOpening] {
            settled()
            let fixture = DrawerFixture()
            defer { fixture.stop() }
            let world = fixture.world
            let how = "medium magnet (\(path.rawValue))"
            let window = world.panel("ClipEdge History")
            fixture.open()
            _ = fixture.drawer.browser.canvas.answer(.quickLook, fixture.entry)
            fixture.drawer.hide(animated: false) // ClipEdge in front: the keyboard goes back to the app behind
            settled()
            check(fixture.magnet.presentation == .carousel && fixture.quickLookPanel.isVisible && world.key == nil && !world.clipEdgeInFront,
                  "\(how): the drawer closed, Quick Look follows the pointer and the app in front has the keyboard")
            world.personClicks(fixture.quickLookPanel)
            check(fixture.magnet.holdsKeyboard && !world.clipEdgeInFront, "\(how): clicked, its panel holds the keyboard")
            switch path {
            case .escape:
                check(fixture.magnet.shouldHandleEscape(), "\(how): with no drawer open, Esc is the magnet's")
                fixture.magnet.onCancel?() // the paste monitor's Esc drops it
            case .copyElsewhere: fixture.copyElsewhere("Copied elsewhere")
            case .windowOpening:
                fixture.store.cancelStaging() // what the ⌥⌘\ window's show() does first, then it takes the keyboard
                window.makeKeyAndOrderFront(nil)
            }
            let expected: KeyboardWorldPanel? = path == .windowOpening ? window : nil
            check(!fixture.magnet.isQuickLook && !world.clipEdgeInFront
                  && (world.key === expected || (expected == nil && world.key === fixture.quickLookPanel)),
                  "\(how): Quick Look gone, no other ClipEdge window takes the keyboard and ClipEdge stays behind (\(world.holder))")
            settled()
            check(world.key === expected && !world.clipEdgeInFront, "\(how): a moment later \(expected == nil ? "the app in front" : "the new window") has the keyboard")
            check(fixture.quickLookPanel.isVisible == (fixture.magnet.presentation == .small) && !fixture.quickLookPanel.isKeyWindow,
                  "\(how): its panel is off the screen, or back as the small magnet without the keyboard")
            window.orderOut(nil)
        }
    }
}

// MARK: Fixtures

/// The window server's keyboard as the fixture's panels share it: one key window, or none when the
/// app in front has it. Ordering out the key window hands it on as AppKit does (2026-10-04 evidence):
/// to the first other ClipEdge panel that accepts it, even one not on screen, activating ClipEdge;
/// with none accepting, the app in front has it.
final class KeyboardWorld {
    private(set) var key: KeyboardWorldPanel?
    var clipEdgeInFront = false
    private var panels: [KeyboardWorldPanel] = []

    func panel(_ title: String) -> KeyboardWorldPanel {
        let panel = KeyboardWorldPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.title = title
        panel.world = self
        panels.append(panel)
        return panel
    }

    /// AppKit posts the old key window's resign once the new one holds the keyboard.
    func give(to panel: KeyboardWorldPanel?) {
        guard key !== panel else { return }
        let previous = key
        key = panel
        if let previous { NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: previous) }
    }

    func handOff(from going: KeyboardWorldPanel) {
        let next = panels.first { $0 !== going && $0.canBecomeKey }
        if next != nil { clipEdgeInFront = true }
        give(to: next)
    }

    func personClicksAnotherApp() { clipEdgeInFront = false; give(to: nil) }
    /// Who has the keyboard, for a failing check: a ClipEdge window, or the app in front.
    var holder: String { "\(key?.title ?? "the app in front") has it, ClipEdge \(clipEdgeInFront ? "in front" : "behind")" }
    /// The drawer activating the app it opened over, in place of a real activation.
    private(set) var returnsToTheAppBehind = 0
    func returnToTheAppBehind() { returnsToTheAppBehind += 1; personClicksAnotherApp() }
    /// A click on a nonactivating panel gives it the keyboard and leaves ClipEdge where it was.
    func personClicks(_ panel: KeyboardWorldPanel) { give(to: panel) }
}

final class KeyboardWorldPanel: NSPanel {
    weak var world: KeyboardWorld?
    private var shown = false
    override var isVisible: Bool { shown }
    override var isKeyWindow: Bool { world?.key === self }
    override var canBecomeKey: Bool { ClipboardWindow.mayBecomeKey(self) }
    override var canBecomeMain: Bool { false }
    override func makeKey() { if canBecomeKey { world?.give(to: self) } }
    override func makeKeyAndOrderFront(_ sender: Any?) { shown = true; makeKey() }
    override func orderFrontRegardless() { shown = true }
    override func orderFront(_ sender: Any?) { shown = true }
    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        if place == .out { orderOut(nil) } else { shown = true }
    }
    override func orderOut(_ sender: Any?) {
        shown = false
        if world?.key === self { world?.handOff(from: self) }
    }
    /// AppKit's resignKey() only notifies; the keyboard stays.
    override func resignKey() {}
}

/// A drawer whose panels all share one world: the drawer first, so AppKit's hand-off reaches it first,
/// unless another ClipEdge window stands before it (`otherWindowFirst`).
final class DrawerFixture {
    let world = KeyboardWorld()
    /// A ClipEdge window AppKit's hand-off reaches before the drawer (one off screen, as the ⌥⌘\ window
    /// is): with it, only the drawer's own taking back puts the keyboard on its cards.
    let otherWindow: KeyboardWorldPanel?
    let board = NSPasteboard.withUniqueName()
    let store: ClipboardStore
    let drawerPanel: KeyboardWorldPanel
    let sendToPanel: KeyboardWorldPanel
    let askPanel: KeyboardWorldPanel
    let quickLookPanel: KeyboardWorldPanel
    let settingsPanel: KeyboardWorldPanel?
    let magnet: ClipboardMagnetController
    let drawer: ClipboardDrawerController
    /// Times the drawer gave the keyboard back to the app it opened over (no real app is activated).
    var returns: Int { world.returnsToTheAppBehind }
    var entry: ClipboardEntry { store.entries[0] }

    init(overSettings: Bool = false, otherWindowFirst: Bool = false) {
        store = ClipboardStore(pasteboard: board, persistenceURL: nil)
        for text in ["Forest", "Ocean"] { board.clearContents(); board.setString(text, forType: .string); _ = store.saveNow() }
        store.cancelStaging()
        otherWindow = otherWindowFirst ? world.panel("ClipEdge History") : nil
        drawerPanel = world.panel("ClipEdge")
        sendToPanel = world.panel("ClipEdge Send To")
        askPanel = world.panel("ClipEdge Ask for a Preview")
        quickLookPanel = world.panel("ClipEdge Cursor Magnet")
        settingsPanel = overSettings ? world.panel("ClipEdge Settings") : nil
        magnet = ClipboardMagnetController(panel: quickLookPanel, commandClickEnabled: false)
        let world = self.world
        if let settingsPanel { settingsPanel.orderFrontRegardless(); world.clipEdgeInFront = true; world.personClicks(settingsPanel) }
        drawer = ClipboardDrawerController(store: store, magnetController: magnet, panel: drawerPanel, defaults: nil,
                                          sendToPopover: ClipboardSendToPopover(panel: sendToPanel),
                                          askPopover: ClipboardPreviewAskPopover(panel: askPanel),
                                          activate: { world.clipEdgeInFront = true },
                                          focus: { world.clipEdgeInFront ? .front(keyWindow: world.key) : .background },
                                          returnTo: { _ in world.returnToTheAppBehind() })
        drawer.sendSources = ClipboardSendTo.Sources(openers: { _ in [] },
                                                     running: { [ClipboardSendTo.RunningApp(pid: 900, name: "Notes", url: nil)] },
                                                     pasteTarget: { _ in nil })
        drawer.showCollapsedTab(on: NSScreen.main!)
    }

    func open() { drawer.toggleFromCommand() }

    /// A key as the drawer's local monitor gets it, then the cards: built here, never posted.
    static func key(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = [], _ characters: String = "") -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }
    func press(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = [], _ characters: String = "") {
        let event = Self.key(code, modifiers, characters)
        if !drawer.handleDrawerKey(event) { drawer.browser.canvas.keyDown(with: event) }
    }

    /// Another app copies: the fixture's named board changes, and the store sees it as it polls.
    func copyElsewhere(_ text: String) {
        board.clearContents()
        board.setString(text, forType: .string)
        _ = store.saveNow()
    }

    func stop() {
        world.personClicksAnotherApp()
        drawer.stop()
        store.stop()
        board.releaseGlobally()
    }
}
