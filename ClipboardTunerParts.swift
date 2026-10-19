import AppKit

/// The number: it says when the keyboard may have come or gone (the tuner reads who has
/// it from the window), draws its focus ring around the whole field rather than around
/// the digits alone, and keeps its own typing undo, apart from the tuner's values.
final class ClipboardTunerEntry: NSTextField {
    /// Each moment the keyboard may have arrived or left: taking it, a click's end (AppKit's
    /// click ends and restarts editing without taking it again), editing beginning or ending.
    var onKeyboardMove: (() -> Void)?
    var ring: (() -> (rect: NSRect, radius: CGFloat)?)?
    /// The field editor's undo while this field is edited (see typingUndoManager).
    let typing = UndoManager()
    /// The press AppKit was delivering when this field took the keyboard: a window may give
    /// the field the keyboard for a press before handing it that press. Compared by identity,
    /// so a press kept from an earlier editing session never matches a new one.
    private var pressThatEntered: NSEvent?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted, let press = NSApp?.currentEvent, press.type == .leftMouseDown { pressThatEntered = press }
        if accepted { onKeyboardMove?() }
        return accepted
    }

    override func textDidBeginEditing(_ notification: Notification) {
        super.textDidBeginEditing(notification)
        onKeyboardMove?()
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        pressThatEntered = nil
        onKeyboardMove?()
    }

    /// The click that brings the keyboard in selects the number whole, as Tab does, whether the
    /// field was not editing yet or its window gave it the keyboard for this press; a click
    /// while it is already being edited places the caret, as in a browser.
    override func mouseDown(with event: NSEvent) {
        let entering = currentEditor() == nil || pressThatEntered === event
        pressThatEntered = nil
        super.mouseDown(with: event)
        if entering { currentEditor()?.selectAll(nil) }
        onKeyboardMove?()
    }

    /// The field editor asks its delegate, this field, where typing is undone.
    @objc(undoManagerForTextView:) func typingUndoManager(for view: NSTextView) -> UndoManager? { typing }

    /// The typed draft is gone once a value is shown, and its typing with it.
    func forgetTyping() {
        (currentEditor() as? NSTextView)?.breakUndoCoalescing()
        typing.removeAllActions()
    }

    override func drawFocusRingMask() {
        guard let ring = ring?() else { return super.drawFocusRingMask() }
        NSBezierPath(roundedRect: ring.rect, xRadius: ring.radius, yRadius: ring.radius).fill()
    }

    override var focusRingMaskBounds: NSRect { ring?()?.rect ?? super.focusRingMaskBounds }
}

/// The drag handle at the field's leading end. A plain drag, tracked by this
/// view: the pointer stays visible and the value follows it left and right.
/// Disabled, it neither drags, tints nor offers its cursor.
final class ClipboardTunerHandle: ClipboardSurfaceView {
    var onScrub: ((ClipboardTunerScrub) -> Void)?
    private var dragOrigin: CGFloat?
    private var isHovered = false
    private var hoverArea: NSTrackingArea?
    var isDragging: Bool { dragOrigin != nil }
    var isEnabled = true {
        didSet { if !isEnabled { endHover() }; window?.invalidateCursorRects(for: self) }
    }

    init(symbol: String, glyph: String) {
        super.init(frame: .zero)
        let mark: NSView
        if let image = ClipboardIcons.symbol(symbol, pointSize: 13) {
            let view = NSImageView(image: image)
            view.contentTintColor = .controlAccentColor
            mark = view
        } else {
            let label = NSTextField(labelWithString: glyph)
            label.textColor = .controlAccentColor
            mark = label
        }
        mark.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mark)
        NSLayoutConstraint.activate([mark.centerXAnchor.constraint(equalTo: centerXAnchor), mark.centerYAnchor.constraint(equalTo: centerYAnchor)])
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("Use init(symbol:glyph:)") }

    override func resetCursorRects() { if isEnabled { addCursorRect(bounds, cursor: .resizeLeftRight) } }

    /// A press anywhere on the handle, its symbol included, is the handle's, and the first
    /// press in a Settings window that is not key already scrubs, as the number and slider do.
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = isEnabled; tint() }
    override func mouseExited(with event: NSEvent) { isHovered = false; tint() }
    /// The window closed under the pointer: no tint, and a fresh area the next visit enters.
    func endHover() { isHovered = false; tint(); updateTrackingAreas() }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        dragOrigin = event.locationInWindow.x
        tint()
        onScrub?(.began)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragOrigin else { return }
        onScrub?(.moved(event.locationInWindow.x - dragOrigin))
    }

    override func mouseUp(with event: NSEvent) {
        guard let dragOrigin else { return }
        self.dragOrigin = nil
        tint()
        onScrub?(.ended(event.locationInWindow.x - dragOrigin))
    }

    private func tint() {
        surface = isHovered || isDragging ? ClipboardSurface(fill: .init(color: .controlAccentColor, opacity: 0.18)) : ClipboardSurface()
    }
}

/// A magnet control above the tuner's field: a card-ground lozenge holding one
/// borderless button, shown and hidden whole. It takes clicks, never the keyboard;
/// its chord is in its label. It lives in a ClipboardTunerMagnetLayer, out of the layout.
final class ClipboardTunerMagnet: ClipboardSurfaceView {
    static let height: CGFloat = 16
    let button: NSButton
    /// As wide as its whole label; the tuner keeps its own label short of both magnets' widths.
    let width: CGFloat
    private var isHovered = false
    private var hoverArea: NSTrackingArea?

