import AppKit

/// The two pieces share one glass container, so the tab joins the drawer
/// without a second background or a seam. Older systems use one masked blur.
final class ClipboardGlassView: NSView {
    let bodyContent = NSView()
    let tabControl = ClipboardTabView()
    private var bodyGlass: NSView?
    private var tabGlass: NSView?
    private var glassContainer: NSView?
    private var glassHost: NSView?
    private var bodyHost: NSView?
    private var tabHost: NSView?
    private var fallback: NSVisualEffectView?
    private var bodyRect: NSRect?
    private var tabRect = NSRect.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        if #available(macOS 26.0, *) {
            let container = NSGlassEffectContainerView()
            let host = NSView()
            container.contentView = host
            container.spacing = 12
            let body = NSGlassEffectView()
            body.style = .clear
            body.cornerRadius = 26
            let bodyHost = NSView()
            bodyHost.addSubview(bodyContent)
            body.contentView = bodyHost
            let tab = NSGlassEffectView()
            tab.style = .clear
            tab.cornerRadius = 14
            let tabHost = NSView()
            tabHost.addSubview(tabControl)
            tab.contentView = tabHost
            host.addSubview(body)
            host.addSubview(tab)
            addSubview(container)
            bodyGlass = body
            tabGlass = tab
            glassHost = host
            glassContainer = container
            self.bodyHost = bodyHost
            self.tabHost = tabHost
        } else {
            let blur = NSVisualEffectView()
            blur.material = .hudWindow
            blur.blendingMode = .behindWindow
            blur.state = .active
            addSubview(blur)
            blur.addSubview(bodyContent)
            blur.addSubview(tabControl)
            fallback = blur
        }
        bodyContent.wantsLayer = true
        bodyContent.layer?.cornerRadius = 26
        bodyContent.layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    func updateLayout(bodyRect: NSRect?, tabRect: NSRect, edge: ClipboardDockEdge) {
        self.bodyRect = bodyRect
        self.tabRect = tabRect
        tabControl.edge = edge
        tabControl.isExpanded = bodyRect != nil
        bodyGlass?.isHidden = bodyRect == nil
        bodyContent.isHidden = bodyRect == nil
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
        let compositionBounds = bounds.union(bodySurface ?? tabSurface).union(tabSurface)
        glassContainer?.frame = compositionBounds
        glassHost?.frame = NSRect(origin: .zero, size: compositionBounds.size)
        if let bodyRect, let surface = bodySurface {
            bodyGlass?.frame = surface.offsetBy(dx: -compositionBounds.minX, dy: -compositionBounds.minY)
            bodyHost?.frame = NSRect(origin: .zero, size: surface.size)
            bodyContent.frame = bodyGlass == nil ? bodyRect : bodyRect.offsetBy(dx: -surface.minX, dy: -surface.minY)
        }
        tabGlass?.frame = tabSurface.offsetBy(dx: -compositionBounds.minX, dy: -compositionBounds.minY)
        tabHost?.frame = NSRect(origin: .zero, size: tabSurface.size)
        tabControl.frame = tabGlass == nil ? tabRect : tabRect.offsetBy(dx: -tabSurface.minX, dy: -tabSurface.minY)
        if let fallback {
            fallback.frame = bounds
            let rect = bounds
            fallback.maskImage = NSImage(size: rect.size, flipped: false) { _ in
                NSColor.white.setFill()
                if let bodyRect { NSBezierPath(roundedRect: extendedThroughWall(bodyRect), xRadius: 26, yRadius: 26).fill() }
                NSBezierPath(roundedRect: tabSurface, xRadius: 14, yRadius: 14).fill()
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
