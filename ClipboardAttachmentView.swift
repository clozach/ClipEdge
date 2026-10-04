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
        switch entry.kind {
        case .image:
            return makeImagePreview(entry.thumbnail, maximumSize: maximumSize)
        case .file:
            return makeFilePreview(entry, maximumSize: maximumSize)
        case .text, .link:
            return makeTextPreview(rawText(for: entry) ?? entry.title, maximumSize: maximumSize)
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

    private static func makeFilePreview(_ entry: ClipboardEntry, maximumSize: NSSize) -> (view: NSView, size: NSSize) {
        let size = NSSize(width: min(210, maximumSize.width), height: min(106, maximumSize.height))
        // With facts and a path beneath, the name keeps one line and the picture shrinks.
        let isShort = size.height < 100
        let side: CGFloat = isShort ? max(24, size.height - 40) : 48
        let container = magnetContainer(size: size)
        let imageView = NSImageView(image: entry.thumbnail ?? NSImage())
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(wrappingLabelWithString: entry.title)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .labelColor
        label.lineBreakMode = isShort ? .byTruncatingMiddle : .byWordWrapping
        label.maximumNumberOfLines = isShort ? 1 : 2
        label.preferredMaxLayoutWidth = size.width - 20
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(imageView)
        container.addSubview(label)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            imageView.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            imageView.widthAnchor.constraint(equalToConstant: side),
            imageView.heightAnchor.constraint(equalToConstant: side),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 5),
            label.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -8)
        ])
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
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.layer?.cornerRadius = 11
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.separatorColor.cgColor
        return view
    }

    private static func rawText(for entry: ClipboardEntry) -> String? {
        for payload in entry.payloads {
            if let value = payload.values.first(where: { $0.type == .string }),
               let string = String(data: value.data, encoding: .utf8) {
                return string
            }
        }
        return nil
    }
}
