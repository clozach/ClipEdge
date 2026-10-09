import AppKit

/// One local release action shared by the drawer and history window. It never
/// compares version strings or decides whether a release has actually landed.
final class ClipboardPublishControl: NSButton {
    var onPress: (() -> Void)?
    var onVisibilityChange: (() -> Void)?
    private var isBright = false
    /// 0...1 while the helper reports progress; nil draws the lozenge as before.
    private(set) var progress: Double?
    /// AppKit posts nothing when the value changes, and the title stays put, so VoiceOver
    /// hears progress only through this notice. A seam for the fixture tests.
    var postValueChange: (ClipboardPublishControl) -> Void = { NSAccessibility.post(element: $0, notification: .valueChanged) }
    private var announcedPercent: Int?
    private var isHovered = false
    private var hoverArea: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        setButtonType(.momentaryPushIn)
        bezelStyle = .rounded
        controlSize = .small
        font = .systemFont(ofSize: 11, weight: .semibold)
        keyEquivalent = "p"
        keyEquivalentModifierMask = [.command, .shift]
        target = self
        action = #selector(pressed)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("Use init()") }

    func apply(_ presentation: PublishPresentation) {
        let changed = isHidden == presentation.isVisible
        // Progress alone never changes the lozenge's size, so it skips relayout.
        let resized = changed || title != presentation.title || isEnabled != presentation.isEnabled
        title = presentation.title
        toolTip = presentation.help
        setAccessibilityLabel(presentation.title)
        setAccessibilityHelp(presentation.help)
        setAccessibilityValue(presentation.percent.map { "\($0) percent" })
        // Once per whole percent: redraws within the same percent stay silent.
        if presentation.percent != announcedPercent {
            announcedPercent = presentation.percent
            if presentation.percent != nil { postValueChange(self) }
        }
        isEnabled = presentation.isEnabled
        isHidden = !presentation.isVisible
        isBright = presentation.emphasis == .bright
        progress = presentation.percent == nil ? nil : min(max(presentation.progress ?? 0, 0), 1)
        needsDisplay = true
        if resized { superview?.needsLayout = true }
        if changed { onVisibilityChange?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isBright else { return super.draw(dirtyRect) }
        // Native bezelColor becomes gray in a nonactivating panel. The release
        // signal must stay bright even while another app owns the menu bar.
        let red: CGFloat = isHighlighted && isEnabled ? 0.70 : (isHovered && isEnabled ? 0.94 : 0.84)
        func pink(_ alpha: CGFloat) -> NSColor { NSColor(srgbRed: red, green: 0.05, blue: 0.40, alpha: alpha) }
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        if let progress {
            // The dimmed busy lozenge is the track; the finished part fills left to right at full strength.
            pink(0.55).setFill()
            shape.fill()
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            pink(1).setFill()
            NSRect(x: 0, y: 0, width: bounds.width * progress, height: bounds.height).fill(using: .sourceOver)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            pink(isEnabled ? 1 : 0.55).setFill()
            shape.fill()
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.white]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }

    /// Explicit routing also works when another app owns the menu bar and the
    /// nonactivating ClipEdge panel's search field owns the keyboard.
    @discardableResult func handleKey(_ event: NSEvent) -> Bool {
        guard !isHidden, event.modifierFlags.intersection([.command, .shift, .option, .control]) == [.command, .shift],
              event.charactersIgnoringModifiers?.lowercased() == "p" else { return false }
        if isEnabled && !event.isARepeat { performClick(nil) }
        return true
    }

    @objc private func pressed() { onPress?() }
}
