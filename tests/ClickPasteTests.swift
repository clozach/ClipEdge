import AppKit
import ApplicationServices

/// No event taps, physical input, real activation, or clipboard writes.
@main enum ClickPasteTests {
    private static var assertions = 0
    private static var failures: [String] = []
    private static let point = CGPoint(x: 100, y: 200)
    /// A physical left-Command click: device bit and non-coalesced bit included.
    private static let realCommand = CGEventFlags(rawValue: 0x100108)
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
        var lookups = 0
        var native = false
        var nativeChecks = 0
        lazy var click: CommandClickPaste = {
            let click = CommandClickPaste(environment: .init(
                receiverAt: { [weak self] _ in
                    guard let self else { return nil }
                    self.lookups += 1
                    guard let target = self.target, let window = self.window else { return nil }
                    return (target, window)
                },
                inspectTarget: { [weak self] _, _, completion in
                    guard let self else { return }
                    if self.deferInspection { self.inspections.append(completion) }
                    else { completion(self.assessment) }
                },
                frontmost: { [weak self] in self?.focused },
                postPaste: { [weak self] pid in self?.events.append("paste:\(pid)"); return self?.postSucceeds ?? false },
                schedule: { [weak self] delay, action in self?.queued.append((delay, action)) },
                now: { [weak self] in self?.clock ?? 0 },
                keepsCommand: { [weak self] _, _ in self?.nativeChecks += 1; return self?.native ?? false }))
            click.onPaste = { [weak self] point in self?.commits += 1; self?.events.append("detach"); self?.points.append(point) }
            click.onDrop = { [weak self] in self?.drops += 1; self?.events.append("detach") }
            click.onFailure = { [weak self] in self?.events.append("failure") }
            return click
        }()
        init() { click.start(observeSystemEvents: false) }
        /// Defaults model the paste gesture: Command held through the click.
        func down(flags: CGEventFlags = .maskCommand) -> Bool { click.receive(type: .leftMouseDown, flags: flags, point: point) }
        func up(flags: CGEventFlags = .maskCommand, at location: CGPoint = point) -> Bool {
            click.receive(type: .leftMouseUp, flags: flags, point: location)
        }
        func drag(flags: CGEventFlags = .maskCommand) -> Bool {
            click.receive(type: .leftMouseDragged, flags: flags, point: CGPoint(x: 110, y: 205))
        }
        /// The tap callback's path with a real, never-posted event.
        func deliver(_ type: CGEventType, flags: CGEventFlags, at location: CGPoint = point) -> CGEventFlags {
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: .left)!
            event.flags = flags
            return click.handle(type, event).flags
        }
        func tick() { if !queued.isEmpty { queued.removeFirst().1() } }
        func drain() { for _ in 0..<40 { if queued.isEmpty { return }; tick() } }
    }

    static func main() {
        commandClick()
        untouchedClicks()
        eventRewriting()
        nativeCommandTargets()
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

    private static func commandClick() {
        let h = Harness()
        check(h.down(), "Command mouse-down is accepted and loses Command")
        check(h.events.isEmpty && h.queued.isEmpty, "mouse-down neither inspects, activates nor pastes")
        check(h.up(), "Command mouse-up is accepted and loses Command")
        check(h.queued.count == 1 && h.queued[0].0 > 0, "delivery starts after mouse-up has returned")
        h.tick()
        check(h.events.isEmpty, "native click owns activation; CE never forces it")
        h.tick()
        check(h.events.isEmpty && h.click.active, "paste waits while another app is frontmost")
        h.focused = 12_345
        h.tick()
        check(h.events == ["paste:12345", "detach"], "settled focus delivers exactly one paste then detaches")
        check(!h.click.active && h.points.count == 1, "successful click ends the held gesture")
        check(!h.up(), "duplicate mouse-up is neither accepted nor changed")
        h.drain()
        check(h.points.count == 1, "duplicate mouse-up cannot paste twice")
        let released = Harness()
        released.focused = 12_345
        _ = released.down()
        check(released.up(flags: []), "Command released just before the button still pastes")
        released.drain()
        check(released.events == ["paste:12345", "detach"], "early Command release delivers one paste")
    }

    /// Al, 2026-10-02: unmodified clicks leave the cursor magnet untouched.
    private static func untouchedClicks() {
        let plain = Harness()
        plain.focused = 12_345
        check(!plain.down(flags: []) && !plain.up(flags: []), "plain click passes unchanged")
        plain.drain()
        check(plain.click.active && plain.events.isEmpty && plain.queued.isEmpty, "plain click keeps the magnet and never pastes")
        check(plain.drops == 0 && plain.commits == 0, "plain click neither drops nor commits")
        check(plain.lookups == 0, "plain click skips window lookups inside the event tap")
        for _ in 0..<3 { _ = plain.down(flags: []); _ = plain.up(flags: []) }
        plain.drain()
        check(plain.click.active && plain.events.isEmpty, "repeated plain clicks keep the magnet")
        let unknown = Harness()
        unknown.target = nil; unknown.window = nil
        _ = unknown.down(flags: []); _ = unknown.up(flags: []); unknown.drain()
        check(unknown.click.active && unknown.events.isEmpty && unknown.lookups == 0, "plain click outside any window keeps the magnet")
        let chrome = Harness()
        chrome.assessment = .reject("control-click")
        _ = chrome.down(flags: []); _ = chrome.up(flags: []); chrome.drain()
        check(chrome.click.active && chrome.events.isEmpty && chrome.lookups == 0, "plain click on app chrome keeps the magnet")
        let thenCommand = Harness()
        thenCommand.focused = 12_345
        _ = thenCommand.down(flags: []); _ = thenCommand.up(flags: [])
        _ = thenCommand.down(); _ = thenCommand.up(); thenCommand.drain()
        check(thenCommand.events == ["paste:12345", "detach"], "plain click, then Command-click, pastes once")
    }

    /// Command is removed from the real event of an accepted press, and only there.
    private static func eventRewriting() {
        let h = Harness()
        h.focused = 12_345
        let down = h.deliver(.leftMouseDown, flags: realCommand)
        check(!down.contains(.maskCommand), "accepted mouse-down reaches the destination without Command")
        check(down.contains(CGEventFlags(rawValue: 0x100)), "only Command is removed from the mouse-down")
        let drag = Harness()
        _ = drag.deliver(.leftMouseDown, flags: realCommand)
        check(drag.deliver(.leftMouseDragged, flags: realCommand).contains(.maskCommand), "drags are observed, never rewritten")
        check(!drag.deliver(.leftMouseUp, flags: realCommand).contains(.maskCommand), "a dragged press's mouse-up still loses Command")
        check(!h.deliver(.leftMouseUp, flags: realCommand).contains(.maskCommand), "accepted mouse-up reaches the destination without Command")
        h.drain()
        check(h.events == ["paste:12345", "detach"], "rewritten real events still paste once")
        for flags in [CGEventFlags(), .maskShift, realCommand.union(.maskShift), realCommand.union(.maskAlternate)] {
            let other = Harness()
            check(other.deliver(.leftMouseDown, flags: flags) == flags && other.deliver(.leftMouseUp, flags: flags) == flags,
                  "other clicks reach the destination unchanged: \(flags.rawValue)")
        }
        for flags in [realCommand, realCommand.union(.maskAlphaShift), realCommand.union(.maskSecondaryFn)] {
            let real = Harness()
            real.focused = 12_345
            check(real.down(flags: flags) && real.up(flags: flags), "physical Command flags are accepted: \(flags.rawValue)")
            real.drain()
            check(real.events == ["paste:12345", "detach"], "physical Command flags paste once: \(flags.rawValue)")
        }
        let observeOnly = Harness()
        observeOnly.click.canRewrite = false
        check(observeOnly.deliver(.leftMouseDown, flags: realCommand) == realCommand, "without an active tap Command is never removed")
        _ = observeOnly.deliver(.leftMouseUp, flags: realCommand); observeOnly.drain()
        check(observeOnly.click.active && observeOnly.events.isEmpty && observeOnly.lookups == 0,
              "without an active tap a Command-click neither pastes nor drops the magnet")
        let lost = Harness()
        _ = lost.down()
        check(!lost.down(flags: [.maskCommand, .maskShift]) && !lost.up(flags: [.maskCommand, .maskShift]),
              "a lost mouse-up does not leak Command removal into the next press")
        let restarted = Harness()
        _ = restarted.down(); restarted.click.start(observeSystemEvents: false)
        check(!restarted.up(flags: [.maskCommand, .maskShift]), "a new magnet forgets the old press")
    }

    /// A Command-click on a link or list row keeps its own meaning.
    private static func nativeCommandTargets() {
        let link = Harness()
        link.native = true; link.focused = 12_345
        check(!link.down() && !link.up(), "Command-click on a link passes unchanged")
        link.drain()
        check(link.click.active && link.events.isEmpty && link.drops == 0, "Command-click on a link keeps the magnet and never pastes")
        check(link.nativeChecks == 1, "one mouse-down check per Command-click")
        let plain = Harness()
        plain.native = true
        _ = plain.down(flags: []); _ = plain.up(flags: [])
        check(plain.nativeChecks == 0, "plain clicks never trigger the accessibility check")
        windowLookup()
        typealias Node = ClickPasteTarget.Node
        func keeps(_ path: [Node], at location: CGPoint = point, timedOut: Bool = false) -> Bool {
            ClickPasteTarget.keepsCommand(path, at: location, timedOut: timedOut)
        }
        check(keeps([Node(role: "AXStaticText"), Node(role: "AXLink"), Node(role: "AXWebArea")]), "link text keeps Command")
        check(keeps([Node(role: "AXStaticText"), Node(role: "AXLink"), Node(role: "AXTextArea", valueWritable: true)]),
              "a link inside an editor keeps Command")
        check(!keeps([Node(role: "AXTextArea", valueWritable: true), Node(role: "AXCell")]),
              "an editable field inside a table cell is a paste target")
        check(keeps([Node(role: "AXTextField"), Node(role: "AXCell"), Node(role: "AXRow")]),
              "a read-only name in a list row keeps Command for multi-select")
        check(keeps([Node(role: "AXButton"), Node(role: "AXToolbar"), Node(role: "AXWindow")]),
              "a toolbar button keeps Command (Back opens a new tab)")
        check(!keeps([Node(role: "AXTextField", valueWritable: true), Node(role: "AXToolbar")]),
              "an address field inside a toolbar still pastes")
        let window = Node(role: "AXWindow", bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        check(!keeps([window]), "window-only editors paste in their interior")
        check(keeps([window], at: CGPoint(x: 100, y: 25)), "a title or tab bar keeps Command (move without activating)")
        check(keeps([window], at: CGPoint(x: 2, y: 300)), "a window border keeps Command")
        check(!keeps([Node(role: "AXWindow")]), "a window without bounds still pastes")
        check(!keeps([Node(role: "AXGroup"), Node(role: "AXWindow"), Node(role: "AXRow")]), "the walk stops at the window")
        check(!keeps([]), "a hit-test that exposes nothing still pastes")
        check(keeps([Node(role: "AXStaticText")], timedOut: true), "a walk cut short by the time limit leaves the click alone")
        check(!keeps([Node(role: "AXTextArea", valueWritable: true)], timedOut: true), "an editor found before the limit still pastes")
        check(keeps([Node(role: "AXDockItem")]) && keeps([Node(role: "AXMenuBarItem")]), "Dock and menu-bar items keep Command")
    }

    private static func modifiersAndDrags() {
        let others: [CGEventFlags] = [.maskShift, .maskControl, .maskAlternate,
                                      [.maskCommand, .maskShift], [.maskCommand, .maskControl], [.maskCommand, .maskAlternate]]
        for modifier in others {
            let h = Harness()
            h.focused = 12_345
            check(!h.down(flags: modifier) && !h.up(flags: modifier), "other modified click passes unchanged: \(modifier.rawValue)")
            h.drain()
            check(h.click.active && h.events.isEmpty && h.queued.isEmpty, "other modified click retains magnet: \(modifier.rawValue)")
        }
        for modifier in [CGEventFlags.maskShift, .maskControl, .maskAlternate] {
            let late = Harness()
            late.focused = 12_345
            _ = late.down()
            check(late.up(flags: modifier.union(.maskCommand)), "late modifier's mouse-up still loses Command: \(modifier.rawValue)")
            late.drain()
            check(late.click.active && late.events.isEmpty, "modifier added before mouse-up suppresses paste: \(modifier.rawValue)")
        }
        let drag = Harness()
        drag.focused = 12_345
        _ = drag.down()
        check(!drag.drag(), "Command-drag events pass unchanged")
        check(drag.up(), "Command-drag mouse-up loses Command like its mouse-down")
        drag.drain()
        check(drag.click.active && drag.events.isEmpty, "drag cancels automatic paste and retains magnet")
        let plainDrag = Harness()
        _ = plainDrag.down(flags: [])
        check(!plainDrag.drag(flags: []) && !plainDrag.up(flags: []), "plain drag passes unchanged")
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
        let laterPlain = Harness()
        _ = laterPlain.down(); _ = laterPlain.up()
        _ = laterPlain.down(flags: []); _ = laterPlain.up(flags: [])
        laterPlain.focused = 12_345; laterPlain.drain()
        check(laterPlain.events.isEmpty && laterPlain.click.active, "later plain click cancels queued paste and keeps magnet")
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

    /// The window a click lands in, from a synthetic window list (front first).
    private static func windowLookup() {
        func window(_ owner: String, pid: Int32, number: Int, layer: Int, _ frame: CGRect, alpha: Double = 1) -> [String: Any] {
            [kCGWindowOwnerName as String: owner, kCGWindowOwnerPID as String: pid, kCGWindowNumber as String: number,
             kCGWindowLayer as String: layer, kCGWindowAlpha as String: alpha,
             kCGWindowBounds as String: CGRect(origin: frame.origin, size: frame.size).dictionaryRepresentation]
        }
        let own = ProcessInfo.processInfo.processIdentifier
        let cursor = window("Window Server", pid: 620, number: 9, layer: Int(CGWindowLevelForKey(.cursorWindow)),
                            CGRect(x: 80, y: 180, width: 62, height: 88))
        let editor = window("Notes", pid: 12_345, number: 42, layer: 0, CGRect(x: 0, y: 0, width: 800, height: 600))
        func first(_ list: [[String: Any]], at location: CGPoint = point, passes: Set<Int> = []) -> Int? {
            CommandClickPaste.firstWindow(at: location, in: list, ownPID: own) { passes.contains($0) }?.number
        }
        check(first([cursor, editor]) == 42, "the Window Server's cursor window around the pointer never takes the click")
        check(first([window("Window Server", pid: 620, number: 3, layer: 24, CGRect(x: 0, y: 0, width: 1800, height: 30)), editor],
                    at: CGPoint(x: 100, y: 10)) == nil, "the menu bar is never a paste destination")
        let magnet = window("ClipEdge", pid: own, number: 7, layer: 101, CGRect(x: 90, y: 190, width: 145, height: 120))
        check(first([cursor, magnet, editor], passes: [7]) == 42, "ClipEdge's click-through magnet is skipped")
        check(first([magnet, editor]) == 7, "a ClipEdge window that takes clicks is not clicked through")
        check(first([window("Overlay", pid: 777, number: 5, layer: 0, CGRect(x: 0, y: 0, width: 900, height: 700), alpha: 0), editor]) == 42,
              "fully transparent windows are skipped")
        check(first([editor], at: CGPoint(x: 900, y: 650)) == nil, "no window under the point")
        let banner = window("Notification Center", pid: 1230, number: 26, layer: 21, CGRect(x: 0, y: 0, width: 2056, height: 1329))
        let menuBar = window("Window Server", pid: 620, number: 3, layer: 24, CGRect(x: 0, y: 0, width: 1800, height: 30))
        check(CommandClickPaste.frontWindow(of: 12_345, at: point, in: [cursor, banner, editor]) == 42,
              "the receiving app's own window is found beneath pass-through overlays")
        check(CommandClickPaste.frontWindow(of: 12_345, at: CGPoint(x: 100, y: 10), in: [menuBar]) == nil,
              "an app has no window of its own in the menu bar")
        check(CommandClickPaste.frontWindow(of: 12_345, at: CGPoint(x: 900, y: 650), in: [editor]) == nil,
              "no window of that app under the point")
    }

    private static func chromeAndUnknownTargets() {
        let chrome = Harness()
        chrome.assessment = .reject("control-click")
        _ = chrome.down()
        check(chrome.click.active && chrome.events.isEmpty, "chrome mouse-down passes through before detach")
        _ = chrome.up(); chrome.drain()
        check(chrome.events == ["detach"] && !chrome.click.active, "chrome drops the magnet without focus changes or paste")
        check(chrome.drops == 1 && chrome.commits == 0, "chrome drop never masquerades as a paste commit")
        for (target, window) in [(nil, 42), (12_345, nil), (nil, nil)] as [(pid_t?, Int?)] {
            let nowhere = Harness()
            nowhere.target = target; nowhere.window = window
            check(!nowhere.down() && !nowhere.up(), "nothing to paste into: Command stays (desktop icons keep ⌘-select)")
            nowhere.drain()
            check(nowhere.click.active && nowhere.events.isEmpty && nowhere.nativeChecks == 0,
                  "nothing to paste into: the magnet stays and no accessibility check runs")
        }
        let own = Harness()
        own.target = ProcessInfo.processInfo.processIdentifier
        check(!own.down() && !own.up(), "Command-click on ClipEdge's own controls passes unchanged")
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
