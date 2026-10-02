import AppKit
import ApplicationServices

/// Watches a held item's next Command-click. The destination receives that
/// click without Command, so it places its insertion point; paste follows after
/// focus settles. Chrome clicks only drop the magnet. Every other click, plain
/// or otherwise modified, passes unchanged and leaves the magnet attached, as
/// does a Command-click on a link or list row, where Command has its own meaning.
final class CommandClickPaste {
    /// Modifiers that decide a gesture. Only Command alone means "paste here".
    private static let gestureModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
    struct Target: Equatable { let pid: pid_t; let point: NSPoint; let window: Int }
    struct Environment {
        /// The app and window that will actually receive a click at a point.
        var receiverAt: (CGPoint) -> (pid: pid_t, window: Int)? = CommandClickPaste.receivingWindow
        var inspectTarget: (CGPoint, pid_t, @escaping (ClickPasteTarget.Assessment) -> Void) -> Void = ClickPasteTarget.inspect
        var frontmost: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        var postPaste: (pid_t) -> Bool = CommandClickPaste.postPaste
        var schedule: (TimeInterval, @escaping () -> Void) -> Void = { delay, action in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action) }
        var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        /// Bounded AX read at mouse-down: does Command-click have its own meaning here?
        var keepsCommand: (CGPoint, pid_t) -> Bool = ClickPasteTarget.commandClickHasNativeMeaning
    }
    var onPaste: ((NSPoint) -> Void)?
    var onDrop: (() -> Void)?
    var onFailure: (() -> Void)?
    private let environment: Environment
    private var taps: [(port: CFMachPort, source: CFRunLoopSource)] = []
    private var mouseMonitor: Any?
    private var generation = 0
    private enum Gesture { case idle, pressed(Target), focusing }
    private var gesture: Gesture = .idle
    /// Command is removed from the mouse-down and mouse-up of an accepted
    /// press, so the destination receives one ordinary click.
    private var removingCommand = false
    /// Only an active tap can remove Command. Fixtures model one; a real start
    /// earns it. Without it, Command-clicks pass unchanged and do not paste:
    /// the destination has already acted on its own Command-click.
    var canRewrite = true
    private(set) var active = false
    private(set) var lastDecision = "idle"
    init(environment: Environment = Environment()) { self.environment = environment }
    deinit { stop() }

    func start(observeSystemEvents: Bool = true) {
        stop(); active = true; lastDecision = "armed"
        canRewrite = !observeSystemEvents
        guard observeSystemEvents else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let clicks = Self.tap(.defaultTap, [.leftMouseDown, .leftMouseUp], context) {
            // Rewriting needs an active tap (Accessibility, which paste also needs).
            // Drags are only observed, so dragging anywhere never waits on CE.
            taps = [clicks] + [Self.tap(.listenOnly, [.leftMouseDragged], context)].compactMap { $0 }
            canRewrite = true
        } else if let observer = Self.tap(.listenOnly, [.leftMouseDown, .leftMouseUp, .leftMouseDragged], context) {
            taps = [observer]
        } else {
            // Mouse observation does not require a keyboard/Input Monitoring grant.
            // Use AppKit only when Quartz could not create a tap (no duplicate downs).
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged]) { [weak self] event in
                guard let cg = event.cgEvent else { return }
                self?.receive(type: cg.type, flags: cg.flags, point: cg.location)
            }
        }
    }
    func stop() {
        active = false; generation += 1; gesture = .idle; removingCommand = false
        for tap in taps {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), tap.source, .commonModes)
            CFMachPortInvalidate(tap.port)
        }
        taps = []
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }
    /// The tap callback's body. A listen-only tap ignores the rewrite.
    @discardableResult
    func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent {
        if receive(type: type, flags: event.flags, point: event.location) {
            // Command-click would open links, jump to definitions or add
            // cursors; the destination should only place its caret.
            event.flags.remove(.maskCommand)
        }
        return event
    }
    /// macOS turned a tap off (a stall or user input) and passed events without
    /// it; a press may have lost its mouse-up. Forget it and turn back on.
    private func resumeAfterTapDisabled() {
        removingCommand = false
        if case .pressed = gesture { gesture = .idle }
        if active { taps.forEach { CGEvent.tapEnable(tap: $0.port, enable: true) } }
    }
    private static let callback: CGEventTapCallBack = { _, type, event, context in
        guard let context else { return Unmanaged.passUnretained(event) }
        let owner = Unmanaged<CommandClickPaste>.fromOpaque(context).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { owner.resumeAfterTapDisabled() }
        else { owner.handle(type, event) }
        return Unmanaged.passUnretained(event)
    }
    private static func tap(_ options: CGEventTapOptions, _ types: [CGEventType],
                            _ context: UnsafeMutableRawPointer) -> (port: CFMachPort, source: CFRunLoopSource)? {
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: options,
                                           eventsOfInterest: mask, callback: callback, userInfo: context) else { return nil }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else { CFMachPortInvalidate(port); return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return (port, source)
    }
    /// Returns whether to remove Command from this event. Only an accepted
    /// Command-click's own events are changed; all other events pass unchanged.
    @discardableResult
    func receive(type: CGEventType, flags: CGEventFlags, point: CGPoint) -> Bool {
        guard active else { return false }
        if type == .leftMouseDown {
            generation += 1 // A later click cancels a still-pending focus/paste.
            gesture = .idle; removingCommand = false
            // A plain or otherwise-modified click is the user's own: the magnet stays.
            guard flags.intersection(Self.gestureModifiers) == .maskCommand else { return false }
            guard canRewrite else { lastDecision = "command-not-removable"; return false }
            // Nothing to paste into here (the desktop, the menu bar, ClipEdge
            // itself): the click keeps Command and the magnet stays.
            guard let (pid, window) = environment.receiverAt(point), pid != ProcessInfo.processInfo.processIdentifier
            else { lastDecision = "no-paste-target"; return false }
            // Do not ask AX whether mouse-down hit an editor. Web/custom editors
            // may create their input only after this very click is delivered.
            // Only ask whether Command already means something here: a link
            // opens a tab, a list row extends a selection. Those stay native.
            if environment.keepsCommand(point, pid) { lastDecision = "native-command-target"; return false }
            gesture = .pressed(Target(pid: pid, point: NSPoint(x: point.x, y: CGDisplayBounds(CGMainDisplayID()).height - point.y), window: window))
            removingCommand = true
            return true
        }
        if type == .leftMouseDragged { gesture = .idle; generation += 1; return false }
        guard type == .leftMouseUp else { return false }
        let accepted = removingCommand
        removingCommand = false
        guard case .pressed(let target) = gesture else { return accepted }
        gesture = .idle
        // Command may be released just before the button; other modifiers cancel.
        guard flags.intersection([.maskControl, .maskAlternate, .maskShift]).isEmpty else { return true }
        let release = NSPoint(x: point.x, y: CGDisplayBounds(CGMainDisplayID()).height - point.y)
        guard hypot(release.x - target.point.x, release.y - target.point.y) < 5 else { return true }
        let current = generation
        gesture = .focusing
        // Let the real click choose the app AND its input. Forcing activation
        // here could bring a stale destination back after the user switched.
        let deadline = environment.now() + 0.85
        environment.schedule(0.06) { [weak self] in
            guard let self, self.active, self.generation == current else { return }
            self.deliver(target, generation: current, attempts: 10, deadline: deadline)
        }
        return true
    }
    private func deliver(_ target: Target, generation current: Int, attempts: Int, deadline: TimeInterval) {
        let pid = target.pid
        let point = CGPoint(x: target.point.x, y: CGDisplayBounds(CGMainDisplayID()).height - target.point.y)
        guard environment.now() < deadline, stillUnder(point, target) else {
            lastDecision = "cancelled-target-or-timeout"
            stop(); onDrop?(); return
        }
        environment.inspectTarget(point, pid) { [weak self] assessment in
            guard let self, self.active, self.generation == current else { return }
            self.lastDecision = String(describing: assessment)
            guard self.environment.now() < deadline, self.stillUnder(point, target) else {
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
    private func stillUnder(_ point: CGPoint, _ target: Target) -> Bool {
        guard let receiver = environment.receiverAt(point) else { return false }
        return receiver.pid == target.pid && receiver.window == target.window
    }
    /// The Window Server, not the top of the window list, decides who receives
    /// a click: the pointer's own window (an enlarged pointer) and Notification
    /// Center's full-screen host (while a banner shows) pass clicks through.
    /// The system-wide hit test names the receiving app; its frontmost window
    /// at the point is the window number. ClipEdge's own clickable windows
    /// answer first, without asking Accessibility about ClipEdge itself.
    static func receivingWindow(at point: CGPoint) -> (pid: pid_t, window: Int)? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let own = ProcessInfo.processInfo.processIdentifier
        let front = firstWindow(at: point, in: windows, ownPID: own) { number in
            NSApp.windows.contains { $0.windowNumber == number && $0.ignoresMouseEvents }
        }
        if let front, front.pid == own { return (front.pid, front.number) }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.02)
        var hit: AXUIElement?
        var pid: pid_t = 0
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              let hit, AXUIElementGetPid(hit, &pid) == .success, pid != own,
              let number = frontWindow(of: pid, at: point, in: windows) else { return nil }
        return (pid, number)
    }
    /// The frontmost on-screen window of `pid` that contains `point`. None for
    /// the menu bar (the Window Server's) or the desktop (excluded from the list).
    static func frontWindow(of pid: pid_t, at point: CGPoint, in windows: [[String: Any]]) -> Int? {
        for window in windows where window[kCGWindowOwnerPID as String] as? Int32 == pid {
            guard let raw = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary), bounds.contains(point),
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  (window[kCGWindowLayer as String] as? Int ?? 0) < cursorLevel else { continue }
            return window[kCGWindowNumber as String] as? Int
        }
        return nil
    }
    private static let cursorLevel = Int(CGWindowLevelForKey(.cursorWindow))
    /// The front window at `point` by the window list alone, used to recognize
    /// ClipEdge's own clickable windows. Skips the Window Server's cursor
    /// window, which macOS lists around an enlarged pointer, and ClipEdge's
    /// click-through panels. The Window Server's own UI (the menu bar) is nil.
    static func firstWindow(at point: CGPoint, in windows: [[String: Any]], ownPID: pid_t,
                            passesClicks: (Int) -> Bool) -> (pid: pid_t, number: Int)? {
        for window in windows {
            guard let raw = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary), bounds.contains(point),
                  let pid = window[kCGWindowOwnerPID as String] as? Int32,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  (window[kCGWindowLayer as String] as? Int ?? 0) < cursorLevel else { continue }
            let number = window[kCGWindowNumber as String] as? Int
            if pid == ownPID, let number, passesClicks(number) { continue }
            if window[kCGWindowOwnerName as String] as? String == "Window Server" { return nil }
            guard let number else { return nil }
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
