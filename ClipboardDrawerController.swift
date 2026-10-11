import AppKit

final class ClipboardDrawerController: NSObject {
    private let store: ClipboardStore
    private let panel: NSPanel
    let browser = ClipboardBrowserView()
    let header = ClipboardDrawerHeader()
    let previewService = ClipboardPreviewService()
    let paster: ClipboardPaster
    let sendToPopover: ClipboardSendToPopover
    private var isConfirmingDeletion = false
    let magnetController: ClipboardMagnetController
    private var targetScreen: NSScreen?
    private var pasteLocation: NSPoint?
    private let glass = ClipboardGlassView(frame: .zero)
    private let defaults: UserDefaults?
    private static let placementKey = "ClipEdgeTabPlacement"
    private(set) var tabPlacement: ClipboardTabPlacement
    private var dockLayout: ClipboardDockLayout?
    private var expanded = false
    private var keyMonitor: Any?
    private let activate: () -> Void
    /// The app to return to, and to paste into, while the drawer holds focus.
    private(set) var previousApplication: NSRunningApplication?
    private var interactionPlacement = ClipboardTabPlacement()
    private var interactionOffset = NSPoint.zero
    private var interactionWallOffset = NSPoint.zero

    var isVisible: Bool { panel.isVisible && expanded }
    weak var revealSettingsWindow: NSWindow?
    var allowsAutomaticHiding: Bool {
        !isConfirmingDeletion && !sendToPopover.isVisible && revealSettingsWindow?.isVisible != true &&
        !(panel.isKeyWindow && panel.firstResponder === browser.search.currentEditor())
    }
    var onRevealSettings: (() -> Void)?
    var onShow: (() -> Void)?
    var sendSources = ClipboardSendTo.Sources()
    var isInteractingWithTab: Bool { glass.tabControl.isInteracting }
    var tabFrame: NSRect? { expanded ? dockLayout?.expandedTabFrame : dockLayout?.tabFrame }
    var bodyFrame: NSRect? { isVisible ? dockLayout?.bodyFrame : nil }
    var screenFrame: NSRect? { targetScreen?.frame }
    private var previewAnchor: ClipboardDrawerPreviewAnchor? {
        guard isVisible, let layout = dockLayout, let screen = targetScreen else { return nil }
        return ClipboardDrawerPreviewAnchor(drawer: layout.expandedFrame, screen: screen.visibleFrame, edge: tabPlacement.edge)
    }

    init(store: ClipboardStore, magnetController: ClipboardMagnetController = ClipboardMagnetController(),
         panel suppliedPanel: NSPanel? = nil, defaults: UserDefaults? = .standard,
         paster: ClipboardPaster? = nil, sendToPopover: ClipboardSendToPopover = ClipboardSendToPopover(),
         activate: @escaping () -> Void = {}) {
        self.store = store
        self.magnetController = magnetController
        self.paster = paster ?? ClipboardPaster(store: store)
        self.sendToPopover = sendToPopover
        self.defaults = defaults
        self.activate = activate
        tabPlacement = defaults?.data(forKey: Self.placementKey)
            .flatMap { try? JSONDecoder().decode(ClipboardTabPlacement.self, from: $0) } ?? ClipboardTabPlacement()
        panel = suppliedPanel ?? ClipboardWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 700),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        super.init()
        configurePanel()
        configureContent()
        configureTab()

