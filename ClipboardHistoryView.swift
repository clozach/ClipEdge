import AppKit

/// The ⌥⌘\ window's content: search and tabs above a compact list beside one
/// card, which turns over to its raw data (⌘I), with the available actions and
/// their keys along the bottom.
final class ClipboardHistoryView: ClipboardSurfaceView {
    /// The shared list. Its search holds the window's keyboard, so its tabs and rows refuse it; its
    /// tabs name their key once, in their title; the image-text note follows the count.
    let list: ClipboardBrowserList
    var keymap: ClipboardKeymap { list.keymap }
    var search: ClipboardSearchField { list.search }
    var tabs: ClipboardTabBar { list.tabs }
    var canvas: ClipboardCanvas { list.canvas }
    private var countLine: ClipboardCountLine { list.countLine }
    var selectButton: ClipboardSelectButton { list.selectButton }
    /// Alone in the top-right corner: nothing sits above it or to its right (Al, 2026-10-12).
    let publishControl = ClipboardPublishControl()
    let card: ClipboardHistoryCard
    /// The card's back: everything the selected entry holds, as copied, each part selectable and
    /// copyable on its own (Al, 2026-10-12).
    let raw: ClipboardRawDataView
    /// The card and its raw data, one place beside the list; ⌘I turns it.
    let flip: ClipboardFlipView
    /// *Raw data ⌘I* / *Preview ⌘I*: a magnet 9 points above the card's top-right corner, shown while
    /// the pointer is over the card or the card is turned.
    let flipMagnet: ClipboardFlipButton
    let sendTo = ClipboardSendToView()
    /// Maintainer copies only; nothing shows it elsewhere.
    let askView = ClipboardPreviewAskView()
    /// Multi-select's actions, in the card's place once anything is marked.
    let selectionPanel: ClipboardSelectionPanel
    let footer = ClipboardHistoryFooter()
    private let scroll = NSScrollView()
    private let divider = NSBox()
    /// The pointer is over the card or its magnet: the window's tracking area says so.
    private(set) var pointerOverCard = false
    private var cardTracking: NSTrackingArea?
    var currentTab: ClipboardBrowserTab { list.tab }
    var countText: String { countLine.count.stringValue }
    var emptyText: String? { countLine.empty.isHidden ? nil : countLine.empty.stringValue }
    /// The card, not Send to, the ask form or the selection's actions, has the place beside the list.
    var showsCard: Bool { !flip.isHidden }
    /// The card shows its raw data (or is turning to it).
    var showsRawData: Bool { showsCard && flip.side == .back }
    /// 308 (310 before 2026-10-12) so the tabs, each at its whole label, end at least 8 points short
    /// of Publish's widest title (*Review release… ⇧⌘P*) at the window's 800 points.
    private static let listWidth: CGFloat = 308
    /// A row and its 2-point gap: 46 at a thumbnail size of 100%.
    private var rowHeight: CGFloat { list.rowHeight(.compact) + 2 }
    private static let headerHeight: CGFloat = 66
    override var isFlipped: Bool { true }

