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
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
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
        copy([(.png, try Data(contentsOf: photo))])
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
        history.prepare = { nil }
        history.pickupMagnet = { false }
        func drawerTab(_ tab: ClipboardBrowserTab) {
            drawer.browser.tabs.selectedSegment = tab.rawValue
            drawer.browser.tabs.sendAction(drawer.browser.tabs.action!, to: drawer.browser.tabs.target)
        }
        func windowTab(_ tab: ClipboardBrowserTab) {
            history.view.tabs.selectedSegment = tab.rawValue
            history.view.tabs.sendAction(history.view.tabs.action!, to: history.view.tabs.target)
        }
        // Native screen region includes the edge and enough room for the history window.
        let capture = NSRect(x: max(frame.minX, frame.maxX - 1130), y: max(frame.minY, frame.maxY - 790), width: min(1130, frame.width), height: min(790, frame.height))
        let topY = screen.frame.maxY - capture.maxY
        let region = "\(Int(capture.minX)),\(Int(topY)),\(Int(capture.width)),\(Int(capture.height))"
        let info: [String: Any] = ["region": region, "fixtureOnly": true,
            "titles": store.entries.map(\.title), "screen": NSStringFromRect(screen.frame),
            "video": "macOS screencapture; real WindowServer frames; real drawer motion at standard 300ms"]
        try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("capture.json"))
        func captureStill() throws {
            let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = ["-x", "-R" + region, root.appendingPathComponent("screenshot-raw.png").path]
            try task.run(); task.waitUntilExit(); precondition(task.terminationStatus == 0)
        }
        // Hero: both actual windows share the exact same fictional store.
        drawer.show(on: screen, animated: false); drawerTab(.all)
        _ = drawer.browser.canvas.answer(.quickLook, image)
        settle(2.0)
        previewPanel.setFrameOrigin(NSPoint(x: capture.minX + 35, y: capture.midY - previewPanel.frame.height / 2))
        settle(0.3); try captureStill()
        history.close(); store.cancelStaging(); drawer.hide(animated: false); settle(0.7)
        if ProcessInfo.processInfo.environment["CLIPEDGE_README_STILL_ONLY"] == "1" { return }
        try? FileManager.default.removeItem(at: root.appendingPathComponent("demo-raw.mov"))
        let recording = Process(); recording.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        recording.arguments = ["-x", "-v", "-V20", "-R" + region, root.appendingPathComponent("demo-raw.mov").path]
        try recording.run(); settle(1.0)
        func preview(_ entry: ClipboardEntry) {
            store.previewInCarousel(entry, among: drawer.browser.visibleEntries)
            settle(0.15)
            previewPanel.setFrameOrigin(NSPoint(x: capture.minX + 35, y: capture.midY - previewPanel.frame.height / 2))
        }
        drawer.show(on: screen); settle(0.4); preview(image); settle(1.65)
        drawerTab(.images); preview(image); settle(1.85)
        drawerTab(.text); preview(note); settle(1.85)
        drawerTab(.other); preview(list); settle(1.65)
        drawer.hide(animated: true); settle(0.8)
        history.hotKeyPressed(); historyPanel.setFrameOrigin(NSPoint(x: capture.midX - 400, y: capture.midY - 235)); settle(1.7)
        windowTab(.images); history.view.canvas.choose(image.id); settle(1.8)
        windowTab(.text); history.view.canvas.choose(note.id); settle(1.1)
        // Use the real Copy action: closes history and changes only our named board.
        history.view.footer.items.first { $0.title.hasPrefix("Copy") }?.action(); settle(0.7)
        drawer.show(on: screen); drawerTab(.all); settle(1.6)
        drawer.hide(animated: true); settle(1)
        while recording.isRunning { settle(0.1) }
        precondition(recording.terminationStatus == 0, "screen recording failed")
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

private final class CapturePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
