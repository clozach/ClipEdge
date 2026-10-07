import AppKit

/// Native controls remain open while changes apply, so the nearby tab can be
/// tried repeatedly. The same settings instance is read by EdgeController.
final class ClipboardRevealSettingsController: NSWindowController {
    private let settings: ClipboardRevealSettings
    private let modePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let delaySlider = NSSlider(value: 0.35, minValue: 0, maxValue: 2, target: nil, action: nil)
    private let delayValue = NSTextField(labelWithString: "")
    private let explanation = NSTextField(wrappingLabelWithString: "")
    private let dismissalSlider = NSSlider(value: 0.5, minValue: 0, maxValue: 3, target: nil, action: nil)
    private let dismissalValue = NSTextField(labelWithString: "")
    private let recorder = ClipboardShortcutRecorder(frame: .zero)
    private let resetShortcut = NSButton(title: "Use Default", target: nil, action: nil)
    private let shortcutMessage = NSTextField(wrappingLabelWithString: "Click the shortcut to record a new combination.")
    private let recallPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let magnetsBox = NSButton(checkboxWithTitle: "Show cursor magnets", target: nil, action: nil)
    private let sourceBoxes = ClipboardMagnetSource.allCases.map { NSButton(checkboxWithTitle: $0.title, target: nil, action: nil) }
    private let sourceStack = NSStackView()
    private var stack: NSStackView?
    private var changeObserver: NSObjectProtocol?
    /// Registration must succeed before the preference (and displayed hints)
    /// change. A nil hook is for isolated settings fixtures, not live delivery.
    var onShortcutChange: ((ClipboardShortcut) -> OSStatus)?
    var isRecordingShortcut: Bool { recorder.isRecording }

    init(settings: ClipboardRevealSettings) {
        self.settings = settings
        let panel = SettingsPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 580),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "ClipEdge Settings"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        super.init(window: panel)
        buildContent(in: panel)
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
        window?.makeFirstResponder(modePicker)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    override func cancelOperation(_ sender: Any?) { close() }

