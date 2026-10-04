import AppKit

/// The one question the updater asks, on first launch. It floats without taking the keyboard,
/// so nothing typed in another app can answer it. Once clicked, Return and Escape choose;
/// Space does nothing.
final class UpdateConsentPanel: NSPanel {
    static let question = "Keep ClipEdge up to date automatically?"
    static let explanation = "Once a day ClipEdge looks on GitHub for a newer version and installs it while you are not using it. Nothing about you or your clipboard is sent. You can change this at any time: ClipEdge menu bar icon → Updates."
    private let onChoice: (UpdatePreference) -> Void

    init(onChoice: @escaping (UpdatePreference) -> Void) {
        self.onChoice = onChoice
        super.init(contentRect: NSRect(x: 0, y: 0, width: 460, height: 160),
                   styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "ClipEdge"
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = Self.content(target: self)
        if let fitting = contentView?.fittingSize { setContentSize(fitting) }
    }

    func present() {
        if let screen = NSScreen.main?.visibleFrame {
            setFrameOrigin(NSPoint(x: screen.midX - frame.width / 2, y: screen.minY + screen.height * 0.62))
        }
        orderFrontRegardless()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        // Space must never answer; Return and Escape reach the buttons through super.
        if event.keyCode == 49 { return }
        super.keyDown(with: event)
    }

    @objc private func accept() { choose(.automatic) }
    @objc private func decline() { choose(.manual) }

    private func choose(_ preference: UpdatePreference) {
        close()
        onChoice(preference)
    }

    private static func content(target: UpdateConsentPanel) -> NSView {
        let icon = NSImageView(image: NSApplication.shared.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        let heading = NSTextField(wrappingLabelWithString: question)
        heading.font = .boldSystemFont(ofSize: 14)
        let body = NSTextField(wrappingLabelWithString: explanation)
        body.font = .systemFont(ofSize: 13)

        let yes = NSButton(title: "Update Automatically ⏎", target: target, action: #selector(accept))
        yes.keyEquivalent = "\r"
        let no = NSButton(title: "No Thanks esc", target: target, action: #selector(decline))
        no.keyEquivalent = "\u{1b}"
        for button in [yes, no] {
            button.bezelStyle = .rounded
            button.refusesFirstResponder = true
        }
        yes.toolTip = "Check once a day and install new versions (Return)"
        no.toolTip = "Leave updates off; Updates in the ClipEdge menu turns them on later (Escape)"

        let buttons = NSStackView(views: [NSView(), no, yes])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        let text = NSStackView(views: [heading, body, buttons])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 8
        text.setCustomSpacing(16, after: body)
        let row = NSStackView(views: [icon, text])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 16
        row.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(row)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -18),
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            icon.widthAnchor.constraint(equalToConstant: 56),
            icon.heightAnchor.constraint(equalToConstant: 56),
            heading.widthAnchor.constraint(equalToConstant: 350),
            body.widthAnchor.constraint(equalToConstant: 350),
            buttons.widthAnchor.constraint(equalTo: body.widthAnchor),
        ])
        return container
    }
}
