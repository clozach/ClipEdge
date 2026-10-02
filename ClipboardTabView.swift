import AppKit

/// Tab motion and its two end grips; hover opening belongs to EdgeController.
final class ClipboardTabView: NSView {
    var onHover: (() -> Void)?
    var onClick: (() -> Void)?
    var onSettings: (() -> Void)?
    var onInteractionBegan: ((NSPoint) -> Void)?
    var onDrag: ((NSPoint) -> Void)?
    var onResize: ((CGFloat) -> Void)?
    var onInteractionEnded: (() -> Void)?
    var edge: ClipboardDockEdge = .right { didSet { refreshHandles() } }
    var isExpanded = false { didSet { refreshHandles() } }
    private(set) var isHovered = false
    private(set) var isInteracting = false
    var showsHandles: Bool { isExpanded || isHovered || isInteracting }
    private var tracking: NSTrackingArea?
    private var draggedEnd: Int?
    private var dragStart = NSPoint.zero
    private var hasDragged = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("ClipEdge tab")
        setAccessibilityHelp("Click to open. Hover opening follows Reveal Settings. Drag the middle to move; drag either end grip to resize both ends. Right-click for Reveal Settings.")
        toolTip = "Open ← click\nMove ← drag the middle\nResize ← drag either end\nReveal Settings ← right-click"
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        refreshHandles()
        if !isInteracting { onHover?() }
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        refreshHandles()
    }

    private func end(at point: NSPoint) -> Int? {
        guard bounds.contains(point) else { return nil }
        if handleRect(-1).contains(point) { return -1 }
        if handleRect(1).contains(point) { return 1 }
        return nil
    }

    private func refreshHandles() {
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        draggedEnd = end(at: convert(event.locationInWindow, from: nil))
        isInteracting = true
        hasDragged = false
        refreshHandles()
        onInteractionBegan?(dragStart)
        if draggedEnd == nil { NSCursor.closedHand.set() }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        guard hasDragged || hypot(point.x - dragStart.x, point.y - dragStart.y) > 2 else { return }
        hasDragged = true
        if let draggedEnd {
            let travel = edge == .top ? point.x - dragStart.x : point.y - dragStart.y
            onResize?(travel * CGFloat(draggedEnd))
        } else { onDrag?(point) }
    }

    override func mouseUp(with event: NSEvent) {
        let clicked = !hasDragged
        isInteracting = false
        draggedEnd = nil
        isHovered = bounds.contains(convert(event.locationInWindow, from: nil))
        onInteractionEnded?()
        if clicked { onClick?() }
        refreshHandles()
        NSCursor.openHand.set()
    }

    override func rightMouseDown(with event: NSEvent) { onSettings?() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: isInteracting ? .closedHand : .openHand)
        if showsHandles {
            for end in [-1, 1] { addCursorRect(handleRect(end), cursor: edge == .top ? .resizeLeftRight : .resizeUpDown) }
        }
    }

    private func handleRect(_ end: Int) -> NSRect {
        let zone = min(18, (edge == .top ? bounds.width : bounds.height) / 4)
        if edge == .top {
            return NSRect(x: end < 0 ? 0 : bounds.width - zone, y: 0, width: zone, height: bounds.height)
        }
        return NSRect(x: 0, y: end < 0 ? 0 : bounds.height - zone, width: bounds.width, height: zone)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard showsHandles else { return }
        for end in [-1, 1] {
            let area = handleRect(end)
            let horizontalTab = edge == .top
            // Side tabs get horizontal lozenges at the top and bottom. The
            // pair rotates with a top-docked tab to mark its left/right ends.
            let grip = NSRect(x: area.midX - (horizontalTab ? 2 : 7),
                              y: area.midY - (horizontalTab ? 7 : 2),
                              width: horizontalTab ? 4 : 14, height: horizontalTab ? 14 : 4)
            NSColor.labelColor.withAlphaComponent(draggedEnd == end ? 0.42 : 0.24).setFill()
            NSBezierPath(roundedRect: grip, xRadius: 2, yRadius: 2).fill()
        }
    }
}