    func makeMenuItem(keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: "Settings…", action: #selector(show), keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    private func buildContent(in panel: NSPanel) {
        guard let content = panel.contentView else { return }
        let title = NSTextField(labelWithString: "Open the drawer")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        modePicker.addItems(withTitles: ClipboardRevealMode.allCases.map(\.title))
        modePicker.target = self
        modePicker.action = #selector(changeRevealMode)
        modePicker.setAccessibilityLabel("Reveal mode")
        let delayTitle = NSTextField(labelWithString: "Hover delay")
        delayValue.alignment = .right
        delayValue.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        delaySlider.target = self
        delaySlider.action = #selector(changeDelay)
        delaySlider.isContinuous = true
        delaySlider.setAccessibilityLabel("Hover delay in seconds")
        delaySlider.toolTip = "0–2 seconds. Arrow keys adjust the delay."
        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = .secondaryLabelColor
        let labelRow = NSStackView(views: [delayTitle, NSView(), delayValue])
        labelRow.orientation = .horizontal
        let closeTitle = NSTextField(labelWithString: "Close the drawer")
        closeTitle.font = title.font
        let closeLabel = NSTextField(labelWithString: "Maximum close delay")
        dismissalValue.alignment = .right
        dismissalValue.font = delayValue.font
        let closeRow = NSStackView(views: [closeLabel, NSView(), dismissalValue])
        closeRow.orientation = .horizontal
        dismissalSlider.target = self
        dismissalSlider.action = #selector(changeDismissalDelay)
        dismissalSlider.isContinuous = true
        dismissalSlider.setAccessibilityLabel("Maximum close delay in seconds")
        dismissalSlider.toolTip = "0–3 seconds near the edge; zero at 200 points away."
        let closeExplanation = NSTextField(wrappingLabelWithString: "Near the edge, wait up to this long. The delay decreases with distance. At 200 points away it closes immediately; returning inside cancels closing.")
        closeExplanation.font = explanation.font
        closeExplanation.textColor = .secondaryLabelColor
        let shortcutTitle = NSTextField(labelWithString: "Global Quick Look shortcut")
        shortcutTitle.font = title.font
        recorder.onRecord = { [weak self] in self?.applyShortcut($0) }
        recorder.onValidationError = { [weak self] message in
            self?.shortcutMessage.stringValue = message.isEmpty ? "Click the shortcut to record a new combination." : message
            self?.shortcutMessage.textColor = .secondaryLabelColor
        }
        resetShortcut.target = self
        resetShortcut.action = #selector(restoreShortcut)
        resetShortcut.setAccessibilityLabel("Restore Control–Option–Space shortcut")
        let shortcutRow = NSStackView(views: [recorder, resetShortcut])
        shortcutRow.orientation = .horizontal
        shortcutRow.distribution = .fillEqually
        shortcutMessage.font = explanation.font
        shortcutMessage.textColor = .secondaryLabelColor
        let recallTitle = NSTextField(labelWithString: "Reopen on the last search")
        recallTitle.font = title.font
        recallPicker.addItems(withTitles: ClipboardRevealSettings.recallChoices.map(ClipboardRevealSettings.recallTitle))
        recallPicker.target = self
        recallPicker.action = #selector(changeRecall)
        recallPicker.setAccessibilityLabel("Reopen on the last search")
        let recallExplanation = NSTextField(wrappingLabelWithString: "After you paste, copy, open or send an item, the drawer and the ⌥⌘\\ window reopen on the search that found it, with the item selected. Typing replaces the search.")
        recallExplanation.font = explanation.font
        recallExplanation.textColor = .secondaryLabelColor
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
        let stack = NSStackView(views: [title, modePicker, labelRow, delaySlider, explanation,
                                       closeTitle, closeRow, dismissalSlider, closeExplanation,
                                       shortcutTitle, shortcutRow, shortcutMessage,
                                       recallTitle, recallPicker, recallExplanation,
                                       magnetsTitle, magnetsBox, sourceStack, magnetsExplanation])
        self.stack = stack
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(20, after: explanation)
        stack.setCustomSpacing(20, after: closeExplanation)
        stack.setCustomSpacing(20, after: shortcutMessage)
        stack.setCustomSpacing(20, after: recallExplanation)
        stack.setCustomSpacing(6, after: magnetsBox)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        for view in [modePicker, labelRow, delaySlider, explanation, closeRow, dismissalSlider, closeExplanation, shortcutRow, shortcutMessage, recallPicker, recallExplanation, magnetsExplanation] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -22),
            delayValue.widthAnchor.constraint(equalToConstant: 90),
            dismissalValue.widthAnchor.constraint(equalToConstant: 90),
            shortcutMessage.heightAnchor.constraint(greaterThanOrEqualToConstant: 42)
        ])
        panel.initialFirstResponder = modePicker
        panel.autorecalculatesKeyViewLoop = false
        modePicker.nextKeyView = delaySlider
        delaySlider.nextKeyView = dismissalSlider
        dismissalSlider.nextKeyView = recorder
        recorder.nextKeyView = resetShortcut
        resetShortcut.nextKeyView = recallPicker
        recallPicker.nextKeyView = magnetsBox
    }

    private func refresh() {
        modePicker.selectItem(at: ClipboardRevealMode.allCases.firstIndex(of: settings.mode) ?? 0)
        delaySlider.doubleValue = settings.delaySeconds
        delaySlider.isEnabled = settings.mode == .delayed
        delayValue.stringValue = String(format: "%.2f seconds", settings.delaySeconds)
        delayValue.textColor = delaySlider.isEnabled ? .labelColor : .secondaryLabelColor
        delaySlider.setAccessibilityValueDescription(delayValue.stringValue)
        dismissalSlider.doubleValue = settings.dismissalDelaySeconds
        dismissalValue.stringValue = String(format: "%.2f seconds", settings.dismissalDelaySeconds)
        dismissalSlider.setAccessibilityValueDescription(dismissalValue.stringValue)
        recorder.shortcut = settings.quickLookShortcut
        recallPicker.selectItem(at: ClipboardRevealSettings.recallChoices.firstIndex(of: settings.recallMinutes) ?? 0)
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
        for (box, next) in zip([magnetsBox] + shown, shown + [modePicker]) { box.nextKeyView = next }
        switch settings.mode {
        case .instant: explanation.stringValue = "Brush the tab to open. Hover shows its resize handles."
        case .delayed: explanation.stringValue = "Keep the pointer over the tab for the chosen delay. Leaving the tab cancels opening."
        case .click: explanation.stringValue = "Click the tab to open. Hover shows its resize handles."
        }
        fitWindowToContent()
    }

    @objc private func changeRevealMode() { settings.mode = ClipboardRevealMode.allCases[modePicker.indexOfSelectedItem] }
    @objc private func changeDelay() { settings.delaySeconds = (delaySlider.doubleValue * 20).rounded() / 20 }
    @objc private func changeDismissalDelay() { settings.dismissalDelaySeconds = (dismissalSlider.doubleValue * 20).rounded() / 20 }
    @objc private func restoreShortcut() { applyShortcut(.defaultQuickLook) }
    @objc private func toggleMagnets() { settings.magnetsEnabled = magnetsBox.state == .on }

    @objc private func toggleSource(_ sender: NSButton) {
        let source = ClipboardMagnetSource.allCases[sender.tag]
        if sender.state == .on { settings.magnetSources.insert(source) } else { settings.magnetSources.remove(source) }
    }

    /// The window grows and shrinks with the magnet choices, keeping its top edge where it is.
    private func fitWindowToContent() {
        guard let window, let stack, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let height = ceil(stack.fittingSize.height) + 44
        let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: NSSize(width: content.bounds.width, height: height)))
        guard abs(frame.height - window.frame.height) > 0.5 else { return }
        var fitted = NSRect(x: window.frame.minX, y: window.frame.maxY - frame.height, width: window.frame.width, height: frame.height)
        // Growing downward must not push the bottom edge off the screen.
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame, fitted.minY < visible.minY {
            fitted.origin.y = min(visible.minY, visible.maxY - fitted.height)
        }
        window.setFrame(fitted, display: true)
    }

    @objc private func changeRecall() { settings.recallMinutes = ClipboardRevealSettings.recallChoices[recallPicker.indexOfSelectedItem] }

    private func applyShortcut(_ shortcut: ClipboardShortcut) {
        let status = onShortcutChange?(shortcut) ?? noErr
        if status == noErr {
            settings.quickLookShortcut = shortcut
            shortcutMessage.stringValue = "Quick Look ← \(shortcut.displayString)"
            shortcutMessage.textColor = .secondaryLabelColor
        } else {
            shortcutMessage.stringValue = "That shortcut is unavailable (\(status)). \(settings.quickLookShortcut.displayString) is unchanged. Try another combination."
            shortcutMessage.textColor = .systemRed
        }
        refresh()
    }
}

/// Settings must not take the keyboard while another ClipEdge window hands it back.
private final class SettingsPanel: NSPanel {
    override var canBecomeKey: Bool { ClipboardWindow.mayBecomeKey(self) && super.canBecomeKey }
}
