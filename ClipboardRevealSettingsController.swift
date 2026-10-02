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
    private var changeObserver: NSObjectProtocol?
    /// Registration must succeed before the preference (and displayed hints)
    /// change. A nil hook is for isolated settings fixtures, not live delivery.
    var onShortcutChange: ((ClipboardShortcut) -> OSStatus)?
    var isRecordingShortcut: Bool { recorder.isRecording }

    init(settings: ClipboardRevealSettings) {
        self.settings = settings
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 574),
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
        let stack = NSStackView(views: [title, modePicker, labelRow, delaySlider, explanation,
                                       closeTitle, closeRow, dismissalSlider, closeExplanation,
                                       shortcutTitle, shortcutRow, shortcutMessage])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(20, after: explanation)
        stack.setCustomSpacing(20, after: closeExplanation)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        for view in [modePicker, labelRow, delaySlider, explanation, closeRow, dismissalSlider, closeExplanation, shortcutRow, shortcutMessage] {
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
        resetShortcut.nextKeyView = modePicker
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
        switch settings.mode {
        case .instant: explanation.stringValue = "Brush the tab to open. Hover shows its resize handles."
        case .delayed: explanation.stringValue = "Keep the pointer over the tab for the chosen delay. Leaving the tab cancels opening."
        case .click: explanation.stringValue = "Click the tab to open. Hover shows its resize handles."
        }
    }

    @objc private func changeRevealMode() { settings.mode = ClipboardRevealMode.allCases[modePicker.indexOfSelectedItem] }
    @objc private func changeDelay() { settings.delaySeconds = (delaySlider.doubleValue * 20).rounded() / 20 }
    @objc private func changeDismissalDelay() { settings.dismissalDelaySeconds = (dismissalSlider.doubleValue * 20).rounded() / 20 }
    @objc private func restoreShortcut() { applyShortcut(.defaultQuickLook) }

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