    override convenience init(frame frameRect: NSRect) { self.init(frame: frameRect, keymap: .window) }
    init(frame frameRect: NSRect, keymap: ClipboardKeymap) {
        list = ClipboardBrowserList(keymap: keymap, home: .search, tooltips: .none, indexing: .appendedToCount)
        card = ClipboardHistoryCard(frame: .zero, keymap: keymap)
        raw = ClipboardRawDataView(keymap: keymap)
        flip = ClipboardFlipView(front: card, back: raw)
        flipMagnet = ClipboardFlipButton(keymap: keymap)
        selectionPanel = ClipboardSelectionPanel(keymap: keymap)
        super.init(frame: frameRect)
        surface = .card(radius: 12, clips: true)
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        canvas.setAccessibilityLabel("Clipboard history")
        sendTo.isHidden = true
        askView.isHidden = true
        selectionPanel.isHidden = true
        flipMagnet.isHidden = true
        flip.onTurn = { [weak self] side in self?.cardTurning(to: side) }
        // The back's text gives the keyboard back to the search, the window's home.
        raw.returnKeyboard = { [weak self] in
            guard let self, let window = self.window else { return }
            self.list.focusHome(in: window)
        }
        divider.boxType = .separator
        [search, tabs, publishControl, countLine.count, countLine.storage, selectButton, scroll, divider, flip, sendTo, askView, selectionPanel, footer,
         countLine.empty, flipMagnet].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The whole history; the list shows what its tab and search let through.
    func update(entries: [ClipboardEntry]) {
        list.entries = entries
        list.showTiles(style: .compact, liftedID: nil)
        needsLayout = true
        layoutSubtreeIfNeeded()
        showEntry(canvas.selected?.entry)
    }

    /// The selected entry on the card's front, and on its back while it is turned, so moving the
    /// selection compares one entry's raw data with the next. The back reads every flavor, so only then;
    /// a copy made from it, which only moves the entry's time, keeps what it shows (`keepShowing`).
    func showEntry(_ entry: ClipboardEntry?) {
        card.show(entry)
        if flip.side == .back { raw.keepShowing(entry) }
    }

    /// Every opening starts on the card's front, its back read afresh when it is next turned.
    func startOnFront() {
        flip.show(.front)
        raw.show(nil)
        hoverCard(false)
    }

    /// Turns the card; as it sets off to the back, the back reads the selected entry (`cardTurning`),
    /// since the turn starts from a snapshot of it.
    func turnCard(to side: ClipboardFlipView.Side, animated: Bool = true) {
        flip.turn(to: side, animated: animated)
    }

    /// A raw-data text view holding the keyboard gives it back to the search, its home here.
    func returnKeyboardFromRaw() { raw.giveBackKeyboard() }

    /// A turn sets off: to the back, the back reads the selected entry first (after any turn under
    /// way has landed, so nothing it lets go of is lost). The back gives the keyboard back as it is
    /// turned away, and lets go of what it read once hidden (`ClipboardFlipFace`).
    private func cardTurning(to side: ClipboardFlipView.Side) {
        if side == .back { raw.keepShowing(canvas.selected?.entry) }
        refreshFlipMagnet(turningTo: side)
    }

    /// The pointer came over the card or its magnet, or left both (fixtures say so directly).
    func hoverCard(_ over: Bool) {
        pointerOverCard = over
        refreshFlipMagnet()
    }
    override func mouseEntered(with event: NSEvent) {
        guard event.trackingArea === cardTracking else { return super.mouseEntered(with: event) }
        hoverCard(true)
    }
    override func mouseExited(with event: NSEvent) {
        guard event.trackingArea === cardTracking else { return super.mouseExited(with: event) }
        hoverCard(false)
    }

    /// The magnet shows with the card, while the pointer is over it or the card is turned, and
    /// offers the other side. A turn says where it is going before it sets off.
    private func refreshFlipMagnet(turningTo target: ClipboardFlipView.Side? = nil) {
        let side = target ?? flip.side
        flipMagnet.reflect(side)
        flipMagnet.isHidden = !showsCard || !(pointerOverCard || side == .back)
        needsLayout = true
    }

    /// The card, the Send to list, the ask form and the selection's actions share the space beside
    /// the list; only one shows at a time.
    func showSendTo(_ targets: [ClipboardSendTarget]) {
        sendTo.show(targets)
        show(sendTo)
    }
    func showAsk(for entry: ClipboardEntry) {
        show(askView)
        askView.begin(entry)
    }
    func showCard() { show(flip) }
    func showSelection(_ state: ClipboardSelectionPanel.State) {
        selectionPanel.show(state)
        show(selectionPanel)
        needsLayout = true
    }
    private func show(_ side: NSView) {
        for view in [flip, sendTo, askView, selectionPanel] as [NSView] { view.isHidden = view !== side }
        refreshFlipMagnet()
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        // The footer takes a second row for its hint when the buttons leave it no room.
        let footerHeight = footer.preferredHeight(for: w)
        let bodyHeight = bounds.height - footerHeight
        let listWidth = Self.listWidth
        search.frame = NSRect(x: 14, y: 12, width: listWidth - 20, height: 28)
        // Select ends the count line's row, its right edge under the search's.
        let select = selectButton.preferredWidth
        selectButton.frame = NSRect(x: search.frame.maxX - select, y: 41, width: select, height: 20)
        // The floppy warning, when it shows, starts the row; the count follows it.
        let countX = 18 + countLine.storageWidth
        let countWidth = max(0, selectButton.frame.minX - 4 - countX)
        let countHeight = max(16, ceil(countLine.count.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: countWidth, height: 1_000)).height ?? 16))
        countLine.count.frame = NSRect(x: countX, y: countHeight > 16 ? 40 : 44, width: countWidth, height: countHeight)
        countLine.storage.frame = NSRect(x: 18, y: countLine.count.frame.minY - 1, width: ClipboardStorageWarning.side, height: ClipboardStorageWarning.side)
        tabs.sizeToFit()
        tabs.frame.origin = NSPoint(x: listWidth + 16, y: 13)
        // The corner is Publish's alone, level with the tabs; they end at least 8 points short of it.
        publishControl.sizeToFit()
        publishControl.frame = NSRect(x: w - publishControl.frame.width - 16, y: 12,
                                      width: publishControl.frame.width, height: 22)
        // A count line wrapped beside Select pushes the list down rather than under it.
        let top = max(Self.headerHeight, countLine.count.frame.maxY)
        scroll.frame = NSRect(x: 8, y: top, width: listWidth - 8, height: bodyHeight - top - 4)
        divider.frame = NSRect(x: listWidth + 7, y: top - 14, width: 1, height: bodyHeight - top + 14)
        let side = NSRect(x: listWidth + 16, y: top - 8, width: w - listWidth - 24, height: bodyHeight - top + 4)
        flip.frame = side
        // Outside what the card paints (both faces start 14 points in), 9 points above its top-right
        // corner, right edges aligned: below the tabs and Publish's corner, never over either.
        let content = side.insetBy(dx: 14, dy: 14)
        let magnetWidth = ceil(flipMagnet.intrinsicContentSize.width) + 6
        flipMagnet.frame = NSRect(x: content.maxX - magnetWidth, y: content.minY - 9 - 20, width: magnetWidth, height: 20)
        trackCard(side.union(flipMagnet.frame))
        sendTo.frame = side
        askView.frame = side
        // Its own height, from the top of the card's place, as a magnet beside the list it acts on.
        let actions = side.insetBy(dx: 4, dy: 8)
        selectionPanel.frame = NSRect(x: actions.minX, y: actions.minY, width: actions.width,
                                      height: min(actions.height, selectionPanel.fittingHeight(width: actions.width)))
        footer.frame = NSRect(x: 0, y: bodyHeight, width: w, height: footerHeight)
        countLine.empty.frame = NSRect(x: 8, y: top + 40, width: listWidth - 8, height: 20)
        let width = scroll.contentSize.width
        let rowHeight = self.rowHeight
        canvas.frame.size = NSSize(width: width, height: max(scroll.contentSize.height, CGFloat(canvas.tiles.count) * rowHeight))
        for (index, tile) in canvas.tiles.enumerated() {
            tile.frame = NSRect(x: 0, y: CGFloat(index) * rowHeight, width: width, height: rowHeight - 2)
        }
        canvas.attachVisible()
    }

    /// Hover over the card and its magnet, the 9-point gap between them included, so the pointer
    /// can reach the magnet without it going.
    private func trackCard(_ rect: NSRect) {
        guard cardTracking?.rect != rect else { return }
        cardTracking.map(removeTrackingArea)
        let area = NSTrackingArea(rect: rect, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        cardTracking = area
    }
}
