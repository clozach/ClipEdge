import AppKit

final class ClipboardMagnetController {
    var quickLookHint = "⌃⌥Space"
    var onCancel: (() -> Void)?
    var onPaste: ((NSPoint) -> Void)?
    var onDrop: (() -> Void)?

    enum Presentation: Equatable { case hidden, small, carousel, drawer(ClipboardDrawerPreviewAnchor) }
    private(set) var presentation: Presentation = .hidden
    var isQuickLook: Bool {
        switch presentation { case .carousel, .drawer: return true; default: return false }
    }
    var drawerAnchor: ClipboardDrawerPreviewAnchor? {
        if case .drawer(let anchor) = presentation { return anchor }
        return nil
    }
    var isVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }
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
    /// What the small magnet was drawn from: late facts or a thumbnail redraw it.
    private var smallContent: (id: UUID, metadata: ClipboardMetadata, thumbnail: NSImage?)?
    // This is a rendered-pixel limit, including padding and the holding glyph.
    // Convert it to AppKit points using the display under the attachment.
    private var maximumAttachmentPixels: CGFloat { drawerAnchor != nil ? .greatestFiniteMagnitude : (isQuickLook ? 840 : 350) }
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

    init(pasteMonitor: PasteMonitor = PasteMonitor(), panel suppliedPanel: NSPanel? = nil,
         commandClickEnabled: Bool = true) {
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
        pasteMonitor.onPaste = { [weak self] point in self?.schedulePasteCompletion(at: point) }
        commandClick.onPaste = { [weak self] point in self?.schedulePasteCompletion(at: point) }
        commandClick.onDrop = { [weak self] in self?.onDrop?() }
        commandClick.onFailure = { NSSound.beep() }
        previousKey.onPress = { [weak self] in self?.onNavigate?(-1) }
        nextKey.onPress = { [weak self] in self?.onNavigate?(1) }
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
        NSCursor.closedHand.set()
        startTimer()
        pasteMonitor.start()
        if commandClickEnabled { commandClick.start() }
    }

    /// Disk facts and Quick Look thumbnails arrive after a copy has attached.
    func refreshSmall(_ entry: ClipboardEntry) {
        guard presentation == .small, let shown = smallContent, shown.id == entry.id,
              shown.metadata != entry.metadata || shown.thumbnail !== entry.thumbnail else { return }
        installSmallPreview(for: entry)
    }

    private func installSmallPreview(for entry: ClipboardEntry) {
        smallContent = (entry.id, entry.metadata, entry.thumbnail)
        let preview = ClipboardAttachmentView.makeHeldPreview(for: entry, maximumAttachmentPixels: maximumAttachmentPixels, holdingGlyphHeight: holdingGlyphHeight, shortcutHint: quickLookHint)
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
        let view = retainedView ?? ClipboardCarouselView(entry: entry, urls: urls, position: position, count: count)
        view.update(entry: entry, urls: urls, position: position, count: count)
        view.onNavigate = { [weak self] in self?.onNavigate?($0) }
        view.onClose = { [weak self] in self?.onCancel?() }
        previewSize = anchor?.frame.size ?? NSSize(width: 420, height: 340)
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
        if anchor == nil { _ = previousKey.register(); _ = nextKey.register() }
        if commandClickEnabled { commandClick.start() }
    }

    func updateDrawerAnchor(_ anchor: ClipboardDrawerPreviewAnchor) {
        guard drawerAnchor != nil, motion == nil else { return }
        presentation = .drawer(anchor)
        previewSize = anchor.frame.size
        panel.setFrame(anchor.frame, display: true)
        panel.contentView?.frame = NSRect(origin: .zero, size: previewSize)
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    func hide() {
        stopObservation()
        presentation = .hidden
        (panel.contentView as? ClipboardCarouselView)?.closePreview()
        panel.orderOut(nil)
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
        NSCursor.arrow.set()
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
