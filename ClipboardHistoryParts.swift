import AppKit

/// What the keyboard can do here, as buttons: each title carries its key, in its cap. Buttons
/// that do not fit on one row go on to the next, never cut short; the hint sits after
/// the last button, or on a row of its own when they leave it no room.
final class ClipboardHistoryFooter: NSView {
    struct Item {
        let keyed: ClipboardKeyedTitle
        let help: String
        let action: () -> Void
        init(title: ClipboardKeyedTitle, help: String, action: @escaping () -> Void) { keyed = title; self.help = help; self.action = action }
        /// The title as plain text: "Paste ⏎".
        var title: String { keyed.plain }
    }
    var items: [Item] = [] { didSet { rebuild() } }
    /// Its keys in caps (2026-10-16).
    var hint = ClipboardHint([]) {
        didSet {
            hintLabel.attributedStringValue = hint.attributed(font: hintLabel.font!, color: .secondaryLabelColor, alignment: .right)
            hintLabel.setAccessibilityLabel(hint.spoken)
            needsLayout = true; superview?.needsLayout = true
        }
    }
    /// The hint as plain text: "⏎ or click selects  ·  ⇧⌘A all".
    var hintText: String { hint.plain }
    /// Where the hint shows; as wide as its words.
    var hintFrame: NSRect { hintLabel.frame }
    static let rowHeight: CGFloat = 38
    /// Room for a line of 11-point words with a key cap in it (the cap stands a little taller).
    static let hintRowHeight: CGFloat = 20
    /// Each further row of buttons.
    static let buttonRowStep: CGFloat = 28
    private var buttons: [ClipboardKeyedButton] = []
    private let hintLabel = NSTextField(labelWithString: "")
    private let rule = NSBox()
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        rule.boxType = .separator
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.alignment = .right
        [rule, hintLabel].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func rebuild() {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = items.enumerated().map { index, item in
            let button = ClipboardKeyedButton(title: "", target: self, action: #selector(pressed(_:)))
            button.tag = index
            button.bezelStyle = .accessoryBarAction
            button.showsBorderOnlyWhileMouseInside = true
            button.font = .systemFont(ofSize: 11, weight: .medium)
            button.keyedTitle = item.keyed
            button.refusesFirstResponder = true // The list keeps the keyboard; these mirror its keys.
            button.toolTip = item.help
            button.spokenLabel = item.help
            addSubview(button)
            return button
        }
        needsLayout = true
        superview?.needsLayout = true
    }
    @objc private func pressed(_ sender: NSButton) {
        guard items.indices.contains(sender.tag) else { return }
        items[sender.tag].action()
    }
    /// Where each button goes at this width, each as wide as its title needs (measured, not
    /// resized, so asking leaves the layout alone): one that would cross the right edge starts the next row.
    private func buttonFrames(width: CGFloat) -> [NSRect] {
        var frames: [NSRect] = [], x: CGFloat = 10, y = (Self.rowHeight - 22) / 2 + 1
        for button in buttons {
            let wanted = button.intrinsicContentSize.width + 6
            if x > 10, x + wanted > width - 10 { x = 10; y += Self.buttonRowStep }
            frames.append(NSRect(x: x, y: y, width: wanted, height: 22))
            x += wanted + 4
        }
        return frames
    }
    /// Where the buttons show: their frames as laid out.
    var shownButtonFrames: [NSRect] { buttons.map(\.frame) }
    /// The rows the buttons take at this width, and whether the hint fits after the last button.
    private func plan(width: CGFloat) -> (frames: [NSRect], buttonsHeight: CGFloat, hintBeside: Bool) {
        let frames = buttonFrames(width: width)
        let rows = Set(frames.map(\.minY)).count
        let words = ceil(hint.attributed(font: hintLabel.font!, color: .secondaryLabelColor).size().width)
        let afterButtons = (frames.last?.maxX ?? 6) + 4
        return (frames, Self.rowHeight + CGFloat(max(0, rows - 1)) * Self.buttonRowStep, afterButtons + 20 + words <= width)
    }
    /// Its rows of buttons, and one more for the hint when its words would not fit after them.
    func preferredHeight(for width: CGFloat) -> CGFloat {
        let plan = plan(width: width)
        return plan.buttonsHeight + (plan.hintBeside ? 0 : Self.hintRowHeight)
    }
    override func layout() {
        super.layout()
        rule.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
        let plan = plan(width: bounds.width)
        zip(buttons, plan.frames).forEach { $0.frame = $1 }
        if plan.hintBeside {
            let last = plan.frames.last ?? NSRect(x: 0, y: (Self.rowHeight - 22) / 2 + 1, width: 6, height: 22)
            let x = last.maxX + 4
            hintLabel.frame = NSRect(x: x + 6, y: last.minY + 2, width: max(0, bounds.width - x - 20), height: 18)
        } else {
            hintLabel.frame = NSRect(x: 15, y: plan.buttonsHeight, width: max(0, bounds.width - 30), height: 18)
        }
    }
}
