import AppKit

/// A free edge of the drawer, dragged left or right to make the drawer wider or narrower (Al,
/// 2026-10-16): the inner edge of a drawer at a side, either side edge of one at the top. The tab is
/// exempt: it lies over the edge, takes its own drags, and the grip is cut where the tab crosses it.
final class ClipboardDrawerEdgeGrip: NSView {
    /// Which way across the screen widens the drawer from this edge: +1 rightward, -1 leftward.
    let widening: CGFloat
    /// How much wider the drawer gets for each point the edge moves: 2 for a drawer centred under a
    /// top tab, whose other side moves too, else 1.
    var gain: CGFloat = 1
    var onBegan: (() -> Void)?
    /// Points wider (negative: narrower) than when the press began.
    var onDrag: ((CGFloat) -> Void)?
    var onEnded: (() -> Void)?
    private var start: CGFloat = 0
    private var isHovered = false { didSet { needsDisplay = true } }
    private(set) var isDragging = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    /// The grip's depth into the drawer: wide enough to find, narrower than the cards' inset.
    static let depth: CGFloat = 8

    init(widening: CGFloat) {
        self.widening = widening
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Drawer width")
        setAccessibilityHelp("Drag left or right to make the drawer wider or narrower.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    override func mouseDown(with event: NSEvent) {
        start = screenX(event)
        isDragging = true
        onBegan?()
    }
    override func mouseDragged(with event: NSEvent) {
        onDrag?((screenX(event) - start) * widening * gain)
    }
    override func mouseUp(with event: NSEvent) {
        isDragging = false
        isHovered = bounds.contains(convert(event.locationInWindow, from: nil))
        onEnded?()
    }
    private func screenX(_ event: NSEvent) -> CGFloat {
        (window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation).x
    }

    /// A short upright lozenge at the edge's middle while the pointer is on it, as the tab shows its grips.
    override func draw(_ dirtyRect: NSRect) {
        guard isHovered || isDragging else { return }
        let grip = NSRect(x: bounds.midX - 2, y: bounds.midY - 14, width: 4, height: 28)
        NSColor.labelColor.withAlphaComponent(isDragging ? 0.42 : 0.24).setFill()
        NSBezierPath(roundedRect: grip, xRadius: 2, yRadius: 2).fill()
    }
}
