import AppKit

/// The Send to list: apps that can open the item, then running apps to paste
/// into. One keyboard stop; ← or Esc goes back.
final class ClipboardSendToView: NSView {
    var onSend: ((ClipboardSendTarget) -> Void)?
    var onBack: (() -> Void)?
    private(set) var targets: [ClipboardSendTarget] = []
    private(set) var selectedIndex = 0
    private enum Row { case heading(String), target(Int) }
    private var rows: [Row] = []
    private var icons: [NSImage?] = []
    private let heading = NSTextField(labelWithString: "Send to")
    private let scroll = NSScrollView()
    private let list = ClipboardSendToList()
    private var typed = ""
    private var typedAt = 0.0
    private static let rowHeight: CGFloat = 30
    private static let headingHeight: CGFloat = 22
    private static let top: CGFloat = 38
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var selected: ClipboardSendTarget? { targets.indices.contains(selectedIndex) ? targets[selectedIndex] : nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        scroll.documentView = list
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        list.owner = self
        [heading, scroll].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Send to")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ targets: [ClipboardSendTarget]) {
        self.targets = targets
        icons = targets.map { $0.appURL.map { NSWorkspace.shared.icon(forFile: $0.path) } }
        rows = []
        for (index, target) in targets.enumerated() {
            let isFirstOfKind = index == 0 || targets[index - 1].isOpen != target.isOpen
            if isFirstOfKind { rows.append(.heading(target.isOpen ? "Open in" : "Paste into")) }
            rows.append(.target(index))
        }
        selectedIndex = 0
        typed = ""
        needsLayout = true
        layoutSubtreeIfNeeded()
        select(0)
    }

    /// The whole list when it fits; otherwise it scrolls inside this height.
    func fittingHeight(limit: CGFloat) -> CGFloat { min(limit, Self.top + contentHeight + 10) }
    private var contentHeight: CGFloat {
        rows.reduce(0) { total, row in
            if case .heading = row { return total + Self.headingHeight }
            return total + Self.rowHeight
        }
    }

    override func layout() {
        super.layout()
        heading.frame = NSRect(x: 16, y: 12, width: bounds.width - 32, height: 18)
        scroll.frame = NSRect(x: 8, y: Self.top, width: bounds.width - 16, height: max(0, bounds.height - Self.top - 8))
        list.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: max(scroll.contentSize.height, contentHeight))
        list.needsDisplay = true
    }

    func move(_ delta: Int, wrapping: Bool = false) {
        guard !targets.isEmpty else { return }
        let next = selectedIndex + delta
        select(wrapping ? (next + targets.count) % targets.count : min(max(0, next), targets.count - 1))
    }

    private func select(_ index: Int) {
        guard targets.indices.contains(index) else { return }
        selectedIndex = index
        setAccessibilityValue(targets[index].name)
        if let frame = frame(ofTarget: index) { list.scrollToVisible(frame.insetBy(dx: 0, dy: -Self.headingHeight)) }
        list.needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch event.keyCode {
        case 53, 123: onBack?()
        case 125: move(1)
        case 126: move(-1)
        case 36, 76: if let selected { onSend?(selected) }
        default:
            guard modifiers.subtracting(.shift).isEmpty, let characters = event.charactersIgnoringModifiers,
                  characters.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(.whitespaces).contains($0) }),
                  !characters.isEmpty else { super.keyDown(with: event); return }
            typeAhead(characters)
        }
    }

    /// Typing a name jumps to the first app that starts with it.
    private func typeAhead(_ characters: String) {
        let now = ProcessInfo.processInfo.systemUptime
        typed = now - typedAt < 0.9 ? typed + characters : characters
        typedAt = now
        if let index = targets.firstIndex(where: { $0.name.localizedLowercase.hasPrefix(typed.localizedLowercase) }) { select(index) }
    }

    private func frame(ofTarget index: Int) -> NSRect? {
        var y: CGFloat = 0
        for row in rows {
            switch row {
            case .heading: y += Self.headingHeight
            case .target(let target):
                if target == index { return NSRect(x: 0, y: y, width: list.bounds.width, height: Self.rowHeight) }
                y += Self.rowHeight
            }
        }
        return nil
    }

    fileprivate func target(at point: NSPoint) -> Int? {
        targets.indices.first { frame(ofTarget: $0)?.contains(point) == true }
    }
    fileprivate func hover(_ point: NSPoint) { if let index = target(at: point), index != selectedIndex { select(index) } }
    fileprivate func click(_ point: NSPoint) { if let index = target(at: point) { select(index); onSend?(targets[index]) } }

    fileprivate func drawRows() {
        var y: CGFloat = 0
        let width = list.bounds.width
        for row in rows {
            switch row {
            case .heading(let title):
                draw(title, in: NSRect(x: 8, y: y + 6, width: width - 16, height: 14), size: 10, weight: .semibold, color: .secondaryLabelColor)
                y += Self.headingHeight
            case .target(let index):
                let frame = NSRect(x: 0, y: y, width: width, height: Self.rowHeight)
                if index == selectedIndex {
                    NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
                    NSBezierPath(roundedRect: frame.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7).fill()
                }
                icons[index]?.draw(in: NSRect(x: 8, y: y + 5, width: 20, height: 20), from: .zero, operation: .sourceOver,
                                   fraction: 1, respectFlipped: true, hints: nil)
                draw(targets[index].name, in: NSRect(x: 36, y: y + 7, width: width - 44, height: 17), size: 13, weight: .regular, color: .labelColor)
                y += Self.rowHeight
            }
        }
    }

    private func draw(_ text: String, in rect: NSRect, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                              attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: paragraph])
    }
}

/// The scrolling rows; selection and actions belong to the owning view.
private final class ClipboardSendToList: NSView {
    weak var owner: ClipboardSendToView?
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) { owner?.drawRows() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeAlways, .mouseMoved], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseMoved(with event: NSEvent) { owner?.hover(convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) { owner?.click(convert(event.locationInWindow, from: nil)) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
