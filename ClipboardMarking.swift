import AppKit

/// Multi-select, shared by the drawer and the ⌥⌘\ window (Al, 2026-10-12, in place of Delete all:
/// the cards slide aside to show selection circles, as in Gmail). The interface says *Select* and
/// *selected*; the code says *marked*, because the chosen card (`ClipboardCanvas.selectedID`, the
/// one the keys act on) already has *selected*. Marked and chosen are independent.
///
/// Every transition is pure and takes the entries the list shows, newest first, and keeps the marks
/// a subset of them in that order: an action on the marks can never touch an item you cannot see.
enum ClipboardMarking: Equatable {
    case off
    /// Circles showing. `marked` may be empty (circles, no panel); it is ordered as the list shows
    /// them. `anchor` is where a ⇧-click range starts: the card marked or unmarked last.
    case on(marked: [UUID], anchor: UUID?)

    /// ⇧↑ and ⇧↓ (⇧← and ⇧→ in the drawer's Images grid): one entry newer or older.
    enum Step {
        case newer, older
        var offset: Int { self == .newer ? -1 : 1 }
    }

    var isOn: Bool { self != .off }
    /// In the order the list shows them; empty when marking is off.
    var marked: [UUID] {
        if case .on(let marked, _) = self { return marked }
        return []
    }
    var anchor: UUID? {
        if case .on(_, let anchor) = self { return anchor }
        return nil
    }
    func isMarked(_ id: UUID) -> Bool { marked.contains(id) }
    /// The marked entries among `shown`, in its order: what an action on the marks acts on.
    func markedEntries(_ shown: [ClipboardEntry]) -> [ClipboardEntry] {
        let marks = Set(marked)
        return shown.filter { marks.contains($0.id) }
    }

    /// Select / Done: circles on with nothing marked, or off with every mark let go.
    var switched: ClipboardMarking { isOn ? .off : .on(marked: [], anchor: nil) }

    /// A click on a card or its circle, or Return, while marking is on; ⌘-click from anywhere. Turns
    /// marking on, marks or unmarks `id` and makes it the anchor. A card not shown changes nothing.
    func toggling(_ id: UUID, shown: [UUID]) -> ClipboardMarking {
        guard shown.contains(id) else { return pruned(to: shown) }
        var marks = Set(marked)
        if marks.remove(id) == nil { marks.insert(id) }
        return Self.on(marks, anchor: id, shown: shown)
    }

    /// ⇧-click: marks every card from the anchor to `id`, both included, beside the marks already
    /// made (nothing is unmarked), and `id` becomes the anchor, so the next ⇧-click goes on from it,
    /// as in Gmail. With no anchor in view, it marks `id` alone. Turns marking on.
    func markingRange(to id: UUID, shown: [UUID]) -> ClipboardMarking {
        guard let end = shown.firstIndex(of: id) else { return pruned(to: shown) }
        let start = anchor.flatMap { shown.firstIndex(of: $0) } ?? end
        let range = shown[min(start, end)...max(start, end)]
        return Self.on(Set(marked).union(range), anchor: id, shown: shown)
    }

    /// ⇧↑ / ⇧↓: marks the chosen card, steps one card, marks that one too, and returns it as the
    /// card now chosen; at an end it marks the chosen card and stays. Marks are only added, so going
    /// back over them keeps them. Turns marking on. A chosen card not shown changes nothing.
    func extending(from chosen: UUID, _ step: Step, shown: [UUID]) -> (marking: ClipboardMarking, chosen: UUID) {
        guard let index = shown.firstIndex(of: chosen) else { return (pruned(to: shown), chosen) }
        let next = shown[min(max(index + step.offset, 0), shown.count - 1)]
        return (Self.on(Set(marked).union([chosen, next]), anchor: next, shown: shown), next)
    }

    /// Select all / Select none: every shown card, or none when every shown card is already marked.
    /// Turns marking on and keeps the anchor while it is in view.
    func togglingAll(shown: [UUID]) -> ClipboardMarking {
        let everything = !shown.isEmpty && Set(shown).isSubset(of: Set(marked))
        return Self.on(everything ? [] : Set(shown), anchor: anchor, shown: shown)
    }

    /// A search or a tab change, or entries leaving the history: marks no longer shown are let go,
    /// the rest kept in the new order, and an anchor out of view is forgotten. Off stays off.
    func pruned(to shown: [UUID]) -> ClipboardMarking {
        guard isOn else { return .off }
        return Self.on(Set(marked), anchor: anchor, shown: shown)
    }

    /// The marks among `shown`, in its order; an anchor out of view is nil.
    private static func on(_ marks: Set<UUID>, anchor: UUID?, shown: [UUID]) -> ClipboardMarking {
        .on(marked: shown.filter(marks.contains), anchor: anchor.flatMap { shown.contains($0) ? $0 : nil })
    }
}

/// A click on a card that marks rather than acts: ⌘-click marks or unmarks that card (turning
/// marking on), ⇧-click marks the range from the anchor. Any other click keeps its meaning.
enum ClipboardMarkClick: Equatable {
    case toggle, range

    init?(_ modifiers: NSEvent.ModifierFlags) {
        let chord = modifiers.intersection([.command, .control, .option, .shift])
        if chord == .command { self = .toggle }
        else if chord == .shift { self = .range }
        else { return nil }
    }
}