    init(title: String, help: String) {
        button = NSButton(title: title, target: nil, action: nil)
        button.isBordered = false
        button.font = .systemFont(ofSize: 10, weight: .medium)
        width = ceil(button.intrinsicContentSize.width) + 10
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        button.translatesAutoresizingMaskIntoConstraints = false
        button.refusesFirstResponder = true
        button.toolTip = help
        button.setAccessibilityLabel(help)
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: Self.height)
        ])
        isHidden = true
        paint()
    }

    required init?(coder: NSCoder) { fatalError("Use init(title:help:)") }

    override var acceptsFirstResponder: Bool { false }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; paint() }
    override func mouseExited(with event: NSEvent) { isHovered = false; paint() }
    /// The window closed under the pointer: no accent, and a fresh area the next visit enters.
    func endHover() { isHovered = false; paint(); updateTrackingAreas() }
    /// Hidden under the pointer (its last step taken), it shows again unhovered.
    override func viewDidHide() { super.viewDidHide(); isHovered = false; paint() }

    private func paint() {
        surface = isHovered
            ? ClipboardSurface(fill: .init(color: .controlAccentColor, opacity: 0.18), rim: .controlAccentColor, radius: Self.height / 2)
            : .card(radius: Self.height / 2)
    }
}

/// A tuner's hover region: its label, field and both magnet slots as one tracking area, so the
/// pointer can cross the gap between the field and a magnet, or rest on the part of a magnet
/// that reaches past the tuner's top, without leaving the tuner. It takes no press.
final class ClipboardTunerHoverRegion: NSView {
    private weak var owner: NSResponder?
    private var area: NSTrackingArea?

    /// `owner` hears the pointer enter and leave the region.
    init(owner: NSResponder) {
        self.owner = owner
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
        updateTrackingAreas()
    }

    required init?(coder: NSCoder) { fatalError("Use init(owner:)") }

    /// Who hears the pointer come and go: the tuner.
    var pointerOwner: AnyObject? { area?.owner as AnyObject? }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        area = owner.map { NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: $0) }
        area.map(addTrackingArea)
    }
}

/// Where a group of tuners shows its magnets, out of the layout: one transparent view over
/// the whole of the view holding the tuners, above every control in it. It holds each tuner's
/// two magnets where that tuner's field puts them (↺ ⌘Z with its bottom 9 points above the
/// field's top and its right edge on the field's, ↻ ⇧⌘Z 4 points to its left), free to reach
/// past the tuner's top, and each tuner's hover region. Nothing in it takes room in the
/// layout, so showing or hiding a magnet moves nothing. A press passes through it to the
/// controls beneath, except on a shown magnet. The tuners laid out together share ⌘Z.
final class ClipboardTunerMagnetLayer: NSView {
    let tuners: [ClipboardTuner]

    /// Lays a layer over the whole of `host`, above everything already in it, holding the
    /// magnets of `tuners`, which must already be inside `host`.
    @discardableResult static func lay(_ tuners: [ClipboardTuner], over host: NSView) -> ClipboardTunerMagnetLayer {
        precondition(tuners.allSatisfy { $0.isDescendant(of: host) }, "a magnet layer lies over the view that holds its tuners")
        let layer = ClipboardTunerMagnetLayer(tuners: tuners, frame: host.bounds)
        host.addSubview(layer)
        NSLayoutConstraint.activate(tuners.flatMap(layer.place))
        return layer
    }

    private init(tuners: [ClipboardTuner], frame: NSRect) {
        self.tuners = tuners
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("Use lay(_:over:)") }

    private func place(_ tuner: ClipboardTuner) -> [NSLayoutConstraint] {
        let (undo, redo, region) = (tuner.undoMagnet, tuner.redoMagnet, tuner.hoverRegion)
        [region, redo, undo].forEach(addSubview)
        // The region is the smallest box holding the tuner and both magnet slots.
        let snug = [region.widthAnchor.constraint(equalToConstant: 0), region.heightAnchor.constraint(equalToConstant: 0)]
        snug.forEach { $0.priority = .defaultLow }
        return snug + [
            undo.trailingAnchor.constraint(equalTo: tuner.field.trailingAnchor),
            undo.bottomAnchor.constraint(equalTo: tuner.field.topAnchor, constant: -ClipboardTuner.magnetGap),
            redo.trailingAnchor.constraint(equalTo: undo.leadingAnchor, constant: -ClipboardTuner.magnetSpacing),
            redo.bottomAnchor.constraint(equalTo: undo.bottomAnchor),
            region.leadingAnchor.constraint(lessThanOrEqualTo: tuner.leadingAnchor),
            region.leadingAnchor.constraint(lessThanOrEqualTo: redo.leadingAnchor),
            region.trailingAnchor.constraint(greaterThanOrEqualTo: tuner.trailingAnchor),
            region.trailingAnchor.constraint(greaterThanOrEqualTo: undo.trailingAnchor),
            region.topAnchor.constraint(lessThanOrEqualTo: tuner.topAnchor),
            region.topAnchor.constraint(lessThanOrEqualTo: undo.topAnchor),
            region.topAnchor.constraint(lessThanOrEqualTo: redo.topAnchor),
            region.bottomAnchor.constraint(greaterThanOrEqualTo: tuner.bottomAnchor)
        ]
    }

    /// Only a shown magnet takes a press; everywhere else, the controls beneath do.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
