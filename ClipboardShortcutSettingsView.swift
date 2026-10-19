import AppKit

/// Both configurable commands use the same recorder, reset and error presentation.
final class ClipboardShortcutSettingsView: NSStackView {
    let recorder = ClipboardShortcutRecorder(frame: .zero)
    let resetButton = NSButton(title: "Use Default", target: nil, action: nil)
    private let message = NSTextField(wrappingLabelWithString: "Click the shortcut to record a new combination.")
    var onChange: ((ClipboardShortcut) -> Void)?
    private let defaultShortcut: ClipboardShortcut

    init(title: String, actionName: String, defaultShortcut: ClipboardShortcut) {
        self.defaultShortcut = defaultShortcut
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 14, weight: .semibold)
        recorder.actionName = actionName
        recorder.onRecord = { [weak self] in self?.onChange?($0) }
        recorder.onValidationError = { [weak self] in self?.showMessage($0.isEmpty ? "Click the shortcut to record a new combination." : $0) }
        resetButton.target = self
        resetButton.action = #selector(restoreDefault)
        resetButton.setAccessibilityLabel("Restore \(actionName) shortcut to \(defaultShortcut.accessibilityDescription)")
        let row = NSStackView(views: [recorder, resetButton])
        row.orientation = .horizontal
        row.distribution = .fillEqually
        message.font = .systemFont(ofSize: 12)
        message.textColor = .secondaryLabelColor
        setViews([heading, row, message], in: .leading)
        row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        message.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        recorder.nextKeyView = resetButton
    }

    required init?(coder: NSCoder) { fatalError("Use init(title:actionName:defaultShortcut:)") }

    func showMessage(_ text: String, error: Bool = false) {
        message.stringValue = text
        message.textColor = error ? .systemRed : .secondaryLabelColor
    }

    @objc private func restoreDefault() { onChange?(defaultShortcut) }
}
