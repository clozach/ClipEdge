import AppKit

/// Screen-space attachment, independent of the pointer and the hovered row.
struct ClipboardDrawerPreviewAnchor: Equatable {
    let drawer: NSRect
    let screen: NSRect
    let edge: ClipboardDockEdge
    static let preferredSize = NSSize(width: 640, height: 520)
    private static let gap: CGFloat = 8

    var frame: NSRect {
        let usable = screen.insetBy(dx: 8, dy: 8)
        let left = NSRect(x: usable.minX, y: usable.minY,
                          width: max(0, drawer.minX - Self.gap - usable.minX), height: usable.height)
        let right = NSRect(x: drawer.maxX + Self.gap, y: usable.minY,
                           width: max(0, usable.maxX - drawer.maxX - Self.gap), height: usable.height)
        let below = NSRect(x: usable.minX, y: usable.minY, width: usable.width,
                           height: max(0, drawer.minY - Self.gap - usable.minY))
        let region: NSRect
        switch edge {
        case .left: region = right
        case .right: region = left
        case .top:
            // A short display may have too little room below a top drawer.
            // Prefer below on ties, otherwise use the side with more preview area.
            region = [below, left, right].reduce(below) { best, candidate in
                capacity(candidate) > capacity(best) ? candidate : best
            }
        }
        let size = NSSize(width: min(Self.preferredSize.width, region.width),
                          height: min(Self.preferredSize.height, region.height))
        let x: CGFloat
        let y: CGFloat
        if region == below {
            x = min(max(drawer.midX - size.width / 2, region.minX), region.maxX - size.width)
            y = region.maxY - size.height
        } else {
            x = region == left ? region.maxX - size.width : region.minX
            y = min(max(drawer.midY - size.height / 2, region.minY), region.maxY - size.height)
        }
        return NSRect(x: floor(x), y: floor(y), width: floor(size.width), height: floor(size.height))
    }

    /// The narrow gap is traversable without counting as leaving the drawer.
    func contains(_ point: NSPoint) -> Bool {
        frame.insetBy(dx: -Self.gap, dy: -Self.gap).contains(point)
    }

    private func capacity(_ region: NSRect) -> CGFloat {
        min(Self.preferredSize.width, region.width) * min(Self.preferredSize.height, region.height)
    }
}
