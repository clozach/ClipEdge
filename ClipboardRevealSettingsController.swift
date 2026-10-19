import AppKit

/// Native controls remain open while changes apply, so the nearby tab can be
/// tried repeatedly. The same settings instance is read by EdgeController.
final class ClipboardRevealSettingsController: NSWindowController, NSWindowDelegate {
    private let settings: ClipboardRevealSettings
    private let modePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let delayTuner = ClipboardTuner(spec: .seconds("Hover delay", maximum: ClipboardRevealSettings.longestDelay,
                                                           standard: ClipboardRevealSettings.standardDelay))
    private let explanation = NSTextField(wrappingLabelWithString: "")
    private let dismissalTuner = ClipboardTuner(spec: .seconds("Maximum close delay", maximum: ClipboardRevealSettings.longestDismissalDelay,
                                                               standard: ClipboardRevealSettings.standardDismissalDelay))
    private let openingDuration = ClipboardTuner(spec: .duration("Opening duration", standard: ClipboardDrawerMotionProfile.standard.duration * 1000))
    private let closingDuration = ClipboardTuner(spec: .duration("Closing duration", standard: ClipboardDrawerMotionProfile.standard.duration * 1000))
    private let motionReset = ClipboardKeyedButton(title: "", target: nil, action: nil)
    /// Text, list thumbnails and Quick Look's preview, each a percentage of the shipped size (2026-10-16).
    private let textSizeTuner = ClipboardTuner(spec: .percent("Text size", range: ClipboardSizes.textRange, symbol: "textformat.size", glyph: "A"))
    private let thumbnailTuner = ClipboardTuner(spec: .percent("Thumbnail size", range: ClipboardSizes.thumbnailRange, symbol: "photo", glyph: "▣"))
    private let previewTuner = ClipboardTuner(spec: .percent("Preview size", range: ClipboardSizes.previewRange, symbol: "eye", glyph: "◉"))
    var sizeTuners: [ClipboardTuner] { [textSizeTuner, thumbnailTuner, previewTuner] }
    /// Settings' content width before zooming: wide enough for two fields a row with each label on
    /// one line, "Maximum close delay" the longest; narrower, a label wraps short of its magnets.
    static let contentWidth: CGFloat = 520
    /// The text size Settings is zoomed to now: a drag on Text size's handle zooms the drawer and the
    /// window live, and Settings, under the pointer, once the handle is let go.
    private(set) var appliedTextScale: CGFloat = 1
    private var trackedScale: CGFloat = 1
    /// The drawer's slide, opening then closing. The capture tools reach them here.
    var motionTuners: [ClipboardTuner] { motionParts.map(\.tuner) }
    private var motionParts: [(tuner: ClipboardTuner, direction: ClipboardDrawerDirection)] { [(openingDuration, .opening), (closingDuration, .closing)] }
    /// Every field in Settings, in Tab order: the hover delay, the close delay, the slide, the sizes.
    /// They share ⌘Z, the hover that reaches it and Reset.
    var tuners: [ClipboardTuner] { [delayTuner, dismissalTuner] + motionTuners + sizeTuners }
    private let quickLookControl = ClipboardShortcutSettingsView(title: "Global Quick Look shortcut", actionName: "Quick Look", defaultShortcut: .defaultQuickLook)
    private let drawerControl = ClipboardShortcutSettingsView(title: "Global Show / Hide Clipboard shortcut", actionName: "Show / Hide Clipboard", defaultShortcut: .defaultDrawer)
    private let hideTabBox = NSButton(checkboxWithTitle: "Hide drawer tab", target: nil, action: nil)
    private let keepDrawerBox = NSButton(checkboxWithTitle: "Keep drawer enabled", target: nil, action: nil)
    private let hiddenTabStack = NSStackView()
    private let drawerExplanation = NSTextField(wrappingLabelWithString: "")
    private let magnetsBox = NSButton(checkboxWithTitle: "Show cursor magnets", target: nil, action: nil)
    private let sourceBoxes = ClipboardMagnetSource.allCases.map { NSButton(checkboxWithTitle: $0.title, target: nil, action: nil) }
    private let sourceStack = NSStackView()
    private let scrollView = NSScrollView()
    private let documentView = SettingsDocumentView()
    private let screenFrame: (() -> NSRect?)?
    private var stack: NSStackView?
    private var changeObserver: NSObjectProtocol?
    /// Registration must succeed before the preference (and displayed hints)
    /// change. A nil hook is for isolated settings fixtures, not live delivery.
    var onShortcutChange: ((ClipboardShortcut) -> OSStatus)?
    var onDrawerShortcutChange: ((ClipboardShortcut) -> OSStatus)?
    var onRecordingChange: ((Bool) -> Void)?
    /// Settings closed, by its close button, Esc or close(): a drawer it held may close again.
    var onClose: (() -> Void)?
    var isRecordingShortcut: Bool { quickLookControl.recorder.isRecording || drawerControl.recorder.isRecording }

