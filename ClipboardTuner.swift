import AppKit

enum ClipboardTunerScrub {
    case began
    case moved(CGFloat)
    case ended(CGFloat)
}

/// One value with its label above: drag the handle to scrub, applied as it moves; click
/// or Tab into the number and its text is selected; Return keeps it, Esc puts it back and
/// leaves; ↑/↓ nudge (⇧ for ten steps). Disabled, while its setting is unused, it is dimmed
/// and takes no drag, typing or undo. Submitted values keep an in-memory history, reached
/// by ⌘Z and ⇧⌘Z and by two magnets above the field's trailing end that show on hover or
/// focus while there is a step to take. The tuner itself is only its label and field: its
/// magnets and hover region live in a ClipboardTunerMagnetLayer laid over its group, so they
/// take no room. While one tuner of its group has the keyboard, only that tuner shows
/// magnets, since ⌘Z reaches it alone.
final class ClipboardTuner: NSControl, NSTextFieldDelegate {
    /// Compacted 2026-10-24 (Al: no tuner "made from 50% wasted pixels"): the field and its handle
    /// are 22 points, the web bloom tuner's new size; the label sits 2 points above.
    static let fieldHeight: CGFloat = 22
    static let handleWidth: CGFloat = 22
    /// The label sits this close above the field.
    static let labelGap: CGFloat = 2
    /// The magnets' distance above the field.
    static let magnetGap: CGFloat = 9
    /// The label ends this far short of the magnets' slots.
    static let labelClearance: CGFloat = 8
    /// Between the two magnets, along the field's top edge.
    static let magnetSpacing: CGFloat = 4
    /// Arrow presses this close together are one undo step.
    static let arrowCoalescing: TimeInterval = 1

    let spec: ClipboardTunerSpec
    private(set) var history: ClipboardTunerHistory
    /// The history's value, or while the handle is held, the value the drag has reached.
    var value: Double { scrubbing?.live ?? history.current }
    /// Its handle is being dragged: values arrive live, and the last arrives again when it is let go.
    var isScrubbing: Bool { scrubbing != nil }
    /// Every value the tuner applies: each drag move, a submit, undo, redo and a reset. The owner persists it.
    var onChange: ((Double) -> Void)?
    /// The tuners that share ⌘Z, itself included: those whose magnets share its layer.
    var group: [ClipboardTuner] { (undoMagnet.superview as? ClipboardTunerMagnetLayer)?.tuners ?? [self] }
    let titleLabel: NSTextField
    let field = ClipboardSurfaceView(frame: .zero)
    let handle: ClipboardTunerHandle
    /// The hairline between the handle and the number.
    let divider = ClipboardSurfaceView(frame: .zero)
    let entry = ClipboardTunerEntry(frame: .zero)
    let undoMagnet: ClipboardTunerMagnet
    let redoMagnet: ClipboardTunerMagnet
    /// Label, field and both magnet slots, as one place for the pointer; in the magnets' layer.
    private(set) lazy var hoverRegion = ClipboardTunerHoverRegion(owner: self)
    var undoButton: NSButton { undoMagnet.button }
    var redoButton: NSButton { redoMagnet.button }
    /// What Tab reaches: the number.
    var keyView: NSView { entry }
    var magnetsRevealed: Bool { !undoMagnet.isHidden || !redoMagnet.isHidden }
    private let clock: () -> TimeInterval
    /// How to drag the handle and how to type the number; a dimmed tuner offers neither.
    private let dragHelp: String
    private let typeHelp = "Click or Tab in to type a number; ↑ and ↓ nudge it, ⇧ for ten at a time. Return keeps it."
    private var lastArrowPress: TimeInterval?
    /// While the handle is held: the value the drag began from and the one it shows now.
    private var scrubbing: (start: Double, live: Double)?
    private var isHovered = false
    /// The window's key changes: a moment the keyboard may have arrived or left.
    private var keyObservers: [NSObjectProtocol] = []

