import AppKit

/// The ⌥⌘\ window's content: search and tabs above a compact list beside one
/// card, with the available actions and their keys along the bottom.
final class ClipboardHistoryView: NSView {
    let search = NSSearchField()
    let tabs = NSSegmentedControl(labels: ["All ⌘1", "Images ⌘2", "Text ⌘3"], trackingMode: .selectOne, target: nil, action: nil)
    let deleteAll = NSButton(title: "Delete all ⇧⌘⌫", target: nil, action: nil)
    let canvas = ClipboardCanvas()
    let card = ClipboardHistoryCard()
    let sendTo = ClipboardSendToView()
    let confirmation = ClipboardHistoryConfirmation()
    let footer = ClipboardHistoryFooter()
    private let count = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let empty = NSTextField(labelWithString: "Copy something to begin")
    private let divider = NSBox()
    private var tiles: [UUID: ClipboardTile] = [:]
    /// Rows that appear or scroll under a still pointer must not take the
    /// selection from the keyboard: hover counts only once the pointer moves.
    var pointer: () -> NSPoint = { NSEvent.mouseLocation }
    private var pointerAtRest: NSPoint?
    func keyboardTookSelection() { pointerAtRest = pointer() }
    var currentTab: ClipboardBrowserTab { ClipboardBrowserTab(rawValue: tabs.selectedSegment) ?? .all }
    var countText: String { count.stringValue }
    var emptyText: String? { empty.isHidden ? nil : empty.stringValue }
    private static let listWidth: CGFloat = 310
    private static let rowHeight: CGFloat = 46
    private static let headerHeight: CGFloat = 66
    private static let footerHeight: CGFloat = 38
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        search.placeholderString = "Type to search clipboard and image text"
        search.setAccessibilityLabel("Search clipboard and image text")
        search.sendsSearchStringImmediately = true
        search.focusRingType = .none
        tabs.selectedSegment = 0
        tabs.refusesFirstResponder = true // Typing stays in the search field; ⌘1–⌘3 switch tabs.
        tabs.setAccessibilityLabel("Clipboard view")
        deleteAll.bezelStyle = .accessoryBarAction
        deleteAll.showsBorderOnlyWhileMouseInside = true
        deleteAll.font = .systemFont(ofSize: 11, weight: .medium)
        deleteAll.refusesFirstResponder = true
        deleteAll.toolTip = "Delete all history permanently: press Shift-Command-Delete twice"
        deleteAll.setAccessibilityLabel(deleteAll.toolTip)
        count.font = .systemFont(ofSize: 11)
        count.textColor = .secondaryLabelColor
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        canvas.columns = 1
        canvas.acceptsKeyboard = false
        canvas.setAccessibilityLabel("Clipboard history")
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        sendTo.isHidden = true
        confirmation.isHidden = true
        divider.boxType = .separator
        [search, tabs, deleteAll, count, scroll, divider, card, sendTo, confirmation, footer, empty].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(entries: [ClipboardEntry], total: [ClipboardEntry]) {
        let previous = canvas.tiles
        let retained = Set(total.map(\.id))
        tiles = tiles.filter { retained.contains($0.key) }
        canvas.tiles = entries.map { entry in
            let tile = tiles[entry.id] ?? makeTile(entry)
            tiles[entry.id] = tile
            tile.refreshEntryPresentation()
            if tile.superview !== canvas { canvas.addSubview(tile) }
            return tile
        }
        let shown = Set(canvas.tiles.map(ObjectIdentifier.init))
        previous.filter { !shown.contains(ObjectIdentifier($0)) }.forEach { $0.removeFromSuperview() }
        canvas.reconcile(liftedID: nil)
        let note = ClipboardIndexingNote(total)
        count.stringValue = (["\(entries.count) of \(total.count) items"] + (note.map { [$0.text] } ?? [])).joined(separator: " · ")
        count.toolTip = note?.help
        empty.stringValue = total.isEmpty ? "Copy something to begin" : "No matching items"
        empty.isHidden = !entries.isEmpty
        needsLayout = true
        layoutSubtreeIfNeeded()
        card.show(canvas.selected?.entry)
    }

    /// The card, the Send to list and the delete-all question share the space
    /// beside the list; only one shows at a time.
    func showSendTo(_ targets: [ClipboardSendTarget]) {
        sendTo.show(targets)
        show(sendTo)
    }
    func showConfirmation(count: Int) {
        confirmation.show(count: count)
        show(confirmation)
    }
    func showCard() { show(card) }
    private func show(_ side: NSView) {
        for view in [card, sendTo, confirmation] as [NSView] { view.isHidden = view !== side }
    }

    private func makeTile(_ entry: ClipboardEntry) -> ClipboardTile {
        let tile = ClipboardTile(entry: entry, style: .compact)
        tile.onPick = { [weak self] in
            self?.canvas.choose(entry.id, reveal: false)
            self?.canvas.onPick?(entry)
        }
        tile.onHover = { [weak self] in
            guard let self, self.pointer() != self.pointerAtRest else { return }
            self.canvas.choose(entry.id, reveal: false)
        }
        return tile
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let bodyHeight = bounds.height - Self.footerHeight
        let listWidth = Self.listWidth
        search.frame = NSRect(x: 14, y: 12, width: listWidth - 20, height: 28)
        count.frame = NSRect(x: 18, y: 44, width: listWidth - 26, height: 16)
        tabs.sizeToFit()
        tabs.frame.origin = NSPoint(x: listWidth + 16, y: 13)
        deleteAll.sizeToFit()
        deleteAll.frame = NSRect(x: w - deleteAll.frame.width - 18, y: 15, width: deleteAll.frame.width + 6, height: 22)
        let top = Self.headerHeight
        scroll.frame = NSRect(x: 8, y: top, width: listWidth - 8, height: bodyHeight - top - 4)
        divider.frame = NSRect(x: listWidth + 7, y: top - 14, width: 1, height: bodyHeight - top + 14)
        let side = NSRect(x: listWidth + 16, y: top - 8, width: w - listWidth - 24, height: bodyHeight - top + 4)
        card.frame = side
        sendTo.frame = side
        confirmation.frame = side.insetBy(dx: 4, dy: 8)
        footer.frame = NSRect(x: 0, y: bodyHeight, width: w, height: Self.footerHeight)
        empty.frame = NSRect(x: 8, y: top + 40, width: listWidth - 8, height: 20)
        let width = scroll.contentSize.width
        canvas.frame.size = NSSize(width: width, height: max(scroll.contentSize.height, CGFloat(canvas.tiles.count) * Self.rowHeight))
        for (index, tile) in canvas.tiles.enumerated() {
            tile.frame = NSRect(x: 0, y: CGFloat(index) * Self.rowHeight, width: width, height: Self.rowHeight - 2)
        }
    }
}
