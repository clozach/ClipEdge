import AppKit

/// Settings as AppDelegate builds and shows it, followed from "a value changed" to "a magnet
/// seen": the same controller and panel, every step of show() but ordering it on screen, and
/// the pointer moved by AppKit's own tracking-area manager, which is asked where a window
/// location falls as it asks on each mouse move. Its entered and exited events then arrive
/// as the screen's would. No event reaches the system, the pointer never moves, no window is
/// ordered on screen; no preferences, a named pasteboard.
@main enum SettingsWindowTests {
    private static var assertions = 0
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError("FAIL: \(message)") }
    }
    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    /// In the window's coordinates, as AppKit tracks the pointer.
    private static func inWindow(_ view: NSView) -> NSRect { view.convert(view.bounds, to: nil) }
    private static func center(_ view: NSView) -> NSPoint { NSPoint(x: inWindow(view).midX, y: inWindow(view).midY) }
    /// A few points right of `point`: the pointer's next move without leaving where it is.
    private static func nudged(_ point: NSPoint) -> NSPoint { NSPoint(x: point.x + 2, y: point.y) }
    private static func spin(_ seconds: TimeInterval = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    // MARK: AppKit's pointer

    /// The window's tracking-area manager and the call AppKit makes on each mouse move, or nil
    /// where this macOS names them differently (then the pointer checks are skipped, said aloud).
    private static func tracker(_ window: NSWindow) -> ((NSPoint) -> Void)? {
        guard let ivar = class_getInstanceVariable(NSWindow.self, "_trackingAreaManager"),
              let manager = object_getIvar(window, ivar) as? NSObject else { return nil }
        let selector = NSSelectorFromString("_updateActiveTrackingAreasForWindowLocation:modifierFlags:")
        guard let method = class_getInstanceMethod(type(of: manager), selector) else { return nil }
        typealias Update = @convention(c) (NSObject, Selector, NSPoint, UInt) -> Void
        let update = unsafeBitCast(method_getImplementation(method), to: Update.self)
        return { point in update(manager, selector, point, 0) }
    }

    /// The pointer at `point` in `window`: AppKit decides which areas it entered and left, and
    /// the events it queued for their owners are delivered.
    private static func movePointer(to point: NSPoint, in window: NSWindow, with track: (NSPoint) -> Void) {
        track(point)
        spin()
        while let event = NSApp.nextEvent(matching: [.mouseEntered, .mouseExited], until: Date(), inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
    }

    // MARK: Settings, as the app has it

    private struct Opened {
        let controller: ClipboardRevealSettingsController
        let settings: ClipboardRevealSettings
        let window: NSWindow
        var document: NSView { controller.window!.contentView!.subviews.compactMap { $0 as? NSScrollView }.first!.documentView! }
        var tuners: [ClipboardTuner] { controller.tuners }
        func view<T: NSView>(_ type: T.Type, _ match: (T) -> Bool) -> T { descendants(window.contentView!).compactMap { $0 as? T }.first(where: match)! }
    }

    /// AppDelegate's Settings: `ClipboardRevealSettingsController(settings:)` over a settings
    /// object, here one with no preferences and a named pasteboard for its editing chords.
    private static func build(_ board: NSPasteboard) -> Opened {
        let settings = ClipboardRevealSettings(defaults: nil)
        let controller = ClipboardRevealSettingsController(settings: settings, pasteboard: board)
        return Opened(controller: controller, settings: settings, window: controller.window!)
    }

    /// show(), less ordering the panel on screen, making it key and activating the app:
    /// its refresh (any change to the settings runs it), centering, the keyboard on Hide drawer tab.
    private static func show(_ opened: Opened) {
        NotificationCenter.default.post(name: ClipboardRevealSettings.didChange, object: opened.settings)
        if !opened.window.isVisible { opened.window.center() }
        opened.window.makeFirstResponder(opened.window.initialFirstResponder)
        spin()
    }

    private static func shown(_ tuners: [ClipboardTuner]) -> [String] { tuners.filter(\.magnetsRevealed).map(\.spec.label) }
    /// One step away from the default, so the field has something to undo.
    private static func change(_ tuner: ClipboardTuner) {
        tuner.submit(tuner.spec.defaultValue == tuner.spec.maximum ? tuner.spec.minimum : tuner.spec.maximum)
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .aqua)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        testStructure(board)
        testDrawing(board)
        let probe = build(board)
        guard tracker(probe.window) != nil else {
            print("Skipped pointer checks: AppKit's tracking-area manager is not reachable on this macOS. PASS: \(assertions) Settings window assertions")
            return
        }
        testHover(board)
        testHandleTakesKeyboard(board)
        testReopenUnderPointer(board)
        print("PASS: \(assertions) Settings window assertions; AppKit's own pointer tracking, nothing on screen")
    }

    /// The magnets' layer stays over everything in Settings, through every change that reshapes it.
    private static func testStructure(_ board: NSPasteboard) {
        let opened = build(board)
        show(opened)
        let content = opened.window.contentView!
        let layer = opened.tuners[0].undoMagnet.superview as? ClipboardTunerMagnetLayer
        let changes: [(String, () -> Void)] = [
            ("as opened", {}),
            ("with the tab hidden", { opened.settings.drawerAvailability = .hiddenTab }),
            ("with the drawer off", { opened.settings.drawerAvailability = .disabled }),
            ("with the drawer back", { opened.settings.drawerAvailability = .visibleTab }),
            ("in delayed hover", { opened.settings.mode = .delayed }),
            ("with cursor magnets off", { opened.settings.magnetsEnabled = false }),
            ("with cursor magnets on", { opened.settings.magnetsEnabled = true })]
        for (moment, change) in changes {
            change()
            content.layoutSubtreeIfNeeded()
            check(layer != nil && opened.document.subviews.last === layer && layer!.frame == opened.document.bounds,
                  "\(moment): the magnets' layer is the document's last view and covers it whole (\(String(describing: layer?.frame)) of \(opened.document.bounds))")
            for tuner in opened.tuners {
                let region = inWindow(tuner.hoverRegion), field = inWindow(tuner.field)
                check(!tuner.hasAmbiguousLayout && !tuner.hoverRegion.hasAmbiguousLayout && !tuner.undoMagnet.hasAmbiguousLayout && !tuner.redoMagnet.hasAmbiguousLayout,
                      "\(moment): \(tuner.spec.label)'s layout is settled")
                check(!field.isEmpty && region.contains(field) && content.bounds.contains(region) && content.bounds.contains(inWindow(tuner.undoMagnet)),
                      "\(moment): \(tuner.spec.label)'s field, hover region and magnets sit inside the window (\(region))")
                let areas = tuner.hoverRegion.trackingAreas
                check(areas.count == 1 && areas[0].owner === tuner && areas[0].options.isSuperset(of: [.mouseEnteredAndExited, .activeAlways]),
                      "\(moment): \(tuner.spec.label)'s hover region has one area, its tuner's, live in any window state")
            }
        }
    }

    /// A shown magnet draws: Settings' own pixels where it sits change when it shows.
    private static func testDrawing(_ board: NSPasteboard) {
        let opened = build(board)
        show(opened)
        let content = opened.window.contentView!
        let tuner = opened.controller.motionTuners[0]
        change(tuner)
        func pixels() -> Data {
            content.layoutSubtreeIfNeeded()
            let rect = tuner.undoMagnet.convert(tuner.undoMagnet.bounds, to: content)
            let rep = content.bitmapImageRepForCachingDisplay(in: rect)!
            content.cacheDisplay(in: rect, to: rep)
            return rep.tiffRepresentation!
        }
        let hidden = pixels()
        opened.window.makeFirstResponder(tuner.keyView)
        check(!tuner.undoMagnet.isHidden && !tuner.undoMagnet.isHiddenOrHasHiddenAncestor && tuner.undoMagnet.alphaValue == 1, "the keyboard in the number shows its ↺")
        check(pixels() != hidden, "and Settings draws it where it sits")
        opened.window.makeFirstResponder(nil)
    }

    /// Hover through AppKit: each tuner's magnets, and only its own, while the pointer is on it;
    /// none on a delay its reveal mode does not use.
    private static func testHover(_ board: NSPasteboard) {
        let opened = build(board)
        opened.settings.mode = .delayed
        show(opened)
        let window = opened.window, tuners = opened.tuners
        let track = tracker(window)!
        let corner = NSPoint(x: 2, y: 2)
        movePointer(to: corner, in: window, with: track)
        tuners.forEach(change)
        // Text size at its largest zooms Settings: AppKit places its tracking areas anew on its next turn.
        spin()
        check(shown(tuners).isEmpty, "with every field changed, nothing shows until the pointer comes")
        for tuner in tuners {
            // Zoomed, Settings is taller than the screen: a field below the fold is scrolled to first.
            tuner.scrollToVisible(tuner.bounds.insetBy(dx: 0, dy: -24))
            spin()
            movePointer(to: center(tuner.field), in: window, with: track)
            check(shown(tuners) == [tuner.spec.label] && !tuner.undoMagnet.isHidden, "the pointer on \(tuner.spec.label) shows its ↺, no one else's")
            let gap = NSPoint(x: inWindow(tuner.undoMagnet).midX, y: inWindow(tuner.field).maxY + ClipboardTuner.magnetGap / 2)
            movePointer(to: gap, in: window, with: track)
            check(shown(tuners) == [tuner.spec.label], "crossing the gap toward \(tuner.spec.label)'s ↺ keeps it")
        }
        movePointer(to: corner, in: window, with: track)
        check(shown(tuners).isEmpty, "the pointer leaving hides them")
        opened.settings.mode = .instant
        movePointer(to: center(tuners[0].field), in: window, with: track)
        check(tuners[0].history.canUndo && shown(tuners).isEmpty, "the dimmed hover delay shows none, though it has a step")
        opened.settings.mode = .delayed
        movePointer(to: nudged(center(tuners[0].field)), in: window, with: track)
        check(shown(tuners) == [tuners[0].spec.label], "in use again, it shows its own on the next move")
    }

    /// A field clicked into earlier keeps the keyboard, so its neighbors' magnets give way to it.
    /// Pressing another field's handle leaves the number, as a press anywhere else in Settings
    /// does; the field dragged then shows its own ↺ under the pointer, and ⌘Z undoes it.
    private static func testHandleTakesKeyboard(_ board: NSPasteboard) {
        let opened = build(board)
        show(opened)
        let window = opened.window, tuners = opened.tuners
        let track = tracker(window)!
        let typed = opened.controller.motionTuners[0], dragged = opened.controller.motionTuners[1]
        window.makeFirstResponder(typed.keyView)
        check(window.firstResponder is NSTextView, "a click into \(typed.spec.label)'s number gives it the keyboard")
        let handle = center(dragged.handle)
        movePointer(to: handle, in: window, with: track)
        func mouse(_ type: NSEvent.EventType, x: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: handle.y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        // The window sees the press first, as AppKit delivers it; then the handle, which AppKit hit-tests to.
        let press = mouse(.leftMouseDown, x: handle.x)
        window.sendEvent(press)
        check(window.contentView!.hitTest(window.contentView!.superview!.convert(handle, from: nil)) === dragged.handle, "the press lands on \(dragged.spec.label)'s handle")
        dragged.handle.mouseDown(with: press)
        dragged.handle.mouseDragged(with: mouse(.leftMouseDragged, x: handle.x + 20))
        dragged.handle.mouseUp(with: mouse(.leftMouseUp, x: handle.x + 20))
        check(dragged.history.canUndo && opened.settings.drawerMotion(for: .closing).duration == dragged.value / 1000, "the drag changed \(dragged.spec.label)")
        check(!(window.firstResponder is NSTextView) && typed.entry.currentEditor() == nil, "pressing a handle left \(typed.spec.label)'s number")
        movePointer(to: center(dragged.field), in: window, with: track)
        check(shown(tuners) == [dragged.spec.label], "the field just dragged shows its ↺ under the pointer (\(shown(tuners)))")
        let commandZ = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: window.windowNumber,
                                        context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6)!
        check(window.performKeyEquivalent(with: commandZ) && !dragged.history.canUndo && dragged.value == dragged.spec.defaultValue, "and ⌘Z undoes the drag, as its ↺ ⌘Z says")

        // A press on the number's own field keeps the keyboard there.
        window.makeFirstResponder(typed.keyView)
        let own = typed.field.convert(NSPoint(x: typed.field.bounds.maxX - 2, y: typed.field.bounds.midY), to: nil)
        window.sendEvent(NSEvent.mouseEvent(with: .leftMouseDown, location: own, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        check((window.firstResponder as? NSTextView)?.delegate === typed.entry, "a press on \(typed.spec.label)'s own field keeps its number")
        window.makeFirstResponder(nil)
    }

    /// Settings closed with the pointer on a field, then opened again: the pointer's next move
    /// on that field shows its magnets, as on any other.
    private static func testReopenUnderPointer(_ board: NSPasteboard) {
        let opened = build(board)
        show(opened)
        let window = opened.window, tuners = opened.tuners
        let track = tracker(window)!
        let (tuner, other) = (opened.controller.motionTuners[0], opened.controller.motionTuners[1])
        change(tuner)
        movePointer(to: NSPoint(x: 2, y: 2), in: window, with: track)
        movePointer(to: center(tuner.field), in: window, with: track)
        check(shown(tuners) == [tuner.spec.label], "the pointer on \(tuner.spec.label) shows its ↺")
        opened.controller.close()
        check(shown(tuners).isEmpty, "closing Settings under the pointer leaves no magnet for the next opening")
        show(opened)
        check(shown(tuners).isEmpty, "opened again, nothing shows before the pointer moves")
        movePointer(to: nudged(center(tuner.field)), in: window, with: track)
        check(shown(tuners) == [tuner.spec.label], "the pointer's next move on \(tuner.spec.label) shows its ↺ again (\(shown(tuners)))")
        movePointer(to: center(other.field), in: window, with: track)
        check(shown(tuners).isEmpty, "and moving on to a field with nothing to undo hides it")
    }
}
