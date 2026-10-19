import AppKit

/// The two pieces share one glass container, so the tab joins the drawer
/// without a second background or a seam. Older systems use one masked blur.
/// Over either, each piece paints the window's ground (`ClipboardSurface.glassGround`),
/// so its text reads in ClipEdge's own appearance whatever is behind the glass.
final class ClipboardGlassView: NSView {
    let bodyContent = NSView()
    let tabControl = ClipboardTabView()
    /// The body's and the tab's painted grounds, under their content.
    let bodyGround = ClipboardSurfaceView(frame: .zero)
    let tabGround = ClipboardSurfaceView(frame: .zero)
    /// The body's left and right edges, dragged to resize it: the inner one of a drawer at a side,
    /// both of one at the top.
    let edgeGrips = (left: ClipboardDrawerEdgeGrip(widening: -1), right: ClipboardDrawerEdgeGrip(widening: 1))
    /// The body's content zooms by the text size (`ClipboardZoom`); the glass, its ground and its
    /// grips keep their own size.
    var contentScale: CGFloat = 1
    private var bodyGlass: NSView?
    private var tabGlass: NSView?
    private var glassContainer: NSView?
    private var glassHost: NSView?
    private var fallback: NSVisualEffectView?
    private var bodyRect: NSRect?
    private var tabRect = NSRect.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        bodyGround.surface = .glassGround(radius: 26)
        tabGround.surface = .glassGround(radius: 14)
        bodyGround.addSubview(bodyContent)
        bodyGround.addSubview(edgeGrips.left)
        bodyGround.addSubview(edgeGrips.right)
        tabGround.addSubview(tabControl)
        if #available(macOS 26.0, *) {
            let container = NSGlassEffectContainerView()
            let host = NSView()
            container.contentView = host
            container.spacing = 12
            let body = NSGlassEffectView()
            body.style = .clear
            body.cornerRadius = 26
            body.contentView = bodyGround
            let tab = NSGlassEffectView()
            tab.style = .clear
            tab.cornerRadius = 14
            tab.contentView = tabGround
            host.addSubview(body)
            host.addSubview(tab)
            addSubview(container)
            bodyGlass = body
            tabGlass = tab
            glassHost = host
            glassContainer = container
        } else {
            let blur = NSVisualEffectView()
            blur.material = .hudWindow
            blur.blendingMode = .behindWindow
            blur.state = .active
            addSubview(blur)
            blur.addSubview(bodyGround)
            blur.addSubview(tabGround)
            fallback = blur
        }
        bodyContent.wantsLayer = true
        bodyContent.layer?.cornerRadius = 26
        bodyContent.layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    func updateLayout(bodyRect: NSRect?, tabRect: NSRect, edge: ClipboardDockEdge, tabVisible: Bool = true) {
        self.bodyRect = bodyRect
        self.tabRect = tabVisible ? tabRect : .zero
        tabControl.edge = edge
        tabControl.isExpanded = bodyRect != nil
        tabControl.isHidden = !tabVisible
        tabGlass?.isHidden = !tabVisible
        bodyGlass?.isHidden = bodyRect == nil
        bodyContent.isHidden = bodyRect == nil
        bodyGround.isHidden = bodyRect == nil
        tabGround.isHidden = !tabVisible
        // A hidden glass view can retain its old merged outline when the
        // container is resized/rotated. Remove that surface while collapsed.
        if let bodyGlass, let glassHost {
            if bodyRect != nil {
                if bodyGlass.superview !== glassHost { glassHost.addSubview(bodyGlass, positioned: .below, relativeTo: tabGlass) }
            } else { bodyGlass.removeFromSuperview() }
        }
        // The glass continues through the screen boundary into the wall.
        // Extending its outer corners past the window clips off the floating
        // card rim while keeping the exposed inner edge rounded.
        func extendedThroughWall(_ rect: NSRect) -> NSRect {
            switch edge {
            case .left: return NSRect(x: rect.minX - 26, y: rect.minY, width: rect.width + 26, height: rect.height)
            case .right: return NSRect(x: rect.minX, y: rect.minY, width: rect.width + 26, height: rect.height)
            case .top: return NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height + 26)
            }
        }
        let bodySurface = bodyRect.map(extendedThroughWall)
        let tabSurface = bodyRect == nil ? extendedThroughWall(tabRect) : tabRect
        // Glass composition needs each complete rounded surface inside its
        // container. Let this outer view/window clip the through-wall portion;
        // clipping inside the compositor can flatten corners after rotation.
        let compositionBounds = bounds.union(bodySurface ?? .zero).union(tabVisible ? tabSurface : .zero)
        glassContainer?.frame = compositionBounds
        glassHost?.frame = NSRect(origin: .zero, size: compositionBounds.size)
        if let bodyRect, let surface = bodySurface {
            bodyGlass?.frame = surface.offsetBy(dx: -compositionBounds.minX, dy: -compositionBounds.minY)
            // Under glass the ground fills the whole surface, through the wall; over the old
            // blur it is the body itself.
            bodyGround.frame = bodyGlass == nil ? bodyRect : NSRect(origin: .zero, size: surface.size)
            bodyContent.frame = bodyGlass == nil ? NSRect(origin: .zero, size: bodyRect.size) : bodyRect.offsetBy(dx: -surface.minX, dy: -surface.minY)
            ClipboardZoom.apply(contentScale, to: bodyContent)
            // A zoomed layer's corner is in zoomed points: the visible corner stays the glass's 26.
            bodyContent.layer?.cornerRadius = 26 / max(0.01, contentScale)
            // Along the free edges, clear of the rounded corners.
            let edge = bodyContent.frame.insetBy(dx: 0, dy: 26), depth = ClipboardDrawerEdgeGrip.depth
            edgeGrips.left.frame = NSRect(x: edge.minX, y: edge.minY, width: depth, height: max(0, edge.height))
            edgeGrips.right.frame = NSRect(x: edge.maxX - depth, y: edge.minY, width: depth, height: max(0, edge.height))
        }
        edgeGrips.left.isHidden = bodyRect == nil || edge == .left
        edgeGrips.right.isHidden = bodyRect == nil || edge == .right
        edgeGrips.left.gain = edge == .top ? 2 : 1
        edgeGrips.right.gain = edge == .top ? 2 : 1
        tabGlass?.frame = tabSurface.offsetBy(dx: -compositionBounds.minX, dy: -compositionBounds.minY)
        tabGround.frame = tabGlass == nil ? tabRect : NSRect(origin: .zero, size: tabSurface.size)
        tabControl.frame = tabGlass == nil ? NSRect(origin: .zero, size: tabRect.size) : tabRect.offsetBy(dx: -tabSurface.minX, dy: -tabSurface.minY)
        if let fallback {
            fallback.frame = bounds
            let rect = bounds
            fallback.maskImage = NSImage(size: rect.size, flipped: false) { _ in
                NSColor.white.setFill()
                if let bodyRect { NSBezierPath(roundedRect: extendedThroughWall(bodyRect), xRadius: 26, yRadius: 26).fill() }
                if tabVisible { NSBezierPath(roundedRect: tabSurface, xRadius: 14, yRadius: 14).fill() }
                return true
            }
        }
        needsLayout = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard tabRect.contains(local) || bodyRect?.contains(local) == true else { return nil }
        return super.hitTest(point)
    }
}
