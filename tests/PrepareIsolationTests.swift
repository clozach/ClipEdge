import AppKit

@main enum PrepareIsolationTests {
    private static var assertions = 0
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError("FAIL: \(message)") }
    }

    static func main() {
        _ = NSApplication.shared
        let marker = "CLIPEDGE_TEST_PREVIEW_ROOT"
        let previous = ProcessInfo.processInfo.environment[marker]
        setenv(marker, "/tmp/ClipEdge-isolated-runtime-\(UUID().uuidString)", 1)
        defer {
            if let previous { setenv(marker, previous, 1) } else { unsetenv(marker) }
        }
        let panel = ClipboardWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 180),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.title = "ClipEdge isolated release fixture"
        panel.makeKeyAndOrderFront(nil)
        check(panel.isVisible && panel.isKeyWindow, "fixture exposes window/key state without ordering a native window")
        ClipboardWindow.orderOutReturningKeyboard(panel)
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        check(!panel.isVisible && !panel.isKeyWindow, "fixture closes and releases its simulated keyboard")
        panel.order(.above, relativeTo: 0)
        check(panel.isVisible, "relative ordering stays testable")
        panel.order(.out, relativeTo: 0)
        check(!panel.isVisible, "relative order-out closes the fixture")

        var cursorChanges = 0, arrowRegistrations = 0, clickStarts = 0
        let effects = ClipboardMagnetController.SystemEffects(
            setCursor: { _ in cursorChanges += 1 },
            registerArrow: { _ in arrowRegistrations += 1 },
            startCommandClick: { _ in clickStarts += 1 })
        let entry = ClipboardEntry(fingerprint: "fixture", capturedAt: Date(),
            payloads: [ClipboardPayload(values: [(.string, Data("Fixture only".utf8))])],
            title: "Fixture only", detail: "", kind: .text, thumbnail: nil)
        let isolated = ClipboardMagnetController(panel: panel, systemEffects: effects)
        isolated.show(entry: entry, from: nil)
        check(isolated.presentation == .small && isolated.isVisible, "isolated small preview keeps presentation behavior")
        isolated.showCarousel(entry: entry, urls: [], position: 0, count: 1)
        check(isolated.presentation == .carousel && isolated.isVisible, "isolated carousel keeps presentation behavior")
        check(cursorChanges == 0 && arrowRegistrations == 0 && clickStarts == 0,
            "isolated previews never invoke cursor, global-arrow or command-click effects")
        check(isolated.pasteDiagnostics["sessionTapCreated"] as? Bool == false &&
              isolated.pasteDiagnostics["processTapCreated"] as? Bool == false &&
              isolated.pasteDiagnostics["processPID"] as? Int == -1,
            "default isolated paste monitor never attaches to the session or foreground app")
        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
        check(windows != nil && !windows!.contains {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ProcessInfo.processInfo.processIdentifier
        }, "WindowServer has no visible fixture window while simulated visibility is true")
        isolated.consume(at: NSPoint(x: 200, y: 200))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        check(!isolated.isVisible && cursorChanges == 0, "isolated paste animation closes without changing the pointer")

        // Exercise normal dispatch with spies and the already isolated panel;
        // this proves the environment gate, without touching native input.
        unsetenv(marker)
        let monitor = PasteMonitor(environment: .init(accessibilityTrusted: { false }, listenAccess: { false },
            externalApplication: { false }, keyAction: { nil }, pointerLocation: { .zero },
            beginObservation: { _ in }, refreshObservation: { _ in }))
        let normal = ClipboardMagnetController(pasteMonitor: monitor, panel: panel, systemEffects: effects)
        normal.show(entry: entry, from: nil)
        check(cursorChanges == 1 && clickStarts == 1 && arrowRegistrations == 0,
            "normal small preview retains its cursor and command-click effects")
        normal.showCarousel(entry: entry, urls: [], position: 0, count: 1)
        check(cursorChanges == 2 && clickStarts == 2 && arrowRegistrations == 2,
            "normal carousel retains bare-arrow registration and command-click effects")
        normal.hide()
        check(cursorChanges == 3, "normal hide restores the arrow cursor")
        print("Prepare isolation tests passed (\(assertions) assertions)")
    }
}
