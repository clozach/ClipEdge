import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var clipboardStore: ClipboardStore!
    private var drawerController: ClipboardDrawerController!
    private var edgeController: EdgeController!
    private var statusItem: NSStatusItem!
    private let hotKey = ClipboardHotKey()
    private let historyHotKey = ClipboardHotKey()
    private let plainPasteHotKey = ClipboardHotKey()
    private let drawerHotKey = ClipboardHotKey()
    private var historyController: ClipboardHistoryController!
    private let loginItemController = LoginItemController()
    private let revealSettings = ClipboardRevealSettings()
    private lazy var settingsController = ClipboardRevealSettingsController(settings: revealSettings)
    private var updateController: UpdateController!
    private var updateMenu: UpdateMenu!
    private var publisher: PublishController!
    private var sampleMenu: ClipboardSampleHistoryMenu!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let source = ClipboardHistorySource.saved()
        clipboardStore = ClipboardStore(pasteboard: .general, persistenceURL: source.url())
        sampleMenu = ClipboardSampleHistoryMenu(store: clipboardStore, source: source)
        drawerController = ClipboardDrawerController(store: clipboardStore, activate: { NSApplication.shared.activate(ignoringOtherApps: true) })
        drawerController.motionProfiles = { [revealSettings] in revealSettings.drawerMotion(for: $0) }
        drawerController.sizes = { [revealSettings] in revealSettings.sizes }
        edgeController = EdgeController(drawerController: drawerController, settings: revealSettings)
        drawerController.onRevealSettings = { [weak self] in self?.settingsController.show() }
        settingsController.onClose = { [weak self] in self?.drawerController.settingsDidClose() }
        drawerController.applyAvailability(revealSettings.drawerAvailability)
        drawerController.onVisibilityChange = { [weak self] in self?.refreshDrawerMenuItems() }
        historyController = ClipboardHistoryController(store: clipboardStore, paster: drawerController.paster,
                                                       previewService: drawerController.previewService)
        let magnets = revealSettings
        clipboardStore.attachesCopiesToCursor = { magnets.showsMagnet(for: .copy) }
        drawerController.pickupMagnet = { magnets.showsMagnet(for: .drawer) }
        historyController.pickupMagnet = { magnets.showsMagnet(for: .window) }
        historyController.prepare = { [weak self] in self?.pasteTarget() }
        historyController.sizes = { magnets.sizes }
        drawerController.magnetController.previewScale = { magnets.sizes.previewScale }
        ClipboardTileTooltip.shared.textScale = { magnets.sizes.textScale }
        drawerController.magnetController.textScale = { magnets.sizes.textScale }
        updateController = UpdateController(environment: .live(
            support: UpdateController.Environment.defaultSupport,
            isBusy: { [weak self] in self?.isInUse ?? true },
            saveBeforeQuit: { [weak self] in self?.clipboardStore.prepareForTermination() ?? false },
            quit: { NSApplication.shared.terminate(nil) }))
        updateMenu = UpdateMenu(controller: updateController)
        configurePublishing()
        configureMainMenu()
        configureStatusItem()
        hotKey.onPress = { [weak self] in
            guard let self, !self.settingsController.isRecordingShortcut else { return }
            self.drawerController.quickLookNext()
        }
        settingsController.onShortcutChange = { [weak self] shortcut in self?.hotKey.register(shortcut: shortcut) ?? -1 }
        settingsController.onDrawerShortcutChange = { [weak self] shortcut in
            guard let self else { return -1 }
            let status = self.drawerHotKey.register(shortcut: shortcut)
            if !self.revealSettings.drawerAvailability.drawerEnabled { self.drawerHotKey.unregister() }
            return status
        }
        settingsController.onRecordingChange = { [weak self] recording in self?.setShortcutRecording(recording) }
        NotificationCenter.default.addObserver(self, selector: #selector(refreshShortcutHints), name: ClipboardRevealSettings.didChange, object: revealSettings)
        NotificationCenter.default.addObserver(self, selector: #selector(releaseMagnetsTurnedOff), name: ClipboardRevealSettings.didChange, object: revealSettings)
        NotificationCenter.default.addObserver(self, selector: #selector(applyDrawerSettings), name: ClipboardRevealSettings.didChange, object: revealSettings)
        refreshShortcutHints()
        let hotKeyStatus = hotKey.register(shortcut: revealSettings.quickLookShortcut)
        if hotKeyStatus != noErr {
            let alert = NSAlert()
            alert.messageText = "Quick Look shortcut is unavailable"
            alert.informativeText = "Another app may already use \(revealSettings.quickLookShortcut.displayString). Choose a different combination in ClipEdge Settings. The menu still has Quick Look Next Item. Registration status: \(hotKeyStatus)."
            alert.runModal()
        }
        historyHotKey.onPress = { [weak self] in
            guard let self, !self.settingsController.isRecordingShortcut else { return }
            self.historyController.hotKeyPressed()
        }
        plainPasteHotKey.onPress = { [weak self] in
            guard let self, !self.settingsController.isRecordingShortcut else { return }
            self.pasteTopAsPlainText()
        }
        let unavailable = [(ClipboardShortcut.history, historyHotKey, "Clipboard History"),
                           (ClipboardShortcut.plainPaste, plainPasteHotKey, "Paste Top Item as Plain Text")]
            .filter { $0.1.register(shortcut: $0.0) != noErr }
        if !unavailable.isEmpty {
            let alert = NSAlert()
            alert.messageText = "A ClipEdge shortcut is unavailable"
            alert.informativeText = unavailable.map { "\($0.2) ← \($0.0.displayString)" }.joined(separator: "\n") +
                "\nAnother app may already use it. The ClipEdge menu bar item still offers both commands."
            alert.runModal()
        }
        drawerHotKey.onPress = { [weak self] in
            guard let self, !self.settingsController.isRecordingShortcut else { return }
            self.showClipboard()
        }
        applyDrawerSettings()

        clipboardStore.start()
        edgeController.start()
        updateController.start()
        publisher.start()

        DispatchQueue.main.async {
            if !CommandLine.arguments.contains("--no-permission-prompt") { PasteMonitor.requestPermissionIfNeeded() }
        }
    }

    @MainActor private func configurePublishing() {
        publisher = PublishController.shared
        let controls = [drawerController.header.publishControl, historyController.view.publishControl]
        for control in controls {
            publisher.observe(owner: control) { [weak control] in control?.apply($0) }
            control.onPress = { [weak self, weak control] in self?.publisher.performAction(presenting: control?.window) }
        }
        drawerController.onShow = { [weak self] in self?.publisher.refresh() }
        historyController.onShow = { [weak self] in self?.publisher.refresh() }
        // The same maintainer build that can publish can ask for a better preview:
        // its brief goes into the vault the publisher tool lives in, and nowhere else.
        let asker = PublishCapability.resolve(info: Bundle.main.infoDictionary ?? [:])
            .flatMap { ClipboardPreviewBriefVault(publisherTool: $0.tool) }
            .map { ClipboardPreviewAsker(vault: $0) }
        drawerController.previewAsker = asker
        historyController.previewAsker = asker
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboardStore.stop()
        edgeController.stop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !clipboardStore.prepareForTermination() else { return .terminateNow }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "ClipEdge couldn't save its history"
        alert.informativeText = "Keep ClipEdge running to preserve the in-memory history, or quit without saving it."
        alert.addButton(withTitle: "Keep ClipEdge Running")
        alert.addButton(withTitle: "Quit Without Saving")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !drawerController.isVisible {
            showClipboard()
        }
        return true
    }

    @MainActor private func configureMainMenu() {
        let mainMenu = NSMenu(title: "Main Menu")
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "ClipEdge")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let showItem = NSMenuItem(title: "Show Clipboard", action: #selector(showClipboard), keyEquivalent: "")
        showItem.target = self
        appMenu.addItem(showItem)
        appMenu.addItem(settingsController.makeMenuItem(keyEquivalent: ","))

        let saveItem = NSMenuItem(title: "Save History Now", action: #selector(saveHistory), keyEquivalent: "s")
        saveItem.keyEquivalentModifierMask = [.command, .option]
        saveItem.target = self
        appMenu.addItem(saveItem)
        appMenu.addItem(.separator())

        appMenu.addItem(loginItemController.makeMenuItem())
        let pasteDetectionItem = NSMenuItem(title: "Enable Paste Detection…", action: #selector(configurePasteDetection), keyEquivalent: "")
        pasteDetectionItem.target = self
        appMenu.addItem(pasteDetectionItem)
        appMenu.addItem(updateMenu.makeMenuItem())
        appMenu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit ClipEdge", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)
        NSApplication.shared.mainMenu = mainMenu
    }

    @MainActor private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = ClipboardIcons.symbol("list.clipboard", description: "ClipEdge")
            button.toolTip = "ClipEdge"
        }

        let menu = NSMenu()
        // Shown only while the sample history is: the way back is never hidden.
        menu.addItem(sampleMenu.banner)
        let showItem = NSMenuItem(title: "Show Clipboard", action: #selector(showClipboard), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
        menu.addItem(settingsController.makeMenuItem())
        let historyItem = NSMenuItem(title: "Clipboard History  \(ClipboardShortcut.history.displayString)", action: #selector(showHistory), keyEquivalent: "")
        historyItem.target = self
        menu.addItem(historyItem)
        let plainItem = NSMenuItem(title: "Paste Top Item as Plain Text  \(ClipboardShortcut.plainPaste.displayString)", action: #selector(pasteTopAsPlainText), keyEquivalent: "")
        plainItem.target = self
        menu.addItem(plainItem)
        let quickLookItem = NSMenuItem(title: "Quick Look Next Item  ⌃⌥Space", action: #selector(quickLookNext), keyEquivalent: "")
        quickLookItem.target = self
        menu.addItem(quickLookItem)

        let clearItem = NSMenuItem(title: "Clear History", action: #selector(clearHistory), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)
        // The easter egg: holding Option turns Clear History and Save History Now into these two.
        menu.addItem(sampleMenu.addItem)

        let saveItem = NSMenuItem(title: "Save History Now", action: #selector(saveHistory), keyEquivalent: "")
        saveItem.target = self
        menu.addItem(saveItem)
        menu.addItem(sampleMenu.toggleItem)
        menu.addItem(.separator())

        menu.addItem(loginItemController.makeMenuItem())
        let pasteDetectionItem = NSMenuItem(title: "Enable Paste Detection…", action: #selector(configurePasteDetection), keyEquivalent: "")
        pasteDetectionItem.target = self
        menu.addItem(pasteDetectionItem)
        menu.addItem(updateMenu.makeMenuItem())
        menu.addItem(.separator())

        let hint = NSMenuItem(title: "Reveal mode in Settings · Drag tab to move", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit ClipEdge", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
        sampleMenu.attach(to: statusItem)
    }

    @objc private func showClipboard() {
        guard revealSettings.drawerAvailability.drawerEnabled else { return }
        if !drawerController.isVisible { historyController.close() }
        drawerController.toggleFromCommand()
    }

    @objc private func applyDrawerSettings() {
        drawerController.applyAvailability(revealSettings.drawerAvailability)
        // Sizes: the drawer and the window follow at once; Quick Look reads the preview size as it opens.
        drawerController.applySizes()
        historyController.applySizes()
        if revealSettings.drawerAvailability.drawerEnabled {
            let status = drawerHotKey.register(shortcut: revealSettings.drawerShortcut)
            if status != noErr {
                let alert = NSAlert()
                alert.messageText = "Show / Hide Clipboard shortcut is unavailable"
                alert.informativeText = "Another app may already use \(revealSettings.drawerShortcut.displayString). Choose a different combination in ClipEdge Settings. The menu still offers Show Clipboard. Registration status: \(status)."
                alert.runModal()
            }
        } else { drawerHotKey.unregister() }
        refreshDrawerMenuItems()
    }

    /// Registered global chords consume their keys before a recorder can see them.
    /// Release all four only for the recording interval; restore accepted settings
    /// on completion, Escape, focus loss or closing Settings.
    private func setShortcutRecording(_ recording: Bool) {
        if recording {
            for key in [hotKey, historyHotKey, plainPasteHotKey, drawerHotKey] { key.unregister() }
            return
        }
        var commands = [(hotKey, revealSettings.quickLookShortcut, "Quick Look"),
                        (historyHotKey, ClipboardShortcut.history, "Clipboard History"),
                        (plainPasteHotKey, ClipboardShortcut.plainPaste, "Paste Top Item as Plain Text")]
        if revealSettings.drawerAvailability.drawerEnabled {
            commands.append((drawerHotKey, revealSettings.drawerShortcut, "Show / Hide Clipboard"))
        }
        let unavailable = commands.filter { $0.0.register(shortcut: $0.1) != noErr }
        if !unavailable.isEmpty {
            let alert = NSAlert()
            alert.messageText = "A ClipEdge shortcut is unavailable"
            alert.informativeText = unavailable.map { "\($0.2) ← \($0.1.displayString)" }.joined(separator: "\n") +
                "\nAnother app may now use it. ClipEdge's menu still offers these commands."
            alert.runModal()
        }
    }

    /// Both Show Clipboard items read Hide while the drawer is open, however it opened.
    static func drawerMenuTitle(drawerVisible: Bool, shortcut: ClipboardShortcut) -> String {
        "\(drawerVisible ? "Hide" : "Show") Clipboard  \(shortcut.displayString)"
    }

    private func refreshDrawerMenuItems() {
        let title = Self.drawerMenuTitle(drawerVisible: drawerController.isVisible, shortcut: revealSettings.drawerShortcut)
        for menu in [NSApplication.shared.mainMenu?.items.first?.submenu, statusItem?.menu] {
            if let item = menu?.items.first(where: { $0.action == #selector(showClipboard) }) {
                item.title = title
                item.isEnabled = revealSettings.drawerAvailability.drawerEnabled
            }
        }
    }

    /// An update waits while anything of ClipEdge's is open or held.
    private var isInUse: Bool {
        clipboardStore.stagedEntryID != nil || drawerController.isVisible || historyController.isVisible
            || settingsController.window?.isVisible == true
    }

    @objc private func quickLookNext() { drawerController.quickLookNext() }
    @objc private func showHistory() { if !historyController.isVisible { historyController.show() } }

    /// Where Return and ⌃⌘V paste: the app in front, or the one the open drawer covers.
    private func pasteTarget() -> ClipboardPaster.Target? {
        let covered = drawerController.previousApplication
        drawerController.hide(animated: false)
        return ClipboardPaster.frontmostTarget() ?? covered.map(ClipboardPaster.target(for:))
    }

    /// ⌃⌘V, with or without any ClipEdge window showing.
    @objc private func pasteTopAsPlainText() {
        historyController.close()
        drawerController.paster.pasteClipboardAsPlainText(into: pasteTarget())
    }
    @objc private func refreshShortcutHints() {
        let shortcut = revealSettings.quickLookShortcut.displayString
        drawerController.browser.quickLookHint = shortcut
        drawerController.magnetController.quickLookHint = shortcut
        statusItem.menu?.items.first(where: { $0.action == #selector(quickLookNext) })?.title = "Quick Look Next Item  \(shortcut)"
    }

    @objc private func releaseMagnetsTurnedOff() {
        let magnets = revealSettings
        drawerController.releaseMagnet { magnets.showsMagnet(for: $0) }
    }

    @objc private func clearHistory() {
        drawerController.confirmClear()
    }

    @objc private func configurePasteDetection() {
        PasteMonitor.configurePermissions()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(showClipboard) { return revealSettings.drawerAvailability.drawerEnabled }
        if menuItem.action == #selector(configurePasteDetection) {
            // Read the running build's actual access, rather than assuming a
            // previously accepted prompt still applies after a local rebuild.
            menuItem.title = AXIsProcessTrusted() ? "Paste Detection: Access Enabled…" : "Enable Paste Detection…"
        }
        return true
    }

    @objc private func saveHistory() {
        guard !clipboardStore.saveNow() else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "ClipEdge couldn't save its history"
        alert.informativeText = "The in-memory history is still available while ClipEdge remains open."
        alert.runModal()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
