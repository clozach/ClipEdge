import AppKit

/// Card actions and their companion panels. Docking, visibility and motion stay in the controller.
extension ClipboardDrawerController {
    /// Tab on a tile: apps that can open it, then running apps to paste into.
    func showSendTo(_ entry: ClipboardEntry) {
        guard isVisible, let layout = dockLayout, let screen = targetScreen else { return }
        guard let targets = ClipboardSendTo.targets(for: entry, materializer: previewService.materializer, sources: sendSources) else { NSSound.beep(); return }
        ClipboardTileTooltip.shared.hide()
        let anchor = self.anchor(beside: layout, on: screen)
        let rowY = browser.screenFrame(for: entry.id)?.midY
        sendToPopover.view.onSend = { [weak self] target in self?.send(entry, to: target) }
        sendToPopover.show(targets) { anchor.frame(fitting: $0, centeredAtY: rowY) }
    }

    /// ⌥⌘A on a tile: the ask form opens where Send to does, beside the drawer.
    func showAskForPreview(_ entry: ClipboardEntry) {
        guard isVisible, let layout = dockLayout, let screen = targetScreen else { return }
        ClipboardTileTooltip.shared.hide()
        sendToPopover.close()
        let anchor = self.anchor(beside: layout, on: screen)
        let rowY = browser.screenFrame(for: entry.id)?.midY
        askPopover.show(entry) { anchor.frame(fitting: $0, centeredAtY: rowY) }
    }

    func send(_ entry: ClipboardEntry, to target: ClipboardSendTarget) {
        // Pasting into the app the drawer covered needs that app in front first.
        hide(animated: true)
        ClipboardSendTo.send(entry, to: target, paster: paster, sources: sendSources) { [weak self] error in self?.onError(error) }
    }

    func togglePreview(_ entry: ClipboardEntry) {
        if magnetController.isQuickLook, store.stagedEntryID == entry.id { store.cancelStaging() }
        else { store.previewInCarousel(entry, among: isVisible ? browser.visibleEntries : nil) }
    }

