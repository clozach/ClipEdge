import AppKit

/// What a step past the end of a list does: stop at that end (the arrows), or go round to the
/// other end (the ⌥⌘\ window's shortcut, pressed again, and its Send to list).
enum ClipboardListEnds {
    case stop, wrap

    /// Where `index` lands in a list of `count` (at least one).
    func index(_ index: Int, count: Int) -> Int {
        switch self {
        case .stop: return min(max(0, index), count - 1)
        case .wrap: return (index % count + count) % count
        }
    }
}

/// One keyboard stop for the list/grid. Arrow keys move its visible selection.
final class ClipboardCanvas: NSView {
    var tiles: [ClipboardTile] = []
    var columns = 1
    private(set) var selectedID: UUID?
    private(set) var liftedID: UUID?
    /// The row whose deletion waits for a second press, as its container holds it (the window's
    /// waiting delete; the drawer asks in an alert, so nothing waits there). Read, never kept: what
    /// lets go of it in the container lets go of it in the row.
    var armed: () -> UUID? = { nil }
    var armedID: UUID? { armed() }
    /// Multi-select's marks, as the list holds them. Read, never kept, as `armed` is.
    var marking: () -> ClipboardMarking = { .off }
    /// Its container's keys.
    let keymap: ClipboardKeymap
    /// Where its container's keyboard rests: on these cards (the drawer), which take it, or in the
    /// search (the window), which a click on a row leaves it in.
    let home: ClipboardKeyboardHome
    /// The container's answer to an action on an entry (a key's is the chosen entry, nil when the
    /// list is empty): true when it acted, false to pass a key on.
    var answer: (ClipboardBrowserAction, ClipboardEntry?) -> Bool = { _, _ in false }
    var onSelect: ((ClipboardEntry) -> Void)?
    var onNavigate: (() -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { home == .tiles }
    var selected: ClipboardTile? { tiles.first { $0.entry.id == selectedID } ?? tiles.first }
    /// Cards that appear or scroll under a still pointer must not take the selection from the
    /// keyboard: a hover counts only once the pointer has moved since the list or a key last
    /// moved the cards or the selection (the window's rule since 2026-10-04; the drawer's too, 2026-10-11).
    var pointer: () -> NSPoint = { NSEvent.mouseLocation }
    private var pointerAtRest: NSPoint?
    var hoverChooses: Bool { pointer() != pointerAtRest }
    private func keyboardTookSelection() { pointerAtRest = pointer() }

    init(keymap: ClipboardKeymap, home: ClipboardKeyboardHome) {
        self.keymap = keymap
        self.home = home
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { scrollObserver.map(NotificationCenter.default.removeObserver) }

    // MARK: Rows near what shows

    /// Only the cards within a screen of what shows are in the view tree (2026-10-16): a history of
    /// thousands would otherwise lay out, track and draw every one. The rest are dormant shells
    /// (`ClipboardTile`), placed but not attached. Runs after each layout and each scroll.
    func attachVisible() {
        // What the scroll view shows, not `visibleRect`: that is also clipped by the window, and the
        // drawer's window is the tab's size while it is closed, so only the top row counted as shown;
        // opening grows the window without a layout, and the rest never arrived (2026-10-16).
        let shown = enclosingScrollView?.documentVisibleRect ?? visibleRect
        let near = shown.isEmpty ? shown : shown.insetBy(dx: 0, dy: -max(shown.height, 300))
        // A card not yet placed (an empty frame at the origin) is not near anything.
        let wanted = tiles.filter { !$0.frame.isEmpty && $0.frame.intersects(near) }
        let keep = Set(wanted.map(ObjectIdentifier.init))
        for case let tile as ClipboardTile in subviews where !keep.contains(ObjectIdentifier(tile)) { tile.removeFromSuperview() }
        // Under those already there, so a card raised for its move stays on top.
        for tile in wanted where tile.superview !== self { addSubview(tile, positioned: .below, relativeTo: nil) }
    }
    /// Whether a card is in the view tree now.
    func isAttached(_ tile: ClipboardTile) -> Bool { tile.superview === self }
    private var scrollObserver: NSObjectProtocol?
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        scrollObserver.map(NotificationCenter.default.removeObserver)
        scrollObserver = nil
        guard let clip = superview as? NSClipView else { return }
        clip.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: nil) { [weak self] _ in
            self?.attachVisible()
        }
    }

    func choose(_ id: UUID, reveal: Bool = true) {
        guard tiles.contains(where: { $0.entry.id == id }) else { return }
        ClipboardTileTooltip.shared.hide()
        selectedID = id
        tiles.forEach { $0.refreshSelection() }
        if reveal, let selected { scrollToVisible(selected.frame.insetBy(dx: -3, dy: -3)) }
        if let selected { onSelect?(selected.entry) }
    }
    /// The container's waiting delete changed: the rows show and say it.
    func refreshArming() { tiles.forEach { $0.refreshSelection() } }
    /// The marks changed: each card shows its circle (sliding aside as marking turns on or off,
    /// when `animated`) and says whether it is selected.
    func refreshMarking(animated: Bool) { tiles.forEach { $0.refreshMarking(animated: animated) } }
    func reconcile(liftedID: UUID?) {
        self.liftedID = liftedID
        keyboardTookSelection()
        selectedID = selectedID.flatMap { id in tiles.contains { $0.entry.id == id } ? id : nil } ?? tiles.first?.entry.id
        tiles.forEach { $0.refreshSelection() }
    }
    override func becomeFirstResponder() -> Bool {
        if let selected { choose(selected.entry.id) }
        return true
    }
    override func resignFirstResponder() -> Bool {
        return true
    }
    /// An arrow's step from the chosen entry, stopping at the ends, or going round them (the
    /// window's shortcut). False when nothing is chosen.
    @discardableResult
    func step(_ action: ClipboardBrowserAction, ends: ClipboardListEnds = .stop) -> Bool {
        guard let delta = action.step(columns: columns), let selected, let index = tiles.firstIndex(of: selected) else { return false }
        chooseByKey(tiles[ends.index(index + delta, count: tiles.count)].entry.id)
        return true
    }
    /// A card chosen from the keyboard (an arrow, ⇧↑ ⇧↓), shown, and kept under a still pointer.
    func chooseByKey(_ id: UUID) {
        onNavigate?()
        keyboardTookSelection()
        choose(id)
    }
    /// Its container's keys while the cards hold the keyboard (the drawer's); any other key passes on.
    override func keyDown(with event: NSEvent) {
        guard let action = keymap.action(for: event) else { super.keyDown(with: event); return }
        if event.isARepeat, action.waitsForNextPress { return }
        let acted = action.step(columns: columns) != nil ? step(action) : answer(action, selected?.entry)
        if !acted { super.keyDown(with: event) }
    }
}
