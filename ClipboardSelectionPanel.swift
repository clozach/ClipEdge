import AppKit

/// Multi-select's actions (Al, 2026-10-12): a magnet summoned while one or more cards are marked.
/// One view for both containers: the ⌥⌘\ window shows it in the card's place, the drawer beside
/// its edge in a panel that leaves the keyboard with the cards. Built from the container's keymap:
/// an action shows only where that keymap gives it a key, so the two differ by injection alone,
/// and each button's title carries its key. Beneath its heading it names every marked item, each title
/// whole and wrapped (a list taller than a few lines scrolls), so what its actions touch can always be
/// read, even where the cards cut titles short. The buttons wrap onto as many rows as they need, never
/// cut short, refuse the keyboard (the cards or the search keep it), and one that cannot act now is
/// dimmed with its reason in its tooltip.
final class ClipboardSelectionPanel: ClipboardSurfaceView {
    /// What it shows.
    struct State: Equatable {
        /// How many cards are marked, at least one.
        var count = 1
        /// The marked cards' titles, in the order shown.
        var titles: [String] = []
        /// Every card shown is marked, so Select all reads Select none.
        var everyShownMarked = false
        /// 🚨 A first delete press is waiting for its second (the window's; the drawer asks in an alert).
        var askingToDelete = false
        /// Why an action cannot act now, in words; absent when it can.
        var unavailable: [ClipboardBrowserAction: String] = [:]
    }
    /// A button's press: the container answers it as it answers the button's key.
    var onAction: ((ClipboardBrowserAction) -> Void)?
    private(set) var state = State()
    let keymap: ClipboardKeymap
    /// The actions a set can take, in the order they show; each only where the keymap has a key for it.
    static let catalog: [ClipboardBrowserAction] = [.pickUp, .plainPaste, .open, .delete, .markAll]
    let actions: [ClipboardBrowserAction]
    private let heading = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let keys = NSTextField(wrappingLabelWithString: "")
    /// What `keys` says, its key in a cap.
    private var keysHint = ClipboardHint([])
    /// The marked items, one title per line: whole, wrapped, and scrolled past `listCap`.
    private let list = NSScrollView()
    private let listText = NSTextView()
    private let buttons: [ClipboardBrowserAction: ClipboardKeyedButton]
    /// The marked items' list grows to this height, then scrolls.
    private static let listCap: CGFloat = 132
    override var isFlipped: Bool { true }

    var headingText: String { heading.stringValue }
    var detailText: String? { detail.isHidden ? nil : detail.stringValue }
    var keysText: String? { keys.isHidden ? nil : keysHint.plain }
    /// The marked items as listed, one per line.
    var listedTitles: String { listText.string }
    var listFrame: NSRect { list.frame }
    /// The list's whole height at its width: what scrolls when it is taller than the panel shows.
    var listContentHeight: CGFloat { listHeight(width: list.frame.width) }
    /// Each button shown, in order: its title, whether it can act, and its tooltip.
    var shownButtons: [(action: ClipboardBrowserAction, title: String, enabled: Bool, help: String)] {
        actions.compactMap { action in buttons[action].map { (action, $0.keyedTitle.plain, $0.isEnabled, $0.toolTip ?? "") } }
    }
    func button(_ action: ClipboardBrowserAction) -> NSButton? { buttons[action] }

