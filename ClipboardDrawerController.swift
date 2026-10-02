import AppKit

final class ClipboardDrawerController: NSObject {
    private let store: ClipboardStore
    private let panel: NSPanel
    let browser = ClipboardBrowserView()
    let header = ClipboardDrawerHeader()
    let previewService = ClipboardPreviewService()
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
    private var previousApplication: NSRunningApplication?
    private var interactionPlacement = ClipboardTabPlacement()
    private var interactionOffset = NSPoint.zero
    private var interactionWallOffset = NSPoint.zero

    var isVisible: Bool { panel.isVisible && expanded }
    weak var revealSettingsWindow: NSWindow?
    var allowsAutomaticHiding: Bool {
        !isConfirmingDeletion && revealSettingsWindow?.isVisible != true &&
        !(panel.isKeyWindow && panel.firstResponder === browser.search.currentEditor())
    }
    var onRevealSettings: (() -> Void)?
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
         activate: @escaping () -> Void = {}) {
        self.store = store
        self.magnetController = magnetController
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
        store.onExternalCopy = { [weak self] in self?.resetPreviewCycle() }
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
        if !expanded {
            previousApplication = NSWorkspace.shared.frontmostApplication
            if previousApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier { previousApplication = nil }
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
        ClipboardTileTooltip.shared.hide()
        panel.resignKey()
        if NSApplication.shared.isActive { previousApplication?.activate(options: []) }
        previousApplication = nil
        applyDockLayout()
        refreshQuickLookPlacement()
    }

    func contains(_ screenPoint: NSPoint) -> Bool {
        tabContains(screenPoint) || (isVisible && (dockLayout?.bodyFrame.contains(screenPoint) == true ||
            magnetController.drawerAnchor?.contains(screenPoint) == true))
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
        guard isVisible, panel.isKeyWindow, !(panel.firstResponder is NSTextView),
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
        header.settingsButton.nextKeyView = browser.search
        browser.onInteraction = { [weak self] in self?.resetPreviewCycle() }
        browser.onVisibleEntriesChange = { [weak self] in self?.refreshQuickLookPlacement() }
        browser.onHover = { [weak self] entry in
            guard let self, self.isVisible, self.magnetController.drawerAnchor != nil,
                  self.store.carouselPosition != nil, self.store.stagedEntryID != entry.id else { return }
            self.store.previewInCarousel(entry, among: self.browser.visibleEntries)
        }
        browser.onClear = { [weak self] in self?.confirmClear() }
        browser.canvas.onPick = { [weak self] entry in self?.resetPreviewCycle(); self?.store.selectForPaste(entry) }
        browser.canvas.onPreview = { [weak self] entry in self?.togglePreview(entry) }
        browser.canvas.onDelete = { [weak self] entry in self?.confirmDelete(entry) }
        browser.canvas.onOpen = { [weak self] entry in self?.openInPreview(entry) }
        browser.canvas.onEscape = { [weak self] in self?.dismissAttachment() }
    }

    private func reload() { browser.update(entries: store.entries, attachedID: store.liftedEntryID) }

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
        if magnetController.isQuickLook, let entry = store.entries.first(where: { $0.id == store.stagedEntryID }) { magnetController.show(entry: entry, from: nil) }
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
        confirmRemoval(message: "Delete this clipboard item permanently?", detail: "🚨 This removes the item from ClipEdge, its saved history and preview copies. If it is on the clipboard, that is cleared too. Original files stay where they are. This cannot be undone.") { [weak self] in
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
        alert.addButton(withTitle: "Delete Permanently")
        if alert.runModal() == .alertSecondButtonReturn { perform() }
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
