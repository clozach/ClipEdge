import AppKit

/// One entry at reading size, with its date, facts and paths along the bottom edge.
final class ClipboardHistoryCard: NSView {
    private let image = NSImageView()
    private let swatch = ClipboardSwatchView(frame: .zero)
    private let text = NSTextField(wrappingLabelWithString: "")
    private let edge = NSTextField(wrappingLabelWithString: "")
    /// Figma layers' link back, on one line under their explanation.
    private let link = NSTextField(labelWithString: "")
    /// What Figma text is beyond its words: where its layers paste.
    private let note = NSTextField(wrappingLabelWithString: "")
    private var showsSymbol = false
    private(set) var entryID: UUID?
    var edgeText: String { edge.stringValue }
    var bodyText: String { text.stringValue }
    var linkText: String? { link.isHidden ? nil : link.stringValue }
    var noteText: String? { note.isHidden ? nil : note.stringValue }
    /// The picture's size on the card: a symbol keeps its own, a thumbnail fills.
    var imageFrame: NSRect? { image.isHidden ? nil : image.frame }
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
        link.font = .systemFont(ofSize: 11)
        link.textColor = .secondaryLabelColor
        link.lineBreakMode = .byTruncatingMiddle
        link.alignment = .center
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        note.isSelectable = false
        note.isHidden = true
        [image, text, edge, swatch, link, note].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ entry: ClipboardEntry?) {
        entryID = entry?.id
        swatch.color = entry?.swatchColor
        guard let entry else {
            image.image = nil; text.stringValue = ""; edge.stringValue = ""; link.isHidden = true; note.isHidden = true
            return
        }
        let isText: Bool = {
            switch entry.kind {
            case .text, .link, .html: return true
            case .figma(let copy): return copy.carriedText != nil
            default: return false
            }
        }()
        // A thumbnail fills the card; a symbol keeps its own size and is never stretched.
        showsSymbol = !isText && entry.thumbnail == nil
        image.image = isText ? nil : (entry.thumbnail ?? ClipboardIcons.symbol(entry.kind.iconName, pointSize: 40))
        image.imageScaling = showsSymbol ? .scaleProportionallyDown : .scaleProportionallyUpOrDown
        image.isHidden = isText
        edge.stringValue = ([entry.dateTimeStamp] + entry.metadata.lines).joined(separator: "\n")
        edge.toolTip = entry.fullDateTimeStamp
        if case .figma(let copy) = entry.kind, let words = copy.carriedText {
            // Figma text reads as the text it is; the note says where its layers paste,
            // with this window's own plain-text key.
            text.font = .systemFont(ofSize: 13)
            text.textColor = .labelColor
            text.stringValue = String(words.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4_000))
            text.alignment = .natural
            note.stringValue = copy.explanation + " ⌃⌘⏎ pastes the text."
            note.isHidden = false
            showLink(copy)
        } else if case .figma(let copy) = entry.kind {
            let centered = NSMutableParagraphStyle()
            centered.alignment = .center
            let shown = NSMutableAttributedString(string: copy.title + "\n", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .paragraphStyle: centered, .foregroundColor: NSColor.labelColor])
            // The window's own key: ⌃⌘V would paste the clipboard, not this row.
            shown.append(NSAttributedString(string: copy.explanation + " ⌃⌘⏎ pastes the link.", attributes: [.font: NSFont.systemFont(ofSize: 12), .paragraphStyle: centered, .foregroundColor: NSColor.labelColor]))
            text.attributedStringValue = shown
            note.isHidden = true
            showLink(copy)
        } else {
            text.font = .systemFont(ofSize: 13)
            text.textColor = .labelColor
            // A picture needs no caption; a Finder item keeps its name beneath its thumbnail.
            text.stringValue = swatch.color != nil ? "" : isText ? String((entry.readableText ?? entry.title).prefix(4_000)) : (entry.isImage && entry.fileURLs.isEmpty ? "" : entry.title)
            text.alignment = isText ? .natural : .center
            link.isHidden = true
            note.isHidden = true
            setAccessibilityLabel("\(entry.title). \(edge.stringValue)")
        }
        needsLayout = true
    }

    private func showLink(_ copy: ClipboardFigmaCopy) {
        link.stringValue = copy.link.absoluteString
        link.toolTip = copy.link.absoluteString
        link.isHidden = false
        setAccessibilityLabel("\(copy.summary) \(copy.link.absoluteString). \(edge.stringValue)")
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 14
        let width = bounds.width - inset * 2
        let edgeHeight = ceil(edge.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10_000)).height ?? 14)
        edge.frame = NSRect(x: inset, y: bounds.height - inset - edgeHeight, width: width, height: edgeHeight)
        let body = NSRect(x: inset, y: inset, width: width, height: max(0, edge.frame.minY - inset - 10))
        if swatch.color != nil {
            let side = min(240, body.width, body.height)
            swatch.frame = NSRect(x: body.midX - side / 2, y: body.midY - side / 2, width: side, height: side)
            text.frame = .zero
        } else if image.isHidden {
            // Text fills the card; Figma text keeps its note and its link beneath.
            let noteHeight = note.isHidden ? 0 : ceil(note.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: body.width, height: 10_000)).height ?? 0)
            let below = (noteHeight > 0 ? noteHeight + 8 : 0) + (link.isHidden ? 0 : 24)
            text.frame = NSRect(x: body.minX, y: body.minY, width: body.width, height: max(0, body.height - below))
            note.frame = NSRect(x: body.minX, y: text.frame.maxY + 8, width: body.width, height: noteHeight)
            link.frame = NSRect(x: body.minX, y: body.maxY - 16, width: body.width, height: 16)
        } else if showsSymbol {
            // A symbol at its own size, with its words beneath (Figma layers add their
            // link), the whole block centered in the card.
            let symbol = min(56, body.height)
            let room = max(0, body.height - symbol - 10 - (link.isHidden ? 0 : 24))
            let wanted = ceil(text.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: body.width, height: 10_000)).height ?? 0)
            let words = text.stringValue.isEmpty ? 0 : min(link.isHidden ? 34 : wanted, room)
            let block = symbol + (words > 0 ? 10 + words : 0) + (link.isHidden ? 0 : 24)
            let top = body.minY + max(0, (body.height - block) / 2)
            image.frame = NSRect(x: body.minX, y: top, width: body.width, height: symbol)
            text.frame = NSRect(x: body.minX, y: image.frame.maxY + 10, width: body.width, height: words)
            link.frame = NSRect(x: body.minX, y: text.frame.maxY + 8, width: body.width, height: 16)
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
final class ClipboardHistoryConfirmation: ClipboardSurfaceView {
    private let title = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "🚨 This removes every item in ClipEdge's history, not only the ones shown, with its saved copies and preview files. It cannot be undone. Original files stay where they are. If the clipboard holds an item from the history, it is cleared too.")
    private let keys = NSTextField(wrappingLabelWithString: "⇧⌘⌫ again deletes all  ·  esc keeps")
    var titleText: String { title.stringValue }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        surface = ClipboardSurface(fill: .init(color: .systemRed, opacity: 0.06), rim: .systemRed, radius: 9)
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