    /// `pasteboard` is the one ⌘C, ⌘X and ⌘V use in Settings' fields; fixtures pass a named one.
    init(settings: ClipboardRevealSettings, screenFrame: (() -> NSRect?)? = nil, pasteboard: NSPasteboard = .general) {
        self.settings = settings
        self.screenFrame = screenFrame
        let panel = SettingsPanel(contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 580),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.editingPasteboard = pasteboard
        panel.title = "ClipEdge Settings"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        super.init(window: panel)
        panel.delegate = self
        buildContent(in: panel)
        panel.tuners = { [unowned self] in self.tuners }
        changeObserver = NotificationCenter.default.addObserver(forName: ClipboardRevealSettings.didChange,
                                                                 object: settings, queue: .main) { [weak self] _ in self?.refresh() }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("Use init(settings:)") }
    deinit { if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) } }

    @objc func show() {
        refresh()
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(hideTabBox)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    override func cancelOperation(_ sender: Any?) { close() }
    override func close() {
        cancelShortcutRecording()
        super.close()
    }

    func windowWillClose(_ notification: Notification) {
        cancelShortcutRecording()
        // A typed number keeps when Settings closes, as leaving its field does, rather than at the next opening.
        window?.makeFirstResponder(nil)
        tuners.forEach { $0.endHover() }
        onClose?()
    }

    /// Another window took the keyboard: a typed number keeps, and its field stays selected for more typing.
    func windowDidResignKey(_ notification: Notification) {
        cancelShortcutRecording()
        tuners.forEach { $0.submitDraft() }
    }

    private func cancelShortcutRecording() {
        quickLookControl.recorder.cancelRecording()
        drawerControl.recorder.cancelRecording()
    }

    func makeMenuItem(keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: "Settings…", action: #selector(show), keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    private func buildContent(in panel: NSPanel) {
        guard let content = panel.contentView else { return }
        let title = NSTextField(labelWithString: "Open the drawer")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        hideTabBox.target = self
        hideTabBox.action = #selector(toggleTabHidden)
        keepDrawerBox.target = self
        keepDrawerBox.action = #selector(toggleDrawerEnabled)
        hiddenTabStack.setViews([keepDrawerBox], in: .leading)
        hiddenTabStack.orientation = .vertical
        hiddenTabStack.alignment = .leading
        hiddenTabStack.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        drawerExplanation.font = .systemFont(ofSize: 12)
        drawerExplanation.textColor = .secondaryLabelColor
        modePicker.addItems(withTitles: ClipboardRevealMode.allCases.map(\.title))
        modePicker.menu?.autoenablesItems = false
        modePicker.target = self
        modePicker.action = #selector(changeRevealMode)
        modePicker.setAccessibilityLabel("Reveal mode")
        delayTuner.onChange = { [weak self] in self?.settings.delaySeconds = $0 }
        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = .secondaryLabelColor
        let closeTitle = NSTextField(labelWithString: "Close the drawer")
        closeTitle.font = title.font
        dismissalTuner.onChange = { [weak self] in self?.settings.dismissalDelaySeconds = $0 }
        let closeExplanation = NSTextField(wrappingLabelWithString: "After opening from the screen edge, moving away closes the drawer: this delay shortens to zero at 200 points. The menu and shortcut keep it open until you close it.")
        closeExplanation.font = explanation.font
        closeExplanation.textColor = .secondaryLabelColor
        let motionTitle = NSTextField(labelWithString: "Drawer motion")
        motionTitle.font = title.font
        let motionExplanation = NSTextField(wrappingLabelWithString: "How long each slide takes (0ms is at once). Drag a handle, type a number, or press ↑ and ↓ (⇧ for ten steps).")
        motionExplanation.font = explanation.font
        motionExplanation.textColor = .secondaryLabelColor
        // Every field is a column of a two-column row, so all are one size; a delay has the row to itself.
        let delayRow = Self.row(delayTuner, NSView())
        let dismissalRow = Self.row(dismissalTuner, NSView())
        let motionRow = Self.row(openingDuration, closingDuration)
        for (tuner, direction) in motionParts {
            tuner.onChange = { [weak self] in self?.applyMotion($0, direction) }
        }
        motionReset.target = self
        motionReset.action = #selector(resetTuners)
        motionReset.keyEquivalent = "r"
        motionReset.keyEquivalentModifierMask = [.option, .command]
        motionReset.toolTip = "Put every field back: hover delay \(delayTuner.spec.text(delayTuner.spec.defaultValue)), close delay \(dismissalTuner.spec.text(dismissalTuner.spec.defaultValue)), each slide \(openingDuration.spec.text(openingDuration.spec.defaultValue)), each size 100%. Each field can undo it. ⌥⌘R"
        motionReset.keyedTitle = ClipboardKeyedTitle(name: "Reset", key: ClipboardKeyLabel(shown: "⌥⌘R", spoken: "Option–Command–R"))
        motionReset.spokenLabel = "Reset every field to its default, Option–Command–R"
        quickLookControl.onChange = { [weak self] in self?.applyShortcut($0, for: .quickLook) }
        drawerControl.onChange = { [weak self] in self?.applyShortcut($0, for: .drawer) }
        for recorder in [quickLookControl.recorder, drawerControl.recorder] {
            recorder.onRecordingChange = { [weak self] in
                guard let self else { return }
                self.onRecordingChange?(self.isRecordingShortcut)
            }
        }
        let sizesTitle = NSTextField(labelWithString: "Sizes")
        sizesTitle.font = title.font
        let sizesExplanation = NSTextField(wrappingLabelWithString: "Text size enlarges everything ClipEdge shows, Settings too. Thumbnails are the pictures at the start of each row; the Images grid keeps its own slider.")
        sizesExplanation.font = explanation.font
        sizesExplanation.textColor = .secondaryLabelColor
        let sizesRow = Self.row(textSizeTuner, thumbnailTuner)
        let previewRow = Self.row(previewTuner, NSView())
        textSizeTuner.onChange = { [weak self] in
            guard let self else { return }
            self.settings.sizes.text = $0
            // Let go of the handle: Settings zooms now, even when the last value was already saved.
            if !self.textSizeTuner.isScrubbing { self.fitWindowToContent() }
        }
        thumbnailTuner.onChange = { [weak self] in self?.settings.sizes.thumbnails = $0 }
        previewTuner.onChange = { [weak self] in self?.settings.sizes.preview = $0 }
        let magnetsTitle = NSTextField(labelWithString: "Cursor magnets")
        magnetsTitle.font = title.font
        magnetsBox.target = self
        magnetsBox.action = #selector(toggleMagnets)
        for (index, box) in sourceBoxes.enumerated() {
            box.tag = index
            box.target = self
            box.action = #selector(toggleSource(_:))
        }
        sourceStack.setViews(sourceBoxes, in: .leading)
        sourceStack.orientation = .vertical
        sourceStack.alignment = .leading
        sourceStack.spacing = 6
        sourceStack.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        let magnetsExplanation = NSTextField(wrappingLabelWithString: "A magnet shows what you are holding beside the pointer. Turn off any you don't want: copies still join the history, a pick without a magnet goes straight onto the clipboard, and Quick Look still opens.")
        magnetsExplanation.font = explanation.font
        magnetsExplanation.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [hideTabBox, hiddenTabStack, drawerExplanation,
                                       title, modePicker, delayRow, explanation,
                                       closeTitle, dismissalRow, closeExplanation,
                                       motionTitle, motionExplanation, motionRow,
                                       sizesTitle, sizesExplanation, sizesRow, previewRow, motionReset,
                                       quickLookControl, drawerControl,
                                       magnetsTitle, magnetsBox, sourceStack, magnetsExplanation])
        self.stack = stack
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(20, after: explanation)
        stack.setCustomSpacing(20, after: closeExplanation)
        stack.setCustomSpacing(20, after: motionRow)
        stack.setCustomSpacing(16, after: sizesExplanation)
        stack.setCustomSpacing(20, after: motionReset)
        // The magnets take no room and reach about 7 points above a field's label: 16 keeps them
        // clear of the menu or heading above a delay, as the explanation above the slide's row is.
        stack.setCustomSpacing(16, after: modePicker)
        stack.setCustomSpacing(16, after: closeTitle)
        stack.setCustomSpacing(20, after: drawerControl)
        stack.setCustomSpacing(6, after: hideTabBox)
        stack.setCustomSpacing(6, after: magnetsBox)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.frame = content.bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        documentView.frame = content.bounds
        scrollView.documentView = documentView
        content.addSubview(scrollView)
        documentView.addSubview(stack)
        for view in [drawerExplanation, modePicker, delayRow, explanation, dismissalRow, closeExplanation,
                     motionExplanation, motionRow, sizesExplanation, sizesRow, previewRow, quickLookControl, drawerControl, magnetsExplanation] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 22)
        ])
        // The tuners' magnets, over everything in Settings and out of its layout; every field shares ⌘Z.
        ClipboardTunerMagnetLayer.lay(tuners, over: documentView)
        panel.initialFirstResponder = hideTabBox
        panel.autorecalculatesKeyViewLoop = false
        // A dimmed field is no stop: Tab passes it, as it passed a disabled slider.
        modePicker.nextKeyView = delayTuner.keyView
        for (tuner, next) in zip(tuners, tuners.dropFirst()) { tuner.keyView.nextKeyView = next.keyView }
        previewTuner.keyView.nextKeyView = motionReset
        motionReset.nextKeyView = quickLookControl.recorder
        quickLookControl.resetButton.nextKeyView = drawerControl.recorder
        drawerControl.resetButton.nextKeyView = magnetsBox
    }

    private func refresh() {
        refreshDrawerAvailability()
        modePicker.selectItem(at: ClipboardRevealMode.allCases.firstIndex(of: settings.mode) ?? 0)
        // The tuners' own changes are already current; a value from elsewhere shows with nothing to undo.
        delayTuner.load(settings.delaySeconds)
        dismissalTuner.load(settings.dismissalDelaySeconds)
        for (tuner, direction) in motionParts { tuner.load((settings.drawerMotion(for: direction).duration * 1000).rounded()) }
        textSizeTuner.load(settings.sizes.text)
        thumbnailTuner.load(settings.sizes.thumbnails)
        previewTuner.load(settings.sizes.preview)
        // Only delayed hover waits; a drawer turned off neither opens nor closes.
        delayTuner.isEnabled = settings.drawerAvailability.drawerEnabled && settings.mode == .delayed
        dismissalTuner.isEnabled = settings.drawerAvailability.drawerEnabled
        delayTuner.toolTip = delayTuner.isEnabled ? nil : settings.drawerAvailability.drawerEnabled
            ? "Used only by \(ClipboardRevealMode.delayed.title). Choose it above to set the wait." : "The drawer is off, so nothing waits to open it."
        dismissalTuner.toolTip = dismissalTuner.isEnabled ? nil : "The drawer is off, so nothing closes it."
        quickLookControl.recorder.shortcut = settings.quickLookShortcut
        drawerControl.recorder.shortcut = settings.drawerShortcut
        magnetsBox.state = settings.magnetsEnabled ? .on : .off
        for (source, box) in zip(ClipboardMagnetSource.allCases, sourceBoxes) {
            box.state = settings.magnetSources.contains(source) ? .on : .off
        }
        // The three choices show only while magnets are on, and the keyboard loop follows what shows.
        if !settings.magnetsEnabled, let focused = window?.firstResponder as? NSButton, sourceBoxes.contains(focused) {
            window?.makeFirstResponder(magnetsBox)
        }
        sourceStack.isHidden = !settings.magnetsEnabled
        stack?.setCustomSpacing(settings.magnetsEnabled ? 6 : stack?.spacing ?? 10, after: magnetsBox)
        let shown = settings.magnetsEnabled ? sourceBoxes : []
        for (box, next) in zip([magnetsBox] + shown, shown + [hideTabBox]) { box.nextKeyView = next }
        refreshRevealExplanation()
        fitWindowToContent()
    }

    @objc private func changeRevealMode() { settings.mode = ClipboardRevealMode.allCases[modePicker.indexOfSelectedItem] }
    @objc private func toggleMagnets() { settings.magnetsEnabled = magnetsBox.state == .on }
    @objc private func toggleTabHidden() { settings.drawerAvailability = hideTabBox.state == .on ? .hiddenTab : .visibleTab }
    @objc private func toggleDrawerEnabled() { settings.drawerAvailability = keepDrawerBox.state == .on ? .hiddenTab : .disabled }

    private func refreshDrawerAvailability() {
        let availability = settings.drawerAvailability
        hideTabBox.state = availability.tabVisible ? .off : .on
        keepDrawerBox.state = availability.drawerEnabled ? .on : .off
        if availability.tabVisible, window?.firstResponder === keepDrawerBox { window?.makeFirstResponder(hideTabBox) }
        hiddenTabStack.isHidden = availability.tabVisible
        hideTabBox.nextKeyView = availability.tabVisible ? modePicker : keepDrawerBox
        keepDrawerBox.nextKeyView = modePicker
        modePicker.isEnabled = availability.drawerEnabled
        modePicker.item(withTitle: ClipboardRevealMode.click.title)?.isEnabled = availability.tabVisible
        switch availability {
        case .visibleTab: drawerExplanation.stringValue = "The tab opens the drawer. The menu and shortcut can show or hide it too."
        case .hiddenTab: drawerExplanation.stringValue = "Hover at the tab's usual screen-edge location, or use Show Clipboard in the menu or its shortcut."
        case .disabled: drawerExplanation.stringValue = "The drawer is off. Clipboard History and Quick Look remain available."
        }
    }

    private func refreshRevealExplanation() {
        if settings.drawerAvailability == .hiddenTab {
            switch settings.mode {
            case .instant: explanation.stringValue = "Hover at the tab's saved screen-edge location to open."
            case .delayed: explanation.stringValue = "Keep the pointer at the tab's saved screen-edge location for the chosen delay. Moving away cancels opening."
            case .click: explanation.stringValue = "With the tab hidden, hover opens immediately; show the tab to use click."
            }
        } else {
            switch settings.mode {
            case .instant: explanation.stringValue = "Brush the tab to open. Hover shows its resize handles."
            case .delayed: explanation.stringValue = "Keep the pointer over the tab for the chosen delay. Leaving the tab cancels opening."
            case .click: explanation.stringValue = "Click the tab to open. Hover shows its resize handles."
            }
        }
    }

    @objc private func toggleSource(_ sender: NSButton) {
        let source = ClipboardMagnetSource.allCases[sender.tag]
        if sender.state == .on { settings.magnetSources.insert(source) } else { settings.magnetSources.remove(source) }
    }

    private func applyMotion(_ milliseconds: Double, _ direction: ClipboardDrawerDirection) {
        settings.setDrawerMotion(ClipboardDrawerMotionProfile(duration: milliseconds / 1000), for: direction)
    }

    /// Each field, a dimmed one too, records the reset as its own step, so any of them can undo it.
    @objc private func resetTuners() {
        for tuner in tuners { tuner.submit(tuner.spec.defaultValue) }
    }

    /// Two fields side by side, each half the width; a label that wraps grows its tuner upward,
    /// and the two fields stay level.
    private static func row(_ left: NSView, _ right: NSView) -> NSStackView {
        let row = NSStackView(views: [left, right])
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.alignment = .bottom
        row.spacing = 10
        return row
    }

    /// Fit shorter content; scroll taller content within the current display. Settings zooms with the
    /// text size, its window growing with it (its layout unchanged), except while Text size's handle
    /// is held.
    private func fitWindowToContent() {
        guard let window, let stack, let content = window.contentView else { return }
        // The line at the top of what shows stays there through a change of zoom or height.
        let top = scrollView.documentVisibleRect.minY
        if !textSizeTuner.isScrubbing { appliedTextScale = settings.sizes.textScale }
        let scale = appliedTextScale
        ClipboardZoom.apply(scale, to: content)
        scrollView.frame = content.bounds
        documentView.setFrameSize(NSSize(width: Self.contentWidth, height: documentView.frame.height))
        documentView.layoutSubtreeIfNeeded()
        let height = ceil(stack.fittingSize.height) + 44
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: NSSize(width: Self.contentWidth * scale, height: height * scale)))
        let visible = screenFrame?() ?? (window.screen ?? NSScreen.main)?.visibleFrame
        if let visible { frame.size.height = min(frame.height, visible.height) }
        var fitted = NSRect(x: window.frame.minX, y: window.frame.maxY - frame.height, width: frame.width, height: frame.height)
        if let visible {
            fitted.origin.y = min(max(fitted.minY, visible.minY), visible.maxY - fitted.height)
        }
        if let visible { fitted.origin.x = min(max(fitted.minX, visible.minX), max(visible.minX, visible.maxX - fitted.width)) }
        if window.frame != fitted { window.setFrame(fitted, display: true) }
        ClipboardZoom.apply(scale, to: content)
        scrollView.frame = content.bounds
        documentView.setFrameSize(NSSize(width: scrollView.contentSize.width, height: height))
        documentView.layoutSubtreeIfNeeded()
        // Hover finds the fields where the zoomed, resized window now draws them.
        if scale != trackedScale {
            trackedScale = scale
            ClipboardZoom.refreshTracking(in: content)
        }
        let lowestTop = max(0, documentView.frame.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, top), lowestTop)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func applyShortcut(_ shortcut: ClipboardShortcut, for action: ClipboardShortcutAction) {
        let control = action == .quickLook ? quickLookControl : drawerControl
        let current = action == .quickLook ? settings.quickLookShortcut : settings.drawerShortcut
        if let conflict = settings.shortcutConflict(shortcut, for: action) {
            control.showMessage("Already used by \(conflict). \(current.displayString) is unchanged.", error: true)
            refresh()
            return
        }
        let status = (action == .quickLook ? onShortcutChange : onDrawerShortcutChange)?(shortcut) ?? noErr
        if status == noErr {
            if action == .quickLook { settings.quickLookShortcut = shortcut } else { settings.drawerShortcut = shortcut }
            control.showMessage("\(control.recorder.actionName) ← \(shortcut.displayString)")
        } else {
            control.showMessage("That shortcut is unavailable (\(status)). \(current.displayString) is unchanged. Try another combination.", error: true)
        }
        refresh()
    }
}

