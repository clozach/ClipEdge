import AppKit

/// How a ClipEdge view paints its own layer. A layer takes CGColors, which
/// freeze when assigned, and outside drawing so does NSColor.withAlphaComponent:
/// both would keep the light look after a switch to dark. A surface keeps its
/// look as a value and resolves it in the view's own appearance.
struct ClipboardSurface {
    /// A ground: a system color, at its own opacity unless one is given.
    struct Fill {
        var color: NSColor
        var opacity: CGFloat?
        /// Applied while painting: outside drawing, withAlphaComponent freezes the color too.
        var resolved: NSColor { opacity.map(color.withAlphaComponent) ?? color }
    }
    var fill: Fill?
    /// A one-point outline in this color.
    var rim: NSColor?
    var radius: CGFloat = 0
    var clips = false

    /// The shared card: the window's ground inside a one-point separator rim.
    static func card(radius: CGFloat, opacity: CGFloat? = nil, clips: Bool = false) -> Self {
        Self(fill: Fill(color: .windowBackgroundColor, opacity: opacity), rim: .separatorColor, radius: radius, clips: clips)
    }

    /// Call only inside the drawing appearance the colors should resolve in.
    func paint(_ layer: CALayer) {
        layer.backgroundColor = fill?.resolved.cgColor
        layer.borderColor = rim?.cgColor
        layer.borderWidth = rim == nil ? 0 : 1
        layer.cornerRadius = radius
        layer.masksToBounds = clips
    }
}

/// Every ClipEdge view that paints its own layer. Set `surface`; never assign
/// layer colors. It repaints when set and whenever its appearance changes.
class ClipboardSurfaceView: NSView {
    var surface = ClipboardSurface() { didSet { repaint() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        repaint()
    }

    /// Outside drawing, NSAppearance.currentDrawing is not this view's appearance.
    private func repaint() {
        guard let layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance { surface.paint(layer) }
    }
}
