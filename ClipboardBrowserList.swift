import AppKit

/// The tab an opening shows: always All (the window), or the one it was left on unless that would
/// hide one of `newCopies`, made since the last opening (the drawer; Al, 2026-10-10).
enum ClipboardOpeningTab {
    case all
    case keepUnlessHiding(newCopies: [ClipboardEntry])
}

/// What changed the list: a tab, or the search.
enum ClipboardFilterChange {
    case tab, query
}

/// The search, tabs, count line and cards the drawer and the ⌥⌘\ window both show, filtered
/// together and answering one keymap (Al, 2026-10-11: one component, many containers). Each
/// container lays them out, says how its tiles look, and answers its own actions; whatever else
/// differs is injected here: the keymap, the keyboard's home, the tabs' tooltips and where the
/// image-text note goes.
final class ClipboardBrowserList {
    let keymap: ClipboardKeymap
    let home: ClipboardKeyboardHome
    let tabs: ClipboardTabBar
    let search: ClipboardSearchField
    let countLine: ClipboardCountLine
    let canvas: ClipboardCanvas
    /// The whole history; the list shows the current tab's entries that match the search.
    var entries: [ClipboardEntry] = []
    /// The store's budget and use, for the count line's floppy warning; the container supplies it.
    var storageReport: () -> ClipboardStorageReport? = { nil }
    /// The container's answer to an action on an entry; the search and the tabs are the list's own.
    var perform: (ClipboardBrowserAction, ClipboardEntry?) -> Bool = { _, _ in false }
    /// The search or a tab changed; the container shows the new list.
    var onFilterChange: (ClipboardFilterChange) -> Void = { _ in }
    /// The keyboard moved through the cards or went to the search (the drawer's Quick Look hands
    /// its item to the pointer).
    var onInteraction: (() -> Void)?
    /// A hover chose a card (the drawer's Quick Look follows it).
    var onHover: ((ClipboardEntry) -> Void)?
    /// Maintainer copies only: what ⌥⌘A writes with, held here for the container, which reads it
    /// back. Its cards' help lists ⌥⌘A from it, so the key and its line cannot disagree.
    var previewAsker: ClipboardPreviewAsker? { didSet { tiles.values.forEach { $0.refreshEntryPresentation() } } }
    /// Multi-select (Al, 2026-10-12): off, or circles showing with the cards marked so far. Its marks
    /// are only ever cards shown, in their order (every list shown prunes them), and every opening
    /// turns it off, so an action on the marks can never reach a card you cannot see.
    private(set) var marking = ClipboardMarking.off
    /// Select / Done, laid out by each container.
    let selectButton: ClipboardSelectButton
    /// The marks changed: the container shows or hides the selection's actions and its hints.
    var onMarkingChange: (() -> Void)?
    /// The container's answer to an action on the marked cards (Copy as text, Delete N…): `marked`
    /// is `markedEntries`, never empty. False when it has no such action.
    var performOnMarks: (ClipboardBrowserAction, [ClipboardEntry]) -> Bool = { _, _ in false }
    /// The thumbnail size (Settings): every row's picture, and so its height; the container lays
    /// the rows out again.
    var thumbnailScale: CGFloat = 1 {
        didSet {
            guard thumbnailScale != oldValue else { return }
            tiles.values.forEach { $0.thumbnailScale = thumbnailScale }
            canvas.enclosingScrollView?.superview?.needsLayout = true
        }
    }
    /// A row's height in this list now (the drawer's rows or the window's compact ones).
    func rowHeight(_ style: ClipboardTileStyle) -> CGFloat { ClipboardTile.rowHeight(style, scale: thumbnailScale) }
    private struct TileKey: Hashable { let id: UUID; let style: ClipboardTileStyle }
    private var tiles: [TileKey: ClipboardTile] = [:]

    var tab: ClipboardBrowserTab { tabs.tab }
    var visibleEntries: [ClipboardEntry] { tab.visible(entries, query: search.stringValue) }
    /// The cards shown, newest first: what marks are kept among.
    private var shown: [UUID] { canvas.tiles.map(\.entry.id) }
    /// The marked cards, each still shown, in the order shown: what the selection's actions act on.
    var markedEntries: [ClipboardEntry] { marking.markedEntries(canvas.tiles.map(\.entry)) }
    /// Every card shown is marked (the panel's Select all reads Select none).
    var everyShownMarked: Bool { !canvas.tiles.isEmpty && markedEntries.count == canvas.tiles.count }

