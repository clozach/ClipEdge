import AppKit

/// One non-interactive tooltip for the whole browser. Native columns, not spaces.
/// It rides the hovered card, never the pointer, and never covers the card.
final class ClipboardTileTooltip {
    static let shared = ClipboardTileTooltip()
    /// Hover this long before the card's info appears, so it isn't constantly in the way.
    static let delay: TimeInterval = 2
    /// The drawer's room for it, level with the card (the Send to placement); nil when no drawer is open.
    var besideDrawer: ((_ card: NSRect, _ size: NSSize) -> NSRect?)?
    /// Quick Look or Send to already fills that room, so the info waits.
    var isRoomTaken: () -> Bool = { false }
    static let rows = [("Pick up", "Return or click"), ("Preview magnet", "Space"),
                       ("Open in Preview", "⌘O"), ("Send to", "Tab"), ("Search", "⌘F"), ("Delete", "⌫ or ⌘⌫"),
                       ("Paste held item", "⌘click"), ("Keep holding", "click"), ("Drop magnet", "Esc")]
    static var legendText: String { rows.map { "\($0.0) ← \($0.1)" }.joined(separator: "\n") }
    private weak var owner: ClipboardTile?
    private var pending: DispatchWorkItem?
    private var panel: NSPanel?

    func schedule(for tile: ClipboardTile) {
        hide()
        owner = tile
        let work = DispatchWorkItem { [weak self, weak tile] in
            guard let self, let tile, self.owner === tile, tile.window?.isVisible == true,
                  tile.isChosen else { return }
            self.show(for: tile)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
    }

    func hide(for tile: ClipboardTile? = nil) {
        if let tile, owner !== tile { return }
        pending?.cancel(); pending = nil
        panel?.orderOut(nil); panel = nil; owner = nil
    }

    static func content(for text: String, details: String = "") -> NSView {
        let view = ClipboardSurfaceView()
        view.surface = ClipboardSurface(fill: .init(color: .windowBackgroundColor), radius: 8)
        let summary = NSTextField(wrappingLabelWithString: String(text.prefix(700)))
        summary.maximumNumberOfLines = 5
        summary.font = .systemFont(ofSize: 11)
        // Facts, paths and the full date wrap in full beneath the excerpt.
        let facts = NSTextField(wrappingLabelWithString: details)
        facts.font = .systemFont(ofSize: 11)
        facts.textColor = .secondaryLabelColor
        facts.isHidden = details.isEmpty
        let grid = NSGridView(views: rows.enumerated().map { index, pair in
            let left = NSTextField(labelWithString: pair.0)
            left.alignment = .right
            let arrow = NSTextField(labelWithString: "←")
            let right = NSTextField(labelWithString: pair.1)
            [left, arrow, right].forEach { $0.font = .systemFont(ofSize: 12) }
            return [left, arrow, right]
        })
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .center
        grid.column(at: 2).xPlacement = .leading
        grid.columnSpacing = 5; grid.rowSpacing = 3
        for index in rows.indices { grid.row(at: index).height = 18 }
        grid.row(at: 5).topPadding = 10
        let stack = NSStackView(views: [summary, facts, NSBox.separator(), grid])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -12),
            summary.widthAnchor.constraint(lessThanOrEqualToConstant: 330),
            facts.widthAnchor.constraint(lessThanOrEqualToConstant: 330)
        ])
        view.setFrameSize(NSSize(width: max(280, stack.fittingSize.width + 24), height: stack.fittingSize.height + 24))
        return view
    }

    /// Beside the drawer when that room fits it; otherwise just below the card, or above it near the screen's bottom.
    static func frame(fitting size: NSSize, card: NSRect, screen: NSRect, beside: NSRect?) -> NSRect {
        if let beside, beside.width >= size.width, beside.height >= size.height {
            return NSRect(origin: beside.origin, size: size)
        }
        let usable = screen.insetBy(dx: 8, dy: 8), gap: CGFloat = 6
        let below = card.minY - gap - size.height
        let y = below >= usable.minY ? below : min(card.maxY + gap, usable.maxY - size.height)
        let x = min(max(card.minX, usable.minX), usable.maxX - size.width)
        return NSRect(x: floor(x), y: floor(y), width: size.width, height: size.height)
    }

    /// Where the info is showing, if it is.
    var frame: NSRect? { panel?.frame }

    /// Where info of this size would open for the card, or nil while Quick Look or Send to holds the room.
    func plannedFrame(for tile: ClipboardTile, size: NSSize) -> NSRect? {
        guard !isRoomTaken(), let host = tile.window else { return nil }
        let card = host.convertToScreen(tile.convert(tile.bounds, to: nil))
        let screen = host.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        return Self.frame(fitting: size, card: card, screen: screen, beside: besideDrawer?(card, size))
    }

    /// After the delay (the fixture calls it directly).
    func show(for tile: ClipboardTile) {
        let content = Self.content(for: tile.tooltipSummary, details: tile.tooltipDetails)
        guard let frame = plannedFrame(for: tile, size: content.fittingSize) else { return }
        let window = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.contentView = content; window.level = .popUpMenu
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
        window.ignoresMouseEvents = true; window.hidesOnDeactivate = false
        window.orderFrontRegardless(); panel = window
    }
}

private extension NSBox {
    static func separator() -> NSBox { let box = NSBox(); box.boxType = .separator; return box }
}