    init(keymap: ClipboardKeymap) {
        self.keymap = keymap
        actions = Self.catalog.filter { keymap.label($0) != nil }
        var made: [ClipboardBrowserAction: ClipboardKeyedButton] = [:]
        for action in actions {
            let button = ClipboardKeyedButton(title: "", target: nil, action: #selector(pressed(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11, weight: .medium)
            button.refusesFirstResponder = true // The cards or the search keep the keyboard; the keys in the titles act.
            made[action] = button
        }
        buttons = made
        super.init(frame: .zero)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        detail.font = .systemFont(ofSize: 12)
        keys.font = .systemFont(ofSize: 12, weight: .medium)
        keys.textColor = .systemRed
        [heading, detail, keys].forEach { $0.isSelectable = false; addSubview($0) }
        listText.isEditable = false
        listText.isSelectable = false // The cards or the search keep the keyboard; the list is read, or scrolled.
        listText.isRichText = false
        listText.drawsBackground = false
        listText.textContainerInset = .zero
        listText.textContainer?.lineFragmentPadding = 0
        listText.textContainer?.widthTracksTextView = true
        listText.isVerticallyResizable = true
        listText.isHorizontallyResizable = false
        listText.font = .systemFont(ofSize: 12)
        listText.textColor = .secondaryLabelColor
        listText.setAccessibilityLabel("Selected items")
        list.documentView = listText
        list.hasVerticalScroller = true
        list.autohidesScrollers = true
        list.drawsBackground = false
        addSubview(list)
        for action in actions { buttons[action]?.target = self; buttons[action].map(addSubview) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        show(State())
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func pressed(_ sender: NSButton) {
        guard let action = actions.first(where: { buttons[$0] === sender }) else { return }
        onAction?(action)
    }

    /// How a button reads, and what its tooltip says, for `state`.
    private func name(_ action: ClipboardBrowserAction) -> String {
        switch action {
        case .pickUp: return "Copy as text"
        case .plainPaste: return "Paste as text"
        case .open: return "Open in Preview"
        case .delete: return "Delete \(state.count)…"
        default: return state.everyShownMarked ? "Select none" : "Select all"
        }
    }
    private func help(_ action: ClipboardBrowserAction, _ key: String) -> String {
        switch action {
        case .pickUp: return "Put the selected items' text on the clipboard as one copy, one item per line (\(key))"
        case .plainPaste: return "Paste the selected items' text where you were, one item per line (\(key))"
        case .open: return "Open each selected item in the Preview app (\(key))"
        case .delete: return "Delete the selected items permanently; it asks first (\(key))"
        default: return state.everyShownMarked ? "Unselect every item (\(key))" : "Select every item shown (\(key))"
        }
    }

    func show(_ new: State) {
        state = new
        let deletion = ClipboardDeletion.marked(count: new.count)
        if new.askingToDelete {
            surface = ClipboardSurface(fill: .init(color: .systemRed, opacity: 0.06), rim: .systemRed, radius: 10)
            heading.stringValue = deletion.question
            heading.textColor = .systemRed
            detail.stringValue = deletion.consequence
            keysHint = keymap.key(.delete).map(deletion.keys(confirm:)) ?? ClipboardHint([])
            keys.attributedStringValue = keysHint.attributed(font: keys.font ?? .systemFont(ofSize: 11), color: keys.textColor ?? .secondaryLabelColor)
        } else {
            surface = .card(radius: 10)
            heading.stringValue = "\(new.count) selected"
            heading.textColor = .labelColor
        }
        detail.isHidden = !new.askingToDelete
        keys.isHidden = !new.askingToDelete || keysHint.isEmpty
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.headIndent = 10
        paragraph.paragraphSpacing = 3
        listText.textStorage?.setAttributedString(NSAttributedString(string: new.titles.map { "• \($0)" }.joined(separator: "\n"), attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph]))
        list.isHidden = new.titles.isEmpty
        for action in actions {
            guard let button = buttons[action] else { continue }
            let reason = new.unavailable[action]
            button.keyedTitle = keymap.keyed(name(action), action)
            button.isEnabled = reason == nil
            button.toolTip = reason ?? help(action, keymap.label(action) ?? "")
            let spoken = keymap.spoken(action).map { ", \($0)" } ?? ""
            button.setAccessibilityLabel(reason.map { "\(name(action))\(spoken). Unavailable: \($0)" } ?? "\(name(action))\(spoken)")
        }
        setAccessibilityLabel(new.askingToDelete ? ([deletion.question, deletion.consequence] + [keysHint.isEmpty ? nil : keysHint.spoken].compactMap { $0 }).joined(separator: " ") : heading.stringValue)
        needsLayout = true
    }

    // MARK: Layout

    private static let inset: CGFloat = 14
    private static let rowHeight: CGFloat = 24
    private static let gap: CGFloat = 8
    private static let rowGap: CGFloat = 6

    /// The buttons in rows at this width, each as wide as its title needs: one that would cross the
    /// right inset starts the next row, so none is ever clipped. Measured, never resized.
    private func rows(width: CGFloat) -> [[(button: NSButton, width: CGFloat)]] {
        var rows: [[(button: NSButton, width: CGFloat)]] = [[]]
        var x = Self.inset
        for action in actions {
            guard let button = buttons[action] else { continue }
            let wanted = ceil(button.intrinsicContentSize.width) + 8
            if x + wanted > width - Self.inset, !rows[rows.count - 1].isEmpty { rows.append([]); x = Self.inset }
            rows[rows.count - 1].append((button, wanted))
            x += wanted + Self.gap
        }
        return rows
    }
    private func labels() -> [NSTextField] { [heading, detail, keys].filter { !$0.isHidden } }
    private func height(_ label: NSTextField, inner: CGFloat) -> CGFloat {
        ceil(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: inner, height: 10_000)).height ?? 18)
    }

