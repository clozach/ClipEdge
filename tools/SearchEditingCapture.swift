import AppKit

/// Native event dispatch to the two real search panels. Named history; no global key injection.
@main enum SearchEditingCapture {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .aqua)
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let board = NSPasteboard.withUniqueName()
        let store = ClipboardStore(pasteboard: board, persistenceURL: nil)
        ClipboardDemo.seed(store, board: board)
        let lease = ClipboardFixtureLease()
        let clipboardFixtures = ["trip", "a"].map { text in
            ClipboardEntry(fingerprint: text, capturedAt: Date(), payloads: [ClipboardPayload(values: [(.string, Data(text.utf8))])],
                           title: text, detail: "fixture", kind: .text, thumbnail: nil)
        }
        lease.register(clipboardFixtures)
        NSPasteboard.general.setString("trip", forType: .string)
        let magnet = ClipboardMagnetController(commandClickEnabled: false)
        let drawer = ClipboardDrawerController(store: store, magnetController: magnet, defaults: nil)
        let history = ClipboardHistoryController(store: store, paster: ClipboardPaster(store: store, environment: .inert), previewService: drawer.previewService)
        history.prepare = { drawer.hide(animated: false); return nil }
        defer { history.close(); drawer.stop(); store.stop(); board.releaseGlobally(); lease.restore() }
        var records: [[String: Any]] = []
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }
        func press(_ panel: NSWindow, code: UInt16, flags: NSEvent.ModifierFlags, characters: String) {
            app.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: panel.windowNumber, context: nil, characters: characters,
                                          charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!)
            settle()
        }
        func capture(_ panel: NSWindow, name: String) throws {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = ["-x", "-o", "-l\(panel.windowNumber)", root.appendingPathComponent(name + ".png").path]
            try task.run(); task.waitUntilExit()
            guard task.terminationStatus == 0 else { fatalError("window capture failed") }
            // The search lives in the drawer's header; exclude its unrelated
            // animated edge tab far below from this editing comparison.
            if name == "drawer" {
                let url = root.appendingPathComponent(name + ".png")
                let image = NSBitmapImageRep(data: try Data(contentsOf: url))!.cgImage!
                let crop = image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: min(340, image.height)))!
                try NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:])!.write(to: url)
            }
        }
        for surface in ["history", "drawer"] {
            if surface == "history" { history.show() } else { drawer.show(on: NSScreen.main!) }
            settle()
            let search = surface == "history" ? history.view.search : drawer.browser.search
            let panel = search.window!
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(search)
            let editor = search.currentEditor() as! NSTextView
            editor.string = "trip"
            editor.didChangeText()
            editor.setSelectedRange(NSRange(location: 4, length: 0))
            settle()
            press(panel, code: 0, flags: .command, characters: "a")
            let selection = editor.selectedRange()
            try capture(panel, name: surface)
            press(panel, code: 0, flags: [], characters: "a")
            let replacement = search.stringValue
            press(panel, code: 6, flags: .command, characters: "z")
            let undo = search.stringValue
            press(panel, code: 6, flags: [.command, .shift], characters: "z")
            let redo = search.stringValue
            editor.string = "trip"; editor.didChangeText(); editor.setSelectedRange(NSRange(location: 0, length: 4))
            press(panel, code: 7, flags: .command, characters: "x")
            let cut = search.stringValue
            let cutClipboard = NSPasteboard.general.string(forType: .string) ?? "none"
            editor.string = ""; editor.didChangeText()
            press(panel, code: 9, flags: .command, characters: "v")
            let paste = search.stringValue
            var copyOK = true
            if surface == "drawer" {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString("a", forType: .string)
                editor.setSelectedRange(NSRange(location: 0, length: 4))
                press(panel, code: 8, flags: .command, characters: "c")
                copyOK = NSPasteboard.general.string(forType: .string) == "trip"
            } else {
                editor.string = ""; editor.didChangeText()
                let selected = history.selectedEntry
                press(panel, code: 8, flags: .command, characters: "c")
                copyOK = !history.isVisible && selected != nil && store.stagedEntryID == selected?.id
                store.cancelStaging()
            }
            let passed = selection == NSRange(location: 0, length: 4) && replacement == "a" && undo == "trip" && redo == "a"
                && cut.isEmpty && cutClipboard == "trip" && paste == "trip" && copyOK
            records.append(["surface": surface, "selection": NSStringFromRange(selection), "replacement": replacement,
                            "undo": undo, "redo": redo, "cut": cut, "cutClipboard": cutClipboard, "paste": paste,
                            "copyOK": copyOK, "passed": passed,
                            "fixtureOnly": true, "dispatch": "NSApplication.sendEvent; real nonactivating panels; no menu"])
            if surface == "history" { history.close() } else { drawer.hide(animated: false) }
            settle()
        }
        try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("record.json"))
        print(String(data: try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
        if CommandLine.arguments.contains("--check"), records.contains(where: { $0["passed"] as? Bool != true }) {
            throw NSError(domain: "ClipEdgeSearchEditingCheck", code: 1)
        }
    }
}
