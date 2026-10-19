import AppKit

/// Only consumes keys while explicitly recording; Escape cancels without
/// changing the stored shortcut. Bare typing is never a global shortcut.
final class ClipboardShortcutRecorder: NSButton {
    private enum State { case idle, recording }
    private var recordingState = State.idle
    var shortcut = ClipboardShortcut.defaultQuickLook { didSet { refresh() } }
    var onRecord: ((ClipboardShortcut) -> Void)?
    var onValidationError: ((String) -> Void)?
    var onRecordingChange: (() -> Void)?
    var actionName = "Quick Look" { didSet { refresh() } }
    var isRecording: Bool { recordingState == .recording }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        bezelStyle = .rounded
        target = self
        action = #selector(beginRecording)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    @objc private func beginRecording() {
        guard !isRecording else { return }
        recordingState = .recording
        window?.makeFirstResponder(self)
        onRecordingChange?()
        onValidationError?("Press a shortcut using Control, Option, or Command.")
        refresh()
    }

    override func keyDown(with event: NSEvent) {
        guard case .recording = recordingState else { super.keyDown(with: event); return }
        if event.keyCode == 53, event.chordModifiers.isEmpty {
            cancelRecording()
            return
        }
        guard !event.isARepeat else { return }
        guard let shortcut = ClipboardShortcut(keyCode: UInt32(event.keyCode), modifiers: event.modifierFlags) else {
            onValidationError?("Include Control, Option, or Command; plain typing and Shift alone are not global shortcuts.")
            return
        }
        recordingState = .idle
        onRecord?(shortcut)
        onRecordingChange?()
        refresh()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard case .recording = recordingState else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func resignFirstResponder() -> Bool {
        cancelRecording()
        return super.resignFirstResponder()
    }

    func cancelRecording() {
        guard isRecording else { return }
        recordingState = .idle
        onValidationError?("")
        onRecordingChange?()
        refresh()
    }

    private func refresh() {
        title = recordingState == .recording ? "Type shortcut…" : shortcut.displayString
        setAccessibilityLabel("\(actionName) global shortcut")
        setAccessibilityValue(recordingState == .recording ? "Recording shortcut" : shortcut.accessibilityDescription)
        toolTip = "Click to record a new global \(actionName) shortcut."
    }
}
