import AppKit

/// The ⌥⌘\ clipboard-history window: find an entry by keyboard and paste it
/// into the app you were in. The window takes the keyboard without activating
/// ClipEdge, so that app stays in front and receives the paste. Typing goes to
/// the search field; the keys in ClipboardHistoryCommand act on the selection.
final class ClipboardHistoryController: NSObject, NSSearchFieldDelegate {
    static let preferredSize = NSSize(width: 800, height: 470)
    let view = ClipboardHistoryView(frame: NSRect(origin: .zero, size: ClipboardHistoryController.preferredSize))
    /// Runs as the window opens: closes other ClipEdge surfaces and names the
    /// app that Return pastes into.
    var prepare: () -> ClipboardPaster.Target? = { ClipboardPaster.frontmostTarget() }
    var sendSources = ClipboardSendTo.Sources()
    var openInPreview: (ClipboardEntry, @escaping (Error?) -> Void) -> Void
    var onError: ((Error) -> Void)?
    private let store: ClipboardStore
    private let paster: ClipboardPaster
    private let recall: ClipboardRecallMemory
    private let materializer: ClipboardMaterializer
    private let panel: NSPanel
    /// Only one thing can be waiting for its second delete press.
    private enum Armed: Equatable { case none, row(UUID), all }
    private enum Mode { case hidden, browsing(Armed), sending(ClipboardEntry) }
    private var mode = Mode.hidden { didSet { reflectArming() } }
    private var returnTarget: ClipboardPaster.Target?
    private var observers: [NSObjectProtocol] = []
    private var keyMonitor: Any?

    var isVisible: Bool { if case .hidden = mode { return false }; return true }
    var isSending: Bool { if case .sending = mode { return true }; return false }
    var isConfirmingDeleteAll: Bool { if case .browsing(.all) = mode { return true }; return false }
    var selectedEntry: ClipboardEntry? { view.canvas.selected?.entry }
    var visibleEntries: [ClipboardEntry] { view.currentTab.visible(store.entries, query: view.search.stringValue) }
    var frame: NSRect { panel.frame }
    var holdsKeyboard: Bool { isVisible && panel.isKeyWindow }

