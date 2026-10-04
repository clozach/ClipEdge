import AppKit

/// One entry at reading size, with its date, facts and paths along the bottom edge.
final class ClipboardHistoryCard: NSView {
    private let image = NSImageView()
    private let text = NSTextField(wrappingLabelWithString: "")
    private let edge = NSTextField(wrappingLabelWithString: "")
    private(set) var entryID: UUID?
    var edgeText: String { edge.stringValue }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        image.imageScaling = .scaleProportionallyUpOrDown
        text.font = .systemFont(ofSize: 13)
        text.cell?.truncatesLastVisibleLine = true
        edge.font = .systemFont(ofSize: 10)
        edge.textColor = .secondaryLabelColor
        edge.lineBreakMode = .byCharWrapping
        edge.isSelectable = false
        [image, text, edge].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ entry: ClipboardEntry?) {
        entryID = entry?.id
        guard let entry else {
            image.image = nil; text.stringValue = ""; edge.stringValue = ""
            return
        }
        let isText = entry.kind == .text || entry.kind == .link || (entry.thumbnail == nil && entry.plainText != nil)
        image.image = isText ? nil : (entry.thumbnail ?? ClipboardIcons.symbol(entry.kind.iconName))
        image.isHidden = isText
        // A picture needs no caption; a Finder item keeps its name beneath its thumbnail.
        text.stringValue = isText ? String((entry.plainText ?? entry.title).prefix(4_000)) : (entry.isImage && entry.fileURLs.isEmpty ? "" : entry.title)
        text.alignment = isText ? .natural : .center
        edge.stringValue = ([entry.dateTimeStamp] + entry.metadata.lines).joined(separator: "\n")
        edge.toolTip = entry.fullDateTimeStamp
        setAccessibilityLabel("\(entry.title). \(edge.stringValue)")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 14
        let width = bounds.width - inset * 2
        let edgeHeight = ceil(edge.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10_000)).height ?? 14)
        edge.frame = NSRect(x: inset, y: bounds.height - inset - edgeHeight, width: width, height: edgeHeight)
        let body = NSRect(x: inset, y: inset, width: width, height: max(0, edge.frame.minY - inset - 10))
        if image.isHidden {
            text.frame = body
        } else {
            let captionHeight: CGFloat = text.stringValue.isEmpty ? 0 : 40
            image.frame = NSRect(x: body.minX, y: body.minY, width: body.width, height: max(0, body.height - captionHeight))
            text.frame = NSRect(x: body.minX, y: image.frame.maxY + 6, width: body.width, height: max(0, captionHeight - 6))
        }
    }
}

/// What the keyboard can do here, as buttons: each title carries its key.
final class ClipboardHistoryFooter: NSView {
    struct Item { let title: String; let help: String; let action: () -> Void }
    var items: [Item] = [] { didSet { rebuild() } }
    var hint = "" { didSet { hintLabel.stringValue = hint; needsLayout = true } }
    private var buttons: [NSButton] = []
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
            let button = NSButton(title: item.title, target: self, action: #selector(pressed(_:)))
            button.tag = index
            button.bezelStyle = .accessoryBarAction
            button.showsBorderOnlyWhileMouseInside = true
            button.font = .systemFont(ofSize: 11, weight: .medium)
            button.refusesFirstResponder = true // The list keeps the keyboard; these mirror its keys.
            button.toolTip = item.help
            button.setAccessibilityLabel(item.help)
            addSubview(button)
            return button
        }
        needsLayout = true
    }
    @objc private func pressed(_ sender: NSButton) {
        guard items.indices.contains(sender.tag) else { return }
        items[sender.tag].action()
    }
    override func layout() {
        super.layout()
        rule.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
        var x: CGFloat = 10
        for button in buttons {
            button.sizeToFit()
            button.frame = NSRect(x: x, y: (bounds.height - 22) / 2 + 1, width: button.frame.width + 6, height: 22)
            x = button.frame.maxX + 4
        }
        hintLabel.frame = NSRect(x: x + 6, y: (bounds.height - 15) / 2 + 1, width: max(0, bounds.width - x - 20), height: 15)
    }
}

/// 🚨 The delete-all question, in place of the card. Nothing is deleted until
/// ⇧⌘⌫ is pressed a second time.
final class ClipboardHistoryConfirmation: NSView {
    private let title = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "🚨 This removes every item in ClipEdge's history, not only the ones shown, with its saved copies and preview files. It cannot be undone. Original files stay where they are. If the clipboard holds an item from the history, it is cleared too.")
    private let keys = NSTextField(wrappingLabelWithString: "⇧⌘⌫ again deletes all  ·  esc keeps")
    var titleText: String { title.stringValue }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.systemRed.cgColor
        layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.06).cgColor
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .systemRed
        detail.font = .systemFont(ofSize: 12)
        keys.font = .systemFont(ofSize: 12, weight: .medium)
        keys.textColor = .systemRed
        [title, detail, keys].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(count: Int) {
        title.stringValue = count == 1 ? "Delete the one clipboard item?" : "Delete all \(count) clipboard items?"
        setAccessibilityLabel("\(title.stringValue) \(detail.stringValue) \(keys.stringValue)")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 18
        for label in [title, detail, keys] {
            let height = ceil(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: bounds.width - 36, height: 10_000)).height ?? 18)
            label.frame = NSRect(x: 18, y: y, width: bounds.width - 36, height: height)
            y += height + 12
        }
    }
}
