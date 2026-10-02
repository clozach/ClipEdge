import AppKit

/// One history chip or square image tile; actions stay at its right edge.
final class ClipboardTile: NSControl {
    let entry: ClipboardEntry
    let imageOnly: Bool
    var onPick: (() -> Void)?
    var onHover: (() -> Void)?
    var onDelete: (() -> Void)?
    var onOpen: (() -> Void)?
    // Selection has exactly one owner. Tiles cannot retain independent hover tint.
    var isChosen: Bool { (superview as? ClipboardCanvas)?.selectedID == entry.id }
    var isAttached: Bool { (superview as? ClipboardCanvas)?.liftedID == entry.id }
    var tooltipText: String { "\(entry.plainText ?? entry.title)\n\(entry.fullDateTimeStamp)" }
    private var tracking: NSTrackingArea?
    private let deleteButton = NSButton()
    private let openButton = NSButton()

    init(entry: ClipboardEntry, imageOnly: Bool) {
        self.entry = entry
        self.imageOnly = imageOnly
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        refreshEntryPresentation()
        configure(deleteButton, image: ClipboardIcons.delete, help: "Delete permanently… ← ⌫", action: #selector(deleteItem))
        configure(openButton, image: ClipboardIcons.openInPreview, help: "Open in Preview ← ⌘O", action: #selector(openItem))
        updateActions()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool { onPick?(); return true }

    func refreshEntryPresentation() {
        setAccessibilityLabel("\(entry.title), copied \(entry.fullDateTimeStamp)")
        setAccessibilityHelp(ClipboardTileTooltip.legendText)
        needsDisplay = true
    }

    private func configure(_ button: NSButton, image: NSImage, help: String, action: Selector) {
        button.image = image
        button.bezelStyle = .regularSquare
        button.isBordered = true
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
        button.toolTip = help
        button.setAccessibilityLabel(help)
        button.refusesFirstResponder = true // Canvas exposes these via Space / Delete / Command-O.
        addSubview(button)
    }
    override func layout() {
        super.layout()
        deleteButton.frame = NSRect(x: bounds.width - 31, y: 5, width: 26, height: 26)
        openButton.frame = NSRect(x: bounds.width - 31, y: 34, width: 26, height: 26)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) { onHover?(); ClipboardTileTooltip.shared.schedule(for: self) }
    override func mouseExited(with event: NSEvent) { ClipboardTileTooltip.shared.hide(for: self) }
    override func mouseDown(with event: NSEvent) { ClipboardTileTooltip.shared.hide(); onPick?() }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { ClipboardTileTooltip.shared.hide(for: self) }
        super.viewWillMove(toWindow: newWindow)
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    @objc private func deleteItem() { ClipboardTileTooltip.shared.hide(); onDelete?() }
    @objc private func openItem() { ClipboardTileTooltip.shared.hide(); onOpen?() }
    func refreshSelection() {
        updateActions()
        setAccessibilitySelected(isChosen)
        setAccessibilityLabel(isAttached ? "Click here to cancel pickup of \(entry.title)" : "\(entry.title), copied \(entry.fullDateTimeStamp)")
        needsDisplay = true
    }
    private func updateActions() {
        deleteButton.isHidden = !isChosen || isAttached
        openButton.isHidden = !isChosen || isAttached
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        // Image corners touching their square container stay square.
        let path = imageOnly ? NSBezierPath(rect: rect) : NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        if isChosen {
            NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
            path.fill()
        }
        if isAttached {
            drawText("Click here to cancel", in: NSRect(x: 20, y: bounds.midY - 9, width: bounds.width - 40, height: 22), size: 13, color: .secondaryLabelColor)
            NSColor.separatorColor.setStroke()
            path.setLineDash([4, 4], count: 2, phase: 0)
            path.stroke()
            return
        }
        if imageOnly {
            if let image = entry.thumbnail { drawImage(image, in: rect) }
            let stampRect = NSRect(x: rect.minX, y: rect.maxY - 23, width: rect.width, height: 23)
            NSColor.controlBackgroundColor.setFill()
            NSBezierPath(rect: stampRect).fill()
            drawText(entry.dateTimeStamp, in: stampRect.insetBy(dx: 4, dy: 4), size: 10, color: .labelColor)
        } else {
            let iconRect = NSRect(x: 11, y: 14, width: 46, height: 46)
            let image = entry.thumbnail ?? ClipboardIcons.symbol(entry.kind.iconName)
            if let image { drawImage(image, in: iconRect) }
            drawText(entry.title, in: NSRect(x: 68, y: 10, width: bounds.width - 106, height: 34), size: 13, color: .labelColor)
            drawText(entry.detail, in: NSRect(x: 68, y: 47, width: bounds.width - 106, height: 16), size: 10, color: .secondaryLabelColor)
            drawText(entry.dateTimeStamp, in: NSRect(x: 68, y: 66, width: bounds.width - 78, height: 16), size: 10, color: .secondaryLabelColor)
        }
        if isChosen {
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
    private func drawImage(_ image: NSImage, in box: NSRect) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let scale = min(box.width / image.size.width, box.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let destination = NSRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height)
        image.draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    private func drawText(_ text: String, in rect: NSRect, size: CGFloat, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                              attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color, .paragraphStyle: paragraph])
    }
}
