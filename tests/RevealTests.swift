import AppKit

@main enum RevealTests {
    private static var assertions = 0
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError("FAIL: \(message)") }
    }

    static func main() {
        _ = NSApplication.shared
        testTiming()
        testPersistence()
        testNativeControls()
        testTab()
        testDrawerHeader()
        testDrawerExit()
        print("PASS: \(assertions) reveal/settings/tab/header/exit assertions")
    }

    private static func testTiming() {
        var trigger = ClipboardRevealTrigger()
        check(!trigger.shouldReveal(pointerOverTab: false, behavior: .instant, now: 0), "instant waits for the tab")
        check(trigger.shouldReveal(pointerOverTab: true, behavior: .instant, now: 0), "instant opens on entry")
        check(!trigger.shouldReveal(pointerOverTab: true, behavior: .click, now: 20), "click mode does not open on hover")
        check(!trigger.shouldReveal(pointerOverTab: true, behavior: .click, now: 200), "long hover cannot bypass click mode")
        check(!trigger.shouldReveal(pointerOverTab: true, behavior: .delayed(2), now: 201), "delay starts on entry")
        check(!trigger.shouldReveal(pointerOverTab: true, behavior: .delayed(2), now: 202.99), "full two-second delay is honored")
        check(trigger.shouldReveal(pointerOverTab: true, behavior: .delayed(2), now: 203), "opens at two-second deadline")
        check(!trigger.shouldReveal(pointerOverTab: false, behavior: .delayed(2), now: 204), "leaving cancels hover")
        check(!trigger.shouldReveal(pointerOverTab: true, behavior: .delayed(2), now: 205), "re-entry gets a fresh delay")
        check(!trigger.shouldReveal(pointerOverTab: true, behavior: .delayed(1), now: 205.5), "changing delay restarts its clock")
        check(trigger.shouldReveal(pointerOverTab: true, behavior: .delayed(1), now: 206.5), "new delay applies")
        trigger.reset()
        check(!trigger.shouldReveal(pointerOverTab: true, behavior: .delayed(1), now: 210), "interaction reset cancels previous wait")
        check(trigger.shouldReveal(pointerOverTab: true, behavior: .delayed(0), now: 211), "zero delay works")
    }

    private static func testPersistence() {
        let suite = "ClipEdge-reveal-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ClipboardRevealSettings(defaults: defaults)
        check(settings.mode == .instant && settings.delaySeconds == 0.35, "fresh settings preserve instant reveal")
        check(settings.dismissalDelaySeconds == 0.5 && settings.quickLookShortcut == .defaultQuickLook, "fresh preferences have close grace and compatible default shortcut")
        settings.dismissalDelaySeconds = 2.75
        let shortcut = ClipboardShortcut(keyCode: 40, modifiers: [.control, .command])!
        settings.quickLookShortcut = shortcut
        let extraReload = ClipboardRevealSettings(defaults: defaults)
        check(extraReload.dismissalDelaySeconds == 2.75 && extraReload.quickLookShortcut == shortcut, "close grace and shortcut survive reload")
        settings.dismissalDelaySeconds = 9
        check(settings.dismissalDelaySeconds == 3, "close grace caps at three seconds")
        settings.dismissalDelaySeconds = -1
        check(settings.dismissalDelaySeconds == 0, "close grace cannot be negative")
        settings.dismissalDelaySeconds = .nan
        check(settings.dismissalDelaySeconds == 0.5, "invalid close grace returns to half second")
        settings.mode = .delayed
        settings.delaySeconds = 1.65
        let reloaded = ClipboardRevealSettings(defaults: defaults)
        check(reloaded.mode == .delayed && reloaded.delaySeconds == 1.65, "mode and delay survive reload")
        settings.mode = .click
        check(ClipboardRevealSettings(defaults: defaults).mode == .click, "click mode persists")
        settings.delaySeconds = 20
        check(settings.delaySeconds == 2, "delay caps at two seconds")
        settings.delaySeconds = -1
        check(settings.delaySeconds == 0, "delay cannot be negative")
        settings.delaySeconds = .infinity
        check(settings.delaySeconds == 0.35, "nonfinite delay has a safe default")
        defaults.set("broken", forKey: "ClipEdgeRevealMode")
        defaults.set(-100, forKey: "ClipEdgeRevealDelay")
        defaults.set(Data("invalid shortcut".utf8), forKey: "ClipEdgeQuickLookShortcut")
        let malformed = ClipboardRevealSettings(defaults: defaults)
        check(malformed.mode == .instant && malformed.delaySeconds == 0, "malformed stored preferences normalize at load")
        check(malformed.quickLookShortcut == .defaultQuickLook, "corrupt stored shortcut safely falls back")
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(forName: ClipboardRevealSettings.didChange,
                                                               object: settings, queue: nil) { _ in notifications += 1 }
        settings.mode = .instant
        settings.delaySeconds = 1
        NotificationCenter.default.removeObserver(observer)
        check(notifications == 2, "both controls notify their shared settings consumers")
    }

    private static func testNativeControls() {
        let settings = ClipboardRevealSettings(defaults: nil)
        let controller = ClipboardRevealSettingsController(settings: settings)
        let content = controller.window!.contentView!
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let controls = descendants(content)
        let popup = controls.compactMap { $0 as? NSPopUpButton }.first!
        let slider = controls.compactMap { $0 as? NSSlider }.first { $0.accessibilityLabel() == "Hover delay in seconds" }!
        let dismissal = controls.compactMap { $0 as? NSSlider }.first { $0.accessibilityLabel() == "Maximum close delay in seconds" }!
        let recorder = controls.compactMap { $0 as? ClipboardShortcutRecorder }.first!
        check(popup.numberOfItems == 3 && popup.accessibilityLabel() == "Reveal mode", "all modes are exposed accessibly")
        check(!slider.isEnabled, "delay stays visible but disabled in instant mode")
        popup.selectItem(at: 1)
        _ = popup.sendAction(popup.action, to: popup.target)
        check(settings.mode == .delayed && slider.isEnabled, "native mode control writes through immediately")
        slider.doubleValue = 1.2
        _ = slider.sendAction(slider.action, to: slider.target)
        check(settings.delaySeconds == 1.2, "native delay slider changes the preference")
        check(slider.accessibilityValueDescription() == "1.20 seconds", "delay value is announced with units")
        popup.selectItem(at: 2)
        _ = popup.sendAction(popup.action, to: popup.target)
        check(settings.mode == .click && !slider.isEnabled, "click mode disables unused delay")
        check(popup.nextKeyView === slider && slider.nextKeyView === dismissal && dismissal.nextKeyView === recorder, "settings controls form a keyboard loop")
        dismissal.doubleValue = 2.4
        _ = dismissal.sendAction(dismissal.action, to: dismissal.target)
        check(settings.dismissalDelaySeconds == 2.4 && dismissal.accessibilityValueDescription() == "2.40 seconds", "native close delay writes through with units")
        var requested: ClipboardShortcut?
        controller.onShortcutChange = { requested = $0; return -9878 }
        let candidate = ClipboardShortcut(keyCode: 40, modifiers: [.control, .option])!
        recorder.onRecord?(candidate)
        check(requested == candidate && settings.quickLookShortcut == .defaultQuickLook, "conflicting shortcut does not alter preference")
        check(controls.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("unchanged") }, "registration conflict is explained inline")
        controller.onShortcutChange = { _ in noErr }
        recorder.onRecord?(candidate)
        check(settings.quickLookShortcut == candidate && recorder.shortcut == candidate, "accepted shortcut changes preference and recorder")
        content.layoutSubtreeIfNeeded()
        for control in [popup, slider, dismissal, recorder] {
            let frame = control.convert(control.bounds, to: content)
            check(!control.hasAmbiguousLayout && frame.width > 0 && frame.height > 0 && content.bounds.contains(frame), "settings control has nonempty, unambiguous in-window bounds")
        }
        check(controller.makeMenuItem(keyEquivalent: ",").keyEquivalent == ",", "settings supports the standard menu shortcut")
    }

    private static func testTab() {
        let tab = ClipboardTabView(frame: NSRect(x: 0, y: 0, width: 28, height: 240))
        func pixels() -> NSBitmapImageRep {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 28, pixelsHigh: 240,
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                          isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            tab.draw(tab.bounds)
            NSGraphicsContext.restoreGraphicsState()
            return bitmap
        }
        func opaqueCount(_ bitmap: NSBitmapImageRep, rows: Range<Int>) -> Int {
            rows.reduce(0) { count, y in count + (0..<28).filter { (bitmap.colorAt(x: $0, y: y)?.alphaComponent ?? 0) > 0 }.count }
        }
        check(!tab.showsHandles && opaqueCount(pixels(), rows: 0..<240) == 0, "collapsed idle tab has no lozenge")
        tab.isExpanded = true
        let expanded = pixels()
        check(tab.showsHandles && opaqueCount(expanded, rows: 0..<20) > 0 && opaqueCount(expanded, rows: 220..<240) > 0, "open tab draws both end grips")
        check(opaqueCount(expanded, rows: 30..<210) == 0, "open tab has no central vertical grip")
        tab.isExpanded = false
        let hover = NSEvent.enterExitEvent(with: .mouseEntered, location: NSPoint(x: 14, y: 120),
                                          modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                          eventNumber: 0, trackingNumber: 0, userData: nil)!
        tab.mouseEntered(with: hover)
        check(tab.showsHandles, "hover reveals grips even while drawer is closed")
        tab.mouseExited(with: hover)
        check(!tab.showsHandles, "leaving the closed tab hides grips")
        var clicks = 0
        tab.onClick = { clicks += 1 }
        check(tab.accessibilityPerformPress() && clicks == 1, "accessibility press opens independent of hover")
        var settingsOpens = 0
        tab.onSettings = { settingsOpens += 1 }
        let rightClick = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
                                          timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                                          clickCount: 1, pressure: 0)!
        tab.rightMouseDown(with: rightClick)
        check(settingsOpens == 1, "right-click exposes the tab settings")
    }

    private static func testDrawerHeader() {
        let header = ClipboardDrawerHeader(appIcon: nil)
        header.frame = NSRect(x: 0, y: 0, width: 390, height: ClipboardDrawerHeader.height)
        header.layoutSubtreeIfNeeded()
        check(!header.hasAppIcon, "header does not invent missing app artwork")
        check(header.subviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "ClipEdge" }, "header identifies the drawer")
        check(header.settingsButton.keyEquivalent == "," && header.settingsButton.keyEquivalentModifierMask == .command, "header gear exposes Command-comma")
        check(header.settingsButton.accessibilityLabel()?.contains("Reveal Settings") == true, "header gear names the existing settings accessibly")
        check(header.settingsButton.showsBorderOnlyWhileMouseInside, "header settings button exposes a hover border")
        var opens = 0
        header.onSettings = { opens += 1 }
        _ = header.settingsButton.sendAction(header.settingsButton.action, to: header.settingsButton.target)
        check(opens == 1, "header gear invokes the settings callback once")
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 390, height: 700))
        let browser = NSView()
        header.install(above: browser, in: host)
        host.layoutSubtreeIfNeeded()
        check(header.frame == NSRect(x: 0, y: 664, width: 390, height: 36), "header occupies the top 36 points of native body layout")
        check(browser.frame == NSRect(x: 0, y: 0, width: 390, height: 664), "browser fills the remaining body below header")
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let store = ClipboardStore(pasteboard: board, persistenceURL: nil)
        let drawer = ClipboardDrawerController(store: store, defaults: nil)
        drawer.onRevealSettings = { opens += 1 }
        _ = drawer.header.settingsButton.sendAction(drawer.header.settingsButton.action, to: drawer.header.settingsButton.target)
        check(opens == 2, "drawer routes header gear to existing Reveal Settings")
        check(drawer.browser.clear.nextKeyView === drawer.header.settingsButton && drawer.header.settingsButton.nextKeyView === drawer.browser.search, "header gear joins the browser keyboard loop")
        check(!drawer.isVisible, "header verification never orders the drawer")
        let settingsWindow = VisibilityFixture(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        drawer.revealSettingsWindow = settingsWindow
        check(drawer.allowsAutomaticHiding, "closed settings do not block outside-close")
        settingsWindow.pretendVisible = true
        check(!drawer.allowsAutomaticHiding, "open settings keep drawer from retracting")
        settingsWindow.pretendVisible = false
        check(drawer.allowsAutomaticHiding, "outside-close resumes after settings close")
    }

    private static func testDrawerExit() {
        check(ClipboardDrawerExitPolicy.delay(distance: 0, maximum: 3) == 3, "edge gets full configured delay")
        check(ClipboardDrawerExitPolicy.delay(distance: 100, maximum: 3) == 1.5, "halfway distance gets half delay")
        check(ClipboardDrawerExitPolicy.delay(distance: 200, maximum: 3) == 0, "200 points gets zero delay")
        check(ClipboardDrawerExitPolicy.delay(distance: 250, maximum: 3) == 0, "beyond 200 never gets negative delay")
        check(ClipboardDrawerExitPolicy.delay(distance: 0, maximum: 0) == 0, "zero preference disables grace")
        let body = NSRect(x: 300, y: 100, width: 390, height: 700)
        var policy = ClipboardDrawerExitPolicy()
        func hides(_ x: CGFloat, _ y: CGFloat, _ time: TimeInterval, _ maxDelay: TimeInterval = 0.5) -> Bool {
            let point = NSPoint(x: x, y: y)
            return policy.shouldHide(pointer: point, containsPointer: body.contains(point), body: body,
                                     tab: nil, maximumDelay: maxDelay, now: time)
        }
        for point in [NSPoint(x: 280, y: 400), NSPoint(x: 710, y: 400), NSPoint(x: 500, y: 80), NSPoint(x: 500, y: 820)] {
            policy.reset()
            check(!hides(point.x, point.y, 0), "every outside edge gets near-edge grace")
            check(!hides(point.x, point.y, 0.449), "near-edge grace lasts the distance-adjusted duration")
            check(hides(point.x, point.y, 0.451), "all edges eventually close, including menu-bar exit")
        }
        policy.reset()
        check(!hides(710, 400, 0), "small overshoot waits")
        check(!hides(680, 400, 0.1), "returning inside cancels close")
        check(!hides(710, 400, 0.3), "later exit starts fresh grace")
        check(!hides(710, 400, 0.7), "fresh grace does not inherit old deadline")
        check(hides(710, 400, 0.751), "fresh deadline eventually closes")
        policy.reset()
        _ = hides(790, 400, 0)
        check(!hides(710, 400, 0.2), "moving inward extends live distance-adjusted deadline")
        check(hides(710, 400, 0.46), "moving inward cannot retain indefinitely")
        policy.reset()
        _ = hides(710, 400, 0)
        check(hides(850, 400, 0.3), "slowly moving outward shortens deadline")
        policy.reset()
        _ = hides(680, 400, 0)
        check(!hides(720, 400, 0.02), "fast small overshoot still receives distance-based grace")
        check(!hides(680, 400, 0.04), "fast overshoot can return inside before closing")
        check(hides(890, 400, 0.06), "fast outward movement closes on reaching 200 points")
        policy.reset()
        _ = hides(710, 400, 0)
        check(!hides(710, 500, 0.02), "fast tangential motion is not outward motion")
        check(hides(890, 500, 0.03), "200-point boundary closes immediately")
        policy.reset()
        check(hides(691, 400, 0, 0), "zero setting closes at first outside sample")
        policy.reset()
        _ = hides(710, 400, 0, 3)
        check(hides(710, 400, 0.1, 0), "changing maximum to zero applies immediately")
        policy.reset()
        let tab = NSRect(x: 682, y: 360, width: 28, height: 240)
        check(!policy.shouldHide(pointer: NSPoint(x: 715, y: 400), containsPointer: false, body: body, tab: tab,
                                  maximumDelay: 0.5, now: 0), "tab participates in nearest drawer edge")
        check(!policy.shouldHide(pointer: NSPoint(x: 715, y: 400), containsPointer: false, body: body, tab: tab,
                                  maximumDelay: 0.5, now: 0.48), "five points beyond tab gets its longer correct grace")
        check(policy.shouldHide(pointer: NSPoint(x: 715, y: 400), containsPointer: false, body: body, tab: tab,
                                 maximumDelay: 0.5, now: 0.49), "tab-edge grace also expires")
    }
}

private final class VisibilityFixture: NSPanel {
    var pretendVisible = false
    override var isVisible: Bool { pretendVisible }
}
