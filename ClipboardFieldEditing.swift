import AppKit

/// The editing chords a text field answers in a ClipEdge window: ⌘A, ⌘C, ⌘X, ⌘V,
/// ⌘Z and ⇧⌘Z. ClipEdge's menu has no Edit menu, and while another app owns the
/// menu bar its Edit menu cannot reach these windows, so each routes the chords here.
enum ClipboardFieldEditing {
    enum Command: Equatable { case selectAll, copy, cut, paste, undo, redo }

    static func command(for event: NSEvent) -> Command? {
        let bindings: [(String, UInt16, NSEvent.ModifierFlags, Command)] = [
            ("a", 0, [.command], .selectAll), ("c", 8, [.command], .copy),
            ("x", 7, [.command], .cut), ("v", 9, [.command], .paste),
            ("z", 6, [.command], .undo), ("z", 6, [.command, .shift], .redo)
        ]
        return bindings.first {
            ClipboardChord(key: .letter($0.0, position: $0.1), modifiers: .exactly($0.2)).matches(event)
        }?.3
    }

    /// Runs an editing chord in the field being edited in `window`; false for any other
    /// key, or when no field is being edited. Copy, cut and paste use `pasteboard`, as the
    /// field editor's own copy: and paste: do with the general one; fixtures pass a named one.
    static func perform(_ event: NSEvent, in window: NSWindow, pasteboard: NSPasteboard = .general) -> Bool {
        guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor, editor.isEditable,
              let command = command(for: event) else { return false }
        let selected = editor.selectedRange().length > 0
        switch command {
        case .selectAll: editor.selectAll(nil)
        case .copy: if selected { _ = editor.writeSelection(to: pasteboard, types: editor.writablePasteboardTypes) }
        case .cut: if selected, editor.writeSelection(to: pasteboard, types: editor.writablePasteboardTypes) { editor.delete(nil) }
        case .paste: _ = editor.readSelection(from: pasteboard)
        case .undo: editor.undoManager?.undo()
        case .redo: editor.undoManager?.redo()
        }
        return true
    }
}
