import AppKit

/// The Updates submenu, the first-launch question, and the alerts that answer its commands.
@MainActor
final class UpdateMenu: NSObject, NSMenuDelegate {
    static let releasePage = URL(string: "https://github.com/clozach/ClipEdge/releases/latest")!
    private let controller: UpdateController
    private var parents: [NSMenuItem] = []
    private var consent: UpdateConsentPanel?

    init(controller: UpdateController) {
        self.controller = controller
        super.init()
        controller.onChange = { [weak self] in self?.refreshTitles() }
        controller.onNeedsChoice = { [weak self] in self?.ask() }
    }

    /// One "Updates" item per menu (the menu bar item and the app menu share this controller).
    func makeMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Updates", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Updates")
        submenu.autoenablesItems = false
        submenu.delegate = self
        item.submenu = submenu
        parents.append(item)
        refreshTitles()
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for row in UpdateStatus.rows(snapshot) { menu.addItem(item(for: row)) }
    }

    private var snapshot: UpdateStatus.Snapshot {
        UpdateStatus.Snapshot(version: controller.runningVersion, availability: controller.availability,
                              preference: controller.preference, phase: controller.phase,
                              lastUpdate: controller.lastUpdate, canGoBack: controller.canGoBack, now: controller.now)
    }

    private func refreshTitles() {
        let title = UpdateStatus.badge(snapshot).map { "Updates · \($0)" } ?? "Updates"
        parents.forEach { $0.title = title }
    }

    private func item(for row: UpdateMenuRow) -> NSMenuItem {
        func command(_ title: String, _ action: Selector, enabled: Bool = true) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            return item
        }
        switch row {
        case .separator: return .separator()
        case .status(let text):
            let item = NSMenuItem()
            item.view = Self.statusView(text)
            item.isEnabled = false
            return item
        case .automatic(let isOn):
            let item = command("Update Automatically", #selector(toggleAutomatic))
            item.state = isOn ? .on : .off
            return item
        case .check(let enabled): return command("Check for Updates Now", #selector(checkNow), enabled: enabled)
        case .install(let title): return command(title, #selector(installNow))
        case .whatsNew(let title): return command(title, #selector(whatsNew))
        case .goBack(let title): return command(title, #selector(goBack))
        case .getRelease: return command("Get the Self-Updating Release…", #selector(getRelease))
        }
    }

    /// The status sentence wraps inside the menu; it is never cut short.
    static func statusView(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .menuFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 280
        label.setAccessibilityLabel(text)
        let size = label.sizeThatFits(NSSize(width: 280, height: CGFloat.greatestFiniteMagnitude))
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 316, height: ceil(size.height) + 10))
        label.frame = NSRect(x: 18, y: 5, width: 280, height: ceil(size.height))
        view.addSubview(label)
        return view
    }

    private func ask() {
        guard consent == nil else { return }
        let panel = UpdateConsentPanel { [weak self] preference in
            self?.consent = nil
            self?.controller.choose(preference)
            self?.controller.tick()
        }
        consent = panel
        panel.present()
    }

    @discardableResult
    private func show(_ title: String, _ text: String, buttons: [String] = ["OK"]) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        buttons.forEach { alert.addButton(withTitle: $0) }
        NSApplication.shared.activate(ignoringOtherApps: true)
        return alert.runModal()
    }

    @objc private func toggleAutomatic() {
        consent?.close()
        consent = nil
        controller.choose(controller.preference == .automatic ? .manual : .automatic)
        controller.tick()
    }

    @objc private func checkNow() {
        consent?.close()
        consent = nil
        if controller.preference == .unasked { controller.choose(.manual) }
        Task { [weak self] in
            guard let self else { return }
            self.report(await self.controller.check())
        }
    }

    private func report(_ phase: UpdatePhase) {
        switch phase {
        case .ready(let staged):
            let answer = show("ClipEdge \(staged.release.version) is ready",
                              "ClipEdge saves your clipboard history, closes for a moment and reopens as the new version. The version you have now goes to the Trash; Updates → Go Back returns it.",
                              buttons: ["Install and Reopen", "Later"])
            if answer == .alertFirstButtonReturn { installNow() }
        case .resting(.current):
            show("ClipEdge \(controller.runningVersion) is the newest version", "There is nothing to install.")
        case .resting(.failed(_, let failure)):
            show("ClipEdge couldn't check for updates", UpdateStatus.message(for: failure))
        case .resting(nil), .checking, .downloading:
            break
        }
    }

    @objc private func installNow() {
        guard let failure = controller.installNow() else { return }
        show("ClipEdge was not updated", UpdateStatus.message(for: failure))
    }

    @objc private func whatsNew() {
        if let page = controller.lastUpdate?.page { NSWorkspace.shared.open(page) }
    }

    @objc private func getRelease() {
        NSWorkspace.shared.open(Self.releasePage)
    }

    @objc private func goBack() {
        guard let record = controller.lastUpdate else { return }
        let answer = show("Go back to ClipEdge \(record.from)?",
                          "ClipEdge \(record.to) moves to the Trash and ClipEdge \(record.from) reopens. Automatic updates turn off, so it stays until you turn them on again in this menu.",
                          buttons: ["Go Back", "Cancel"])
        guard answer == .alertFirstButtonReturn, let failure = controller.goBack() else { return }
        show("ClipEdge \(record.to) is still installed", UpdateStatus.message(for: failure))
    }
}
