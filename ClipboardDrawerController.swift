import AppKit

final class ClipboardDrawerController: NSObject {
    var confirmDeletion: (_ question: String, _ detail: String) -> Bool = ClipboardDrawerController.askByAlert
    var pickupMagnet: () -> Bool = { true }
    let store: ClipboardStore
    let panel: NSPanel
    let browser: ClipboardBrowserView
    let header: ClipboardDrawerHeader
    let previewService = ClipboardPreviewService()
    /// Opens an entry in the Preview app, one card's ⌘O and the marked cards' alike; fixtures watch it.
    lazy var openInPreview: (ClipboardEntry, @escaping (Error?) -> Void) -> Void = previewService.openInPreview
    let paster: ClipboardPaster
    let sendToPopover: ClipboardSendToPopover
    /// Maintainer copies only: ⌥⌘A on a tile. Without an asker the key does nothing.
    let askPopover: ClipboardPreviewAskPopover
    /// Multi-select's actions beside the drawer while anything is marked; it leaves the keyboard with the cards.
    let selectionPopover: ClipboardSelectionPopover
    /// Kept by the list, whose cards' help lists ⌥⌘A from it.
    var previewAsker: ClipboardPreviewAsker? {
        get { browser.list.previewAsker }
        set { browser.list.previewAsker = newValue; askPopover.view.asker = newValue }
    }
    var isConfirmingDeletion = false
    let magnetController: ClipboardMagnetController
    var targetScreen: NSScreen?
    var pasteLocation: NSPoint?
    private let glass = ClipboardGlassView(frame: .zero)
    private let defaults: UserDefaults?
    private static let placementKey = "ClipEdgeTabPlacement"
    private(set) var tabPlacement: ClipboardTabPlacement
    var dockLayout: ClipboardDockLayout?
    /// automatic: opened by hover or the tab, it closes on leaving. command: opened by the menu
    /// or shortcut, it stays until closed. heldForSettings: a hover opening whose gear or tab
    /// opened Settings, held while Settings stays open, then automatic again.
    private enum Visibility { case closed, automatic, command, heldForSettings }
    private var visibility = Visibility.closed
    private var expanded: Bool { visibility != .closed }
    private var availability = ClipboardDrawerAvailability.visibleTab
    private let motion = ClipboardDrawerMotion()
    private var waitsForTabExit = false
    /// Closed in the background holding the keyboard, the drawer lets go of it a moment later (`letGoOfKeyboard`).
    private var lettingGo = false
    /// When the drawer last opened; nil before its first opening. Copies made since then,
    /// including during the close grace, decide its tab at the next opening.
    private var openedAt: Date?
    private var keyMonitor: Any?
    private let activate: () -> Void
    /// ClipEdge in front with its key window, or in the background; fixtures supply their own.
    private let focus: () -> ClipboardAppFocus
    /// Gives the keyboard back to the app the drawer opened over; fixtures supply their own.
    private let returnTo: (NSRunningApplication) -> Void
    private let animationsEnabled: () -> Bool
    /// The app to return to, and to paste into, while the drawer holds focus.
    private(set) var previousApplication: NSRunningApplication?
    /// Instead, the ClipEdge window that had the keyboard when the drawer opened over it, such as Settings.
    private weak var previousKeyWindow: NSWindow?
    private var interactionPlacement = ClipboardTabPlacement()
    private var interactionOffset = NSPoint.zero
    private var interactionWallOffset = NSPoint.zero
    /// How open the drawer was when a drag on its tab began, and how wide when a drag on its edge did.
    private var slideStart: CGFloat = 0
    private var resizeStart: CGFloat = ClipboardTabGeometry.defaultBodyWidth
    /// A release at least this fast (points a second) opens or closes by its direction alone; a
    /// slower one by where the drawer would be this many seconds on.
    static let flickSpeed: CGFloat = 400
    static let releaseProjection: CGFloat = 0.15

