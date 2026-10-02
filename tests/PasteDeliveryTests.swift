import AppKit
import ApplicationServices

/// Pure policy checks. No event is posted, no tap is installed, and no clipboard
/// is read. Real OS delivery is verified separately with the installed app.
@main enum PasteDeliveryTests {
    static func main() {
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            assertions += 1
        }
        let monitor = PasteMonitor(environment: .init(
            accessibilityTrusted: { false }, listenAccess: { false }, externalApplication: { false },
            keyAction: { nil }, pointerLocation: { .zero }, uptime: { 50 },
            beginObservation: { _ in }, refreshObservation: { _ in }))
        var pastes = 0
        var cancels = 0
        monitor.onPaste = { _ in pastes += 1 }
        monitor.onCancel = { cancels += 1 }
        monitor.start()
        let paste = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true)!
        paste.flags = .maskCommand
        monitor.receive(paste, source: .quartzProcess)
        monitor.receive(paste, source: .quartzSession)
        check(pastes == 1, "process/session observations must coalesce into one paste")
        check(monitor.diagnostics["pasteCallbacks"] as? Int == 1, "diagnostics report the delivered callback")
        let counts = monitor.diagnostics["deliveries"] as? [String: Int]
        check(counts?["quartzProcess"] == 1 && counts?["quartzSession"] == 1, "diagnostics distinguish event sources")
        check(monitor.diagnostics["lastCandidateKeyCode"] as? Int == 9, "diagnostics retain candidate shortcut code")
        check(monitor.diagnostics["processTapCreated"] as? Bool == false, "injected tests cannot report a real tap")
        monitor.stop()
        monitor.receive(paste, source: .appKitGlobal)
        check(pastes == 1, "stopped monitor ignores deliveries")
        monitor.start()
        check((monitor.diagnostics["deliveries"] as? [String: Int])?.isEmpty == true, "new pickup resets delivery evidence")
        let escape = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)!
        escape.flags = []
        monitor.receive(escape)
        check(cancels == 1 && pastes == 1, "Escape stays independent from paste")
        let ordinary = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
        monitor.receive(ordinary)
        check(monitor.diagnostics["lastCandidateKeyCode"] as? Int == 53, "ordinary key identity is not retained")
        check(monitor.diagnostics["pasteCallbacks"] as? Int == 0, "new pickup does not inherit old paste receipt")
        monitor.stop()

        check(PasteMonitor.MenuLifetime.open.permitsCachedCandidate(at: 500, trailingEvent: false), "an open menu's cache does not expire after 250ms")
        check(!PasteMonitor.MenuLifetime.absent.permitsCachedCandidate(at: 500, trailingEvent: true), "no menu means no persistent cache")
        check(PasteMonitor.MenuLifetime.closed(50).permitsCachedCandidate(at: 50.1, trailingEvent: true), "trailing mouse-up may use recently closed menu")
        check(!PasteMonitor.MenuLifetime.closed(50).permitsCachedCandidate(at: 50.1, trailingEvent: false), "new mouse-down cannot reuse closed menu")
        check(!PasteMonitor.MenuLifetime.closed(50).permitsCachedCandidate(at: 50.2, trailingEvent: true), "closed cache expires after grace interval")
        check(!PasteMonitor.MenuLifetime.closed(50).permitsCachedCandidate(at: 49.9, trailingEvent: true), "backwards timestamps cannot reactivate a closed menu")
        print("\(assertions) paste-delivery policy assertions passed; no OS event delivery claimed.")
    }
}
