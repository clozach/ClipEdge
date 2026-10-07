import AppKit

/// A borderless nonactivating panel needs an explicit key-window opt-in for search.
final class ClipboardWindow: NSPanel {
    /// The window closing right now; while set, no other ClipEdge window can take the keyboard.
    private static var closing: ObjectIdentifier?
    override var canBecomeKey: Bool { Self.mayBecomeKey(self) }
    override var canBecomeMain: Bool { false }

    /// Nonactivating panels cannot rely on the foreground app's Edit menu.
    /// Route the native editing chords to this panel's field editor. Local key
    /// monitors run first, so the history window keeps its deliberate ⌘C pickup.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let editor = firstResponder as? NSTextView, editor.isFieldEditor, editor.isEditable else {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch (event.charactersIgnoringModifiers?.lowercased(), flags) {
        case ("a", [.command]): editor.selectAll(nil)
        case ("c", [.command]): editor.copy(nil)
        case ("x", [.command]): editor.cut(nil)
        case ("v", [.command]): editor.paste(nil)
        case ("z", [.command]): editor.undoManager?.undo()
        case ("z", [.command, .shift]): editor.undoManager?.redo()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    override func fieldEditor(_ createFlag: Bool, for object: Any?) -> NSText? {
        let editor = super.fieldEditor(createFlag, for: object)
        if object is NSSearchField { (editor as? NSTextView)?.allowsUndo = true }
        return editor
    }

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
