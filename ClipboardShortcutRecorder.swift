import AppKit

/// Only consumes keys while explicitly recording; Escape cancels without
/// changing the stored shortcut. Bare typing is never a global shortcut.
final class ClipboardShortcutRecorder: NSButton {
    private enum State { case idle, recording }
    private var recordingState = State.idle
    var shortcut = ClipboardShortcut.defaultQuickLook { didSet { refresh() } }
    var onRecord: ((ClipboardShortcut) -> Void)?
    var onValidationError: ((String) -> Void)?
    var isRecording: Bool { recordingState == .recording }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        bezelStyle = .rounded
        target = self
        action = #selector(beginRecording)
        setAccessibilityLabel("Quick Look global shortcut")
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    @objc private func beginRecording() {
        recordingState = .recording
        window?.makeFirstResponder(self)
        onValidationError?("Press a shortcut using Control, Option, or Command. Escape cancels.")
        refresh()
    }

    override func keyDown(with event: NSEvent) {
        guard case .recording = recordingState else { super.keyDown(with: event); return }
        if event.keyCode == 53, event.modifierFlags.intersection([.control, .option, .shift, .command]).isEmpty {
            recordingState = .idle
            onValidationError?("")
            refresh()
            return
        }
        guard !event.isARepeat else { return }
        guard let shortcut = ClipboardShortcut(keyCode: UInt32(event.keyCode), modifiers: event.modifierFlags) else {
            onValidationError?("Include Control, Option, or Command; plain typing and Shift alone are not global shortcuts.")
            return
        }
        recordingState = .idle
        onRecord?(shortcut)
        refresh()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard case .recording = recordingState else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func resignFirstResponder() -> Bool {
        if isRecording { onValidationError?("") }
        recordingState = .idle
        refresh()
        return super.resignFirstResponder()
    }

    private func refresh() {
        title = recordingState == .recording ? "Type shortcut…" : shortcut.displayString
        setAccessibilityValue(recordingState == .recording ? "Recording shortcut" : shortcut.accessibilityDescription)
        toolTip = "Click to record a new global Quick Look shortcut."
    }
}
