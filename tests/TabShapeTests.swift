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
        failures.forEach { print("FAIL: " + $0) }
        guard failures.isEmpty else { exit(1) }
        print("PASS: \(assertions) native tab shape/placement assertions (no windows shown)")
    }
}