    init(store: ClipboardStore, paster: ClipboardPaster, previewService: ClipboardPreviewService,
         recall: ClipboardRecallMemory = ClipboardRecallMemory(minutes: { 0 }), panel suppliedPanel: NSPanel? = nil) {
        self.store = store
        self.paster = paster
        self.recall = recall
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
        case .browsing: disarm(); step(1, wrapping: true)
        case .sending: view.sendTo.move(1, wrapping: true)
        }
    }

    /// Each opening starts from All, an empty search and the newest entry, or,
    /// within the Reopen setting, from the last use: its tab and search, selected
    /// so typing replaces it, with that entry chosen.
    func show() {
        store.cancelStaging()
        returnTarget = prepare()
        let recalled = recall.recall()
        view.search.stringValue = recalled?.search ?? ""
        view.tabs.selectedSegment = (recalled?.tab ?? .all).rawValue
        mode = .browsing(.none)
        view.showCard()
        refreshFooter()
        reload(selectFirst: true)
        if let id = recalled?.entryID, view.canvas.tiles.contains(where: { $0.entry.id == id }) { view.canvas.choose(id) }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        panel.setFrame(Self.frame(in: screen.visibleFrame), display: true)
        panel.makeKeyAndOrderFront(nil)
        focusSearch(selectingAll: recalled != nil)
    }

    func close() {
        guard isVisible else { return }
        mode = .hidden
        panel.orderOut(nil)
    }

    /// Centered a little above the middle, and never larger than the display.
    static func frame(in visible: NSRect) -> NSRect {
        let usable = visible.insetBy(dx: 8, dy: 8)
        let size = NSSize(width: min(preferredSize.width, usable.width), height: min(preferredSize.height, usable.height))
        let y = min(usable.midY - size.height / 2 + usable.height * 0.06, usable.maxY - size.height)
        return NSRect(x: floor(usable.midX - size.width / 2), y: floor(y), width: floor(size.width), height: floor(size.height))
    }

    /// The window's keys while browsing. Anything without a command is typing
    /// for the search field. Shared with fixture tests; no input is synthesized.
    func handleKey(_ event: NSEvent) -> Bool {
        guard case .browsing = mode, panel.isKeyWindow else { return false }
        guard let command = ClipboardHistoryCommand.command(for: event) else { disarm(); return false }
        if command != .delete && command != .deleteAll && command != .escape { disarm() }
        let selected = selectedEntry
        switch command {
        case .newer: step(-1, wrapping: false)
        case .older: step(1, wrapping: false)
        case .escape: escape()
        case .tab(let tab): select(tab)
        case .deleteAll: requestDeleteAll()
        case .ignore: break
        case .find: focusSearch(selectingAll: true)
        case .paste, .plainPaste, .pickUp, .sendTo, .openInPreview, .delete:
            guard let entry = selected else { NSSound.beep(); return true }
            switch command {
            case .paste: paste(entry, plain: false)
            case .plainPaste: paste(entry, plain: true)
            case .pickUp: pickUp(entry)
            case .sendTo: beginSendTo(entry)
            case .openInPreview: open(entry)
            default: requestDelete(entry)
            }
        }
        return true
    }

    func controlTextDidChange(_ obj: Notification) { queryChanged() }

    private func configureActions() {
        view.search.delegate = self
        view.search.target = self
        view.search.action = #selector(queryChanged) // Also the field's clear button.
        view.tabs.target = self
        view.tabs.action = #selector(tabClicked)
        view.deleteAll.target = self
        view.deleteAll.action = #selector(deleteAllClicked)
        let canvas = view.canvas
        canvas.onSelect = { [weak self] entry in self?.view.card.show(entry) }
        canvas.onPick = { [weak self] entry in self?.paste(entry, plain: false) }
        view.sendTo.onBack = { [weak self] in self?.endSendTo() }
        view.sendTo.onSend = { [weak self] target in self?.send(to: target) }
    }

    private func refreshFooter() {
        let onSelected: (@escaping (ClipboardEntry) -> Void) -> () -> Void = { [weak self] action in
            { if let entry = self?.selectedEntry { action(entry) } else { NSSound.beep() } }
        }
        if isSending {
            view.footer.items = [
                .init(title: "Send ⏎", help: "Send to the selected app (Return)") { [weak self] in
                    if let target = self?.view.sendTo.selected { self?.send(to: target) }
                },
                .init(title: "Back ←", help: "Back to the clipboard history (Left Arrow or Escape)") { [weak self] in self?.endSendTo() }
            ]
            view.footer.hint = "↑ ↓ choose  ·  type a name to jump"
            return
        }
        view.footer.items = [
            .init(title: "Paste ⏎", help: "Paste the selected item where you were (Return)", action: onSelected { [weak self] in self?.paste($0, plain: false) }),
            .init(title: "Plain text ⌃⌘⏎", help: "Paste as plain text (Control-Command-Return)", action: onSelected { [weak self] in self?.paste($0, plain: true) }),
            .init(title: "Copy ⌘C", help: "Put it on the clipboard without pasting (Command-C). It rides the cursor until you paste or press Escape, which brings back the previous clipboard.", action: onSelected { [weak self] in self?.pickUp($0) }),
            .init(title: "Send to ⇥", help: "Open it in an app, or paste it into a running app (Tab)", action: onSelected { [weak self] in self?.beginSendTo($0) }),
            .init(title: "Open in Preview ⌘O", help: "Open in the Preview app (Command-O)", action: onSelected { [weak self] in self?.open($0) }),
            .init(title: "Delete ⌘⌫", help: "Delete permanently: press Command-Delete twice", action: onSelected { [weak self] in self?.requestDelete($0) })
        ]
        refreshHint()
    }

    private func refreshHint() {
        guard !isSending else { return }
        view.footer.hint = "\(ClipboardShortcut.history.displayString) older  ·  esc " +
            (isArmed ? "keeps" : (view.search.stringValue.isEmpty ? "closes" : "clears search"))
    }

    // MARK: Selection and filtering

    private func reload(selectFirst: Bool = false) {
        guard isVisible else { return }
        view.update(entries: visibleEntries, total: store.entries)
        if selectFirst, let first = view.canvas.tiles.first { view.canvas.choose(first.entry.id) }
        view.keyboardTookSelection()
        if case .sending(let entry) = mode, !store.entries.contains(where: { $0.id == entry.id }) { endSendTo() }
        if case .browsing(.all) = mode { view.showConfirmation(count: store.entries.count) }
        refreshHint()
    }

    /// A new search selects its newest match, as each letter is typed.
    @objc private func queryChanged() {
        disarm()
        reload(selectFirst: true)
    }

    @objc private func tabClicked() { select(view.currentTab) }

    /// A tab keeps the selection when it is still shown, otherwise its newest entry.
    private func select(_ tab: ClipboardBrowserTab) {
        view.tabs.selectedSegment = tab.rawValue
        reload()
    }

    /// Arrows stop at the ends; the history shortcut wraps.
    private func step(_ delta: Int, wrapping: Bool) {
        let tiles = view.canvas.tiles
        guard let current = view.canvas.selected, let index = tiles.firstIndex(of: current) else { return }
        let next = index + delta
        view.keyboardTookSelection()
        view.canvas.choose(tiles[wrapping ? (next + tiles.count) % tiles.count : min(max(0, next), tiles.count - 1)].entry.id)
    }

    /// Esc steps out one level: a waiting delete, then the search, then the window.
    private func escape() {
        if isArmed { disarm() }
        else if !view.search.stringValue.isEmpty { view.search.stringValue = ""; queryChanged() }
        else { close() }
    }

    /// Returning to the field leaves the caret at the end; only a search the
    /// window offered back is selected, so the next letter replaces it.
    private func focusSearch(selectingAll: Bool = false) {
        panel.makeFirstResponder(view.search)
        let length = view.search.stringValue.utf16.count
        view.search.currentEditor()?.selectedRange = selectingAll ? NSRange(location: 0, length: length) : NSRange(location: length, length: 0)
    }

    private func remember(_ entry: ClipboardEntry) {
        recall.remember(entry, tab: view.currentTab, query: view.search.stringValue)
    }

    // MARK: Actions

    private func paste(_ entry: ClipboardEntry, plain: Bool) {
        remember(entry)
        let target = returnTarget
        close()
        paster.paste(entry, into: target, plain: plain)
    }

    /// The keyboard's pickup: the entry goes on the clipboard and rides the
    /// cursor magnet. Pasting moves it to the top; Esc restores the clipboard.
    private func pickUp(_ entry: ClipboardEntry) {
        remember(entry)
        close()
        store.selectForPaste(entry)
    }

    private func open(_ entry: ClipboardEntry) {
        remember(entry)
        close()
        openInPreview(entry) { [weak self] error in if let error { self?.onError?(error) } }
    }

    private func beginSendTo(_ entry: ClipboardEntry) {
        let items = ClipboardSendTo.openItems(for: entry, materializer: materializer)
        let targets = ClipboardSendTo.targets(opening: items, sources: sendSources)
        guard !targets.isEmpty else { NSSound.beep(); return }
        mode = .sending(entry)
        view.showSendTo(targets)
        refreshFooter()
        panel.makeFirstResponder(view.sendTo)
    }

    private func endSendTo() {
        guard isSending else { return }
        mode = .browsing(.none)
        view.showCard()
        refreshFooter()
        focusSearch()
    }

    private func send(to target: ClipboardSendTarget) {
        guard case .sending(let entry) = mode else { return }
        remember(entry)
        close()
        ClipboardSendTo.send(entry, to: target, paster: paster, sources: sendSources) { [weak self] error in self?.onError?(error) }
    }

    // MARK: Deleting — 🚨 cannot be undone, so the first press only asks

    private var isArmed: Bool { if case .browsing(let armed) = mode { return armed != .none }; return false }

    private func disarm() {
        guard isArmed else { return }
        mode = .browsing(.none)
        view.showCard()
        refreshHint()
    }

    private func reflectArming() {
        if case .browsing(.row(let id)) = mode { view.canvas.arm(id) } else { view.canvas.arm(nil) }
    }

    private func requestDelete(_ entry: ClipboardEntry) {
        guard case .browsing(.row(entry.id)) = mode else {
            mode = .browsing(.row(entry.id))
            view.showCard()
            refreshHint()
            return
        }
        mode = .browsing(.none)
        let canvas = view.canvas
        let index = canvas.tiles.firstIndex { $0.entry.id == entry.id } ?? 0
        if !store.remove(entry) { NSSound.beep() }
        // The row that moved up into the deleted one's place takes the selection.
        let remaining = canvas.tiles
        if !remaining.isEmpty { canvas.choose(remaining[min(index, remaining.count - 1)].entry.id) }
        refreshHint()
    }

    @objc private func deleteAllClicked() { requestDeleteAll() }

    private func requestDeleteAll() {
        guard case .browsing(let armed) = mode, !store.entries.isEmpty else { NSSound.beep(); return }
        guard armed == .all else {
            mode = .browsing(.all)
            view.showConfirmation(count: store.entries.count)
            refreshHint()
            return
        }
        mode = .browsing(.none)
        view.showCard()
        store.clear()
        if !store.saveNow() { onError?(ClipEdgeError.cannotDelete) }
        reload(selectFirst: true)
    }
}
