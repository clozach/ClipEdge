import AppKit

/// Tab motion and its two end grips; hover opening belongs to EdgeController. A drag that starts
/// across the edge slides the drawer open or closed under the pointer (Al, 2026-10-16); one that
/// starts along it moves the tab, to another edge too.
final class ClipboardTabView: NSView {
    var onHover: (() -> Void)?
    var onClick: (() -> Void)?
    var onSettings: (() -> Void)?
    var onInteractionBegan: ((NSPoint) -> Void)?
    var onDrag: ((NSPoint) -> Void)?
    var onResize: ((CGFloat) -> Void)?
    /// Points the pointer has travelled away from the wall since the press (negative: toward it).
    var onSlide: ((CGFloat) -> Void)?
    /// The slide let go, moving away from the wall at this many points a second (negative: toward it).
    var onSlideEnded: ((CGFloat) -> Void)?
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
    /// What a drag of the middle does, decided by its first few points of travel.
    private enum Gesture { case undecided, move, slide }
    private var gesture = Gesture.undecided
    /// The slide's recent travel, for its speed when it lets go.
    private var samples: [(time: TimeInterval, travel: CGFloat)] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("ClipEdge tab")
        setAccessibilityHelp("Click to open. Hover opening follows Settings. Drag away from the edge to open, toward it to close; drag along the edge to move; drag either end grip to resize both ends. Right-click for Settings.")
        toolTip = "Open ← click, or drag away from the edge\nClose ← drag toward the edge\nMove ← drag along the edge\nResize ← drag either end\nSettings ← right-click"
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
        gesture = .undecided
        samples = []
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
            return
        }
        let away = awayFromWall(point), along = edge == .top ? point.x - dragStart.x : point.y - dragStart.y
        if gesture == .undecided { gesture = abs(away) > abs(along) ? .slide : .move }
        switch gesture {
        case .slide:
            samples.append((event.timestamp, away))
            samples.removeAll { event.timestamp - $0.time > 0.1 }
            onSlide?(away)
        case .move, .undecided:
            onDrag?(point)
        }
    }

    /// The pointer's travel since the press, away from the wall the tab sits on.
    private func awayFromWall(_ point: NSPoint) -> CGFloat {
        switch edge {
        case .left: return point.x - dragStart.x
        case .right: return dragStart.x - point.x
        case .top: return dragStart.y - point.y
        }
    }

    /// Over the last tenth of a second, points a second away from the wall.
    private var slideSpeed: CGFloat {
        guard let first = samples.first, let last = samples.last, last.time > first.time else { return 0 }
        return (last.travel - first.travel) / CGFloat(last.time - first.time)
    }

    override func mouseUp(with event: NSEvent) {
        let clicked = !hasDragged
        let slid = gesture == .slide
        // A pause before letting go is no flick: only travel in the last tenth of a second counts.
        samples.removeAll { event.timestamp - $0.time > 0.1 }
        let speed = slid ? slideSpeed : 0
        gesture = .undecided
        isInteracting = false
        draggedEnd = nil
        isHovered = bounds.contains(convert(event.locationInWindow, from: nil))
        onInteractionEnded?()
        if slid { onSlideEnded?(speed) }
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