    var isVisible: Bool { panel.isVisible && expanded }
    /// An open Settings window is no reason to stay: opened from the drawer it holds the drawer
    /// until it closes (`revealSettings()`); opened elsewhere it leaves hover closing alone.
    var allowsAutomaticHiding: Bool {
        visibility != .command && visibility != .heldForSettings && !motion.isMoving && !isConfirmingDeletion &&
        !sendToPopover.isVisible && !askPopover.isVisible &&
        !(panel.isKeyWindow && panel.firstResponder === browser.search.currentEditor())
    }
    var onRevealSettings: (() -> Void)?
    /// How a failed action is shown.
    var onError: (Error) -> Void = ClipboardErrorAlert.show
    var onShow: (() -> Void)?
    var onVisibilityChange: (() -> Void)?
    var sendSources = ClipboardSendTo.Sources()
    var isInteractingWithTab: Bool { glass.tabControl.isInteracting }
    var tabFrame: NSRect? { availability.tabVisible ? (expanded ? dockLayout?.expandedTabFrame : dockLayout?.tabFrame) : nil }
    var bodyFrame: NSRect? { isVisible ? dockLayout?.bodyFrame : nil }
    var openingFraction: CGFloat { motion.fraction }
    var isAnimating: Bool { motion.isMoving }
    /// How each direction slides, read at each move; Settings supplies it.
    var motionProfiles: (ClipboardDrawerDirection) -> ClipboardDrawerMotionProfile {
        get { motion.profiles }
        set { motion.profiles = newValue }
    }
    var screenFrame: NSRect? { targetScreen?.frame }
    /// How large it draws: its content zooms by the text size, its rows' thumbnails and Quick Look
    /// beside it follow theirs. Settings supplies it; `applySizes()` after a change.
    var sizes: () -> ClipboardSizes = { .standard }
    var previewAnchor: ClipboardDrawerPreviewAnchor? {
        guard isVisible, let layout = dockLayout, let screen = targetScreen else { return nil }
        return anchor(beside: layout, on: screen)
    }
    /// Where panels beside the drawer go: Quick Look at its preview size, Send to and the ask level with a row.
    func anchor(beside layout: ClipboardDockLayout, on screen: NSScreen) -> ClipboardDrawerPreviewAnchor {
        var anchor = ClipboardDrawerPreviewAnchor(drawer: layout.expandedFrame, screen: screen.visibleFrame, edge: tabPlacement.edge)
        anchor.previewScale = sizes().previewScale
        return anchor
    }

    /// Settings' sizes changed: the content zooms, the drawer keeps its width (wider when the
    /// content now needs more), the rows' thumbnails and Quick Look resize.
    func applySizes() {
        browser.list.thumbnailScale = sizes().thumbnailScale
        applyDockLayout()
    }

    init(store: ClipboardStore, magnetController: ClipboardMagnetController = ClipboardMagnetController(),
         panel suppliedPanel: NSPanel? = nil, defaults: UserDefaults? = .standard,
         paster: ClipboardPaster? = nil, sendToPopover: ClipboardSendToPopover = ClipboardSendToPopover(),
         askPopover: ClipboardPreviewAskPopover = ClipboardPreviewAskPopover(), selectionPanel: NSPanel? = nil,
         activate: @escaping () -> Void = {}, animationsEnabled: (() -> Bool)? = nil,
         focus: @escaping () -> ClipboardAppFocus = ClipboardAppFocus.current,
         returnTo: @escaping (NSRunningApplication) -> Void = { _ = $0.activate(options: []) },
         keymap: ClipboardKeymap = .drawer) {
        self.store = store
        browser = ClipboardBrowserView(frame: .zero, keymap: keymap)
        header = ClipboardDrawerHeader(keymap: keymap)
        self.magnetController = magnetController
        self.paster = paster ?? ClipboardPaster(store: store)
        self.sendToPopover = sendToPopover
        self.askPopover = askPopover
        selectionPopover = ClipboardSelectionPopover(keymap: keymap, panel: selectionPanel)
        self.defaults = defaults
        self.activate = activate
        self.focus = focus
        self.returnTo = returnTo
        self.animationsEnabled = animationsEnabled ?? {
            !ClipboardWindow.isIsolatedTestRun && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
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
        motion.onFrame = { [weak self] in self?.applyDockLayout() }

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
            do { try self.previewService.materializer.remove(entry) } catch { self.onError(error) }
        }
        magnetController.onCancel = { [weak self] in
            self?.dismissAttachment()
        }
        magnetController.shouldHandleEscape = { [weak self] in
            guard let self else { return true }
            // Quick Look's own panel holding the keyboard (its raw data's text) is the drawer's too: its Esc
            // gives the keyboard back to the cards rather than closing Quick Look.
            return !(self.isVisible && (self.panel.isKeyWindow || self.magnetController.holdsKeyboard
                                        || self.sendToPopover.isVisible || self.askPopover.isVisible))
        }
        magnetController.onPaste = { [weak self] point in
            self?.pasteLocation = point
            self?.store.commitStagedPaste()
        }
        magnetController.onDrop = { [weak self] in self?.store.dropStaging() }
        magnetController.onNavigate = { [weak self] direction in self?.movePreview(direction) }
        magnetController.onPresentationChange = { [weak self] in self?.refreshSelectionPanel() }
        // Quick Look's raw data: titled from the drawer's keys, its copies joining the history as any copy
        // does. A copy replaces what Quick Look put on the clipboard, so the preview ends with it.
        magnetController.keymap = keymap
        magnetController.copyPart = { [weak self] part in self?.store.copy(part) ?? false }
        // Its raw data's text, about to go or left by key, gives the keyboard back to the cards.
        magnetController.returnKeyboard = { [weak self] in self?.returnKeyboardFromQuickLook() }
        reload()
    }