    init(keymap: ClipboardKeymap, home: ClipboardKeyboardHome, tooltips: ClipboardTabTooltips, indexing: ClipboardIndexingPlacement) {
        self.keymap = keymap
        self.home = home
        tabs = ClipboardTabBar(keymap: keymap, home: home, tooltips: tooltips)
        search = ClipboardSearchField(keymap: keymap, home: home)
        countLine = ClipboardCountLine(placement: indexing)
        selectButton = ClipboardSelectButton(keymap: keymap, home: home)
        // Where the search keeps the keyboard, a click on the cards leaves it there.
        canvas = ClipboardCanvas(keymap: keymap, home: home)
        tabs.onChange = { [weak self] in self?.filterChanged(.tab) }
        search.onChange = { [weak self] in self?.filterChanged(.query) }
        canvas.onNavigate = { [weak self] in self?.onInteraction?() }
        canvas.answer = { [weak self] action, entry in self?.answer(action, on: entry) ?? false }
        canvas.marking = { [weak self] in self?.marking ?? .off }
        selectButton.onPress = { [weak self] in _ = self?.answer(.selecting, on: nil) }
    }

    /// Shows the visible entries as tiles of `style`, each made once per entry and kept while the
    /// entry stays in the history, and counts them. Returns the tiles shown before.
    @discardableResult
    func showTiles(style: ClipboardTileStyle, liftedID: UUID?) -> [ClipboardTile] {
        let previous = canvas.tiles
        let retained = Set(entries.map(\.id))
        tiles = tiles.filter { retained.contains($0.key.id) }
        canvas.tiles = visibleEntries.map { entry in
            let key = TileKey(id: entry.id, style: style)
            let tile = tiles[key] ?? makeTile(entry, style: style)
            tiles[key] = tile
            tile.refreshEntryPresentation()
            // A card new to the list shows the circles as they are now, without sliding; one not in
            // the view tree catches up when it joins it (`ClipboardCanvas.attachVisible`).
            tile.refreshMarking(animated: false)
            return tile
        }
        let shownTiles = Set(canvas.tiles.map(ObjectIdentifier.init))
        previous.filter { !shownTiles.contains(ObjectIdentifier($0)) }.forEach { $0.removeFromSuperview() }
        canvas.reconcile(liftedID: liftedID)
        canvas.attachVisible()
        countLine.show(canvas.tiles.count, of: entries)
        let report = storageReport()
        countLine.storage.report = report
        countLine.count.report = report
        // A search, a tab or the history leaving cards out lets go of their marks.
        mark(marking.pruned(to: shown))
        return previous
    }

    /// While marking, the list's own answers come first (`answerMarking`); then the container's;
    /// then the list's own: its find key puts the keyboard in the search, a tab's key chooses that
    /// tab, and the multi-select keys mark.
    func answer(_ action: ClipboardBrowserAction, on entry: ClipboardEntry?) -> Bool {
        if marking.isOn, let answered = answerMarking(action, on: entry) { return answered }
        if perform(action, entry) { return true }
        switch action {
        case .find: focusSearch(selectingAll: true); return true
        case .tab(let tab): choose(tab); return true
        case .selecting: mark(marking.switched); return true
        case .markAll: mark(marking.togglingAll(shown: shown)); return true
        case .extendNewer: extend(.newer); return true
        case .extendOlder: extend(.older); return true
        default: return false
        }
    }

    /// While marking is on: Return, or a click on a card, marks or unmarks it instead of its own
    /// action; the actions a set can take act on the marks (a beep with nothing marked); those that
    /// make no sense for a set (Send to, Ask for a preview) do nothing. Nil: the usual path.
    private func answerMarking(_ action: ClipboardBrowserAction, on entry: ClipboardEntry?) -> Bool? {
        switch action {
        case .primary:
            if let entry { mark(marking.toggling(entry.id, shown: shown)) }
            return true
        case .sendTo, .ask: return true
        case .pickUp, .plainPaste, .open, .delete:
            let marked = markedEntries
            guard !marked.isEmpty else { NSSound.beep(); return true }
            return performOnMarks(action, marked)
        default: return nil
        }
    }

    /// Esc's rung for marking, between what each container lets go of first and the search: off,
    /// every mark let go. False when it was already off.
    @discardableResult
    func endMarking() -> Bool {
        guard marking.isOn else { return false }
        mark(.off)
        return true
    }

    /// ⇧↑ / ⇧↓: the chosen card and the next one marked, and the next one chosen.
    private func extend(_ step: ClipboardMarking.Step) {
        guard let chosen = canvas.selected?.entry.id else { return }
        let extended = marking.extending(from: chosen, step, shown: shown)
        mark(extended.marking)
        canvas.chooseByKey(extended.chosen)
    }

    /// The one way marks change: the cards slide aside as circles turn on or off, the button turns
    /// into Done or Select, and the container hears it.
    private func mark(_ new: ClipboardMarking, animated: Bool = true) {
        guard new != marking else { return }
        let switched = new.isOn != marking.isOn
        marking = new
        selectButton.reflect(new)
        canvas.refreshMarking(animated: animated && switched)
        onMarkingChange?()
    }

