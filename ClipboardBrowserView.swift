import AppKit
import QuartzCore

enum ClipboardBrowserTab: Int, CaseIterable {
    case all, images, text
    var title: String { switch self { case .all: return "All"; case .images: return "Images"; case .text: return "Text" } }
    func includes(_ entry: ClipboardEntry) -> Bool {
        switch self {
        case .all: return true
        case .images: return entry.isImage
        case .text: return entry.kind == .text || entry.kind == .link || (entry.kind == .other && entry.plainText != nil)
        }
    }
}

final class ClipboardBrowserView: NSView, NSSearchFieldDelegate {
    let tabs = NSSegmentedControl(labels: ClipboardBrowserTab.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    let search = NSSearchField()
    let zoom = NSSlider(value: 2, minValue: 1, maxValue: 3, target: nil, action: nil)
    let canvas = ClipboardCanvas()
    private let scroll = NSScrollView()
    private let count = NSTextField(labelWithString: "")
    private let empty = NSTextField(wrappingLabelWithString: "Copy something to begin")
    private let shortcut = NSTextField(labelWithString: "Quick Look  ⌃⌥Space")
    var quickLookHint = "⌃⌥Space" { didSet { rebuild() } }
    private let zoomLabels = ["3 across", "2", "1"].map { NSTextField(labelWithString: $0) }
    private var entries: [ClipboardEntry] = []
    private var attachedID: UUID?
    private struct TileKey: Hashable { let id: UUID; let imageOnly: Bool }
    private var cachedTiles: [TileKey: ClipboardTile] = [:]
    private var layoutTargets: [ObjectIdentifier: NSRect] = [:]
    private var pendingPromotion: UUID?
    var onInteraction: (() -> Void)?
    var onHover: ((ClipboardEntry) -> Void)?
    var onVisibleEntriesChange: (() -> Void)?
    var onClear: (() -> Void)?
    let clear = NSButton(title: "Clear…", target: nil, action: nil)
    var currentTab: ClipboardBrowserTab { ClipboardBrowserTab(rawValue: tabs.selectedSegment) ?? .all }
    var imagesOnly: Bool { currentTab == .images }
    var columns: Int { imagesOnly ? 4 - Int(zoom.doubleValue.rounded()) : 1 }
    var visibleEntries: [ClipboardEntry] { entries.filter { currentTab.includes($0) && $0.matches(search.stringValue) } }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        tabs.selectedSegment = 0
        tabs.target = self; tabs.action = #selector(filterChanged)
        tabs.setAccessibilityLabel("Clipboard view")
        search.placeholderString = "Search clipboard and image text"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.setAccessibilityLabel("Search clipboard and image text")
        zoom.numberOfTickMarks = 3
        zoom.allowsTickMarkValuesOnly = true
        zoom.isContinuous = true
        zoom.target = self; zoom.action = #selector(zoomChanged)
        zoom.setAccessibilityLabel("Image size: 3, 2, or 1 across")
        clear.target = self; clear.action = #selector(clearHistory)
        clear.bezelStyle = .inline
        count.font = .systemFont(ofSize: 11)
        count.textColor = .secondaryLabelColor
        shortcut.font = .systemFont(ofSize: 11, weight: .medium)
        shortcut.textColor = .secondaryLabelColor
        zoomLabels.forEach { $0.font = .systemFont(ofSize: 10); $0.textColor = .secondaryLabelColor; addSubview($0) }
        zoomLabels[1].alignment = .center
        zoomLabels[2].alignment = .right
        empty.alignment = .center
        empty.textColor = .secondaryLabelColor
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        [tabs, search, zoom, scroll, count, empty, shortcut, clear].forEach(addSubview)
        canvas.onNavigate = { [weak self] in self?.onInteraction?() }
        search.nextKeyView = canvas
        canvas.nextKeyView = tabs
        tabs.nextKeyView = zoom
        zoom.nextKeyView = clear
        clear.nextKeyView = search
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    func update(entries: [ClipboardEntry], attachedID: UUID?) {
        self.entries = entries
        self.attachedID = attachedID
        rebuild(animatePromotion: true)
    }
    @objc private func filterChanged() { rebuild(); scroll.contentView.scroll(to: .zero) }
    @objc private func zoomChanged() { layoutTiles(); canvas.selected.map { canvas.choose($0.entry.id) } }
    @objc private func clearHistory() { onClear?() }
    @objc private func scrolled() { ClipboardTileTooltip.shared.hide(); window?.invalidateCursorRects(for: canvas) }
    func controlTextDidChange(_ obj: Notification) { filterChanged() }

    private func rebuild(animatePromotion: Bool = false) {
        let previousTiles = canvas.tiles
        let visible = visibleEntries
        pendingPromotion = animatePromotion && previousTiles.first?.imageOnly == imagesOnly
            ? Self.promotedEntry(from: previousTiles.map { $0.entry.id }, to: visible.map(\.id)) : nil
        let retained = Set(entries.map(\.id))
        cachedTiles = cachedTiles.filter { retained.contains($0.key.id) }
        canvas.tiles = visible.map { entry in
            let key = TileKey(id: entry.id, imageOnly: imagesOnly)
            let tile = cachedTiles[key] ?? makeTile(entry)
            cachedTiles[key] = tile
            tile.refreshEntryPresentation()
            if tile.superview !== canvas { canvas.addSubview(tile) }
            return tile
        }
        let displayed = Set(canvas.tiles.map(ObjectIdentifier.init))
        previousTiles.filter { !displayed.contains(ObjectIdentifier($0)) }.forEach { $0.removeFromSuperview() }
        layoutTargets = layoutTargets.filter { displayed.contains($0.key) }
        if let id = pendingPromotion, let promoted = canvas.tiles.first(where: { $0.entry.id == id }) {
            canvas.addSubview(promoted, positioned: .above, relativeTo: nil)
        }
        canvas.reconcile(liftedID: attachedID)
        let pending = entries.contains { if case .pending = $0.searchIndex { return true }; return false }
        let failure = entries.compactMap { entry -> String? in if case .failed(let message) = entry.searchIndex { return message }; return nil }.first
        shortcut.stringValue = pending ? "Reading image text…" : (failure == nil ? "Quick Look  Space · \(quickLookHint)" : "Some image text is unavailable")
        shortcut.toolTip = failure ?? "Quick Look hovered item ← Space\nNext clipboard item ← \(quickLookHint)"
        count.stringValue = "\(canvas.tiles.count) of \(entries.count) items"
        empty.stringValue = entries.isEmpty ? "Copy something to begin" : "No matching items"
        empty.isHidden = !canvas.tiles.isEmpty
        zoom.isHidden = !imagesOnly
        zoomLabels.forEach { $0.isHidden = !imagesOnly }
        tabs.nextKeyView = imagesOnly ? zoom : clear
        needsLayout = true
        layoutSubtreeIfNeeded()
        if let id = canvas.selectedID { canvas.choose(id, reveal: false) }
        if previousTiles.map({ $0.entry.id }) != visible.map(\.id) { onVisibleEntriesChange?() }
    }
    private func makeTile(_ entry: ClipboardEntry) -> ClipboardTile {
        let tile = ClipboardTile(entry: entry, imageOnly: imagesOnly)
        tile.wantsLayer = true
        tile.onPick = { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.canvas)
            self.canvas.choose(entry.id, reveal: false)
            self.canvas.onPick?(entry)
        }
        tile.onHover = { [weak self] in
            self?.canvas.choose(entry.id, reveal: false)
            self?.onHover?(entry)
        }
        tile.onDelete = { [weak self] in self?.canvas.onDelete?(entry) }
        tile.onOpen = { [weak self] in self?.canvas.onOpen?(entry) }
        return tile
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
        tabs.frame = NSRect(x: 16, y: 17, width: w - 104, height: 27)
        clear.frame = NSRect(x: w - 81, y: 19, width: 65, height: 24)
        search.frame = NSRect(x: 16, y: 54, width: w - 32, height: 26)
        shortcut.frame = NSRect(x: 16, y: 88, width: w - 130, height: 18)
        count.frame = NSRect(x: w - 110, y: 88, width: 94, height: 18)
        zoom.frame = NSRect(x: 23, y: 116, width: w - 46, height: 21)
        zoomLabels[0].frame = NSRect(x: 23, y: 139, width: 80, height: 18)
        zoomLabels[1].frame = NSRect(x: w / 2 - 40, y: 139, width: 80, height: 18)
        zoomLabels[2].frame = NSRect(x: w - 103, y: 139, width: 80, height: 18)
        let top: CGFloat = imagesOnly ? 166 : 116
        scroll.frame = NSRect(x: 12, y: top, width: w - 24, height: max(0, bounds.height - top - 12))
        empty.frame = NSRect(x: 24, y: top + 50, width: w - 48, height: 50)
        layoutTiles()
    }
    private func layoutTiles() {
        let width = scroll.contentSize.width
        let gap: CGFloat = 8
        let columns = self.columns
        canvas.columns = columns
        let side = floor((width - gap * CGFloat(columns - 1)) / CGFloat(columns))
        let height: CGFloat = imagesOnly ? side : 88
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
    }
    func screenFrame(for id: UUID) -> NSRect? {
        guard let window, let tile = canvas.tiles.first(where: { $0.entry.id == id }) else { return nil }
        return window.convertToScreen(tile.convert(tile.bounds, to: nil))
    }
    func reveal(_ id: UUID) { canvas.choose(id) }
}
