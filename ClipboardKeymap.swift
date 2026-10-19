import AppKit

/// What a key press, a click or a footer button asks of a container (the drawer or the ⌥⌘\ window).
/// Each container's keymap says which keys reach which action; each container answers every action.
enum ClipboardBrowserAction: Hashable {
    /// The arrows: one entry back or on, or one row of cards back or on (one entry in a list).
    case newer, older, previousRow, nextRow
    /// Return, or a click on a card: the container's own action, picking up in the drawer, pasting in the window.
    case primary
    case plainPaste, pickUp, sendTo, open, delete
    /// Put the keyboard in the search, its text selected so typing replaces it.
    case find
    case tab(ClipboardBrowserTab)
    /// A brief for a better preview of the selection (maintainer copies; elsewhere nothing).
    case ask
    case quickLook, settings, escape
    /// Keys that would otherwise take the keyboard from where it stays (the window's ⇧Tab).
    case ignore
    /// Multi-select (Al, 2026-10-12): Select / Done; every shown card marked, or none; and the
    /// chosen card marked with the one newer or older, which is chosen next (⇧↑, ⇧↓).
    case selecting, markAll, extendNewer, extendOlder
    /// The card turned over to its raw data, and back (Al, 2026-10-12): the window's card, Quick
    /// Look beside the drawer.
    case flip
    /// Flavor `n` (from 1) of the raw data showing, copied by itself: ⌥1–⌥9.
    case copyFlavor(Int)
    /// The raw data showing, read by key: the keyboard to the next of its texts (the overview, then
    /// each flavor's content), where the arrows move and ⇧ with them selects; Page Up and Page Down
    /// scroll it a screenful. Elsewhere these pass on.
    case selectRawText, pageUp, pageDown

    /// The arrows' steps through a list `columns` wide.
    func step(columns: Int) -> Int? {
        switch self {
        case .newer: return -1
        case .older: return 1
        case .previousRow: return -columns
        case .nextRow: return columns
        default: return nil
        }
    }
    /// Held down, these wait for the next press rather than repeating: Space, ",", and Select, Select
    /// all, the card's turn and the move to the next text, which would otherwise flicker (⇧↑ and ⇧↓
    /// repeat, marking as they go). 🚨 Delete too: its second press deletes for good, and a held key's
    /// repeat is not a second press.
    var waitsForNextPress: Bool { [.quickLook, .settings, .selecting, .markAll, .flip, .selectRawText, .delete].contains(self) }
}

/// Where in its container a key acts.
enum ClipboardKeyReach {
    /// Wherever the keyboard is, the search included.
    case anywhere
    /// Anywhere but a field being typed in.
    case outsideText
    /// Only while the cards hold the keyboard.
    case cards
}

/// How a container shows a key and how it says it: "⏎" and "Return", "," and "comma".
struct ClipboardKeyLabel: Equatable {
    let shown: String
    let spoken: String
}

struct ClipboardKeyBinding {
    let chord: ClipboardChord
    let action: ClipboardBrowserAction
    let reach: ClipboardKeyReach
    /// Nil for a key that is not shown: Enter beside Return, ⌦ beside ⌫, the keypad's digits.
    let label: ClipboardKeyLabel?

    init(_ key: ClipboardChord.Key, _ modifiers: ClipboardChord.Modifiers, _ action: ClipboardBrowserAction,
         _ reach: ClipboardKeyReach, _ shown: String? = nil, spoken: String? = nil) {
        chord = ClipboardChord(key: key, modifiers: modifiers)
        self.action = action
        self.reach = reach
        label = shown.map { ClipboardKeyLabel(shown: $0, spoken: spoken ?? $0) }
    }
}

/// One container's keys and how it shows them: the single source for what a key does there and
/// for every label that names it (tabs, the search's placeholder, tooltips, card info, the footer).
struct ClipboardKeymap {
    let bindings: [ClipboardKeyBinding]

