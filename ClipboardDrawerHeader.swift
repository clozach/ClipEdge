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

    init(appIcon: NSImage? = ClipboardDrawerHeader.bundledApplicationIcon(), keymap: ClipboardKeymap = .drawer) {
        super.init(frame: .zero)
        icon.image = appIcon
        icon.imageScaling = .scaleProportionallyDown
        icon.isHidden = appIcon == nil
        icon.setAccessibilityElement(false)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        settingsButton.image = ClipboardIcons.symbol("gearshape", description: "Settings")
        settingsButton.imagePosition = .imageOnly
        settingsButton.bezelStyle = .recessed
        settingsButton.isBordered = true
        settingsButton.showsBorderOnlyWhileMouseInside = true
        settingsButton.setButtonType(.momentaryPushIn)
        settingsButton.target = self
        settingsButton.action = #selector(openSettings)
        settingsButton.keyEquivalent = ","
        settingsButton.keyEquivalentModifierMask = [.command]
        // "," while the cards hold the keyboard; ⌘, works from anywhere in the drawer, as in the menu.
        settingsButton.toolTip = keymap.help("Settings", .settings)
        settingsButton.setAccessibilityLabel(keymap.spoken(.settings).map { "Settings, \($0)" } ?? "Settings")
        [icon, title, settingsButton, publishControl].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("Use init(appIcon:)") }

    /// Shared by the live drawer and its isolated native evidence fixture. The header across the
    /// host's top and the browser under it, placed by the host's bounds whenever its frame or bounds
    /// change, not by constraints: Auto Layout reads a superview's frame, so in a host zoomed by the
    /// text size (2026-10-16) constraints put both a zoom's worth off.
    func install(above browser: NSView, in host: NSView) {
        host.addSubview(self)
        host.addSubview(browser)
        translatesAutoresizingMaskIntoConstraints = true
        browser.translatesAutoresizingMaskIntoConstraints = true
        installed = (host, browser)
        host.postsFrameChangedNotifications = true
        host.postsBoundsChangedNotifications = true
        for name in [NSView.frameDidChangeNotification, NSView.boundsDidChangeNotification] {
            hostObservers.append(NotificationCenter.default.addObserver(forName: name, object: host, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.placeInHost() }
            })
        }
        placeInHost()
    }
    private var installed: (host: NSView, browser: NSView)?
    private var hostObservers: [NSObjectProtocol] = []
    deinit { hostObservers.forEach(NotificationCenter.default.removeObserver) }

    private func placeInHost() {
        guard let (host, browser) = installed else { return }
        let bounds = host.bounds, height = min(Self.height, bounds.height)
        let headerY = host.isFlipped ? bounds.minY : bounds.maxY - height
        let browserY = host.isFlipped ? bounds.minY + height : bounds.minY
        let header = NSRect(x: bounds.minX, y: headerY, width: bounds.width, height: height)
        let below = NSRect(x: bounds.minX, y: browserY, width: bounds.width, height: max(0, bounds.height - height))
        if frame != header { frame = header }
        if browser.frame != below { browser.frame = below }
    }

    /// Publish takes the right edge alone, nothing above it or to its right (Al, 2026-10-12: the
    /// corner's symmetry), with the gear 6 points to its left; without Publish the gear keeps the
    /// edge. Tab goes as they sit, left to right: gear, then Publish (the drawer's key loop).
    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 16, y: 8, width: 20, height: 20)
        let titleX: CGFloat = hasAppIcon ? 44 : 16
        publishControl.sizeToFit()
        publishControl.frame = NSRect(x: bounds.width - 16 - publishControl.frame.width, y: 6,
                                      width: publishControl.frame.width, height: 24)
        let gearX = publishControl.isHidden ? bounds.width - 42 : publishControl.frame.minX - 6 - 28
        settingsButton.frame = NSRect(x: gearX, y: 5, width: 28, height: 26)
        title.frame = NSRect(x: titleX, y: 9, width: max(0, settingsButton.frame.minX - 6 - titleX), height: 20)
        // The gear moves with Publish, so its pointing hand does too.
        window?.invalidateCursorRects(for: self)
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
