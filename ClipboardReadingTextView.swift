import AppKit

/// One of the raw data's texts (its overview, a flavor's content), in the window's card and Quick
/// Look alike. It says when it takes the keyboard or lets it go, and, never editable, it still has a
/// caret, drawn where it is, that the keys move as in any text: the arrows (with ⌥ a word at a time,
/// with ⌘ to a line's or the text's ends), and ⇧ with them selects from it. So a part can be selected
/// and copied without a pointer (AppKit moves nothing in a text that cannot be edited; only its ⇧
/// moves extend a selection, and only from where a click left one).
final class ClipboardReadingTextView: NSTextView {
    var onKeyboardChange: (() -> Void)?
    private var holdsKeyboard: Bool { window?.firstResponder === self }

    override func becomeFirstResponder() -> Bool {
        let took = super.becomeFirstResponder()
        if took { onKeyboardChange?(); needsDisplay = true }
        return took
    }
    override func resignFirstResponder() -> Bool {
        let left = super.resignFirstResponder()
        if left { onKeyboardChange?(); needsDisplay = true }
        return left
    }
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        needsDisplay = true
    }

    override func moveDown(_ sender: Any?) { moveCaret(forward: true) { super.moveDownAndModifySelection(sender) } }
    override func moveUp(_ sender: Any?) { moveCaret(forward: false) { super.moveUpAndModifySelection(sender) } }
    override func moveRight(_ sender: Any?) { moveCaret(forward: true, collapsesFirst: true) { super.moveRightAndModifySelection(sender) } }
    override func moveLeft(_ sender: Any?) { moveCaret(forward: false, collapsesFirst: true) { super.moveLeftAndModifySelection(sender) } }
    override func moveWordRight(_ sender: Any?) { moveCaret(forward: true) { super.moveWordRightAndModifySelection(sender) } }
    override func moveWordLeft(_ sender: Any?) { moveCaret(forward: false) { super.moveWordLeftAndModifySelection(sender) } }
    override func moveToRightEndOfLine(_ sender: Any?) { moveCaret(forward: true) { super.moveToRightEndOfLineAndModifySelection(sender) } }
    override func moveToLeftEndOfLine(_ sender: Any?) { moveCaret(forward: false) { super.moveToLeftEndOfLineAndModifySelection(sender) } }
    override func moveToEndOfDocument(_ sender: Any?) { moveCaret(forward: true) { super.moveToEndOfDocumentAndModifySelection(sender) } }
    override func moveToBeginningOfDocument(_ sender: Any?) { moveCaret(forward: false) { super.moveToBeginningOfDocumentAndModifySelection(sender) } }

    /// The caret moved by `extend` (the same move with ⇧) from the end of the selection the key
    /// points to, then set down there; a selection first gives way to that end, and ← and → stop
    /// there, as in any text. It stays in view.
    private func moveCaret(forward: Bool, collapsesFirst: Bool = false, _ extend: () -> Void) {
        let selected = selectedRange()
        setSelectedRange(NSRange(location: forward ? NSMaxRange(selected) : selected.location, length: 0))
        if !(collapsesFirst && selected.length > 0) {
            extend()
            let moved = selectedRange()
            setSelectedRange(NSRange(location: forward ? NSMaxRange(moved) : moved.location, length: 0))
        }
        scrollRangeToVisible(selectedRange())
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard holdsKeyboard, selectedRange().length == 0, let caret = caretRect else { return }
        insertionPointColor.setFill()
        caret.fill()
    }
    /// Where its caret is drawn, while it holds the keyboard with nothing selected: a point wide,
    /// a line high.
    var caretRect: NSRect? {
        guard let layout = layoutManager, let container = textContainer else { return nil }
        layout.ensureLayout(for: container)
        let length = (string as NSString).length, location = min(selectedRange().location, length)
        let line: NSRect, x: CGFloat
        if location < length {
            let glyph = layout.glyphIndexForCharacter(at: location)
            line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            x = line.minX + layout.location(forGlyphAt: glyph).x
        } else if !layout.extraLineFragmentRect.isEmpty {
            line = layout.extraLineFragmentRect
            x = line.minX
        } else if layout.numberOfGlyphs > 0 {
            let glyph = layout.numberOfGlyphs - 1
            line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            x = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).maxX
        } else {
            let font = self.font ?? ClipboardRawDataView.contentFont
            line = NSRect(x: 0, y: 0, width: 0, height: ceil(font.ascender - font.descender + font.leading))
            x = 0
        }
        return NSRect(x: x + textContainerOrigin.x, y: line.minY + textContainerOrigin.y, width: 1, height: line.height)
    }
}
