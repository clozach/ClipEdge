import AppKit
import QuickLookUI

/// Quick Look content shared by medium cursor and large drawer magnets.
final class ClipboardCarouselView: ClipboardSurfaceView {
    private let swatch = ClipboardSwatchView(frame: .zero)
    private let preview = QLPreviewView(frame: .zero, style: .normal)!
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

    init(entry: ClipboardEntry, urls: [URL], position index: Int, count: Int) {
        super.init(frame: NSRect(x: 0, y: 0, width: 420, height: 340))
        surface = .card(radius: 12, clips: true)
        preview.autostarts = false
        stamp.font = .systemFont(ofSize: 11)
        stamp.textColor = .secondaryLabelColor
        meta.font = .systemFont(ofSize: 10)
        meta.textColor = .secondaryLabelColor
        meta.lineBreakMode = .byCharWrapping
        meta.maximumNumberOfLines = 3
        meta.cell?.truncatesLastVisibleLine = true
        position.font = .systemFont(ofSize: 11)
        position.alignment = .center
        position.textColor = .secondaryLabelColor
        for (button, action, help) in [(previous, #selector(back), "Previous clipboard item (←)"), (next, #selector(forward), "Next clipboard item (→)"), (close, #selector(dismiss), "Drop cursor magnet (Esc)")] {
            button.target = self; button.action = action; button.bezelStyle = .inline
            button.refusesFirstResponder = true
            button.setAccessibilityLabel(help); button.toolTip = help
        }
        previous.image = ClipboardIcons.previous; next.image = ClipboardIcons.next; close.image = ClipboardIcons.delete
        [previous, next, close].forEach { $0.title = ""; $0.imagePosition = .imageOnly }
        fileMenu.target = self; fileMenu.action = #selector(selectFile)
        fileMenu.setAccessibilityLabel("Files in this clipboard item")
        [preview, swatch, stamp, meta, position, previous, next, close, fileMenu].forEach(addSubview)
        update(entry: entry, urls: urls, position: index, count: count)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(entry: ClipboardEntry, urls: [URL], position index: Int, count: Int) {
        swatch.color = entry.swatchColor
        swatch.setAccessibilityLabel(entry.readableText)
        preview.isHidden = swatch.color != nil
        stamp.stringValue = entry.dateTimeStamp
        stamp.toolTip = entry.fullDateTimeStamp
        meta.stringValue = entry.metadata.lines.joined(separator: "\n")
        meta.toolTip = meta.stringValue
        meta.isHidden = meta.stringValue.isEmpty
        position.stringValue = "\(index + 1) of \(count)   ·   ← → browse   ·   Esc drops"
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
    override func layout() {
        super.layout()
        stamp.frame = NSRect(x: 12, y: bounds.height - 28, width: bounds.width - 54, height: 18)
        close.frame = NSRect(x: bounds.width - 33, y: bounds.height - 30, width: 24, height: 22)
        let filesHeight: CGFloat = urls.count > 1 ? 28 : 0
        let metaWidth = bounds.width - 24
        let metaHeight = meta.isHidden ? 0 : min(39, ceil(meta.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: metaWidth, height: 1_000)).height ?? 13)) + 4
        meta.frame = NSRect(x: 12, y: bounds.height - 32 - metaHeight, width: metaWidth, height: metaHeight)
        preview.frame = NSRect(x: 1, y: 40 + filesHeight, width: bounds.width - 2, height: max(0, bounds.height - 74 - filesHeight - metaHeight))
        let side = min(240, preview.frame.width - 28, preview.frame.height - 28)
        swatch.frame = NSRect(x: preview.frame.midX - side / 2, y: preview.frame.midY - side / 2, width: side, height: side)
        fileMenu.frame = NSRect(x: 12, y: 41, width: bounds.width - 24, height: 25)
        previous.frame = NSRect(x: 12, y: 7, width: 35, height: 26)
        next.frame = NSRect(x: bounds.width - 47, y: 7, width: 35, height: 26)
        position.frame = NSRect(x: 49, y: 11, width: bounds.width - 98, height: 18)
    }
    func closePreview() { preview.previewItem = nil }
    @objc private func selectFile() {
        guard urls.indices.contains(fileMenu.indexOfSelectedItem) else { return }
        preview.previewItem = urls[fileMenu.indexOfSelectedItem] as NSURL
        preview.refreshPreviewItem()
    }
    @objc private func back() { onNavigate?(-1) }
    @objc private func forward() { onNavigate?(1) }
    @objc private func dismiss() { onClose?() }
}
