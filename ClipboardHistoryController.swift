import AppKit

/// The ⌥⌘\ clipboard-history window: find an entry by keyboard and paste it
/// into the app you were in. The window takes the keyboard without activating
/// ClipEdge, so that app stays in front and receives the paste. Typing goes to
/// the search field; the keys in its keymap (ClipboardKeymap.window) act on the selection.
final class ClipboardHistoryController: NSObject {
    static let preferredSize = NSSize(width: 800, height: 470)
    let view: ClipboardHistoryView
    /// Runs as the window opens: closes other ClipEdge surfaces and names the
    /// app that Return pastes into.
    var prepare: () -> ClipboardPaster.Target? = { ClipboardPaster.frontmostTarget() }
    var sendSources = ClipboardSendTo.Sources()
    var openInPreview: (ClipboardEntry, @escaping (Error?) -> Void) -> Void
    /// How a failed action is shown.
    var onError: (Error) -> Void = ClipboardErrorAlert.show
    var onShow: (() -> Void)?
    /// Settings › Cursor magnets › From the window: with it off, ⌘C just makes the entry current.
    var pickupMagnet: () -> Bool = { true }
    /// Maintainer copies only: ⌥⌘A and the footer's Ask for a preview. Nil hides both. Kept by the
    /// list, as the drawer's is.
    var previewAsker: ClipboardPreviewAsker? {
        get { view.list.previewAsker }
        set { view.list.previewAsker = newValue; view.askView.asker = newValue; if isVisible { refreshFooter() } }
    }
    private let store: ClipboardStore
    private let paster: ClipboardPaster
    private let materializer: ClipboardMaterializer
    private let panel: NSPanel
    /// Only one thing can be waiting for its second delete press: a row, or the marked cards it
    /// asked about (multi-select), in the order shown.
    private enum Armed: Equatable { case none, row(UUID), marks([UUID]) }
    private enum Mode { case hidden, browsing(Armed), sending(ClipboardEntry), asking(ClipboardEntry) }
    private var mode = Mode.hidden { didSet { view.canvas.refreshArming() } }
    private var returnTarget: ClipboardPaster.Target?
    private var observers: [NSObjectProtocol] = []
    private var keyMonitor: Any?

    var isVisible: Bool { if case .hidden = mode { return false }; return true }
    var isSending: Bool { if case .sending = mode { return true }; return false }
    var isAsking: Bool { if case .asking = mode { return true }; return false }
    var selectedEntry: ClipboardEntry? { view.canvas.selected?.entry }
    var visibleEntries: [ClipboardEntry] { view.list.visibleEntries }
    var frame: NSRect { panel.frame }
    var holdsKeyboard: Bool { isVisible && panel.isKeyWindow }