        store.onChange = { [weak self] in
            self?.reload()
        }
        store.onStagingChange = { [weak self] change in
            self?.stagingChanged(change)
        }
        store.onPasteCommitted = { [weak self] in
            guard let self, self.store.entries.indices.contains(0) else { return }
            self.browser.reveal(self.store.entries[0].id)
        }
        // A copy made elsewhere replaces whatever was previewed, and the store drops the preview
        // right after this: only the carousel resets. Handing it to the pointer, or closing it
        // with drawer magnets off, would put the previous clipboard back over the new copy.
        store.onExternalCopy = { [weak self] in self?.store.resetCycle() }
        store.onRemove = { [weak self] entry in
            guard let self else { return }
            do { try self.previewService.materializer.remove(entry) } catch { self.showError(error) }
        }
        magnetController.onCancel = { [weak self] in
            self?.dismissAttachment()
        }
        magnetController.onPaste = { [weak self] point in
            self?.pasteLocation = point
            self?.store.commitStagedPaste()
        }
        magnetController.onDrop = { [weak self] in self?.store.dropStaging() }
        magnetController.onNavigate = { [weak self] direction in self?.movePreview(direction) }
        reload()
    }

    func show(on screen: NSScreen, animated _: Bool = true) {
        onShow?()
        if !expanded {
            previousApplication = NSWorkspace.shared.frontmostApplication
            if previousApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier { previousApplication = nil }
            // Cleared as it opens, not as it closes, so nothing moves while the drawer is open.
            browser.startFresh()
            // The search's typing from before the close would undo against the cleared text
            // and throw; the drawer's own window holds it, as the collapsed browser has none.
            panel.undoManager?.removeAllActions()
        }
        targetScreen = screen
        expanded = true
        applyDockLayout()
        activate()
        panel.makeKey()
        panel.makeFirstResponder(browser.canvas)
        refreshQuickLookPlacement()
    }

    func hide(animated _: Bool) {
        guard expanded else { return }
        expanded = false
        sendToPopover.close()
        ClipboardTileTooltip.shared.hide()
        panel.resignKey()
        if NSApplication.shared.isActive { previousApplication?.activate(options: []) }
        previousApplication = nil
        applyDockLayout()
        refreshQuickLookPlacement()
    }

    func contains(_ screenPoint: NSPoint) -> Bool {
        tabContains(screenPoint) || (isVisible && (dockLayout?.bodyFrame.contains(screenPoint) == true ||
            magnetController.drawerAnchor?.contains(screenPoint) == true ||
            (sendToPopover.isVisible && sendToPopover.frame.contains(screenPoint))))
    }

    func tabContains(_ point: NSPoint) -> Bool {
        guard panel.isVisible, let frame = tabFrame else { return false }
        return NSBezierPath(roundedRect: frame, xRadius: 14, yRadius: 14).contains(point)
    }

    func showCollapsedTab(on screen: NSScreen) {
        if expanded { hide(animated: false) }
        targetScreen = screen
        expanded = false
        applyDockLayout()
    }

    func showAtTab() {
        guard !isInteractingWithTab else { return }
        show(on: targetScreen ?? preferredScreen())
    }

    func preferredScreen() -> NSScreen {
        NSScreen.screens.first { Self.screenID($0) == tabPlacement.screenID } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    func refreshScreenGeometry() {
        targetScreen = preferredScreen()
        applyDockLayout()
    }

    func stop() { hide(animated: false); magnetController.hide(); ClipboardTileTooltip.shared.hide(); previewService.materializer.removeAll(); panel.orderOut(nil) }
    deinit { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }

    private static func screenID(_ screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func applyDockLayout() {
        guard let screen = targetScreen else { return }
        let geometry = ClipboardTabGeometry.layout(placement: tabPlacement, in: screen.visibleFrame)
        // Align the drawer and its attached tab with NSWindow's point grid.
        func aligned(_ rect: NSRect) -> NSRect {
            NSRect(x: floor(rect.minX), y: floor(rect.minY), width: floor(rect.width), height: floor(rect.height))
        }
        let layout = ClipboardDockLayout(tabFrame: aligned(geometry.tabFrame), bodyFrame: aligned(geometry.bodyFrame),
                                         expandedTabFrame: aligned(geometry.expandedTabFrame))
        dockLayout = layout
        let frame = expanded ? layout.expandedFrame : layout.tabFrame
        panel.setFrame(frame, display: false)
        glass.frame = NSRect(origin: .zero, size: frame.size)
        glass.updateLayout(bodyRect: expanded ? layout.bodyFrame.offsetBy(dx: -frame.minX, dy: -frame.minY) : nil,
                           tabRect: (expanded ? layout.expandedTabFrame : layout.tabFrame).offsetBy(dx: -frame.minX, dy: -frame.minY), edge: tabPlacement.edge)
        glass.layoutSubtreeIfNeeded()
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        if let anchor = previewAnchor { magnetController.updateDrawerAnchor(anchor) }
    }

    private func configureTab() {
        // EdgeController owns hover timing, including delayed and click modes.
        glass.tabControl.onClick = { [weak self] in self?.showAtTab() }
        glass.tabControl.onSettings = { [weak self] in self?.onRevealSettings?() }
        glass.tabControl.onInteractionBegan = { [weak self] pointer in
            guard let self else { return }
            if self.magnetController.drawerAnchor == nil { self.resetPreviewCycle() }
            self.interactionPlacement = self.tabPlacement
            let tab = self.tabFrame ?? .zero
            self.interactionOffset = NSPoint(x: tab.midX - pointer.x, y: tab.midY - pointer.y)
            let resting = self.dockLayout?.tabFrame ?? tab
            self.interactionWallOffset = NSPoint(x: resting.midX - tab.midX, y: resting.midY - tab.midY)
        }
        glass.tabControl.onDrag = { [weak self] point in self?.moveTab(to: point) }
        glass.tabControl.onResize = { [weak self] delta in self?.resizeTab(by: delta) }
        glass.tabControl.onInteractionEnded = { [weak self] in
            guard let self, let data = try? JSONEncoder().encode(self.tabPlacement) else { return }
            self.defaults?.set(data, forKey: Self.placementKey)
        }
    }

    private func moveTab(to pointer: NSPoint) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? targetScreen else { return }
        var placement = ClipboardTabGeometry.moved(tabPlacement, to: pointer, in: screen.visibleFrame, wallOffset: interactionWallOffset)
        let centerPoint = NSPoint(x: pointer.x + interactionOffset.x, y: pointer.y + interactionOffset.y)
        // Keep the grab point stable along an edge; on rotation, use the new
        // tab's center so a long vertical offset cannot push a top tab sideways.
        let position = placement.edge == interactionPlacement.edge ? centerPoint : pointer
        let axisStart = placement.edge == .top ? screen.visibleFrame.minX : screen.visibleFrame.minY
        let axisLength = placement.edge == .top ? screen.visibleFrame.width : screen.visibleFrame.height
        let coordinate = placement.edge == .top ? position.x : position.y
        placement.center = Double((coordinate - axisStart - 8) / max(1, axisLength - 16))
        placement.screenID = Self.screenID(screen)
        tabPlacement = ClipboardTabGeometry.resized(placement, by: 0, in: screen.visibleFrame)
        targetScreen = screen
        applyDockLayout()
    }

    private func resizeTab(by delta: CGFloat) {
        guard let screen = targetScreen else { return }
        tabPlacement = ClipboardTabGeometry.resized(interactionPlacement, by: delta, in: screen.visibleFrame)
        tabPlacement.screenID = Self.screenID(screen)
        // Keep the body open while resizing: the tab's center and the glass
        // join stay fixed, and the handles remain under the pointer.
        applyDockLayout()
    }

    private func stagingChanged(_ change: ClipboardStagingChange) {
        switch change {
        case .pickedUp(let entry):
            ClipboardTileTooltip.shared.hide()
            let source = slotFrame(for: entry.id)
            reload()
            if let position = store.carouselPosition {
                do {
                    let urls = try previewService.materializer.urls(for: entry)
                    magnetController.showCarousel(entry: entry, urls: urls, position: position.index, count: position.count, anchor: previewAnchor)
                } catch { store.cancelStaging(); showError(error) }
            } else { magnetController.show(entry: entry, from: source) }
        case .cancelled(let entry):
            magnetController.returnToSlot(slotFrame(for: entry.id)) {}
            reload()
        case .pasted:
            magnetController.consume(at: pasteLocation ?? NSEvent.mouseLocation)
            pasteLocation = nil
            reload()
        case .invalidated:
            pasteLocation = nil
            magnetController.hide()
            reload()
        }
    }

    private func slotFrame(for id: UUID) -> NSRect? {
        isVisible ? browser.screenFrame(for: id) : nil
    }

    private func configurePanel() {
        panel.title = "ClipEdge"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleDrawerKey(event) == true ? nil : event
        }
    }

    /// Shared with fixture tests; no system input is synthesized.
    func handleDrawerKey(_ event: NSEvent) -> Bool {
        guard isVisible, panel.isKeyWindow else { return false }
        if header.publishControl.handleKey(event) { return true }
        guard !(panel.firstResponder is NSTextView),
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
        if event.keyCode == 49, let entry = browser.canvas.selected?.entry {
            if !event.isARepeat { togglePreview(entry) }
            return true
        }
        if magnetController.isQuickLook, store.carouselPosition != nil, (123...126).contains(event.keyCode) {
            movePreview(event.keyCode == 123 || event.keyCode == 126 ? -1 : 1)
            return true
        }
        return false
    }

    private func configureContent() {
        panel.contentView = glass
        header.install(above: browser, in: glass.bodyContent)
        header.onSettings = { [weak self] in self?.onRevealSettings?() }
        browser.clear.nextKeyView = header.settingsButton
        header.publishControl.onVisibilityChange = { [weak self] in self?.refreshHeaderKeyLoop() }
        refreshHeaderKeyLoop()
        browser.onInteraction = { [weak self] in self?.resetPreviewCycle() }
        browser.onVisibleEntriesChange = { [weak self] in self?.refreshQuickLookPlacement() }
        browser.onHover = { [weak self] entry in
            guard let self, self.isVisible, self.magnetController.drawerAnchor != nil,
                  self.store.carouselPosition != nil, self.store.stagedEntryID != entry.id else { return }
            self.store.previewInCarousel(entry, among: self.browser.visibleEntries)
        }
        browser.onClear = { [weak self] in self?.confirmClear() }
        browser.canvas.onPick = { [weak self] entry in self?.resetPreviewCycle(); self?.pick(entry) }
        browser.canvas.onPreview = { [weak self] entry in self?.togglePreview(entry) }
        browser.canvas.onDelete = { [weak self] entry in self?.confirmDelete(entry) }
        browser.canvas.onOpen = { [weak self] entry in self?.openInPreview(entry) }
        browser.canvas.onSendTo = { [weak self] entry in self?.showSendTo(entry) }
        sendToPopover.view.onBack = { [weak self] in self?.sendToPopover.close() }
        sendToPopover.onClose = { [weak self] in
            // Back to the same selected tile, with the keyboard.
            guard let self, self.isVisible else { return }
            self.panel.makeKey()
            self.panel.makeFirstResponder(self.browser.canvas)
        }
        browser.canvas.onEscape = { [weak self] in self?.dismissAttachment() }
        // A card's info opens where Send to does: beside the drawer, level with the card.
        ClipboardTileTooltip.shared.besideDrawer = { [weak self] card, size in
            self?.previewAnchor?.frame(fitting: size, centeredAtY: card.midY)
        }
        ClipboardTileTooltip.shared.isRoomTaken = { [weak self] in
            guard let self else { return false }
            return self.magnetController.drawerAnchor != nil || self.sendToPopover.isVisible
        }
    }

    private func refreshHeaderKeyLoop() {
        if header.publishControl.isHidden, panel.firstResponder === header.publishControl {
            panel.makeFirstResponder(header.settingsButton)
        }
        header.settingsButton.nextKeyView = header.publishControl.isHidden ? browser.search : header.publishControl
        header.publishControl.nextKeyView = browser.search
    }

    private func reload() {
        browser.update(entries: store.entries, attachedID: store.liftedEntryID)
        if let held = store.entries.first(where: { $0.id == store.stagedEntryID }) { magnetController.refreshSmall(held) }
    }

    /// Tab on a tile: apps that can open it, then running apps to paste into.
    private func showSendTo(_ entry: ClipboardEntry) {
        guard isVisible, let layout = dockLayout, let screen = targetScreen else { return }
        let items = ClipboardSendTo.openItems(for: entry, materializer: previewService.materializer)
        let targets = ClipboardSendTo.targets(opening: items, sources: sendSources)
        guard !targets.isEmpty else { NSSound.beep(); return }
        ClipboardTileTooltip.shared.hide()
        let anchor = ClipboardDrawerPreviewAnchor(drawer: layout.expandedFrame, screen: screen.visibleFrame, edge: tabPlacement.edge)
        let rowY = browser.screenFrame(for: entry.id)?.midY
        sendToPopover.view.onSend = { [weak self] target in self?.send(entry, to: target) }
        sendToPopover.show(targets) { anchor.frame(fitting: $0, centeredAtY: rowY) }
    }

    private func send(_ entry: ClipboardEntry, to target: ClipboardSendTarget) {
        // Pasting into the app the drawer covered needs that app in front first.
        hide(animated: true)
        ClipboardSendTo.send(entry, to: target, paster: paster, sources: sendSources) { [weak self] error in self?.showError(error) }
    }

    private func togglePreview(_ entry: ClipboardEntry) {
        if magnetController.isQuickLook, store.stagedEntryID == entry.id { store.cancelStaging() }
        else { store.previewInCarousel(entry, among: isVisible ? browser.visibleEntries : nil) }
    }

    func quickLookNext() {
        if isVisible {
            if magnetController.isQuickLook, store.carouselPosition != nil { movePreview(1) }
            else if let entry = browser.canvas.selected?.entry { store.previewInCarousel(entry, among: browser.visibleEntries) }
            else { NSSound.beep() }
            return
        }
        guard store.quickLookNext() != nil else { NSSound.beep(); return }
    }

    private func movePreview(_ direction: Int) {
        guard let entry = store.moveCarousel(direction, among: isVisible ? browser.visibleEntries : nil) else { return }
        if isVisible { browser.reveal(entry.id) }
    }

    private func refreshQuickLookPlacement() {
        guard magnetController.isQuickLook, store.carouselPosition != nil else { return }
        let candidates = isVisible ? browser.visibleEntries : store.entries
        guard let entry = candidates.first(where: { $0.id == store.stagedEntryID }) ?? candidates.first else {
            store.cancelStaging(); return
        }
        store.previewInCarousel(entry, among: candidates)
        if isVisible { browser.reveal(entry.id) }
    }

    private func resetPreviewCycle() {
        store.resetCycle()
        guard magnetController.isQuickLook, let entry = store.entries.first(where: { $0.id == store.stagedEntryID }) else { return }
        // Touching the drawer hands a preview to the pointer; with drawer magnets off it closes instead.
        if pickupMagnet() { magnetController.show(entry: entry, from: nil) } else { store.cancelStaging() }
    }

    /// Settings › Cursor magnets changed: a magnet whose choice is now off lets go.
    /// What it held stays on the clipboard, where a pick without a magnet would leave it.
    func releaseMagnet(unlessShown shows: (ClipboardMagnetSource) -> Bool) {
        guard magnetController.presentation == .small, let source = store.heldMagnetSource, !shows(source) else { return }
        store.dropStaging()
    }

    private func dismissAttachment() {
        store.cancelStaging()
    }

    func confirmClear() {
        confirmRemoval(message: "Delete all clipboard history permanently?", detail: "🚨 This removes saved ClipEdge payloads and preview copies. It cannot be undone. The current clipboard is cleared if ClipEdge holds it.") { [weak self] in
            guard let self else { return }
            self.store.clear()
            if !self.store.saveNow() { self.showError(ClipEdgeError.cannotDelete) }
        }
    }

    private func confirmDelete(_ entry: ClipboardEntry) {
        confirmRemoval(message: "Delete this clipboard item permanently?", detail: "🚨 This removes the item from ClipEdge, its saved history and preview copies. If it is on the clipboard, that is cleared too. Original files stay where they are. This cannot be undone. Press ⌘⌫ again to delete.") { [weak self] in
            guard let self else { return }
            if !self.store.remove(entry) { self.showError(ClipEdgeError.cannotDelete) }
        }
    }

    private func confirmRemoval(message: String, detail: String, perform: () -> Void) {
        resetPreviewCycle()
        isConfirmingDeletion = true
        defer { isConfirmingDeletion = false }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        Self.acceptCommandDelete(alert.addButton(withTitle: "Delete Permanently"))
        if alert.runModal() == .alertSecondButtonReturn { perform() }
    }

    /// A second ⌘⌫ confirms a deletion; Return and Esc still cancel.
    static func acceptCommandDelete(_ button: NSButton) {
        button.keyEquivalent = "\u{7F}"
        button.keyEquivalentModifierMask = .command
    }

    /// Settings › Cursor magnets › From the drawer: with it off, picking a tile just makes it current.
    var pickupMagnet: () -> Bool = { true }

    private func pick(_ entry: ClipboardEntry) {
        if pickupMagnet() { store.selectForPaste(entry, from: .drawer) } else if store.makeCurrent(entry) { browser.reveal(entry.id) }
    }

    private func openInPreview(_ entry: ClipboardEntry) {
        resetPreviewCycle()
        previewService.openInPreview(entry) { [weak self] error in if let error { self?.showError(error) } }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "ClipEdge"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

enum ClipEdgeError: LocalizedError {
    case cannotDelete
    var errorDescription: String? { "ClipEdge could not save the deletion. Keep the app open and try Save History Now again." }
}