    func show(on screen: NSScreen, animated: Bool = true) {
        present(on: screen, mode: visibility == .closed ? .automatic : visibility, animated: animated)
    }

    private func present(on screen: NSScreen, mode: Visibility, animated: Bool, velocity: CGFloat = 0) {
        guard availability.drawerEnabled else { return }
        onShow?()
        if !expanded {
            // The keyboard goes back where it was: to a ClipEdge window such as Settings, or to the app in front.
            previousKeyWindow = focus().keyWindow.flatMap { $0 === panel ? nil : $0 }
            previousApplication = previousKeyWindow == nil ? NSWorkspace.shared.frontmostApplication : nil
            if previousApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier { previousApplication = nil }
            // Cleared as it opens, not as it closes, so nothing moves while the drawer is open.
            // The search's undo is the drawer's own window's.
            let newCopies = openedAt.map { opened in store.entries.filter { $0.capturedAt > opened } } ?? []
            browser.list.startFresh(.keepUnlessHiding(newCopies: newCopies), undo: panel.undoManager)
            openedAt = Date()
        }
        targetScreen = screen
        visibility = mode
        motion.move(to: 1, animated: shouldAnimate(animated), velocity: velocity)
        activate()
        panel.makeKey()
        browser.list.focusHome(in: panel)
        refreshQuickLookPlacement()
        onVisibilityChange?()
    }

    /// `velocity` carries a released slide's speed (fractions a second) into the closing.
    func hide(animated: Bool, velocity: CGFloat = 0) {
        guard expanded else { return }
        // Decided before anything closes, from where the keyboard is now (`ClipboardKeyboardReturn`).
        let keyboard = ClipboardKeyboardReturn.after(.drawer(clipEdgeInFront: focus().isFront), holdingKeyboard: holdsKeyboard)
        visibility = .closed
        waitsForTabExit = true
        // Letting go: the drawer's own panel gathers the keyboard first (from Send to, the ask or Quick
        // Look), so closing them hands it nowhere else.
        if keyboard == .letGo, !panel.isKeyWindow { panel.makeKey() }
        sendToPopover.close()
        askPopover.close()
        selectionPopover.close()
        ClipboardTileTooltip.shared.hide()
        switch keyboard {
        case .takeBack:
            panel.resignKey()
            // resignKey() only notifies; making the window key moves the keyboard off the collapsed tab.
            if let window = previousKeyWindow, window.isVisible { window.makeKey() }
            else if let app = previousApplication { returnTo(app) }
        case .letGo:
            // A moment later, so a ClipEdge window opening as the drawer closes (the ⌥⌘\ window) keeps it.
            lettingGo = true
            DispatchQueue.main.async { [weak self] in self?.letGoOfKeyboard() }
        case .leave:
            break
        }
        previousApplication = nil
        previousKeyWindow = nil
        motion.move(to: 0, animated: shouldAnimate(animated), velocity: velocity)
        refreshQuickLookPlacement()
        onVisibilityChange?()
    }

