import AppKit

/// "Ask for a preview": one optional line for what it should show, then
/// Write brief ⌘⏎ or Cancel. Writing puts the brief's place in the form's
/// place, with Open in Obsidian ⌘⏎ and Copy prompt ⌥⌘C; a failure puts a plain
/// sentence there, never a modal. In the window it has no surface of its own;
/// the drawer's panel gives it a card. Maintainer copies only: without an asker
/// nothing opens it.
final class ClipboardPreviewAskView: ClipboardSurfaceView, NSTextFieldDelegate {
    enum Stage: Equatable { case asking, written(ClipboardPreviewBriefRecord), failed(String) }
    var asker: ClipboardPreviewAsker?
    var onBack: (() -> Void)?
    /// The stage changed, so the form wants another size (the drawer's panel follows).
    var onStageChange: (() -> Void)?
    private(set) var stage = Stage.asking
    private(set) var entry: ClipboardEntry?
    /// The one field. Its text is Al's note, verbatim, or nothing.
    let note = NSTextField()
    private let heading = NSTextField(labelWithString: "Ask for a preview")
    private let about = NSTextField(wrappingLabelWithString: "Writes a brief for an agent into the vault: this copy's formats and sizes, never what it holds.")
    private let result = NSTextField(wrappingLabelWithString: "")
    private let copied = NSTextField(wrappingLabelWithString: "")
    private lazy var writeButton = button("Write brief", Self.commandReturn, help: "Write the brief into the vault (Command-Return)", #selector(writePressed))
    private lazy var cancelButton = button("Cancel", nil, help: "Back to the item", #selector(backPressed))
    private lazy var openButton = button("Open in Obsidian", Self.commandReturn, help: "Open the brief in Obsidian (Command-Return)", #selector(openPressed))
    private lazy var copyButton = button("Copy prompt", ClipboardKeyLabel(shown: "⌥⌘C", spoken: "Option-Command-C"), help: "Put the brief's text on the clipboard, which ClipEdge never records (Option-Command-C)", #selector(copyPressed))
    private lazy var backButton = button("Back", nil, help: "Back to the item", #selector(backPressed))
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var resultText: String { result.stringValue }
    /// Who holds the keyboard: the field while asking, the form itself afterwards.
    var stageResponder: NSView { if case .asking = stage { return note } else { return self } }
    var copiedText: String? { copied.isHidden ? nil : copied.stringValue }
    var shownButtons: [String] { buttons.filter { !$0.isHidden }.map(\.keyedTitle.plain) }
    private var buttons: [ClipboardKeyedButton] { [writeButton, cancelButton, openButton, copyButton, backButton] }
    private static let commandReturn = ClipboardKeyLabel(shown: "⌘⏎", spoken: "Command-Return")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        about.font = .systemFont(ofSize: 11)
        about.textColor = .secondaryLabelColor
        note.placeholderString = "What should a better preview show?"
        note.font = .systemFont(ofSize: 12)
        note.delegate = self
        note.setAccessibilityLabel("What should a better preview show?")
        // The whole path shows: it wraps at any character rather than being cut short.
        result.font = .systemFont(ofSize: 12)
        result.lineBreakMode = .byCharWrapping
        result.isSelectable = true
        copied.font = .systemFont(ofSize: 11)
        copied.textColor = .secondaryLabelColor
        copied.isHidden = true
        [heading, about, note, result, copied].forEach(addSubview)
        buttons.forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Ask for a preview")
        reflectStage()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Its name and key, the key in its cap.
    private func button(_ name: String, _ key: ClipboardKeyLabel?, help: String, _ action: Selector) -> ClipboardKeyedButton {
        let button = ClipboardKeyedButton(title: "", target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.keyedTitle = ClipboardKeyedTitle(name: name, key: key)
        button.refusesFirstResponder = true // Space never presses these; the chords in their titles do.
        button.toolTip = help
        button.spokenLabel = help
        return button
    }

    /// A fresh form for this item, with the keyboard in its field.
    func begin(_ entry: ClipboardEntry) {
        self.entry = entry
        note.stringValue = ""
        stage = .asking
        reflectStage()
        window?.makeFirstResponder(stageResponder)
    }

    /// The brief into the vault; the result takes the form's place.
    func write() {
        guard case .asking = stage, let entry, let asker else { return }
        switch asker.write(entry, note: note.stringValue) {
        case .written(let record): stage = .written(record)
        case .failed(let sentence): stage = .failed(sentence)
        }
        reflectStage()
        window?.makeFirstResponder(stageResponder)
    }
    func open() {
        guard case .written(let record) = stage else { return }
        asker?.openInObsidian(record)
    }
    func copyPrompt() {
        guard case .written(let record) = stage, let asker else { return }
        copied.stringValue = asker.copyPrompt(record) ? "Prompt copied. Paste it into a chat; ClipEdge keeps no copy." : "The prompt could not be copied."
        copied.isHidden = false
        needsLayout = true
        onStageChange?() // The extra line wants room: the drawer's panel grows to it.
    }
    func back() { onBack?() }

    private func reflectStage() {
        let asking: Bool = { if case .asking = stage { return true }; return false }()
        let written: Bool = { if case .written = stage { return true }; return false }()
        about.isHidden = !asking
        note.isHidden = !asking
        writeButton.isHidden = !asking
        cancelButton.isHidden = !asking
        openButton.isHidden = !written
        copyButton.isHidden = !written
        backButton.isHidden = asking
        copied.isHidden = true
        switch stage {
        case .asking: result.stringValue = ""
        case .written(let record): result.stringValue = record.sentence
        case .failed(let sentence): result.stringValue = sentence
        }
        result.isHidden = asking
        setAccessibilityValue(asking ? heading.stringValue : result.stringValue)
        needsLayout = true
        onStageChange?()
    }

    // MARK: Keys — ⌘⏎, ⌥⌘C and esc/← wherever the keyboard is; Space never presses anything

    private var isEditingNote: Bool { (window?.firstResponder as? NSTextView)?.delegate === note }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard !isHiddenOrHasHiddenAncestor, entry != nil else { return false }
        let modifiers = event.chordModifiers
        let copyChord = ClipboardChord(key: .letter("c", position: 8), modifiers: .exactly([.option, .command]))
        switch (event.keyCode, modifiers) {
        case (53, []): back(); return true
        case (36, [.command]), (76, [.command]):
            switch stage {
            case .asking: write()
            case .written: open()
            case .failed: break
            }
            return true
        case (_, [.option, .command]) where copyChord.matches(event):
            copyPrompt()
            return true
        case (123, []):
            // With words in the field, Left moves through them; otherwise it goes back.
            guard !(isEditingNote && !note.stringValue.isEmpty) else { return false }
            back()
            return true
        case (49, []): return !isEditingNote
        default: return false
        }
    }

    override func keyDown(with event: NSEvent) {
        if performKeyEquivalent(with: event) { return }
        if event.keyCode == 49 { return }
        super.keyDown(with: event)
    }

    /// The field editor's own commands: Esc and a Left at the start go back;
    /// a plain Return keeps the words, since writing is ⌘⏎.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)): back(); return true
        case #selector(NSResponder.insertNewline(_:)): return true
        case #selector(NSResponder.moveLeft(_:)) where note.stringValue.isEmpty: back(); return true
        default: return false
        }
    }

    @objc private func writePressed() { write() }
    @objc private func openPressed() { open() }
    @objc private func copyPressed() { copyPrompt() }
    @objc private func backPressed() { back() }

    // MARK: Layout

    private static let inset: CGFloat = 16
    private static let rowHeight: CGFloat = 24
    private static let gap: CGFloat = 8
    private static let rowGap: CGFloat = 6

    /// The shown buttons in rows at this width, each with the width its title
    /// needs: one that would cross the right inset starts the next row, so none
    /// is ever clipped. Measured, never resized, so asking leaves the layout alone.
    private func buttonRows(width: CGFloat) -> [[(button: NSButton, width: CGFloat)]] {
        var rows: [[(button: NSButton, width: CGFloat)]] = [[]]
        var x = Self.inset
        for button in buttons where !button.isHidden {
            let wanted = ceil(button.intrinsicContentSize.width) + 8
            if x + wanted > width - Self.inset, !rows[rows.count - 1].isEmpty { rows.append([]); x = Self.inset }
            rows[rows.count - 1].append((button, wanted))
            x += wanted + Self.gap
        }
        return rows
    }

    /// The form's height at this width; the drawer's panel takes it.
    func fittingHeight(width: CGFloat) -> CGFloat {
        let inner = width - Self.inset * 2
        func height(_ label: NSTextField) -> CGFloat { ceil(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: inner, height: 10_000)).height ?? 0) }
        var total: CGFloat = 12 + 18 + 8
        if case .asking = stage { total += height(about) + 10 + 24 + 12 }
        else { total += height(result) + 12 + (copied.isHidden ? 0 : height(copied) + 6) }
        let rows = CGFloat(buttonRows(width: width).count)
        return total + rows * Self.rowHeight + (rows - 1) * Self.rowGap + 14
    }

    override func layout() {
        super.layout()
        let inset = Self.inset, inner = bounds.width - inset * 2
        func height(_ label: NSTextField) -> CGFloat { ceil(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: inner, height: 10_000)).height ?? 0) }
        var y: CGFloat = 12
        heading.frame = NSRect(x: inset, y: y, width: inner, height: 18); y += 18 + 8
        if case .asking = stage {
            about.frame = NSRect(x: inset, y: y, width: inner, height: height(about)); y += about.frame.height + 10
            note.frame = NSRect(x: inset, y: y, width: inner, height: 24); y += 24 + 12
        } else {
            result.frame = NSRect(x: inset, y: y, width: inner, height: height(result)); y += result.frame.height + 12
            if !copied.isHidden { copied.frame = NSRect(x: inset, y: y, width: inner, height: height(copied)); y += copied.frame.height + 6 }
        }
        // Buttons in rows from the left, each at its own width, never clipped.
        for row in buttonRows(width: bounds.width) {
            var x = inset
            for (button, width) in row {
                button.frame = NSRect(x: x, y: y, width: width, height: Self.rowHeight)
                x = button.frame.maxX + Self.gap
            }
            y += Self.rowHeight + Self.rowGap
        }
    }
}