    /// The action a key press asks for where the keyboard is; an exact chord wins over one that takes other modifiers.
    func action(for event: NSEvent, reaching reach: Set<ClipboardKeyReach> = [.anywhere, .outsideText, .cards]) -> ClipboardBrowserAction? {
        let matching = bindings.filter { reach.contains($0.reach) && $0.chord.matches(event) }
        let exact = matching.first { if case .exactly = $0.chord.modifiers { return true }; return false }
        return (exact ?? matching.first)?.action
    }

    /// The action's shown keys, joined: "⌫ or ⌘⌫". Nil when it has none here.
    func label(_ action: ClipboardBrowserAction) -> String? {
        joined(bindings.filter { $0.action == action }.compactMap { $0.label?.shown })
    }
    /// The action's keys in words: "Command-Delete".
    func spoken(_ action: ClipboardBrowserAction) -> String? {
        joined(bindings.filter { $0.action == action }.compactMap { $0.label?.spoken })
    }
    /// A name and its key, for a control that shows the key apart, in its cap (the tabs, Select).
    func keyed(_ name: String, _ action: ClipboardBrowserAction) -> ClipboardKeyedTitle {
        ClipboardKeyedTitle(name: name, key: key(action))
    }
    /// The action's keys, shown and spoken: "⌫ or ⌘⌫", "Delete or Command-Delete". Nil when it has none here.
    func key(_ action: ClipboardBrowserAction) -> ClipboardKeyLabel? {
        label(action).map { ClipboardKeyLabel(shown: $0, spoken: spoken(action) ?? $0) }
    }
    /// A name carrying its key as plain text, as buttons show it: "Paste ⏎"; the name alone without one.
    func titled(_ name: String, _ action: ClipboardBrowserAction) -> String { keyed(name, action).plain }
    /// A tooltip line: "Settings ← ,"; the name alone when the action has no key here.
    func help(_ name: String, _ action: ClipboardBrowserAction) -> String {
        label(action).map { "\(name) ← \($0)" } ?? name
    }
    /// The tabs' keys as a range: "0–3".
    var tabRange: String? {
        guard let first = ClipboardBrowserTab.allCases.first.flatMap({ label(.tab($0)) }),
              let last = ClipboardBrowserTab.allCases.last.flatMap({ label(.tab($0)) }) else { return nil }
        return "\(first)–\(last)"
    }
    private func joined(_ keys: [String]) -> String? { keys.isEmpty ? nil : keys.joined(separator: " or ") }
}

