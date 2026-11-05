import AppKit

/// A single input clock drives the visible cursor, press/key cue, scoped event and receipt.
/// The cursor image is macOS's own arrow; no systemwide keyboard listener or event posting.
final class ReadmeInput {
    let panel: NSPanel
    let overlay: ReadmeInputOverlay
    let output: URL
    var began = ProcessInfo.processInfo.systemUptime
    var events: [[String: Any]] = []
    var seconds: TimeInterval { ProcessInfo.processInfo.systemUptime - began }

    init(frame: NSRect, output: URL) {
        self.output = output
        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        overlay = ReadmeInputOverlay(frame: NSRect(origin: .zero, size: frame.size))
        panel.contentView = overlay
        panel.isOpaque = false; panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true; panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: 902)
        panel.orderFrontRegardless()
        overlay.cursor = NSPoint(x: 120, y: 110)
    }
    deinit { panel.orderOut(nil) }

    func screenPoint(_ point: NSPoint) -> NSPoint {
        NSPoint(x: point.x - panel.frame.minX, y: panel.frame.maxY - point.y)
    }
    func move(to point: NSPoint, duration: TimeInterval = 0.8) {
        let from = overlay.cursor, to = screenPoint(point), start = ProcessInfo.processInfo.systemUptime
        repeat {
            let t = min(1, (ProcessInfo.processInfo.systemUptime - start) / duration)
            let eased = t * t * (3 - 2 * t)
            overlay.cursor = NSPoint(x: from.x + (to.x - from.x) * eased, y: from.y + (to.y - from.y) * eased)
            overlay.needsDisplay = true
            ReadmeCapture.settle(1 / 60)
        } while ProcessInfo.processInfo.systemUptime - start < duration
        overlay.cursor = to; overlay.needsDisplay = true
    }
    func cue(_ text: String) { overlay.cue = text; overlay.needsDisplay = true }

    func click(_ label: String, view: NSView, at local: NSPoint? = nil, hold: TimeInterval = 1.3,
               verify: () -> Bool) throws {
        guard let window = view.window, let content = window.contentView else { throw failure("target is not attached") }
        let point = local ?? NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        let inWindow = view.convert(point, to: nil)
        let global = window.convertPoint(toScreen: inWindow)
        content.layoutSubtreeIfNeeded()
        // NSView.hitTest takes its superview's coordinates, which differs from
        // content coordinates when the history view has a native text zoom.
        let hitPoint = content.superview?.convert(inWindow, from: nil) ?? inWindow
        guard let hit = content.hitTest(hitPoint), hit === view || hit.isDescendant(of: view) else {
            events.append(["kind": "geometryFailure", "cue": label, "target": NSStringFromPoint(global),
                           "contentFrame": NSStringFromRect(content.frame), "contentBounds": NSStringFromRect(content.bounds),
                           "hitPoint": NSStringFromPoint(hitPoint), "delivered": false, "verified": false])
            try save()
            throw failure("\(label): measured target did not hit its native view")
        }
        cue(label); ReadmeCapture.settle(0.45)
        move(to: global); ReadmeCapture.settle(0.32)
        let pressed = seconds
        overlay.pressBegan = ProcessInfo.processInfo.systemUptime
        overlay.needsDisplay = true; overlay.displayIfNeeded()
        let down = mouse(.leftMouseDown, point: inWindow, window: window)
        let up = mouse(.leftMouseUp, point: inWindow, window: window)
        let route: String
        let delivered: Bool
        if let tabs = hit as? NSSegmentedControl {
            // Native cells consult physical pressed-button state while tracking. A
            // scripted fixture resolves the hit-tested segment and dispatches its
            // real target/action in this same press operation instead.
            let location = tabs.convert(inWindow, from: nil)
            var edge: CGFloat = 0
            var index: Int?
            for segment in 0..<tabs.segmentCount {
                let next = edge + tabs.width(forSegment: segment)
                if location.x >= edge && location.x < next { index = segment; break }
                edge = next
            }
            guard let index, let action = tabs.action else { throw failure("\(label): no native segment at measured point") }
            tabs.selectedSegment = index
            delivered = tabs.sendAction(action, to: tabs.target)
            route = "hit-tested native segment → production target/action"
        } else {
            // The edge tab's native handler accepts these scoped mouse phases.
            hit.mouseDown(with: down)
            ReadmeCapture.settle(0.12)
            hit.mouseUp(with: up)
            delivered = true
            route = "hit-tested native view mouseDown/mouseUp"
        }
        ReadmeCapture.settle(0.38)
        let passed = verify()
        events.append(["kind": "click", "cue": label, "seconds": pressed,
                       "target": NSStringFromPoint(global), "nativeHit": String(describing: type(of: hit)),
                       "window": window.windowNumber, "route": route, "delivered": delivered, "verified": passed])
        try save()
        guard delivered && passed else { throw failure("\(label): native action did not reach its expected result") }
        ReadmeCapture.settle(hold)
    }

    func key(_ label: String, code: UInt16, modifiers: NSEvent.ModifierFlags, characters: String,
             window: NSWindow, route: String, hold: TimeInterval = 1.4,
             deliver: (NSEvent) -> Bool, verify: () -> Bool) throws {
        cue(label); ReadmeCapture.settle(0.85)
        let pressed = seconds
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                    context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                    isARepeat: false, keyCode: code)!
        overlay.keyPressed = true; overlay.needsDisplay = true; overlay.displayIfNeeded()
        let delivered = deliver(event)
        ReadmeCapture.settle(0.38)
        let passed = verify()
        events.append(["kind": "key", "cue": label, "seconds": pressed, "keyCode": Int(code),
                       "modifierFlags": modifiers.rawValue, "route": route, "window": window.windowNumber,
                       "delivered": delivered, "verified": passed])
        try save()
        guard delivered && passed else { throw failure("\(label): key delivery or result failed") }
        overlay.keyPressed = false; overlay.needsDisplay = true
        ReadmeCapture.settle(hold)
    }
    func save() throws {
        try JSONSerialization.data(withJSONObject: ["events": events], options: [.prettyPrinted, .sortedKeys]).write(to: output)
    }
    private func failure(_ text: String) -> Error { NSError(domain: "ReadmeInput", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    private func mouse(_ type: NSEvent.EventType, point: NSPoint, window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                          windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
                          pressure: type == .leftMouseDown ? 1 : 0)!
    }
}