/// The drawer's ask form, in its own panel beside the selected tile.
final class ClipboardPreviewAskPopover {
    let view = ClipboardPreviewAskView(frame: .zero)
    var onClose: (() -> Void)? {
        get { host.onClose }
        set { host.onClose = newValue }
    }
    private let host: ClipboardDrawerSidePanel
    static let width: CGFloat = 320
    var isVisible: Bool { host.isVisible }
    var textScale: () -> CGFloat { get { host.textScale } set { host.textScale = newValue } }
    var frame: NSRect { host.frame }

    init(panel suppliedPanel: NSPanel? = nil) {
        host = ClipboardDrawerSidePanel(title: "ClipEdge Ask for a Preview", content: view, panel: suppliedPanel)
        view.onBack = { [weak self] in self?.close() }
    }

    /// `place` receives the form's wanted size and returns its on-screen frame.
    /// The result can be taller than the form, so the panel follows the stage.
    func show(_ entry: ClipboardEntry, place: @escaping (NSSize) -> NSRect) {
        view.onStageChange = { [weak self] in
            guard let self else { return }
            self.host.show(at: place(self.host.scaled(self.wantedSize)), keyboardOn: self.view.stageResponder)
        }
        view.begin(entry)
    }
    private var wantedSize: NSSize { NSSize(width: Self.width, height: view.fittingHeight(width: Self.width)) }

    func close() {
        view.onStageChange = nil
        host.close()
    }
}