    init(store: ClipboardStore, paster: ClipboardPaster, previewService: ClipboardPreviewService, panel suppliedPanel: NSPanel? = nil,
         keymap: ClipboardKeymap = .window) {
        view = ClipboardHistoryView(frame: NSRect(origin: .zero, size: Self.preferredSize), keymap: keymap)
        self.store = store
        self.paster = paster
        materializer = previewService.materializer
        openInPreview = previewService.openInPreview
        panel = suppliedPanel ?? ClipboardWindow(contentRect: NSRect(origin: .zero, size: Self.preferredSize),
                                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.title = "ClipEdge History"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.contentView = view
        configureActions()
        observers.append(NotificationCenter.default.addObserver(forName: ClipboardStore.didChange, object: store, queue: nil) { [weak self] _ in
            self?.reload()
        })
        // Clicking elsewhere or switching apps dismisses; applying nothing here does.
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: nil) { [weak self] _ in
            self?.close()
        })
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event) == true ? nil : event
        }
    }
    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    /// The first press opens with the newest entry selected; each further press
    /// selects the next older one in the visible list, wrapping at the end.
    func hotKeyPressed() {
        switch mode {
        case .hidden: show()
        case .browsing: disarm(); view.canvas.step(.older, ends: .wrap)
        case .sending: view.sendTo.move(1, ends: .wrap)
        case .asking: break
        }
    }

    /// Each opening starts from All, an empty search and the newest entry, so
    /// a search left from before never hides what was just copied.
    func show() {
        onShow?()
        store.cancelStaging()
        returnTarget = prepare()
        mode = .browsing(.none)
        view.startOnFront()
        view.showCard()
        refreshFooter()
        view.list.startFresh(.all, undo: panel.undoManager)
        let screen = NSScreen.main ?? NSScreen.screens[0]
        view.list.thumbnailScale = sizes().thumbnailScale
        panel.setFrame(Self.frame(in: screen.visibleFrame, scale: sizes().textScale), display: false)
        ClipboardZoom.apply(sizes().textScale, to: view)
        panel.makeKeyAndOrderFront(nil)
        view.list.focusHome(in: panel)
    }

    /// The keyboard goes back to the app in front: see ClipboardWindow.orderOutReturningKeyboard.
    func close() {
        guard isVisible else { return }
        mode = .hidden
        // The back lets go of what it read: nothing of an entry deleted while the window is closed stays.
        view.raw.show(nil)
        ClipboardWindow.orderOutReturningKeyboard(panel)
    }

    /// How large it draws: its content zooms by the text size, its window growing with it (its layout
    /// unchanged); its rows' thumbnails follow theirs. Settings supplies it; `applySizes()` after a change.
    var sizes: () -> ClipboardSizes = { .standard }

    /// Settings' sizes changed while the window shows: it grows or shrinks about its middle.
    func applySizes() {
        view.list.thumbnailScale = sizes().thumbnailScale
        guard isVisible, let screen = panel.screen ?? NSScreen.main else { return }
        var frame = Self.frame(in: screen.visibleFrame, scale: sizes().textScale)
        frame.origin = NSPoint(x: floor(panel.frame.midX - frame.width / 2), y: floor(panel.frame.maxY - frame.height))
        let usable = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        frame.origin.x = min(max(frame.minX, usable.minX), usable.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, usable.minY), usable.maxY - frame.height)
        panel.setFrame(frame, display: false)
        ClipboardZoom.apply(sizes().textScale, to: view)
        view.needsLayout = true
    }

    /// Centered a little above the middle, its preferred size times the text size, and never larger
    /// than the display.
    static func frame(in visible: NSRect, scale: CGFloat = 1) -> NSRect {
        let usable = visible.insetBy(dx: 8, dy: 8)
        let size = NSSize(width: min(preferredSize.width * scale, usable.width), height: min(preferredSize.height * scale, usable.height))
        let y = min(usable.midY - size.height / 2 + usable.height * 0.06, usable.maxY - size.height)
        return NSRect(x: floor(usable.midX - size.width / 2), y: floor(y), width: floor(size.width), height: floor(size.height))
    }

    /// The window's keys while browsing, through the list the drawer's keys go through too. Anything
    /// its keymap doesn't name is typing for the search field. Shared with fixture tests; no input
    /// is synthesized.
    func handleKey(_ event: NSEvent) -> Bool {
        guard isVisible, panel.isKeyWindow else { return false }
        if view.publishControl.handleKey(event) { return true }
        guard case .browsing = mode else { return false }
        // The raw data's text being read takes ⌘C (with a selection) and ⌘A before the window's keys,
        // and keeps the keys that move its caret and, with ⇧, select (not the rows' ↑ ↓ or ⇧↑ ⇧↓).
        if view.showsRawData, view.raw.handleEditingKey(event) { disarm(); return true }
        if view.raw.holdsKeyboard, ClipboardRawDataView.isTextNavigation(event) { disarm(); return false }
        // Any key but the delete keys and Esc lets go of a waiting delete, typing included: a row's,
        // or the marked cards'.
        if view.list.handleKey(event, in: panel, heard: { action in
            if action != .delete && action != .escape { disarm() }
        }) { return true }
        // Typing while the raw data's text holds the keyboard goes to the search, the window's home
        // for typing: the key goes on to it.
        if view.raw.holdsKeyboard, Self.isTyping(event) { view.returnKeyboardFromRaw() }
        return false
    }

    /// A key that types or erases: a character with neither ⌘ nor ⌃, or ⌫.
    static func isTyping(_ event: NSEvent) -> Bool {
        guard event.chordModifiers.isDisjoint(with: [.command, .control]) else { return false }
        if event.keyCode == 51 { return true }
        guard let scalar = event.characters?.unicodeScalars.first else { return false }
        return !CharacterSet.controlCharacters.contains(scalar) && !(0xF700...0xF8FF).contains(scalar.value)
    }

    /// The window's answer to an action from its keys, a click on a row or a footer button;
    /// `entry` is the selected row's. False passes it on: to the list (the find key, a tab's key),
    /// then to the search.
    private func perform(_ action: ClipboardBrowserAction, on entry: ClipboardEntry?) -> Bool {
        switch action {
        case .newer, .older, .previousRow, .nextRow:
            // Arrows stop at the ends; the history shortcut wraps.
            view.canvas.step(action)
        case .escape: escape()
        case .flip:
            // While the selection's actions hold the card's place, there is no card to turn.
            guard view.showsCard, entry != nil || view.flip.side == .back else { NSSound.beep(); return true }
            turnCard(to: view.flip.side.other)
        case .copyFlavor(let number):
            // Only while the card shows its raw data; otherwise ⌥1–⌥9 type in the search, as ever.
            guard view.showsRawData else { return false }
            if !view.raw.copyFlavor(number: number) { NSSound.beep() }
        case .selectRawText:
            // ⌘T: the keyboard to the back's next text, to read and select; on the front it goes on.
            guard view.showsRawData else { return false }
            if !view.raw.selectNextText() { NSSound.beep() }
            refreshHint()
        case .pageUp, .pageDown:
            guard view.showsRawData else { return false }
            view.raw.page(action == .pageUp ? .up : .down)
        case .ignore: break
        // The list's own: the search, the tabs and the marks.
        case .find, .tab, .selecting, .markAll, .extendNewer, .extendOlder: return false
        case .ask:
            // In ordinary and released copies the key does nothing.
            guard previewAsker != nil else { return true }
            guard let entry else { NSSound.beep(); return true }
            beginAsk(entry)
        case .primary, .plainPaste, .pickUp, .sendTo, .open, .delete:
            guard let entry else { NSSound.beep(); return true }
            switch action {
            case .primary: paste(entry, plain: false)
            case .plainPaste: paste(entry, plain: true)
            case .pickUp: pickUp(entry)
            case .sendTo: beginSendTo(entry)
            case .open: open(entry)
            default: requestDelete(entry)
            }
        // Not the window's: its card shows the item whole, and Settings opens from the menu.
        case .quickLook, .settings: return false
        }
        return true
    }

    private func configureActions() {
        view.list.onFilterChange = { [weak self] change in
            switch change {
            case .query: self?.queryChanged()
            case .tab: self?.reload()
            }
        }
        view.canvas.armed = { [weak self] in self?.armedRow }
        view.canvas.onSelect = { [weak self] entry in
            self?.view.showEntry(entry)
            self?.disarmUnlessChosen()
        }
        // A part copied from the card's back joins the history as any copy does.
        view.raw.copier = { [weak self] part in self?.store.copy(part) ?? false }
        // Esc's next rung changes as the back's text takes the keyboard or lets it go.
        view.raw.onKeyboardChange = { [weak self] in self?.refreshHint() }
        view.flipMagnet.onPress = { [weak self] in
            guard let self else { return }
            _ = self.view.list.answer(.flip, on: self.selectedEntry)
        }
        view.list.perform = { [weak self] action, entry in self?.perform(action, on: entry) ?? false }
        view.list.onMarkingChange = { [weak self] in self?.markingChanged() }
        view.list.performOnMarks = { [weak self] action, marked in self?.performOnMarks(action, marked) ?? false }
        view.list.storageReport = { [weak self] in self?.store.storageReport }
        view.selectionPanel.onAction = { [weak self] action in
            guard let self else { return }
            _ = self.view.list.answer(action, on: self.selectedEntry)
        }
        view.sendTo.onBack = { [weak self] in self?.endSendTo() }
        view.sendTo.onSend = { [weak self] target in self?.send(to: target) }
        view.askView.onBack = { [weak self] in self?.endAsk() }
    }

    /// The footer's buttons: each action the window's keymap gives a key, titled with it.
    private static let footerActions: [(ClipboardBrowserAction, String, (String) -> String)] = [
        (.primary, "Paste", { "Paste the selected item where you were (\($0))" }),
        (.plainPaste, "Plain text", { "Paste as plain text (\($0))" }),
        (.pickUp, "Copy", { "Put it on the clipboard without pasting (\($0)). With cursor magnets on for the window, it rides the cursor until you paste." }),
        (.sendTo, "Send to", { "Open it in an app, or paste it into a running app (\($0))" }),
        (.open, "Open in Preview", { "Open in the Preview app (\($0))" }),
        // Named for the side it turns to: Raw data, or Preview while the card is turned.
        (.flip, "Raw data", { "\(ClipboardFlipButton.help(for: .front)) (\($0))" }),
        (.delete, "Delete", { "Delete permanently: press \($0) twice" }),
        (.ask, "Ask for a preview", { "Write a brief for a better preview of this kind of copy into the vault (\($0))" })
    ]

    private func refreshFooter() {
        if isSending {
            view.footer.items = [
                .init(title: ClipboardKeyedTitle(name: "Send", key: ClipboardKeyLabel(shown: "⏎", spoken: "Return")), help: "Send to the selected app (Return)") { [weak self] in
                    if let target = self?.view.sendTo.selected { self?.send(to: target) }
                },
                .init(title: ClipboardKeyedTitle(name: "Back", key: ClipboardKeyLabel(shown: "←", spoken: "Left Arrow")), help: "Back to the clipboard history (Left Arrow)") { [weak self] in self?.endSendTo() }
            ]
            view.footer.hint = .key(ClipboardKeyLabel(shown: "↑", spoken: "Up Arrow")) + " " + .key(ClipboardKeyLabel(shown: "↓", spoken: "Down Arrow")) + " choose  ·  type a name to jump"
            return
        }
        if isAsking {
            // The form carries its own buttons and their chords; Esc going back is never explained.
            view.footer.items = []
            view.footer.hint = ClipboardHint([])
            return
        }
        // While marking, the selection's actions are in the panel beside the list; the hint says how to mark.
        if view.list.marking.isOn {
            view.footer.items = []
            refreshHint()
            return
        }
        let keymap = view.keymap
        let side = view.flip.side
        view.footer.items = Self.footerActions.compactMap { action, name, help in
            guard action != .ask || previewAsker != nil, let spoken = keymap.spoken(action) else { return nil }
            let turned = action == .flip && side == .back
            return .init(title: keymap.keyed(turned ? ClipboardFlipButton.name(for: side) : name, action),
                         help: turned ? "\(ClipboardFlipButton.help(for: side)) (\(spoken))" : help(spoken)) { [weak self] in
                guard let self else { return }
                _ = self.view.list.answer(action, on: self.selectedEntry)
            }
        }
        refreshHint()
    }

    /// The keys beside the footer's buttons: how to mark while marking, how to read the back by
    /// key while it shows, otherwise the older-item shortcut. Esc is never explained (vault rule,
    /// 2026-10-16): its rungs (a waiting delete, the back's text, the card, selecting, the search,
    /// the window) still go one at a time.
    private func refreshHint() {
        guard isVisible, !isSending, !isAsking else { return }
        let keymap = view.keymap, marking = view.list.marking.isOn
        let reading: [ClipboardHint?] = view.showsRawData && !marking
            ? [keymap.key(.selectRawText).map { .key($0) + " selects text" },
               keymap.key(.pageUp).flatMap { up in keymap.key(.pageDown).map { .key(up) + " " + .key($0) + " scroll" } }] : []
        let older = ClipboardKeyLabel(shown: ClipboardShortcut.history.displayString, spoken: ClipboardShortcut.history.accessibilityDescription)
        let lead: [ClipboardHint] = marking
            ? [(keymap.key(.primary).map { .key($0) + " or click" } ?? "click") + " selects", keymap.key(.markAll).map { .key($0) + " all" }].compactMap { $0 }
            : [.key(older) + " older"] + reading.compactMap { $0 }
        view.footer.hint = .joined(lead, separator: "  ·  ")
    }

    // MARK: Selection and filtering

    private func reload(selectFirst: Bool = false) {
        guard isVisible else { return }
        view.update(entries: store.entries)
        if selectFirst, let first = view.canvas.tiles.first { view.canvas.choose(first.entry.id) }
        // A tab or a change in the history can take the selection off a row waiting to be deleted
        // (the marks it asked about are let go as the list prunes them).
        disarmUnlessChosen()
        if case .sending(let entry) = mode, !store.entries.contains(where: { $0.id == entry.id }) { endSendTo() }
        if case .asking(let entry) = mode, !store.entries.contains(where: { $0.id == entry.id }) { endAsk() }
        refreshHint()
    }

    /// A new search selects its newest match, as each letter is typed.
    private func queryChanged() {
        disarm()
        reload(selectFirst: true)
    }

    /// Esc steps out one level: a waiting delete, then the back's text (the keyboard goes back to the
    /// search), then the card's raw data (it turns back), then marking (every mark let go), then the
    /// search (and its typing's undo, as the drawer's Esc empties it), then the window.
    private func escape() {
        if isArmed { disarm() }
        else if view.raw.holdsKeyboard { view.returnKeyboardFromRaw(); refreshHint() }
        else if view.showsRawData { turnCard(to: .front) }
        else if view.list.endMarking() {}
        else if !view.list.clearSearch(undo: panel.undoManager) { close() }
    }

    // MARK: The card's raw data

    /// ⌘I, its magnet or its footer item: the card turns, and the footer and its hint say what the
    /// keys do on the side it turns to.
    private func turnCard(to side: ClipboardFlipView.Side) {
        view.turnCard(to: side)
        refreshFooter()
    }

    // MARK: Multi-select

    /// The marks changed: a delete waiting on other marks lets go, as does a row's once marking is
    /// on; marking takes the place Send to and the ask form would have; the space beside the list,
    /// the footer and its hint follow.
    private func markingChanged() {
        let marking = view.list.marking
        switch mode {
        case .browsing(.marks(let asked)) where asked != view.list.markedEntries.map(\.id): mode = .browsing(.none)
        case .browsing(.row) where marking.isOn: mode = .browsing(.none)
        default: break
        }
        if marking.isOn { endSendTo(); endAsk() }
        refreshSide()
        refreshFooter()
    }

    /// Beside the list while browsing: the selection's actions once anything is marked, its heading
    /// the question while a delete waits on them; otherwise the card.
    private func refreshSide() {
        guard case .browsing(let armed) = mode else { return }
        let marked = view.list.markedEntries
        guard !marked.isEmpty else { view.showCard(); return }
        // The shared reasons, each entry's text read once for all of them, and the window's own.
        var reasons = ClipboardBulkActions.reasons(ClipboardSelectionPanel.catalog, marked)
        for action in ClipboardSelectionPanel.catalog where reasons[action] == nil { reasons[action] = ownReason(action) }
        let asking: Bool = { if case .marks = armed { return true }; return false }()
        view.showSelection(.init(count: marked.count, titles: marked.map(\.title), everyShownMarked: view.list.everyShownMarked,
                                 askingToDelete: asking, unavailable: reasons))
    }

    /// Why one of the selection's actions cannot act now, nil when it can: the shared reasons, and
    /// the window's own (Paste as text needs an app to paste into).
    private func unavailable(_ action: ClipboardBrowserAction, _ marked: [ClipboardEntry]) -> String? {
        ClipboardBulkActions.unavailable(action, marked) ?? ownReason(action)
    }
    /// The window's own reason, beside the shared ones: Paste as text needs an app to paste into.
    private func ownReason(_ action: ClipboardBrowserAction) -> String? {
        action == .plainPaste && returnTarget == nil ? "There is no app to paste into: the window opened over ClipEdge itself." : nil
    }

    /// The selection's actions on the marked cards, alike from their keys and the panel's buttons.
    /// Copy, paste and open close the window first, as ⌘C, ⌃⌘⏎ and ⌘O do for one; a delete asks.
    private func performOnMarks(_ action: ClipboardBrowserAction, _ marked: [ClipboardEntry]) -> Bool {
        guard unavailable(action, marked) == nil else { NSSound.beep(); return true }
        switch action {
        case .pickUp:
            view.list.endMarking()
            close()
            ClipboardBulkActions.copy(marked, to: store)
        case .plainPaste:
            let target = returnTarget, text = ClipboardBulkActions.text(marked)
            view.list.endMarking()
            close()
            paster.pasteText(text, into: target)
        case .open:
            close()
            ClipboardBulkActions.open(marked, with: openInPreview) { [weak self] error in self?.onError(error) }
        case .delete: requestDelete(marked)
        default: return false
        }
        return true
    }

    // MARK: Actions

    private func paste(_ entry: ClipboardEntry, plain: Bool) {
        let target = returnTarget
        close()
        paster.paste(entry, into: target, plain: plain)
    }

    /// The keyboard's pickup: the entry goes on the clipboard and rides the
    /// cursor magnet. Pasting moves it to the top; Esc restores the clipboard.
    /// With window magnets off it just becomes the clipboard's current item.
    private func pickUp(_ entry: ClipboardEntry) {
        close()
        ClipboardPickup.pick(entry, from: .window, showsMagnet: pickupMagnet(), store: store)
    }

    private func open(_ entry: ClipboardEntry) {
        close()
        openInPreview(entry) { [weak self] error in if let error { self?.onError(error) } }
    }

    private func beginSendTo(_ entry: ClipboardEntry) {
        guard let targets = ClipboardSendTo.targets(for: entry, materializer: materializer, sources: sendSources) else { NSSound.beep(); return }
        mode = .sending(entry)
        view.showSendTo(targets)
        refreshFooter()
        panel.makeFirstResponder(view.sendTo)
    }

    private func endSendTo() {
        guard isSending else { return }
        mode = .browsing(.none)
        refreshSide()
        refreshFooter()
        view.list.focusHome(in: panel)
    }

    private func send(to target: ClipboardSendTarget) {
        guard case .sending(let entry) = mode else { return }
        close()
        ClipboardSendTo.send(entry, to: target, paster: paster, sources: sendSources) { [weak self] error in self?.onError(error) }
    }

    /// ⌥⌘A: the ask form takes the card's place, as Send to does.
    private func beginAsk(_ entry: ClipboardEntry) {
        guard previewAsker != nil else { return }
        mode = .asking(entry)
        view.showAsk(for: entry)
        refreshFooter()
    }

    private func endAsk() {
        guard isAsking else { return }
        mode = .browsing(.none)
        refreshSide()
        refreshFooter()
        view.list.focusHome(in: panel)
    }

    // MARK: Deleting — 🚨 cannot be undone, so the first press only asks

    private var isArmed: Bool { if case .browsing(let armed) = mode { return armed != .none }; return false }
    /// Whether the selection's delete waits for its second press (fixtures read it).
    var isAskingToDeleteMarks: Bool { if case .browsing(.marks) = mode { return true }; return false }
    /// The row whose delete waits for a second ⌘⌫, kept only here; its row reads it, so whatever
    /// lets go of it here lets go of the row's question and the footer's hint with it.
    private var armedRow: UUID? { if case .browsing(.row(let id)) = mode { return id }; return nil }

    /// A delete waits only on the chosen row: choosing another, by key, pointer, tab or search,
    /// lets go of it, so a later ⌘⌫ back on that row asks again.
    private func disarmUnlessChosen() {
        if let row = armedRow, row != view.canvas.selectedID { disarm() }
    }

    private func disarm() {
        guard isArmed else { return }
        mode = .browsing(.none)
        refreshSide()
        refreshHint()
    }

    private func requestDelete(_ entry: ClipboardEntry) {
        guard case .browsing(.row(entry.id)) = mode else {
            mode = .browsing(.row(entry.id))
            refreshHint()
            return
        }
        mode = .browsing(.none)
        ClipboardDeletion.remove(entry, from: store, choosingIn: view.canvas, failed: onError)
        refreshHint()
    }

    /// 🚨 The marked cards: the first ⌘⌫ (or Delete N…) turns the panel's heading into the question
    /// and deletes nothing; a second deletes the cards it asked about, and only if they are still the
    /// ones marked: anything that changes the marks between the presses (a search, a tab, a copy
    /// pushing one out of the history) lets go of the question. Marking then ends and the card that
    /// moved into the first one's place is chosen.
    private func requestDelete(_ marked: [ClipboardEntry]) {
        let ids = marked.map(\.id)
        guard case .browsing(.marks(let asked)) = mode, asked == ids else {
            mode = .browsing(.marks(ids))
            refreshSide()
            refreshHint()
            return
        }
        mode = .browsing(.none)
        ClipboardDeletion.remove(marked, from: store, choosingIn: view.canvas, failed: onError)
        view.list.endMarking()
        refreshSide()
        refreshHint()
    }
}
