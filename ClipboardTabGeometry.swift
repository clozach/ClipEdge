import AppKit

enum ClipboardDockEdge: String, Codable, CaseIterable {
    case left, right, top
}

struct ClipboardTabPlacement: Codable, Equatable {
    var edge: ClipboardDockEdge = .right
    // Fraction of the usable edge axis, after the small end margins.
    var center: Double = 0.5
    var length: Double = 240
    var screenID: UInt32? = nil
}

struct ClipboardDockLayout {
    let tabFrame: NSRect
    let bodyFrame: NSRect
    let expandedTabFrame: NSRect

    var expandedFrame: NSRect { expandedTabFrame.union(bodyFrame) }
}

/// Pure geometry shared by the resting tab, drag preview, and expanded panel.
/// All coordinates are global AppKit coordinates, with Y increasing upward.
enum ClipboardTabGeometry {
    static let tabDepth: CGFloat = 28
    static let minimumLength: CGFloat = 28
    static let defaultLength: CGFloat = 240
    static let endMargin: CGFloat = 8
    static let bodyOverlap: CGFloat = 8

    static func layout(placement: ClipboardTabPlacement, in visibleFrame: NSRect) -> ClipboardDockLayout {
        let frame = usableFrame(visibleFrame)
        let axis = usableAxis(for: placement.edge, in: frame)
        let resolved = resolvedPlacement(placement, axis: axis, maximumLength: maximumTabLength(for: placement.edge, in: frame))
        let length = CGFloat(resolved.length)
        let center = axis.lowerBound + CGFloat(resolved.center) * axisLength(axis)

        switch placement.edge {
        case .left, .right:
            let depth = min(tabDepth, frame.width)
            let overlap = min(bodyOverlap, depth)
            let bodyWidth = min(390, frame.width * 0.45,
                                max(0, frame.width - depth + overlap))
            let join = min(overlap, bodyWidth)
            let tab = NSRect(x: placement.edge == .left ? frame.minX : frame.maxX - depth,
                             y: center - length / 2, width: depth, height: length)
            let body = NSRect(x: placement.edge == .left ? frame.minX : frame.maxX - bodyWidth,
                              y: frame.minY, width: bodyWidth, height: frame.height)
            let exposedTab = NSRect(x: placement.edge == .left ? body.maxX - join : body.minX - depth + join,
                                   y: tab.minY, width: depth, height: length)
            return ClipboardDockLayout(tabFrame: tab, bodyFrame: body, expandedTabFrame: exposedTab)
        case .top:
            let depth = min(tabDepth, frame.height)
            let overlap = min(bodyOverlap, depth)
            let bodyWidth = min(390, frame.width)
            let bodyHeight = min(700, frame.height * 0.8,
                                 max(0, frame.height - depth + overlap))
            let tab = NSRect(x: center - length / 2, y: frame.maxY - depth,
                             width: length, height: depth)
            let bodyX = clamped(center - bodyWidth / 2,
                                to: frame.minX...(frame.maxX - bodyWidth))
            let body = NSRect(x: bodyX, y: frame.maxY - bodyHeight,
                              width: bodyWidth, height: bodyHeight)
            let exposedTab = NSRect(x: tab.minX, y: body.minY - depth + min(overlap, bodyHeight), width: length, height: depth)
            return ClipboardDockLayout(tabFrame: tab, bodyFrame: body, expandedTabFrame: exposedTab)
        }
    }

    /// Selects the nearest permitted boundary. The bottom is intentionally not
    /// a destination, so it cannot collide with the Dock.
    static func moved(_ placement: ClipboardTabPlacement, to point: NSPoint,
                      in visibleFrame: NSRect, wallOffset: NSPoint = .zero) -> ClipboardTabPlacement {
        let frame = usableFrame(visibleFrame)
        let rawPoint = NSPoint(x: point.x.isFinite ? point.x : frame.midX,
                              y: point.y.isFinite ? point.y : frame.midY)
        // An open drawer's handle sits inward from its wall. Preserve that
        // offset for motion along the same edge, but directly approaching a
        // different boundary must always let the user dock there.
        let nearBoundary = ClipboardDockEdge.allCases.map { distance(from: rawPoint, to: $0, in: frame) }.min() ?? 0
        let pointer = nearBoundary <= 44 ? rawPoint : NSPoint(x: rawPoint.x + wallOffset.x, y: rawPoint.y + wallOffset.y)
        var result = placement
        var nearest = placement.edge
        var nearestDistance = distance(from: pointer, to: nearest, in: frame)
        for edge in ClipboardDockEdge.allCases where edge != placement.edge {
            let candidateDistance = distance(from: pointer, to: edge, in: frame)
            // Preserve the current edge at an exact corner tie to avoid jitter.
            if candidateDistance < nearestDistance {
                nearest = edge
                nearestDistance = candidateDistance
            }
        }
        result.edge = nearest
        let axis = usableAxis(for: nearest, in: frame)
        let coordinate = nearest == .top ? pointer.x : pointer.y
        result.center = axisLength(axis) > 0
            ? Double((coordinate - axis.lowerBound) / axisLength(axis)) : 0.5
        return resolvedPlacement(result, axis: axis, maximumLength: maximumTabLength(for: nearest, in: frame))
    }