extension ClipboardKeymap {
    /// The drawer's keys. Its cards hold the keyboard, so single keys act there, as in Gmail
    /// (Al, 2026-10-11): / the search (F until 2026-10-16), 0–3 the tabs by position (renumbered from 1–4 on 2026-10-16), "," Settings, S and A select, I
    /// turns Quick Look to the raw data and T reads its text (2026-10-12). In the search every
    /// character types; Esc and ⌥⌘A act from anywhere in the drawer, Space, the Quick Look arrows,
    /// ⌥1–⌥9 and Page Up and Page Down from anywhere but the search.
    static let drawer = ClipboardKeymap(bindings: [
        .init(.code(53), .exactly([]), .escape, .anywhere, "Esc", spoken: "Escape"),
        .init(.code(53), .any, .escape, .cards),
        .init(.letter("a", position: 0), .exactly([.option, .command]), .ask, .anywhere, "⌥⌘A", spoken: "Option-Command-A"),
        .init(.code(49), .exactly([]), .quickLook, .outsideText, "Space"),
        .init(.code(123), .exactly([]), .newer, .outsideText), .init(.code(124), .exactly([]), .older, .outsideText),
        .init(.code(126), .exactly([]), .previousRow, .outsideText), .init(.code(125), .exactly([]), .nextRow, .outsideText),
        .init(.code(123), .any, .newer, .cards), .init(.code(124), .any, .older, .cards),
        .init(.code(126), .any, .previousRow, .cards), .init(.code(125), .any, .nextRow, .cards),
        .init(.code(36), .any, .primary, .cards, "Return"),
        .init(.code(76), .any, .primary, .cards),
        .init(.code(48), .exactly([]), .sendTo, .cards, "Tab"),
        .init(.code(51), .exactly([]), .delete, .cards, "⌫", spoken: "Delete"),
        .init(.code(117), .exactly([]), .delete, .cards),
        .init(.code(51), .exactly([.command]), .delete, .cards, "⌘⌫", spoken: "Command-Delete"),
        .init(.letter("o", position: 31), .exactly([.command]), .open, .cards, "⌘O", spoken: "Command-O"),
        // ⌘C picks the card up as Return does; with cards marked, it copies their text.
        .init(.letter("c", position: 8), .exactly([.command]), .pickUp, .cards, "⌘C", spoken: "Command-C"),
        // The slash, as in Gmail (Al, 2026-10-16; F until then); ⇧ too, since some layouts type it so.
        .init(.character("/"), .exactly([]), .find, .cards, "/", spoken: "slash"),
        .init(.character("/"), .exactly([.shift]), .find, .cards),
        .init(.letter("f", position: 3), .exactly([.command]), .find, .cards),
        // Multi-select. The shifted arrows are exact, so they win over the plain arrows, which take any
        // modifier; ⇧← and ⇧→ step one card, as ← and → do, in the Images grid too.
        .init(.letter("s", position: 1), .exactly([]), .selecting, .cards, "S"),
        .init(.letter("a", position: 0), .exactly([]), .markAll, .cards, "A"),
        .init(.code(126), .exactly([.shift]), .extendNewer, .cards, "⇧↑", spoken: "Shift-Up Arrow"),
        .init(.code(125), .exactly([.shift]), .extendOlder, .cards, "⇧↓", spoken: "Shift-Down Arrow"),
        .init(.code(123), .exactly([.shift]), .extendNewer, .cards), .init(.code(124), .exactly([.shift]), .extendOlder, .cards),
        // I turns Quick Look beside the drawer to the card's raw data (⌘I too); ⌥1–⌥9 copy its flavors.
        .init(.letter("i", position: 34), .exactly([]), .flip, .cards, "I"),
        .init(.letter("i", position: 34), .exactly([.command]), .flip, .cards),
        // T puts the keyboard in its raw data's text (⌘T too); Page Up and Page Down scroll it.
        .init(.letter("t", position: 17), .exactly([]), .selectRawText, .cards, "T"),
        .init(.letter("t", position: 17), .exactly([.command]), .selectRawText, .cards)
    ] + rawPages(.outsideText) + flavorCopies(.outsideText) + tabs(.exactly([]), .cards, shown: { $0 }, spoken: { $0 }) + [
        .init(.character(","), .exactly([]), .settings, .cards, ",", spoken: "comma"),
        .init(.character(","), .exactly([.shift]), .settings, .cards)
    ])

