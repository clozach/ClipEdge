import AppKit
import ApplicationServices

enum PasteDetectionDiagnostic {
    static func run(reportURL: URL) {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let monitor = PasteMonitor()
        var finished = false

        func report(_ state: String) {
            let values: [String: Any] = [
                "state": state,
                "accessibility": AXIsProcessTrusted(),
                "inputMonitoring": CGPreflightListenEventAccess(),
                "delivery": monitor.diagnostics
            ]
            if let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) {
                try? data.write(to: reportURL, options: .atomic)
            }
        }

        func finish(_ state: String) {
            guard !finished else { return }
            finished = true
            report(state)
            monitor.stop()
            application.stop(nil)
            // Wake run() so it can return without waiting for another user event.
            if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                                             modifierFlags: [], timestamp: 0, windowNumber: 0,
                                             context: nil, subtype: 0, data1: 0, data2: 0) {
                application.postEvent(event, atStart: true)
            }
        }

        monitor.onPaste = { _ in finish("received") }
        monitor.onCancel = { finish("cancelled") }
        report("waiting")
        monitor.start()
        let timeout = Timer(timeInterval: 45, repeats: false) { _ in finish("timedOut") }
        RunLoop.main.add(timeout, forMode: .common)
        application.run()
        timeout.invalidate()
        monitor.stop()
    }
}