    /// I: Quick Look turns over when it shows the chosen card; otherwise it opens on that card, already
    /// turned to its raw data.
    func turnPreview(_ entry: ClipboardEntry) {
        if let carousel = magnetController.drawerCarousel, store.stagedEntryID == entry.id {
            carousel.turnOver()
            return
        }
        store.previewInCarousel(entry, among: browser.visibleEntries)
        magnetController.drawerCarousel?.turn(to: .back, animated: false)
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

    func movePreview(_ direction: Int) {
        guard let entry = store.moveCarousel(direction, among: isVisible ? browser.visibleEntries : nil) else { return }
        if isVisible { browser.reveal(entry.id) }
    }

    func refreshQuickLookPlacement() {
        guard magnetController.isQuickLook, store.carouselPosition != nil else { return }
        let candidates = isVisible ? browser.visibleEntries : store.entries
        guard let entry = candidates.first(where: { $0.id == store.stagedEntryID }) ?? candidates.first else {
            store.cancelStaging(); return
        }
        store.previewInCarousel(entry, among: candidates)
        if isVisible { browser.reveal(entry.id) }
    }

    func resetPreviewCycle() {
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

    func dismissAttachment() {
        store.cancelStaging()
    }

    /// Esc steps out one level: a held item, then marking (every mark let go), then the search, then the drawer.
    func dismissFromKeyboard() {
        if store.stagedEntryID != nil { dismissAttachment() }
        else if browser.list.endMarking() {}
        else if !browser.list.clearSearch(undo: panel.undoManager) { hide(animated: true) }
    }

    // MARK: Multi-select

    /// The selection's actions beside the drawer, level with Select, while anything is marked; out of
    /// the way while Quick Look's drawer magnet fills that room, back when it closes. Read on each
    /// change of the marks (and of Quick Look); the drawer moving only moves it (`placeSelectionPanel`).
    func refreshSelectionPanel() {
        let marked = browser.list.markedEntries
        guard isVisible, !marked.isEmpty, magnetController.drawerAnchor == nil, let anchor = previewAnchor else {
            selectionPopover.close(); return
        }
        ClipboardTileTooltip.shared.hide()
        let state = ClipboardSelectionPanel.State(count: marked.count, titles: marked.map(\.title), everyShownMarked: browser.list.everyShownMarked,
                                                  unavailable: ClipboardBulkActions.reasons(ClipboardSelectionPanel.catalog, marked))
        selectionPopover.show(state, place: selectionPlace(anchor))
    }

    /// The selection's actions follow the drawer, showing what they showed.
    func placeSelectionPanel() {
        guard let anchor = previewAnchor else { return }
        selectionPopover.place(selectionPlace(anchor))
    }

    /// Outside the drawer's edge, its top level with Select's where the display allows.
    func selectionPlace(_ anchor: ClipboardDrawerPreviewAnchor) -> (NSSize) -> NSRect {
        let select = browser.selectButton
        let top = select.window.map { $0.convertToScreen(select.convert(select.bounds, to: nil)).maxY }
        return { size in anchor.frame(fitting: size, centeredAtY: top.map { $0 - size.height / 2 }) }
    }

    /// The selection's actions on the marked cards, alike from their keys and the panel's buttons.
    /// The drawer stays open; its delete asks in its alert.
    func performOnMarks(_ action: ClipboardBrowserAction, _ marked: [ClipboardEntry]) -> Bool {
        guard ClipboardBulkActions.unavailable(action, marked) == nil else { NSSound.beep(); return true }
        switch action {
        case .pickUp:
            resetPreviewCycle()
            browser.list.endMarking()
            ClipboardBulkActions.copy(marked, to: store)
        case .open:
            resetPreviewCycle()
            ClipboardBulkActions.open(marked, with: openInPreview) { [weak self] error in self?.onError(error) }
        case .delete: confirmDelete(marked)
        default: return false
        }
        return true
    }

    /// 🚨 Asks before deleting for good, with a modal alert; true deletes. Fixtures answer it themselves.

    /// The menu bar's Clear History, its one way in: the drawer's Clear… and the window's Delete all
    /// were retired so deleting everything is never one press away (Al, 2026-10-12).
    func confirmClear() {
        guard !store.entries.isEmpty else { NSSound.beep(); return }
        let deletion = ClipboardDeletion.all(count: store.entries.count)
        guard ask(deletion.question, deletion.consequence) else { return }
        ClipboardDeletion.removeAll(from: store, failed: onError)
    }

    func confirmDelete(_ entry: ClipboardEntry) {
        guard ask(.one) else { return }
        ClipboardDeletion.remove(entry, from: store, choosingIn: browser.canvas, failed: onError)
    }

    /// 🚨 The marked cards, asked about in the alert with their count. Only those still marked, still
    /// shown and still in the history once it is answered are deleted (the history keeps changing
    /// while an alert waits); then marking ends and the card in the first one's place is chosen.
    func confirmDelete(_ marked: [ClipboardEntry]) {
        guard ask(.marked(count: marked.count)) else { return }
        let asked = Set(marked.map(\.id))
        ClipboardDeletion.remove(browser.list.markedEntries.filter { asked.contains($0.id) }, from: store,
                                 choosingIn: browser.canvas, failed: onError)
        browser.list.endMarking()
    }

    /// The alert's Delete Permanently answers a second ⌘⌫; Esc keeps, unsaid.
    func ask(_ deletion: ClipboardDeletion) -> Bool {
        let keys = deletion.keys(confirm: ClipboardKeyLabel(shown: Self.confirmKey, spoken: "Command-Delete")).plain
        return ask(deletion.question, [deletion.consequence, keys].joined(separator: "\n\n"))
    }

    func ask(_ question: String, _ detail: String) -> Bool {
        resetPreviewCycle()
        isConfirmingDeletion = true
        defer { isConfirmingDeletion = false }
        return confirmDeletion(question, detail)
    }

    static func askByAlert(_ question: String, _ detail: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = question
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        acceptCommandDelete(alert.addButton(withTitle: "Delete Permanently"))
        return ignoringRepeats { alert.runModal() } == .alertSecondButtonReturn
    }

    /// 🚨 A key press a waiting deletion question may answer: nil for a held key's repeat. The ⌘⌫ that
    /// opened the alert may still be held, and its repeats are not the second press that confirms.
    static func answerable(_ event: NSEvent) -> NSEvent? { event.isARepeat ? nil : event }
    /// Runs `question` (a modal alert) with held keys' repeats kept from it.
    static func ignoringRepeats<Answer>(_ question: () -> Answer) -> Answer {
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { answerable($0) }
        defer { monitor.map(NSEvent.removeMonitor) }
        return question()
    }

    /// A second ⌘⌫ confirms a deletion; Return and Esc still cancel.
    static let confirmKey = "⌘⌫"
    static func acceptCommandDelete(_ button: NSButton) {
        button.keyEquivalent = "\u{7F}"
        button.keyEquivalentModifierMask = .command
    }

    /// Settings › Cursor magnets › From the drawer: with it off, picking a tile just makes it current.

    func pick(_ entry: ClipboardEntry) {
        if ClipboardPickup.pick(entry, from: .drawer, showsMagnet: pickupMagnet(), store: store) == .madeCurrent { browser.reveal(entry.id) }
    }

    func open(_ entry: ClipboardEntry) {
        resetPreviewCycle()
        openInPreview(entry) { [weak self] error in if let error { self?.onError(error) } }
    }
}