    /// The list's whole height at this width, every title wrapped: measured from its words alone, so the
    /// same before and after the panel is laid out.
    private func listHeight(width: CGFloat) -> CGFloat {
        guard !list.isHidden, let words = listText.textStorage, words.length > 0 else { return 0 }
        return ceil(words.boundingRect(with: NSSize(width: max(1, width), height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
    }
    /// The height the list takes in the panel: all of it, up to `listCap`.
    private func listRoom(inner: CGFloat) -> CGFloat {
        list.isHidden ? 0 : min(Self.listCap, listHeight(width: inner)) + 8
    }

    /// Its height at this width: every line of its words, the list of what is marked and every row of buttons.
    func fittingHeight(width: CGFloat) -> CGFloat {
        let inner = width - Self.inset * 2
        let words = labels().reduce(CGFloat(12)) { $0 + height($1, inner: inner) + 8 }
        let count = CGFloat(rows(width: width).count)
        return words + listRoom(inner: inner) + 4 + count * Self.rowHeight + max(0, count - 1) * Self.rowGap + 14
    }

    override func layout() {
        super.layout()
        let inner = bounds.width - Self.inset * 2
        var y: CGFloat = 12
        for label in labels() {
            label.frame = NSRect(x: Self.inset, y: y, width: inner, height: height(label, inner: inner))
            y = label.frame.maxY + 8
        }
        if !list.isHidden {
            let room = listRoom(inner: inner) - 8
            list.frame = NSRect(x: Self.inset, y: y, width: inner, height: room)
            listText.frame = NSRect(x: 0, y: 0, width: list.contentSize.width, height: max(room, listHeight(width: list.contentSize.width)))
            y = list.frame.maxY + 8
        }
        y += 4
        for row in rows(width: bounds.width) {
            var x = Self.inset
            for (button, width) in row {
                button.frame = NSRect(x: x, y: y, width: width, height: Self.rowHeight)
                x = button.frame.maxX + Self.gap
            }
            y += Self.rowHeight + Self.rowGap
        }
    }
}

/// The drawer's selection actions, in a panel beside it that leaves the keyboard with the cards, so
/// marking goes on by key while it shows.
final class ClipboardSelectionPopover {
    let view: ClipboardSelectionPanel
    private let host: ClipboardDrawerSidePanel
    static let width: CGFloat = 280
    var isVisible: Bool { host.isVisible }
    var textScale: () -> CGFloat { get { host.textScale } set { host.textScale = newValue } }
    var frame: NSRect { host.frame }

    init(keymap: ClipboardKeymap, panel suppliedPanel: NSPanel? = nil) {
        view = ClipboardSelectionPanel(keymap: keymap)
        host = ClipboardDrawerSidePanel(title: "ClipEdge Selection", content: view, keyboard: .leaves, panel: suppliedPanel)
    }

    /// `place` receives the panel's wanted size and returns its on-screen frame.
    func show(_ state: ClipboardSelectionPanel.State, place: (NSSize) -> NSRect) {
        view.show(state)
        self.place(place)
    }

    /// Moved to follow the drawer (its tab dragged, its edge changed), showing what it showed: nothing
    /// is read again for a move.
    func place(_ place: (NSSize) -> NSRect) {
        host.show(at: place(host.scaled(NSSize(width: Self.width, height: view.fittingHeight(width: Self.width)))), keyboardOn: nil)
    }

    func close() { host.close() }
}
