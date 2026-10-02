import AppKit
import ApplicationServices

/// Observes a held item's next unmodified click without changing the real event.
/// Content clicks paste after focus settles; chrome clicks only drop the magnet.
final class CommandClickPaste {
    enum Destination: Equatable { case paste(pid_t), drop }
    struct Target: Equatable { let destination: Destination; let point: NSPoint; let window: Int? }
    struct Environment {
        var targetAt: (CGPoint) -> pid_t? = CommandClickPaste.targetApplication
        var windowAt: (CGPoint) -> Int? = { CommandClickPaste.targetWindow(at: $0)?.number }
        var inspectTarget: (CGPoint, pid_t, @escaping (ClickPasteTarget.Assessment) -> Void) -> Void = ClickPasteTarget.inspect
        var frontmost: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        var postPaste: (pid_t) -> Bool = CommandClickPaste.postPaste
        var schedule: (TimeInterval, @escaping () -> Void) -> Void = { delay, action in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action) }
        var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    }
    var onPaste: ((NSPoint) -> Void)?
    var onDrop: (() -> Void)?
    var onFailure: (() -> Void)?
    private let environment: Environment
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var mouseMonitor: Any?
    private var generation = 0
    private enum Gesture { case idle, pressed(Target), focusing }
    private var gesture: Gesture = .idle
    private(set) var active = false
    private(set) var lastDecision = "idle"
    init(environment: Environment = Environment()) { self.environment = environment }
    deinit { stop() }

    func start(observeSystemEvents: Bool = true) {
        stop(); active = true; lastDecision = "armed"
        guard observeSystemEvents else { return }
        let mask = [CGEventType.leftMouseDown, .leftMouseUp, .leftMouseDragged].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<CommandClickPaste>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if owner.active, let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            } else { owner.receive(type: type, flags: event.flags, point: event.location) }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        if let tap {
            source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        // Mouse observation does not require a keyboard/Input Monitoring grant.
        // Use AppKit only when Quartz could not create the tap (no duplicate downs).
        if tap == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged]) { [weak self] event in
                guard let cg = event.cgEvent else { return }
                self?.receive(type: cg.type, flags: cg.flags, point: cg.location)
            }
        }
    }
    func stop() {
        active = false; generation += 1; gesture = .idle
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil; tap = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }
    /// Returns whether this gesture was accepted; all physical events pass unchanged.
    @discardableResult
    func receive(type: CGEventType, flags: CGEventFlags, point: CGPoint) -> Bool {
        guard active else { return false }
        if type == .leftMouseDown {
            generation += 1 // A later click cancels a still-pending focus/paste.
            gesture = .idle
            guard flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty else { return false }
            let pid = environment.targetAt(point)
            guard pid != ProcessInfo.processInfo.processIdentifier else { return false }
            let window = environment.windowAt(point)
            // Do not ask AX whether mouse-down hit an editor. Web/custom editors
            // may create their input only after this very click is delivered.
            let destination: Destination = window == nil ? .drop : pid.map(Destination.paste) ?? .drop
            gesture = .pressed(Target(destination: destination, point: NSPoint(x: point.x, y: CGDisplayBounds(CGMainDisplayID()).height - point.y), window: window))
            return true
        }
        if type == .leftMouseDragged { gesture = .idle; generation += 1; return false }
        guard type == .leftMouseUp, case .pressed(let target) = gesture else { return false }
        gesture = .idle
        guard flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty else { return false }
        let release = NSPoint(x: point.x, y: CGDisplayBounds(CGMainDisplayID()).height - point.y)
        guard hypot(release.x - target.point.x, release.y - target.point.y) < 5 else { return true }
        guard case .paste = target.destination else { stop(); onDrop?(); return true }
        gesture = .focusing
        // Let the real click choose the app AND its input. Forcing activation
        // here could bring a stale destination back after the user switched.
        let current = generation
        let deadline = environment.now() + 0.85
        environment.schedule(0.06) { [weak self] in
            guard let self, self.active, self.generation == current else { return }
            self.deliver(target, generation: current, attempts: 10, deadline: deadline)
        }
        return true
    }
    private func deliver(_ target: Target, generation current: Int, attempts: Int, deadline: TimeInterval) {
        guard case .paste(let pid) = target.destination else { return }
        let point = CGPoint(x: target.point.x, y: CGDisplayBounds(CGMainDisplayID()).height - target.point.y)
        guard environment.now() < deadline, environment.targetAt(point) == pid, environment.windowAt(point) == target.window else {
            lastDecision = "cancelled-target-or-timeout"
            stop(); onDrop?(); return
        }
        environment.inspectTarget(point, pid) { [weak self] assessment in
            guard let self, self.active, self.generation == current else { return }
            self.lastDecision = String(describing: assessment)
            guard self.environment.now() < deadline, self.environment.targetAt(point) == pid,
                  self.environment.windowAt(point) == target.window else {
                self.lastDecision = "cancelled-target-or-timeout"
                self.stop(); self.onDrop?(); return
            }
            if assessment == .ready, self.environment.frontmost() == pid {
                if self.environment.postPaste(pid) { self.stop(); self.onPaste?(target.point) }
                else { self.stop(); self.onFailure?(); self.onDrop?() }
            } else if case .reject = assessment {
                self.stop(); self.onDrop?()
            } else if attempts > 1 {
                self.environment.schedule(0.04) { [weak self] in
                    guard let self, self.active, self.generation == current else { return }
                    self.deliver(target, generation: current, attempts: attempts - 1, deadline: deadline)
                }
            } else { self.stop(); self.onDrop?() }
        }
    }
    private static func targetApplication(at point: CGPoint) -> pid_t? {
        targetWindow(at: point)?.pid
    }
    private static func targetWindow(at point: CGPoint) -> (pid: pid_t, number: Int)? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in windows {
            guard let raw = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary), bounds.contains(point),
                  let pid = window[kCGWindowOwnerPID as String] as? Int32,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { continue }
            if pid == ProcessInfo.processInfo.processIdentifier,
               let number = window[kCGWindowNumber as String] as? Int,
               NSApp.windows.contains(where: { $0.windowNumber == number && $0.ignoresMouseEvents }) { continue }
            guard let number = window[kCGWindowNumber as String] as? Int else { return nil }
            return (pid, number) // Do not click through CE or a foreground overlay into another app.
        }
        return nil
    }
    private static func postPaste(to pid: pid_t) -> Bool {
        guard AXIsProcessTrusted(), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return false }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.postToPid(pid); up.postToPid(pid)
        return true
    }
}