/// Capture-only annotation. It never handles input or changes the app's layout.
final class ReadmeInputOverlay: NSView {
    var cursor = NSPoint.zero
    var cue = ""
    var pressBegan: TimeInterval?
    var keyPressed = false
    private var ticker: Timer?
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        ticker = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in self?.needsDisplay = true }
        RunLoop.main.add(ticker!, forMode: .common)
    }
    required init?(coder: NSCoder) { fatalError("init(frame:)") }
    deinit { ticker?.invalidate() }
    override func draw(_ dirtyRect: NSRect) {
        if let start = pressBegan {
            let age = ProcessInfo.processInfo.systemUptime - start
            if age < 0.55 {
                let radius = 10 + 23 * age / 0.55
                let ring = NSBezierPath(ovalIn: NSRect(x: cursor.x - radius, y: cursor.y - radius, width: radius * 2, height: radius * 2))
                NSColor.white.withAlphaComponent(0.95 * (1 - age / 0.55)).setStroke()
                ring.lineWidth = 5; ring.stroke()
                NSColor.systemBlue.withAlphaComponent(0.6 * (1 - age / 0.55)).setFill(); ring.fill()
            }
        }
        if !cue.isEmpty {
            let lines = cue.components(separatedBy: "\n")
            let height: CGFloat = lines.count > 1 ? 76 : 48
            let textWidth = lines.enumerated().map { index, line in
                (line as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: index == 0 ? 26 : 20, weight: .semibold)]).width
            }.max() ?? 0
            let box = NSRect(x: 24, y: bounds.height - height - 8, width: min(textWidth + 36, bounds.width - 470), height: height)
            (keyPressed ? NSColor(srgbRed: 0.12, green: 0.29, blue: 0.58, alpha: 0.97) : NSColor(calibratedWhite: 0.08, alpha: 0.94)).setFill()
            NSBezierPath(roundedRect: box, xRadius: 13, yRadius: 13).fill()
            for (index, line) in lines.enumerated() {
                (line as NSString).draw(at: NSPoint(x: box.minX + 18, y: box.minY + 8 + CGFloat(index) * 31),
                    withAttributes: [.font: NSFont.systemFont(ofSize: index == 0 ? 26 : 20, weight: .semibold), .foregroundColor: NSColor.white])
            }
        }
        let arrow = NSCursor.arrow
        let image = arrow.image, scale: CGFloat = 1.8
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: NSRect(x: cursor.x - arrow.hotSpot.x * scale, y: cursor.y - arrow.hotSpot.y * scale,
                             width: size.width, height: size.height), from: .zero, operation: .sourceOver,
                   fraction: 1, respectFlipped: true, hints: nil)
    }
}
