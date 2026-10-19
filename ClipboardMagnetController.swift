import AppKit

final class ClipboardMagnetController {
    /// Effects that reach outside the fixture process. Release preparation
    /// suppresses them while retaining the controller's layout and lifecycle.
    struct SystemEffects {
        var setCursor: (NSCursor) -> Void = { $0.set() }
        var registerArrow: (ClipboardHotKey) -> Void = { _ = $0.register() }
        var startCommandClick: (CommandClickPaste) -> Void = { $0.start() }
    }
    private let systemEffects: SystemEffects?
    var quickLookHint = "⌃⌥Space"
    var onCancel: (() -> Void)?
    var shouldHandleEscape: () -> Bool = { true }
    var onPaste: ((NSPoint) -> Void)?
    var onDrop: (() -> Void)?

    enum Presentation: Equatable { case hidden, small, carousel, drawer(ClipboardDrawerPreviewAnchor) }
    private(set) var presentation: Presentation = .hidden {
        didSet { if presentation != oldValue { onPresentationChange?() } }
    }
    /// Quick Look opened, moved or closed, or the small magnet came or went (the drawer's selection
    /// panel gives way to Quick Look's drawer magnet and returns when it closes).
    var onPresentationChange: (() -> Void)?
    var isQuickLook: Bool {
        switch presentation { case .carousel, .drawer: return true; default: return false }
    }
    var drawerAnchor: ClipboardDrawerPreviewAnchor? {
        if case .drawer(let anchor) = presentation { return anchor }
        return nil
    }
    var isVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }
    /// Quick Look beside the open drawer, which turns over to the raw data; nil otherwise.
    var drawerCarousel: ClipboardCarouselView? { drawerAnchor == nil ? nil : panel.contentView as? ClipboardCarouselView }
    /// Its panel has the keyboard: a click in the raw data's text can give it.
    var holdsKeyboard: Bool { panel.isVisible && panel.isKeyWindow }
    /// The keys Quick Look's turn button and raw data name: the drawer's.
    var keymap = ClipboardKeymap.drawer
    /// Where a part copied from the raw data goes; the drawer routes it through its store.
    var copyPart: (ClipboardRawCopy) -> Bool = { $0.write(to: .general) }
    /// Where the keyboard goes when Quick Look's raw data's text lets go of it (the entry changes, the
    /// preview turns back, Esc): the drawer's cards. Every Quick Look it shows uses it.
    var returnKeyboard: () -> Void = {}
    var pasteDiagnostics: [String: Any] { pasteMonitor.diagnostics }
    var onNavigate: ((Int) -> Void)?
    private let previousKey = ClipboardHotKey(keyCode: 123, modifiers: [])
    private let nextKey = ClipboardHotKey(keyCode: 124, modifiers: [])
    private let commandClick = CommandClickPaste()
    private let commandClickEnabled: Bool
    private let panel: NSPanel
    private let pasteMonitor: PasteMonitor
    private var trackingTimer: Timer?
    private var pasteCompletionScheduled = false
    private var presentationGeneration = 0
    private var previewSize = NSSize.zero
    private var motion: Motion?
    private var isHolding = false
    /// What the small magnet was drawn from: late facts, a thumbnail or a new
    /// appearance redraw it.
    private var smallContent: (entry: ClipboardEntry, metadata: ClipboardMetadata, thumbnail: NSImage?)?
    private var appearanceObservation: NSKeyValueObservation?
    // This is a rendered-pixel limit, including padding and the holding glyph.
    // Convert it to AppKit points using the display under the attachment.
    private var maximumAttachmentPixels: CGFloat { drawerAnchor != nil ? .greatestFiniteMagnitude : (isQuickLook ? 840 * previewScale() : 350) }
    /// The preview size (Settings, 2026-10-16): Quick Look at the pointer is 420 × 340 points at
    /// 100%, at most 840 pixels a side; beside the drawer its anchor carries the size.
    var previewScale: () -> CGFloat = { 1 }
    /// The Text size: Quick Look's caption and the held magnet's words grow with it.
    var textScale: () -> CGFloat = { 1 }
    static let pointerPreviewSize = NSSize(width: 420, height: 340)
    private let holdingGlyphHeight: CGFloat = 25

    private struct Motion {
        enum Destination {
            case pointer
            case paste(NSPoint)
            case slot(NSRect)
        }
        let from: NSRect
        let destination: Destination
        let start: TimeInterval
        let duration: TimeInterval
        let completion: (() -> Void)?
    }

    init(pasteMonitor suppliedMonitor: PasteMonitor? = nil, panel suppliedPanel: NSPanel? = nil,
         commandClickEnabled: Bool = true, systemEffects: SystemEffects = SystemEffects()) {
        let isolated = ClipboardWindow.isIsolatedTestRun
        self.systemEffects = isolated ? nil : systemEffects
        // Explicit fake monitors keep their injected-event tests. The normal
        // default must never observe the user's apps from a release test run.
        let pasteMonitor = suppliedMonitor ?? PasteMonitor(environment: isolated ? .init(
            accessibilityTrusted: { false }, listenAccess: { false }, externalApplication: { false },
            keyAction: { nil }, pointerLocation: { .zero },
            beginObservation: { _ in }, refreshObservation: { _ in }
        ) : PasteMonitor.Environment())
        self.pasteMonitor = pasteMonitor
        self.commandClickEnabled = commandClickEnabled
        panel = suppliedPanel ?? ClipboardWindow(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.title = "ClipEdge Cursor Magnet"
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Keep all attachment pixels inside the bounded preview rectangle.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        // Carousel buttons must not steal the destination app's keyboard focus.
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = true
        pasteMonitor.onCancel = { [weak self] in self?.onCancel?() }
        pasteMonitor.shouldHandleCancel = { [weak self] in self?.shouldHandleEscape() ?? true }
        pasteMonitor.onPaste = { [weak self] point in self?.schedulePasteCompletion(at: point) }
        commandClick.onPaste = { [weak self] point in self?.schedulePasteCompletion(at: point) }
        commandClick.onDrop = { [weak self] in self?.onDrop?() }
        commandClick.onFailure = { NSSound.beep() }
        previousKey.onPress = { [weak self] in self?.onNavigate?(-1) }
        nextKey.onPress = { [weak self] in self?.onNavigate?(1) }
        // The small magnet is a snapshot, so it cannot follow the Mac into dark
        // or light by itself. Redraw it once AppKit has passed the change on.
        appearanceObservation = NSApplication.shared.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.redrawSmall() }
        }
    }

    deinit {
        trackingTimer?.invalidate()
        pasteMonitor.stop()
    }

    func show(entry: ClipboardEntry, from source: NSRect?) {
        hide()
        isHolding = true
        presentation = .small
        panel.ignoresMouseEvents = true
        installSmallPreview(for: entry)
        let destination = pointerFrame()
        let origin = source.map { rect in
            NSRect(x: rect.midX - previewSize.width * 0.4,
                   y: rect.midY - previewSize.height * 0.4,
                   width: previewSize.width * 0.8, height: previewSize.height * 0.8)
        } ?? destination
        panel.setFrame(cappedFrame(origin), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        motion = Motion(from: panel.frame, destination: .pointer, start: ProcessInfo.processInfo.systemUptime,
                        duration: 0.22, completion: nil)
        systemEffects?.setCursor(.closedHand)
        startTimer()
        pasteMonitor.start()
        if commandClickEnabled { systemEffects?.startCommandClick(commandClick) }
    }

    /// Disk facts and Quick Look thumbnails arrive after a copy has attached.
    func refreshSmall(_ entry: ClipboardEntry) {
        guard presentation == .small, let shown = smallContent, shown.entry.id == entry.id,
              shown.metadata != entry.metadata || shown.thumbnail !== entry.thumbnail else { return }
        installSmallPreview(for: entry)
    }

    /// Only while it is held: a magnet on its way into a paste or back to its slot keeps its look.
    private func redrawSmall() {
        guard presentation == .small, isHolding, let shown = smallContent else { return }
        installSmallPreview(for: shown.entry)
    }

    private func installSmallPreview(for entry: ClipboardEntry) {
        smallContent = (entry, entry.metadata, entry.thumbnail)
        let preview = ClipboardAttachmentView.makeHeldPreview(for: entry, maximumAttachmentPixels: maximumAttachmentPixels, holdingGlyphHeight: holdingGlyphHeight,
                                                              shortcutHint: quickLookHint, textScale: textScale())
        previewSize = preview.size
        let visibleFrame = panel.frame
        panel.setFrame(NSRect(origin: visibleFrame.origin, size: preview.size), display: false)
        panel.contentView = preview.view
        preview.view.layoutSubtreeIfNeeded()
        // Freeze the preview into an image so shrinking the panel also shrinks
        // its text, corners and image, rather than reflowing its constraints.
        if let bitmap = preview.view.bitmapImageRepForCachingDisplay(in: preview.view.bounds) {
            preview.view.cacheDisplay(in: preview.view.bounds, to: bitmap)
            let image = NSImage(size: preview.size)
            image.addRepresentation(bitmap)
            let imageView = NSImageView(frame: NSRect(origin: .zero, size: preview.size))
            imageView.image = image
            imageView.imageScaling = .scaleAxesIndependently
            panel.contentView = imageView
        }
    }

    func showCarousel(entry: ClipboardEntry, urls: [URL], position: Int, count: Int,
                      anchor: ClipboardDrawerPreviewAnchor? = nil) {
        let previousFrame = presentation == .carousel && panel.isVisible ? panel.frame : nil
        let retainedView = isQuickLook && motion == nil ? panel.contentView as? ClipboardCarouselView : nil
        // Cancel stale paste work without ordering out or blanking the remote
        // Quick Look view between hovered items.
        if retainedView != nil { stopObservation() } else { hide() }
        presentation = anchor.map(Presentation.drawer) ?? .carousel
        isHolding = true
        panel.ignoresMouseEvents = false
        let view = retainedView ?? ClipboardCarouselView(entry: entry, urls: urls, position: position, count: count, keymap: keymap)
        view.textScale = textScale()
        view.update(entry: entry, urls: urls, position: position, count: count)
        // Beside the open drawer only: the medium cursor magnet takes no keys, so it stays on the preview.
        view.allowsFlip = anchor != nil
        view.raw.copier = { [weak self] part in self?.copyPart(part) ?? false }
        view.raw.returnKeyboard = { [weak self] in self?.returnKeyboard() }
        view.onNavigate = { [weak self] in self?.onNavigate?($0) }
        view.onClose = { [weak self] in self?.onCancel?() }
        previewSize = anchor?.frame.size ?? NSSize(width: Self.pointerPreviewSize.width * previewScale(), height: Self.pointerPreviewSize.height * previewScale())
        if panel.contentView !== view { panel.contentView = view }
        panel.setFrame(anchor?.frame ?? previousFrame ?? pointerFrame(), display: true)
        view.frame = NSRect(origin: .zero, size: panel.frame.size)
        view.layoutSubtreeIfNeeded()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        startTimer()
        pasteMonitor.start()
        // The open drawer owns local keys, including search-field caret movement.
        // Only the cursor carousel needs bare arrows while another app is active.
        if anchor == nil { systemEffects?.registerArrow(previousKey); systemEffects?.registerArrow(nextKey) }
        if commandClickEnabled { systemEffects?.startCommandClick(commandClick) }
    }

    func updateDrawerAnchor(_ anchor: ClipboardDrawerPreviewAnchor) {
        guard drawerAnchor != nil, motion == nil else { return }
        presentation = .drawer(anchor)
        previewSize = anchor.frame.size
        panel.setFrame(anchor.frame, display: true)
        panel.contentView?.frame = NSRect(origin: .zero, size: previewSize)
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    /// The keyboard goes back to the drawer: Quick Look's panel lets go of the raw data's text it held.
    func releaseKeyboard() { panel.makeFirstResponder(nil) }
    /// Quick Look beside the drawer takes the keyboard, for its raw data's text to be read by key.
    func takeKeyboard() { panel.makeKey() }

    /// Quick Look hiding while its panel holds the keyboard (a copy ends it, its × or Esc drops it) gives the
    /// keyboard back by the one rule (`ClipboardKeyboardReturn`). Ordered out holding it, AppKit would hand
    /// it to another ClipEdge window (the drawer's tab, or the ⌥⌘\ window off screen) and bring ClipEdge to
    /// the front.
    func hide() {
        stopObservation()
        // Decided before anything closes, from where the keyboard is now.
        let keyboard = ClipboardKeyboardReturn.after(.quickLook(besideOpenDrawer: drawerAnchor != nil), holdingKeyboard: holdsKeyboard)
        presentation = .hidden
        smallContent = nil
        // Its raw data's text holding the keyboard gives it to the drawer's cards as it goes (`returnKeyboard`).
        (panel.contentView as? ClipboardCarouselView)?.closePreview()
        switch keyboard {
        case .takeBack:
            // The panel itself still holding it (a click on it, not its text): the cards take it back the same way.
            if holdsKeyboard { returnKeyboard() }
            ClipboardWindow.orderOutReturningKeyboard(panel)
        case .letGo where holdsKeyboard:
            // No drawer open to take it back. Gated now, a ClipEdge window opening at this moment could not
            // take the keyboard (the ⌥⌘\ window cancels Quick Look as it opens), so the panel stays a moment,
            // unseen, and leaves through the keyboard gate, as the drawer's panel does.
            panel.alphaValue = 0
            panel.ignoresMouseEvents = true
            guard !lettingGo else { return }
            lettingGo = true
            DispatchQueue.main.async { [weak self] in self?.letGoOfKeyboard() }
        case .letGo, .leave:
            panel.orderOut(nil)
        }
    }

    /// Hidden holding the keyboard with no drawer open to take it back, the panel leaves a moment later (`letGoOfKeyboard`).
    private var lettingGo = false

    /// The panel goes out through the keyboard gate, so the app in front has the keyboard; shown again
    /// meanwhile (the small magnet of the copy that ended Quick Look), it comes straight back without it. A
    /// ClipEdge window that took the keyboard meanwhile keeps it.
    private func letGoOfKeyboard() {
        lettingGo = false
        let showing = presentation != .hidden
        guard !showing || panel.isKeyWindow else { return }
        ClipboardWindow.orderOutReturningKeyboard(panel)
        if showing { panel.orderFrontRegardless() }
    }

    private func stopObservation() {
        presentationGeneration += 1
        commandClick.stop(); previousKey.unregister(); nextKey.unregister()
        pasteCompletionScheduled = false
        motion = nil
        trackingTimer?.invalidate()
        trackingTimer = nil
        pasteMonitor.stop()
        releaseCursor()
    }

    func consume(at point: NSPoint) {
        finishMotion(to: .paste(point), duration: 0.2, completion: nil)
    }

    func returnToSlot(_ rect: NSRect?, completion: @escaping () -> Void) {
        guard let rect, panel.isVisible else {
            hide()
            completion()
            return
        }
        finishMotion(to: .slot(rect), duration: 0.28, completion: completion)
    }

    private func finishMotion(to destination: Motion.Destination, duration: TimeInterval,
                              completion: (() -> Void)?) {
        presentationGeneration += 1
        // Small magnets are already snapshots. Keep Quick Look live: its remote
        // content is absent from cacheDisplay snapshots and would flash blank.
        panel.ignoresMouseEvents = true
        commandClick.stop(); previousKey.unregister(); nextKey.unregister()
        pasteMonitor.stop()
        releaseCursor()
        pasteCompletionScheduled = false
        motion = Motion(from: panel.frame, destination: destination,
                        start: ProcessInfo.processInfo.systemUptime, duration: duration,
                        completion: completion)
        startTimer()
    }

    private func startTimer() {
        trackingTimer?.invalidate()
        trackingTimer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(trackingTimer!, forMode: .common)
    }

    private func tick() {
        guard let motion else {
            if isHolding {
                if drawerAnchor != nil { return }
                // The medium magnet settles while the pointer reaches its controls.
                if presentation == .carousel && panel.frame.insetBy(dx: -24, dy: -24).contains(NSEvent.mouseLocation) { return }
                panel.setFrame(pointerFrame(), display: true)
            }
            return
        }
        let fraction = min(1, (ProcessInfo.processInfo.systemUptime - motion.start) / motion.duration)
        let eased = 1 - pow(1 - fraction, 3)
        let destination: NSRect
        switch motion.destination {
        case .pointer:
            destination = pointerFrame()
        case .paste(let point):
            destination = NSRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)
            panel.alphaValue = 1 - fraction
        case .slot(let rect):
            let scale = min(1, rect.width / previewSize.width, rect.height / previewSize.height)
            let size = NSSize(width: previewSize.width * scale, height: previewSize.height * scale)
            destination = NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                 width: size.width, height: size.height)
            panel.alphaValue = 1 - max(0, (fraction - 0.75) / 0.25)
        }
        let from = motion.from
        let frame = NSRect(x: from.minX + (destination.minX - from.minX) * eased,
                              y: from.minY + (destination.minY - from.minY) * eased,
                              width: from.width + (destination.width - from.width) * eased,
                              height: from.height + (destination.height - from.height) * eased)
        panel.setFrame(cappedFrame(frame), display: true)
        guard fraction >= 1 else { return }
        self.motion = nil
        switch motion.destination {
        case .pointer: break
        case .paste, .slot:
            hide()
            motion.completion?()
        }
    }

    private func releaseCursor() {
        guard isHolding else { return }
        isHolding = false
        systemEffects?.setCursor(.arrow)
    }

    private func schedulePasteCompletion(at point: NSPoint) {
        guard isHolding, !pasteCompletionScheduled else { return }
        pasteCompletionScheduled = true
        let generation = presentationGeneration
        // Preserve the location of the actual paste even if the pointer moves
        // while the destination is consuming the fully materialized clipboard.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.presentationGeneration == generation, self.isHolding else { return }
            self.onPaste?(point)
        }
    }

    private func pointerFrame() -> NSRect {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? NSRect(x: pointer.x - 200, y: pointer.y - 200, width: 400, height: 400)
        let margin: CGFloat = 8
        let gap: CGFloat = 16
        let size = cappedSize(previewSize, scale: screen?.backingScaleFactor ?? 1)
        let x = min(max(pointer.x - size.width / 2, bounds.minX + margin),
                    max(bounds.minX + margin, bounds.maxX - size.width - margin))
        var y = pointer.y - size.height - gap
        if y < bounds.minY + margin {
            y = min(pointer.y + gap, bounds.maxY - size.height - margin)
        }
        return cappedFrame(NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height))
    }

    private func cappedSize(_ size: NSSize, scale: CGFloat) -> NSSize {
        let limit = maximumAttachmentPixels / max(1, scale)
        let factor = min(1, limit / max(1, size.width), limit / max(1, size.height))
        return NSSize(width: size.width * factor, height: size.height * factor)
    }

    private func cappedFrame(_ rect: NSRect) -> NSRect {
        // A preview crossing a display boundary must fit on both displays.
        let scale = NSScreen.screens.filter { $0.frame.intersects(rect) }
            .map(\.backingScaleFactor).max() ?? 1
        let size = cappedSize(rect.size, scale: scale)
        return NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

}
