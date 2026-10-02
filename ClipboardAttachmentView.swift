import AppKit

enum ClipboardAttachmentView {
    static func makeHeldPreview(for entry: ClipboardEntry, maximumAttachmentPixels: CGFloat, holdingGlyphHeight: CGFloat, shortcutHint: String = "⌃⌥Space") -> (view: NSView, size: NSSize) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let limit = maximumAttachmentPixels / max(1, screen?.backingScaleFactor ?? 1)
        let stampHeight: CGFloat = 17
        let hintHeight: CGFloat = 16
        let preview = makePreview(for: entry, maximumSize: NSSize(width: limit, height: limit - holdingGlyphHeight - stampHeight - hintHeight))
        let size = NSSize(width: max(145, preview.size.width), height: preview.size.height + holdingGlyphHeight + stampHeight + hintHeight)
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        preview.view.frame.origin = NSPoint(x: (size.width - preview.size.width) / 2, y: stampHeight + hintHeight)
        container.addSubview(preview.view)
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
                                           y: preview.size.height + stampHeight + hintHeight + 1, width: 24, height: 24))
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
        let container = magnetContainer(size: size)
        let imageView = NSImageView(image: entry.thumbnail ?? NSImage())
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(wrappingLabelWithString: entry.title)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .labelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
        label.preferredMaxLayoutWidth = size.width - 20
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(imageView)
        container.addSubview(label)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            imageView.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            imageView.widthAnchor.constraint(equalToConstant: 48),
            imageView.heightAnchor.constraint(equalToConstant: 48),
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
