import AppKit

/// Al, 2026-10-16: tuners for text size, thumbnail size and preview size. Text size zooms each
/// window's content (the drawer keeps its width and lays out within it; the ⌥⌘\ window and Settings
/// grow), thumbnail size the pictures at the start of each row, preview size Quick Look.
/// Isolated preferences, named pasteboards, nothing on screen.
@main enum SizesTests {
    private static var assertions = 0
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError("FAIL: \(message)") }
    }
    private static func spin(_ seconds: TimeInterval = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    static func main() {
        _ = NSApplication.shared
        modelChecks()
        settingsChecks()
        drawerChecks()
        windowChecks()
        previewChecks()
        besideChecks()
        print("PASS: \(assertions) size assertions; isolated preferences, named pasteboards, nothing on screen")
    }

    private static func modelChecks() {
        let name = ClipboardMaterializer.privateSuiteName("ClipEdge-size-tests-")
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = ClipboardRevealSettings(defaults: defaults)
        check(settings.sizes == .standard, "every size starts at 100%")
        var posts = 0
        let observer = NotificationCenter.default.addObserver(forName: ClipboardRevealSettings.didChange, object: settings, queue: nil) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        settings.sizes.text = 150
        settings.sizes.thumbnails = 999
        settings.sizes.preview = 87
        check(settings.sizes == ClipboardSizes(text: 150, thumbnails: 300, preview: 85) && posts == 3, "each change is kept in range, in steps of 5, and announced")
        settings.sizes.text = 150
        check(posts == 3, "an unchanged size announces nothing")
        let again = ClipboardRevealSettings(defaults: defaults)
        check(again.sizes == ClipboardSizes(text: 150, thumbnails: 300, preview: 85), "and each is saved")
        check(ClipboardSizes(text: .nan, thumbnails: 10, preview: 500).valid == ClipboardSizes(text: 100, thumbnails: 50, preview: 200), "an unreadable size is 100%, others clamp")
        let spec = ClipboardTunerSpec.percent("Text size", range: ClipboardSizes.textRange, symbol: "textformat.size", glyph: "A")
        check(spec.text(125) == "125%" && spec.parsed("130 %") == 130 && spec.nudged(200, by: 1, large: false) == 200 && spec.scrubbed(from: 100, points: 3) == 115,
              "a size reads like 125%, types, nudges and drags in steps of 5")
    }

    private static func settingsChecks() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let settings = ClipboardRevealSettings(defaults: nil)
        let controller = ClipboardRevealSettingsController(settings: settings, pasteboard: board)
        let window = controller.window!
        NotificationCenter.default.post(name: ClipboardRevealSettings.didChange, object: settings)
        spin()
        let sizes = controller.sizeTuners
        check(sizes.map(\.spec.label) == ["Text size", "Thumbnail size", "Preview size"] && Array(controller.tuners.suffix(3)) == sizes,
              "Settings has the three size tuners, last among its fields")
        check(zip(controller.tuners, controller.tuners.dropFirst()).allSatisfy { $0.keyView.nextKeyView === $1.keyView }, "Tab goes field to field, the sizes included")
        let content = window.contentView!
        check(abs(content.frame.width - ClipboardRevealSettingsController.contentWidth) < 0.5 && content.bounds.width == content.frame.width, "at 100% Settings is its usual width, unzoomed")
        sizes[0].submit(150)
        spin()
        check(settings.sizes.text == 150 && abs(content.frame.width - ClipboardRevealSettingsController.contentWidth * 1.5) < 1
              && abs(content.bounds.width - ClipboardRevealSettingsController.contentWidth) < 0.5 && controller.appliedTextScale == 1.5,
              "at 150% Settings is half again as wide and lays out exactly as before (\(content.frame.width) × \(content.bounds.width))")
        let heightAt150 = window.frame.height
        sizes[0].undo()
        spin()
        check(settings.sizes.text == 100 && abs(content.frame.width - ClipboardRevealSettingsController.contentWidth) < 0.5 && window.frame.height < heightAt150,
              "undo zooms it back")
        sizes[1].submit(200); sizes[2].submit(120)
        check(settings.sizes.thumbnails == 200 && settings.sizes.preview == 120, "the other two save as they change")
        controller.tuners.forEach { $0.submit($0.spec.defaultValue) }
        check(settings.sizes == .standard, "Reset puts every size back to 100%")
        window.orderOut(nil)
    }

    private static func drawerChecks() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let store = ClipboardStore(pasteboard: board, persistenceURL: nil)
        board.clearContents(); board.setString("Harbor notes", forType: .string); store.saveNow(); store.cancelStaging()
        let panel = ClipboardWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        let drawer = ClipboardDrawerController(store: store, panel: panel, defaults: nil, animationsEnabled: { false })
        defer { drawer.stop() }
        var sizes = ClipboardSizes.standard
        drawer.sizes = { sizes }
        drawer.show(on: NSScreen.main!, animated: false)
        let glass = panel.contentView as! ClipboardGlassView
        let width = drawer.dockLayout!.bodyFrame.width
        check(glass.bodyContent.bounds.size == glass.bodyContent.frame.size, "at 100% the drawer's content is unzoomed")
        sizes.text = 150
        drawer.applySizes()
        let content = glass.bodyContent
        check(abs(content.bounds.width * 1.5 - content.frame.width) < 0.5 && abs(content.bounds.height * 1.5 - content.frame.height) < 0.5,
              "at 150% the drawer's content draws half again as large")
        check(drawer.dockLayout!.bodyFrame.width == max(width, ClipboardTabGeometry.contentMinimumWidth * 1.5),
              "the drawer keeps its width, growing only to what its zoomed content needs (\(drawer.dockLayout!.bodyFrame.width))")
        check(abs((content.layer?.cornerRadius ?? 0) * 1.5 - 26) < 0.01, "its rounded corner still matches the glass's 26 points")
        spin()
        let header = drawer.header.frame, list = drawer.browser.frame
        check(abs(header.maxY - content.bounds.maxY) < 0.5 && abs(list.maxY - header.minY) < 0.5 && list.minY == content.bounds.minY
              && header.width == content.bounds.width && list.width == content.bounds.width,
              "zoomed, the header still runs across the top and the list fills the rest (\(header), \(list) in \(content.bounds)); Auto Layout would have placed them by the frame")
        let browser = drawer.browser
        browser.layoutSubtreeIfNeeded()
        check(browser.tabs.fittingSize.width <= browser.tabs.frame.width && browser.tabs.frame.maxX <= browser.bounds.width - 16, "the tabs still fit whole in the zoomed drawer")
        sizes.text = 100; sizes.thumbnails = 200
        drawer.applySizes()
        browser.layoutSubtreeIfNeeded()
        let tile = browser.canvas.tiles[0]
        check(tile.thumbnailScale == 2 && tile.frame.height == ClipboardTile.rowHeight(.row, scale: 2) && ClipboardTile.rowHeight(.row, scale: 2) == 120,
              "at 200% a row's thumbnail is 92 points and the row grows to 120 (\(tile.frame.height))")
        check(ClipboardTile.rowHeight(.row, scale: 1) == 88 && ClipboardTile.rowHeight(.compact, scale: 1) == 44 && ClipboardTile.rowHeight(.row, scale: 0.5) == 88,
              "at 100% and below, rows keep their usual heights")
        sizes.preview = 150
        check(drawer.previewAnchor?.previewScale == 1.5, "Quick Look beside the drawer takes the preview size")
    }

    private static func windowChecks() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let store = ClipboardStore(pasteboard: board, persistenceURL: nil)
        board.clearContents(); board.setString("Harbor notes", forType: .string); store.saveNow(); store.cancelStaging()
        let screen = NSRect(x: 0, y: 0, width: 2_000, height: 1_200)
        check(ClipboardHistoryController.frame(in: screen, scale: 1.5).size == NSSize(width: 1_200, height: 705), "at 150% the window opens half again as large")
        check(ClipboardHistoryController.frame(in: NSRect(x: 0, y: 0, width: 1_000, height: 700), scale: 1.5).width <= 984, "never larger than the display")
        let panel = ClipboardWindow(contentRect: NSRect(origin: .zero, size: ClipboardHistoryController.preferredSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        let history = ClipboardHistoryController(store: store, paster: ClipboardPaster(store: store, environment: .inert), previewService: ClipboardPreviewService(), panel: panel)
        var sizes = ClipboardSizes(text: 125, thumbnails: 150, preview: 100)
        history.sizes = { sizes }
        history.prepare = { nil }
        history.hotKeyPressed()
        spin()
        let view = history.view
        check(abs(view.bounds.width - view.frame.width / 1.25) < 0.5 && abs(view.bounds.width - min(800, view.frame.width / 1.25)) < 0.5,
              "the window's content zooms by the text size, laid out at its usual 800 points where the display allows")
        let row = view.list.canvas.tiles[0]
        check(row.thumbnailScale == 1.5 && row.frame.height == ClipboardTile.rowHeight(.compact, scale: 1.5), "its rows take the thumbnail size")
        sizes.text = 100
        history.applySizes()
        check(view.bounds.size == view.frame.size, "a change while it shows zooms it back")
        history.close()
    }

    /// What opens beside the drawer or at the pointer: Send to, the ask, the selection's actions and
    /// card info lay out as at 100% and draw at the Text size; Quick Look's words and raw data grow,
    /// its preview keeps its size; the held magnet's words grow, its picture keeps its size.
    private static func besideChecks() {
        let content = NSView()
        let host = ClipboardZoomHost(content)
        host.scale = 1.5
        check(host.scaled(NSSize(width: 280, height: 100)) == NSSize(width: 420, height: 150), "a panel's wanted size grows by the Text size")
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 150)
        host.layoutSubtreeIfNeeded()
        check(content.frame.size == NSSize(width: 280, height: 100) && host.bounds.size == content.frame.size,
              "its content lays out at 280 × 100, drawn half again as large (\(content.frame))")
        let side = ClipboardDrawerSidePanel(title: "Fixture", content: ClipboardSurfaceView(), keyboard: .leaves,
                                            panel: ClipboardWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true))
        side.textScale = { 2 }
        check(side.scaled(NSSize(width: 260, height: 120)) == NSSize(width: 520, height: 240), "Send to, the ask and the selection's actions take it as they show")

        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let store = ClipboardStore(pasteboard: board, persistenceURL: nil)
        board.clearContents(); board.setString("Harbor notes", forType: .string); store.saveNow(); store.cancelStaging()
        let entry = store.entries[0]
        let carousel = ClipboardCarouselView(entry: entry, urls: [], position: 0, count: 3)
        carousel.allowsFlip = true
        carousel.frame = NSRect(x: 0, y: 0, width: 640, height: 520)
        carousel.layoutSubtreeIfNeeded()
        let previewAt100 = carousel.flip.frame.height, buttonAt100 = carousel.flipButton.frame.height
        carousel.textScale = 1.5
        carousel.layoutSubtreeIfNeeded()
        check(carousel.flipButton.font?.pointSize == 16.5 && carousel.flipButton.frame.height == buttonAt100 * 1.5 && carousel.flip.frame.height < previewAt100,
              "at 150% Quick Look's turn button and caption grow; the preview gives up the room (\(carousel.flip.frame.height) of \(previewAt100))")
        check(abs(carousel.raw.frame.width * 1.5 - carousel.flip.frame.width) < 0.5, "and its raw data draws half again as large (\(carousel.raw.frame.width))")
        carousel.textScale = 1
        carousel.layoutSubtreeIfNeeded()
        check(carousel.flip.frame.height == previewAt100 && carousel.raw.frame.size == carousel.flip.frame.size, "at 100% it is as it was")

        let held = ClipboardAttachmentView.makeHeldPreview(for: entry, maximumAttachmentPixels: 700, holdingGlyphHeight: 24)
        let large = ClipboardAttachmentView.makeHeldPreview(for: entry, maximumAttachmentPixels: 700, holdingGlyphHeight: 24, textScale: 1.5)
        check(large.size.width >= held.size.width && large.size.height > held.size.height, "the held magnet's words grow too (\(held.size) → \(large.size))")
    }

    private static func previewChecks() {
        let screen = NSRect(x: 0, y: 0, width: 2_400, height: 1_400)
        var anchor = ClipboardDrawerPreviewAnchor(drawer: NSRect(x: 2_000, y: 0, width: 400, height: 1_400), screen: screen, edge: .right)
        check(anchor.frame.size == ClipboardDrawerPreviewAnchor.preferredSize, "at 100% Quick Look beside the drawer is 640 × 520")
        anchor.previewScale = 1.5
        check(anchor.frame.size == NSSize(width: 960, height: 780), "at 150% it is 960 × 780 where there is room")
        let tight = ClipboardDrawerPreviewAnchor(drawer: NSRect(x: 400, y: 0, width: 400, height: 900), screen: NSRect(x: 0, y: 0, width: 800, height: 900), edge: .right)
        var big = tight; big.previewScale = 2
        check(big.frame.width <= 400 - 8 - 8 && big.frame.height <= 900 - 16, "and never more than the space beside the drawer")
        check(ClipboardMagnetController.pointerPreviewSize == NSSize(width: 420, height: 340), "at the pointer it starts from 420 × 340")
    }
}
