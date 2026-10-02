import AppKit
import PDFKit

@main enum CoreTests {
    static var assertions = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError("FAIL: \(message)") }
    }
    static func main() throws {
        _ = NSApplication.shared
        let board = NSPasteboard.withUniqueName()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClipEdge-tests-" + UUID().uuidString)
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
        let history = root.appendingPathComponent("History.plist")
        let store = ClipboardStore(pasteboard: board, persistenceURL: history)
        store.start()
        var changes: [String] = []
        store.onStagingChange = { change in
            switch change { case .pickedUp: changes.append("pickup"); case .cancelled: changes.append("cancel"); case .pasted: changes.append("paste"); case .invalidated: changes.append("invalid") }
        }
        func copy(_ text: String) {
            board.clearContents(); board.setString(text, forType: .string); store.saveNow()
        }
        for text in ["D", "C", "B", "A"] { copy(text) }
        check(store.entries.map(\.title) == ["A", "B", "C", "D"], "copy order")
        check(store.stagedEntryID == store.entries.first?.id, "external copy attaches")
        check(changes.filter { $0 == "pickup" }.count == 4, "every copy attaches")
        store.cancelStaging()
        check(store.stagedEntryID == nil && board.string(forType: .string) == "A", "Esc detaches without restoring")
        let a = store.quickLookNext()!
        check(a.title == "A", "cycle starts at top")
        check(store.quickLookNext()?.title == "B", "second cycle is B")
        check(store.quickLookNext()?.title == "C", "third cycle is C")
        check(board.string(forType: .string) == "C", "cycle prepares real pasteboard")
        check(store.entries.map(\.title) == ["A", "B", "C", "D"], "cycling preserves order before paste")
        store.commitStagedPaste()
        check(store.entries.map(\.title) == ["C", "A", "B", "D"], "paste promotes only C")
        check(store.stagedEntryID == nil, "paste drops attachment")
        check(store.quickLookNext()?.title == "C", "paste resets cycling")
        store.resetCycle()
        store.selectForPaste(a)
        check(store.entries.first?.title == "C" && board.string(forType: .string) == "A", "pickup writes without reordering")
        check(store.liftedEntryID == a.id, "pickup reserves the original slot")
        store.selectForPaste(a)
        check(store.stagedEntryID == nil && store.liftedEntryID == nil, "same slot cancels pickup")
        check(board.string(forType: .string) == "C" && store.entries.first?.title == "C", "cancel restores previous clipboard without reordering")
        _ = store.quickLookNext()
        copy("NEW")
        check(store.quickLookNext()?.title == "NEW", "external copy resets cycling")
        let originalStamp = store.entries[0].capturedAt
        copy("NEW")
        check(store.entries.filter { $0.title == "NEW" }.count == 1 && store.entries[0].capturedAt >= originalStamp, "recopy dedup and timestamp")
        let secret = store.entries[0]
        check(store.remove(secret), "delete persists")
        check(board.string(forType: .string) == nil && store.stagedEntryID == nil, "delete clears active clipboard and cursor")
        check(!store.entries.contains { $0.id == secret.id }, "delete removes row")
        store.stop()
        let reloaded = ClipboardStore(pasteboard: board, persistenceURL: history)
        reloaded.start()
        check(!reloaded.entries.contains { $0.title == "NEW" }, "deletion survives reload")
        check(reloaded.entries.map(\.title) == ["C", "A", "B", "D"], "history persisted in order")
        reloaded.stop()
        store.start()
        copy("race candidate")
        let race = store.entries[0]
        board.clearContents(); board.setString("external wins", forType: .string)
        _ = store.remove(race)
        check(board.string(forType: .string) == "external wins", "deletion cannot erase newer unpolled copy")
        let concealed = NSPasteboardItem(); concealed.setString("secret excluded", forType: .string)
        concealed.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        board.clearContents(); board.writeObjects([concealed]); store.saveNow()
        check(!store.entries.contains { $0.title == "secret excluded" }, "concealed clipboard excluded")
        check(store.stagedEntryID == nil, "concealed copy invalidates cursor")
        let browser = ClipboardBrowserView(frame: NSRect(x: 0, y: 0, width: 390, height: 700))
        ClipboardDemo.seed(store, board: board)
        browser.update(entries: store.entries, attachedID: nil)
        check(browser.visibleEntries.count == store.entries.count, "All includes every retained item")
        browser.tabs.selectedSegment = 1
        browser.update(entries: store.entries, attachedID: nil)
        check(browser.visibleEntries.count == 3, "Images filters text out")
        for value in [1.0, 2.0, 3.0] {
            browser.zoom.doubleValue = value; browser.needsLayout = true; browser.layoutSubtreeIfNeeded()
            check(browser.columns == 4 - Int(value), "zoom column stops")
            check(browser.canvas.tiles.allSatisfy { abs($0.frame.width - $0.frame.height) < 0.1 }, "square grid")
            check(browser.canvas.tiles.allSatisfy { $0.frame.minX >= 0 && $0.frame.maxX <= browser.canvas.bounds.width }, "no grid overflow")
        }
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline && store.entries.filter(\.isImage).contains(where: { $0.recognizedText.isEmpty }) { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        check(store.entries.filter(\.isImage).allSatisfy { !$0.recognizedText.isEmpty }, "all fixture images indexed")
        browser.search.stringValue = "FOREST 314"
        browser.update(entries: store.entries, attachedID: nil)
        check(browser.visibleEntries.count == 1, "on-device OCR is searchable in Images")
        browser.tabs.selectedSegment = 0; browser.update(entries: store.entries, attachedID: nil)
        check(browser.visibleEntries.count == 1, "OCR is searchable in All")
        browser.search.stringValue = "Full text"; browser.update(entries: store.entries, attachedID: nil)
        check(browser.visibleEntries.count == 1, "search includes full text beyond title")
        let materializer = ClipboardMaterializer(root: root.appendingPathComponent("Previews"))
        let text = ClipboardEntry(fingerprint: "long", capturedAt: Date(), payloads: [ClipboardPayload(values: [(.string, Data(String(repeating: "All text must reach Preview.\n", count: 300).utf8))])], title: "Long text", detail: "", kind: .text, thumbnail: nil)
        let pdf = try materializer.urls(for: text, forPreviewApp: true)[0]
        let document = PDFDocument(url: pdf)!
        check(document.pageCount > 1, "Preview text conversion paginates full payload")
        check(document.string!.components(separatedBy: "All text must reach Preview.").count > 290, "Preview PDF retains text")
        try materializer.remove(text)
        check(!FileManager.default.fileExists(atPath: pdf.path), "sensitive derived previews deleted")
        check(PasteMonitor.keyAction(keyCode: 9, flags: .maskCommand) == .paste, "Command V recognized")
        check(PasteMonitor.keyAction(keyCode: 53, flags: []) == .cancel, "Esc recognized")
        check(PasteMonitor.keyAction(keyCode: 49, flags: [.maskControl, .maskAlternate]) == nil, "Quick Look chord is not paste")
        let monitor = PasteMonitor(environment: .init(accessibilityTrusted: { true }, listenAccess: { true }, externalApplication: { false }, keyAction: { nil }, pointerLocation: { NSPoint(x: 50, y: 50) }, uptime: { 0 }, beginObservation: { _ in }, refreshObservation: { _ in }))
        let magnet = ClipboardMagnetController(pasteMonitor: monitor, commandClickEnabled: false)
        let controller = ClipboardDrawerController(store: store, magnetController: magnet, defaults: nil)
        controller.quickLookNext()
        check(magnet.presentation == .carousel, "shortcut presents one medium magnet")
        check(NSApplication.shared.windows.filter { $0.isVisible && $0.title == "ClipEdge Cursor Magnet" }.count == 1, "one visible cursor magnet")
        check(!NSApplication.shared.windows.contains { $0.isVisible && $0.title == "ClipEdge Quick Look" }, "no drawer Quick Look window")
        check(store.carouselPosition?.index == 0, "carousel starts at first")
        magnet.onNavigate?(1)
        check(store.carouselPosition?.index == 1, "right arrow advances history")
        magnet.onNavigate?(-1)
        check(store.carouselPosition?.index == 0, "left arrow returns")
        magnet.onNavigate?(-1)
        check(store.carouselPosition?.index == store.entries.count - 1, "carousel wraps backward")
        let chosen = store.stagedEntryID
        let paste = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9)!
        monitor.receive(paste)
        monitor.receive(paste)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        check(store.stagedEntryID == nil, "paste dismisses despite stale CE frontmost ownership")
        check(store.entries.first?.id == chosen, "carousel paste promotes the selected entry")
        check(!magnet.isVisible, "paste animation ends with no cursor window")
        store.selectForPaste(store.entries[0])
        check(magnet.presentation == .small, "drawer selection uses small magnet")
        monitor.receive(paste)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        check(store.stagedEntryID == nil && !magnet.isVisible, "small magnet also disappears after paste")
        store.selectForPaste(store.entries[0])
        monitor.receive(paste)
        copy("New copy during paste delay")
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        check(store.stagedEntryID == store.entries[0].id && magnet.isVisible, "old paste cannot drop a newer copy")
        monitor.receive(paste)
        board.clearContents(); board.setString("Unpolled copy during paste delay", forType: .string)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        check(store.stagedEntryID == store.entries[0].id && magnet.isVisible, "paste commit cannot consume an unpolled newer copy")
        store.selectForPaste(store.entries[0])
        magnet.onCancel?()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        check(store.stagedEntryID == nil && !magnet.isVisible, "Esc drops magnet")
        board.clearContents(); board.setString("Poll refresh fixture", forType: .string)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        check(controller.browser.visibleEntries.first?.title == "Poll refresh fixture", "external clipboard polling refreshes the browser without manual save")
        check(store.stagedEntryID == store.entries.first?.id, "external polling attaches the newly copied payload")
        controller.stop()
        verifyPasteRoutes()
        verifyCommandClick()
        store.clear(); store.stop()
        print("PASS: \(assertions) assertions (clipboard, persistence, OCR, grid, PDF, carousel, dismissal and click-paste)")
    }
    static func verifyCommandClick() {
        var queued: [() -> Void] = []
        var events: [String] = []
        var focused: pid_t? = 99
        var pastedPoints: [NSPoint] = []
        let click = CommandClickPaste(environment: .init(receiverAt: { _ in (12345, 42) }, inspectTarget: { _, _, done in done(.ready) }, frontmost: { focused }, postPaste: { _ in events.append("paste"); return true }, schedule: { _, action in queued.append(action) }, keepsCommand: { _, _ in false }))
        click.onPaste = { pastedPoints.append($0) }
        click.start(observeSystemEvents: false)
        let point = CGPoint(x: 100, y: 200)
        check(!click.receive(type: .leftMouseDown, flags: .maskShift, point: point), "shift click retains attachment")
        check(!click.receive(type: .leftMouseDown, flags: [], point: point), "ordinary click retains attachment")
        check(!click.receive(type: .leftMouseUp, flags: [], point: point) && queued.isEmpty, "ordinary click never schedules paste")
        check(click.receive(type: .leftMouseDown, flags: .maskCommand, point: point), "Command mouse-down starts a destination click")
        check(events.isEmpty, "no paste before the user's click")
        check(click.receive(type: .leftMouseUp, flags: .maskCommand, point: point), "matching mouse-up schedules paste")
        check(events.isEmpty, "real mouse-up finishes before target inspection")
        queued.removeFirst()()
        check(events.isEmpty, "native click owns activation; CE does not force focus")
        queued.removeFirst()()
        check(events.isEmpty, "do not paste into the old foreground app")
        focused = 12345
        queued.removeFirst()()
        check(events == ["paste"] && pastedPoints.count == 1, "one paste after target owns focus")
        click.start(observeSystemEvents: false)
        _ = click.receive(type: .leftMouseDown, flags: .maskCommand, point: point)
        _ = click.receive(type: .leftMouseUp, flags: .maskCommand, point: point)
        click.stop()
        queued.removeFirst()()
        check(events.count == 1, "dropping or replacing attachment cancels delayed paste")
        click.start(observeSystemEvents: false)
        _ = click.receive(type: .leftMouseDown, flags: .maskCommand, point: point)
        _ = click.receive(type: .leftMouseUp, flags: .maskCommand, point: CGPoint(x: 150, y: 200))
        check(queued.isEmpty, "drag does not paste")
        var failures = 0
        click.onFailure = { failures += 1 }
        focused = 99
        _ = click.receive(type: .leftMouseDown, flags: .maskCommand, point: point)
        _ = click.receive(type: .leftMouseUp, flags: .maskCommand, point: point)
        while !queued.isEmpty { queued.removeFirst()() }
        check(failures == 0 && events.filter { $0 == "paste" }.count == 1, "unresolved focus drops quietly without pasting into a different app")
        click.start(observeSystemEvents: false)
        _ = click.receive(type: .leftMouseDown, flags: .maskCommand, point: point)
        _ = click.receive(type: .leftMouseUp, flags: .maskCommand, point: point)
        _ = click.receive(type: .leftMouseDown, flags: [], point: point)
        while !queued.isEmpty { queued.removeFirst()() }
        check(events.filter { $0 == "paste" }.count == 1, "another click cancels pending paste")
        click.stop()
    }

    static func verifyPasteRoutes() {
        var polled: PasteMonitor.KeyAction?
        var delivered = 0
        let monitor = PasteMonitor(environment: .init(accessibilityTrusted: { false }, listenAccess: { false }, externalApplication: { false }, keyAction: { polled }, pointerLocation: { .zero }, uptime: { 0 }, beginObservation: { _ in }, refreshObservation: { _ in }))
        monitor.onPaste = { _ in delivered += 1 }
        monitor.start()
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true)!
        event.flags = .maskCommand
        monitor.receive(event)
        check(delivered == 1, "Quartz keyboard route dismisses despite CE ownership")
        monitor.receive(event)
        check(delivered == 1, "duplicate delivery is coalesced")
        monitor.start()
        polled = .paste; monitor.sample()
        check(delivered == 2, "fallback polling dismisses despite CE ownership")
        monitor.stop(); polled = nil; monitor.sample()
        check(delivered == 2, "inactive listener never commits")
    }

}