    init(spec: ClipboardTunerSpec, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.spec = spec
        self.clock = clock
        history = ClipboardTunerHistory(current: spec.defaultValue)
        titleLabel = NSTextField(wrappingLabelWithString: spec.label)
        handle = ClipboardTunerHandle(symbol: spec.symbol, glyph: spec.glyph)
        let name = spec.label.lowercased()
        undoMagnet = ClipboardTunerMagnet(title: "↺ ⌘Z", help: "Undo the last change to \(name), Command–Z")
        redoMagnet = ClipboardTunerMagnet(title: "↻ ⇧⌘Z", help: "Redo the change to \(name) you undid, Shift–Command–Z")
        dragHelp = "Drag left or right to change \(name) (\(spec.text(spec.minimum))–\(spec.text(spec.maximum)))"
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        field.translatesAutoresizingMaskIntoConstraints = false
        paintField()
        handle.translatesAutoresizingMaskIntoConstraints = false
        handle.toolTip = dragHelp
        handle.onScrub = { [weak self] in self?.scrub($0) }
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.surface = ClipboardSurface(fill: .init(color: .separatorColor))
        entry.translatesAutoresizingMaskIntoConstraints = false
        entry.isBordered = false
        entry.drawsBackground = false
        entry.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        entry.delegate = self
        entry.cell?.usesSingleLineMode = true
        entry.cell?.wraps = false
        entry.cell?.isScrollable = true
        entry.setAccessibilityLabel(spec.accessibilityLabel)
        entry.toolTip = typeHelp
        entry.onKeyboardMove = { [weak self] in self?.keyboardMoved() }
        entry.ring = { [weak self] in
            guard let self else { return nil }
            return (self.field.convert(self.field.bounds, to: self.entry), self.field.surface.radius)
        }
        undoButton.target = self
        undoButton.action = #selector(undo)
        redoButton.target = self
        redoButton.action = #selector(redo)
        addSubview(titleLabel)
        addSubview(field)
        [handle, divider, entry].forEach(field.addSubview)
        // The magnets' slots: both widths and the space between, at the field's trailing end.
        let slots = undoMagnet.width + Self.magnetSpacing + redoMagnet.width
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            // The label wraps short of the magnets' slots, so its words never run under them.
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(slots + Self.labelClearance)),
            field.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: Self.labelGap),
            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.bottomAnchor.constraint(equalTo: bottomAnchor),
            field.heightAnchor.constraint(equalToConstant: Self.fieldHeight),
            handle.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            handle.topAnchor.constraint(equalTo: field.topAnchor),
            handle.bottomAnchor.constraint(equalTo: field.bottomAnchor),
            handle.widthAnchor.constraint(equalToConstant: Self.handleWidth),
            divider.leadingAnchor.constraint(equalTo: handle.trailingAnchor),
            divider.topAnchor.constraint(equalTo: field.topAnchor),
            divider.bottomAnchor.constraint(equalTo: field.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            entry.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 6),
            entry.trailingAnchor.constraint(equalTo: field.trailingAnchor, constant: -6),
            entry.centerYAnchor.constraint(equalTo: field.centerYAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(spec.label)
        render()
    }

    required init?(coder: NSCoder) { fatalError("Use init(spec:)") }
    deinit { keyObservers.forEach(NotificationCenter.default.removeObserver) }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    /// Dimmed and still while its setting is unused: no drag, no typing, no magnets, no ⌘Z,
    /// and no help offering them; the owner's tooltip on the tuner says why it is dimmed.
    override var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            if !isEnabled, hasKeyboardFocus { window?.makeFirstResponder(nil) }
            entry.isEnabled = isEnabled
            handle.isEnabled = isEnabled
            handle.toolTip = isEnabled ? dragHelp : nil
            entry.toolTip = isEnabled ? typeHelp : nil
            alphaValue = isEnabled ? 1 : 0.5
            refreshMagnets()
        }
    }

    /// The field's border takes the accent while the number has the keyboard.
    private func paintField() {
        field.surface = ClipboardSurface(fill: .init(color: .controlBackgroundColor), rim: hasKeyboardFocus ? .controlAccentColor : .separatorColor,
                                         radius: 6, clips: true)
    }

    // MARK: Values

    /// A value chosen through the control's owner (Reset): one undo step, like any other.
    func submit(_ value: Double) { record(spec.clamped(value)) }

    /// The saved value, shown with nothing to undo: at first showing, or when the setting changed elsewhere.
    func load(_ value: Double) {
        let value = spec.clamped(value)
        guard scrubbing == nil, value != self.value else { return }
        lastArrowPress = nil
        history.load(value)
        render()
    }

    private func record(_ value: Double) {
        lastArrowPress = nil
        guard value != self.value else { render(); return }
        history.submit(value)
        settled()
    }

    /// The ↺ magnet and ⌘Z alike: a typed draft undoes its typing first (performKeyEquivalent
    /// leaves the chord to the window for that); otherwise the last value comes back.
    @objc func undo() {
        if hasKeyboardFocus, entry.typing.canUndo { entry.typing.undo(); return }
        guard scrubbing == nil, history.undo() else { return }
        lastArrowPress = nil
        settled()
    }

    @objc func redo() {
        if hasKeyboardFocus, entry.typing.canRedo { entry.typing.redo(); return }
        guard scrubbing == nil, history.redo() else { return }
        lastArrowPress = nil
        settled()
    }

    private func settled() {
        render()
        onChange?(value)
    }

    private func render() {
        show(value)
        refreshMagnets()
    }

    /// The number as shown. Showing a value ends any typed draft, so ⌘Z after it undoes values, not old typing.
    private func show(_ value: Double) {
        entry.stringValue = spec.text(value)
        entry.setAccessibilityValue(spec.text(value))
        entry.forgetTyping()
    }

    private func submitTyped() {
        if let typed = spec.parsed(entry.stringValue) { record(typed) } else { render() }
    }

    /// Keeps a typed number without leaving the field, as a browser's blur does when its window loses focus.
    func submitDraft() {
        guard let editor = entry.currentEditor() else { return }
        submitTyped()
        editor.selectAll(nil)
    }

    private func nudge(_ presses: Int, large: Bool) {
        let now = clock()
        let coalesces = lastArrowPress.map { now - $0 < Self.arrowCoalescing } ?? false
        // From the kept value: showing the result drops any typed draft.
        let next = spec.nudged(value, by: presses, large: large)
        let steps = history.past.count
        if coalesces { history.amend(next) } else { history.submit(next) }
        // The next press amends this step only while there is one: a press that changes
        // nothing opens none, and one that returns the value to where the step began closes it.
        let stepOpen = coalesces ? history.past.count == steps : history.past.count > steps
        lastArrowPress = stepOpen ? now : nil
        settled()
        entry.currentEditor()?.selectAll(nil)
    }

    /// Each move applies at once; the history takes the drag as one step when the handle is let go.
    private func scrub(_ scrub: ClipboardTunerScrub) {
        switch scrub {
        case .began:
            lastArrowPress = nil
            scrubbing = (value, value)
        case .moved(let points):
            guard let scrubbing else { return }
            let live = spec.scrubbed(from: scrubbing.start, points: points)
            guard live != scrubbing.live else { return }
            self.scrubbing = (scrubbing.start, live)
            show(live)
            onChange?(live)
        case .ended(let points):
            guard let scrubbing else { return }
            self.scrubbing = nil
            history.submit(spec.scrubbed(from: scrubbing.start, points: points))
            settled()
        }
    }

    // MARK: Typing

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            submitTyped()
            textView.selectAll(nil)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            // Esc puts the number back and leaves the field in one press; the next Esc closes Settings.
            render()
            window?.makeFirstResponder(nil)
            return true
        case #selector(NSResponder.moveUp(_:)): nudge(1, large: false); return true
        case #selector(NSResponder.moveDown(_:)): nudge(-1, large: false); return true
        case #selector(NSResponder.moveUpAndModifySelection(_:)): nudge(1, large: true); return true
        case #selector(NSResponder.moveDownAndModifySelection(_:)): nudge(-1, large: true); return true
        default: return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) { submitTyped() }

    /// ⌘Z and ⇧⌘Z while the number has the keyboard. A typed draft undoes and redoes its
    /// typing first, as a browser's field does, through the window's editing chords;
    /// otherwise they step through the values.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let command = ClipboardFieldEditing.command(for: event)
        guard hasKeyboardFocus, command == .undo || command == .redo,
              !(command == .undo ? entry.typing.canUndo : entry.typing.canRedo) else { return super.performKeyEquivalent(with: event) }
        if !event.isARepeat { command == .redo ? redo() : undo() }
        return true
    }

    /// The number has the keyboard: its window's first responder is the number or the field
    /// editor editing it. Read from the window each time, never remembered, so the border,
    /// the magnets and ⌘Z agree with AppKit however the keyboard arrived.
    var hasKeyboardFocus: Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder === entry { return true }
        if let editor = responder as? NSTextView, editor.delegate === entry { return true }
        return (responder as? NSView)?.isDescendant(of: self) == true
    }

    // MARK: Magnets

    /// The keyboard may have arrived or left: every tuner of the group reads who has it and
    /// redraws from that, since a hovered neighbour's magnets give way while this one has the
    /// keyboard, and come back after.
    private func keyboardMoved() {
        for tuner in group {
            tuner.paintField()
            tuner.refreshMagnets()
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        keyObservers.forEach(NotificationCenter.default.removeObserver)
        keyObservers = newWindow.map { window in
            [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map {
                NotificationCenter.default.addObserver(forName: $0, object: window, queue: nil) { [weak self] _ in self?.keyboardMoved() }
            }
        } ?? []
    }

    /// Another tuner of the group has the keyboard, so ⌘Z is that tuner's.
    private var keyboardElsewhere: Bool { group.contains { $0 !== self && $0.hasKeyboardFocus } }

    /// The keyboard in the number, or the pointer in its hover region (label, field or the
    /// magnets' slots) while no other tuner has the keyboard, shows each magnet that has a step
    /// to take; neither moves anything.
    private func refreshMagnets() {
        let revealed = isEnabled && (hasKeyboardFocus || (isHovered && !keyboardElsewhere))
        undoMagnet.isHidden = !(revealed && history.canUndo)
        redoMagnet.isHidden = !(revealed && history.canRedo)
    }

    /// A ⌘Z or ⇧⌘Z nothing else in Settings took: the hovered tuner's, as its magnet promises.
    func performHoveredChord(_ event: NSEvent) -> Bool {
        let command = ClipboardFieldEditing.command(for: event)
        guard isEnabled, isHovered, !keyboardElsewhere, command == .undo ? history.canUndo : (command == .redo && history.canRedo) else { return false }
        if !event.isARepeat { command == .redo ? redo() : undo() }
        return true
    }

    /// From the hover region, which the magnets' layer places.
    override func mouseEntered(with event: NSEvent) { isHovered = true; refreshMagnets() }
    override func mouseExited(with event: NSEvent) { isHovered = false; refreshMagnets() }

    /// A press on the field around the number puts the keyboard in the number, selected, and
    /// leaves a number being typed alone; a press on the label passes on, which leaves the field.
    override func mouseDown(with event: NSEvent) {
        guard field.bounds.contains(field.convert(event.locationInWindow, from: nil)) else { return super.mouseDown(with: event) }
        if entry.currentEditor() == nil { window?.makeFirstResponder(entry) }
    }

    /// A press on this part of Settings keeps the keyboard in the number: the field holding
    /// it (handle and number) and the magnets that act on it. A press anywhere else leaves it.
    func keepsKeyboard(forPressOn view: NSView) -> Bool {
        [field, undoMagnet, redoMagnet].contains { view.isDescendant(of: $0) }
    }

    /// AppKit sends no mouseExited when the window closes under the pointer; Settings ends the hover
    /// itself. AppKit still counts the pointer inside the areas it was in, and would send no
    /// mouseEntered on its next visit to them, so each part starts a fresh area, outside.
    func endHover() {
        isHovered = false
        hoverRegion.updateTrackingAreas()
        handle.endHover()
        [undoMagnet, redoMagnet].forEach { $0.endHover() }
        refreshMagnets()
    }
}
