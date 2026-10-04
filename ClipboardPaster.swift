import AppKit

/// Puts an entry on the clipboard, brings its destination forward when needed
/// and sends Paste. Shared by the history window, Send to and ⌃⌘V.
final class ClipboardPaster {
    struct Target {
        let pid: pid_t
        let activate: () -> Void
    }
    struct Environment {
        var frontmost: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        var postPaste: (pid_t) -> Bool = CommandClickPaste.postPaste
        var schedule: (TimeInterval, @escaping () -> Void) -> Void = { delay, action in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        }
        var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        var failed: () -> Void = { NSSound.beep() }
        /// Fixtures on a named clipboard must not paste the user's real one.
        static var inert: Environment { var value = Environment(); value.postPaste = { _ in false }; return value }
    }
    private let store: ClipboardStore
    private let environment: Environment
    private var generation = 0

    init(store: ClipboardStore, environment: Environment = Environment()) {
        self.store = store
        self.environment = environment
    }

    /// The app in front, unless that is ClipEdge itself.
    static func frontmostTarget() -> Target? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return target(for: app)
    }

    static func target(for app: NSRunningApplication) -> Target {
        Target(pid: app.processIdentifier) {
            // Opening a running app brings it forward even while ClipEdge is in the background.
            guard let url = app.bundleURL else { app.activate(options: []); return }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Without a destination the entry still becomes the clipboard's current item.
    func paste(_ entry: ClipboardEntry, into target: Target?, plain: Bool = false) {
        guard store.makeCurrent(entry), let target else { environment.failed(); return }
        if plain { pasteClipboardAsPlainText(into: target) } else { deliver(to: target) { _ in } }
    }

    /// One paste of the clipboard's text alone; the full item returns afterwards.
    func pasteClipboardAsPlainText(into target: Target?) {
        guard let target, let loan = store.beginPlainTextPaste() else { environment.failed(); return }
        deliver(to: target) { [store, environment] _ in
            // The destination reads the clipboard after it receives Command-V.
            environment.schedule(0.45) { store.endPlainTextPaste(loan) }
        }
    }

    private func deliver(to target: Target, completion: @escaping (Bool) -> Void) {
        generation += 1
        if environment.frontmost() != target.pid { target.activate() }
        attempt(target, generation: generation, deadline: environment.now() + 1.5, completion: completion)
    }

    private func attempt(_ target: Target, generation current: Int, deadline: TimeInterval,
                         completion: @escaping (Bool) -> Void) {
        // A newer paste replaces this one, but its clipboard loan still ends.
        guard current == generation else { completion(false); return }
        if environment.frontmost() == target.pid {
            // Let the destination's own window take the keyboard back first.
            environment.schedule(0.06) { [weak self] in
                guard let self else { return }
                let pasted = current == self.generation && self.environment.postPaste(target.pid)
                if !pasted { self.environment.failed() }
                completion(pasted)
            }
        } else if environment.now() < deadline {
            environment.schedule(0.04) { [weak self] in
                self?.attempt(target, generation: current, deadline: deadline, completion: completion)
            }
        } else {
            environment.failed()
            completion(false)
        }
    }
}
