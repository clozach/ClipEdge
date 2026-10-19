import AppKit

/// The storage popover both hovers share (Al, 2026-10-16): the disk as one bar
/// (`ClipboardStorageBar`), with, for the low-space warning, its heading above and what to do below.
final class ClipboardStorageDetail {
    static let width: CGFloat = 320
    static let usageHeading = "Disk usage"
    let bar = ClipboardStorageBar()
    let showsWarning: Bool
    private let popover = NSPopover()
    var report: ClipboardStorageReport? { didSet { bar.report = report } }
    /// What the popover shows (the deck draws it in place).
    var content: NSView { popover.contentViewController!.view }
    var isShown: Bool { popover.isShown }

    init(showsWarning: Bool) {
        self.showsWarning = showsWarning
        popover.behavior = .applicationDefined
        popover.animates = false
        // A heading either way (Al, 2026-10-16): the warning's, or *Disk usage* from the count.
        let heading = NSTextField(labelWithString: showsWarning ? ClipboardStorageReport.heading : Self.usageHeading)
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        var views: [NSView] = [heading, bar]
        var constraints = [bar.widthAnchor.constraint(equalToConstant: Self.width)]
        if showsWarning {
            let advice = NSTextField(wrappingLabelWithString: ClipboardStorageReport.advice)
            advice.font = .systemFont(ofSize: 12)
            // Measured wrapped at its width, so the popover is tall enough for every line.
            advice.preferredMaxLayoutWidth = Self.width
            views = [heading, bar, advice]
            constraints.append(advice.widthAnchor.constraint(equalToConstant: Self.width))
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        // A leading-aligned stack keeps only its leading inset; its width keeps both (Al, 2026-10-16:
        // the bar ran to the popover's right edge).
        constraints.append(stack.widthAnchor.constraint(equalToConstant: Self.width + stack.edgeInsets.left + stack.edgeInsets.right))
        NSLayoutConstraint.activate(constraints)
        let controller = NSViewController()
        controller.view = stack
        popover.contentViewController = controller
    }

    /// Beside `anchor`, above the list where there is room; nothing without a report.
    func show(from anchor: NSView) {
        guard report != nil, anchor.window != nil, !anchor.isHiddenOrHasHiddenAncestor else { return }
        // Sized to the stack, insets included, so the bar keeps its side padding in the popover.
        content.layoutSubtreeIfNeeded()
        popover.contentSize = content.fittingSize
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }
    func hide() { if popover.isShown { popover.performClose(nil) } }
}

/// Shows a `ClipboardStorageDetail` while the pointer rests on its owner.
private final class ClipboardStorageHover {
    let detail: ClipboardStorageDetail
    private var area: NSTrackingArea?
    init(showsWarning: Bool) { detail = ClipboardStorageDetail(showsWarning: showsWarning) }
    func track(in view: NSView) {
        if let area { view.removeTrackingArea(area) }
        let next = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: view)
        view.addTrackingArea(next)
        area = next
    }
}

/// 💾 with a ⚠️ badge before the count line's count, shown while the history's budget (1% of free
/// space) is under 1 GB (Al, 2026-10-16). Resting the pointer on it shows the disk as one bar with
/// the warning's heading and what to do about it.
final class ClipboardStorageWarning: NSView {
    static let side: CGFloat = 18
    /// What it shows; nil or a budget of 1 GB or more hides it.
    var report: ClipboardStorageReport? {
        didSet {
            guard report != oldValue else { return }
            let hidden = !(report?.isLow ?? false)
            if hidden != isHidden {
                isHidden = hidden
                // Its container makes room before the count, or gives it back.
                superview?.needsLayout = true
            }
            setAccessibilityLabel(report == nil ? nil : ClipboardStorageReport.heading)
            setAccessibilityHelp(report.map { "\($0.summary) \(ClipboardStorageReport.advice)" })
            hover.detail.report = report
        }
    }
    /// The hover's words: its heading, the bar's numbers (its tooltip), and what to do.
    var detailText: String { report.map { [ClipboardStorageReport.heading, $0.summary, ClipboardStorageReport.advice].joined(separator: "\n") } ?? "" }
    var detailContent: NSView { hover.detail.content }
    var bar: ClipboardStorageBar { hover.detail.bar }
    var isShowingDetail: Bool { hover.detail.isShown }
    private let hover = ClipboardStorageHover(showsWarning: true)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }

    override func draw(_ dirtyRect: NSRect) {
        let disk = NSAttributedString(string: "💾", attributes: [.font: NSFont.systemFont(ofSize: 14)])
        let size = disk.size()
        disk.draw(at: NSPoint(x: (bounds.width - size.width) / 2 - 1, y: (bounds.height - size.height) / 2))
        let badge = NSAttributedString(string: "⚠️", attributes: [.font: NSFont.systemFont(ofSize: 8)])
        let badgeSize = badge.size()
        badge.draw(at: NSPoint(x: bounds.maxX - badgeSize.width + 1, y: isFlipped ? bounds.maxY - badgeSize.height + 1 : -1))
    }

    override func updateTrackingAreas() { super.updateTrackingAreas(); hover.track(in: self) }
    override func mouseEntered(with event: NSEvent) { showDetail() }
    override func mouseExited(with event: NSEvent) { hideDetail() }
    override func viewDidHide() { super.viewDidHide(); hideDetail() }
    override func viewWillMove(toWindow newWindow: NSWindow?) { if newWindow == nil { hideDetail() }; super.viewWillMove(toWindow: newWindow) }
    func showDetail() { hover.detail.show(from: self) }
    func hideDetail() { hover.detail.hide() }
}

/// The count line's *n of x items*: resting the pointer on it shows the disk as one bar, no
/// warning (Al, 2026-10-16), whatever the free space.
final class ClipboardCountLabel: NSTextField {
    var report: ClipboardStorageReport? { didSet { hover.detail.report = report } }
    var detailContent: NSView { hover.detail.content }
    var bar: ClipboardStorageBar { hover.detail.bar }
    var isShowingDetail: Bool { hover.detail.isShown }
    private let hover = ClipboardStorageHover(showsWarning: false)

    override func updateTrackingAreas() { super.updateTrackingAreas(); hover.track(in: self) }
    override func mouseEntered(with event: NSEvent) { showDetail() }
    override func mouseExited(with event: NSEvent) { hideDetail() }
    override func viewWillMove(toWindow newWindow: NSWindow?) { if newWindow == nil { hideDetail() }; super.viewWillMove(toWindow: newWindow) }
    func showDetail() { hover.detail.show(from: self) }
    func hideDetail() { hover.detail.hide() }
}
