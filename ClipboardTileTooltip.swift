import AppKit

/// One non-interactive tooltip for the whole browser. Native columns, not spaces.
final class ClipboardTileTooltip {
    static let shared = ClipboardTileTooltip()
    static let rows = [("Pick up", "Return or click"), ("Preview magnet", "Space"),
                       ("Open in Preview", "⌘O"), ("Delete", "⌫"),
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    func hide(for tile: ClipboardTile? = nil) {
        if let tile, owner !== tile { return }
        pending?.cancel(); pending = nil
        panel?.orderOut(nil); panel = nil; owner = nil
    }

    static func content(for text: String) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view.layer?.cornerRadius = 8
        let summary = NSTextField(wrappingLabelWithString: String(text.prefix(700)))
        summary.maximumNumberOfLines = 5
        summary.font = .systemFont(ofSize: 11)
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
        grid.row(at: 4).topPadding = 10
        let stack = NSStackView(views: [summary, NSBox.separator(), grid])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -12),
            summary.widthAnchor.constraint(lessThanOrEqualToConstant: 330)
        ])
        view.setFrameSize(NSSize(width: max(280, stack.fittingSize.width + 24), height: stack.fittingSize.height + 24))
        return view
    }

    private func show(for tile: ClipboardTile) {
        let content = Self.content(for: tile.tooltipText)
        let point = NSEvent.mouseLocation
        let screen = tile.window?.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        let size = content.fittingSize
        let origin = NSPoint(x: min(max(screen.minX + 8, point.x - size.width - 15), screen.maxX - size.width - 8),
                             y: min(max(screen.minY + 8, point.y - size.height - 15), screen.maxY - size.height - 8))
        let window = NSPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.contentView = content; window.level = .popUpMenu
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
        window.ignoresMouseEvents = true; window.hidesOnDeactivate = false
        window.orderFrontRegardless(); panel = window
    }
}

private extension NSBox {
    static func separator() -> NSBox { let box = NSBox(); box.boxType = .separator; return box }
}
