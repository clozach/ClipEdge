import AppKit
import QuartzCore

/// The drawer's content: the shared list (tabs, Select, search, count line and cards) laid out
/// down the drawer, with the image zoom.
final class ClipboardBrowserView: NSView {
    /// The drawer's cards hold its keyboard; its tabs name their key in a tooltip too; the image-text
    /// note takes the Quick Look hint's place.
    let list: ClipboardBrowserList
    var keymap: ClipboardKeymap { list.keymap }
    var tabs: ClipboardTabBar { list.tabs }
    var search: ClipboardSearchField { list.search }
    var canvas: ClipboardCanvas { list.canvas }
    private var countLine: ClipboardCountLine { list.countLine }
    var selectButton: ClipboardSelectButton { list.selectButton }
    let zoom = NSSlider(value: 2, minValue: 1, maxValue: 3, target: nil, action: nil)
    private let scroll = NSScrollView()
    var quickLookHint = "⌃⌥Space" { didSet { rebuild() } }
    private let zoomLabels = ["3 across", "2", "1"].map { NSTextField(labelWithString: $0) }
    private var attachedID: UUID?
    private var layoutTargets: [ObjectIdentifier: NSRect] = [:]
    private var pendingPromotion: UUID?
    var onInteraction: (() -> Void)? { get { list.onInteraction } set { list.onInteraction = newValue } }
    /// The drawer's answer to an action on an entry; the search and the tabs are the list's own.
    var perform: (ClipboardBrowserAction, ClipboardEntry?) -> Bool { get { list.perform } set { list.perform = newValue } }
    var onHover: ((ClipboardEntry) -> Void)? { get { list.onHover } set { list.onHover = newValue } }
    var onVisibleEntriesChange: (() -> Void)?
    /// Where Tab goes after the drawer's last control (Select): the header's gear, given by the
    /// drawer; the search when nothing is.
    weak var keyLoopExit: NSView? { didSet { refreshKeyLoop() } }
    var currentTab: ClipboardBrowserTab { list.tab }
    var imagesOnly: Bool { currentTab == .images }
    var columns: Int { imagesOnly ? 4 - Int(zoom.doubleValue.rounded()) : 1 }
    var visibleEntries: [ClipboardEntry] { list.visibleEntries }
    override var isFlipped: Bool { true }

