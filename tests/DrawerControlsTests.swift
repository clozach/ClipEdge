import AppKit

@main enum DrawerControlsTests {
    private static var assertions = 0
    private static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard value() else { fatalError("FAIL: \(message)") }
    }

    static func main() {
        _ = NSApplication.shared
        testMotion()
        testReleaseMotion()
        testCommandAndHover()
        testSettingsAndHover()
        testKeyboardReturn()
        testAvailability()
        testAnimatedGeometry()
        testSlideAndWidth()
        print("PASS: \(assertions) drawer visibility/motion assertions")
    }

    private static func testMotion() {
        var now: TimeInterval = 0
        let motion = ClipboardDrawerMotion(clock: { now })
        motion.move(to: 1, animated: true)
        check(motion.isAnimating && motion.fraction == 0, "opening begins at the edge")
        now = 0.15; motion.advance(at: now)
        check(abs(motion.fraction - 0.5) < 0.001, "300 ms opening is halfway at 150 ms")
        motion.move(to: 0, animated: true)
        check(abs(motion.fraction - 0.5) < 0.001, "reversal starts from its current position")
        now = 0.225; motion.advance(at: now)
        check(abs(motion.fraction - 0.25) < 0.001, "reversal eases through the remaining travel")
        now = 0.31; motion.advance(at: now)
        check(!motion.isAnimating && motion.fraction == 0, "a reversed animation ends closed")
        motion.move(to: 1, animated: false)
        check(!motion.isAnimating && motion.fraction == 1, "Reduce Motion can finish opening immediately")
        motion.move(to: 0, animated: true)
        now += 0.301; motion.advance(at: now)
        check(!motion.isAnimating && motion.fraction == 0, "full close also finishes after 300 ms")
    }

    /// Al, 2026-10-16: a released drag on the tab carries its speed into the slide, which still
    /// stops softly and never overshoots; a drag holds the drawer where the pointer puts it.
    private static func testReleaseMotion() {
        var now: TimeInterval = 0
        let motion = ClipboardDrawerMotion(clock: { now })
        motion.hold(at: 0.4)
        check(motion.isHeld && motion.isMoving && !motion.isAnimating && motion.fraction == 0.4, "a drag holds the drawer part-way, drawn but not sliding")
        motion.hold(at: 1.6)
        check(motion.fraction == 1, "a drag past fully open holds it open")
        motion.hold(at: 0)
        motion.move(to: 1, animated: true, velocity: 20)
        check(!motion.isHeld && motion.isAnimating, "letting go slides on from where it was held")
        var samples: [CGFloat] = []
        for step in 1...30 { now = Double(step) * 0.005; motion.advance(at: now); samples.append(motion.fraction) }
        check(samples[1] > 0.15, "a fast release starts fast: \(samples[1]) open after 10 ms, where a resting start is 0.003")
        check(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 } && samples.allSatisfy { $0 <= 1 }, "and never runs past fully open")
        check(!motion.isAnimating && motion.fraction == 1, "a release three times faster than the usual pace finishes in a third of the time (0.15 s)")
        now = 0; motion.hold(at: 0.5)
        motion.move(to: 1, animated: true, velocity: -5)
        now = 0.075; motion.advance(at: now)
        check(abs(motion.fraction - 0.75) < 0.001, "speed away from the target is dropped: the slide starts softly, halfway at half time")
        now = 1; motion.advance(at: now)
        motion.hold(at: 0.4)
        motion.move(to: 0, animated: true, velocity: -2)
        now = 1.06; motion.advance(at: now)
        check(motion.fraction < 0.4 * 0.5, "closing carries its speed too (\(motion.fraction) at half time)")
        now = 1.2; motion.advance(at: now)
        check(!motion.isAnimating && motion.fraction == 0, "and ends closed")
    }

    /// The tab slides the drawer and lets it go open or closed; its free edge sets its width.
    private static func testSlideAndWidth() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let store = ClipboardStore(pasteboard: board, persistenceURL: nil)
        let name = ClipboardMaterializer.privateSuiteName("ClipEdge-width-tests-")
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let panel = ClipboardWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        let drawer = ClipboardDrawerController(store: store, panel: panel, defaults: defaults, animationsEnabled: { true })
        defer { drawer.stop() }
        let screen = NSScreen.main!
        drawer.showCollapsedTab(on: screen)
        let glass = panel.contentView as! ClipboardGlassView, tab = glass.tabControl
        let width = drawer.dockLayout!.bodyFrame.width
        func settle(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
        // A slow drag past halfway opens; one short of it closes again.
        tab.onInteractionBegan?(.zero)
        tab.onSlide?(width * 0.38)
        check(abs(drawer.openingFraction - 0.38) < 0.01 && drawer.isAnimating && !glass.bodyContent.isHidden && !drawer.isVisible,
              "a drag away from the wall draws the drawer as far open as the pointer has gone, before it counts as open")
        tab.onSlideEnded?(100)
        settle(0.4)
        check(!drawer.isVisible && drawer.openingFraction == 0 && !drawer.isAnimating, "let go short of halfway, slowly, it closes again")
        tab.onInteractionBegan?(.zero)
        tab.onSlide?(width * 0.64)
        tab.onSlideEnded?(100)
        check(drawer.isVisible, "let go past halfway, it opens, as a click on the tab opens it")
        settle(0.4)
        check(drawer.openingFraction == 1 && !drawer.isAnimating, "and finishes opening")
        // From open: a flick toward the wall closes from anywhere; a flick away opens from anywhere.
        tab.onInteractionBegan?(.zero)
        tab.onSlide?(-width * 0.15)
        check(abs(drawer.openingFraction - 0.85) < 0.01, "toward the wall the open drawer follows the pointer")
        tab.onSlideEnded?(-900)
        settle(0.4)
        check(!drawer.isVisible && drawer.openingFraction == 0, "a flick toward the wall closes it")
        tab.onInteractionBegan?(.zero)
        tab.onSlide?(width * 0.1)
        tab.onSlideEnded?(900)
        settle(0.4)
        check(drawer.isVisible && drawer.openingFraction == 1, "a flick away from the wall opens it, even barely started")
        // The free edge sets the width, within what the content needs and most of the screen.
        let grip = glass.edgeGrips.left
        check(!grip.isHidden && glass.edgeGrips.right.isHidden, "a drawer at the right edge widens from its left edge")
        grip.onBegan?()
        grip.onDrag?(60)
        check(drawer.dockLayout!.bodyFrame.width == width + 60 && glass.bodyContent.frame.width == width + 60, "dragging the edge 60 points out widens the drawer by 60")
        grip.onDrag?(-2_000)
        check(drawer.dockLayout!.bodyFrame.width == ClipboardTabGeometry.contentMinimumWidth, "never narrower than its content needs")
        settle(0.05)
        let browser = drawer.browser
        check(browser.tabs.fittingSize.width <= browser.tabs.frame.width && browser.tabs.frame.maxX <= browser.bounds.width - 16
              && browser.selectButton.frame.minY > browser.search.frame.maxY && !browser.selectButton.frame.intersects(browser.list.countLine.count.frame)
              && browser.list.countLine.note.frame.maxX <= browser.list.countLine.count.frame.minX
              && browser.list.countLine.note.frame.height >= ceil(browser.list.countLine.note.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: browser.list.countLine.note.frame.width, height: 1_000)).height),
              "at its narrowest the tabs keep their whole names and keys, Select moves under the search beside the count, and the note wraps whole")
        grip.onDrag?(20_000)
        let widest = drawer.dockLayout!.bodyFrame.width
        check(widest > width + 60 && widest <= screen.visibleFrame.width * ClipboardTabGeometry.widestShare, "never wider than most of the screen (\(widest))")
        grip.onBegan?()
        grip.onDrag?(-(drawer.dockLayout!.bodyFrame.width - width - 40))
        grip.onEnded?()
        let saved = defaults.data(forKey: "ClipEdgeTabPlacement").flatMap { try? JSONDecoder().decode(ClipboardTabPlacement.self, from: $0) }
        check(saved?.bodyWidth == Double(width + 40), "letting go keeps the width (\(saved?.bodyWidth ?? -1))")
        let again = ClipboardDrawerController(store: store, panel: ClipboardWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true),
                                              defaults: defaults, animationsEnabled: { false })
        again.showCollapsedTab(on: screen)
        check(again.dockLayout!.bodyFrame.width == width + 40, "and the next launch opens at it")
        again.stop()
        let older = try! JSONDecoder().decode(ClipboardTabPlacement.self, from: Data(#"{"edge":"right","center":0.5,"length":240}"#.utf8))
        check(older.bodyWidth == nil, "a placement saved before widths reads with the default width")
    }

    private static func testCommandAndHover() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let store = ClipboardStore(pasteboard: board, persistenceURL: nil)
        let panel = ClipboardWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        let drawer = ClipboardDrawerController(store: store, panel: panel, defaults: nil)
        defer { drawer.stop() }
        let settings = ClipboardRevealSettings(defaults: nil)
        let edge = EdgeController(drawerController: drawer, settings: settings)
        drawer.showCollapsedTab(on: NSScreen.main!)
        let tabPoint = NSPoint(x: drawer.tabFrame!.midX, y: drawer.tabFrame!.midY)
        let outside = NSPoint(x: drawer.screenFrame!.midX, y: drawer.screenFrame!.midY)
        edge.samplePointer(at: tabPoint)
        check(drawer.isVisible, "hover still opens the drawer")
        edge.samplePointer(at: outside)
        check(!drawer.isVisible, "automatic opening still closes outside the drawer")
        var changes = 0
        drawer.onVisibilityChange = { changes += 1 }
        drawer.toggleFromCommand()
        edge.samplePointer(at: outside)
        edge.samplePointer(at: outside)
        check(drawer.isVisible && !drawer.allowsAutomaticHiding, "menu/shortcut opening survives the outside pointer")
        drawer.toggleFromCommand()
        edge.samplePointer(at: tabPoint)
        check(!drawer.isVisible, "command close over the tab cannot instantly hover-reopen")
        edge.samplePointer(at: outside)
        edge.samplePointer(at: tabPoint)
        check(drawer.isVisible && drawer.allowsAutomaticHiding, "leaving and re-entering restores ordinary hover")
        drawer.toggleFromCommand()
        check(!drawer.isVisible, "command toggles off a hover-opened drawer")
        drawer.toggleFromCommand()
        _ = drawer.browser.canvas.answer(.escape, nil)
        check(!drawer.isVisible && changes == 6, "Escape closes command-opened drawer and visibility callbacks track toggles")
        drawer.toggleFromCommand()
        drawer.browser.focusSearch()
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
            windowNumber: panel.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53)!
        drawer.browser.search.stringValue = "fixture"
        check(drawer.handleDrawerKey(escape) && drawer.isVisible && drawer.browser.search.stringValue.isEmpty,
              "Escape clears the search without closing on the same press")
        check(drawer.handleDrawerKey(escape) && !drawer.isVisible, "Escape in the empty search closes the drawer")
        drawer.toggleFromCommand()
        panel.makeFirstResponder(drawer.header.settingsButton)
        check(drawer.handleDrawerKey(escape) && !drawer.isVisible, "Escape from header controls also closes")
    }

    /// Al, 2026-10-11: with Settings open, a drawer hovered open stayed open after the pointer left,
    /// with the tab shown or hidden. Settings now holds the drawer only when opened from the drawer.
    private static func testSettingsAndHover() {
        for availability in [ClipboardDrawerAvailability.visibleTab, .hiddenTab] {
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            let store = ClipboardStore(pasteboard: board, persistenceURL: nil)
            let panel = ClipboardWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            let drawer = ClipboardDrawerController(store: store, panel: panel, defaults: nil)
            defer { drawer.stop() }
            let settingsWindow = SettingsWindowFixture(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
            drawer.onRevealSettings = { settingsWindow.pretendVisible = true }
            let settings = ClipboardRevealSettings(defaults: nil)
            settings.dismissalDelaySeconds = 0.5
            var now: TimeInterval = 0
            var pointer = NSPoint.zero
            let edge = EdgeController(drawerController: drawer, settings: settings, pointerLocation: { pointer }, clock: { now })
            drawer.showCollapsedTab(on: NSScreen.main!)
            let tab = drawer.tabFrame!
            drawer.applyAvailability(availability)
            let tabPoint = NSPoint(x: tab.midX, y: tab.midY)
            let name = availability == .visibleTab ? "visible tab" : "hidden tab"
            func hoverOpen() {
                pointer = NSPoint(x: drawer.screenFrame!.midX, y: drawer.screenFrame!.midY); edge.samplePointer()
                pointer = tabPoint; edge.samplePointer()
            }
            /// Twenty points outside the drawer, where the grace is 0.45 s; reports whether it is still open part-way.
            func leave() -> Bool {
                guard let body = drawer.bodyFrame else { return false }
                pointer = [NSPoint(x: body.midX, y: body.minY - 20), NSPoint(x: body.minX - 20, y: body.minY + 20),
                           NSPoint(x: body.maxX + 20, y: body.minY + 20)].first { !drawer.contains($0) }!
                edge.samplePointer()
                now += 0.3; edge.samplePointer()
                let openWithinGrace = drawer.isVisible
                now += 0.3; edge.samplePointer()
                return openWithinGrace
            }
            func menuTitle() -> String { AppDelegate.drawerMenuTitle(drawerVisible: drawer.isVisible, shortcut: .defaultDrawer) }

            settingsWindow.pretendVisible = true
            hoverOpen()
            check(drawer.isVisible && drawer.allowsAutomaticHiding, "\(name): hover opens while Settings is open, and may close again")
            check(leave() && !drawer.isVisible, "\(name): with Settings open, leaving the drawer closes it once its grace runs out")

            settingsWindow.pretendVisible = false
            hoverOpen()
            settingsWindow.pretendVisible = true
            check(leave() && !drawer.isVisible, "\(name): Settings opened from the app menu leaves a hovered drawer to close")

            let gear = drawer.header.settingsButton, tabControl = (panel.contentView as! ClipboardGlassView).tabControl
            // "," from the cards, as the keyboard delivers it.
            let comma = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber,
                                         context: nil, characters: ",", charactersIgnoringModifiers: ",", isARepeat: false, keyCode: 43)!
            let openers: [(String, () -> Void)] = [("gear", { _ = gear.sendAction(gear.action, to: gear.target) }),
                                                   ("tab right-click", { tabControl.onSettings?() }),
                                                   ("\",\" key", { panel.makeFirstResponder(drawer.browser.canvas); panel.sendEvent(comma) })]
            for (source, open) in openers {
                settingsWindow.pretendVisible = false
                hoverOpen()
                var changes = 0
                drawer.onVisibilityChange = { changes += 1 }
                open()
                check(settingsWindow.pretendVisible && changes == 1, "\(name): the \(source) opens Settings and reports the drawer's new hold")
                _ = leave()
                check(drawer.isVisible && !drawer.allowsAutomaticHiding, "\(name): a drawer that opened Settings from its \(source) stays after the pointer leaves")
                check(menuTitle().hasPrefix("Hide Clipboard"), "\(name): the menu reads Hide Clipboard while the \(source) holds it")
                if availability == .visibleTab {
                    drawer.showAtTab()
                    _ = leave()
                    check(drawer.isVisible && !drawer.allowsAutomaticHiding, "\(name): a click on the tab keeps the \(source)'s hold")
                }
                settingsWindow.pretendVisible = false
                drawer.settingsDidClose()
                check(drawer.allowsAutomaticHiding && leave() && !drawer.isVisible, "\(name): once Settings closes, the drawer the \(source) held closes on leaving")
                hoverOpen()
                open()
                _ = leave()
                check(drawer.isVisible && !drawer.allowsAutomaticHiding, "\(name): opening Settings from the \(source) again holds the drawer again")
                drawer.toggleFromCommand()
                check(!drawer.isVisible && menuTitle().hasPrefix("Show Clipboard"), "\(name): Show/Hide Clipboard closes the held drawer")
                drawer.onVisibilityChange = nil
                hoverOpen()
                check(drawer.isVisible && leave() && !drawer.isVisible, "\(name): the next hover opening, Settings still open, closes on leaving")
            }

            if availability == .visibleTab {
                pointer = NSPoint(x: drawer.screenFrame!.midX, y: drawer.screenFrame!.midY); edge.samplePointer()
                tabControl.onSettings?()
                check(!drawer.isVisible, "right-clicking the closed tab opens Settings without opening the drawer")
                hoverOpen()
                check(leave() && !drawer.isVisible, "and arms no hold for the next hover opening")
            }
        }
    }

    /// Settings had the keyboard when hover opened the drawer over it: when the drawer closes,
    /// Settings gets the keyboard back, so the next arrow or ⌘Z reaches its field, not the hidden drawer.
    private static func testKeyboardReturn() {
        for availability in [ClipboardDrawerAvailability.visibleTab, .hiddenTab] {
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            let store = ClipboardStore(pasteboard: board, persistenceURL: nil)
            let panel = ClipboardWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            let settingsWindow = SettingsWindowFixture(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
            settingsWindow.pretendVisible = true
            let drawer = ClipboardDrawerController(store: store, panel: panel, defaults: nil, focus: { .front(keyWindow: settingsWindow) })
            defer { drawer.stop() }
            var now: TimeInterval = 0
            var pointer = NSPoint.zero
            let edge = EdgeController(drawerController: drawer, settings: ClipboardRevealSettings(defaults: nil), pointerLocation: { pointer }, clock: { now })
            drawer.showCollapsedTab(on: NSScreen.main!)
            let tab = drawer.tabFrame!
            drawer.applyAvailability(availability)
            let name = availability == .visibleTab ? "visible tab" : "hidden tab"
            func hoverOpen() {
                pointer = NSPoint(x: drawer.screenFrame!.midX, y: drawer.screenFrame!.midY); edge.samplePointer()
                pointer = NSPoint(x: tab.midX, y: tab.midY); edge.samplePointer()
            }
            func leave() {
                pointer = NSPoint(x: drawer.screenFrame!.midX, y: drawer.screenFrame!.midY)
                for _ in 0..<4 { edge.samplePointer(); now += 0.5 }
            }
            hoverOpen()
            check(drawer.isVisible && drawer.previousApplication == nil && settingsWindow.keyRequests == 0, "\(name): hover opens over Settings, with no other app to return to")
            leave()
            check(!drawer.isVisible && settingsWindow.keyRequests == 1, "\(name): closing on leaving hands the keyboard back to Settings")
            hoverOpen()
            settingsWindow.pretendVisible = false
            leave()
            check(!drawer.isVisible && settingsWindow.keyRequests == 1, "\(name): a Settings window closed meanwhile is not brought back")
        }
    }

    private static func testAvailability() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let store = ClipboardStore(pasteboard: board, persistenceURL: nil)
        let panel = ClipboardWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        let drawer = ClipboardDrawerController(store: store, panel: panel, defaults: nil)
        defer { drawer.stop() }
        drawer.showCollapsedTab(on: NSScreen.main!)
        let oldTab = drawer.tabFrame!
        drawer.applyAvailability(.hiddenTab)
        check(!panel.isVisible && drawer.tabFrame == nil, "hidden tab removes the collapsed window")
        let hoverPoint = NSPoint(x: oldTab.midX, y: oldTab.midY)
        check(!drawer.tabContains(hoverPoint) && drawer.revealTargetContains(hoverPoint), "hidden paint preserves the saved hover position without a window")
        let edge = EdgeController(drawerController: drawer, settings: ClipboardRevealSettings(defaults: nil))
        edge.samplePointer(at: hoverPoint)
        check(drawer.isVisible && drawer.allowsAutomaticHiding, "hover opens the enabled hidden-tab drawer")
        drawer.hide(animated: false)
        drawer.toggleFromCommand()
        check(drawer.isVisible && panel.frame == drawer.bodyFrame, "enabled hidden-tab drawer opens from command with body-only bounds")
        let glass = panel.contentView as! ClipboardGlassView
        check(glass.tabControl.isHidden, "hidden tab is absent from expanded drawer too")
        drawer.applyAvailability(.disabled)
        // This process is never the active app, so its drawer holds the keyboard with ClipEdge in the background:
        // the drawer lets go of it a moment later, and with no tab to show its panel leaves then (`letGoOfKeyboard`).
        check(!drawer.isVisible, "disabling closes the drawer at once")
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        check(!drawer.isVisible && !panel.isVisible, "disabling closes the drawer")
        drawer.toggleFromCommand()
        drawer.show(on: NSScreen.main!, animated: false)
        check(!drawer.isVisible, "disabled drawer rejects all opening paths")
        drawer.applyAvailability(.visibleTab)
        check(panel.isVisible && !drawer.isVisible && !glass.tabControl.isHidden, "restoring the tab restores just the tab")
        check(drawer.tabFrame == oldTab, "visibility settings preserve the tab's saved location")
    }

    private static func testAnimatedGeometry() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let store = ClipboardStore(pasteboard: board, persistenceURL: nil)
        for edge in ClipboardDockEdge.allCases {
            let name = ClipboardMaterializer.privateSuiteName("ClipEdge-motion-tests-")
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            defaults.set(try! JSONEncoder().encode(ClipboardTabPlacement(edge: edge)), forKey: "ClipEdgeTabPlacement")
            let panel = ClipboardWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            let drawer = ClipboardDrawerController(store: store, panel: panel, defaults: defaults, animationsEnabled: { true })
            drawer.showCollapsedTab(on: NSScreen.main!)
            drawer.toggleFromCommand()
            let glass = panel.contentView as! ClipboardGlassView
            let fullSize = glass.bodyContent.frame.size
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            check(drawer.openingFraction > 0.15 && drawer.openingFraction < 0.95, "\(edge) has a visible intermediate slide position")
            check(glass.bodyContent.frame.size == fullSize, "\(edge) text and tiles stay full-size during slide")
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            check(!drawer.isAnimating && drawer.openingFraction == 1, "\(edge) opening reaches its destination")
            drawer.hide(animated: true)
            RunLoop.current.run(until: Date().addingTimeInterval(0.35))
            check(!drawer.isVisible && !drawer.isAnimating && panel.frame == drawer.tabFrame, "\(edge) close returns to tab-only bounds")
            drawer.applyAvailability(.hiddenTab)
            drawer.toggleFromCommand()
            drawer.toggleFromCommand()
            RunLoop.current.run(until: Date().addingTimeInterval(0.35))
            check(!panel.isVisible && !drawer.isAnimating, "\(edge) rapid hidden-tab toggle ends fully hidden")
            drawer.stop()
        }
    }
}

private final class SettingsWindowFixture: NSPanel {
    var pretendVisible = false
    private(set) var keyRequests = 0
    override var isVisible: Bool { pretendVisible }
    override func makeKey() { keyRequests += 1 }
}
