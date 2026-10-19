import AppKit

/// Multi-select's marks (Al, 2026-10-12): the pure transitions the drawer and the ⌥⌘\ window share
/// (Select / Done, a click or ⌘-click, a ⇧-click range, ⇧↑ / ⇧↓, Select all / none, pruning to what
/// the list shows), the rule that marks are always among the shown entries in their order, and the
/// wording of the delete that asks about them. Made-up identifiers and entries only.
@main enum MarkingTests {
    private static var assertions = 0
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError("FAIL: \(message)") }
    }
    /// Six entries as a list shows them, newest first.
    private static let ids = (0..<6).map { _ in UUID() }
    private static var a: UUID { ids[0] }
    private static var b: UUID { ids[1] }
    private static var c: UUID { ids[2] }
    private static var d: UUID { ids[3] }
    private static var e: UUID { ids[4] }
    private static var f: UUID { ids[5] }
    private static func on(_ marked: [UUID], _ anchor: UUID?) -> ClipboardMarking { .on(marked: marked, anchor: anchor) }

    static func main() {
        offAndSwitch()
        toggling()
        ranges()
        extending()
        allOrNone()
        pruning()
        invariants()
        markedEntries()
        deletionWording()
        print("Marking tests passed (\(assertions) assertions)")
    }

    private static func offAndSwitch() {
        let off = ClipboardMarking.off
        check(!off.isOn && off.marked.isEmpty && off.anchor == nil && !off.isMarked(a), "off: no circles, no marks, no anchor")
        check(off.switched == on([], nil), "Select turns the circles on with nothing marked")
        check(on([a, c], c).switched == .off, "Done turns them off and lets go of every mark")
        check(off.switched.switched == .off, "Select then Done is where it started")
        check(on([], nil).isOn && on([], nil).marked.isEmpty, "circles may show with nothing marked")
    }

    private static func toggling() {
        let first = ClipboardMarking.off.toggling(c, shown: ids)
        check(first == on([c], c), "a ⌘-click with marking off turns it on and marks that card, the anchor")
        let second = first.toggling(a, shown: ids)
        check(second == on([a, c], a) && second.isMarked(a) && second.isMarked(c) && !second.isMarked(b),
              "a second card joins the marks in the list's order, not the order clicked; it is the anchor now")
        check(second.toggling(c, shown: ids) == on([a], c), "clicking a marked card unmarks it, and it becomes the anchor")
        check(second.toggling(a, shown: ids).toggling(c, shown: ids) == on([], c), "unmarking the last mark leaves the circles on, with nothing marked")
        let hidden = UUID()
        check(second.toggling(hidden, shown: ids) == second, "a card not shown cannot be marked")
        check(ClipboardMarking.off.toggling(hidden, shown: ids) == .off, "nor can it turn marking on")
        check(second.toggling(b, shown: [a, b]) == on([a, b], b), "toggling with a narrower list keeps only marks still shown")
    }

    private static func ranges() {
        let start = on([b], b)
        let down = start.markingRange(to: e, shown: ids)
        check(down == on([b, c, d, e], e), "⇧-click marks from the anchor to the card, both included; the card is the new anchor")
        check(down.markingRange(to: d, shown: ids) == on([b, c, d, e], d), "a ⇧-click inside the marks unmarks nothing")
        check(down.markingRange(to: a, shown: ids) == on([a, b, c, d, e], a), "the next ⇧-click goes on from the last one, upward too")
        check(on([f], b).markingRange(to: c, shown: ids) == on([b, c, f], c), "a range adds to marks made elsewhere")
        check(on([], nil).markingRange(to: c, shown: ids) == on([c], c), "with no anchor, ⇧-click marks the card alone")
        check(ClipboardMarking.off.markingRange(to: d, shown: ids) == on([d], d), "with marking off, ⇧-click turns it on and marks the card")
        check(on([a], UUID()).markingRange(to: c, shown: ids) == on([a, c], c), "an anchor out of view starts no range")
        check(on([a], a).markingRange(to: UUID(), shown: ids) == on([a], a), "a ⇧-click on a card not shown changes nothing")
        check(on([a], a).markingRange(to: a, shown: ids) == on([a], a), "a range of one card is that card")
    }

    private static func extending() {
        let older = ClipboardMarking.off.extending(from: c, .older, shown: ids)
        check(older.marking == on([c, d], d) && older.chosen == d, "⇧↓ with marking off marks the chosen card and the next older, and chooses it")
        let further = older.marking.extending(from: d, .older, shown: ids)
        check(further.marking == on([c, d, e], e) && further.chosen == e, "another ⇧↓ marks one more")
        let back = further.marking.extending(from: e, .newer, shown: ids)
        check(back.marking == on([c, d, e], d) && back.chosen == d, "⇧↑ back over marked cards keeps them marked")
        let top = ClipboardMarking.off.extending(from: a, .newer, shown: ids)
        check(top.marking == on([a], a) && top.chosen == a, "⇧↑ on the newest card marks it and stays")
        let bottom = on([b], b).extending(from: f, .older, shown: ids)
        check(bottom.marking == on([b, f], f) && bottom.chosen == f, "⇧↓ on the oldest card marks it and stays, keeping other marks")
        let hidden = UUID()
        let nowhere = on([b], b).extending(from: hidden, .older, shown: ids)
        check(nowhere.marking == on([b], b) && nowhere.chosen == hidden, "with no chosen card in view, nothing is marked and nothing moves")
        let single = ClipboardMarking.off.extending(from: c, .older, shown: [c])
        check(single.marking == on([c], c) && single.chosen == c, "a list of one card: ⇧↓ marks it and stays")
    }

    private static func allOrNone() {
        check(ClipboardMarking.off.togglingAll(shown: ids) == on(ids, nil), "Select all with marking off turns it on and marks every shown card")
        check(on([b, d], d).togglingAll(shown: ids) == on(ids, d), "with some marked, Select all marks every shown card and keeps the anchor")
        check(on(ids, c).togglingAll(shown: ids) == on([], c), "with every shown card marked, it marks none, the circles still on")
        check(on([a, b, c], a).togglingAll(shown: [b, c]) == on([], nil), "every shown card marked counts, whatever was marked before; an anchor out of view goes")
        check(on([], nil).togglingAll(shown: []) == on([], nil), "an empty list has nothing to mark")
        check(on([b], b).togglingAll(shown: [b, e]) == on([b, e], b), "Select all marks only what is shown")
    }

    private static func pruning() {
        let marks = on([a, c, e], c)
        check(marks.pruned(to: [e, c, UUID()]) == on([e, c], c), "a search keeps the marks it still shows, in its new order")
        check(marks.pruned(to: [a, b]) == on([a], nil), "marks no longer shown are let go, and so is an anchor out of view")
        check(marks.pruned(to: []) == on([], nil), "a list showing nothing leaves the circles on with nothing marked")
        check(ClipboardMarking.off.pruned(to: ids) == .off, "pruning never turns marking on")
        check(marks.pruned(to: ids) == marks, "pruning to the same list changes nothing")
    }

    /// Whatever the order of clicks, keys, searches and tab changes, marks stay among what is shown,
    /// in its order, without repeats, and the anchor is shown or nil.
    private static func invariants() {
        var seed: UInt64 = 0x5EED_C11B
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        var marking = ClipboardMarking.off
        var shown = ids, chosen = a
        var steps = 0
        for _ in 0..<2_000 {
            let id = ids[next(ids.count)]
            switch next(7) {
            case 0: marking = marking.toggling(id, shown: shown)
            case 1: marking = marking.markingRange(to: id, shown: shown)
            case 2: (marking, chosen) = marking.extending(from: chosen, next(2) == 0 ? .newer : .older, shown: shown)
            case 3: marking = marking.togglingAll(shown: shown)
            case 4: marking = marking.switched
            default:
                // A search or a tab change: some of the entries, still newest first.
                shown = ids.filter { _ in next(3) != 0 }
                marking = marking.pruned(to: shown)
                if !shown.contains(chosen), let first = shown.first { chosen = first }
            }
            let marked = marking.marked
            guard Set(marked).count == marked.count, marked == shown.filter(Set(marked).contains),
                  marking.anchor.map(shown.contains) ?? true, marking.isOn || (marked.isEmpty && marking.anchor == nil) else { break }
            steps += 1
        }
        check(steps == 2_000, "after any of 2,000 random steps, marks are shown entries in the list's order and the anchor is in view (failed at \(steps))")
    }

    private static func markedEntries() {
        let entries = ["Alder", "Birch", "Cedar"].map { text in
            ClipboardEntry(fingerprint: text, capturedAt: Date(), payloads: [ClipboardPayload(values: [(.string, Data(text.utf8))])],
                           title: text, detail: "", kind: .text, thumbnail: nil)
        }
        let marking = ClipboardMarking.off.toggling(entries[2].id, shown: entries.map(\.id)).toggling(entries[0].id, shown: entries.map(\.id))
        check(marking.markedEntries(entries).map(\.title) == ["Alder", "Cedar"], "the marked entries come in the list's order, not the order marked")
        check(marking.markedEntries(Array(entries.prefix(2))).map(\.title) == ["Alder"], "only entries still shown are acted on")
        check(ClipboardMarking.off.markedEntries(entries).isEmpty, "with marking off, nothing is acted on")
    }

    /// 🚨 One wording for the multi-select delete in both containers, answered by their own keys.
    private static func deletionWording() {
        let three = ClipboardDeletion.marked(count: 3), one = ClipboardDeletion.marked(count: 1)
        check(three.question == "Delete 3 items permanently?" && one.question == "Delete 1 item permanently?", "the question counts the selected items")
        check(three.consequence.hasPrefix("🚨") && three.consequence.contains("selected items") && three.consequence.contains("cannot be undone")
              && three.consequence.contains("Original files stay where they are"), "it says what goes, what stays and that it cannot be undone")
        check(one.consequence.contains("selected item ") && !one.consequence.contains("items"), "one selected item is one item")
        let window = ClipboardKeymap.window
        let keys = three.keys(confirm: window.key(.delete)!)
        check(keys.plain == "⌘⌫ again deletes" && keys.parts.first == .key(window.key(.delete)!),
              "the window shows its key in a cap: a second ⌘⌫ deletes; Esc keeping it goes unsaid")
        check(keys.spoken == "Command-Delete again deletes", "VoiceOver hears it in words")
        check(keys == ClipboardDeletion.one.keys(confirm: window.key(.delete)!), "the keys read as one item's do")
        check(ClipboardDeletion.all(count: 5).question == "Delete all 5 clipboard items?" && ClipboardDeletion.one.question == "Delete permanently?",
              "the menu's Clear History and a single delete keep their questions")
    }
}
