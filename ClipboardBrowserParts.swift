import AppKit

/// Where a container's keyboard rests: on its cards (the drawer), or in its search (the ⌥⌘\
/// window), where a bare letter or digit is typing.
enum ClipboardKeyboardHome {
    case tiles, search
}

/// Whether a container's tabs also name their key in a tooltip. The drawer's controls each say
/// "Name ← key" there; the window's tabs and buttons say their key once, in their title.
enum ClipboardTabTooltips {
    case keys, none
}

/// The tabs, one segment per ClipboardBrowserTab in its order, each its name and its key in the
/// container's keymap with the key in its cap (Al, 2026-10-15): *All* [1] in the drawer, *All* [⌘1]
/// in the window. The system's large size, 28 points, so the cap has room above and below.
final class ClipboardTabBar: NSSegmentedControl {
    /// A click chose a tab.
    var onChange: (() -> Void)?
    /// What each segment shows, in the tabs' order. Its label, what VoiceOver reads, is the spoken
    /// form ("Images, 2"); the segment draws the name and the key's cap itself.
    let titles: [ClipboardKeyedTitle]
    /// Either side of a segment's name and cap: the window's four, ⌘ in each cap, end 8 points
    /// short of Publish's widest title at its 800 points.
    static let padding: CGFloat = 7
    var tab: ClipboardBrowserTab {
        get { ClipboardBrowserTab(rawValue: selectedSegment) ?? .all }
        set { selectedSegment = newValue.rawValue }
    }

    init(keymap: ClipboardKeymap, home: ClipboardKeyboardHome, tooltips: ClipboardTabTooltips) {
        titles = ClipboardBrowserTab.allCases.map { keymap.keyed($0.title, .tab($0)) }
        super.init(frame: .zero)
        cell = ClipboardKeyedSegmentCell(titles: titles)
        controlSize = .large
        segmentCount = titles.count
        trackingMode = .selectOne
        for tab in ClipboardBrowserTab.allCases {
            setLabel(titles[tab.rawValue].spoken, forSegment: tab.rawValue)
            if tooltips == .keys { setToolTip(keymap.help(tab.title, .tab(tab)), forSegment: tab.rawValue) }
        }
        fill(width: 0)
        tab = .all
        setAccessibilityLabel("Clipboard view")
        // Where the search holds the keyboard, a click on a tab leaves it there.
        refusesFirstResponder = home == .search
        target = self
        action = #selector(chose)
        sizeToFit()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func chose() { onChange?() }

    /// Each segment its name and cap with `padding` either side, plus an equal share of whatever
    /// `width` leaves over, so tabs given a wider frame (the drawer's) fill it with their segments;
    /// a width too small for that leaves each at its whole name and cap.
    /// Every segment at its name and cap with `padding` either side, nothing shared out.
    var naturalWidth: CGFloat { naturalWidths.reduce(0, +) }
    private var naturalWidths: [CGFloat] {
        let font = self.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        return titles.map { $0.size(font: font).width + 2 * Self.padding }
    }

    func fill(width: CGFloat) {
        let natural = naturalWidths
        let share = max(0, floor((width - natural.reduce(0, +)) / CGFloat(max(1, natural.count))))
        for (segment, own) in natural.enumerated() { setWidth(own + share, forSegment: segment) }
    }
}

/// Draws each segment's name and key cap in place of a plain label; the bezel, the selection and
/// the focus ring stay the system's.
final class ClipboardKeyedSegmentCell: NSSegmentedCell {
    private let titles: [ClipboardKeyedTitle]
    init(titles: [ClipboardKeyedTitle]) {
        self.titles = titles
        super.init(textCell: "")
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// When the selected segment is drawn in the accent color: selected, in the key window.
    static func fillsWithAccent(selected: Bool, keyWindow: Bool) -> Bool { selected && keyWindow }

    override func drawSegment(_ segment: Int, inFrame frame: NSRect, with controlView: NSView) {
        guard titles.indices.contains(segment) else { return super.drawSegment(segment, inFrame: frame, with: controlView) }
        let font = (controlView as? NSControl)?.font ?? self.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let enabled = isEnabled && isEnabled(forSegment: segment)
        // The system fills the selected segment with the accent color while its window is key; dark
        // label text on it was unreadable in Light mode (Al, 2026-10-16), so it takes the selected
        // text's color there, its key too.
        let onAccent = enabled && Self.fillsWithAccent(selected: isSelected(forSegment: segment), keyWindow: controlView.window?.isKeyWindow == true)
        titles[segment].draw(centeredIn: frame, font: font,
                             color: !enabled ? .disabledControlTextColor : onAccent ? .alternateSelectedControlTextColor : .labelColor,
                             glyph: onAccent ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.8) : .secondaryLabelColor)
    }
}

/// The search both containers show. Its placeholder names the container's key for it ("/" in the
/// drawer, "⌘F" in the window); typing and its clear button both report a change, once.
final class ClipboardSearchField: NSSearchField, NSSearchFieldDelegate {
    /// The query changed: typed, pasted, undone, or emptied by the field's clear button,
    /// which sends only the field's action.
    var onChange: (() -> Void)?
    /// The query last reported. Typing reports as the text changes and again, a moment later, as
    /// the field sends its search; only a query that differs from this one is a change.
    private var reported = ""
    /// Its placeholder, the key in its cap: "Search clipboard and image text  [/]".
    private(set) var placeholderHint = ClipboardHint([])