/// Settings must not take the keyboard while another ClipEdge window hands it back.
/// Its controls take their chords first (a tuner's ⌘Z, Reset's ⌥⌘R, a recorder
/// recording); then a field being edited takes the editing chords; then a ⌘Z or ⇧⌘Z
/// still unclaimed goes to the hovered tuner. Esc that no control took, as after Esc
/// leaves a tuner, goes to the controller, which closes.
private final class SettingsPanel: NSPanel {
    var editingPasteboard = NSPasteboard.general
    var tuners: () -> [ClipboardTuner] = { [] }
    override var canBecomeKey: Bool { ClipboardWindow.mayBecomeKey(self) && super.canBecomeKey }

    /// A press in Settings outside the number being typed leaves it, keeping what was typed, as
    /// leaving does: before, a handle, Reset or a button, which take no keyboard, left it there,
    /// and the number holding it kept every other field's magnets hidden and ⌘Z for itself.
    /// A press on its own field or magnets keeps it; the title bar is not Settings' content.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, let holder = tuners().first(where: \.hasKeyboardFocus), let content = contentView,
           let pressed = content.superview?.hitTest(event.locationInWindow), pressed.isDescendant(of: content),
           !holder.keepsKeyboard(forPressOn: pressed) {
            makeFirstResponder(nil)
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        super.performKeyEquivalent(with: event) || ClipboardFieldEditing.perform(event, in: self, pasteboard: editingPasteboard)
            || tuners().contains { $0.performHoveredChord(event) }
    }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 53, event.chordModifiers.isEmpty,
              let controller = windowController else { return super.keyDown(with: event) }
        // A held Esc repeats: only a fresh press closes, so the press that left a field or
        // ended a recording does not also close Settings.
        if !event.isARepeat { controller.cancelOperation(self) }
    }
}

private final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }

    /// A press on Settings' ground, or on a label, which passes it on, leaves a number being typed and keeps it.
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(nil) }
}
