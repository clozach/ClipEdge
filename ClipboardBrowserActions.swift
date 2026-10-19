import AppKit

/// Picking an entry up, in the drawer (Return, a click) or the ⌥⌘\ window (⌘C): it rides the
/// cursor magnet when that source's magnet shows (Settings › Cursor magnets), otherwise it just
/// becomes the clipboard's current item.
enum ClipboardPickup {
    enum Result { case held, madeCurrent, unchanged }

    @discardableResult
    static func pick(_ entry: ClipboardEntry, from source: ClipboardMagnetSource, showsMagnet: Bool, store: ClipboardStore) -> Result {
        if showsMagnet { store.selectForPaste(entry, from: source); return .held }
        return store.makeCurrent(entry) ? .madeCurrent : .unchanged
    }
}

/// How either container says an action failed.
enum ClipboardErrorAlert {
    static func show(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "ClipEdge"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

/// 🚨 Deleting for good, done alike in the drawer and the window.
extension ClipboardDeletion {
    /// Deletes `entry` and chooses the entry that moved into its place among `cards` (the one now
    /// last, when it was last), as the window always did (Al, 2026-10-11): the one-card case of
    /// deleting several, so the two cannot choose or report differently.
    static func remove(_ entry: ClipboardEntry, from store: ClipboardStore, choosingIn cards: ClipboardCanvas, failed: (Error) -> Void) {
        remove([entry], from: store, choosingIn: cards, failed: failed)
    }

    /// Deletes `marked` (a card, or the marked cards once asked), those still in the history, saving
    /// once, and chooses the card that moved into the place of the first of them (the one now last,
    /// when they were last). A deletion that could not be saved is `failed`, in both containers
    /// alike. Nothing else is touched: no card that was not marked.
    static func remove(_ marked: [ClipboardEntry], from store: ClipboardStore, choosingIn cards: ClipboardCanvas, failed: (Error) -> Void) {
        guard !marked.isEmpty else { return }
        let ids = Set(marked.map(\.id))
        let index = cards.tiles.firstIndex { ids.contains($0.entry.id) } ?? 0
        let saved = store.remove(marked)
        let remaining = cards.tiles
        if !remaining.isEmpty { cards.choose(remaining[min(index, remaining.count - 1)].entry.id) }
        if !saved { failed(ClipEdgeError.cannotDelete) }
    }

    /// Deletes the whole history, saving at once.
    static func removeAll(from store: ClipboardStore, failed: (Error) -> Void) {
        store.clear()
        if !store.saveNow() { failed(ClipEdgeError.cannotDelete) }
    }
}

enum ClipEdgeError: LocalizedError {
    case cannotDelete
    var errorDescription: String? { "ClipEdge could not save the deletion. Keep the app open and try Save History Now again." }
}
