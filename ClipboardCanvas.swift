import AppKit

/// One keyboard stop for the list/grid. Arrow keys move its visible selection.
final class ClipboardCanvas: NSView {
    var tiles: [ClipboardTile] = []
    var columns = 1
    private(set) var selectedID: UUID?
    private(set) var liftedID: UUID?
    /// The row whose deletion waits for a second ⌘⌫ (history window).
    private(set) var armedID: UUID?
    var onPick: ((ClipboardEntry) -> Void)?
    /// When set, Tab offers apps to send the selected item to.
    var onSendTo: ((ClipboardEntry) -> Void)?
    var onSelect: ((ClipboardEntry) -> Void)?
    var onPreview: ((ClipboardEntry) -> Void)?
    var onDelete: ((ClipboardEntry) -> Void)?
    var onOpen: ((ClipboardEntry) -> Void)?
    var onNavigate: (() -> Void)?
    var onEscape: (() -> Void)?
    /// ⌘F: put the keyboard in the search field.
    var onFind: (() -> Void)?
    override var isFlipped: Bool { true }
    /// The history window keeps the keyboard in its search field; clicks there
    /// must not move it to the list.
    var acceptsKeyboard = true
    override var acceptsFirstResponder: Bool { acceptsKeyboard }
    var selected: ClipboardTile? { tiles.first { $0.entry.id == selectedID } ?? tiles.first }

    func choose(_ id: UUID, reveal: Bool = true) {
        guard tiles.contains(where: { $0.entry.id == id }) else { return }
        ClipboardTileTooltip.shared.hide()
        selectedID = id
        if armedID != id { armedID = nil }
        tiles.forEach { $0.refreshSelection() }
        if reveal, let selected { scrollToVisible(selected.frame.insetBy(dx: -3, dy: -3)) }
        if let selected { onSelect?(selected.entry) }
    }
    func arm(_ id: UUID?) {
        armedID = id
        tiles.forEach { $0.refreshSelection() }
    }
    func reconcile(liftedID: UUID?) {
        self.liftedID = liftedID
        selectedID = selectedID.flatMap { id in tiles.contains { $0.entry.id == id } ? id : nil } ?? tiles.first?.entry.id
        if armedID != selectedID { armedID = nil }
        tiles.forEach { $0.refreshSelection() }
    }
    override func becomeFirstResponder() -> Bool {
        if let selected { choose(selected.entry.id) }
        return true
    }
    override func resignFirstResponder() -> Bool {
        return true
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?(); return }
        if event.keyCode == 49 && event.isARepeat { return }
        if event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "f", let onFind { onFind(); return }
        guard let selected else { super.keyDown(with: event); return }
        let index = tiles.firstIndex(of: selected) ?? 0
        let next: Int?
        switch event.keyCode {
        case 123: next = index - 1
        case 124: next = index + 1
        case 125: next = index + columns
        case 126: next = index - columns
        case 36, 76: onPick?(selected.entry); return
        case 48 where event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty && onSendTo != nil:
            onSendTo?(selected.entry); return
        case 49 where event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty:
            onPreview?(selected.entry); return
        case 51, 117: onDelete?(selected.entry); return
        case 53: onEscape?(); return
        default:
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "o" { onOpen?(selected.entry); return }
            super.keyDown(with: event); return
        }
        if let next { onNavigate?(); choose(tiles[min(max(0, next), tiles.count - 1)].entry.id) }
    }
}