    /// The drawer, a panel beside it or Quick Look beside it has the keyboard. A panel beside it that
    /// takes the keyboard closes as soon as it loses it, so one showing holds it.
    private var holdsKeyboard: Bool {
        panel.isKeyWindow || magnetController.holdsKeyboard || sendToPopover.isVisible || askPopover.isVisible
    }

    /// The drawer closed with ClipEdge in the background while it held the keyboard: the collapsed
    /// tab would keep it, taking the person's typing in the app in front. Its panel goes out through
    /// the keyboard gate, so that app has the keyboard, and the tab comes straight back without it.
    /// A hidden-tab panel left on screen for this moment (`applyDockLayout`) then leaves, whoever has the keyboard.
    private func letGoOfKeyboard() {
        lettingGo = false
        guard !expanded else { return }
        if ClipboardKeyboardReturn.after(.drawer(clipEdgeInFront: focus().isFront), holdingKeyboard: panel.isKeyWindow) == .letGo {
            ClipboardWindow.orderOutReturningKeyboard(panel)
        }
        applyDockLayout()
    }

    /// Menu, Dock reopen and shortcut own a persistent open/closed state.
    func toggleFromCommand() {
        guard availability.drawerEnabled else { return }
        if expanded { hide(animated: true) }
        else { present(on: targetScreen ?? preferredScreen(), mode: .command, animated: true) }
    }

    func applyAvailability(_ newValue: ClipboardDrawerAvailability) {
        guard availability != newValue else { return }
        availability = newValue
        if !newValue.drawerEnabled { hide(animated: false) }
        motion.move(to: expanded ? 1 : 0, animated: false)
        applyDockLayout()
        onVisibilityChange?()
    }

    /// The gear and a right-click on the tab open Settings. A drawer they were reached from
    /// stays in view while Settings is open: pointer exit leaves it open, the menu reads
    /// Hide Clipboard, and the menu, the shortcut or Esc close it.
    private func revealSettings() {
        if visibility == .automatic { visibility = .heldForSettings; onVisibilityChange?() }
        onRevealSettings?()
    }

    /// Settings closed: a drawer it held closes on leaving again, after its usual grace.
    func settingsDidClose() { if visibility == .heldForSettings { visibility = .automatic } }

    /// An explicit close while over the tab stays closed until the pointer leaves.
    func canAutomaticallyReveal(pointerOverTab: Bool) -> Bool {
        if !pointerOverTab { waitsForTabExit = false }
        return availability.drawerEnabled && !waitsForTabExit && !motion.isMoving
    }

    private func shouldAnimate(_ requested: Bool) -> Bool {
        requested && animationsEnabled()
    }

    func contains(_ screenPoint: NSPoint) -> Bool {
        tabContains(screenPoint) || (isVisible && (dockLayout?.bodyFrame.contains(screenPoint) == true ||
            magnetController.drawerAnchor?.contains(screenPoint) == true ||
            (sendToPopover.isVisible && sendToPopover.frame.contains(screenPoint)) ||
            (askPopover.isVisible && askPopover.frame.contains(screenPoint)) ||
            (selectionPopover.isVisible && selectionPopover.frame.contains(screenPoint))))
    }

    func tabContains(_ point: NSPoint) -> Bool {
        guard availability.tabVisible, panel.isVisible, let frame = tabFrame else { return false }
        return NSBezierPath(roundedRect: frame, xRadius: 14, yRadius: 14).contains(point)
    }

    /// Hiding the paint keeps the user's saved screen-edge hover position.
    /// No transparent window is left to intercept clicks in other apps.
    func revealTargetContains(_ point: NSPoint) -> Bool {
        guard availability.drawerEnabled, let frame = dockLayout?.tabFrame else { return false }
        return NSBezierPath(roundedRect: frame, xRadius: 14, yRadius: 14).contains(point)
    }