    override convenience init(frame frameRect: NSRect) { self.init(frame: frameRect, keymap: .drawer) }
    init(frame frameRect: NSRect, keymap: ClipboardKeymap) {
        list = ClipboardBrowserList(keymap: keymap, home: .tiles, tooltips: .keys, indexing: .ownLabel)
        super.init(frame: frameRect)
        list.onFilterChange = { [weak self] _ in self?.filterChanged() }
        zoom.numberOfTickMarks = 3
        zoom.allowsTickMarkValuesOnly = true
        zoom.isContinuous = true
        zoom.target = self; zoom.action = #selector(zoomChanged)
        zoom.setAccessibilityLabel("Image size: 3, 2, or 1 across")
        zoomLabels.forEach { $0.font = .systemFont(ofSize: 10); $0.textColor = .secondaryLabelColor; addSubview($0) }
        zoomLabels[1].alignment = .center
        zoomLabels[2].alignment = .right
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        [tabs, selectButton, search, zoom, scroll, countLine.count, countLine.storage, countLine.empty, countLine.note].forEach(addSubview)
        search.nextKeyView = canvas
        canvas.nextKeyView = tabs
        refreshKeyLoop()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    func update(entries: [ClipboardEntry], attachedID: UUID?) {
        list.entries = entries
        self.attachedID = attachedID
        rebuild(animatePromotion: true)
    }
    private func filterChanged() { rebuild(); scroll.contentView.scroll(to: .zero) }
    /// F or ⌘F from the cards: the keyboard goes to the search, its text selected so typing replaces it.
    func focusSearch() { list.focusSearch(selectingAll: true) }
    /// A tab chosen by its number key; the keyboard stays with the cards, and the card they act on
    /// stays in view, as zooming keeps it.
    func choose(_ tab: ClipboardBrowserTab) { list.choose(tab) }
    @objc private func zoomChanged() { layoutTiles(); canvas.selected.map { canvas.choose($0.entry.id) } }
    @objc private func scrolled() { ClipboardTileTooltip.shared.hide(); window?.invalidateCursorRects(for: canvas) }

    private func rebuild(animatePromotion: Bool = false) {
        let previousTiles = canvas.tiles
        let visible = visibleEntries
        pendingPromotion = animatePromotion && previousTiles.first?.imageOnly == imagesOnly
            ? Self.promotedEntry(from: previousTiles.map { $0.entry.id }, to: visible.map(\.id)) : nil
        let next = ClipboardHint.key(ClipboardKeyLabel(shown: quickLookHint, spoken: quickLookHint))
        countLine.resting = ("Quick Look  " + (keymap.key(.quickLook).map { .key($0) + " · " } ?? "") + next,
                             "\(keymap.help("Quick Look hovered item", .quickLook))\nNext clipboard item ← \(quickLookHint)")
        list.showTiles(style: imagesOnly ? .image : .row, liftedID: attachedID)
        let displayed = Set(canvas.tiles.map(ObjectIdentifier.init))
        layoutTargets = layoutTargets.filter { displayed.contains($0.key) }
        if let id = pendingPromotion, let promoted = canvas.tiles.first(where: { $0.entry.id == id }) {
            canvas.addSubview(promoted, positioned: .above, relativeTo: nil)
        }
        zoom.isHidden = !imagesOnly
        zoomLabels.forEach { $0.isHidden = !imagesOnly }
        refreshKeyLoop()
        needsLayout = true
        layoutSubtreeIfNeeded()
        if let id = canvas.selectedID { canvas.choose(id, reveal: false) }
        if previousTiles.map({ $0.entry.id }) != visible.map(\.id) { onVisibleEntriesChange?() }
    }
    /// search → cards → tabs → (zoom, under Images) → Select → `keyLoopExit` → … → search, as
    /// Clear… sat in it before Select took its place.
    private func refreshKeyLoop() {
        tabs.nextKeyView = imagesOnly ? zoom : selectButton
        zoom.nextKeyView = selectButton
        selectButton.nextKeyView = keyLoopExit ?? search
    }
    /// Only a move-to-front qualifies. Filtering, insertion and OCR refreshes don't animate.
    static func promotedEntry(from previous: [UUID], to current: [UUID]) -> UUID? {
        guard previous.count == current.count, let first = current.first,
              previous.first != first, previous.contains(first),
              previous.filter({ $0 != first }) == Array(current.dropFirst()) else { return nil }
        return first
    }
    override func layout() {
        super.layout()
        let w = bounds.width
        // Select at the tabs' right, where Clear… was, as wide as Done or Select needs, level with
        // the tabs' middle; the tabs as tall as their size draws them, everything below after them.
        // A drawer dragged too narrow for both (2026-10-16) puts Select under the search, at the end
        // of the count line, as the ⌥⌘\ window does, so the tabs keep their whole names and keys.
        let select = selectButton.preferredWidth
        let tabsHeight = tabs.intrinsicContentSize.height
        let besideTabs = tabs.naturalWidth + 8 + select <= w - 32
        let tabsWidth = max(0, besideTabs ? w - 32 - select - 8 : w - 32)
        tabs.fill(width: tabsWidth)
        tabs.frame = NSRect(x: 16, y: 17, width: max(tabsWidth, tabs.fittingSize.width), height: tabsHeight)
        search.frame = NSRect(x: 16, y: tabs.frame.maxY + 10, width: w - 32, height: 26)
        let countY = search.frame.maxY + 8
        selectButton.frame = besideTabs ? NSRect(x: w - 16 - select, y: round(tabs.frame.midY - 12), width: select, height: 24)
            : NSRect(x: w - 16 - select, y: countY - 3, width: select, height: 24)
        let countRight = besideTabs ? w - 16 : selectButton.frame.minX - 8
        let countWidth = max(94, ceil(countLine.count.fittingSize.width))
        countLine.count.frame = NSRect(x: countRight - countWidth, y: countY, width: countWidth, height: 18)
        // The floppy warning, when it shows, just before the count's words.
        countLine.storage.frame = NSRect(x: countLine.count.frame.minX - countLine.storageWidth, y: countY, width: ClipboardStorageWarning.side, height: ClipboardStorageWarning.side)
        let noteWidth = max(0, countLine.count.frame.minX - countLine.storageWidth - 4 - 16)
        let noteHeight = max(18, ceil(countLine.note.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: noteWidth, height: 1_000)).height ?? 18))
        countLine.note.frame = NSRect(x: 16, y: countY, width: noteWidth, height: noteHeight)
        let below = countY + 10 + noteHeight
        zoom.frame = NSRect(x: 23, y: below, width: w - 46, height: 21)
        zoomLabels[0].frame = NSRect(x: 23, y: below + 23, width: 80, height: 18)
        zoomLabels[1].frame = NSRect(x: w / 2 - 40, y: below + 23, width: 80, height: 18)
        zoomLabels[2].frame = NSRect(x: w - 103, y: below + 23, width: 80, height: 18)
        let top: CGFloat = imagesOnly ? below + 50 : below
        scroll.frame = NSRect(x: 12, y: top, width: w - 24, height: max(0, bounds.height - top - 12))
        countLine.empty.frame = NSRect(x: 24, y: top + 50, width: w - 48, height: 50)
        layoutTiles()
    }
    private func layoutTiles() {
        let width = scroll.contentSize.width
        let gap: CGFloat = 8
        let columns = self.columns
        canvas.columns = columns
        let side = floor((width - gap * CGFloat(columns - 1)) / CGFloat(columns))
        let height: CGFloat = imagesOnly ? side : list.rowHeight(.row)
        let rows = Int(ceil(Double(canvas.tiles.count) / Double(columns)))
        canvas.frame.size = NSSize(width: width, height: max(scroll.contentSize.height, CGFloat(rows) * (height + gap)))
        let animate = pendingPromotion != nil && window?.isVisible == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        pendingPromotion = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animate ? 0.3 : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for (index, tile) in canvas.tiles.enumerated() {
                let frame = NSRect(x: CGFloat(index % columns) * (side + gap), y: CGFloat(index / columns) * (height + gap), width: side, height: height)
                let key = ObjectIdentifier(tile)
                // An unrelated refresh must not snap or restart an in-flight move.
                guard layoutTargets[key] != frame else { continue }
                if animate, layoutTargets[key] != nil { tile.animator().frame = frame }
                else { tile.layer?.removeAllAnimations(); tile.frame = frame }
                layoutTargets[key] = frame
            }
        }
        canvas.attachVisible()
    }
    func screenFrame(for id: UUID) -> NSRect? {
        guard let window, let tile = canvas.tiles.first(where: { $0.entry.id == id }) else { return nil }
        return window.convertToScreen(tile.convert(tile.bounds, to: nil))
    }
    func reveal(_ id: UUID) { canvas.choose(id) }
}
