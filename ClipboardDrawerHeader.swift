import AppKit

/// Identifies the drawer and keeps its reveal controls reachable in place.
final class ClipboardDrawerHeader: NSView {
    static let height: CGFloat = 36
    let settingsButton = NSButton()
    let publishControl = ClipboardPublishControl()
    private let title = NSTextField(labelWithString: "ClipEdge")
    private let icon = NSImageView()
    var onSettings: (() -> Void)?
    var hasAppIcon: Bool { icon.image != nil }
    override var isFlipped: Bool { true }

    init(appIcon: NSImage? = ClipboardDrawerHeader.bundledApplicationIcon()) {
        super.init(frame: .zero)
        icon.image = appIcon
        icon.imageScaling = .scaleProportionallyDown
        icon.isHidden = appIcon == nil
        icon.setAccessibilityElement(false)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        settingsButton.image = ClipboardIcons.symbol("gearshape", description: "Reveal Settings")
        settingsButton.imagePosition = .imageOnly
        settingsButton.bezelStyle = .recessed
        settingsButton.isBordered = true
        settingsButton.showsBorderOnlyWhileMouseInside = true
        settingsButton.setButtonType(.momentaryPushIn)
        settingsButton.target = self
        settingsButton.action = #selector(openSettings)
        settingsButton.keyEquivalent = ","
        settingsButton.keyEquivalentModifierMask = [.command]
        settingsButton.toolTip = "Reveal Settings ← ⌘,"
        settingsButton.setAccessibilityLabel("Reveal Settings, Command-comma")
        [icon, title, settingsButton, publishControl].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("Use init(appIcon:)") }

    /// Shared by the live drawer and its isolated native evidence fixture.
    func install(above browser: NSView, in host: NSView) {
        translatesAutoresizingMaskIntoConstraints = false
        browser.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(self)
        host.addSubview(browser)
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: host.leadingAnchor),
            trailingAnchor.constraint(equalTo: host.trailingAnchor),
            topAnchor.constraint(equalTo: host.topAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
            browser.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            browser.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            browser.topAnchor.constraint(equalTo: bottomAnchor),
            browser.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 16, y: 8, width: 20, height: 20)
        let titleX: CGFloat = hasAppIcon ? 44 : 16
        publishControl.sizeToFit()
        publishControl.frame = NSRect(x: bounds.width - 50 - publishControl.frame.width, y: 6,
                                      width: publishControl.frame.width, height: 24)
        let titleRight = publishControl.isHidden ? bounds.width - 54 : publishControl.frame.minX - 6
        title.frame = NSRect(x: titleX, y: 9, width: max(0, titleRight - titleX), height: 20)
        settingsButton.frame = NSRect(x: bounds.width - 42, y: 5, width: 28, height: 26)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.withAlphaComponent(0.5).setFill()
        NSRect(x: 16, y: bounds.height - 0.5, width: max(0, bounds.width - 32), height: 0.5).fill()
    }

    override func resetCursorRects() {
        addCursorRect(settingsButton.frame, cursor: .pointingHand)
        if !publishControl.isHidden && publishControl.isEnabled { addCursorRect(publishControl.frame, cursor: .pointingHand) }
    }
    @objc private func openSettings() { onSettings?() }

    private static func bundledApplicationIcon() -> NSImage? {
        // NSApplicationIcon alone can be the generic missing-artwork placeholder.
        // Show it only when this bundle actually contains the declared artwork.
        guard let declared = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String else { return nil }
        let name = declared as NSString
        let ext = name.pathExtension.isEmpty ? "icns" : name.pathExtension
        let stem = name.pathExtension.isEmpty ? declared : name.deletingPathExtension
        guard let url = Bundle.main.url(forResource: stem, withExtension: ext),
              let image = NSImage(contentsOf: url) else { return nil }
        return image
    }
}
