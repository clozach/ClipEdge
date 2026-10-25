import AppKit

/// Settings' tuners, the hover and close delays and the drawer's slide each way: parsing,
/// stepping and scrubbing; the in-memory undo and redo; what is persisted; the one curve
/// each direction slides on, for its own duration; how each tuner
/// behaves (selecting on entry, Esc leaving, live drags, the unit right after the number,
/// the editing chords, a typed number kept however the field is left); and the Settings
/// layout with its magnets above each field, in light and dark, and a delay dimmed while
/// unused. Isolated preferences, a
/// named pasteboard; nothing on screen.
@main enum TunerTests {
    private static var assertions = 0
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError("FAIL: \(message)") }
    }
    private static func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func isDark(_ view: NSView) -> Bool { view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
    private static func luminance(_ color: CGColor?) -> CGFloat {
        guard let color, let c = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return -1 }
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    }
    private static func resolved(_ color: NSColor, in name: NSAppearance.Name) -> CGColor {
        var result = color.cgColor
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance { result = color.cgColor }
        return result
    }
    private static func same(_ a: CGColor?, _ b: CGColor?) -> Bool {
        guard let a, let b, let x = NSColor(cgColor: a)?.usingColorSpace(.sRGB), let y = NSColor(cgColor: b)?.usingColorSpace(.sRGB) else { return false }
        return abs(x.redComponent - y.redComponent) < 0.02 && abs(x.greenComponent - y.greenComponent) < 0.02 && abs(x.blueComponent - y.blueComponent) < 0.02
    }
    private static func key(_ characters: String, _ modifiers: NSEvent.ModifierFlags, code: UInt16, window: NSWindow, isARepeat: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: isARepeat, keyCode: code)!
    }
    private static func hover(_ entered: Bool, window: NSWindow) -> NSEvent {
        NSEvent.enterExitEvent(with: entered ? .mouseEntered : .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
    }
    private static func mouse(_ type: NSEvent.EventType, x: CGFloat, window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 20), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
    }
    /// Closes the undo group typing opened: undo groups by run-loop pass.
    private static func spin() {
        RunLoop.current.add(Timer(timeInterval: 0.01, repeats: false) { _ in }, forMode: .default)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    private static let keyCodes: [Character: UInt16] = ["0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "r": 15, " ": 49]
    /// Typed through the window, as the keyboard delivers it.
    private static func type(_ text: String, into window: NSWindow) {
        for character in text { window.sendEvent(key(String(character), [], code: keyCodes[character] ?? 0, window: window)) }
        spin()
    }
    /// A click on the number: the mouse-up is queued first, so the field's own tracking ends at once.
    private static func click(_ entry: NSTextField) {
        guard let window = entry.window else { fatalError("FAIL: the number is in a window") }
        let point = entry.convert(NSPoint(x: entry.bounds.midX, y: entry.bounds.midY), to: nil)
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                      context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        NSApp.postEvent(up, atStart: false)
        entry.mouseDown(with: down)
    }
    /// A click in the other order AppKit may use: the window gives the number the keyboard while
    /// it is delivering the press (the press is the application's current event), then hands it the press.
    private static func clickAfterFocus(_ entry: NSTextField) {
        guard let window = entry.window else { fatalError("FAIL: the number is in a window") }
        let point = entry.convert(NSPoint(x: entry.bounds.midX, y: entry.bounds.midY), to: nil)
        for (type, pressure) in [(NSEvent.EventType.leftMouseDown, Float(1)), (.leftMouseUp, 0)] {
            NSApp.postEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                               context: nil, eventNumber: 0, clickCount: 1, pressure: pressure)!, atStart: false)
        }
        guard let press = NSApp.nextEvent(matching: .leftMouseDown, until: Date(), inMode: .default, dequeue: true), NSApp.currentEvent === press else {
            fatalError("FAIL: the press is the application's current event")
        }
        window.makeFirstResponder(entry)
        entry.mouseDown(with: press)
        _ = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true)
    }
    /// A label's frame reaches past its text by a couple of points; its alignment rect is where layout put it.
    private static func aligned(_ view: NSView, in content: NSView) -> NSRect {
        view.superview!.convert(view.alignmentRect(forFrame: view.frame), to: content)
    }
    private static func whole(_ field: NSTextField) -> NSRange { NSRange(location: 0, length: (field.stringValue as NSString).length) }
    private static func near(_ a: NSRect, _ b: NSRect) -> Bool {
        abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5 && abs(a.maxX - b.maxX) < 0.5 && abs(a.maxY - b.maxY) < 0.5
    }
    /// A click at `point` (in `content`'s coordinates): what Settings' views put under it, clicked if it is a button.
    /// (NSButton's own press tracking does not run on a synthetic press in a window laid out off screen,
    /// so the button found is clicked with performClick, which highlights it and sends its action.)
    private static func clickButton(at point: NSPoint, in content: NSView) -> NSView? {
        let view = content.hitTest(content.superview!.convert(point, from: content))
        (view as? NSButton)?.performClick(nil)
        return view
    }
    /// How far down a label's glyphs reach, in `content`'s coordinates, read from the pixels it draws.
    private static func lowestInk(of label: NSView, in content: NSView) -> CGFloat? {
        guard let rep = label.bitmapImageRepForCachingDisplay(in: label.bounds) else { return nil }
        label.cacheDisplay(in: label.bounds, to: rep)
        for row in stride(from: rep.pixelsHigh - 1, through: 0, by: -1) where (0..<rep.pixelsWide).contains(where: { (rep.colorAt(x: $0, y: row)?.alphaComponent ?? 0) > 0 }) {
            let fromTop = CGFloat(row + 1) * label.bounds.height / CGFloat(rep.pixelsHigh)
            return label.convert(NSPoint(x: 0, y: label.isFlipped ? fromTop : label.bounds.height - fromTop), to: content).y
        }
        return nil
    }

    static func main() {
        let app = NSApplication.shared
        app.appearance = NSAppearance(named: .aqua)
        testSpec()
        testHistory()
        testPersistence()
        testMotion()
        testRouting()
        testControl()
        testLimit()
        testWrapping()
        for name in [NSAppearance.Name.aqua, .darkAqua] { testSettings(in: name) }
        app.appearance = NSAppearance(named: .aqua)
        testSettingsKeyboard()
        testSettingsLeaving()
        testSettingsHover()
        print("PASS: \(assertions) Settings tuner assertions; isolated preferences, a named pasteboard, nothing on screen")
    }

    private static func testSpec() {
        let duration = ClipboardTunerSpec.duration("Opening duration", standard: 300)
        check(duration.parsed("300ms") == 300 && duration.parsed(" 1,200 ms ") == 1200 && duration.parsed("45") == 45, "letters, spaces and commas are stripped from a typed duration")
        check(duration.parsed("0.5") == 1 && duration.parsed("0.4") == 0, "a duration rounds to whole milliseconds")
        check(duration.parsed("garbage") == nil && duration.parsed("") == nil && duration.parsed("-") == nil && duration.parsed(".") == nil, "nothing numeric parses to nothing")
        check(duration.parsed("9999") == 1500 && duration.parsed("-20") == 0, "a typed duration clamps to 0–1500 ms")
        check(duration.text(300) == "300ms" && duration.text(0) == "0ms" && duration.parsed(duration.text(1500)) == 1500, "a duration shows its unit right after the number, and reads back")
        let delay = ClipboardTunerSpec.seconds("Hover delay", maximum: 2, standard: 0.35)
        check(delay.parsed("0.35s") == 0.35 && delay.parsed("0.2.3") == 0.2 && delay.parsed("7") == 2 && delay.parsed("-0.5") == 0, "a delay keeps one point and clamps to 0–2 s")
        check(delay.parsed("0,5") == 0.5 && delay.parsed("1,25s") == 1.25 && delay.parsed(",") == nil && delay.parsed("0,5.3") == 0.5, "a comma is the point in a delay")
        check(delay.text(0.35) == "0.35s" && delay.text(0.5) == "0.5s" && delay.text(2) == "2s" && delay.text(0) == "0s" && delay.parsed(delay.text(0.35)) == 0.35,
              "a delay shows no trailing zeros, the unit right after the number, and reads back")
        check(delay.accessibilityLabel == "Hover delay in seconds" && delay.symbol == "clock", "a delay is named in seconds and wears the duration's clock")
        check(delay.clamped(0.004) == 0 && delay.clamped(0.005) == 0.01 && delay.clamped(.nan) == 0.35 && duration.clamped(.infinity) == 300, "values round to the shown digits; not-a-number takes the default")
        check(duration.nudged(300, by: 1, large: false) == 310 && duration.nudged(300, by: -1, large: true) == 200 && duration.nudged(1495, by: 1, large: false) == 1500, "arrows step 10 ms, Shift ten times that, within range")
        check(delay.nudged(0.35, by: 1, large: false) == 0.4 && delay.nudged(0.35, by: -1, large: true) == 0 && delay.nudged(1.98, by: 1, large: false) == 2,
              "a delay steps by a twentieth of a second, Shift by half a second, within range")
        check(duration.decimals == 0 && delay.decimals == 2, "the shown digits follow the step: none for 10 ms, two for 0.05 s")
        let speed = ClipboardTunerSpec(label: "Time multiplier", accessibilityLabel: "Time multiplier", unit: "×", minimum: 0, maximum: 60, step: 0.05, defaultValue: 1, symbol: "speedometer", glyph: "×")
        let doubling = ClipboardTunerSpec(label: "Seconds per doubling", accessibilityLabel: "Seconds per doubling", unit: "s", minimum: 10, maximum: 300, step: 1, defaultValue: 163, symbol: "clock", glyph: "◷")
        let phase = ClipboardTunerSpec(label: "Moment in the loop", accessibilityLabel: "Moment in the loop", unit: "", minimum: 0, maximum: 1, step: 0.001, defaultValue: 0, symbol: "clock", glyph: "◷")
        check(speed.text(1.43) == "1.43×" && speed.text(2) == "2×" && doubling.text(163) == "163s" && phase.decimals == 3 && phase.text(0.125) == "0.125" && phase.text(0.5) == "0.5",
              "steps set the digits shown: 1.43×, 2×, 163s, 0.125")
        check(duration.scrubbed(from: 300, points: 25) == 550 && duration.scrubbed(from: 300, points: -40) == 0 && delay.scrubbed(from: 0.35, points: 10) == 0.85,
              "a drag counts one step per point, right is up, within range")
    }

    private static func testHistory() {
        var history = ClipboardTunerHistory(current: 300)
        check(!history.canUndo && !history.canRedo, "a fresh history has nothing to undo or redo")
        history.submit(300)
        check(!history.canUndo, "an equal value is no step")
        history.submit(500)
        history.submit(700)
        check(history.current == 700 && history.canUndo && !history.canRedo, "each new value is a step")
        check(history.undo() && history.current == 500 && history.canRedo, "undo returns the previous value and opens redo")
        check(history.undo() && history.current == 300 && !history.canUndo && !history.undo(), "undo stops at the first value")
        check(history.redo() && history.current == 500 && history.redo() && history.current == 700 && !history.redo(), "redo walks forward and stops")
        _ = history.undo()
        history.submit(900)
        check(history.current == 900 && !history.canRedo, "a new value clears redo")
        history.submit(910)
        history.amend(920)
        history.amend(930)
        check(history.current == 930 && history.undo() && history.current == 900, "amended values stay one step")
        _ = history.redo()
        history.submit(940)
        history.amend(930)
        check(!history.canUndo == false && history.current == 930, "amending onward keeps the step")
        history.amend(900)
        check(history.current == 900 && history.past == [300, 500], "amending back to the value before the step dissolves the step")
        history.submit(1000)
        _ = history.undo()
        history.load(123)
        check(history.current == 123 && history.past == [300, 500] && history.undone == [1000], "a loaded value changes nothing about the steps")
    }

    private static func testPersistence() {
        let suite = ClipboardMaterializer.privateSuiteName("ClipEdge-tuner-tests-")
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ClipboardRevealSettings(defaults: defaults)
        check(settings.drawerMotion(for: .opening) == .standard && settings.drawerMotion(for: .closing) == .standard, "fresh settings slide as before: 300 ms")
        let opening = ClipboardDrawerMotionProfile(duration: 0.5)
        settings.setDrawerMotion(opening, for: .opening)
        check(settings.drawerMotion(for: .opening) == opening && settings.drawerMotion(for: .closing) == .standard, "opening leaves closing alone")
        check(ClipboardRevealSettings(defaults: defaults).drawerMotion(for: .opening) == opening, "a direction's motion survives relaunch")
        settings.setDrawerMotion(ClipboardDrawerMotionProfile(duration: 9), for: .closing)
        check(settings.drawerMotion(for: .closing) == ClipboardDrawerMotionProfile(duration: 1.5), "duration caps at 1.5 s")
        settings.setDrawerMotion(ClipboardDrawerMotionProfile(duration: -1), for: .closing)
        check(settings.drawerMotion(for: .closing) == ClipboardDrawerMotionProfile(duration: 0), "a duration cannot be negative")
        settings.setDrawerMotion(ClipboardDrawerMotionProfile(duration: .nan), for: .closing)
        check(settings.drawerMotion(for: .closing) == .standard, "a duration that is not a number takes the standard")
        let expectedKeys: Set<String> = ["ClipEdgeDrawerOpeningDuration", "ClipEdgeDrawerClosingDuration"]
        var stored = defaults.persistentDomain(forName: suite) ?? [:]
        check(Set(stored.keys) == expectedKeys, "only the two current durations are stored, one key each; no ease (\(stored.keys.sorted()))")
        settings.setDrawerMotion(ClipboardDrawerMotionProfile(duration: 0.1), for: .opening)
        settings.setDrawerMotion(ClipboardDrawerMotionProfile(duration: 0.2), for: .opening)
        stored = defaults.persistentDomain(forName: suite) ?? [:]
        check(Set(stored.keys) == expectedKeys && defaults.double(forKey: "ClipEdgeDrawerOpeningDuration") == 0.2,
              "repeated changes keep only the current values; no undo history reaches the preferences")
        // An ease saved by an earlier build is neither read nor written: the slide is the soft one again.
        defaults.set(0.25, forKey: "ClipEdgeDrawerOpeningEase")
        let stale = ClipboardRevealSettings(defaults: defaults)
        check(stale.drawerMotion(for: .opening) == ClipboardDrawerMotionProfile(duration: 0.2), "a stored ease changes nothing")
        stale.setDrawerMotion(ClipboardDrawerMotionProfile(duration: 0.4), for: .opening)
        check(defaults.double(forKey: "ClipEdgeDrawerOpeningEase") == 0.25 && defaults.object(forKey: "ClipEdgeDrawerClosingEase") == nil, "and is never written")
        defaults.removeObject(forKey: "ClipEdgeDrawerOpeningEase")
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(forName: ClipboardRevealSettings.didChange, object: settings, queue: nil) { _ in notifications += 1 }
        settings.setDrawerMotion(ClipboardDrawerMotionProfile(duration: 0.2), for: .opening)
        settings.setDrawerMotion(ClipboardDrawerMotionProfile(duration: 0.3), for: .opening)
        NotificationCenter.default.removeObserver(observer)
        check(notifications == 1, "an unchanged motion is silent; a changed one notifies the shared consumers")
        defaults.set("slow", forKey: "ClipEdgeDrawerOpeningDuration")
        check(ClipboardRevealSettings(defaults: defaults).drawerMotion(for: .opening) == .standard, "an unreadable stored duration normalizes at load")
        let fixture = ClipboardRevealSettings(defaults: nil)
        fixture.setDrawerMotion(ClipboardDrawerMotionProfile(duration: 0.4), for: .closing)
        check(fixture.drawerMotion(for: .closing) == ClipboardDrawerMotionProfile(duration: 0.4) && fixture.drawerMotion(for: .opening) == .standard,
              "a fixture with no preferences keeps its motion in memory")
    }

    private static func testMotion() {
        var now: TimeInterval = 0
        let motion = ClipboardDrawerMotion(clock: { now })
        var profiles: [ClipboardDrawerDirection: ClipboardDrawerMotionProfile] = [
            .opening: ClipboardDrawerMotionProfile(duration: 1), .closing: ClipboardDrawerMotionProfile(duration: 0.4)]
        motion.profiles = { profiles[$0]! }
        /// The one curve: smoothstep, soft at both ends.
        func soft(_ progress: Double) -> Double { progress * progress * (3 - 2 * progress) }
        motion.move(to: 1, animated: true)
        now = 0.25; motion.advance(at: now)
        check(motion.fraction == CGFloat(soft(0.25)) && motion.fraction < 0.25, "the slide starts softly: behind a steady pace a quarter of the way into the opening time")
        now = 0.5; motion.advance(at: now)
        check(motion.fraction == 0.5, "the opening uses its own duration")
        profiles[.opening] = ClipboardDrawerMotionProfile(duration: 0.1)
        now = 0.75; motion.advance(at: now)
        check(motion.fraction == CGFloat(soft(0.75)) && motion.isAnimating, "a slide under way keeps the values it started with")
        let reversedFrom = motion.fraction
        motion.move(to: 0, animated: true)
        check(motion.fraction == reversedFrom && motion.isAnimating, "a reversal starts from where it is")
        now = 0.9; motion.advance(at: now)
        let travel = 0.4 * Double(reversedFrom)
        check(abs(motion.fraction - reversedFrom * CGFloat(1 - soft(0.15 / travel))) < 1e-9, "closing slides softly through the remaining travel with its own duration")
        now = 0.75 + travel + 0.01; motion.advance(at: now)
        check(!motion.isAnimating && motion.fraction == 0, "the reversed slide ends closed when its own duration is up")
        // The curve the drawer has always had, bit for bit: the formula it shipped with, computed here as it was.
        profiles[.opening] = .standard
        now = 10; motion.move(to: 1, animated: true)
        for step in 1...29 {
            now = 10 + Double(step) * 0.01; motion.advance(at: now)
            let progress = min(1, max(0, (now - 10) / (0.3 * 1)))
            let former = 0 + (1 - 0) * CGFloat(progress * progress * (3 - 2 * progress))
            check(motion.fraction == former, "the slide is the former smoothstep bit for bit at step \(step)")
        }
        now = 10.31; motion.advance(at: now)
        check(!motion.isAnimating && motion.fraction == 1, "the standard opening still takes 300 ms")
        profiles[.opening] = ClipboardDrawerMotionProfile(duration: 0)
        motion.move(to: 0, animated: false)
        motion.move(to: 1, animated: true)
        check(!motion.isAnimating && motion.fraction == 1, "a 0 ms opening is at once")
        profiles[.closing] = ClipboardDrawerMotionProfile(duration: 1.5)
        motion.move(to: 0, animated: false)
        check(!motion.isAnimating && motion.fraction == 0, "Reduce Motion is still immediate, whatever the closing duration")
        let standard = ClipboardDrawerMotion(clock: { now })
        standard.move(to: 1, animated: true)
        now += 0.15; standard.advance(at: now)
        check(abs(standard.fraction - 0.5) < 0.001, "a motion given no profiles slides as before")
    }

    /// The editing chords every ClipEdge window routes to the field being edited.
    private static func testRouting() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 40), styleMask: [.titled], backing: .buffered, defer: false)
        let chords: [(String, NSEvent.ModifierFlags, UInt16, ClipboardFieldEditing.Command?)] = [
            ("a", [.command], 0, .selectAll), ("c", [.command], 8, .copy), ("x", [.command], 7, .cut), ("v", [.command], 9, .paste),
            ("z", [.command], 6, .undo), ("Z", [.command, .shift], 6, .redo), ("a", [.option, .command], 0, nil), ("a", [], 0, nil),
            ("z", [.control, .command], 6, nil), ("r", [.option, .command], 15, nil)]
        for (characters, modifiers, code, expected) in chords {
            check(ClipboardFieldEditing.command(for: key(characters, modifiers, code: code, window: panel)) == expected, "\(modifiers) \(characters) is \(String(describing: expected))")
        }
        check(!ClipboardFieldEditing.perform(key("a", [.command], code: 0, window: panel), in: panel), "with no field being edited, the chords pass on")
    }


    private static func testControl() {
        var now: TimeInterval = 50
        let tuner = ClipboardTuner(spec: .duration("Opening duration", standard: 300), clock: { now })
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        let content = panel.contentView!
        content.addSubview(tuner)
        NSLayoutConstraint.activate([tuner.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
                                     tuner.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
                                     tuner.topAnchor.constraint(equalTo: content.topAnchor, constant: 10)])
        let layer = ClipboardTunerMagnetLayer.lay([tuner], over: content)
        content.layoutSubtreeIfNeeded()
        func rect(_ view: NSView) -> NSRect { view.convert(view.bounds, to: content) }
        var changes: [Double] = []
        tuner.onChange = { changes.append($0) }
        check(tuner.value == 300 && tuner.entry.stringValue == "300ms" && !tuner.magnetsRevealed, "a tuner starts at its default with nothing showing but the number")
        check(!tuner.hasAmbiguousLayout && !tuner.undoMagnet.hasAmbiguousLayout && !tuner.redoMagnet.hasAmbiguousLayout && !tuner.hoverRegion.hasAmbiguousLayout,
              "the tuner's layout is settled, its magnets and hover region too")

        // The tuner's field: label above, then a 22-point field of handle, hairline and number.
        let field = rect(tuner.field), handle = rect(tuner.handle), divider = rect(tuner.divider), entry = rect(tuner.entry), label = rect(tuner.titleLabel)
        check(label.minY >= field.maxY && label.minY <= field.maxY + 4, "the label sits just above the field (\(label.minY - field.maxY) points)")
        check(field.height == ClipboardTuner.fieldHeight && tuner.field.surface.radius == 6, "the field is 22 points tall with 6-point corners")
        check(handle.minX == field.minX && handle.width == ClipboardTuner.handleWidth && divider.minX == handle.maxX && divider.width == 1 && divider.height == field.height,
              "the field reads handle, a hairline, then the number")
        check(tuner.divider.surface.fill?.color == .separatorColor, "the hairline is the separator color")
        check(entry.minX > divider.maxX && entry.maxX >= field.maxX - 8, "the number takes the rest of the field's width; nothing inside the field is kept for buttons")
        let undo = rect(tuner.undoMagnet), redo = rect(tuner.redoMagnet), bounds = rect(tuner)
        let labelHeight = aligned(tuner.titleLabel, in: content).height
        check(abs(bounds.height - (labelHeight + ClipboardTuner.labelGap + ClipboardTuner.fieldHeight)) < 0.5,
              "the tuner is its label, 2 points, then the 22-point field: no room kept for magnets (\(bounds.height) points, label \(labelHeight))")
        check(abs(undo.maxX - field.maxX) < 0.5 && abs(undo.minY - field.maxY - ClipboardTuner.magnetGap) < 0.5,
              "Undo's magnet sits 9 points above the field, its right edge on the field's (\(undo), field \(field))")
        check(abs(redo.maxX - (undo.minX - ClipboardTuner.magnetSpacing)) < 0.5 && redo.minY == undo.minY && redo.height == undo.height,
              "Redo's magnet sits just left of Undo's, on the same line and as close to the field")
        check(tuner.undoMagnet.superview === layer && tuner.redoMagnet.superview === layer && content.subviews.last === layer && tuner.group == [tuner],
              "the magnets live in one layer laid over the controls, above every one of them; the tuners in it are the group")
        check(undo.maxY > bounds.maxY + 1 && redo.maxY == undo.maxY, "the magnets reach above the tuner's top, out of its layout (\(undo.maxY - bounds.maxY) points)")
        let region = rect(tuner.hoverRegion)
        check(near(region, bounds.union(undo).union(redo)) && region.contains(aligned(tuner.titleLabel, in: content)) && region.contains(field),
              "one hover region holds label, field and both magnets, so the pointer crosses the 9-point gap without leaving (\(region))")
        check(tuner.hoverRegion.pointerOwner === tuner && tuner.hoverRegion.hitTest(NSPoint(x: 1, y: 1)) == nil && layer.hitTest(NSPoint(x: undo.midX, y: undo.midY)) == nil,
              "the region tells the tuner when the pointer comes and goes; neither it nor the layer, nor a hidden magnet, takes a press")
        check(!aligned(tuner.titleLabel, in: content).intersects(undo) && !aligned(tuner.titleLabel, in: content).intersects(redo)
              && abs(aligned(tuner.titleLabel, in: content).maxX - (redo.minX - ClipboardTuner.labelClearance)) < 0.5,
              "the label ends 8 points short of the magnets' slots")
        // A press anywhere on the handle, its symbol included, is the handle's, and scrubs even in a window that is not key.
        func hit(_ point: NSPoint) -> NSView? { content.hitTest(content.convert(point, to: content.superview)) }
        for point in [NSPoint(x: handle.midX, y: handle.midY), NSPoint(x: handle.minX + 2, y: handle.maxY - 2)] {
            check(hit(point) === tuner.handle && tuner.handle.acceptsFirstMouse(for: nil), "a press on the handle at \(point) is the handle's, and its first press scrubs")
        }
        check(hit(NSPoint(x: entry.midX, y: entry.midY)) !== tuner.handle, "past the handle, the number takes the press")

        // Tab or a click in selects the number; Return keeps it and selects it again.
        panel.makeFirstResponder(tuner.entry)
        guard let editor = tuner.entry.currentEditor() as? NSTextView else { fatalError("FAIL: the number takes the keyboard") }
        check(editor.selectedRange() == whole(tuner.entry), "Tab into the number selects its text")
        check(!tuner.magnetsRevealed && tuner.field.surface.rim == .controlAccentColor, "the keyboard in the number tints the whole field's border; with nothing to undo, no magnet shows")
        tuner.entry.stringValue = "450ms"
        check(tuner.control(tuner.entry, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))), "Return is the tuner's")
        check(tuner.value == 450 && tuner.entry.stringValue == "450ms" && changes == [450], "Return keeps a typed value, letters stripped, and shows the unit again")
        check(editor.selectedRange() == whole(tuner.entry) && panel.firstResponder === editor, "Return selects the number again and the keyboard stays")
        check(!tuner.undoMagnet.isHidden && tuner.redoMagnet.isHidden, "focus reveals undo once there is something to undo, and no redo yet")
        tuner.entry.stringValue = "fast"
        _ = tuner.control(tuner.entry, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        check(tuner.value == 450 && tuner.entry.stringValue == "450ms" && changes == [450], "text without a number changes nothing and is put back")
        now = 100; _ = tuner.control(tuner.entry, textView: editor, doCommandBy: #selector(NSResponder.moveUp(_:)))
        check(editor.selectedRange() == whole(tuner.entry), "an arrow press selects the number again")
        now = 100.5; _ = tuner.control(tuner.entry, textView: editor, doCommandBy: #selector(NSResponder.moveUp(_:)))
        now = 100.9; _ = tuner.control(tuner.entry, textView: editor, doCommandBy: #selector(NSResponder.moveUpAndModifySelection(_:)))
        check(tuner.value == 570 && changes == [450, 460, 470, 570], "each arrow press applies: up by 10 ms, Shift-up by 100 ms")
        check(tuner.history.past == [300, 450], "presses within a second are one undo step")
        now = 102; _ = tuner.control(tuner.entry, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:)))
        check(tuner.value == 560 && tuner.history.past == [300, 450, 570], "a press after a second starts a new step")
        tuner.entry.stringValue = "1000"
        now = 104; _ = tuner.control(tuner.entry, textView: editor, doCommandBy: #selector(NSResponder.moveDownAndModifySelection(_:)))
        check(tuner.value == 460 && tuner.entry.stringValue == "460ms" && tuner.history.past == [300, 450, 570, 560],
              "an arrow steps from the kept value and puts it back in place of the typed draft")
        let commandZ = key("z", [.command], code: 6, window: panel)
        let shiftCommandZ = key("Z", [.command, .shift], code: 6, window: panel)
        check(tuner.performKeyEquivalent(with: commandZ) && tuner.value == 560 && !tuner.redoMagnet.isHidden && !tuner.undoMagnet.isHidden, "Command-Z undoes the last step and shows redo")
        check(tuner.performKeyEquivalent(with: shiftCommandZ) && tuner.value == 460 && tuner.redoMagnet.isHidden, "Shift-Command-Z redoes it")
        tuner.undo(); tuner.undo()
        check(tuner.value == 570 && tuner.history.canRedo && changes.suffix(2) == [560, 570], "every undo is reported to the owner")
        tuner.submit(500)
        check(tuner.value == 500 && !tuner.history.canRedo && tuner.redoMagnet.isHidden, "a new value clears redo")
        _ = tuner.undoButton.sendAction(tuner.undoButton.action, to: tuner.undoButton.target)
        check(tuner.value == 570 && !tuner.redoMagnet.isHidden, "the undo magnet undoes and shows redo")
        _ = tuner.redoButton.sendAction(tuner.redoButton.action, to: tuner.redoButton.target)
        check(tuner.value == 500 && tuner.redoMagnet.isHidden, "the redo magnet redoes")
        check(tuner.undoButton.refusesFirstResponder && tuner.redoButton.refusesFirstResponder && !tuner.undoMagnet.acceptsFirstResponder && !tuner.redoMagnet.acceptsFirstResponder,
              "the magnets take clicks but are not Tab stops; their chords reach them")

        // Esc puts the number back and leaves in one press; a click comes back in with the number selected.
        tuner.entry.stringValue = "999"
        check(tuner.control(tuner.entry, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))), "Esc is the tuner's")
        check(tuner.entry.stringValue == "500ms" && tuner.value == 500 && tuner.entry.currentEditor() == nil && panel.firstResponder === panel,
              "Esc puts the old number back and leaves the field in one press")
        check(!tuner.magnetsRevealed && tuner.field.surface.rim == .separatorColor, "leaving the number hides the magnets and its border's tint")
        check(!tuner.performKeyEquivalent(with: commandZ) && tuner.value == 500, "Command-Z belongs to whichever control has the keyboard")
        click(tuner.entry)
        guard let clicked = tuner.entry.currentEditor() as? NSTextView else { fatalError("FAIL: a click puts the keyboard in the number") }
        check(clicked.selectedRange() == whole(tuner.entry), "a click into the number selects its text, as Tab does")
        check(tuner.field.surface.rim == .controlAccentColor, "a click into the number tints the field's border, as Tab does")
        check(!tuner.undoMagnet.isHidden && tuner.redoMagnet.isHidden && tuner.magnetsRevealed, "the clicked number shows undo, with a step to take, without hover")
        check(tuner.performKeyEquivalent(with: commandZ) && tuner.value == 570 && !tuner.redoMagnet.isHidden, "⌘Z reaches the number clicked into, and redo shows")
        check(tuner.performKeyEquivalent(with: shiftCommandZ) && tuner.value == 500, "and ⇧⌘Z")
        click(tuner.entry)
        check(tuner.entry.currentEditor() === clicked && clicked.selectedRange().length == 0 && clicked.selectedRange().location > 0,
              "a click while the number is being edited places the caret, as in a browser (\(clicked.selectedRange()))")
        panel.makeFirstResponder(nil)
        check(tuner.field.surface.rim == .separatorColor && !tuner.magnetsRevealed, "leaving after a click puts the border and magnets back to rest")
        clickAfterFocus(tuner.entry)
        check((tuner.entry.currentEditor() as? NSTextView)?.selectedRange() == whole(tuner.entry) && tuner.field.surface.rim == .controlAccentColor,
              "a click selects the number even when the window gives it the keyboard before handing it the press")
        tuner.entry.stringValue = "600"
        panel.makeFirstResponder(nil)
        check(tuner.value == 600 && tuner.entry.stringValue == "600ms", "leaving the number keeps what was typed")

        // Revealing a magnet moves nothing, and each magnet keeps its own slot.
        content.layoutSubtreeIfNeeded()
        let frames = { [tuner, tuner.field, tuner.entry, tuner.titleLabel, tuner.handle, tuner.divider, tuner.undoMagnet, tuner.redoMagnet, tuner.hoverRegion, layer].map(rect) }
        let atRest = frames()
        tuner.mouseEntered(with: hover(true, window: panel))
        content.layoutSubtreeIfNeeded()
        check(tuner.magnetsRevealed && !tuner.undoMagnet.isHidden && tuner.redoMagnet.isHidden && frames() == atRest, "hovering shows undo without moving the field, its number, its label or its handle")
        tuner.undoMagnet.mouseEntered(with: hover(true, window: panel))
        check(tuner.magnetsRevealed && tuner.undoMagnet.surface.rim == .controlAccentColor && tuner.undoMagnet.surface.fill?.color == .controlAccentColor,
              "a hovered magnet stays shown and takes the accent")
        // A press on a magnet's part above the tuner's top still reaches it.
        let kept = tuner.value
        let undoHit = clickButton(at: NSPoint(x: undo.midX, y: (bounds.maxY + undo.maxY) / 2), in: content)
        check(undoHit === tuner.undoButton && tuner.value != kept && tuner.history.canRedo && !tuner.redoMagnet.isHidden,
              "a click on ↺ above the tuner's top undoes (\(undoHit.map { String(describing: Swift.type(of: $0)) } ?? "nothing"))")
        let redoHit = clickButton(at: NSPoint(x: redo.midX, y: (bounds.maxY + redo.maxY) / 2), in: content)
        check(redoHit === tuner.redoButton && tuner.value == kept && frames() == atRest, "and a click on ↻ there redoes; nothing moved")
        tuner.undoMagnet.mouseExited(with: hover(false, window: panel))
        check(tuner.undoMagnet.surface.fill?.color == .windowBackgroundColor && tuner.undoMagnet.surface.rim == .separatorColor, "and gives it back: a card's ground and rim")
        tuner.undo(); tuner.undo(); tuner.undo(); tuner.undo(); tuner.undo()
        content.layoutSubtreeIfNeeded()
        check(!tuner.history.canUndo && tuner.undoMagnet.isHidden && !tuner.redoMagnet.isHidden && frames() == atRest,
              "undone to the first value, redo shows alone in its own slot; nothing slides into Undo's place")
        while tuner.history.canRedo { tuner.redo() }
        tuner.mouseExited(with: hover(false, window: panel))
        check(!tuner.magnetsRevealed, "leaving hides them again")

        // A drag applies as it moves, and is one undo step when let go.
        changes = []
        let past = tuner.history.past
        tuner.handle.mouseEntered(with: hover(true, window: panel))
        check(tuner.handle.surface.fill?.color == .controlAccentColor && tuner.handle.surface.fill?.opacity == 0.18, "a hovered handle takes the accent tint")
        tuner.handle.mouseDown(with: mouse(.leftMouseDown, x: 20, window: panel))
        check(tuner.handle.isDragging, "pressing the handle starts a drag")
        tuner.handle.mouseDragged(with: mouse(.leftMouseDragged, x: 45, window: panel))
        check(tuner.entry.stringValue == "850ms" && tuner.value == 850 && changes == [850] && tuner.history.past == past, "each move applies at once; the history waits")
        tuner.handle.mouseDragged(with: mouse(.leftMouseDragged, x: 30, window: panel))
        tuner.handle.mouseDragged(with: mouse(.leftMouseDragged, x: 30, window: panel))
        check(tuner.entry.stringValue == "700ms" && changes == [850, 700], "dragging back lowers it from where the drag began; a move that changes nothing applies nothing")
        tuner.load(700)
        check(tuner.value == 700 && tuner.history.past == past, "the owner's echo of a live value changes nothing mid-drag")
        tuner.handle.mouseUp(with: mouse(.leftMouseUp, x: 45, window: panel))
        check(!tuner.handle.isDragging && tuner.value == 850 && tuner.history.past == past + [600] && changes.last == 850, "letting go keeps the value as one undo step")
        tuner.undo()
        check(tuner.value == 600 && changes.last == 600, "one undo takes the whole drag back")
        tuner.handle.mouseDown(with: mouse(.leftMouseDown, x: 20, window: panel))
        tuner.handle.mouseDragged(with: mouse(.leftMouseDragged, x: 40, window: panel))
        tuner.handle.mouseUp(with: mouse(.leftMouseUp, x: 20, window: panel))
        check(tuner.value == 600 && tuner.history.past == past && changes.suffix(2) == [800, 600], "a drag that ends where it began applies the value back and records no step")
        tuner.handle.mouseExited(with: hover(false, window: panel))

        tuner.load(123)
        check(tuner.value == 123 && tuner.entry.stringValue == "123ms" && changes.last == 600, "a loaded value shows with nothing new to undo and is not reported back")
        check(tuner.undoButton.title == "↺ ⌘Z" && tuner.redoButton.title == "↻ ⇧⌘Z", "each magnet shows its glyph and chord")
        check(tuner.undoButton.frame.width >= tuner.undoButton.intrinsicContentSize.width && tuner.redoButton.frame.width >= tuner.redoButton.intrinsicContentSize.width,
              "each magnet is as wide as its whole label")
        check(tuner.undoButton.accessibilityLabel()?.contains("Command–Z") == true && tuner.redoButton.accessibilityLabel()?.contains("Shift–Command–Z") == true, "each magnet names its chord to VoiceOver")
        check(tuner.entry.accessibilityLabel() == "Opening duration in milliseconds" && tuner.entry.accessibilityValue() == "123ms", "the number is accessibly named with its unit")
        check(tuner.entry.focusRingType != .none && tuner.accessibilityLabel() == "Opening duration", "the number keeps a focus ring around the field; the tuner is a named group")
    }


    /// A press that changes nothing opens no step, and a step that returns to where it began is gone:
    /// the next press, however soon, is its own step, so a way back always exists.
    private static func testLimit() {
        var now: TimeInterval = 50
        let tuner = ClipboardTuner(spec: .seconds("Hover delay", maximum: 2, standard: 2), clock: { now })
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        panel.contentView!.addSubview(tuner)
        panel.makeFirstResponder(tuner.entry)
        guard let editor = tuner.entry.currentEditor() as? NSTextView else { fatalError("FAIL: the number takes the keyboard") }
        let up = #selector(NSResponder.moveUp(_:)), down = #selector(NSResponder.moveDown(_:)), bigDown = #selector(NSResponder.moveDownAndModifySelection(_:))
        now = 50; _ = tuner.control(tuner.entry, textView: editor, doCommandBy: up)
        check(tuner.value == 2 && !tuner.history.canUndo, "an arrow at the maximum changes nothing and records nothing")
        now = 50.4; _ = tuner.control(tuner.entry, textView: editor, doCommandBy: down)
        check(tuner.value == 1.95 && tuner.history.past == [2] && !tuner.undoButton.isHidden, "the next press within a second is its own step, back from the maximum")
        now = 50.7; _ = tuner.control(tuner.entry, textView: editor, doCommandBy: up)
        check(tuner.value == 2 && !tuner.history.canUndo, "returning to where the step began leaves no step")
        now = 50.9; for _ in 1...12 { _ = tuner.control(tuner.entry, textView: editor, doCommandBy: bigDown); now += 0.1 }
        check(tuner.value == 0 && tuner.history.past == [2], "a held key after that is one step, from where the value last stood")
        tuner.undo()
        check(tuner.value == 2 && tuner.history.canRedo, "undo returns to the maximum")
    }

    /// Labels wrap, never truncate, and never run under the magnets.
    private static func testWrapping() {
        let spec = ClipboardTunerSpec(label: "A label long enough that it has to wrap onto more than one line", accessibilityLabel: "A long label",
                                      unit: "ms", minimum: 0, maximum: 1500, step: 10, defaultValue: 300, symbol: "clock", glyph: "◷")
        let tuner = ClipboardTuner(spec: spec)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 140), styleMask: [.titled], backing: .buffered, defer: false)
        let content = panel.contentView!
        content.addSubview(tuner)
        NSLayoutConstraint.activate([tuner.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
                                     tuner.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
                                     tuner.topAnchor.constraint(equalTo: content.topAnchor, constant: 10)])
        ClipboardTunerMagnetLayer.lay([tuner], over: content)
        content.layoutSubtreeIfNeeded()
        func rect(_ view: NSView) -> NSRect { view.convert(view.bounds, to: content) }
        let label = tuner.titleLabel
        let needed = label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.frame.width, height: .greatestFiniteMagnitude)).height
        check(needed > 20 && label.frame.height >= needed - 0.5 && label.cell?.truncatesLastVisibleLine != true && label.lineBreakMode == .byWordWrapping,
              "a long label wraps onto more lines with every word shown (\(label.frame.height) of \(needed) points)")
        check(!tuner.hasAmbiguousLayout && rect(tuner).contains(aligned(label, in: content)) && rect(label).minY >= rect(tuner.field).maxY && rect(tuner.field).height == ClipboardTuner.fieldHeight,
              "the tuner grows upward to hold it; the field keeps its height below")
        check(!rect(label).intersects(rect(tuner.undoMagnet)) && !rect(label).intersects(rect(tuner.redoMagnet))
              && abs(rect(tuner).height - (aligned(label, in: content).height + ClipboardTuner.labelGap + ClipboardTuner.fieldHeight)) < 0.5,
              "a wrapped label still keeps clear of the magnets, and the tuner is still just label and field")
    }


    private static func testSettings(in name: NSAppearance.Name) {
        let app = NSApplication.shared
        app.appearance = NSAppearance(named: name)
        let dark = name == .darkAqua
        let moment = dark ? "dark" : "light"
        let settings = ClipboardRevealSettings(defaults: nil)
        settings.mode = .delayed
        settings.dismissalDelaySeconds = 1.2
        settings.setDrawerMotion(ClipboardDrawerMotionProfile(duration: 0.45), for: .closing)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let controller = ClipboardRevealSettingsController(settings: settings, pasteboard: board)
        let window = controller.window!
        let content = window.contentView!
        let tuners = controller.tuners
        let (delay, dismissal, opening, closing) = (tuners[0], tuners[1], tuners[2], tuners[3])
        let views = descendants(content)
        func rect(_ view: NSView) -> NSRect { view.convert(view.bounds, to: content) }
        func text(_ prefix: String) -> NSTextField { views.compactMap { $0 as? NSTextField }.first { $0.stringValue.hasPrefix(prefix) }! }
        check(tuners.map(\.spec.label) == ["Hover delay", "Maximum close delay", "Opening duration", "Closing duration", "Text size", "Thumbnail size", "Preview size"]
              && controller.motionTuners == [opening, closing] && controller.sizeTuners == Array(tuners.suffix(3)),
              "\(moment): seven fields, the hover delay, the close delay, the slide opening and closing, then the three sizes")
        check(tuners.map(\.value) == [0.35, 1.2, 300, 450, 100, 100, 100] && tuners.map(\.entry.stringValue) == ["0.35s", "1.2s", "300ms", "450ms", "100%", "100%", "100%"]
              && tuners.allSatisfy { !$0.history.canUndo },
              "\(moment): saved values show with nothing to undo, the unit right after the number")
        check(delay.entry.accessibilityLabel() == "Hover delay in seconds" && dismissal.entry.accessibilityLabel() == "Maximum close delay in seconds"
              && [delay, dismissal].allSatisfy { $0.spec.symbol == opening.spec.symbol && $0.spec.step == 0.05 } && delay.spec.maximum == 2 && dismissal.spec.maximum == 3,
              "\(moment): each delay is named in seconds, 0–2 s and 0–3 s in twentieths, with the duration's clock")
        check(!views.contains { $0 is NSSlider } && !views.compactMap { $0 as? NSTextField }.contains { $0.stringValue.hasSuffix(" seconds") }
              && views.compactMap { $0 as? NSTextField }.filter { $0.stringValue == "Hover delay" || $0.stringValue == "Maximum close delay" }.count == 2,
              "\(moment): no slider and no value at the right are left; each delay's name is its field's label")
        content.layoutSubtreeIfNeeded()
        settle()
        let document = content.subviews.compactMap { $0 as? NSScrollView }.first!.documentView!
        let layer = document.subviews.last as? ClipboardTunerMagnetLayer
        check(layer != nil && layer?.tuners == tuners && tuners.allSatisfy { $0.undoMagnet.superview === layer && $0.redoMagnet.superview === layer && $0.group == tuners },
              "\(moment): every field's magnets share one layer over everything in Settings, and the four share ⌘Z")
        for tuner in tuners {
            let frame = rect(tuner)
            check(!tuner.hasAmbiguousLayout && frame.width > 150 && frame.height > ClipboardTuner.fieldHeight + 12 && content.bounds.contains(frame), "\(moment): \(tuner.spec.label) sits inside the window")
            let labelHeight = aligned(tuner.titleLabel, in: content).height
            let line = tuner.titleLabel.font!.boundingRectForFont.height
            check(labelHeight < line * 1.5 && abs(frame.height - (labelHeight + ClipboardTuner.labelGap + ClipboardTuner.fieldHeight)) < 0.5,
                  "\(moment): \(tuner.spec.label) is its label on one line, 2 points and its field, \(frame.height) points, with nothing kept for magnets")
            check(rect(tuner.undoMagnet).maxY > frame.maxY + 1 && abs(rect(tuner.undoMagnet).minY - rect(tuner.field).maxY - ClipboardTuner.magnetGap) < 0.5
                  && abs(rect(tuner.redoMagnet).maxX - (rect(tuner.undoMagnet).minX - ClipboardTuner.magnetSpacing)) < 0.5 && content.bounds.contains(rect(tuner.undoMagnet)),
                  "\(moment): \(tuner.spec.label)'s magnets sit 9 points above its field, reaching past its top, inside the window")
            check(near(rect(tuner.hoverRegion), frame.union(rect(tuner.undoMagnet)).union(rect(tuner.redoMagnet))), "\(moment): \(tuner.spec.label)'s hover region holds label, field and magnets")
            let longest = NSAttributedString(string: tuner.spec.text(tuner.spec.maximum), attributes: [.font: tuner.entry.font!]).size().width
            check(tuner.entry.frame.width >= longest + 4 && tuner.undoButton.frame.width >= tuner.undoButton.intrinsicContentSize.width &&
                  tuner.redoButton.frame.width >= tuner.redoButton.intrinsicContentSize.width,
                  "\(moment): \(tuner.spec.label)'s longest number (\(tuner.spec.text(tuner.spec.maximum))) and both magnet labels fit in full")
            let words = NSAttributedString(string: tuner.spec.label, attributes: [.font: tuner.titleLabel.font!]).size().width
            check(rect(tuner.titleLabel).minX + words + 2 <= rect(tuner.redoMagnet).minX && abs(rect(tuner.undoMagnet).maxX - rect(tuner.field).maxX) < 0.5,
                  "\(moment): \(tuner.spec.label)'s label ends clear of its magnets at Settings' width")
            check(isDark(tuner.field) == dark, "\(moment): AppKit gave \(tuner.spec.label)'s field the \(moment) appearance")
            check(same(tuner.field.layer?.backgroundColor, resolved(.controlBackgroundColor, in: name)), "\(moment): \(tuner.spec.label)'s field ground is the \(moment) one")
            let ground = luminance(tuner.field.layer?.backgroundColor)
            check(dark ? ground < 0.3 : ground > 0.9, "\(moment): \(tuner.spec.label)'s field reads \(moment) (\(ground))")
        }
        check(Set(tuners.map { rect($0).width }).count == 1 && Set(tuners.map { rect($0.field).height }).count == 1, "\(moment): every field is the same size")
        check(rect(delay).minX == rect(opening).minX && rect(dismissal).minX == rect(opening).minX && rect(opening).minY == rect(closing).minY && rect(opening).maxX < rect(closing).minX
              && rect(delay).minY > rect(dismissal).maxY && rect(dismissal).minY > rect(opening).maxY,
              "\(moment): each delay sits in the left column of its own row, above the slide's two fields, opening beside closing")
        // The magnets reach above a field's label: they stay clear of what sits above each row.
        let popup = views.compactMap { $0 as? NSPopUpButton }.first!
        check(rect(popup).minY - rect(delay.undoMagnet).maxY >= 2, "\(moment): the hover delay's magnets stay below the reveal menu (\(rect(popup).minY - rect(delay.undoMagnet).maxY) points)")
        for (above, row) in [(text("Close the drawer"), [dismissal]), (text("How long each slide"), [opening, closing])] {
            let ink = lowestInk(of: above, in: content) ?? .nan
            let clearance = ink - row.map { rect($0.undoMagnet).maxY }.max()!
            check(clearance > 0, "\(moment): the magnets under \"\(above.stringValue.prefix(20))\" stay clear of its text (\(clearance) points)")
        }
        check(text("How long each slide").stringValue == "How long each slide takes (0ms is at once). Drag a handle, type a number, or press ↑ and ↓ (⇧ for ten steps).",
              "\(moment): the slide is explained without an ease")
        let reset = views.compactMap { $0 as? ClipboardKeyedButton }.first { $0.keyedTitle.plain == "Reset ⌥⌘R" }!
        let recorder = views.compactMap { $0 as? ClipboardShortcutRecorder }.first { $0.actionName == "Quick Look" }!
        let sizes = controller.sizeTuners
        check(popup.nextKeyView === delay.keyView && delay.keyView.nextKeyView === dismissal.keyView && dismissal.keyView.nextKeyView === opening.keyView &&
              opening.keyView.nextKeyView === closing.keyView && closing.keyView.nextKeyView === sizes[0].keyView && sizes[0].keyView.nextKeyView === sizes[1].keyView
              && sizes[1].keyView.nextKeyView === sizes[2].keyView && sizes[2].keyView.nextKeyView === reset && reset.nextKeyView === recorder,
              "\(moment): Tab goes menu, hover delay, close delay, opening, closing, the three sizes, Reset, then the shortcuts; no magnet is a stop")
        check(reset.keyEquivalent == "r" && reset.keyEquivalentModifierMask == [.option, .command] && reset.accessibilityLabel()?.contains("Option–Command–R") == true
              && reset.toolTip?.contains("0.35s") == true && reset.toolTip?.contains("0.5s") == true && reset.toolTip?.contains("300ms") == true && reset.toolTip?.contains("100%") == true, "\(moment): Reset carries its chord and names every default")
        check(["Open the drawer", "Close the drawer", "Drawer motion", "Sizes"].allSatisfy { title in views.compactMap { $0 as? NSTextField }.contains { $0.stringValue == title } }
              && text("After opening from the screen edge").isHidden == false, "\(moment): each section keeps its heading and explanation")
        opening.submit(800)
        delay.submit(1)
        dismissal.submit(2.5)
        check(settings.drawerMotion(for: .opening) == ClipboardDrawerMotionProfile(duration: 0.8) && settings.drawerMotion(for: .closing) == ClipboardDrawerMotionProfile(duration: 0.45)
              && settings.delaySeconds == 1 && settings.dismissalDelaySeconds == 2.5, "\(moment): each field writes its own setting and nothing else")
        _ = reset.sendAction(reset.action, to: reset.target)
        check(tuners.map(\.value) == [0.35, 0.5, 300, 300, 100, 100, 100] && settings.delaySeconds == 0.35 && settings.dismissalDelaySeconds == 0.5
              && settings.drawerMotion(for: .opening) == .standard && settings.drawerMotion(for: .closing) == .standard, "\(moment): Reset returns every field to its default")
        check(tuners.prefix(4).allSatisfy { $0.history.canUndo } && sizes.allSatisfy { !$0.history.canUndo },
              "\(moment): each field that changed can undo the reset on its own; the sizes, already at 100%, have nothing to undo")
        closing.undo()
        check(closing.value == 450 && settings.drawerMotion(for: .closing) == ClipboardDrawerMotionProfile(duration: 0.45) && opening.value == 300 && delay.value == 0.35,
              "\(moment): undo after Reset restores that field alone")
        opening.submit(500)
        opening.undo()
        check(tuners.allSatisfy { !$0.magnetsRevealed }, "\(moment): the magnets are hidden at rest")
        content.layoutSubtreeIfNeeded()
        let frames = { tuners.flatMap { [$0, $0.field, $0.entry, $0.titleLabel, $0.undoMagnet, $0.redoMagnet, $0.hoverRegion].map(rect) } + [rect(reset), rect(layer!)] }
        let atRest = frames(), windowAtRest = window.frame
        closing.mouseEntered(with: hover(true, window: window))
        content.layoutSubtreeIfNeeded()
        check(closing.undoMagnet.isHidden && !closing.redoMagnet.isHidden && tuners.filter(\.magnetsRevealed).count == 1,
              "\(moment): hovering a field undone to its first value offers redo alone, and nobody else's magnets show")
        check(frames() == atRest && window.frame == windowAtRest, "\(moment): revealing a magnet moves no field, label, number or neighbor, and the window keeps its size")
        closing.mouseExited(with: hover(false, window: window))
        opening.mouseEntered(with: hover(true, window: window))
        content.layoutSubtreeIfNeeded()
        check(!opening.undoMagnet.isHidden && !opening.redoMagnet.isHidden && !closing.magnetsRevealed, "\(moment): a field with steps both ways shows undo and redo side by side")
        check(frames() == atRest && window.frame == windowAtRest, "\(moment): revealing both magnets moves nothing either")
        for magnet in [opening.undoMagnet, opening.redoMagnet] {
            check(isDark(magnet) == dark && same(magnet.layer?.backgroundColor, resolved(.windowBackgroundColor, in: name)) && same(magnet.layer?.borderColor, resolved(.separatorColor, in: name)),
                  "\(moment): a magnet's ground is the \(moment) card")
            let ground = luminance(magnet.layer?.backgroundColor)
            check(dark ? ground < 0.3 : ground > 0.8, "\(moment): a magnet reads \(moment) (\(ground))")
        }
        // Clicks on the magnets' parts above the tuner's top, through Settings' own views.
        let top = rect(opening).maxY, held = opening.value
        let undoHit = clickButton(at: NSPoint(x: rect(opening.undoMagnet).midX, y: (top + rect(opening.undoMagnet).maxY) / 2), in: content)
        check(undoHit === opening.undoButton && opening.value != held && settings.drawerMotion(for: .opening).duration * 1000 == opening.value,
              "\(moment): a click on ↺ above the opening duration undoes it, in the drawer's settings too")
        let redoHit = clickButton(at: NSPoint(x: rect(opening.redoMagnet).midX, y: (top + rect(opening.redoMagnet).maxY) / 2), in: content)
        check(redoHit === opening.redoButton && opening.value == held && frames() == atRest && window.frame == windowAtRest,
              "\(moment): and a click on ↻ there redoes it; nothing moved")
        opening.mouseExited(with: hover(false, window: window))
        window.makeFirstResponder(delay.keyView)
        check(delay.magnetsRevealed && !delay.undoMagnet.isHidden && delay.field.surface.rim == .controlAccentColor, "\(moment): Tab into a field reveals its undo and tints its border")
        let commandZ = key("z", [.command], code: 6, window: window)
        check(window.performKeyEquivalent(with: commandZ) && delay.value == 1 && settings.delaySeconds == 1, "\(moment): Command-Z reaches the focused field through the window")
        window.makeFirstResponder(nil)
        check(frames() == atRest && !delay.magnetsRevealed, "\(moment): leaving the field hides its magnets, still without moving anything")

        // The handle's drag reaches the drawer's settings as it moves; the field records one step.
        let steps = dismissal.history.past.count
        dismissal.handle.mouseDown(with: mouse(.leftMouseDown, x: 100, window: window))
        dismissal.handle.mouseDragged(with: mouse(.leftMouseDragged, x: 110, window: window))
        check(settings.dismissalDelaySeconds == 1 && dismissal.history.past.count == steps, "\(moment): mid-drag, the close delay is already 1s")
        dismissal.handle.mouseDragged(with: mouse(.leftMouseDragged, x: 104, window: window))
        check(settings.dismissalDelaySeconds == 0.7 && dismissal.value == 0.7 && dismissal.entry.stringValue == "0.7s", "\(moment): and follows the drag")
        dismissal.handle.mouseUp(with: mouse(.leftMouseUp, x: 104, window: window))
        check(dismissal.history.past.count == steps + 1 && settings.dismissalDelaySeconds == 0.7, "\(moment): letting go is one undo step")
        dismissal.undo()
        check(settings.dismissalDelaySeconds == 0.5 && dismissal.value == 0.5, "\(moment): which one undo takes back")

        // A delay its reveal mode does not use is dimmed: no drag, no typing, no magnets, no ⌘Z, and Tab passes it.
        settings.mode = .instant
        check(!delay.isEnabled && delay.alphaValue < 1 && !delay.entry.isEnabled && dismissal.isEnabled && dismissal.alphaValue == 1,
              "\(moment): instant hover dims the hover delay and leaves the close delay")
        // A dimmed field offers no drag or typing it would refuse; over it, the reason shows instead.
        let dragHelp = "Drag left or right to change hover delay (0s–2s)"
        check(delay.handle.toolTip == nil && delay.entry.toolTip == nil && delay.toolTip == "Used only by Delayed hover. Choose it above to set the wait."
              && dismissal.handle.toolTip != nil && dismissal.toolTip == nil, "\(moment): the dimmed delay says why it is dimmed, not how to drag it")
        delay.mouseEntered(with: hover(true, window: window))
        check(delay.history.canUndo && !delay.magnetsRevealed && !window.performKeyEquivalent(with: commandZ) && delay.value == 1, "\(moment): hovered, the dimmed delay shows no magnet and takes no ⌘Z")
        delay.mouseExited(with: hover(false, window: window))
        delay.handle.mouseDown(with: mouse(.leftMouseDown, x: 100, window: window))
        delay.handle.mouseDragged(with: mouse(.leftMouseDragged, x: 130, window: window))
        delay.handle.mouseUp(with: mouse(.leftMouseUp, x: 130, window: window))
        check(delay.value == 1 && settings.delaySeconds == 1 && !delay.handle.isDragging, "\(moment): its handle does not drag")
        check(!window.makeFirstResponder(delay.keyView) || !(window.firstResponder is NSTextView), "\(moment): its number takes no keyboard")
        window.makeFirstResponder(popup)
        check(popup.nextValidKeyView === dismissal.keyView, "\(moment): Tab from the menu passes the dimmed delay (\(String(describing: popup.nextValidKeyView)))")
        settings.mode = .click
        check(!delay.isEnabled, "\(moment): click to open dims it too")
        settings.mode = .delayed
        check(delay.isEnabled && delay.alphaValue == 1 && delay.entry.isEnabled && popup.nextValidKeyView === delay.keyView, "\(moment): delayed hover brings it back")
        check(delay.handle.toolTip == dragHelp && delay.entry.toolTip?.hasPrefix("Click or Tab in to type a number") == true && delay.toolTip == nil,
              "\(moment): with its drag and typing help again")
        settings.drawerAvailability = .hiddenTab
        settings.drawerAvailability = .disabled
        check(!delay.isEnabled && !dismissal.isEnabled && opening.isEnabled, "\(moment): a drawer turned off dims both delays, not the slide")
        check(delay.toolTip == "The drawer is off, so nothing waits to open it." && dismissal.toolTip == "The drawer is off, so nothing closes it."
              && dismissal.handle.toolTip == nil && opening.toolTip == nil, "\(moment): and each says the drawer is off")
        settings.drawerAvailability = .visibleTab
        check(delay.isEnabled && dismissal.isEnabled, "\(moment): and turned on again, brings them back")

        opening.submit(700)
        let optionCommandR = key("r", [.option, .command], code: 15, window: window)
        check(window.performKeyEquivalent(with: optionCommandR) && opening.value == 300, "\(moment): Option-Command-R resets from anywhere in Settings")
        let stack = views.compactMap { $0 as? NSStackView }.first!
        check(abs(content.bounds.height - (ceil(stack.fittingSize.height) + 44)) <= 1 && window.frame.height <= (NSScreen.main ?? NSScreen.screens[0]).visibleFrame.height,
              "\(moment): the window fits its content and stays within the display")
    }

    /// The keyboard in a Settings field, through the real panel: the editing chords,
    /// typing undone before values, plain keys kept as text, and Esc then Esc.
    private static func testSettingsKeyboard() {
        let settings = ClipboardRevealSettings(defaults: nil)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let controller = ClipboardRevealSettingsController(settings: settings, pasteboard: board)
        let window = controller.window!
        window.contentView!.layoutSubtreeIfNeeded()
        let tuners = controller.motionTuners
        let tuner = tuners[0]
        func press(_ characters: String, _ modifiers: NSEvent.ModifierFlags, _ code: UInt16) -> Bool {
            window.performKeyEquivalent(with: key(characters, modifiers, code: code, window: window))
        }
        func editor() -> NSTextView? { window.firstResponder as? NSTextView }
        window.makeFirstResponder(tuner.keyView)
        editor()?.setSelectedRange(NSRange(location: 1, length: 0))
        check(press("a", [.command], 0) && editor()?.selectedRange() == whole(tuner.entry), "⌘A selects the number's text in Settings")
        check(press("c", [.command], 8) && board.string(forType: .string) == "300ms" && tuner.entry.stringValue == "300ms", "⌘C copies it")
        check(press("x", [.command], 7) && tuner.entry.stringValue.isEmpty && board.string(forType: .string) == "300ms" && tuner.value == 300,
              "⌘X cuts it; nothing applies until Return or leaving")
        spin()
        check(press("z", [.command], 6) && tuner.entry.stringValue == "300ms" && tuner.value == 300 && !tuner.history.canUndo, "⌘Z with a typed draft undoes the editing, not a value")
        board.clearContents()
        board.setString("750", forType: .string)
        _ = press("a", [.command], 0)
        check(press("v", [.command], 9) && tuner.entry.stringValue == "750" && tuner.value == 300, "⌘V pastes into the number")
        window.sendEvent(key("\r", [], code: 36, window: window))
        check(tuner.value == 750 && tuner.entry.stringValue == "750ms" && settings.drawerMotion(for: .opening).duration == 0.75 && editor()?.selectedRange() == whole(tuner.entry),
              "Return applies the pasted number and selects it again")
        type("45", into: window)
        check(tuner.entry.stringValue == "45" && tuner.value == 750, "typing replaces the selected number as a draft")
        _ = tuner.undoButton.sendAction(tuner.undoButton.action, to: tuner.undoButton.target)
        check(tuner.entry.stringValue == "750ms" && tuner.value == 750 && tuner.history.past == [300], "the ↺ ⌘Z magnet undoes a typed draft first, as ⌘Z does")
        check(press("Z", [.command, .shift], 6) && tuner.entry.stringValue == "45" && tuner.value == 750, "and ⇧⌘Z redoes the typing it undid")
        check(press("z", [.command], 6) && tuner.entry.stringValue == "750ms" && tuner.value == 750, "⌘Z undoes the typing first, as a browser's field does")
        check(press("Z", [.command, .shift], 6) && tuner.entry.stringValue == "45" && tuner.value == 750, "⇧⌘Z redoes the typing")
        _ = press("z", [.command], 6)
        check(press("z", [.command], 6) && tuner.value == 300 && tuner.entry.stringValue == "300ms" && settings.drawerMotion(for: .opening).duration == 0.3,
              "with no typing left to undo, ⌘Z undoes the value")
        check(press("Z", [.command, .shift], 6) && tuner.value == 750, "and ⇧⌘Z redoes the value")
        let before = tuners.map(\.value)
        check(!press("r", [], 15) && !press(" ", [], 49), "plain keys are no key equivalents in Settings")
        _ = press("a", [.command], 0)
        type("r 1", into: window)
        check(tuner.entry.stringValue == "r 1" && tuners.map(\.value) == before && window.firstResponder === editor() && editor()?.delegate === tuner.entry,
              "plain keys typed in the field stay in the field: no reset, no other control")
        check(press("r", [.option, .command], 15) && tuners.map(\.value) == [300, 300] && tuner.entry.stringValue == "300ms", "⌥⌘R still resets while a field is edited")
        type("99", into: window)
        var closed = false
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: nil) { _ in closed = true }
        defer { NotificationCenter.default.removeObserver(observer) }
        let escape = key("\u{1b}", [], code: 53, window: window)
        window.sendEvent(escape)
        check(tuner.entry.stringValue == "300ms" && tuner.value == 300 && tuner.entry.currentEditor() == nil && !closed, "Esc puts the number back and leaves the field; Settings stays open")
        window.sendEvent(key("\u{1b}", [], code: 53, window: window, isARepeat: true))
        check(!closed, "a held Esc's repeats do not close Settings")
        window.sendEvent(escape)
        check(closed, "a second Esc closes Settings")
    }

    /// A Settings controller on a named pasteboard, with no preferences: its window, settings and tuners.
    private static func openSettings(_ board: NSPasteboard) -> (controller: ClipboardRevealSettingsController, settings: ClipboardRevealSettings, window: NSWindow) {
        let settings = ClipboardRevealSettings(defaults: nil)
        let controller = ClipboardRevealSettingsController(settings: settings, pasteboard: board)
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        return (controller, settings, controller.window!)
    }

    /// A typed number keeps however its field is left, not only by Return or Tab: a press on
    /// Settings' ground or on a label, another window taking the keyboard, or Settings closing.
    private static func testSettingsLeaving() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        for place in ["ground", "label"] {
            let (controller, settings, window) = openSettings(board)
            let tuner = controller.motionTuners[0]
            window.makeFirstResponder(tuner.keyView)
            type("800", into: window)
            check(tuner.entry.stringValue == "800" && tuner.value == 300, "\(place): 800 is typed, not yet kept")
            let content = window.contentView!
            let document = content.subviews.compactMap { $0 as? NSScrollView }.first!.documentView!
            let target: NSView = place == "ground" ? content.hitTest(NSPoint(x: 4, y: 4))! : tuner.titleLabel
            check(place == "label" || target === document, "the window's corner is Settings' ground (\(target))")
            let point = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
            // A label tracks the press until the button comes up: queue the release first, and take back any left over.
            NSApp.postEvent(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                               context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!, atStart: false)
            target.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                      context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
            _ = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true)
            check(tuner.entry.currentEditor() == nil && tuner.value == 800 && tuner.entry.stringValue == "800ms" && settings.drawerMotion(for: .opening).duration == 0.8,
                  "a press on Settings' \(place) leaves the field and keeps the typed 800")
            check(tuner.field.surface.rim == .separatorColor && !tuner.magnetsRevealed, "\(place): the field's border and magnets go back to rest")
        }

        // A press on the field around the number is the field's: it never leaves the number.
        do {
            let (controller, _, window) = openSettings(board)
            let tuner = controller.motionTuners[0]
            let padding = tuner.field.convert(NSPoint(x: tuner.field.bounds.maxX - 2, y: tuner.field.bounds.maxY - 2), to: nil)
            let press = NSEvent.mouseEvent(with: .leftMouseDown, location: padding, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            let hit = window.contentView!.hitTest(window.contentView!.convert(padding, from: nil))!
            check(hit === tuner.field, "the field's edge, past the number, is the field's own ground (\(hit))")
            hit.mouseDown(with: press)
            check((tuner.entry.currentEditor() as? NSTextView)?.selectedRange() == whole(tuner.entry), "a press there puts the keyboard in the number, selected")
            type("800", into: window)
            hit.mouseDown(with: press)
            check(tuner.entry.currentEditor() != nil && tuner.entry.stringValue == "800" && tuner.value == 300, "and while a number is typed, a press there leaves it being typed")
            window.makeFirstResponder(nil)
        }

        // The drawer opening, or another app, takes the keyboard: the number keeps and stays selected for more typing.
        var (controller, settings, window) = openSettings(board)
        var tuner = controller.motionTuners[0]
        window.makeFirstResponder(tuner.keyView)
        type("900", into: window)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        check(tuner.value == 900 && tuner.entry.stringValue == "900ms" && settings.drawerMotion(for: .opening).duration == 0.9 && tuner.history.past == [300],
              "another window taking the keyboard keeps the typed 900")
        check((tuner.entry.currentEditor() as? NSTextView)?.selectedRange() == whole(tuner.entry), "and the number stays in its field, selected")

        // Closing Settings keeps a typed number then, not silently at the next opening.
        for close in ["close button", "close()"] {
            (controller, settings, window) = openSettings(board)
            tuner = controller.motionTuners[0]
            window.makeFirstResponder(tuner.keyView)
            type("800", into: window)
            if close == "close()" { controller.close() } else { window.performClose(nil) }
            check(tuner.value == 800 && settings.drawerMotion(for: .opening).duration == 0.8 && tuner.history.past == [300] && tuner.entry.currentEditor() == nil,
                  "closing Settings by its \(close) keeps the typed 800 at once")
            // Opening again: show() loads the saved values, then gives the Hide drawer tab checkbox the keyboard.
            let closed = (value: tuner.value, past: tuner.history.past)
            tuner.load(settings.drawerMotion(for: .opening).duration * 1000)
            let hideTab = descendants(window.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Hide drawer tab" }!
            window.makeFirstResponder(hideTab)
            check(tuner.value == closed.value && tuner.history.past == closed.past, "\(close): opening again changes nothing and adds no undo step")
        }
    }

    /// The magnets name the chord, so ⌘Z reaches the field they show on: the hovered one, unless
    /// another field has the keyboard; then that field alone shows magnets. Closing Settings ends the hover.
    private static func testSettingsHover() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        var (controller, _, window) = openSettings(board)
        var opening = controller.motionTuners[0]
        let closing = controller.motionTuners[1], dismissal = controller.tuners[1]
        let commandZ = key("z", [.command], code: 6, window: window), shiftCommandZ = key("Z", [.command, .shift], code: 6, window: window)
        let hideTab = descendants(window.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Hide drawer tab" }!
        window.makeFirstResponder(hideTab)
        opening.submit(800)
        opening.mouseEntered(with: hover(true, window: window))
        check(opening.magnetsRevealed && window.performKeyEquivalent(with: commandZ) && opening.value == 300, "with the keyboard on a checkbox, ⌘Z undoes the hovered field, as its ↺ ⌘Z magnet says")
        check(window.performKeyEquivalent(with: shiftCommandZ) && opening.value == 800, "and ⇧⌘Z redoes it")
        opening.mouseExited(with: hover(false, window: window))
        check(!window.performKeyEquivalent(with: commandZ) && opening.value == 800, "an unhovered field's history is left alone")

        dismissal.submit(1.5)
        closing.submit(500)
        window.makeFirstResponder(closing.keyView)
        dismissal.mouseEntered(with: hover(true, window: window))
        check(controller.tuners.filter(\.magnetsRevealed).map(\.spec.label) == ["Closing duration"], "while a field has the keyboard, it alone shows magnets: ⌘Z is its")
        check(window.performKeyEquivalent(with: commandZ) && closing.value == 300 && dismissal.value == 1.5, "⌘Z undoes the field with the keyboard, not the hovered one")
        window.makeFirstResponder(nil)
        check(dismissal.magnetsRevealed && !closing.magnetsRevealed, "once the keyboard leaves, the hovered field's magnets show")
        window.makeFirstResponder(closing.keyView)
        check(!dismissal.magnetsRevealed && closing.magnetsRevealed, "and Tab into another field hides them again")
        window.makeFirstResponder(nil)
        closing.redo()
        check(dismissal.magnetsRevealed && closing.value == 500, "the hovered field shows its magnets again")
        click(closing.entry)
        check(!dismissal.magnetsRevealed && closing.magnetsRevealed && closing.field.surface.rim == .controlAccentColor,
              "a click into another field hides the hovered field's magnets, as Tab does, and the clicked field shows its own")
        check(window.performKeyEquivalent(with: commandZ) && closing.value == 300 && dismissal.value == 1.5, "⌘Z undoes the field clicked into, not the hovered one")
        window.makeFirstResponder(nil)
        check(dismissal.magnetsRevealed && !closing.magnetsRevealed && closing.field.surface.rim == .separatorColor, "leaving it gives the hover back")

        // Closing under the pointer: AppKit sends no exit, so Settings ends the hover.
        (controller, _, window) = openSettings(board)
        opening = controller.motionTuners[0]
        opening.submit(800)
        opening.mouseEntered(with: hover(true, window: window))
        opening.undoMagnet.mouseEntered(with: hover(true, window: window))
        opening.handle.mouseEntered(with: hover(true, window: window))
        check(opening.magnetsRevealed && opening.undoMagnet.surface.rim == .controlAccentColor, "a hovered field and magnet show their hover")
        controller.close()
        check(!opening.magnetsRevealed && opening.undoMagnet.surface.rim != .controlAccentColor && opening.handle.surface.fill?.color != .controlAccentColor,
              "closing Settings under the pointer leaves no magnet, magnet tint or handle tint showing for the next opening")
    }
}
