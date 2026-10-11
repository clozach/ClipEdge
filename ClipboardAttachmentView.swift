import AppKit

enum ClipboardAttachmentView {
    static func makeHeldPreview(for entry: ClipboardEntry, maximumAttachmentPixels: CGFloat, holdingGlyphHeight: CGFloat, shortcutHint: String = "⌃⌥Space") -> (view: NSView, size: NSSize) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let limit = maximumAttachmentPixels / max(1, screen?.backingScaleFactor ?? 1)
        let stampHeight: CGFloat = 17
        let hintHeight: CGFloat = 16
        // Quiet facts, then the first path on up to two lines, along the preview's
        // bottom edge. A long path keeps its start and its file name; the drawer
        // and the history window show it whole.
        let wrapping = NSMutableParagraphStyle()
        wrapping.lineBreakMode = .byCharWrapping
        wrapping.alignment = .center
        let factsAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .paragraphStyle: wrapping]
        func factsText(_ width: CGFloat) -> String {
            let path = entry.metadata.displayPaths.first.map { middleElided($0, lines: 2, width: width - 12, attributes: factsAttributes) }
            return [entry.metadata.line, path ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
        }
        func factsHeight(_ text: String, _ width: CGFloat) -> CGFloat {
            guard !text.isEmpty else { return 0 }
            return ceil((text as NSString).boundingRect(with: NSSize(width: width - 12, height: .greatestFiniteMagnitude),
                                                        options: .usesLineFragmentOrigin, attributes: factsAttributes).height) + 4
        }
        // The narrowest magnet needs the most lines; a wider preview needs fewer.
        let preview = makePreview(for: entry, maximumSize: NSSize(width: limit, height: limit - holdingGlyphHeight - stampHeight - hintHeight - factsHeight(factsText(145), 145)))
        let width = max(145, preview.size.width)
        let facts = factsText(width)
        let metaHeight = factsHeight(facts, width)
        let size = NSSize(width: width, height: preview.size.height + holdingGlyphHeight + stampHeight + hintHeight + metaHeight)
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        preview.view.frame.origin = NSPoint(x: (size.width - preview.size.width) / 2, y: stampHeight + hintHeight + metaHeight)
        container.addSubview(preview.view)
        if metaHeight > 0 {
            let meta = NSTextField(wrappingLabelWithString: facts)
            meta.attributedStringValue = NSAttributedString(string: facts, attributes: factsAttributes.merging([.foregroundColor: NSColor.secondaryLabelColor]) { $1 })
            meta.frame = NSRect(x: 0, y: stampHeight + hintHeight, width: size.width, height: metaHeight)
            meta.drawsBackground = true
            meta.backgroundColor = .windowBackgroundColor
            container.addSubview(meta)
        }
        let stamp = NSTextField(labelWithString: entry.dateTimeStamp)
        stamp.font = .systemFont(ofSize: 10, weight: .medium)
        stamp.alignment = .center
        stamp.frame = NSRect(x: 0, y: hintHeight, width: size.width, height: stampHeight)
        stamp.drawsBackground = true
        stamp.backgroundColor = .windowBackgroundColor
        container.addSubview(stamp)
        let hint = NSTextField(labelWithString: "\(shortcutHint) · preview")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        hint.frame = NSRect(x: 0, y: 0, width: size.width, height: hintHeight)
        hint.drawsBackground = true
        hint.backgroundColor = .windowBackgroundColor
        container.addSubview(hint)
        // The destination app owns its actual cursor. Keep the holding cue
        // visible with our attachment even when that app chooses an I-beam.
        let hand = NSImageView(frame: NSRect(x: (size.width - 24) / 2,
                                           y: preview.size.height + stampHeight + hintHeight + metaHeight + 1, width: 24, height: 24))
        hand.image = NSCursor.closedHand.image
        hand.imageScaling = .scaleProportionallyUpOrDown
        container.addSubview(hand)
        return (container, size)
    }

    private static func makePreview(for entry: ClipboardEntry, maximumSize: NSSize) -> (view: NSView, size: NSSize) {
        if let color = entry.swatchColor {
            let side = max(1, min(136, maximumSize.width, maximumSize.height))
            let size = NSSize(width: side, height: side)
            let swatch = ClipboardSwatchView(frame: NSRect(origin: .zero, size: size))
            swatch.color = color
            swatch.setAccessibilityLabel(entry.readableText)
            return (swatch, size)
        }
        switch entry.kind {
        case .image:
            return makeImagePreview(entry.thumbnail, maximumSize: maximumSize)
        case .file:
            return makeCardPreview(image: entry.thumbnail, title: entry.title, maximumSize: maximumSize)
        case .figma(let copy):
            let symbol = NSImage(systemSymbolName: entry.kind.iconName, accessibilityDescription: nil)
            return makeCardPreview(image: symbol, title: copy.title, notes: [copy.explanation, copy.shortNote], maximumSize: maximumSize)
        case .text, .link, .html:
            return makeTextPreview(entry.readableText ?? entry.title, maximumSize: maximumSize)
        case .other:
            return makeSymbolPreview(name: entry.kind.iconName)
        }
    }

    private static func makeTextPreview(_ text: String, maximumSize: NSSize) -> (view: NSView, size: NSSize) {
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let clipped = text.count > 600 ? String(text.prefix(600)) + "…" : text
        let width = min(252, maximumSize.width)
        let availableWidth = width - 24
        let bounds = (clipped as NSString).boundingRect(
            with: NSSize(width: availableWidth, height: 112),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [.font: font]
        )
        let size = NSSize(width: width, height: min(max(50, ceil(bounds.height) + 24), 136, maximumSize.height))
        let container = magnetContainer(size: size)
        let label = NSTextField(wrappingLabelWithString: clipped)
        label.font = font
        label.textColor = .labelColor
        label.maximumNumberOfLines = 6
        label.lineBreakMode = .byWordWrapping
        // Text cut short by the lines or the frame ends with "…", never looking complete.
        label.cell?.truncatesLastVisibleLine = true
        label.cell?.wraps = true
        label.cell?.usesSingleLineMode = false
        label.preferredMaxLayoutWidth = availableWidth
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 11),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -11)
        ])
        return (container, size)
    }

    private static func makeImagePreview(_ image: NSImage?, maximumSize: NSSize) -> (view: NSView, size: NSSize) {
        guard let image, image.size.width > 0, image.size.height > 0 else {
            return makeSymbolPreview(name: "photo")
        }

        let maximum = NSSize(width: min(220, maximumSize.width - 16), height: min(150, maximumSize.height - 16))
        let scale = min(maximum.width / image.size.width, maximum.height / image.size.height, 1)
        let imageSize = NSSize(width: max(54, image.size.width * scale), height: max(54, image.size.height * scale))
        let size = NSSize(width: imageSize.width + 16, height: imageSize.height + 16)
        let container = magnetContainer(size: size)
        let imageView = NSImageView(image: image)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            imageView.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8)
        ])
        return (container, size)
    }

    /// A picture over a name: a Finder item's icon, or a symbol over a title and
    /// a note (Figma layers). Without notes it keeps a Finder item's size. With
    /// them it shows the first that fits whole, the symbol shrinking or giving
    /// way before a note is cut short.
    private static func makeCardPreview(image: NSImage?, title: String, notes: [String] = [], maximumSize: NSSize) -> (view: NSView, size: NSSize) {
        let width = min(notes.isEmpty ? 210 : 240, maximumSize.width)
        let label = NSTextField(wrappingLabelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        let detail = notes.first.map { note -> NSTextField in
            let detail = NSTextField(wrappingLabelWithString: note)
            detail.font = .systemFont(ofSize: 10)
            detail.textColor = .secondaryLabelColor
            detail.alignment = .center
            detail.cell?.truncatesLastVisibleLine = true
            detail.preferredMaxLayoutWidth = width - 20
            detail.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
            detail.translatesAutoresizingMaskIntoConstraints = false
            return detail
        }
        // Measured by the labels' own cells, which wrap a little inside their frames.
        func height(_ field: NSTextField, lines: CGFloat) -> CGFloat {
            let line = ceil((field.font ?? .systemFont(ofSize: 12)).boundingRectForFont.height)
            return min(ceil(field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width - 20, height: 10_000)).height ?? line), line * lines)
        }
        var side: CGFloat
        let size: NSSize
        if let detail {
            let fixed = 8 + height(label, lines: 2) + 4 + 8
            let fitting = notes.first { note in detail.stringValue = note; return fixed + height(detail, lines: 6) <= maximumSize.height } ?? notes[notes.count - 1]
            detail.stringValue = fitting
            let words = fixed + height(detail, lines: 6)
            let room = maximumSize.height - words - 5
            side = room >= 16 ? min(26, room) : 0
            size = NSSize(width: width, height: min(words + (side > 0 ? side + 5 : 0), maximumSize.height))
        } else {
            size = NSSize(width: width, height: min(106, maximumSize.height))
            // With facts and a path beneath, the name keeps one line and the picture shrinks.
            side = size.height < 100 ? max(24, size.height - 40) : 48
        }
        let isShort = notes.isEmpty && size.height < 100
        label.lineBreakMode = isShort ? .byTruncatingMiddle : .byWordWrapping
        label.maximumNumberOfLines = isShort ? 1 : 2
        // A name cut at two lines ends with "…", so a shortened file name never looks whole.
        label.cell?.truncatesLastVisibleLine = true
        label.preferredMaxLayoutWidth = size.width - 20
        let container = magnetContainer(size: size)
        let imageView = NSImageView(image: image ?? NSImage())
        imageView.imageScaling = .scaleProportionallyUpOrDown
        // A symbol is a template: tinted here, in the magnet's own appearance.
        if image?.isTemplate == true {
            imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: side * 0.8, weight: .regular)
            imageView.contentTintColor = .controlAccentColor
        }
        imageView.isHidden = side == 0
        imageView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(imageView)
        container.addSubview(label)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            imageView.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            imageView.widthAnchor.constraint(equalToConstant: side),
            imageView.heightAnchor.constraint(equalToConstant: side),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: side > 0 ? imageView.bottomAnchor : container.topAnchor, constant: side > 0 ? 5 : 8),
            label.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -8)
        ])
        if let detail {
            container.addSubview(detail)
            NSLayoutConstraint.activate([
                detail.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
                detail.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
                detail.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 4),
                detail.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -8)
            ])
        }
        return (container, size)
    }

    private static func makeSymbolPreview(name: String) -> (view: NSView, size: NSSize) {
        let size = NSSize(width: 66, height: 66)
        let container = magnetContainer(size: size)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
        let imageView = NSImageView(image: image)
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 26, weight: .regular)
        imageView.contentTintColor = .controlAccentColor
        imageView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 34),
            imageView.heightAnchor.constraint(equalToConstant: 34)
        ])
        return (container, size)
    }

    /// The start of a long path and its end, whatever fits `lines` at `width`.
    static func middleElided(_ text: String, lines: Int, width: CGFloat, attributes: [NSAttributedString.Key: Any]) -> String {
        func height(_ string: String) -> CGFloat {
            ceil((string as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                                   options: .usesLineFragmentOrigin, attributes: attributes).height)
        }
        let limit = height(Array(repeating: "X", count: lines).joined(separator: "\n"))
        guard height(text) > limit else { return text }
        let characters = Array(text)
        var low = 2, high = characters.count - 1, best = "…"
        while low <= high {
            let kept = (low + high) / 2
            // The file name at the end says more than the folders at the start.
            let head = kept / 3
            let candidate = String(characters.prefix(head)) + "…" + String(characters.suffix(kept - head))
            if height(candidate) <= limit { best = candidate; low = kept + 1 } else { high = kept - 1 }
        }
        return best
    }

    private static func magnetContainer(size: NSSize) -> NSView {
        let view = ClipboardSurfaceView(frame: NSRect(origin: .zero, size: size))
        view.surface = .card(radius: 11, opacity: 0.96)
        return view
    }
}
