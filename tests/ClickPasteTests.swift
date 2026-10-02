import AppKit
import ApplicationServices

/// No event taps, physical input, real activation, or clipboard writes.
@main enum ClickPasteTests {
    private static var assertions = 0
    private static var failures: [String] = []
    private static let point = CGPoint(x: 100, y: 200)
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() { failures.append(message); print("FAIL: \(message)") }
    }

    private final class Harness {
        var target: pid_t? = 12_345
        var window: Int? = 42
        var assessment: ClickPasteTarget.Assessment = .ready
        var focused: pid_t? = 99
        var postSucceeds = true
        var clock: TimeInterval = 0
        var deferInspection = false
        var inspections: [(ClickPasteTarget.Assessment) -> Void] = []
        var events: [String] = []
        var queued: [(TimeInterval, () -> Void)] = []
        var points: [NSPoint] = []
        var commits = 0
        var drops = 0
        lazy var click: CommandClickPaste = {
            let click = CommandClickPaste(environment: .init(
                targetAt: { [weak self] _ in self?.target },
                windowAt: { [weak self] _ in self?.window },
                inspectTarget: { [weak self] _, _, completion in
                    guard let self else { return }
                    if self.deferInspection { self.inspections.append(completion) }
                    else { completion(self.assessment) }
                },
                frontmost: { [weak self] in self?.focused },
                postPaste: { [weak self] pid in self?.events.append("paste:\(pid)"); return self?.postSucceeds ?? false },
                schedule: { [weak self] delay, action in self?.queued.append((delay, action)) },
                now: { [weak self] in self?.clock ?? 0 }))
            click.onPaste = { [weak self] point in self?.commits += 1; self?.events.append("detach"); self?.points.append(point) }
            click.onDrop = { [weak self] in self?.drops += 1; self?.events.append("detach") }
            click.onFailure = { [weak self] in self?.events.append("failure") }
            return click
        }()
        init() { click.start(observeSystemEvents: false) }
        func down(flags: CGEventFlags = []) -> Bool { click.receive(type: .leftMouseDown, flags: flags, point: point) }
        func up(flags: CGEventFlags = [], at location: CGPoint = point) -> Bool {
            click.receive(type: .leftMouseUp, flags: flags, point: location)
        }
        func tick() { if !queued.isEmpty { queued.removeFirst().1() } }
        func drain() { for _ in 0..<40 { if queued.isEmpty { return }; tick() } }
    }

    static func main() {
        ordinaryClick()
        modifiersAndDrags()
        staleWork()
        chromeAndUnknownTargets()
        failurePaths()
        missingAccessibility()
        targetPolicy()
        asynchronousInspection()
        print("\(failures.isEmpty ? "PASS" : "FAIL"): \(assertions) click/paste assertions; \(failures.count) failures")
        if !failures.isEmpty { exit(EXIT_FAILURE) }
    }

    private static func ordinaryClick() {
        let h = Harness()
        check(h.down(), "ordinary down is accepted")
        check(h.events.isEmpty && h.queued.isEmpty, "mouse-down neither inspects, activates nor pastes")
        check(h.up(), "ordinary up is accepted")
        check(h.queued.count == 1 && h.queued[0].0 > 0, "delivery starts after mouse-up has returned")
        h.tick()
        check(h.events.isEmpty, "native click owns activation; CE never forces it")
        h.tick()
        check(h.events.isEmpty && h.click.active, "paste waits while another app is frontmost")
        h.focused = 12_345
        h.tick()
        check(h.events == ["paste:12345", "detach"], "settled focus delivers exactly one paste then detaches")
        check(!h.click.active && h.points.count == 1, "successful click ends the held gesture")
        _ = h.up(); h.drain()
        check(h.points.count == 1, "duplicate mouse-up cannot paste twice")
    }

    private static func modifiersAndDrags() {
        for modifier in [CGEventFlags.maskShift, .maskCommand, .maskControl, .maskAlternate] {
            let h = Harness()
            check(!h.down(flags: modifier) && !h.up(flags: modifier), "modified click is not an automatic paste: \(modifier.rawValue)")
            check(h.click.active && h.events.isEmpty && h.queued.isEmpty, "modified click retains magnet: \(modifier.rawValue)")
            let late = Harness()
            _ = late.down(); _ = late.up(flags: modifier); late.drain()
            check(late.click.active && late.events.isEmpty, "modifier added before mouse-up suppresses paste: \(modifier.rawValue)")
        }
        let shifted = Harness()
        _ = shifted.down(); _ = shifted.up(flags: .maskShift)
        shifted.drain()
        check(shifted.click.active && shifted.events.isEmpty, "Shift added before release suppresses paste and detach")
        let drag = Harness()
        _ = drag.down()
        _ = drag.click.receive(type: .leftMouseDragged, flags: [], point: CGPoint(x: 110, y: 205))
        _ = drag.up(); drag.drain()
        check(drag.click.active && drag.events.isEmpty, "drag cancels automatic paste and retains magnet")
        let distant = Harness()
        _ = distant.down(); _ = distant.up(at: CGPoint(x: 120, y: 200)); distant.drain()
        check(distant.click.active && distant.events.isEmpty, "distant release cancels even if dragged event was missed")
    }

    private static func staleWork() {
        let later = Harness()
        _ = later.down(); _ = later.up()
        _ = later.down(flags: .maskShift)
        later.focused = 12_345; later.drain()
        check(later.events.isEmpty && later.click.active, "later Shift click cancels queued inspection and paste")
        let stopped = Harness()
        _ = stopped.down(); _ = stopped.up(); stopped.click.stop(); stopped.drain()
        check(stopped.events.isEmpty && !stopped.click.active, "Esc/drop cancels queued work")
        let replaced = Harness()
        _ = replaced.down(); _ = replaced.up(); replaced.tick()
        replaced.click.start(observeSystemEvents: false)
        replaced.focused = 12_345; replaced.drain()
        check(replaced.events.isEmpty && replaced.click.active, "new held item invalidates old focus retries")
        let laterTarget = Harness()
        _ = laterTarget.down(); _ = laterTarget.up()
        laterTarget.target = 54_321
        _ = laterTarget.down(); _ = laterTarget.up()
        laterTarget.focused = 54_321; laterTarget.drain()
        check(laterTarget.events == ["paste:54321", "detach"], "only the latest click's app receives paste")
    }

    private static func chromeAndUnknownTargets() {
        let chrome = Harness()
        chrome.assessment = .reject("control-click")
        _ = chrome.down()
        check(chrome.click.active && chrome.events.isEmpty, "chrome mouse-down passes through before detach")
        _ = chrome.up(); chrome.drain()
        check(chrome.events == ["detach"] && !chrome.click.active, "chrome drops the magnet without focus changes or paste")
        check(chrome.drops == 1 && chrome.commits == 0, "chrome drop never masquerades as a paste commit")
        let unknown = Harness()
        unknown.target = nil
        _ = unknown.down(); _ = unknown.up(); unknown.drain()
        check(unknown.events == ["detach"] && !unknown.click.active, "raw click without a known target still drops the magnet")
        check(unknown.drops == 1 && unknown.commits == 0, "unknown target drops without a paste commit")
        let own = Harness()
        own.target = ProcessInfo.processInfo.processIdentifier
        check(!own.down() && !own.up(), "ClipEdge controls do not receive automatic paste")
        check(own.click.active && own.events.isEmpty, "ClipEdge's own controls preserve the held item")
    }

    private static func failurePaths() {
        let timeout = Harness()
        _ = timeout.down(); _ = timeout.up(); timeout.drain()
        check(timeout.events == ["detach"], "focus timeout drops magnet without activating or pasting elsewhere")
        check(!timeout.click.active && timeout.queued.isEmpty, "focus timeout terminates retries")
        let unavailable = Harness()
        unavailable.focused = 12_345; unavailable.postSucceeds = false
        _ = unavailable.down(); _ = unavailable.up(); unavailable.drain()
        check(unavailable.events == ["paste:12345", "failure", "detach"], "failed paste reports failure and still drops magnet")
        check(unavailable.drops == 1 && unavailable.commits == 0, "failed post drops without a paste commit")
        check(!unavailable.click.active, "paste failure cannot leave the gesture armed")
    }

    private static func missingAccessibility() {
        check(ClickPasteTarget.Snapshot().assessment == .reject("accessibility-denied"), "missing AX permission refuses paste")
        let denied = Harness()
        denied.assessment = .reject("accessibility-denied")
        _ = denied.down(); _ = denied.up(); denied.drain()
        check(denied.events == ["detach"], "injected missing AX access detaches without posting")
    }

    private static func targetPolicy() {
        let field = ClickPasteTarget.Node(role: "AXTextArea", valueWritable: true,
                                         hasTextSelection: true, bounds: CGRect(x: 80, y: 180, width: 200, height: 100))
        let base = ClickPasteTarget.Snapshot(trusted: true, hitOwnedByTarget: true, focusOwnedByTarget: true,
                                            hitPath: [field], focused: field, focusInHitPath: true,
                                            sameWindow: true, point: point)
        check(base.assessment == .ready, "writable native text target is ready")
        var custom = base
        custom.focused?.role = "AXGroup"; custom.hitPath = [custom.focused!]
        check(custom.assessment == .ready, "custom role with writable value is supported")
        custom.focused?.valueWritable = false; custom.focused?.selectedTextWritable = true
        check(custom.assessment == .ready, "writable selected text is a separate editor capability")
        custom.focused?.selectedTextWritable = false; custom.pasteEnabled = true
        check(custom.assessment == .ready, "linked custom editor may use enabled standard Paste")
        custom.pasteEnabled = false
        check(custom.assessment == .reject("paste-disabled"), "read-only custom editor with disabled Paste is rejected")
        custom.pasteEnabled = nil
        check(custom.assessment == .retry("editability-unavailable"), "unknown editability never blindly pastes")
        var stale = base
        stale.focusInHitPath = false
        stale.focused?.bounds = CGRect(x: 500, y: 500, width: 100, height: 100)
        stale.pasteEnabled = true
        check(stale.assessment == .retry("stale-focus"), "enabled Paste in another field is insufficient")
        var otherWindow = base
        otherWindow.sameWindow = false
        check(otherWindow.assessment == .retry("different-window"), "a focused editor in another window is insufficient")
        var button = base
        button.hitPath = [.init(role: "AXStaticText"), .init(role: "AXButton"), field]
        check(button.assessment == .reject("control-click"), "button text cannot route into stale editor underneath")
        button.hitPath = [.init(role: "AXStaticText", hasTextSelection: true), .init(role: "AXButton"), field]
        check(button.assessment == .reject("control-click"), "selectable decorative text does not bypass button guard")
        var toolbar = base
        toolbar.hitPath = [field, .init(role: "AXToolbar")]
        check(toolbar.assessment == .ready, "actual editable field inside toolbar remains valid")
        for role in ["AXMenuItem", "AXDockItem", "AXTab", "AXLink", "AXScrollBar", "AXSlider"] {
            button.hitPath = [.init(role: role)]
            check(button.assessment == .reject("control-click"), "chrome role is not an editor: \(role)")
        }
        var disabled = base
        disabled.focused?.enabled = false
        check(disabled.assessment == .reject("disabled-focus"), "disabled focused field never receives paste")
        disabled = base; disabled.hitPath[0].enabled = false
        check(disabled.assessment == .reject("disabled-hit"), "disabled clicked field cannot paste into retained focus")
        var unresolved = base
        unresolved.hitOwnedByTarget = false
        check(unresolved.assessment == .retry("hit-unavailable"), "foreign/absent hit waits rather than pastes")
        unresolved = base; unresolved.focusOwnedByTarget = false
        check(unresolved.assessment == .retry("focus-unavailable"), "foreign focus never receives paste")
        unresolved = base; unresolved.focused?.role = "AXWindow"
        check(unresolved.assessment == .reject("window-chrome"), "window without a safe interior is not a paste destination")
        var generic = base
        generic.focused = .init(role: "AXGroup", bounds: field.bounds)
        generic.hitPath = [generic.focused!]; generic.pasteEnabled = true
        check(generic.assessment == .ready, "focused custom content with actual enabled Paste is supported without role allowlist")
        generic.focusInHitPath = false
        check(generic.assessment == .retry("editability-unavailable"), "generic container geometry alone cannot authorize menu fallback")
        var windowOnly = base
        windowOnly.focused = .init(role: "AXWindow", bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        windowOnly.hitPath = [windowOnly.focused!]
        windowOnly.windowInterior = CGRect(x: 8, y: 64, width: 784, height: 528)
        windowOnly.pasteEnabled = true
        check(windowOnly.assessment == .ready, "window-only custom app supports intentional interior click with enabled Paste")
        windowOnly.pasteEnabled = nil
        check(windowOnly.assessment == .retry("window-paste-unavailable"), "window-only app cannot rely on absent Paste metadata")
        windowOnly.pasteEnabled = false
        check(windowOnly.assessment == .reject("paste-disabled"), "window-only app honors disabled Paste")
        windowOnly.pasteEnabled = true; windowOnly.point = CGPoint(x: 100, y: 25)
        check(windowOnly.assessment == .reject("window-chrome"), "window-only fallback excludes title/tab bar strip")
        windowOnly.point = CGPoint(x: 2, y: 200)
        check(windowOnly.assessment == .reject("window-chrome"), "window-only fallback excludes resize borders")
        windowOnly.point = CGPoint(x: 1000, y: 200)
        check(windowOnly.assessment == .reject("window-chrome"), "window-only fallback excludes points outside the target geometry")
        windowOnly.point = point; windowOnly.sameWindow = false
        check(windowOnly.assessment == .retry("focus-not-content"), "window-only fallback requires exact focused window")
        windowOnly.sameWindow = true; windowOnly.hitPath = [.init(role: "AXButton"), windowOnly.focused!]
        check(windowOnly.assessment == .reject("control-click"), "known custom-app controls still reject window fallback")
    }

    private static func asynchronousInspection() {
        let delayed = Harness()
        delayed.assessment = .retry("editability-unavailable"); delayed.focused = 12_345
        _ = delayed.down(); _ = delayed.up(); delayed.tick()
        check(delayed.click.active && delayed.events.isEmpty, "editor may become editable after delivered click")
        delayed.assessment = .ready; delayed.tick()
        check(delayed.events == ["paste:12345", "detach"], "later positive focus inspection completes one paste")
        let obsolete = Harness()
        obsolete.focused = 12_345; obsolete.deferInspection = true
        _ = obsolete.down(); _ = obsolete.up(); obsolete.tick()
        _ = obsolete.down(flags: .maskShift)
        obsolete.inspections.removeFirst()(.ready)
        check(obsolete.events.isEmpty && obsolete.click.active, "later click invalidates in-flight AX response")
        let switched = Harness()
        switched.focused = 12_345; switched.deferInspection = true
        _ = switched.down(); _ = switched.up(); switched.tick()
        switched.target = 54_321; switched.inspections.removeFirst()(.ready)
        check(switched.events == ["detach"], "changed window under pointer cancels stale AX response")
        let windowChanged = Harness()
        windowChanged.focused = 12_345; windowChanged.deferInspection = true
        _ = windowChanged.down(); _ = windowChanged.up(); windowChanged.tick()
        windowChanged.window = 43; windowChanged.inspections.removeFirst()(.ready)
        check(windowChanged.events == ["detach"], "different window in the same app cancels stale AX response")
        let slow = Harness()
        slow.focused = 12_345; slow.deferInspection = true
        _ = slow.down(); _ = slow.up(); slow.tick()
        slow.clock = 2; slow.inspections.removeFirst()(.ready)
        check(slow.events == ["detach"], "AX response past wall-clock deadline never pastes")
        let keyboardSwitch = Harness()
        keyboardSwitch.focused = 12_345; keyboardSwitch.deferInspection = true
        _ = keyboardSwitch.down(); _ = keyboardSwitch.up(); keyboardSwitch.tick()
        keyboardSwitch.focused = 54_321; keyboardSwitch.inspections.removeFirst()(.ready)
        check(keyboardSwitch.events.isEmpty, "focus is rechecked after background inspection")
    }
}