    init(keymap: ClipboardKeymap, home: ClipboardKeyboardHome) {
        super.init(frame: .zero)
        placeholderHint = "Search clipboard and image text" + (keymap.key(.find).map { "  " + .key($0) } ?? "")
        placeholderAttributedString = placeholderHint.attributed(font: font ?? .systemFont(ofSize: NSFont.systemFontSize), color: .placeholderTextColor)
        setAccessibilityLabel("Search clipboard and image text")
        sendsSearchStringImmediately = true
        // Where the search always holds the keyboard, a ring around it says nothing.
        if home == .search { focusRingType = .none }
        delegate = self
        target = self
        action = #selector(changed)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func controlTextDidChange(_ obj: Notification) { report() }
    @objc private func changed() { report() }
    private func report() {
        guard stringValue != reported else { return }
        reported = stringValue
        onChange?()
    }

    /// The keyboard to the search, with its text selected so typing replaces it (F, ⌘F), or the
    /// caret at its end.
    func focus(selectingAll: Bool) {
        window?.makeFirstResponder(self)
        let length = stringValue.utf16.count
        currentEditor()?.selectedRange = selectingAll ? NSRange(location: 0, length: length) : NSRange(location: length, length: 0)
    }

    /// Empty, and nothing left to undo: typing from before, undone against the empty search, would
    /// throw. The undo is its window's, given by the container (the closed drawer's view has none).
    func clear(undo: UndoManager?) {
        stringValue = ""
        reported = ""
        undo?.removeAllActions()
    }
}

/// Select / Done: multi-select's switch (Al, 2026-10-12), one view the list owns and each container
/// lays out (the drawer beside its tabs, where Clear… was; the window at the end of its count line).
/// Its name is followed by the container's key in its cap, the same key both ways. Where the search
/// holds the keyboard (the window) a click leaves it there; in the drawer it is one of the Tab stops.
final class ClipboardSelectButton: ClipboardKeyedButton {
    private let keymap: ClipboardKeymap
    /// A click: the list switches marking on or off, as the key does.
    var onPress: (() -> Void)?
    /// As wide as its wider title, so turning into Done never moves or cuts it.
    private(set) var preferredWidth: CGFloat = 0

    init(keymap: ClipboardKeymap, home: ClipboardKeyboardHome) {
        self.keymap = keymap
        super.init(frame: .zero)
        bezelStyle = home == .search ? .accessoryBarAction : .inline
        if home == .search {
            showsBorderOnlyWhileMouseInside = true
            font = .systemFont(ofSize: 11, weight: .medium)
        }
        refusesFirstResponder = home == .search
        target = self
        action = #selector(pressed)
        preferredWidth = [false, true].map { on -> CGFloat in
            keymap.keyed(Self.name(on), .selecting).apply(to: self)
            sizeToFit()
            return ceil(frame.width) + (home == .search ? 6 : 0)
        }.max() ?? 0
        reflect(.off)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func name(_ on: Bool) -> String { on ? "Done" : "Select" }

    /// Select while marking is off, Done while it is on; its help and VoiceOver say so with the key.
    func reflect(_ marking: ClipboardMarking) {
        keyedTitle = keymap.keyed(Self.name(marking.isOn), .selecting)
        toolTip = keymap.help(marking.isOn ? "Done selecting" : "Select several items", .selecting)
    }
    @objc private func pressed() { onPress?() }
}

/// Where the image-text reader's note shows: in a label of its own, in place of what that label
/// says otherwise (the drawer's Quick Look hint), or after the count (the window).
enum ClipboardIndexingPlacement {
    case ownLabel, appendedToCount
}

/// "N of M items", the image-text reader's note, and the empty list's words, for both containers.
final class ClipboardCountLine {
    /// *n of x items*; resting the pointer on it shows the disk as one bar.
    let count = ClipboardCountLabel(labelWithString: "")
    /// The note's own label (`.ownLabel`): `resting` while the reader has nothing to say.
    let note = NSTextField(labelWithString: "")
    let empty = NSTextField(wrappingLabelWithString: "Copy something to begin")
    /// 💾⚠️ before the count while the history's storage budget is under 1 GB.
    let storage = ClipboardStorageWarning()
    /// The width the warning takes before the count, with its gap: 0 while it hides.
    var storageWidth: CGFloat { storage.isHidden ? 0 : ClipboardStorageWarning.side + 4 }
    let placement: ClipboardIndexingPlacement
    /// Its keys in caps: *Quick Look* [Space] · [⌃⌥Space].
    var resting: (text: ClipboardHint, help: String?) = (ClipboardHint([]), nil)
    /// What the note says, as plain text.
    var noteText: String { noteHint.plain }
    private var noteHint = ClipboardHint([])

