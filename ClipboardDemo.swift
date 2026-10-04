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
        let recall = ClipboardRecallMemory(minutes: { settings.recallMinutes })
        let controller = ClipboardDrawerController(store: store,
            magnetController: ClipboardMagnetController(commandClickEnabled: usesSystemBoard), defaults: nil,
            paster: ClipboardPaster(store: store, environment: usesSystemBoard ? .init() : .inert),
            recall: recall, activate: { app.activate(ignoringOtherApps: true) })
        let history = ClipboardHistoryController(store: store, paster: controller.paster,
                                                 previewService: controller.previewService, recall: recall)
        history.prepare = { controller.hide(animated: false); return ClipboardPaster.frontmostTarget() }
        let settingsController = ClipboardRevealSettingsController(settings: settings)
        let edge = EdgeController(drawerController: controller, settings: settings)
        controller.onRevealSettings = { settingsController.show() }
        controller.revealSettingsWindow = settingsController.window
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
        let reportURL = CommandLine.arguments.firstIndex(of: "--demo-report").flatMap { CommandLine.arguments.indices.contains($0 + 1) ? URL(fileURLWithPath: CommandLine.arguments[$0 + 1]) : nil }
        let reporting = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            guard let reportURL else { return }
            let preview = controller.magnetController
            if CommandLine.arguments.contains("--inspect-preview"), preview.isVisible {
                app.windows.first { $0.title == "ClipEdge Cursor Magnet" }?.makeKeyAndOrderFront(nil)
            }
            let report: [String: Any] = ["shortcutStatus": hotKeyStatus, "historyShortcutStatus": historyStatus, "plainShortcutStatus": plainStatus, "historyVisible": history.isVisible, "historyKey": history.holdsKeyboard, "historyIndex": store.entries.firstIndex { $0.id == history.selectedEntry?.id } ?? -1, "historyShown": history.visibleEntries.count, "historySelected": history.selectedEntry?.title ?? "none", "historyTab": history.view.currentTab.title, "historyQuery": history.view.search.stringValue, "historyConfirmingAll": history.isConfirmingDeleteAll, "historySending": history.isSending, "historyArmed": history.view.canvas.armedID != nil, "sendTo": history.view.sendTo.selected?.name ?? "none", "frontmost": NSWorkspace.shared.frontmostApplication?.localizedName ?? "none", "order": store.entries.map(\.title), "attached": store.entries.first { $0.id == store.stagedEntryID }?.title ?? "none", "preview": String(describing: preview.presentation), "carouselIndex": store.carouselPosition?.index ?? -1, "carouselCount": store.carouselPosition?.count ?? 0, "previewFrame": NSStringFromRect(preview.frame), "windows": app.windows.filter(\.isVisible).map { ["title": $0.title, "id": $0.windowNumber, "frame": NSStringFromRect($0.frame)] }]
            var diagnostics = report
            diagnostics["delivery"] = preview.pasteDiagnostics
            diagnostics["accessibility"] = AXIsProcessTrusted()
            diagnostics["inputMonitoring"] = CGPreflightListenEventAccess()
            if let data = try? JSONSerialization.data(withJSONObject: diagnostics, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: reportURL, options: .atomic) }
        }
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
        withExtendedLifetime((store, controller, hotKey, historyHotKey, plainHotKey, history, reporting, settingsController, delegate, termination)) { app.run() }
        edge.stop(); controller.stop()
        store.stop()
        lease?.restore()
        if !usesSystemBoard { board.releaseGlobally() }
    }
}
