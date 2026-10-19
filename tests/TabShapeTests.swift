import AppKit

@main enum TabShapeTests {
    static var assertions = 0
    static var failures: [String] = []
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() { failures.append(message) }
    }
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .aqua)
        let glass = ClipboardGlassView(frame: .zero)
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = glass
        // Reuse the same native hierarchy, as a dragged tab does when changing walls.
        for edge in [ClipboardDockEdge.right, .left, .top, .right] {
            for expanded in [false, true] {
                let layout = ClipboardTabGeometry.layout(placement: .init(edge: edge, length: 180),
                                                         in: NSRect(x: 0, y: 0, width: 700, height: 600))
                let frame = expanded ? layout.expandedFrame : layout.tabFrame
                let tab = (expanded ? layout.expandedTabFrame : layout.tabFrame).offsetBy(dx: -frame.minX, dy: -frame.minY)
                let body = expanded ? layout.bodyFrame.offsetBy(dx: -frame.minX, dy: -frame.minY) : nil
                window.setFrame(frame, display: false)
                glass.frame = NSRect(origin: .zero, size: frame.size)
                glass.updateLayout(bodyRect: body, tabRect: tab, edge: edge)
                glass.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                check(glass.tabControl.convert(glass.tabControl.bounds, to: glass) == tab,
                      "\(edge) \(expanded): translated host preserves the tab's hit target")
                if let body {
                    check(glass.bodyContent.convert(glass.bodyContent.bounds, to: glass) == body,
                          "\(edge): translated host preserves drawer content placement")
                    // The free edges carry the width grips (2026-10-16): the inner one at a side, both at the top.
                    let left = glass.edgeGrips.left, right = glass.edgeGrips.right
                    check(left.isHidden == (edge == .left) && right.isHidden == (edge == .right),
                          "\(edge): the grips sit on the drawer's free edges only")
                    for grip in [left, right] where !grip.isHidden {
                        let frame = grip.convert(grip.bounds, to: glass)
                        check(abs((grip === left ? frame.minX : frame.maxX) - (grip === left ? body.minX : body.maxX)) < 0.5
                              && frame.width == ClipboardDrawerEdgeGrip.depth && frame.minY >= body.minY + 26 && frame.maxY <= body.maxY - 26,
                              "\(edge): a grip runs along its edge, inside the body, clear of the corners (\(frame) in \(body))")
                        check(grip.gain == (edge == .top ? 2 : 1), "\(edge): a top drawer widens on both sides, so its grips count double")
                    }
                } else {
                    check(glass.edgeGrips.left.isHidden && glass.edgeGrips.right.isHidden, "\(edge): a closed drawer has no grips")
                }
                if #available(macOS 26.0, *),
                   let container = glass.subviews.compactMap({ $0 as? NSGlassEffectContainerView }).first,
                   let host = container.contentView {
                    let surfaces = host.subviews.compactMap { $0 as? NSGlassEffectView }.filter { !$0.isHidden }
                    check(surfaces.count == (expanded ? 2 : 1), "\(edge) \(expanded): expected live glass surfaces")
                    for surface in surfaces {
                        check(host.bounds.contains(surface.frame), "\(edge) \(expanded): complete rounded surface remains inside glass compositor")
                    }
                }
                let bitmap = glass.bitmapImageRepForCachingDisplay(in: glass.bounds)!
                bitmap.bitmapData?.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
                glass.cacheDisplay(in: glass.bounds, to: bitmap)
                if !expanded {
                    let x = edge == .left ? bitmap.pixelsWide - 1 : 0
                    let y = edge == .top ? bitmap.pixelsHigh - 1 : 0
                    check((bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 1) < 0.1,
                          "\(edge): exposed corner is rounded in the native cache capture")
                    check((bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.alphaComponent ?? 0) > 0.5,
                          "\(edge): tab center stays visible")
                }
                if CommandLine.arguments.count > 1 {
                    let url = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("tab-\(edge)-\(expanded ? "open" : "closed").png")
                    try bitmap.representation(using: .png, properties: [:])!.write(to: url)
                }
            }
        }
        // The tab calls the window it opens by the name the gear and its title use.
        let help = ClipboardTabView(frame: .zero)
        check(help.toolTip?.hasSuffix("\nSettings ← right-click") == true && help.toolTip?.contains("Reveal Settings") == false
              && help.accessibilityHelp()?.contains("Reveal Settings") == false, "the tab's help names Settings as the gear does")
        gestureChecks()
        failures.forEach { print("FAIL: " + $0) }
        guard failures.isEmpty else { exit(1) }
        print("PASS: \(assertions) native tab shape/placement assertions (no windows shown)")
    }

    /// Al, 2026-10-16: a drag on the tab that starts across its wall slides the drawer, with the
    /// speed it lets go at; one that starts along the wall moves the tab, as before.
    static func gestureChecks() {
        let window = NSWindow(contentRect: NSRect(x: 500, y: 300, width: 28, height: 200), styleMask: .borderless, backing: .buffered, defer: false)
        let tab = ClipboardTabView(frame: NSRect(x: 0, y: 0, width: 28, height: 200))
        window.contentView = tab
        var slides: [CGFloat] = [], moves = 0, released: CGFloat?, clicks = 0
        tab.onSlide = { slides.append($0) }
        tab.onDrag = { _ in moves += 1 }
        tab.onSlideEnded = { released = $0 }
        tab.onClick = { clicks += 1 }
        func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat, _ time: TimeInterval) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: [], timestamp: time,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func drag(_ points: [(CGFloat, CGFloat, TimeInterval)], upAt: TimeInterval, from start: NSPoint = NSPoint(x: 14, y: 100)) {
            slides = []; moves = 0; released = nil
            tab.mouseDown(with: event(.leftMouseDown, start.x, start.y, points[0].2 - 0.02))
            for (x, y, t) in points { tab.mouseDragged(with: event(.leftMouseDragged, x, y, t)) }
            tab.mouseUp(with: event(.leftMouseUp, points.last!.0, points.last!.1, upAt))
        }
        for edge in [ClipboardDockEdge.right, .left] {
            tab.edge = edge
            let s: CGFloat = edge == .right ? -1 : 1
            drag([(14 + 10 * s, 101, 1.02), (14 + 54 * s, 102, 1.06), (14 + 100 * s, 103, 1.10)], upAt: 1.10)
            check(slides == [10, 54, 100] && moves == 0, "\(edge): a drag away from the wall slides the drawer (\(slides), \(moves) moves)")
            check(released.map { abs($0 - 1125) < 1 } == true, "\(edge): it lets go at its last tenth of a second's speed (\(released ?? .nan))")
            drag([(14 - 10 * s, 100, 2.02), (14 - 30 * s, 100, 2.06)], upAt: 2.06)
            check(slides == [-10, -30] && released.map { $0 < 0 } == true, "\(edge): toward the wall the travel and speed are negative")
            drag([(15, 130, 3.02), (40 * s + 14, 160, 3.06)], upAt: 3.06)
            check(slides.isEmpty && moves == 2 && released == nil, "\(edge): a drag that starts along the wall moves the tab, even when it turns across")
            drag([(14 + 30 * s, 100, 4.0), (14 + 60 * s, 100, 4.05)], upAt: 4.5)
            check(released == 0, "\(edge): a pause before letting go is no flick")
        }
        tab.edge = .top
        tab.frame = NSRect(x: 0, y: 0, width: 200, height: 28)
        drag([(100, 4, 5.02), (101, -36, 5.06)], upAt: 5.06, from: NSPoint(x: 100, y: 14))
        check(slides == [10, 50] && moves == 0, "top: a drag down, away from the wall, slides the drawer (\(slides))")
        let before = clicks
        tab.mouseDown(with: event(.leftMouseDown, 14, 14, 6)); tab.mouseUp(with: event(.leftMouseUp, 14, 14, 6.1))
        check(clicks == before + 1, "a press without travel is still a click")
    }
}