    /// A key press its container's window got before the keyboard's holder, answered as the cards
    /// answer theirs, in the drawer and the window alike: the keys that act wherever the keyboard is
    /// (`.anywhere`), or anywhere but a field being typed in (`.outsideText`). The cards' own keys
    /// (`.cards`) wait for the cards. `heard` sees the key's action first, nil for anything else (the
    /// window lets go of a waiting delete there). True when it acted, or when a held key that waits
    /// for the next press was swallowed; false passes the key on.
    func handleKey(_ event: NSEvent, in window: NSWindow, heard: (ClipboardBrowserAction?) -> Void = { _ in }) -> Bool {
        let reach: Set<ClipboardKeyReach> = window.firstResponder is NSTextView ? [.anywhere] : [.anywhere, .outsideText]
        let action = keymap.action(for: event, reaching: reach)
        heard(action)
        guard let action else { return false }
        if event.isARepeat, action.waitsForNextPress { return true }
        return answer(action, on: canvas.selected?.entry)
    }

    /// A tab chosen by its key, as a click chooses it; the card the keys act on stays in view.
    func choose(_ tab: ClipboardBrowserTab) {
        guard tab != self.tab else { return }
        tabs.tab = tab
        filterChanged(.tab)
        canvas.selected.map { canvas.choose($0.entry.id) }
    }

    func focusSearch(selectingAll: Bool) {
        search.focus(selectingAll: selectingAll)
        onInteraction?()
    }

    /// The keyboard to where it rests in `window`: the cards, or the search with the caret at its end.
    func focusHome(in window: NSWindow) {
        switch home {
        case .tiles: window.makeFirstResponder(canvas)
        case .search: search.focus(selectingAll: false)
        }
    }

    /// Each opening starts here: an empty search with nothing of its typing left to undo, and the
    /// newest entry chosen, so a search left from before never hides a new copy (Al, 2026-10-10).
    func startFresh(_ opening: ClipboardOpeningTab, undo: UndoManager?) {
        switch opening {
        case .all: tabs.tab = .all
        case .keepUnlessHiding(let newCopies): if newCopies.contains(where: { !tab.includes($0) }) { tabs.tab = .all }
        }
        search.clear(undo: undo)
        mark(.off, animated: false)
        filterChanged(.query)
        chooseNewest()
    }

    /// Esc's middle rung, between what each container lets go of first and closing: a search is
    /// emptied as an opening empties it. False when it was already empty.
    func clearSearch(undo: UndoManager?) -> Bool {
        guard !search.stringValue.isEmpty else { return false }
        startFresh(.keepUnlessHiding(newCopies: []), undo: undo)
        return true
    }

    private func filterChanged(_ change: ClipboardFilterChange) {
        onFilterChange(change)
        // Where the search holds the keyboard, each letter typed selects its newest match.
        if change == .query, home == .search { chooseNewest() }
    }

    private func chooseNewest() {
        if let newest = canvas.tiles.first { canvas.choose(newest.entry.id) }
    }

    private func makeTile(_ entry: ClipboardEntry, style: ClipboardTileStyle) -> ClipboardTile {
        let tile = ClipboardTile(entry: entry, style: style, keymap: keymap)
        tile.thumbnailScale = thumbnailScale
        tile.asker = { [weak self] in self?.previewAsker }
        tile.wantsLayer = true
        tile.onPick = { [weak self] in
            guard let self else { return }
            // Where the cards hold the keyboard, a click gives it to them.
            if self.home == .tiles { self.canvas.window?.makeFirstResponder(self.canvas) }
            self.canvas.choose(entry.id, reveal: false)
            _ = self.canvas.answer(.primary, entry)
        }
        // ⌘-click marks or unmarks the card, turning marking on; ⇧-click marks the range from the anchor.
        tile.onMarkClick = { [weak self] click in
            guard let self else { return }
            if self.home == .tiles { self.canvas.window?.makeFirstResponder(self.canvas) }
            self.canvas.choose(entry.id, reveal: false)
            switch click {
            case .toggle: self.mark(self.marking.toggling(entry.id, shown: self.shown))
            case .range: self.mark(self.marking.markingRange(to: entry.id, shown: self.shown))
            }
        }
        tile.onHover = { [weak self] in
            guard let self, self.canvas.hoverChooses else { return }
            self.canvas.choose(entry.id, reveal: false)
            self.onHover?(entry)
        }
        tile.onDelete = { [weak self] in _ = self?.canvas.answer(.delete, entry) }
        tile.onOpen = { [weak self] in _ = self?.canvas.answer(.open, entry) }
        return tile
    }
}
