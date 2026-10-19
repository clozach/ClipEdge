import AppKit

/// A ClipEdge panel that can take the keyboard: it asks the keyboard gate first, and an isolated
/// test run keeps its window and key state to itself, so no fixture panel reaches the desktop.
/// The drawer, its companions, the ⌥⌘\ window and the first-launch update question are all one.
class ClipboardKeyboardPanel: NSPanel {
    /// Frozen release checks run beside the real app. Keep their window state
    /// testable without putting fixture panels on the user's desktop.
    static var isIsolatedTestRun: Bool {
        ProcessInfo.processInfo.environment["CLIPEDGE_TEST_PREVIEW_ROOT"] != nil
    }
    private let isolatesNativeWindow = ClipboardKeyboardPanel.isIsolatedTestRun
    private var fixtureVisible = false
    private var fixtureKey = false
    override var isVisible: Bool { isolatesNativeWindow ? fixtureVisible : super.isVisible }
    override var isKeyWindow: Bool { isolatesNativeWindow ? fixtureKey : super.isKeyWindow }

    override func orderFrontRegardless() {
        if isolatesNativeWindow { fixtureVisible = true } else { super.orderFrontRegardless() }
    }
    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        if isolatesNativeWindow {
            fixtureVisible = place != .out
            if !fixtureVisible { fixtureKey = false }
        } else { super.order(place, relativeTo: otherWin) }
    }
    override func orderFront(_ sender: Any?) {
        if isolatesNativeWindow { fixtureVisible = true } else { super.orderFront(sender) }
    }
    override func orderOut(_ sender: Any?) {
        if isolatesNativeWindow { fixtureVisible = false; fixtureKey = false } else { super.orderOut(sender) }
    }
    override func makeKey() {
        if isolatesNativeWindow { fixtureKey = canBecomeKey } else { super.makeKey() }
    }
    override func resignKey() {
        if isolatesNativeWindow { fixtureKey = false } else { super.resignKey() }
    }
    override func makeKeyAndOrderFront(_ sender: Any?) {
        if isolatesNativeWindow { orderFront(sender); makeKey() } else { super.makeKeyAndOrderFront(sender) }
    }

    /// The window closing right now; while set, no other ClipEdge window can take the keyboard.
    private static var closing: ObjectIdentifier?
    override var canBecomeKey: Bool { Self.mayBecomeKey(self) }
    override var canBecomeMain: Bool { false }

    /// Every ClipEdge window that can take the keyboard asks this, not only ClipboardWindows.
    static func mayBecomeKey(_ window: NSWindow) -> Bool {
        closing.map { $0 == ObjectIdentifier(window) } ?? true
    }

    /// Orders out a window that holds the keyboard, so the
    /// keyboard returns to the app in front. Left alone, AppKit hands it to another ClipEdge
    /// window (the drawer, even collapsed) and activates ClipEdge: typing and ⌘V then go nowhere.
    static func orderOutReturningKeyboard(_ window: NSWindow) {
        guard window.isKeyWindow else { return window.orderOut(nil) }
        closing = ObjectIdentifier(window)
        window.orderOut(nil)
        DispatchQueue.main.async { closing = nil }
    }
}

/// A borderless nonactivating panel needs an explicit key-window opt-in for search.
final class ClipboardWindow: ClipboardKeyboardPanel {
    /// Nonactivating panels cannot rely on the foreground app's Edit menu, so the
    /// search takes the editing chords first. Local key monitors run before this,
    /// so the history window keeps its deliberate ⌘C pickup.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        ClipboardFieldEditing.perform(event, in: self) || super.performKeyEquivalent(with: event)
    }

    override func fieldEditor(_ createFlag: Bool, for object: Any?) -> NSText? {
        let editor = super.fieldEditor(createFlag, for: object)
        if object is NSSearchField { (editor as? NSTextView)?.allowsUndo = true }
        return editor
    }
}

/// ClipEdge in front, with its key window if it has one, or in the background: what decides where
/// the keyboard goes as one of its windows goes. Read at that moment; fixtures supply their own.
enum ClipboardAppFocus {
    case background
    case front(keyWindow: NSWindow?)

    static func current() -> Self {
        let app = NSApplication.shared
        return app.isActive ? .front(keyWindow: app.keyWindow) : .background
    }
    var isFront: Bool { if case .front = self { return true } else { return false } }
    var keyWindow: NSWindow? { if case .front(let window) = self { return window } else { return nil } }
}

/// The one rule for where the keyboard goes as a ClipEdge window that may hold it goes. ClipEdge's
/// windows are nonactivating panels, which can hold the keyboard while another app is in front:
/// one made or left key after the person has moved to that app takes their typing. So ClipEdge
/// takes the keyboard back only from a window that still holds it, and only while the person is
/// still in ClipEdge; otherwise the going window lets go of it, or there is nothing to give back.
enum ClipboardKeyboardReturn: Equatable {
    /// Back where it was: the drawer's cards, as a panel beside it closes by Esc, Back or a send, or as
    /// Quick Look beside it hides; or, as the drawer closes with ClipEdge in front, the ClipEdge window or
    /// app it opened over.
    case takeBack
    /// The drawer closed with ClipEdge in the background while one of its windows still held the
    /// keyboard (the person clicked back into it from another app), or Quick Look following the pointer
    /// hid holding it: it lets go, through the keyboard gate, and the app in front has it. The collapsed
    /// tab never keeps it.
    case letGo
    /// The going window no longer holds the keyboard: the person clicked into another app or window,
    /// which keeps it, and no ClipEdge window takes it.
    case leave

    /// What is going: a panel beside the open drawer (Send to, the preview ask), which stays open; the
    /// drawer itself, with ClipEdge in front or not; or Quick Look's panel, which holds the keyboard for
    /// its raw data's text or a click on it.
    enum Going {
        case besideDrawer
        case drawer(clipEdgeInFront: Bool)
        /// Beside the open drawer it is one of the panels beside it. Following the pointer (the medium
        /// magnet, which takes no keys), no ClipEdge window takes the keyboard back.
        case quickLook(besideOpenDrawer: Bool)
    }

    static func after(_ going: Going, holdingKeyboard: Bool) -> Self {
        guard holdingKeyboard else { return .leave }
        switch going {
        case .besideDrawer: return .takeBack
        case .drawer(let inFront): return inFront ? .takeBack : .letGo
        case .quickLook(let besideOpenDrawer): return besideOpenDrawer ? .takeBack : .letGo
        }
    }
}