    /// The ⌥⌘\ window's keys. Its search always holds the keyboard, so a bare 1 types a 1:
    /// ⌘0–⌘3 choose the tabs and ⌘F selects the search. Anything not here is typing. Letters, here
    /// and in the drawer's, are the key in the letter's place on layouts without Latin letters.
    static let window = ClipboardKeymap(bindings: [
        // Left and right select too, so the caret stays at the end of the search.
        .init(.code(123), .exactly([]), .newer, .anywhere), .init(.code(124), .exactly([]), .older, .anywhere),
        .init(.code(126), .exactly([]), .previousRow, .anywhere), .init(.code(125), .exactly([]), .nextRow, .anywhere),
        .init(.code(36), .exactly([]), .primary, .anywhere, "⏎", spoken: "Return"),
        .init(.code(76), .exactly([]), .primary, .anywhere),
        .init(.code(36), .exactly([.control, .command]), .plainPaste, .anywhere, "⌃⌘⏎", spoken: "Control-Command-Return"),
        .init(.code(76), .exactly([.control, .command]), .plainPaste, .anywhere),
        .init(.code(36), .any, .ignore, .anywhere), .init(.code(76), .any, .ignore, .anywhere),
        .init(.code(48), .exactly([]), .sendTo, .anywhere, "⇥", spoken: "Tab"),
        .init(.code(48), .exactly([.shift]), .ignore, .anywhere),
        .init(.code(53), .exactly([]), .escape, .anywhere, "esc", spoken: "Escape"),
        .init(.code(51), .exactly([.command]), .delete, .anywhere, "⌘⌫", spoken: "Command-Delete"),
        .init(.letter("a", position: 0), .exactly([.option, .command]), .ask, .anywhere, "⌥⌘A", spoken: "Option-Command-A")
    ] + tabs(.exactly([.command]), .anywhere, shown: { "⌘\($0)" }, spoken: { "Command-\($0)" }) + [
        .init(.letter("c", position: 8), .exactly([.command]), .pickUp, .anywhere, "⌘C", spoken: "Command-C"),
        .init(.letter("o", position: 31), .exactly([.command]), .open, .anywhere, "⌘O", spoken: "Command-O"),
        .init(.letter("f", position: 3), .exactly([.command]), .find, .anywhere, "⌘F", spoken: "Command-F"),
        // Multi-select: ⌘A stays the search's select-all, so every card is ⇧⌘A.
        .init(.letter("s", position: 1), .exactly([.command]), .selecting, .anywhere, "⌘S", spoken: "Command-S"),
        .init(.letter("a", position: 0), .exactly([.shift, .command]), .markAll, .anywhere, "⇧⌘A", spoken: "Shift-Command-A"),
        .init(.code(126), .exactly([.shift]), .extendNewer, .anywhere, "⇧↑", spoken: "Shift-Up Arrow"),
        .init(.code(125), .exactly([.shift]), .extendOlder, .anywhere, "⇧↓", spoken: "Shift-Down Arrow"),
        // The card's raw data; while it shows, ⌥1–⌥9 copy its flavors, ⌘T reads its text and Page Up
        // and Page Down scroll it (otherwise they go on to the search).
        .init(.letter("i", position: 34), .exactly([.command]), .flip, .anywhere, "⌘I", spoken: "Command-I"),
        .init(.letter("t", position: 17), .exactly([.command]), .selectRawText, .anywhere, "⌘T", spoken: "Command-T")
    ] + rawPages(.anywhere) + flavorCopies(.anywhere))

    /// Page Up and Page Down (Fn-↑ and Fn-↓ on a laptop): the raw data showing, a screenful at a time.
    private static func rawPages(_ reach: ClipboardKeyReach) -> [ClipboardKeyBinding] {
        [ClipboardKeyBinding(.code(116), .exactly([]), .pageUp, reach, "⇞", spoken: "Page Up"),
         ClipboardKeyBinding(.code(121), .exactly([]), .pageDown, reach, "⇟", spoken: "Page Down")]
    }

    /// ⌥1–⌥9 by position, the top row's shown, the keypad's not: flavor n of the raw data showing.
    /// Beyond the ninth a flavor has no key; its Copy button still copies it.
    private static func flavorCopies(_ reach: ClipboardKeyReach) -> [ClipboardKeyBinding] {
        let row: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25], keypad: [UInt16] = [83, 84, 85, 86, 87, 88, 89, 91, 92]
        return (1...9).flatMap { number in [
            ClipboardKeyBinding(.code(row[number - 1]), .exactly([.option]), .copyFlavor(number), reach, "⌥\(number)", spoken: "Option-\(number)"),
            ClipboardKeyBinding(.code(keypad[number - 1]), .exactly([.option]), .copyFlavor(number), reach)
        ] }
    }

    /// Every tab's number key by position, the top row's shown, the keypad's not, so layouts
    /// without digits there still reach them.
    private static func tabs(_ modifiers: ClipboardChord.Modifiers, _ reach: ClipboardKeyReach,
                             shown: (String) -> String, spoken: (String) -> String) -> [ClipboardKeyBinding] {
        ClipboardBrowserTab.allCases.flatMap { tab in [
            ClipboardKeyBinding(.code(tab.keyCodes.row), modifiers, .tab(tab), reach, shown(tab.numberKey), spoken: spoken(tab.numberKey)),
            ClipboardKeyBinding(.code(tab.keyCodes.keypad), modifiers, .tab(tab), reach)
        ] }
    }
}
