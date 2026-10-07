import AppKit

/// Default fixtures use a named clipboard. --demo-system-clipboard opts into
/// a restoring integration lease; neither mode reads/writes the history archive.
enum ClipboardDemo {
    static func image(_ title: String, size: NSSize, color: NSColor) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        (title as NSString).draw(at: NSPoint(x: 20, y: size.height / 2), withAttributes: [.font: NSFont.systemFont(ofSize: 36, weight: .bold), .foregroundColor: NSColor.white])
        image.unlockFocus()
        return image
    }
    static func seed(_ store: ClipboardStore, board: NSPasteboard) {
        for (name, size, color) in [("FOREST 314", NSSize(width: 640, height: 360), NSColor.systemGreen), ("OCEAN 271", NSSize(width: 320, height: 480), NSColor.systemBlue), ("SUNSET 628", NSSize(width: 480, height: 480), NSColor.systemOrange)] {
            board.clearContents()
            board.writeObjects([image(name, size: size, color: color)])
            store.saveNow()
        }
        board.clearContents()
        board.setString("ClipEdge fixture — a note to carry into the next app.\nFull text stays available in Quick Look.", forType: .string)
        store.saveNow()
        for entry in store.entries { entry.capturedAt = Date(timeIntervalSince1970: 1790794800) }
        store.cancelStaging()
    }
    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .aqua)
        let usesSystemBoard = CommandLine.arguments.contains("--demo-system-clipboard")
        let lease = usesSystemBoard ? ClipboardFixtureLease() : nil
        let board = usesSystemBoard ? NSPasteboard.general : NSPasteboard.withUniqueName()
        let store = ClipboardStore(pasteboard: board)
        store.start()
        seed(store, board: board)
        lease?.register(store.entries)
        // The fixture board must never trigger a paste from the user's general board.
        let settings = ClipboardRevealSettings(defaults: nil)
        // A longer exit grace keeps the open drawer up while a check clicks just beside it (the setting allows up to 3 s).
        if let flag = CommandLine.arguments.firstIndex(of: "--demo-dismissal-delay"), CommandLine.arguments.indices.contains(flag + 1),
           let seconds = Double(CommandLine.arguments[flag + 1]) { settings.dismissalDelaySeconds = seconds }
        let recall = ClipboardRecallMemory(minutes: { settings.recallMinutes })
        let controller = ClipboardDrawerController(store: store,
            magnetController: ClipboardMagnetController(commandClickEnabled: usesSystemBoard), defaults: nil,
            paster: ClipboardPaster(store: store, environment: usesSystemBoard ? .init() : .inert),
            recall: recall, activate: { app.activate(ignoringOtherApps: true) })
        let history = ClipboardHistoryController(store: store, paster: controller.paster,
                                                 previewService: controller.previewService, recall: recall)
        history.prepare = { controller.hide(animated: false); return ClipboardPaster.frontmostTarget() }
        store.attachesCopiesToCursor = { settings.showsMagnet(for: .copy) }
        controller.pickupMagnet = { settings.showsMagnet(for: .drawer) }
        history.pickupMagnet = { settings.showsMagnet(for: .window) }
        let settingsController = ClipboardRevealSettingsController(settings: settings)
        // --demo-hold-drawer: an open drawer never hides on its own, so a check can see who takes the keyboard back.
        let holdsDrawer = CommandLine.arguments.contains("--demo-hold-drawer")
        let edge = EdgeController(drawerController: controller, settings: settings, pointerLocation: {
            if holdsDrawer, let body = controller.bodyFrame { return NSPoint(x: body.midX, y: body.midY) }
            return NSEvent.mouseLocation
        })
        controller.onRevealSettings = { settingsController.show() }
        controller.revealSettingsWindow = settingsController.window
        if let i = CommandLine.arguments.firstIndex(of: "--demo-appearance"), CommandLine.arguments.indices.contains(i + 1) {
            app.appearance = NSAppearance(named: CommandLine.arguments[i + 1] == "dark" ? .darkAqua : .aqua)
        }
        if CommandLine.arguments.contains("--demo-magnets-off") { settings.magnetsEnabled = false }
        if CommandLine.arguments.contains("--demo-show-settings") { settingsController.show() }
        let delegate = ClipboardDemoDelegate()
        app.delegate = delegate
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination.setEventHandler { delegate.stop() }; termination.resume()
        let hotKey = ClipboardHotKey()
        hotKey.onPress = { if !settingsController.isRecordingShortcut { controller.quickLookNext() } }
        settingsController.onShortcutChange = { hotKey.register(shortcut: $0) }
        let hints = NotificationCenter.default.addObserver(forName: ClipboardRevealSettings.didChange, object: settings, queue: .main) { _ in
            controller.browser.quickLookHint = settings.quickLookShortcut.displayString
            controller.magnetController.quickLookHint = settings.quickLookShortcut.displayString
            controller.releaseMagnet { settings.showsMagnet(for: $0) }
        }
        defer { NotificationCenter.default.removeObserver(hints) }
        let hotKeyStatus = hotKey.register(shortcut: settings.quickLookShortcut)
        let historyHotKey = ClipboardHotKey()
        historyHotKey.onPress = { history.hotKeyPressed() }
        let historyStatus = historyHotKey.register(shortcut: .history)
        let plainHotKey = ClipboardHotKey()
        plainHotKey.onPress = { history.close(); controller.paster.pasteClipboardAsPlainText(into: ClipboardPaster.frontmostTarget()) }
        let plainStatus = plainHotKey.register(shortcut: .plainPaste)
        if CommandLine.arguments.contains("--demo-history") { DispatchQueue.main.async { history.show() } }
        // The real first-launch update question, kept in a temporary folder (ClipboardDemoReport.swift).
        let question = CommandLine.arguments.contains("--demo-update-question") ? MainActor.assumeIsolated { DemoUpdateQuestion() } : nil
        let reportURL = CommandLine.arguments.firstIndex(of: "--demo-report").flatMap { CommandLine.arguments.indices.contains($0 + 1) ? URL(fileURLWithPath: CommandLine.arguments[$0 + 1]) : nil }
        var timeline: DemoKeyTimeline?
        let writeReport = {
            guard let reportURL else { return }
            let preview = controller.magnetController
            if CommandLine.arguments.contains("--inspect-preview"), preview.isVisible {
                app.windows.first { $0.title == "ClipEdge Cursor Magnet" }?.makeKeyAndOrderFront(nil)
            }
            let report: [String: Any] = ["shortcutStatus": hotKeyStatus, "historyShortcutStatus": historyStatus, "plainShortcutStatus": plainStatus, "historyVisible": history.isVisible, "historyKey": history.holdsKeyboard, "historyIndex": store.entries.firstIndex { $0.id == history.selectedEntry?.id } ?? -1, "historyShown": history.visibleEntries.count, "historySelected": history.selectedEntry?.title ?? "none", "historyTab": history.view.currentTab.title, "historyQuery": history.view.search.stringValue, "historyConfirmingAll": history.isConfirmingDeleteAll, "historySending": history.isSending, "historyArmed": history.view.canvas.armedID != nil, "sendTo": history.view.sendTo.selected?.name ?? "none", "frontmost": NSWorkspace.shared.frontmostApplication?.localizedName ?? "none", "order": store.entries.map(\.title), "attached": store.entries.first { $0.id == store.stagedEntryID }?.title ?? "none", "preview": String(describing: preview.presentation), "carouselIndex": store.carouselPosition?.index ?? -1, "carouselCount": store.carouselPosition?.count ?? 0, "previewFrame": NSStringFromRect(preview.frame)]
            var diagnostics = report
            diagnostics["delivery"] = preview.pasteDiagnostics
            diagnostics["keyWindow"] = app.keyWindow?.title ?? "none"
            diagnostics["active"] = app.isActive
            diagnostics["appAppearance"] = app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"
            diagnostics["drawerBody"] = controller.bodyFrame.map(NSStringFromRect) ?? "none"
            diagnostics["tileInfo"] = ClipboardTileTooltip.shared.frame.map(NSStringFromRect) ?? "none"
            diagnostics["chosenTile"] = controller.browser.canvas.selected.map { tile in
                tile.window.map { NSStringFromRect($0.convertToScreen(tile.convert(tile.bounds, to: nil))) } ?? "none" } ?? "none"
            diagnostics["accessibility"] = AXIsProcessTrusted()
            diagnostics["inputMonitoring"] = CGPreflightListenEventAccess()
            diagnostics.merge(ClipboardDemoReport.keyboard(app)) { $1 }
            diagnostics.merge(ClipboardDemoReport.drawer(controller, in: app)) { $1 }
            diagnostics["keyTimeline"] = timeline?.events ?? []
            if let question {
                diagnostics.merge(ClipboardDemoReport.consent(app)) { $1 }
                diagnostics["updateChoice"] = MainActor.assumeIsolated { question.choice }
                diagnostics["updateSupport"] = question.support.path
            }
            if let data = try? JSONSerialization.data(withJSONObject: diagnostics, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: reportURL, options: .atomic) }
        }
        let reporting = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in writeReport() }
        if reportURL != nil { timeline = DemoKeyTimeline { writeReport() } }
        let menu = NSMenu()
        let item = NSMenuItem()
        item.submenu = NSMenu()
        item.submenu?.addItem(settingsController.makeMenuItem(keyEquivalent: ","))
        let quit = NSMenuItem(title: "Quit Fixture", action: #selector(ClipboardDemoDelegate.stop), keyEquivalent: "q")
        quit.target = delegate
        item.submenu?.addItem(quit)
        menu.addItem(item)
        app.mainMenu = menu
        if CommandLine.arguments.contains("--demo-edge") { edge.start() }
        else { controller.show(on: NSScreen.main!) }
        // --demo-tile-info N: card N's info at once, as the 2-second hover would show it (for screenshots).
        if let flag = CommandLine.arguments.firstIndex(of: "--demo-tile-info"), CommandLine.arguments.indices.contains(flag + 1),
           let index = Int(CommandLine.arguments[flag + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let tiles = controller.browser.canvas.tiles
                guard tiles.indices.contains(index) else { return }
                tiles[index].onHover?()
                ClipboardTileTooltip.shared.show(for: tiles[index])
            }
        }
        // Asked after the drawer's tab appears, as AppDelegate does at launch.
        if let question { DispatchQueue.main.async { MainActor.assumeIsolated { question.ask() } } }
        withExtendedLifetime((store, controller, hotKey, historyHotKey, plainHotKey, history, reporting, settingsController, delegate, termination, question, timeline)) { app.run() }
        edge.stop(); controller.stop()
        question?.discard()
        store.stop()
        lease?.restore()
        if !usesSystemBoard { board.releaseGlobally() }
    }
}
