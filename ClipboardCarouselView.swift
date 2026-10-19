import AppKit
import QuickLookUI

/// Quick Look content shared by medium cursor and large drawer magnets. Beside the open drawer its
/// preview turns over to the entry's raw data (*Raw data I*, Al 2026-10-12), the window card's flip
/// and back; the medium cursor magnet, which no key reaches, stays on the preview.
final class ClipboardCarouselView: ClipboardSurfaceView {
    private let swatch = ClipboardSwatchView(frame: .zero)
    private let preview = QLPreviewView(frame: .zero, style: .normal)!
    /// Quick Look's preview and the swatch: the front. Drawn by another process, so a turn crossfades.
    private let face = NSView()
    /// The back: everything the entry holds, as copied, each part selectable and copyable.
    let raw: ClipboardRawDataView
    /// The back as the flip holds it: the raw data at the Text size.
    private let rawHost: ClipboardZoomHost
    /// The Text size (2026-10-16): the date, facts, position and turn button grow with it, and so does
    /// the raw data behind; the preview keeps the size Quick Look gives it.
    var textScale: CGFloat = 1 {
        didSet {
            guard textScale != oldValue else { return }
            applyTextScale()
        }
    }
    /// The preview area, turning between the two; the arrows, × and the turn button stay on both sides.
    let flip: ClipboardFlipView
    /// *Raw data I* / *Preview I*, beside ×.
    let flipButton: ClipboardFlipButton
    /// Only beside the open drawer, where the drawer's keys reach it; off, it shows the preview.
    var allowsFlip = false {
        didSet {
            flipButton.isHidden = !allowsFlip
            if !allowsFlip { flip.show(.front) }
            needsLayout = true
        }
    }
    /// Its raw data shows (or is turning to show).
    var showsRawData: Bool { allowsFlip && flip.side == .back }
    /// Held weakly: a deleted entry is not kept alive by a preview that once showed it.
    private weak var entry: ClipboardEntry?
    private let previous = NSButton(title: "←", target: nil, action: nil)
    private let next = NSButton(title: "→", target: nil, action: nil)
    private let close = NSButton(title: "×", target: nil, action: nil)
    private let position = NSTextField(labelWithString: "")
    private let stamp = NSTextField(labelWithString: "")
    /// Quiet facts and paths beneath the date, along the preview's top edge.
    private let meta = NSTextField(wrappingLabelWithString: "")
    private let fileMenu = NSPopUpButton()
    private var urls: [URL] = []
    private(set) var entryID: UUID?
    var onNavigate: ((Int) -> Void)?
    var onClose: (() -> Void)?