    /// `delta` is one handle's outward travel. Both ends travel that distance,
    /// preserving the current center even when an end reaches its margin.
    static func resized(_ placement: ClipboardTabPlacement, by delta: CGFloat,
                        in visibleFrame: NSRect) -> ClipboardTabPlacement {
        let frame = usableFrame(visibleFrame)
        let axis = usableAxis(for: placement.edge, in: frame)
        let limit = maximumTabLength(for: placement.edge, in: frame)
        var result = resolvedPlacement(placement, axis: axis, maximumLength: limit)
        let center = CGFloat(result.center) * axisLength(axis)
        let maximumLength = min(limit, max(0, 2 * min(center, axisLength(axis) - center)))
        let minimum = min(minimumLength, maximumLength)
        let travel = delta.isFinite ? delta : 0
        result.length = Double(clamped(CGFloat(result.length) + 2 * travel,
                                       to: minimum...maximumLength))
        return result
    }

    private static func usableFrame(_ frame: NSRect) -> NSRect {
        NSRect(x: frame.origin.x.isFinite ? frame.origin.x : 0,
               y: frame.origin.y.isFinite ? frame.origin.y : 0,
               width: frame.width.isFinite ? max(0, frame.width) : 0,
               height: frame.height.isFinite ? max(0, frame.height) : 0)
    }

    private static func margin(for length: CGFloat) -> CGFloat {
        min(endMargin, length / 4)
    }

    private static func usableAxis(for edge: ClipboardDockEdge, in frame: NSRect) -> ClosedRange<CGFloat> {
        let start = edge == .top ? frame.minX : frame.minY
        let length = edge == .top ? frame.width : frame.height
        let inset = margin(for: length)
        return (start + inset)...(start + length - inset)
    }

    private static func axisLength(_ axis: ClosedRange<CGFloat>) -> CGFloat {
        max(0, axis.upperBound - axis.lowerBound)
    }

    private static func resolvedPlacement(_ placement: ClipboardTabPlacement,
                                          axis: ClosedRange<CGFloat>, maximumLength: CGFloat) -> ClipboardTabPlacement {
        var result = placement
        let available = axisLength(axis)
        let requestedLength = placement.length.isFinite ? CGFloat(placement.length) : defaultLength
        let limit = min(available, maximumLength)
        let length = clamped(requestedLength, to: min(minimumLength, limit)...limit)
        let requestedCenter = placement.center.isFinite ? CGFloat(placement.center) : 0.5
        let center = clamped(requestedCenter * available, to: (length / 2)...(available - length / 2))
        result.length = Double(length)
        result.center = available > 0 ? Double(center / available) : 0.5
        return result
    }

    private static func maximumTabLength(for edge: ClipboardDockEdge, in frame: NSRect) -> CGFloat {
        edge == .top ? min(390, frame.width) : frame.height
    }

    private static func clamped(_ value: CGFloat, to range: ClosedRange<CGFloat>) -> CGFloat {
        min(range.upperBound, max(range.lowerBound, value))
    }

    private static func distance(from point: NSPoint, to edge: ClipboardDockEdge, in frame: NSRect) -> CGFloat {
        let closest: NSPoint
        switch edge {
        case .left:
            closest = NSPoint(x: frame.minX, y: clamped(point.y, to: frame.minY...frame.maxY))
        case .right:
            closest = NSPoint(x: frame.maxX, y: clamped(point.y, to: frame.minY...frame.maxY))
        case .top:
            closest = NSPoint(x: clamped(point.x, to: frame.minX...frame.maxX), y: frame.maxY)
        }
        return hypot(point.x - closest.x, point.y - closest.y)
    }
}
