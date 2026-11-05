import AppKit

/// Marketing fixtures only: the original controllers, a named pasteboard, nil persistence,
/// nil defaults and a private materializer. Capture the actual WindowServer animation.
@main enum ReadmeCapture {
    static func settle(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            fatalError("usage: readme-capture <costume-photo.png> <scratch-directory>")
        }
        let photo = URL(fileURLWithPath: CommandLine.arguments[1])
        let photoData = try Data(contentsOf: photo)
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let rehearsing = ProcessInfo.processInfo.environment["CLIPEDGE_README_REHEARSE"] == "1"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previews = ClipboardMaterializer.usePrivateRoot()
        defer { try? FileManager.default.removeItem(at: previews) }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .aqua)
        let screen = NSScreen.main!
        let frame = screen.visibleFrame
        let backdrop = CapturePanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        backdrop.backgroundColor = NSColor(srgbRed: 0.91, green: 0.89, blue: 0.94, alpha: 1)
        backdrop.isOpaque = true
        let ground = NSView(frame: NSRect(origin: .zero, size: frame.size))
        ground.wantsLayer = true
        ground.layer?.backgroundColor = backdrop.backgroundColor!.cgColor
        backdrop.contentView = ground
        backdrop.level = NSWindow.Level(rawValue: 900)
        backdrop.orderFrontRegardless()
        defer { backdrop.orderOut(nil) }

        let board = NSPasteboard.withUniqueName()
        let store = ClipboardStore(pasteboard: board, persistenceURL: nil)
        defer { store.stop(); board.releaseGlobally() }
        func copy(_ values: [(NSPasteboard.PasteboardType, Data)]) {
            board.clearContents()
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            board.writeObjects([item]); store.saveNow()
        }
        func text(_ value: String) { copy([(.string, Data(value.utf8))]) }
        text("Sunday reset: oat cappuccino, flowers, then the 11am mat class.")
        text("https://example.com/shop/angel-devil-duo")
        text("Maya: angel + devil costumes?? Silver + red boots, tiny bags, rooftop party at 9. I'm so in ✨")
        copy([(.png, photoData)])
        let checklist = root.appendingPathComponent("Halloween duo — shopping list.pdf")
        try makePDF().write(to: checklist)
        board.clearContents(); board.writeObjects([checklist as NSURL]); store.saveNow()
        text("Halloween shopping: silver angel wings, red devil horns, glitter liner. Send Maya the screenshots before checkout.")
        for (index, entry) in store.entries.enumerated() {
            entry.capturedAt = Date(timeIntervalSince1970: 1792256400 - Double(index * 180))
        }
        let image = store.entries.first { $0.isImage }!
        let list = store.entries.first { !$0.fileURLs.isEmpty }!
        let note = store.entries[0]
        store.cancelStaging()
        image.searchIndex = .ready("")
        settle(2)
        // Paths and file facts are derived only from our public fictional fixture.
        for entry in store.entries where !entry.fileURLs.isEmpty {
            entry.metadata.paths = ["~/Downloads/Halloween duo — shopping list.pdf"]
        }
        let drawerPanel = CapturePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        let historyPanel = CapturePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        let previewPanel = CapturePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        let magnet = ClipboardMagnetController(panel: previewPanel, commandClickEnabled: false)
        var environment = ClipboardPaster.Environment.inert
        environment.failed = {}
        let paster = ClipboardPaster(store: store, environment: environment)
        let drawer = ClipboardDrawerController(store: store, magnetController: magnet, panel: drawerPanel,
                                                defaults: nil, paster: paster, animationsEnabled: { true })
        defer { drawer.stop() }
        let history = ClipboardHistoryController(store: store, paster: paster, previewService: drawer.previewService, panel: historyPanel)
        for panel in [drawerPanel, historyPanel, previewPanel] { panel.level = NSWindow.Level(rawValue: 901) }
        drawer.sizes = { ClipboardSizes(text: 130, thumbnails: 110, preview: 80) }
        history.sizes = { ClipboardSizes(text: 120, thumbnails: 110, preview: 80) }
        drawer.applySizes()
        history.prepare = { nil }
        history.pickupMagnet = { false }
        // Native screen region includes the edge and enough room for the history window.
        let capture = NSRect(x: max(frame.minX, frame.maxX - 1000), y: max(frame.minY, frame.maxY - 740), width: min(1000, frame.width), height: min(740, frame.height))
        historyPanel.placement = .centered(NSPoint(x: capture.midX, y: capture.midY))
        previewPanel.placement = .left(capture.minX + 35, midY: capture.midY)
        let topY = screen.frame.maxY - capture.maxY
        let region = "\(Int(capture.minX)),\(Int(topY)),\(Int(capture.width)),\(Int(capture.height))"
        let info: [String: Any] = ["region": region, "fixtureOnly": true,
            "titles": store.entries.map(\.title), "screen": NSStringFromRect(screen.frame),
            "video": "macOS screencapture; real WindowServer frames; real drawer motion at standard 300ms"]
        try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("capture.json"))
        // Setup happens before recording: useful populated first frame, stable native sizes.
        drawer.show(on: screen, animated: false)
        let input = ReadmeInput(frame: capture, output: root.appendingPathComponent(rehearsing ? "rehearsal.json" : "timeline.json"))
        input.overlay.cursor = NSPoint(x: capture.width - 230, y: 150)
        input.cue("Click Images")
        CGDisplayHideCursor(CGMainDisplayID())
        defer { CGDisplayShowCursor(CGMainDisplayID()); input.panel.orderOut(nil) }
        let recording = Process()
        // This defer runs before the cursor/backdrop/window cleanups, including on
        // an assertion thrown by the input screenplay. Only our recorder is stopped.
        defer {
            if recording.isRunning { recording.terminate(); recording.waitUntilExit() }
        }
        if !rehearsing {
            try? FileManager.default.removeItem(at: root.appendingPathComponent("demo-raw.mov"))
            recording.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            recording.arguments = ["-x", "-v", "-V38", "-R" + region, root.appendingPathComponent("demo-raw.mov").path]
            try recording.run()
        }
        input.began = ProcessInfo.processInfo.systemUptime
        let story = ReadmeStory(drawer: drawer, history: history, drawerPanel: drawerPanel, historyPanel: historyPanel,
                                magnet: magnet, store: store, board: board, image: image, note: note, file: list,
                                photo: photoData, input: input)
        let summary = try story.run()
        try JSONSerialization.data(withJSONObject: info.merging(summary) { _, new in new }, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent(rehearsing ? "rehearsal-summary.json" : "capture.json"))
        if !rehearsing {
            while recording.isRunning { settle(0.1) }
            precondition(recording.terminationStatus == 0, "screen recording failed")
        }
        history.close()
    }

    static func makePDF() -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 600, height: 760)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0.98, alpha: 1)); context.fill(box)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let lines = ["HALLOWEEN DUO", "Angel + devil / city rooftop / 9pm", "", "Silver angel wings + halo", "Red devil wings + horns", "Glitter liner + silver / red boots", "Tiny bags (phone, keys, lip gloss)", "", "Send Maya the screenshots ✨"]
        for (index, line) in lines.enumerated() {
            (line as NSString).draw(at: NSPoint(x: 48, y: 660 - index * 55), withAttributes: [
                .font: NSFont.systemFont(ofSize: index == 0 ? 34 : 22, weight: index == 0 ? .bold : .regular),
                .foregroundColor: NSColor(srgbRed: 0.27, green: 0.19, blue: 0.4, alpha: 1)])
        }
        NSGraphicsContext.restoreGraphicsState(); context.endPDFPage(); context.closePDF()
        return data as Data
    }
}

private enum CapturePlacement {
    case native, centered(NSPoint), left(CGFloat, midY: CGFloat)
}

private final class CapturePanel: NSPanel {
    var placement = CapturePlacement.native
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var frame = frameRect
        switch placement {
        case .native: break
        case .centered(let center): frame.origin = NSPoint(x: center.x - frame.width / 2, y: center.y - frame.height / 2)
        case .left(let x, let midY): frame.origin = NSPoint(x: x, y: midY - frame.height / 2)
        }
        super.setFrame(frame, display: flag)
    }
}
