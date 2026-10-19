import AppKit
import QuartzCore

/// A drawer row, a square image tile, or a compact row in the history window.
enum ClipboardTileStyle { case row, image, compact }

/// One history chip or square image tile; actions stay at its right edge.
final class ClipboardTile: NSControl {
    let entry: ClipboardEntry
    let style: ClipboardTileStyle
    /// Its container's keys, which its buttons, help and armed row name.
    let keymap: ClipboardKeymap
    var imageOnly: Bool { style == .image }
    var onPick: (() -> Void)?
    /// A ⌘-click or ⇧-click: marks rather than picks (multi-select).
    var onMarkClick: ((ClipboardMarkClick) -> Void)?
    var onHover: (() -> Void)?
    var onDelete: (() -> Void)?
    var onOpen: (() -> Void)?
    /// Its container's maintainer-only asker, which its help names ⌥⌘A from; none for a lone tile.
    var asker: () -> ClipboardPreviewAsker? = { nil }
    // Selection has exactly one owner. Tiles cannot retain independent hover tint.
    var isChosen: Bool { (superview as? ClipboardCanvas)?.selectedID == entry.id }
    var isAttached: Bool { (superview as? ClipboardCanvas)?.liftedID == entry.id }
    /// A second ⌘⌫ deletes this row for good; anything else keeps it.
    var isArmed: Bool { (superview as? ClipboardCanvas)?.armedID == entry.id }
    /// Multi-select, as the list holds it: circles show while it is on, filled on marked cards.
    var marking: ClipboardMarking { (superview as? ClipboardCanvas)?.marking() ?? .off }
    var isMarked: Bool { marking.isMarked(entry.id) }
    /// Whether this card shows its circle: the state `markReveal` moves to.
    private(set) var showsCircle = false
    /// 0 to 1 as the circle shows: rows slide their content right by their gutter to reveal it at
    /// their left, image tiles fade it in at their top-left corner. Drawn, never laid out, so no
    /// other card moves; animated through `animator()` (Al, 2026-10-12: as in Gmail).
    @objc dynamic var markReveal: CGFloat = 0 { didSet { needsDisplay = true } }
    /// How far rows slide: the circle's room at their left.
    var markGutter: CGFloat { style == .compact ? 26 : 28 }
    /// The thumbnail size (Settings, 2026-10-16): a row's picture or symbol at this share of its
    /// 46 points (the drawer) or 32 (the window); the row grows once the picture needs more.
    var thumbnailScale: CGFloat = 1 { didSet { if thumbnailScale != oldValue { needsDisplay = true } } }
    /// A row's picture side at `scale`; image tiles have none of their own.
    static func thumbnailSide(_ style: ClipboardTileStyle, scale: CGFloat) -> CGFloat {
        ((style == .compact ? 32 : 46) * scale).rounded()
    }
    /// A tile's height in a list at `scale`: the drawer's 88 and the window's 44 at 100%.
    static func rowHeight(_ style: ClipboardTileStyle, scale: CGFloat) -> CGFloat {
        let side = thumbnailSide(style, scale: scale)
        return style == .compact ? max(44, side + 12) : max(88, side + 28)
    }
    /// How long the slide takes, and whether there is one: Reduce Motion, or a card off screen, shows
    /// it at once. Fixtures replace the Reduce Motion reading.
    static var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static func markSlide(onScreen: Bool, reduceMotion: Bool) -> TimeInterval? { onScreen && !reduceMotion ? 0.2 : nil }
    override class func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        key == "markReveal" ? CABasicAnimation() : super.defaultAnimation(forKey: key)
    }
    var tooltipSummary: String {
        switch entry.kind {
        case .figma(let copy): return copy.summary
        case .appData(let data): return data.summary
        // A picture that is also app data says where it pastes; its facts name the app.
        case .image: return entry.appData == nil ? entry.title : "\(entry.title)\n\(ClipboardAppData.explanation)"
        case .text, .link, .html, .file, .other: return entry.readableText ?? entry.title
        }
    }
    /// Facts, paths and the date wrap in full; a Figma link, or app data's every
    /// format, leads them, never cut short. A copy Quick Look is handed as a
    /// typed file says so after its facts.
    var tooltipDetails: String {
        let leading: [String] = {
            if case .figma(let copy) = entry.kind { return [copy.link.absoluteString] }
            return entry.appData.map { [$0.formatList] } ?? []
        }()
        let typed = ClipboardTypedPreview.choice(for: entry).map { [$0.fact] } ?? []
        return (leading + entry.metadata.lines + typed + [entry.fullDateTimeStamp]).joined(separator: "\n")
    }
    var tooltipText: String { "\(tooltipSummary)\n\(tooltipDetails)" }
    private var tracking: NSTrackingArea?
    /// Delete and Open in Preview, made the first time the card is in the list's view tree: a card
    /// scrolled far out of view is a dormant shell (2026-10-16), so thousands cost little.
    private var buttons: (delete: NSButton, open: NSButton)?

    init(entry: ClipboardEntry, style: ClipboardTileStyle, keymap: ClipboardKeymap) {
        self.entry = entry
        self.style = style
        self.keymap = keymap
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool { onPick?(); return true }

    func refreshEntryPresentation() { needsDisplay = true }
    /// Said as it is asked, never stored: a dormant card spends nothing on it.
    override func accessibilityLabel() -> String? {
        isArmed ? armedLabel : isAttached ? "Click here to cancel pickup of \(entry.title)" : "\(entry.title), copied \(entry.fullDateTimeStamp)"
    }
    /// The history window's footer shows its own keys; this legend is the drawer's.
    override func accessibilityHelp() -> String? {
        style == .compact ? nil : ClipboardTileTooltip.legendText(keymap, asker: asker(), spoken: true)
    }

    /// Joining the list's view tree wakes the card: its buttons are made once, and its selection,
    /// marks and tooltip catch up.
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard superview != nil else { return }
        if buttons == nil {
            buttons = (makeButton(image: ClipboardIcons.delete, help: keymap.help("Delete permanently…", .delete),
                                  spoken: keymap.spoken(.delete).map { "Delete permanently, \($0)" } ?? "Delete permanently", action: #selector(deleteItem)),
                       makeButton(image: ClipboardIcons.openInPreview, help: keymap.help("Open in Preview", .open),
                                  spoken: keymap.spoken(.open).map { "Open in Preview, \($0)" } ?? "Open in Preview", action: #selector(openItem)))
            needsLayout = true
        }
        refreshMarking(animated: false)
    }

    private func makeButton(image: NSImage, help: String, spoken: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.image = image
        button.bezelStyle = .regularSquare
        button.isBordered = true
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
        button.toolTip = help
        button.setAccessibilityLabel(spoken)
        button.refusesFirstResponder = true // Canvas exposes these via Space / Delete / Command-O.
        addSubview(button)
        return button
    }
    override func layout() {
        super.layout()
        buttons?.delete.frame = NSRect(x: bounds.width - 31, y: 5, width: 26, height: 26)
        buttons?.open.frame = NSRect(x: bounds.width - 31, y: 34, width: 26, height: 26)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) {
        onHover?()
        // The history window's card already shows the whole item beside its row; while marking, the
        // card's own tooltip names it (the selection's actions take card info's room).
        if style != .compact, !marking.isOn { ClipboardTileTooltip.shared.schedule(for: self) }
    }
    override func mouseExited(with event: NSEvent) { ClipboardTileTooltip.shared.hide(for: self) }
    override func mouseDown(with event: NSEvent) {
        ClipboardTileTooltip.shared.hide()
        if let click = ClipboardMarkClick(event.modifierFlags), let onMarkClick { onMarkClick(click) } else { onPick?() }
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { ClipboardTileTooltip.shared.hide(for: self) }
        super.viewWillMove(toWindow: newWindow)
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: style == .compact ? .pointingHand : .openHand) }
    @objc private func deleteItem() { ClipboardTileTooltip.shared.hide(); onDelete?() }
    @objc private func openItem() { ClipboardTileTooltip.shared.hide(); onOpen?() }
    /// The keys that answer an armed row, in its container's labels.
    private var armedKeys: ClipboardHint? { keymap.key(.delete).map(ClipboardDeletion.one.keys(confirm:)) }
    /// What VoiceOver says of an armed row: which item, the question, and its key in words
    /// ("Command-Delete again deletes").
    private var armedLabel: String {
        (["\(entry.title).", ClipboardDeletion.one.question] + [armedKeys?.spoken].compactMap { $0 }).joined(separator: " ")
    }
    func refreshSelection() {
        updateActions()
        setAccessibilitySelected(isChosen)
        // While circles show, VoiceOver hears each card's circle.
        setAccessibilityValue(marking.isOn ? (isMarked ? "selected" : "not selected") : nil)
        // While marking, the card or card info that would show a title whole gives way to the
        // selection's actions, and the circles narrow it further: pointing at a card names it whole.
        // A dormant card (out of the view tree) gets its tooltip when it joins it.
        toolTip = superview == nil ? nil : style == .compact ? tooltipText : (marking.isOn && style != .image ? entry.title : nil)
        needsDisplay = true
    }
    /// The marks changed: the circle shows or goes, sliding when `animated` and the card is on
    /// screen without Reduce Motion, and the card says whether it is selected.
    func refreshMarking(animated: Bool) {
        let shows = marking.isOn
        if shows != showsCircle {
            showsCircle = shows
            let target: CGFloat = shows ? 1 : 0
            if animated, let duration = Self.markSlide(onScreen: window?.isVisible == true, reduceMotion: Self.reduceMotion()) {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = duration
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    animator().markReveal = target
                }
            } else { markReveal = target }
        }
        refreshSelection()
    }
    private func updateActions() {
        // Compact rows keep their actions in the window's footer; while marking, the selection's
        // panel holds them.
        let hidden = !isChosen || isAttached || style == .compact || marking.isOn
        buttons?.delete.isHidden = hidden
        buttons?.open.isHidden = hidden
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        // Image corners touching their square container stay square.
        let path = imageOnly ? NSBezierPath(rect: rect) : NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        if isChosen {
            NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
            path.fill()
        }
        if showsCircle, isMarked {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            path.fill()
        }
        defer { drawCircle() }
        if isAttached {
            drawText("Click here to cancel", in: NSRect(x: 20 + slide, y: bounds.midY - 9, width: bounds.width - 40 - slide, height: 22), size: 13, color: .secondaryLabelColor)
            NSColor.separatorColor.setStroke()
            path.setLineDash([4, 4], count: 2, phase: 0)
            path.stroke()
            return
        }
        switch style {
        case .image:
            if let image = entry.thumbnail { drawImage(image, in: rect) }
            // The stamp and the quiet facts share the tile's bottom edge.
            let stampRect = NSRect(x: rect.minX, y: rect.maxY - 36, width: rect.width, height: 36)
            NSColor.controlBackgroundColor.setFill()
            NSBezierPath(rect: stampRect).fill()
            drawText(entry.dateTimeStamp, in: NSRect(x: stampRect.minX + 4, y: stampRect.minY + 4, width: stampRect.width - 8, height: 14), size: 10, color: .labelColor)
            drawText(entry.edgeText, in: NSRect(x: stampRect.minX + 4, y: stampRect.minY + 19, width: stampRect.width - 8, height: 14), size: 10, color: .secondaryLabelColor)
        case .row:
            let side = Self.thumbnailSide(.row, scale: thumbnailScale), textX = side + 22
            let iconRect = NSRect(x: 11 + slide, y: 14, width: side, height: side)
            let image = entry.thumbnail ?? ClipboardIcons.drawn(entry.kind.iconName)
            if let color = entry.swatchColor { color.setFill(); NSBezierPath(ovalIn: iconRect).fill() }
            else if let image { drawImage(image, in: iconRect) }
            drawText(entry.title, in: NSRect(x: textX + slide, y: 10, width: bounds.width - textX - 38, height: 34), size: 13, color: .labelColor)
            drawText(entry.edgeText, in: NSRect(x: textX + slide, y: 47, width: bounds.width - textX - 38, height: 16), size: 10, color: .secondaryLabelColor, truncation: .byTruncatingMiddle)
            drawText(entry.dateTimeStamp, in: NSRect(x: textX + slide, y: 66, width: bounds.width - textX - 10 - slide, height: 16), size: 10, color: .secondaryLabelColor)
        case .compact:
            let side = Self.thumbnailSide(.compact, scale: thumbnailScale), textX = side + 18
            // The two lines stay centred on the row as a larger thumbnail makes it taller.
            let textY = ((bounds.height - 33) / 2).rounded()
            let textRect = NSRect(x: textX + slide, y: textY, width: bounds.width - textX - 10 - slide, height: 17)
            let edgeRect = NSRect(x: textX + slide, y: textY + 19, width: bounds.width - textX - 10 - slide, height: 14)
            if isArmed {
                drawText(ClipboardDeletion.one.question, in: textRect, size: 13, color: .systemRed)
                // Its cap stands taller than the line's letters, so the line gets 2 points either side.
                armedKeys?.attributed(font: .systemFont(ofSize: 10), color: .systemRed).draw(with: edgeRect.insetBy(dx: 0, dy: -2), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
                NSColor.systemRed.setStroke()
                path.lineWidth = 1
                path.stroke()
                return
            }
            let iconRect = NSRect(x: 9 + slide, y: ((bounds.height - side) / 2).rounded() + 1, width: side, height: side)
            if let color = entry.swatchColor { color.setFill(); NSBezierPath(ovalIn: iconRect).fill() }
            else if let image = entry.thumbnail ?? ClipboardIcons.drawn(entry.kind.iconName) {
                drawImage(image, in: iconRect)
            }
            drawText(entry.title, in: textRect, size: 13, color: .labelColor)
            drawText(entry.edgeText, in: edgeRect, size: 10, color: .secondaryLabelColor, truncation: .byTruncatingMiddle)
        }
        if isChosen {
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
    /// How far a row's content has slid right for its circle; image tiles never slide.
    private var slide: CGFloat { style == .image ? 0 : (markReveal * markGutter).rounded() }
    /// Where the circle sits: in a row's gutter, centred on the row, where its icon starts at rest,
    /// or 6 points in from an image tile's top-left corner, over the picture.
    var circleFrame: NSRect {
        let size: CGFloat = 18
        switch style {
        case .image: return NSRect(x: 6, y: 6, width: size, height: size)
        case .row: return NSRect(x: 11, y: (bounds.midY - size / 2).rounded(), width: size, height: size)
        case .compact: return NSRect(x: 9, y: (bounds.midY - size / 2).rounded(), width: size, height: size)
        }
    }
    /// Unmarked: a ring on the card's ground. Marked: filled with the accent, a white check.
    /// It fades in as the content slides away from it.
    private func drawCircle() {
        guard markReveal > 0, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setAlpha(markReveal)
        let ring = NSBezierPath(ovalIn: circleFrame.insetBy(dx: 0.75, dy: 0.75))
        if isMarked {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(ovalIn: circleFrame).fill()
            let box = circleFrame, check = NSBezierPath()
            check.move(to: NSPoint(x: box.minX + 5, y: box.minY + 9.5))
            check.line(to: NSPoint(x: box.minX + 8, y: box.minY + 12.5))
            check.line(to: NSPoint(x: box.minX + 13.5, y: box.minY + 6))
            check.lineWidth = 1.8
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            NSColor.white.setStroke()
            check.stroke()
        } else {
            NSColor.controlBackgroundColor.setFill()
            ring.fill()
            ring.lineWidth = 1.5
            NSColor.secondaryLabelColor.setStroke()
            ring.stroke()
        }
        context.restoreGState()
    }
    private func drawImage(_ image: NSImage, in box: NSRect) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let scale = min(box.width / image.size.width, box.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let destination = NSRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height)
        image.draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    private func drawText(_ text: String, in rect: NSRect, size: CGFloat, color: NSColor,
                          truncation: NSLineBreakMode = .byTruncatingTail) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = truncation
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                              attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color, .paragraphStyle: paragraph])
    }
}
