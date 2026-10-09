import AppKit

@MainActor
enum PublishReview {
    static func confirm(_ candidate: PublishCandidate, _ parent: NSWindow?) async -> Bool {
        let alert = alert(candidate: candidate)
        // A standalone modal survives the drawer/window closing when ClipEdge activates.
        NSApp.activate(ignoringOtherApps: true)
        let monitor = suppressSpace(in: alert.window)
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        return alert.runModal() == .alertSecondButtonReturn
    }

    static func alert(candidate: PublishCandidate) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Publish ClipEdge \(candidate.version) to everyone?"
        alert.informativeText = "This tested, frozen build replaces release \(candidate.previousVersion). Everyone with automatic updates on can receive it after their next check and idle time. This cannot confirm Mom's installed version.\n\nNo source changes made after preparation are included.\n\nChanges are shown below."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Publish \(candidate.version) ⌘Return")
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[0].keyEquivalentModifierMask = []
        alert.buttons[1].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalentModifierMask = .command
        alert.buttons[1].toolTip = "Candidate: \(candidate.id)\nContent: \(candidate.fingerprint)\nDownload SHA-256: \(candidate.archiveSHA256)\nReview receipt SHA-256: \(candidate.receiptSHA256)"
        alert.accessoryView = details(candidate.changes)
        return alert
    }

    static func failure(_ failure: PublishFailure) {
        let alert = NSAlert()
        alert.messageText = "The release needs attention"
        alert.informativeText = "Check the release status before trying again. The full details are below."
        alert.accessoryView = details(failure.localizedDescription)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if failure.log != nil { alert.addButton(withTitle: "Show Log in Finder") }
        NSApp.activate(ignoringOtherApps: true)
        let monitor = suppressSpace(in: alert.window)
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        if alert.runModal() == .alertSecondButtonReturn, let log = failure.log {
            NSWorkspace.shared.activateFileViewerSelecting([log])
        }
    }

    private static func details(_ text: String) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 430, height: 125))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let view = NSTextView(frame: scroll.bounds)
        view.isEditable = false
        view.isSelectable = true
        view.font = .systemFont(ofSize: 12)
        view.string = text
        view.textContainerInset = NSSize(width: 6, height: 6)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        scroll.documentView = view
        return scroll
    }

    private static func suppressSpace(in window: NSWindow) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            event.window === window && event.keyCode == 49 ? nil : event
        }
    }
}
