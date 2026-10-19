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
    /// App data's formats, one per line and whole: this is the "what is this"
    /// view, so a long list scrolls rather than being cut short.
    private let formats = NSTextField(wrappingLabelWithString: "")
    private let formatsScroll = NSScrollView()
    private var showsSymbol = false
    private(set) var entryID: UUID?
    var edgeText: String { edge.stringValue }
    var bodyText: String { text.stringValue }
    var linkText: String? { link.isHidden ? nil : link.stringValue }
    var noteText: String? { note.isHidden ? nil : note.stringValue }
    var formatsText: String? { formatsScroll.isHidden ? nil : formats.stringValue }
    /// Where the formats show, and how much of the list that frame reaches (the rest scrolls).
    var formatsFrame: (visible: NSRect, whole: NSRect)? { formatsScroll.isHidden ? nil : (formatsScroll.frame, formats.frame) }
    /// Where in the list the scroller is showing: its top is `.zero`.
    var formatsScrolledTo: NSPoint? { formatsScroll.isHidden ? nil : formatsScroll.documentVisibleRect.origin }
    /// The picture's size on the card: a symbol keeps its own, a thumbnail fills.
    var imageFrame: NSRect? { image.isHidden ? nil : image.frame }
    /// The window's keys, for the plain-text paste its notes name.
    private let keymap: ClipboardKeymap
    override var isFlipped: Bool { true }

    override convenience init(frame frameRect: NSRect) { self.init(frame: frameRect, keymap: .window) }
    init(frame frameRect: NSRect, keymap: ClipboardKeymap) {
        self.keymap = keymap
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
        formats.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        formats.textColor = .secondaryLabelColor
        formats.lineBreakMode = .byCharWrapping
        formats.isSelectable = false
        formatsScroll.documentView = formats
        formatsScroll.hasVerticalScroller = true
        formatsScroll.autohidesScrollers = true
        formatsScroll.drawsBackground = false
        formatsScroll.isHidden = true
        [image, text, edge, swatch, link, note, formatsScroll].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ entry: ClipboardEntry?) {
        entryID = entry?.id
        swatch.color = entry?.swatchColor
        formatsScroll.isHidden = true
        guard let entry else {
            image.image = nil; text.stringValue = ""; edge.stringValue = ""; link.isHidden = true; note.isHidden = true
            return
        }
        // An entry reads as text where the Text tab lists it.
        let isText = ClipboardBrowserTab.text.includes(entry)
        // A thumbnail fills the card; a symbol keeps its own size and is never stretched.
        showsSymbol = !isText && entry.thumbnail == nil
        image.image = isText ? nil : (entry.thumbnail ?? ClipboardIcons.symbol(entry.kind.iconName, pointSize: 40))
        image.imageScaling = showsSymbol ? .scaleProportionallyDown : .scaleProportionallyUpOrDown
        image.isHidden = isText
        // A copy Quick Look is handed as a typed file says so after its facts.
        let typed = ClipboardTypedPreview.choice(for: entry).map { [$0.fact] } ?? []
        edge.stringValue = ([entry.dateTimeStamp] + entry.metadata.lines + typed).joined(separator: "\n")
        edge.toolTip = entry.fullDateTimeStamp
        if case .figma(let copy) = entry.kind, let words = copy.carriedText {
            // Figma text reads as the text it is; the note says where its layers paste,
            // with this window's own plain-text key.
            text.font = .systemFont(ofSize: 13)
            text.textColor = .labelColor
            text.stringValue = String(words.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4_000))
            text.alignment = .natural
            note.stringValue = copy.explanation + (keymap.label(.plainPaste).map { " \($0) pastes the text." } ?? "")
            note.isHidden = false
            showLink(copy)
        } else if case .figma(let copy) = entry.kind {
            // The window's own key: ⌃⌘V would paste the clipboard, not this row.
            text.attributedStringValue = Self.titled(copy.title, over: copy.explanation + (keymap.label(.plainPaste).map { " \($0) pastes the link." } ?? ""))
            note.isHidden = true
            showLink(copy)
        } else if case .appData(let data) = entry.kind {
            // What it is and where it pastes, then every format, whole.
            text.attributedStringValue = Self.titled(data.title, over: ClipboardAppData.explanation)
            formats.stringValue = data.formatList
            formats.toolTip = data.formatList
            formatsScroll.isHidden = false
            link.isHidden = true
            note.isHidden = true
            setAccessibilityLabel("\(data.summary) \(data.formatList). \(edge.stringValue)")
        } else {
            text.font = .systemFont(ofSize: 13)
            text.textColor = .labelColor
            // A picture needs no caption, unless it is also app data: then the app's name and
            // where it pastes go beneath it. A Finder item keeps its name beneath its thumbnail.
            let caption = entry.isImage && entry.fileURLs.isEmpty ? (entry.appData?.summary ?? "") : entry.title
            text.stringValue = swatch.color != nil ? "" : isText ? String((entry.readableText ?? entry.title).prefix(4_000)) : caption
            text.alignment = isText ? .natural : .center
            link.isHidden = true
            note.isHidden = true
            // Name the item once: its title, the app's note when a picture carries one, then the facts.
            let aside = caption.isEmpty || caption == entry.title ? "" : "\(caption) "
            setAccessibilityLabel("\(entry.title). \(aside)\(edge.stringValue)")
        }
        needsLayout = true
    }

    /// A centered title in semibold over its explanation, as Figma layers and app data read.
    private static func titled(_ title: String, over explanation: String) -> NSAttributedString {
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        let shown = NSMutableAttributedString(string: title + "\n", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .paragraphStyle: centered, .foregroundColor: NSColor.labelColor])
        shown.append(NSAttributedString(string: explanation, attributes: [.font: NSFont.systemFont(ofSize: 12), .paragraphStyle: centered, .foregroundColor: NSColor.labelColor]))
        return shown
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
        } else if showsSymbol, !formatsScroll.isHidden {
            // App data: the symbol, its title and explanation, then the formats taking
            // the rest of the card. The list is laid out at its full height inside the
            // scroller, so a long one scrolls and nothing is cut short.
            let symbol = min(56, body.height)
            let wanted = ceil(text.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: body.width, height: 10_000)).height ?? 0)
            let words = min(wanted, max(0, (body.height - symbol - 20) / 2))
            image.frame = NSRect(x: body.minX, y: body.minY, width: body.width, height: symbol)
            text.frame = NSRect(x: body.minX, y: image.frame.maxY + 10, width: body.width, height: words)
            let room = max(0, body.maxY - text.frame.maxY - 10)
            let listWidth = body.width
            let listHeight = ceil(formats.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: listWidth, height: 100_000)).height ?? 0)
            formatsScroll.frame = NSRect(x: body.minX, y: text.frame.maxY + 10, width: body.width, height: min(listHeight, room))
            formats.frame = NSRect(x: 0, y: 0, width: listWidth, height: listHeight)
            // The label is flipped (every NSControl is), so its first line is at y = 0: start there.
            formatsScroll.contentView.scroll(to: .zero)
            formatsScroll.reflectScrolledClipView(formatsScroll.contentView)
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
            // A caption of one line for a name; app data's name and explanation take up to three.
            let wanted = ceil(text.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: body.width, height: 10_000)).height ?? 0)
            let captionHeight: CGFloat = text.stringValue.isEmpty ? 0 : min(max(40, wanted + 6), 72)
            image.frame = NSRect(x: body.minX, y: body.minY, width: body.width, height: max(0, body.height - captionHeight))
            text.frame = NSRect(x: body.minX, y: image.frame.maxY + 6, width: body.width, height: max(0, captionHeight - 6))
        }
    }
}
