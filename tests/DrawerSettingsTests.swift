import AppKit

@main enum DrawerSettingsTests {
    private static var count = 0
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        count += 1
        guard condition() else { fatalError("FAIL: \(message)") }
    }

    static func main() throws {
        _ = NSApplication.shared
        try persistence()
        controls()
        smallDisplay()
        print("PASS: \(count) drawer settings/shortcut assertions; isolated preferences, no OS registration or input")
    }

    private static func persistence() throws {
        let suite = ClipboardMaterializer.privateSuiteName("ClipEdge-drawer-settings-")
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ClipboardRevealSettings(defaults: defaults)
        check(settings.drawerAvailability == .visibleTab, "existing installs keep the visible tab")
        check(settings.drawerShortcut == .defaultDrawer, "drawer has a distinct initial shortcut")
        check(settings.drawerShortcut.displayString == "⌃⌥⌘Space", "drawer shortcut has a readable description")
        for state in ClipboardDrawerAvailability.allCases {
            settings.drawerAvailability = state
            check(ClipboardRevealSettings(defaults: defaults).drawerAvailability == state, "each drawer availability survives relaunch")
            check(!state.tabVisible || state.drawerEnabled, "visible tab cannot be disabled")
        }
        settings.drawerShortcut = ClipboardShortcut(keyCode: 40, modifiers: [.control, .command])!
        let saved = settings.drawerShortcut
        check(ClipboardRevealSettings(defaults: defaults).drawerShortcut == saved, "drawer shortcut survives relaunch")
        for conflict in [ClipboardShortcut.history, .plainPaste, settings.quickLookShortcut] {
            settings.drawerShortcut = conflict
            check(settings.drawerShortcut == saved, "direct settings mutation cannot introduce a shortcut collision")
        }
        settings.quickLookShortcut = saved
        check(settings.quickLookShortcut == .defaultQuickLook, "Quick Look cannot steal the drawer shortcut")
        settings.drawerAvailability = .hiddenTab
        settings.mode = .click
        check(settings.behavior == .instant && settings.mode == .click, "hidden tab turns saved click mode into instant hover without replacing preference")
        settings.mode = .delayed
        settings.delaySeconds = 1.25
        check(settings.behavior == .delayed(1.25), "hidden edge hover honors configured delay")
        settings.mode = .click
        settings.drawerAvailability = .visibleTab
        check(settings.behavior == .click, "restoring tab restores saved click behavior")
        defaults.set("impossible", forKey: "ClipEdgeDrawerAvailability")
        defaults.set(Data("corrupt".utf8), forKey: "ClipEdgeDrawerShortcut")
        let repaired = ClipboardRevealSettings(defaults: defaults)
        check(repaired.drawerAvailability == .visibleTab && repaired.drawerShortcut == .defaultDrawer, "corrupt persisted settings normalize safely")
        defaults.set(try JSONEncoder().encode(ClipboardShortcut.defaultDrawer), forKey: "ClipEdgeQuickLookShortcut")
        defaults.set(try JSONEncoder().encode(ClipboardShortcut.defaultDrawer), forKey: "ClipEdgeDrawerShortcut")
        let collision = ClipboardRevealSettings(defaults: defaults)
        check(collision.quickLookShortcut == .defaultDrawer && collision.drawerShortcut == .alternateDrawer, "persisted collision preserves existing Quick Look and selects an available drawer fallback")
        defaults.set(try JSONEncoder().encode(ClipboardShortcut.history), forKey: "ClipEdgeQuickLookShortcut")
        defaults.set(try JSONEncoder().encode(ClipboardShortcut.plainPaste), forKey: "ClipEdgeDrawerShortcut")
        let fixedCollision = ClipboardRevealSettings(defaults: defaults)
        check(fixedCollision.quickLookShortcut == .defaultQuickLook && fixedCollision.drawerShortcut == .defaultDrawer, "persisted conflicts with fixed chords normalize")
    }

    private static func controls() {
        let settings = ClipboardRevealSettings(defaults: nil)
        let controller = ClipboardRevealSettingsController(settings: settings)
        let content = controller.window!.contentView!
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let views = descendants(content)
        func box(_ title: String) -> NSButton { views.compactMap { $0 as? NSButton }.first { $0.title == title }! }
        func press(_ button: NSButton, state: NSControl.StateValue) {
            button.state = state
            _ = button.sendAction(button.action, to: button.target)
        }
        let hide = box("Hide drawer tab"), keep = box("Keep drawer enabled")
        let popup = views.compactMap { $0 as? NSPopUpButton }.first!
        let quickLook = views.compactMap { $0 as? ClipboardShortcutRecorder }.first { $0.actionName == "Quick Look" }!
        let drawer = views.compactMap { $0 as? ClipboardShortcutRecorder }.first { $0.actionName == "Show / Hide Clipboard" }!
        check(hide.state == .off && keep.isHiddenOrHasHiddenAncestor, "nested keep option stays hidden until requested")
        press(hide, state: .on)
        check(settings.drawerAvailability == .hiddenTab && keep.state == .on && !keep.isHiddenOrHasHiddenAncestor, "first hide keeps drawer enabled and reveals nested option")
        check(popup.isEnabled && hide.nextKeyView === keep, "hidden tab retains hover mode and exposes keep to keyboard")
        check(popup.item(withTitle: ClipboardRevealMode.click.title)?.isEnabled == false, "hidden tab cannot select a mode that needs a visible click target")
        settings.mode = .click
        check(settings.mode == .click && popup.titleOfSelectedItem == ClipboardRevealMode.click.title, "hidden tab preserves the saved click preference")
        check(views.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "With the tab hidden, hover opens immediately; show the tab to use click." }, "hidden click fallback is explained")
        settings.mode = .delayed
        let delay = views.compactMap { $0 as? ClipboardTuner }.first { $0.spec.label == "Hover delay" }!
        let closeDelay = views.compactMap { $0 as? ClipboardTuner }.first { $0.spec.label == "Maximum close delay" }!
        check(delay.isEnabled && closeDelay.isEnabled, "hidden edge hover retains both timing controls")
        content.layoutSubtreeIfNeeded()
        let hideFrame = hide.convert(hide.bounds, to: content)
        let keepFrame = keep.convert(keep.bounds, to: content)
        check(keepFrame.minX > hideFrame.minX && keepFrame.maxY < hideFrame.minY, "keep checkbox sits underneath and indented")
        press(keep, state: .off)
        check(settings.drawerAvailability == .disabled && hide.state == .on, "unchecking keep disables a hidden drawer")
        check(!popup.isEnabled && !delay.isEnabled && !closeDelay.isEnabled, "disabled drawer disables its opening and closing controls")
        check(views.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("Clipboard History and Quick Look remain") }, "disabled drawer explains surviving commands")
        press(hide, state: .off)
        check(settings.drawerAvailability == .visibleTab && popup.isEnabled && keep.isHiddenOrHasHiddenAncestor && popup.item(withTitle: ClipboardRevealMode.click.title)?.isEnabled == true, "showing tab restores drawer and click choice")
        press(hide, state: .on)
        press(keep, state: .off)
        press(keep, state: .on)
        check(settings.drawerAvailability == .hiddenTab, "nested option re-enables invisible-edge drawer")

        var active: ClipboardShortcut? = .defaultDrawer
        var registrations = 0
        var rejection: OSStatus = noErr
        let hotkey = ClipboardHotKey(registrar: { code, flags, _ in
            registrations += 1
            guard rejection == noErr else { return .failed(rejection) }
            let candidate = ClipboardShortcut(keyCode: code, modifiers: flags)!
            active = candidate
            return .registered(cancel: { if active == candidate { active = nil } })
        })
        _ = hotkey.register(shortcut: settings.drawerShortcut)
        controller.onDrawerShortcutChange = { hotkey.register(shortcut: $0) }
        for candidate in [ClipboardShortcut.history, .plainPaste, settings.quickLookShortcut] {
            drawer.onRecord?(candidate)
            check(registrations == 1 && active == .defaultDrawer && settings.drawerShortcut == .defaultDrawer, "own-command collision leaves registrar and saved shortcut untouched")
        }
        let replacement = ClipboardShortcut(keyCode: 40, modifiers: [.control, .command])!
        rejection = -9878
        drawer.onRecord?(replacement)
        check(active == .defaultDrawer && settings.drawerShortcut == .defaultDrawer && drawer.shortcut == .defaultDrawer, "OS rejection preserves live lease, preference and displayed shortcut")
        check(views.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("unavailable (-9878)") }, "OS conflict appears inline")
        rejection = noErr
        drawer.onRecord?(replacement)
        check(active == replacement && settings.drawerShortcut == replacement && drawer.shortcut == replacement, "accepted recorder replaces live lease and saved/displayed shortcut together")
        let priorRegistrations = registrations
        var quickLookRegistration = false
        controller.onShortcutChange = { _ in quickLookRegistration = true; return noErr }
        quickLook.onRecord?(replacement)
        check(!quickLookRegistration && settings.quickLookShortcut == .defaultQuickLook && registrations == priorRegistrations, "reverse collision rejected before Quick Look registrar")
        let reset = views.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel()?.hasPrefix("Restore Show / Hide Clipboard") == true }!
        _ = reset.sendAction(reset.action, to: reset.target)
        check(active == .defaultDrawer && settings.drawerShortcut == .defaultDrawer, "Use Default takes the same registration path")
        var recordingChanges: [Bool] = []
        controller.onRecordingChange = { recordingChanges.append($0) }
        _ = drawer.sendAction(drawer.action, to: drawer.target)
        check(controller.isRecordingShortcut && drawer.accessibilityLabel() == "Show / Hide Clipboard global shortcut", "drawer recorder is accessibly named and blocks other commands during recording")
        check(recordingChanges == [true], "starting recorder requests global shortcut suspension")
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                     context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53)!
        drawer.keyDown(with: escape)
        check(!controller.isRecordingShortcut && settings.drawerShortcut == .defaultDrawer, "Escape cancels drawer recording without changing its shortcut")
        check(recordingChanges == [true, false], "Escape restores global shortcuts")
        _ = quickLook.sendAction(quickLook.action, to: quickLook.target)
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: controller.window))
        check(!controller.isRecordingShortcut && recordingChanges.suffix(2) == [true, false], "leaving Settings cancels recording and restores shortcuts")
        _ = drawer.sendAction(drawer.action, to: drawer.target)
        var closings = 0
        controller.onClose = { closings += 1 }
        controller.close()
        check(!controller.isRecordingShortcut && recordingChanges.suffix(2) == [true, false], "closing Settings restores shortcuts")
        check(closings == 1, "close() tells the drawer Settings closed, once")
        let escaped = ClipboardRevealSettingsController(settings: ClipboardRevealSettings(defaults: nil))
        escaped.onClose = { closings += 1 }
        escaped.cancelOperation(nil)
        check(closings == 2, "so does Esc, through cancelOperation")
        for state in ClipboardDrawerAvailability.allCases {
            settings.drawerAvailability = state
            content.layoutSubtreeIfNeeded()
            for control in [hide, drawer, quickLook, box("Show cursor magnets")] {
                let frame = control.convert(control.bounds, to: content)
                check(!control.hasAmbiguousLayout && frame.width > 0 && frame.height > 0 && content.bounds.contains(frame), "settings controls fit in every drawer mode")
            }
        }
        print("Settings fixture: \(Int(controller.window!.frame.width)) × \(Int(controller.window!.frame.height)) points; screen \(Int(NSScreen.main!.visibleFrame.height)) points high")
    }

    private static func smallDisplay() {
        let available = NSRect(x: 0, y: 0, width: 1024, height: 680)
        let settings = ClipboardRevealSettings(defaults: nil)
        let controller = ClipboardRevealSettingsController(settings: settings, screenFrame: { available })
        settings.drawerAvailability = .hiddenTab
        let window = controller.window!
        let scroll = window.contentView!.subviews.compactMap { $0 as? NSScrollView }.first!
        let document = scroll.documentView!
        check(window.frame.height <= available.height && window.frame.minY >= available.minY && window.frame.maxY <= available.maxY, "settings fit a small display without hiding the title bar")
        check(document.frame.height > scroll.contentSize.height && scroll.hasVerticalScroller, "small display keeps all settings in a scrollable document")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.frame.height - scroll.contentSize.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        check(scroll.documentVisibleRect.maxY >= document.frame.maxY - 1, "the bottom of all settings remains reachable")
    }
}
