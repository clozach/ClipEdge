import AppKit

/// The disk as one bar (Al, 2026-10-16): a hairline-outlined strip, at the left what everything
/// else uses, then ClipEdge's history (never narrower than half a point, in a bright color), then
/// the free space in light gray. *Used* and *Free* sit above the bar, centered over their parts, in
/// their colors; *ClipEdge* sits below its part, in its color. Each name is followed, in a fainter
/// tone of its color, by its size and share (*Used · 358 GB | 17%*), the pair centered as one. The
/// exact numbers are its tooltip and what VoiceOver reads.
final class ClipboardStorageBar: NSView {
    static let usedColor = NSColor.systemBlue
    static let clipEdgeColor = NSColor.systemPink
    /// Light gray as a fill; the same gray, at full strength, reads as its label.
    static let freeColor = NSColor.systemGray
    static let freeFill = NSColor.systemGray.withAlphaComponent(0.28)
    static let barHeight: CGFloat = 10
    /// The narrowest ClipEdge's part gets, however small its share.
    static let sliver: CGFloat = 0.5
    private static let font = NSFont.systemFont(ofSize: 11, weight: .medium)
    private static let usageFont = NSFont.systemFont(ofSize: 11)
    /// How faint a label's size and share are beside its name.
    static let usageAlpha: CGFloat = 0.55
    private static let labelHeight: CGFloat = 14
    private static let gap: CGFloat = 3

    var report: ClipboardStorageReport? {
        didSet {
            toolTip = report?.summary
            setAccessibilityValue(report?.summary)
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Disk space")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.labelHeight * 2 + Self.gap * 2 + Self.barHeight) }

    /// Where the bar and its three parts are, in this view's bounds.
    var parts: (bar: NSRect, used: NSRect, clipEdge: NSRect, free: NSRect) {
        let bar = NSRect(x: 0, y: Self.labelHeight + Self.gap, width: bounds.width, height: Self.barHeight)
        let shares = report?.shares ?? (used: 0, clipEdge: 0, free: 1)
        let clipEdgeWidth = max(Self.sliver, bar.width * shares.clipEdge)
        let freeWidth = min(bar.width - clipEdgeWidth, bar.width * shares.free)
        let usedWidth = max(0, bar.width - clipEdgeWidth - freeWidth)
        let used = NSRect(x: bar.minX, y: bar.minY, width: usedWidth, height: bar.height)
        let clipEdge = NSRect(x: used.maxX, y: bar.minY, width: clipEdgeWidth, height: bar.height)
        let free = NSRect(x: clipEdge.maxX, y: bar.minY, width: max(0, bar.maxX - clipEdge.maxX), height: bar.height)
        return (bar, used, clipEdge, free)
    }

    /// Each label's frame: centered on its part, kept inside the view, *Used* and *Free* never
    /// overlapping (the narrower part's label gives way at the edge).
    /// A label as drawn: its name in `color`, then " · " and its usage in a fainter tone.
    static func label(_ name: String, usage: String?, color: NSColor) -> NSAttributedString {
        let text = NSMutableAttributedString(string: name, attributes: [.font: font, .foregroundColor: color])
        if let usage {
            text.append(NSAttributedString(string: " · \(usage)", attributes: [.font: usageFont, .foregroundColor: color.withAlphaComponent(usageAlpha)]))
        }
        return text
    }
    /// The three labels, with their usage once there is a report.
    var labels: (used: NSAttributedString, free: NSAttributedString, clipEdge: NSAttributedString) {
        let usage = report?.usage
        return (Self.label("Used", usage: usage?.used, color: Self.usedColor),
                Self.label("Free", usage: usage?.free, color: Self.freeColor),
                Self.label("ClipEdge", usage: usage?.clipEdge, color: Self.clipEdgeColor))
    }

    var labelFrames: (used: NSRect, free: NSRect, clipEdge: NSRect) {
        let parts = self.parts, labels = self.labels
        func frame(_ text: NSAttributedString, centeredOn x: CGFloat, y: CGFloat) -> NSRect {
            let width = ceil(text.size().width)
            return NSRect(x: min(max(0, x - width / 2), bounds.width - width), y: y, width: width, height: Self.labelHeight)
        }
        var used = frame(labels.used, centeredOn: parts.used.midX, y: 0)
        var free = frame(labels.free, centeredOn: parts.free.midX, y: 0)
        if used.maxX + 6 > free.minX {
            used.origin.x = 0
            free.origin.x = bounds.width - free.width
        }
        let clipEdge = frame(labels.clipEdge, centeredOn: parts.clipEdge.midX, y: parts.bar.maxY + Self.gap)
        return (used, free, clipEdge)
    }

    override func draw(_ dirtyRect: NSRect) {
        let parts = self.parts
        let hairline = 1 / max(1, window?.backingScaleFactor ?? 2)
        let outline = NSBezierPath(roundedRect: parts.bar.insetBy(dx: hairline / 2, dy: hairline / 2), xRadius: 2, yRadius: 2)
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        Self.usedColor.setFill(); parts.used.fill()
        Self.clipEdgeColor.setFill(); parts.clipEdge.fill()
        Self.freeFill.setFill(); parts.free.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.secondaryLabelColor.setStroke()
        outline.lineWidth = hairline
        outline.stroke()
        let frames = labelFrames, labels = self.labels
        for (text, frame) in [(labels.used, frames.used), (labels.free, frames.free), (labels.clipEdge, frames.clipEdge)] {
            text.draw(in: frame)
        }
    }
}