    init(placement: ClipboardIndexingPlacement) {
        self.placement = placement
        count.font = .systemFont(ofSize: 11)
        count.textColor = .secondaryLabelColor
        // The window's count shares its row with Select: a long reader's note wraps, never cut short.
        count.usesSingleLineMode = false
        count.cell?.wraps = true
        count.lineBreakMode = .byWordWrapping
        count.maximumNumberOfLines = 2
        note.font = .systemFont(ofSize: 11, weight: .medium)
        note.textColor = .secondaryLabelColor
        // A narrow drawer wraps the note onto as many lines as it needs rather than cutting it short.
        note.usesSingleLineMode = false
        note.cell?.wraps = true
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 0
        empty.alignment = .center
        empty.textColor = .secondaryLabelColor
        // A click on the empty list's words must not take the keyboard.
        empty.isSelectable = false
    }

    /// `shown` of `entries` are listed.
    func show(_ shown: Int, of entries: [ClipboardEntry]) {
        let indexing = ClipboardIndexingNote(entries)
        let items = "\(shown) of \(entries.count) items"
        switch placement {
        case .ownLabel:
            count.stringValue = items
            noteHint = indexing.map { ClipboardHint($0.text) } ?? resting.text
            note.attributedStringValue = noteHint.attributed(font: note.font!, color: .secondaryLabelColor)
            note.setAccessibilityLabel(noteHint.spoken)
            note.toolTip = indexing?.help ?? resting.help
        case .appendedToCount:
            count.stringValue = ([items] + (indexing.map { [$0.text] } ?? [])).joined(separator: " · ")
            count.toolTip = indexing?.help
        }
        empty.stringValue = entries.isEmpty ? "Copy something to begin" : "No matching items"
        empty.isHidden = shown > 0
    }
}

/// 🚨 Deleting for good, asked and done alike in the drawer and the window: one wording for each
/// question (Al, 2026-10-11), answered by keys in the container's own labels.
enum ClipboardDeletion {
    case one
    /// The cards marked for a multi-select delete (Delete N…), all of them shown.
    case marked(count: Int)
    /// The menu bar's Clear History: the whole history, shown or not.
    case all(count: Int)

    var question: String {
        switch self {
        case .one: return "Delete permanently?"
        case .marked(let count): return count == 1 ? "Delete 1 item permanently?" : "Delete \(count) items permanently?"
        case .all(let count): return count == 1 ? "Delete the one clipboard item?" : "Delete all \(count) clipboard items?"
        }
    }
    /// What it removes and what it keeps, where there is room to say so (not in an armed row).
    var consequence: String {
        switch self {
        case .one: return "🚨 This removes the item from ClipEdge, its saved history and preview copies. If it is on the clipboard, that is cleared too. Original files stay where they are. This cannot be undone."
        case .marked(let count) where count == 1: return "🚨 This removes the selected item from ClipEdge, its saved history and preview copies. If it is on the clipboard, that is cleared too. Original files stay where they are. This cannot be undone."
        case .marked: return "🚨 This removes the selected items from ClipEdge, their saved history and preview copies, and nothing else. If one of them is on the clipboard, that is cleared too. Original files stay where they are. This cannot be undone."
        case .all: return "🚨 This removes every item in ClipEdge's history, not only the ones shown, with its saved copies and preview files. It cannot be undone. Original files stay where they are. If the clipboard holds an item from the history, it is cleared too."
        }
    }
    /// The key that answers it, in its cap: "[⌘⌫] again deletes"; `spoken` is how VoiceOver says it.
    /// The same for one item and for a selection. Esc keeping it goes unsaid (vault rule, 2026-10-16).
    func keys(confirm: ClipboardKeyLabel) -> ClipboardHint {
        ClipboardHint([.key(confirm), .words(" again deletes")])
    }
}

/// What the image-text reader is doing, for the line beside the item count.
enum ClipboardIndexingNote: Equatable {
    case reading, failed(String)
    init?(_ entries: [ClipboardEntry]) {
        if entries.contains(where: { if case .pending = $0.searchIndex { return true }; return false }) { self = .reading; return }
        guard let message = entries.compactMap({ entry -> String? in
            if case .failed(let message) = entry.searchIndex { return message }; return nil
        }).first else { return nil }
        self = .failed(message)
    }
    var text: String { self == .reading ? "Reading image text…" : "Some image text is unavailable" }
    var help: String? { if case .failed(let message) = self { return message }; return nil }
}