    init(entry: ClipboardEntry, urls: [URL], position index: Int, count: Int, keymap: ClipboardKeymap = .drawer) {
        self.entry = entry
        raw = ClipboardRawDataView(keymap: keymap)
        rawHost = ClipboardZoomHost(raw)
        flip = ClipboardFlipView(front: face, back: rawHost)
        flipButton = ClipboardFlipButton(keymap: keymap)
        super.init(frame: NSRect(x: 0, y: 0, width: 420, height: 340))
        surface = .card(radius: 12, clips: true)
        preview.autostarts = false
        stamp.textColor = .secondaryLabelColor
        meta.textColor = .secondaryLabelColor
        meta.lineBreakMode = .byCharWrapping
        meta.maximumNumberOfLines = 3
        meta.cell?.truncatesLastVisibleLine = true
        position.alignment = .center
        applyTextScale()
        position.textColor = .secondaryLabelColor
        for (button, action, help) in [(previous, #selector(back), "Previous clipboard item (←)"), (next, #selector(forward), "Next clipboard item (→)"), (close, #selector(dismiss), "Drop cursor magnet")] {
            button.target = self; button.action = action; button.bezelStyle = .inline
            button.refusesFirstResponder = true
            button.setAccessibilityLabel(help.replacingOccurrences(of: "←", with: "Left Arrow").replacingOccurrences(of: "→", with: "Right Arrow")); button.toolTip = help
        }
        previous.image = ClipboardIcons.previous; next.image = ClipboardIcons.next; close.image = ClipboardIcons.delete
        [previous, next, close].forEach { $0.title = ""; $0.imagePosition = .imageOnly }
        fileMenu.target = self; fileMenu.action = #selector(selectFile)
        fileMenu.setAccessibilityLabel("Files in this clipboard item")
        [preview, swatch].forEach(face.addSubview)
        flipButton.isHidden = true
        flipButton.onPress = { [weak self] in self?.turnOver() }
        // Setting off to the back, it reads the entry: the turn starts from a snapshot of it.
        flip.onTurn = { [weak self] side in
            guard let self else { return }
            if side == .back { self.raw.keepShowing(self.entry) }
            self.flipButton.reflect(side)
            self.needsLayout = true
        }
        [flip, stamp, meta, position, previous, next, close, flipButton, fileMenu].forEach(addSubview)
        update(entry: entry, urls: urls, position: index, count: count)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(entry: ClipboardEntry, urls: [URL], position index: Int, count: Int) {
        self.entry = entry
        // The back follows the arrows, and the hovered card, while it shows; a text there holding the
        // keyboard gives it back first (`keepShowing`).
        if flip.side == .back { raw.keepShowing(entry) }
        swatch.color = entry.swatchColor
        swatch.setAccessibilityLabel(entry.readableText)
        preview.isHidden = swatch.color != nil
        stamp.stringValue = entry.dateTimeStamp
        stamp.toolTip = entry.fullDateTimeStamp
        meta.stringValue = entry.metadata.lines.joined(separator: "\n")
        meta.toolTip = meta.stringValue
        meta.isHidden = meta.stringValue.isEmpty
        // Its keys in caps; Esc dropping the magnet goes unsaid (2026-10-16).
        position.attributedStringValue = (ClipboardHint("\(index + 1) of \(count)   ·   ") + .key(ClipboardKeyLabel(shown: "←", spoken: "Left Arrow")) + " "
            + .key(ClipboardKeyLabel(shown: "→", spoken: "Right Arrow")) + " browse").attributed(font: position.font ?? .systemFont(ofSize: 11), color: .secondaryLabelColor, alignment: .center)
        previous.isEnabled = count > 1; next.isEnabled = count > 1
        // Retain the remote Quick Look view and a grouped-file choice on resize.
        if entryID != entry.id || self.urls != urls {
            entryID = entry.id
            self.urls = urls
            fileMenu.removeAllItems()
            fileMenu.addItems(withTitles: urls.map(\.lastPathComponent))
            fileMenu.isHidden = urls.count < 2
            selectFile()
        }
        needsLayout = true
    }
    /// Turns the preview to `side`; the back reads the entry as the turn sets off (`flip.onTurn`).
    func turn(to side: ClipboardFlipView.Side, animated: Bool = true) {
        guard allowsFlip else { return }
        flip.turn(to: side, animated: animated)
    }
    /// Its button, and the drawer's I: to the other side.
    func turnOver() { turn(to: flip.side.other) }

    /// The chrome's type at the Text size; its bands grow to match in `layout`.
    private func applyTextScale() {
        stamp.font = .systemFont(ofSize: 11 * textScale)
        meta.font = .systemFont(ofSize: 10 * textScale)
        position.font = .systemFont(ofSize: 11 * textScale)
        flipButton.font = .systemFont(ofSize: 11 * textScale, weight: .medium)
        flipButton.reflect(flip.side)
        rawHost.scale = textScale
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let s = textScale
        close.frame = NSRect(x: bounds.width - 33 * s, y: bounds.height - 30 * s, width: 24 * s, height: 22 * s)
        let turnWidth = flipButton.isHidden ? 0 : ceil(flipButton.intrinsicContentSize.width) + 6
        flipButton.frame = NSRect(x: close.frame.minX - 4 - turnWidth, y: bounds.height - 30 * s, width: turnWidth, height: 22 * s)
        // The date ends short of the turn button, or of × without it.
        stamp.frame = NSRect(x: 12, y: bounds.height - 28 * s, width: (flipButton.isHidden ? bounds.width - 42 * s : flipButton.frame.minX - 8) - 12, height: 18 * s)
        let filesHeight: CGFloat = urls.count > 1 ? 28 : 0
        let metaWidth = bounds.width - 24
        let metaHeight = meta.isHidden ? 0 : min(39 * s, ceil(meta.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: metaWidth, height: 1_000)).height ?? 13 * s)) + 4
        meta.frame = NSRect(x: 12, y: bounds.height - 32 * s - metaHeight, width: metaWidth, height: metaHeight)
        let bottom = 40 * s
        flip.frame = NSRect(x: 1, y: bottom + filesHeight, width: bounds.width - 2, height: max(0, bounds.height - bottom - 34 * s - filesHeight - metaHeight))
        preview.frame = NSRect(origin: .zero, size: flip.frame.size)
        let side = min(240, preview.frame.width - 28, preview.frame.height - 28)
        swatch.frame = NSRect(x: preview.frame.midX - side / 2, y: preview.frame.midY - side / 2, width: side, height: side)
        fileMenu.frame = NSRect(x: 12, y: bottom + 1, width: bounds.width - 24, height: 25)
        previous.frame = NSRect(x: 12, y: 7 * s, width: 35 * s, height: 26 * s)
        next.frame = NSRect(x: bounds.width - 12 - 35 * s, y: 7 * s, width: 35 * s, height: 26 * s)
        position.frame = NSRect(x: previous.frame.maxX + 2, y: 11 * s, width: max(0, next.frame.minX - 2 - previous.frame.maxX - 2), height: 18 * s)
    }
    /// Closed: Quick Look's item and the raw data let go of the entry.
    func closePreview() {
        preview.previewItem = nil
        raw.show(nil)
    }
    @objc private func selectFile() {
        guard urls.indices.contains(fileMenu.indexOfSelectedItem) else { return }
        preview.previewItem = urls[fileMenu.indexOfSelectedItem] as NSURL
        preview.refreshPreviewItem()
    }
    @objc private func back() { onNavigate?(-1) }
    @objc private func forward() { onNavigate?(1) }
    @objc private func dismiss() { onClose?() }
}
