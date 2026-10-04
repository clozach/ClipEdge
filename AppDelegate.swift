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
    private var historyController: ClipboardHistoryController!
    private let loginItemController = LoginItemController()
    private let revealSettings = ClipboardRevealSettings()
    private lazy var settingsController = ClipboardRevealSettingsController(settings: revealSettings)
    private var updateController: UpdateController!
    private var updateMenu: UpdateMenu!

    func applicationDidFinishLaunching(_ notification: Notification) {
        clipboardStore = ClipboardStore()
        let settings = revealSettings
        let recall = ClipboardRecallMemory(minutes: { settings.recallMinutes })
        drawerController = ClipboardDrawerController(store: clipboardStore, recall: recall,
                                                     activate: { NSApplication.shared.activate(ignoringOtherApps: true) })
        edgeController = EdgeController(drawerController: drawerController, settings: revealSettings)
        drawerController.onRevealSettings = { [weak self] in self?.settingsController.show() }
        drawerController.revealSettingsWindow = settingsController.window
        historyController = ClipboardHistoryController(store: clipboardStore, paster: drawerController.paster,
                                                       previewService: drawerController.previewService, recall: recall)
        historyController.onError = { error in
            let alert = NSAlert()
            alert.messageText = "ClipEdge"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        historyController.prepare = { [weak self] in self?.pasteTarget() }
        updateController = UpdateController(environment: .live(
            support: UpdateController.Environment.defaultSupport,
            isBusy: { [weak self] in self?.isInUse ?? true },
            saveBeforeQuit: { [weak self] in self?.clipboardStore.prepareForTermination() ?? false },
            quit: { NSApplication.shared.terminate(nil) }))
        updateMenu = UpdateMenu(controller: updateController)
        configureMainMenu()
        configureStatusItem()
        hotKey.onPress = { [weak self] in
            guard let self, !self.settingsController.isRecordingShortcut else { return }
            self.drawerController.quickLookNext()
        }
        settingsController.onShortcutChange = { [weak self] shortcut in self?.hotKey.register(shortcut: shortcut) ?? -1 }
        NotificationCenter.default.addObserver(self, selector: #selector(refreshShortcutHints), name: ClipboardRevealSettings.didChange, object: revealSettings)
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
        plainPasteHotKey.onPress = { [weak self] in self?.pasteTopAsPlainText() }
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

        clipboardStore.start()
        edgeController.start()
        updateController.start()

        DispatchQueue.main.async {
            if !CommandLine.arguments.contains("--no-permission-prompt") { PasteMonitor.requestPermissionIfNeeded() }
        }
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

        let quitItem = NSMenuItem(title: "Save History & Quit ClipEdge", action: #selector(quit), keyEquivalent: "q")
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

        let saveItem = NSMenuItem(title: "Save History Now", action: #selector(saveHistory), keyEquivalent: "")
        saveItem.target = self
        menu.addItem(saveItem)
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

        let quitItem = NSMenuItem(title: "Save History & Quit ClipEdge", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    @objc private func showClipboard() {
        if drawerController.isVisible {
            drawerController.hide(animated: true)
        } else {
            drawerController.showAtTab()
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

    @objc private func clearHistory() {
        drawerController.confirmClear()
    }

    @objc private func configurePasteDetection() {
        PasteMonitor.configurePermissions()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
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