    func showCollapsedTab(on screen: NSScreen) {
        if expanded { hide(animated: false) }
        targetScreen = screen
        visibility = .closed
        motion.move(to: 0, animated: false)
        applyDockLayout()
    }

    func showAtTab() {
        guard availability.drawerEnabled, !isInteractingWithTab else { return }
        show(on: targetScreen ?? preferredScreen())
    }

    func preferredScreen() -> NSScreen {
        NSScreen.screens.first { Self.screenID($0) == tabPlacement.screenID } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    func refreshScreenGeometry() {
        targetScreen = preferredScreen()
        applyDockLayout()
    }

    func stop() {
        hide(animated: false)
        motion.move(to: 0, animated: false)
        magnetController.hide()
        ClipboardTileTooltip.shared.hide()
        previewService.materializer.removeAll()
        panel.orderOut(nil)
    }
    deinit { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }

    private static func screenID(_ screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func applyDockLayout() {
        guard let screen = targetScreen else { return }
        let textScale = sizes().textScale
        let geometry = ClipboardTabGeometry.layout(placement: tabPlacement, in: screen.visibleFrame,
                                                   minimumBodyWidth: ClipboardTabGeometry.contentMinimumWidth * textScale)
        glass.contentScale = textScale
        // Align the drawer and its attached tab with NSWindow's point grid.
        func aligned(_ rect: NSRect) -> NSRect {
            NSRect(x: floor(rect.minX), y: floor(rect.minY), width: floor(rect.width), height: floor(rect.height))
        }
        let layout = ClipboardDockLayout(tabFrame: aligned(geometry.tabFrame), bodyFrame: aligned(geometry.bodyFrame),
                                         expandedTabFrame: aligned(geometry.expandedTabFrame))
        dockLayout = layout
        let drawingBody = expanded || motion.isMoving
        // No tab to show: the panel leaves the screen. One still holding the keyboard while the drawer lets go
        // of it (a hidden-tab drawer closing at once, in the background) leaves a moment later, through the
        // keyboard gate (`letGoOfKeyboard`): ordered out now, AppKit would hand the keyboard to another ClipEdge
        // window and activate ClipEdge; gated now, a ClipEdge window opening as the drawer closes (the ⌥⌘\
        // window) could not take it.
        guard drawingBody || availability.tabVisible else {
            if !(lettingGo && panel.isKeyWindow) { panel.orderOut(nil) }
            return
        }
        let frame = drawingBody ? (availability.tabVisible ? layout.expandedFrame : layout.bodyFrame) : layout.tabFrame
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        glass.frame = NSRect(origin: .zero, size: frame.size)
        let remaining = 1 - motion.fraction
        var body = layout.bodyFrame
        switch tabPlacement.edge {
        case .left: body.origin.x -= body.width * remaining
        case .right: body.origin.x += body.width * remaining
        case .top: body.origin.y += body.height * remaining
        }
        let tab = drawingBody ? layout.expandedTabFrame.offsetBy(
            dx: (layout.tabFrame.minX - layout.expandedTabFrame.minX) * remaining,
            dy: (layout.tabFrame.minY - layout.expandedTabFrame.minY) * remaining) : layout.tabFrame
        glass.updateLayout(bodyRect: drawingBody ? body.offsetBy(dx: -frame.minX, dy: -frame.minY) : nil,
                           tabRect: tab.offsetBy(dx: -frame.minX, dy: -frame.minY), edge: tabPlacement.edge,
                           tabVisible: availability.tabVisible)
        glass.layoutSubtreeIfNeeded()
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        if let anchor = previewAnchor { magnetController.updateDrawerAnchor(anchor) }
        // The selection's actions follow the drawer as its tab is dragged: moved, never read again.
        if selectionPopover.isVisible { placeSelectionPanel() }
    }

    private func configureTab() {
        // EdgeController owns hover timing, including delayed and click modes.
        glass.tabControl.onClick = { [weak self] in self?.showAtTab() }
        glass.tabControl.onSettings = { [weak self] in self?.revealSettings() }
        glass.tabControl.onInteractionBegan = { [weak self] pointer in
            guard let self else { return }
            if self.magnetController.drawerAnchor == nil { self.resetPreviewCycle() }
            self.interactionPlacement = self.tabPlacement
            let tab = self.tabFrame ?? .zero
            self.interactionOffset = NSPoint(x: tab.midX - pointer.x, y: tab.midY - pointer.y)
            let resting = self.dockLayout?.tabFrame ?? tab
            self.interactionWallOffset = NSPoint(x: resting.midX - tab.midX, y: resting.midY - tab.midY)
            self.slideStart = self.motion.fraction
        }
        glass.tabControl.onDrag = { [weak self] point in self?.moveTab(to: point) }
        glass.tabControl.onResize = { [weak self] delta in self?.resizeTab(by: delta) }
        glass.tabControl.onSlide = { [weak self] away in self?.slide(by: away) }
        glass.tabControl.onSlideEnded = { [weak self] speed in self?.releaseSlide(speed: speed) }
        glass.tabControl.onInteractionEnded = { [weak self] in self?.savePlacement() }
        for grip in [glass.edgeGrips.left, glass.edgeGrips.right] {
            grip.onBegan = { [weak self] in self?.resizeStart = self?.dockLayout?.bodyFrame.width ?? ClipboardTabGeometry.defaultBodyWidth }
            grip.onDrag = { [weak self] wider in self?.resizeBody(to: (self?.resizeStart ?? 0) + wider) }
            grip.onEnded = { [weak self] in self?.savePlacement() }
        }
    }

    private func savePlacement() {
        guard let data = try? JSONEncoder().encode(tabPlacement) else { return }
        defaults?.set(data, forKey: Self.placementKey)
    }

    /// The drawer follows a drag on its tab across the edge: open by as much as the pointer has
    /// travelled away from the wall, over the body's width.
    private func slide(by away: CGFloat) {
        guard availability.drawerEnabled else { return }
        let width = max(1, dockLayout?.bodyFrame.width ?? ClipboardTabGeometry.defaultBodyWidth)
        motion.hold(at: slideStart + away / width)
    }

    /// A slide let go: the drawer finishes opening or closing from where it is, starting at the speed
    /// it was let go with. A flick decides by its direction; a slower release by whether the drawer
    /// would be past halfway a moment later. Opening this way is opening by a click on the tab.
    private func releaseSlide(speed: CGFloat) {
        guard availability.drawerEnabled else { return }
        let velocity = speed / max(1, dockLayout?.bodyFrame.width ?? ClipboardTabGeometry.defaultBodyWidth)
        let opens = abs(speed) >= Self.flickSpeed ? speed > 0 : motion.fraction + velocity * Self.releaseProjection >= 0.5
        switch (opens, expanded) {
        case (true, true): motion.move(to: 1, animated: shouldAnimate(true), velocity: velocity)
        case (true, false): present(on: targetScreen ?? preferredScreen(), mode: .automatic, animated: true, velocity: velocity)
        case (false, true): hide(animated: true, velocity: velocity)
        case (false, false): motion.move(to: 0, animated: shouldAnimate(true), velocity: velocity)
        }
    }

    /// The drawer as wide as a drag on its edge makes it, between what its content needs and most of
    /// the screen; kept as the width the geometry allowed, so the next drag starts from what shows.
    private func resizeBody(to width: CGFloat) {
        tabPlacement.bodyWidth = Double(width)
        applyDockLayout()
        if let shown = dockLayout?.bodyFrame.width { tabPlacement.bodyWidth = Double(shown) }
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
                } catch { store.cancelStaging(); onError(error) }
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

    /// The drawer's keys that act wherever its keyboard is (Esc, ⌥⌘A), or anywhere but its search
    /// (Space, ⌥1–⌥9, Page Up and Page Down, and the arrows while Quick Look shows), through the list
    /// the window's keys go through too; the rest are the cards'. While Quick Look's raw data's text
    /// holds the keyboard it keeps its own keys. Shared with fixture tests; no system input is synthesized.
    func handleDrawerKey(_ event: NSEvent) -> Bool {
        guard isVisible else { return false }
        let rawData = magnetController.drawerCarousel.flatMap { $0.showsRawData ? $0.raw : nil }
        let textHolds = rawData?.holdsKeyboard == true && magnetController.holdsKeyboard
        // Quick Look's panel holding the keyboard, its raw data's text (T, or a click there) or not (a
        // click on it): the drawer's keys still act, never stranded there.
        if textHolds || (magnetController.holdsKeyboard && !panel.isKeyWindow) {
            if textHolds, let rawData {
                // The text keeps ⌘C (with a selection) and ⌘A, and the arrows, Home and End that move
                // its caret and, with ⇧, select; T moves on to the next text, Page Up and Page Down
                // scroll, and Esc gives the keyboard back to the cards, Quick Look staying.
                if rawData.handleEditingKey(event) { return true }
                if ClipboardRawDataView.isTextNavigation(event) { return false }
                let action = browser.keymap.action(for: event)
                if event.isARepeat, action?.waitsForNextPress == true { return true }
                switch action {
                case .selectRawText?: rawData.selectNextText(); return true
                case .pageUp?: rawData.page(.up); return true
                case .pageDown?: rawData.page(.down); return true
                case .escape?: returnKeyboardFromQuickLook(); return true
                default: break
                }
            }
            // Any other key brings the keyboard back to the cards and acts there. It was on its way to
            // Quick Look's panel, which no longer wants it: it acts on the cards (their own keys, S or
            // I, included), or beeps there as any unused key does.
            returnKeyboardFromQuickLook()
            if header.publishControl.handleKey(event) || browser.list.handleKey(event, in: panel) { return true }
            browser.canvas.keyDown(with: event)
            return true
        }
        guard panel.isKeyWindow else { return false }
        if header.publishControl.handleKey(event) { return true }
        // Text left selected in Quick Look's raw data is not consulted: the drawer has the keyboard,
        // and its search's ⌘A and ⌘C, or the cards' pick-up, are what the keys mean here.
        return browser.list.handleKey(event, in: panel)
    }

    /// The keyboard back to the cards from Quick Look's panel. A text there that held it only in a
    /// panel no longer key (the drawer took the keyboard by a click) lets go, and the keyboard stays.
    private func returnKeyboardFromQuickLook() {
        let held = magnetController.holdsKeyboard
        magnetController.releaseKeyboard()
        guard held, isVisible else { return }
        panel.makeKey()
        browser.list.focusHome(in: panel)
    }

    /// The drawer's answer to an action from its keys, a click on a card or a card's buttons;
    /// `entry` is the chosen card's. False passes a key on.
    private func perform(_ action: ClipboardBrowserAction, on entry: ClipboardEntry?) -> Bool {
        switch action {
        case .escape: dismissFromKeyboard(); return true
        case .ask:
            guard previewAsker != nil, let entry else { return false }
            showAskForPreview(entry); return true
        case .newer, .older, .previousRow, .nextRow:
            // The panel's arrows browse Quick Look's carousel while it shows; the cards move their own selection.
            guard magnetController.isQuickLook, store.carouselPosition != nil, let step = action.step(columns: 1) else { return false }
            movePreview(step < 0 ? -1 : 1); return true
        case .quickLook:
            guard let entry else { return false }
            togglePreview(entry); return true
        case .flip:
            guard let entry else { return false }
            turnPreview(entry); return true
        case .copyFlavor(let number):
            // Only while Quick Look shows the raw data; otherwise the key passes on.
            guard let carousel = magnetController.drawerCarousel, carousel.showsRawData else { return false }
            if !carousel.raw.copyFlavor(number: number) { NSSound.beep() }
            return true
        case .selectRawText:
            // T: the keyboard to Quick Look's raw data's first text, to read and select by key.
            guard let carousel = magnetController.drawerCarousel, carousel.showsRawData else { return false }
            magnetController.takeKeyboard()
            if !carousel.raw.selectNextText() { returnKeyboardFromQuickLook(); NSSound.beep() }
            return true
        case .pageUp, .pageDown:
            guard let carousel = magnetController.drawerCarousel, carousel.showsRawData else { return false }
            carousel.raw.page(action == .pageUp ? .up : .down)
            return true
        case .primary, .pickUp:
            guard let entry else { return false }
            resetPreviewCycle(); pick(entry); return true
        case .sendTo:
            guard let entry else { return false }
            showSendTo(entry); return true
        case .open:
            guard let entry else { return false }
            open(entry); return true
        case .delete:
            guard let entry else { return false }
            confirmDelete(entry); return true
        // "," opens Settings as the gear does, so it holds the drawer too.
        case .settings: revealSettings(); return true
        case .ignore: return true
        // The browser's own: its search, its tabs and the marks.
        case .find, .tab, .selecting, .markAll, .extendNewer, .extendOlder: return false
        // Not the drawer's: it picks up, and the paste happens where the item is dropped.
        case .plainPaste: return false
        }
    }

    private func configureContent() {
        panel.contentView = glass
        header.install(above: browser, in: glass.bodyContent)
        header.onSettings = { [weak self] in self?.revealSettings() }
        browser.keyLoopExit = header.settingsButton
        header.publishControl.onVisibilityChange = { [weak self] in self?.refreshHeaderKeyLoop() }
        refreshHeaderKeyLoop()
        browser.onInteraction = { [weak self] in self?.resetPreviewCycle() }
        browser.onVisibleEntriesChange = { [weak self] in self?.refreshQuickLookPlacement() }
        browser.onHover = { [weak self] entry in
            guard let self, self.isVisible, self.magnetController.drawerAnchor != nil,
                  self.store.carouselPosition != nil, self.store.stagedEntryID != entry.id else { return }
            self.store.previewInCarousel(entry, among: self.browser.visibleEntries)
        }
        browser.perform = { [weak self] action, entry in self?.perform(action, on: entry) ?? false }
        browser.list.onMarkingChange = { [weak self] in self?.refreshSelectionPanel() }
        browser.list.performOnMarks = { [weak self] action, marked in self?.performOnMarks(action, marked) ?? false }
        browser.list.storageReport = { [weak self] in self?.store.storageReport }
        selectionPopover.view.onAction = { [weak self] action in
            guard let self else { return }
            _ = self.browser.list.answer(action, on: self.browser.canvas.selected?.entry)
        }
        sendToPopover.view.onBack = { [weak self] in self?.sendToPopover.close() }
        // Back to the same selected tile, with the keyboard.
        let backToTile: () -> Void = { [weak self] in
            guard let self, self.isVisible else { return }
            self.panel.makeKey()
            self.browser.list.focusHome(in: self.panel)
        }
        sendToPopover.onClose = backToTile
        askPopover.onClose = backToTile
        // The panels beside it draw at the Text size, as its own content does.
        let textScale: () -> CGFloat = { [weak self] in self?.sizes().textScale ?? 1 }
        sendToPopover.textScale = textScale
        askPopover.textScale = textScale
        selectionPopover.textScale = textScale
        // A card's info opens where Send to does: beside the drawer, level with the card.
        ClipboardTileTooltip.shared.besideDrawer = { [weak self] card, size in
            self?.previewAnchor?.frame(fitting: size, centeredAtY: card.midY)
        }
        ClipboardTileTooltip.shared.isRoomTaken = { [weak self] in
            guard let self else { return false }
            return self.magnetController.drawerAnchor != nil || self.sendToPopover.isVisible || self.askPopover.isVisible
                || self.selectionPopover.isVisible
        }
    }

    private func refreshHeaderKeyLoop() {
        if header.publishControl.isHidden, panel.firstResponder === header.publishControl {
            panel.makeFirstResponder(header.settingsButton)
        }
        header.settingsButton.nextKeyView = header.publishControl.isHidden ? browser.search : header.publishControl
        header.publishControl.nextKeyView = browser.search
    }

    func reload() {
        browser.update(entries: store.entries, attachedID: store.liftedEntryID)
        if let held = store.entries.first(where: { $0.id == store.stagedEntryID }) { magnetController.refreshSmall(held) }
    }

}
