import AppKit

/// The back of a flipped card: everything an entry holds, as copied. A scrolling column with
/// the overview, then one block per flavor: its type, description and size on a header line
/// beside **Copy ⌥n**, over its content in a box, then quiet notes (how much is shown, a
/// picture's size). Every part is a selectable, non-editable text view, so a part of it can
/// be selected and copied on its own, by pointer or by key (the container's ⌘T or T moves the
/// keyboard from text to text; the arrows move in it, ⇧ with them selects). Content is plain
/// text only: HTML and RTF show as their source, never rendered. One view for the window's card
/// and the drawer's Quick Look; the container injects the keys, where the keyboard goes back to,
/// and, if it wants one, a ground (`surface`).
final class ClipboardRawDataView: ClipboardSurfaceView, ClipboardFlipFace {
    /// The key that copies flavor `n` (from 1), as the container's keymap shows and says it; nil for none.
    typealias Keys = (Int) -> ClipboardKeyLabel?
    /// ⌥1–⌥9: flavors beyond the ninth have no key.
    static let optionDigits: Keys = { number in
        (1...9).contains(number) ? ClipboardKeyLabel(shown: "⌥\(number)", spoken: "Option-\(number)") : nil
    }
    static let contentFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    /// Flavors built at once, then as many more each time the column is scrolled to within a
    /// screenful of its end: a Finder copy of a thousand files is a thousand pasteboard items,
    /// read and built a batch at a time rather than all before the card can turn.
    static let batch = 24

    enum Direction { case up, down }

    /// A flavor was copied, by its button or by `copyFlavor(number:)`.
    var onCopy: ((ClipboardRawData.Flavor) -> Void)?
    private(set) var raw: ClipboardRawData?
    private(set) var entryID: UUID?
    /// The flavor copied last: its button says *Copied* until another is copied or the entry changes.
    private(set) var copiedNumber: Int?

    /// Where Copy puts a flavor or a selection: the pasteboard given at init. A container routes it
    /// through its store instead, so the copy joins the history at once, as any copy does.
    var copier: (ClipboardRawCopy) -> Bool
    /// Where the keyboard goes when a text here holding it is about to go (another entry shown, the
    /// back turned away) or is left by key: its container's home, the search or the cards. The one
    /// rule for both containers; each says only where its home is.
    var returnKeyboard: () -> Void = {}
    /// One of its texts took the keyboard or let it go: the container's hints follow.
    var onKeyboardChange: (() -> Void)?
    private let keys: Keys
    private let scroll = NSScrollView()
    private let column = Column()
    private let heading = NSTextField(labelWithString: "Raw data")
    private let about = NSTextField(wrappingLabelWithString: "Every flavor this copy holds, as copied. Nothing is rendered: HTML and RTF show as their source.")
    /// How the container's keys read it (⌘T, Page Up and Page Down, Esc), in its keymap's words.
    private let guide = NSTextField(wrappingLabelWithString: "")
    private var guideHint: ClipboardHint?
    private let overview = ClipboardRawDataView.textView()
    /// The entry's overview as shown: a copy made again moves its time, and only then is it redrawn.
    private var shownOverview: ClipboardRawData.Overview?
    private var parts: [Part] = []
    private var blocks: [Block] { parts.compactMap { if case .flavor(let block) = $0 { return block }; return nil } }
    /// What is still to be built, in order: item headings and flavors past the batches built so far.
    private var unbuilt: ArraySlice<Planned> = []
    private var unbuiltFlavors = 0
    /// "… 976 more flavors below": the column's last line while flavors are still to be built.
    private let more = NSTextField(wrappingLabelWithString: "")
    /// The column width the parts were laid out for (-1: everything again) and how many of them,
    /// down to `columnBottom`; a batch built later is laid out from there.
    private var laidOutWidth: CGFloat = -1
    private var laidOutParts = 0
    private var columnBottom: CGFloat = 0
    private var scrollObserver: NSObjectProtocol?
    private static let inset: CGFloat = 14
    private static let gap: CGFloat = 14
    private static let textInset = NSSize(width: 8, height: 6)
    override var isFlipped: Bool { true }

    /// Copy writes to `pasteboard`: the general one in the app, a named one in tests.
    init(frame frameRect: NSRect = .zero, keys: @escaping Keys = ClipboardRawDataView.optionDigits, pasteboard: NSPasteboard = .general,
         guide guideHint: ClipboardHint? = nil) {
        self.keys = keys
        copier = { $0.write(to: pasteboard) }
        super.init(frame: frameRect)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        for label in [about, guide, more] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
        }
        self.guideHint = guideHint
        guide.attributedStringValue = guideHint?.attributed(font: guide.font ?? .systemFont(ofSize: 11), color: .secondaryLabelColor) ?? NSAttributedString()
        guide.isHidden = guideHint == nil
        more.isHidden = true
        overview.setAccessibilityLabel("Overview")
        overview.onKeyboardChange = { [weak self] in self?.keyboardChanged() }
        // In line with the heading, not boxed like the content.
        overview.textContainerInset = NSSize(width: 0, height: 2)
        scroll.documentView = column
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        [heading, about, guide, overview, more].forEach(column.addSubview)
        addSubview(scroll)
        // Scrolling near the column's end builds the next batch.
        scroll.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView,
                                                                queue: nil) { [weak self] _ in self?.buildMoreIfNear() }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Raw data")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { scrollObserver.map(NotificationCenter.default.removeObserver) }

    /// Its Copy keys and its guide from a container's keymap (⌥1–⌥9 in both), shown and said in its words.
    convenience init(keymap: ClipboardKeymap) {
        self.init(frame: .zero, keys: { number in
            keymap.label(.copyFlavor(number)).map { ClipboardKeyLabel(shown: $0, spoken: keymap.spoken(.copyFlavor(number)) ?? $0) }
        }, guide: Self.guide(keymap))
    }

    /// "[⌘T] selects text, again for the next  ·  [⇞] [⇟] scroll", each key in its cap: how a
    /// container's keys read the raw data. Nil unless its keymap has both. Esc leaving the text goes
    /// unsaid (2026-10-16).
    static func guide(_ keymap: ClipboardKeymap) -> ClipboardHint? {
        let pages = keymap.key(.pageUp).flatMap { up in keymap.key(.pageDown).map { ClipboardHint.key(up) + " " + .key($0) + " scroll" } }
        let parts = [keymap.key(.selectRawText).map { ClipboardHint.key($0) + " selects text, again for the next" }, pages].compactMap { $0 }
        return parts.count < 2 ? nil : ClipboardHint.joined(parts, separator: "  ·  ")
    }

    // MARK: Showing an entry

    /// This entry's raw data from the top, every part read afresh, or nothing. A text here holding
    /// the keyboard gives it back first: it is about to go.
    func show(_ entry: ClipboardEntry?) {
        giveBackKeyboard()
        entryID = entry?.id
        copiedNumber = nil
        parts.forEach { $0.views.forEach { $0.removeFromSuperview() } }
        parts = []
        raw = entry.map(ClipboardRawData.init(entry:))
        shownOverview = raw?.overview
        unbuilt = []
        unbuiltFlavors = 0
        if let raw {
            overview.textStorage?.setAttributedString(Self.overviewText(raw.overview))
            var plan: [Planned] = []
            for item in raw.items {
                if raw.items.count > 1 { plan.append(.itemHeading(item.number, of: raw.items.count)) }
                plan += item.flavors.map(Planned.flavor)
            }
            unbuilt = plan[...]
            unbuiltFlavors = raw.overview.flavorCount
            buildBatch()
            setAccessibilityLabel("Raw data: \(raw.overview.title)")
        } else {
            overview.string = ""
            more.isHidden = true
            setAccessibilityLabel("Raw data")
        }
        laidOutWidth = -1
        needsLayout = true
        column.scroll(.zero)
    }

    /// The entry its container shows now, kept up to date without starting over. Another entry is
    /// shown from the top. The same one, copied again (from here or elsewhere, which moves only its
    /// time), keeps its parts, its scroll, the keyboard, a selection and *Copied*; only the overview
    /// follows. Both containers keep their back up to date through here.
    func keepShowing(_ entry: ClipboardEntry?) {
        guard let entry, entry.id == entryID, raw != nil else {
            if entry != nil || entryID != nil || raw != nil { show(entry) }
            return
        }
        let now = ClipboardRawData.overview(of: entry)
        guard now != shownOverview else { return }
        shownOverview = now
        overview.textStorage?.setAttributedString(Self.overviewText(now))
        laidOutWidth = -1
        needsLayout = true
    }

    /// The next `batch` flavors, each item's heading before its first, at the column's end.
    private func buildBatch() {
        var added: [Part] = [], built = 0
        while built < Self.batch, let next = unbuilt.first {
            unbuilt = unbuilt.dropFirst()
            switch next {
            case .itemHeading(let number, let count):
                let label = NSTextField(wrappingLabelWithString: "Item \(number) of \(count)")
                label.font = .systemFont(ofSize: 12, weight: .semibold)
                added.append(.itemHeading(label))
            case .flavor(let flavor):
                added.append(.flavor(makeBlock(flavor)))
                built += 1
            }
        }
        unbuiltFlavors -= built
        parts += added
        added.flatMap(\.views).forEach(column.addSubview)
        more.stringValue = Self.moreText(unbuiltFlavors)
        more.isHidden = unbuiltFlavors == 0
        needsLayout = true
    }
    /// "… 976 more flavors below, shown as you scroll."
    static func moreText(_ count: Int) -> String {
        "… \(count.formatted()) more flavor\(count == 1 ? "" : "s") below, shown as you scroll."
    }

    /// Scrolled to within a screenful of the column's end, with flavors still to build: the next batch.
    private func buildMoreIfNear() {
        guard unbuiltFlavors > 0 else { return }
        let visible = scroll.documentVisibleRect
        guard visible.maxY >= column.frame.height - visible.height else { return }
        buildBatch()
    }

    private func makeBlock(_ flavor: ClipboardRawData.Flavor) -> Block {
        let block = Block(flavor: flavor)
        block.header.attributedStringValue = Self.headerText(flavor)
        block.header.isSelectable = true
        block.button.target = self
        block.button.action = #selector(copyPressed(_:))
        block.button.tag = flavor.number
        block.button.bezelStyle = .accessoryBarAction
        block.button.showsBorderOnlyWhileMouseInside = true
        block.button.font = .systemFont(ofSize: 11, weight: .medium)
        block.button.refusesFirstResponder = true // The keys in their titles reach them; Space never does.
        let key = keys(flavor.number)
        let what: String
        switch flavor.content {
        case .empty: what = "Nothing to copy: this flavor holds no bytes"
        case .text: what = "Copy all of this text, as plain text"
        case .bytes: what = "Copy these bytes as \(flavor.type.rawValue)"
        }
        let reach = key.map { " (\($0.spoken))" } ?? (flavor.number > 9 ? ". Only the first nine flavors have keys." : "")
        block.button.toolTip = what + reach
        block.button.spokenLabel = "\(what), flavor \(flavor.number), \(flavor.type.rawValue)\(reach)"
        block.button.isEnabled = flavor.content != .empty
        block.box.surface = ClipboardSurface(fill: .init(color: .textBackgroundColor), rim: .separatorColor, radius: 6, clips: true)
        block.box.isHidden = flavor.content == .empty
        block.text.setAccessibilityLabel("\(flavor.type.rawValue) content")
        block.text.onKeyboardChange = { [weak self] in self?.keyboardChanged() }
        block.box.addSubview(block.text)
        block.notes.font = .systemFont(ofSize: 11)
        block.notes.textColor = .secondaryLabelColor
        block.notes.stringValue = flavor.notes.joined(separator: "\n")
        block.notes.isHidden = flavor.notes.isEmpty
        if case .text(let text) = flavor.content { block.setContent(text.shown) }
        updateTitle(block)
        return block
    }

    private func updateTitle(_ block: Block) {
        let name = copiedNumber == block.flavor.number ? "Copied" : "Copy"
        block.button.keyedTitle = ClipboardKeyedTitle(name: name, key: keys(block.flavor.number))
    }

    // MARK: Copying

    /// Copies flavor `number` (from 1) as its button does: text as the whole decoded text, bytes
    /// under their own type, whether or not its block is built yet. False when there is no such
    /// flavor or nothing to copy.
    @discardableResult
    func copyFlavor(number: Int) -> Bool {
        guard let flavor = blocks.first(where: { $0.flavor.number == number })?.flavor ?? raw?.flavors.first(where: { $0.number == number }),
              let copy = flavor.copy, copier(copy) else { return false }
        copiedNumber = number
        blocks.forEach(updateTitle)
        laidOutWidth = -1 // "Copied" is wider than "Copy": the header beside it rewraps.
        needsLayout = true
        let element: NSView = blocks.first { $0.flavor.number == number }?.button ?? self
        NSAccessibility.post(element: element, notification: .announcementRequested,
                             userInfo: [.announcement: "Copied flavor \(number), \(flavor.type.rawValue)",
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
        onCopy?(flavor)
        return true
    }
    @objc private func copyPressed(_ sender: NSButton) { copyFlavor(number: sender.tag) }

    /// The text selected in whichever of this view's text views holds the keyboard; nil when
    /// the keyboard is elsewhere or nothing is selected.
    var selectedText: String? {
        guard let text = keyboardText else { return nil }
        let string = text.string as NSString
        let parts = text.selectedRanges.map(\.rangeValue).filter { $0.length > 0 && NSMaxRange($0) <= string.length }
        return parts.isEmpty ? nil : parts.map { string.substring(with: $0) }.joined(separator: "\n")
    }
    /// ⌘C and ⌘A for the text being read here. ClipEdge has no Edit menu, so the container's key
    /// handling asks this first. ⌘C copies just the selection, as plain text; ⌘A selects all of
    /// the text view holding the keyboard. False for other keys, when the keyboard is elsewhere,
    /// and for ⌘C with nothing selected, so the container's own ⌘C (the window's pick-up) acts then.
    func handleEditingKey(_ event: NSEvent) -> Bool {
        guard let text = keyboardText, let command = ClipboardFieldEditing.command(for: event) else { return false }
        switch command {
        case .copy:
            guard let selected = selectedText else { return false }
            _ = copier(.text(selected))
            return true
        case .selectAll:
            text.selectAll(nil)
            return true
        case .cut, .paste, .undo, .redo:
            return false
        }
    }
    /// One of its text views holds its window's keyboard (a click or the container's ⌘T or T put
    /// it there, to read and select).
    var holdsKeyboard: Bool { keyboardText != nil }
    /// The overview's, a header's (through its field editor) or a content's text view, when it holds the keyboard.
    private var keyboardText: NSTextView? {
        guard let text = window?.firstResponder as? NSTextView, text.isDescendant(of: self) else { return nil }
        return text
    }
    /// A text here holding the keyboard gives it to the container's home.
    func giveBackKeyboard() {
        if holdsKeyboard { returnKeyboard() }
    }
    /// The keys a text being read moves its caret and extends its selection with: the arrows, Home
    /// and End, with any modifiers. While one of its texts holds the keyboard, they are the text's,
    /// not the list's (the window's ⇧↑ and ⇧↓ would otherwise mark cards, its ↑ and ↓ choose another).
    static func isTextNavigation(_ event: NSEvent) -> Bool { [115, 119, 123, 124, 125, 126].contains(event.keyCode) }

    // MARK: Reading by key

    /// The container's ⌘T or T: the keyboard to the next of its texts, top to bottom (the overview,
    /// then each flavor's content), after the last the overview again. The caret starts at the text's
    /// beginning, scrolled into view with its header; the arrows move it and ⇧ with them selects.
    /// False when it shows nothing, or is in no window.
    @discardableResult
    func selectNextText() -> Bool {
        guard raw != nil, let window else { return false }
        layoutSubtreeIfNeeded()
        let stops: [NSTextView] = [overview] + blocks.filter { !$0.box.isHidden }.map(\.text)
        let current = keyboardText.flatMap { text in stops.firstIndex { $0 === text } }
        let next = stops[current.map { ($0 + 1) % stops.count } ?? 0]
        guard window.makeFirstResponder(next) else { return false }
        next.setSelectedRange(NSRange(location: 0, length: 0))
        let region = blocks.first { $0.text === next }.map { $0.header.frame.union($0.box.frame) } ?? heading.frame.union(overview.frame)
        column.scrollToVisible(NSRect(x: region.minX, y: region.minY, width: region.width, height: min(region.height, scroll.contentSize.height)))
        return true
    }

    /// Page Up or Page Down: the column a screenful up or down, a line of the last kept in view.
    /// False when it shows nothing.
    @discardableResult
    func page(_ direction: Direction) -> Bool {
        guard raw != nil else { return false }
        layoutSubtreeIfNeeded()
        let clip = scroll.contentView
        let height = clip.bounds.height
        let step = max(height - 24, height / 2)
        let limit = max(0, column.frame.height - height)
        let y = min(max(0, clip.bounds.minY + (direction == .down ? step : -step)), limit)
        clip.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(clip)
        return true
    }

    /// The text holding the keyboard changed: said on the next turn of the run loop, once the window
    /// has settled which view holds it.
    private func keyboardChanged() {
        DispatchQueue.main.async { [weak self] in self?.onKeyboardChange?() }
    }

    // MARK: Turned away

    func faceWillTurnAway() { giveBackKeyboard() }
    /// Hidden, it lets go of what it read: nothing of a deleted entry stays behind it, and it reads
    /// the entry afresh when next turned to.
    func faceDidTurnAway() { show(nil) }

    // MARK: For tests and captures

    /// What one flavor's block shows.
    struct ShownBlock: Equatable {
        let number: Int
        let header: String
        let button: String
        let help: String
        let isEnabled: Bool
        /// The text in the content box, exactly as stored; nil for an empty flavor.
        let content: String?
        let notes: String?
    }
    /// The blocks built so far: the first `batch`, more as the column is scrolled.
    var shownBlocks: [ShownBlock] {
        blocks.map { block in
            ShownBlock(number: block.flavor.number, header: block.header.stringValue, button: block.button.keyedTitle.plain,
                       help: block.button.toolTip ?? "", isEnabled: block.button.isEnabled,
                       content: block.box.isHidden ? nil : block.text.string, notes: block.notes.isHidden ? nil : block.notes.stringValue)
        }
    }
    var itemHeadings: [String] { parts.compactMap { if case .itemHeading(let label) = $0 { return label.stringValue }; return nil } }
    var overviewText: String { overview.string }
    var overviewView: NSTextView { overview }
    var guideText: String? { guide.isHidden ? nil : guideHint?.plain }
    /// "… 976 more flavors below, shown as you scroll" while flavors are still to be built.
    var moreNote: String? { more.isHidden ? nil : more.stringValue }
    /// Flavor `number`'s content text view.
    func contentView(of number: Int) -> NSTextView? { blocks.first { $0.flavor.number == number }?.text }
    /// Where the caret of the text holding the keyboard is drawn, in that text's coordinates; nil
    /// with nothing holding it or something selected.
    var caretRect: NSRect? {
        guard let text = keyboardText as? ClipboardReadingTextView, text.selectedRange().length == 0 else { return nil }
        return text.caretRect
    }
    func button(of number: Int) -> ClipboardKeyedButton? { blocks.first { $0.flavor.number == number }?.button }
    /// The scrolling column: its width is the visible width, so nothing scrolls sideways.
    var documentFrame: NSRect { column.frame }
    var visibleWidth: CGFloat { scroll.contentSize.width }
    /// How far down the column is scrolled.
    var scrollOffset: CGFloat { scroll.contentView.bounds.minY }
    /// Where its scrolling shows, in its own coordinates: nothing it holds shows above this.
    var scrollFrame: NSRect { scroll.frame }

    // MARK: Layout

    override func layout() {
        super.layout()
        // Scrolling starts where the content does, 14 points in: text scrolled up stops short of
        // what sits over the top edge (the window card's Preview ⌘I magnet, 9 points above it;
        // Quick Look's controls).
        scroll.frame = NSRect(x: 0, y: Self.inset, width: bounds.width, height: max(0, bounds.height - Self.inset))
        // A scroller that appears takes width (with legacy scrollers): lay out again at the new
        // width. A batch built since is laid out below what was.
        for _ in 0..<2 {
            let width = scroll.contentSize.width
            if width != laidOutWidth { layoutColumn(width: width, from: 0) }
            else if laidOutParts < parts.count { layoutColumn(width: width, from: laidOutParts) }
            else { break }
        }
        // A column too short to scroll could never reach its next batch: build until it fills twice its view.
        while unbuiltFlavors > 0, scroll.contentSize.height > 0, columnBottom < scroll.contentSize.height * 2 {
            buildBatch()
            layoutColumn(width: laidOutWidth, from: laidOutParts)
        }
    }

    /// The column from part `start` down (from the top, its heading and overview included, when 0).
    private func layoutColumn(width: CGFloat, from start: Int) {
        let inset = Self.inset
        let inner = max(0, width - inset * 2)
        var y: CGFloat
        if start == 0 {
            // The scroller starts 14 points down already (layout()).
            y = 0
            for label in [heading, about, guide] where !label.isHidden {
                let height = Self.height(of: label, width: inner)
                label.frame = NSRect(x: inset, y: y, width: inner, height: height)
                y += height + 4
            }
            overview.frame = NSRect(x: inset, y: y, width: inner, height: Self.height(of: overview, width: inner))
            y = overview.frame.maxY + Self.gap
        } else {
            y = columnBottom
        }
        for part in parts[start...] {
            switch part {
            case .itemHeading(let label):
                let height = Self.height(of: label, width: inner)
                label.frame = NSRect(x: inset, y: y, width: inner, height: height)
                y += height + 6
            case .flavor(let block):
                y = layout(block, x: inset, y: y, width: inner) + Self.gap
            }
        }
        columnBottom = y
        laidOutParts = parts.count
        laidOutWidth = width
        if !more.isHidden {
            let height = Self.height(of: more, width: inner)
            more.frame = NSRect(x: inset, y: y, width: inner, height: height)
            y += height + Self.gap
        }
        column.frame = NSRect(x: 0, y: 0, width: width, height: max(y - Self.gap + inset, scroll.contentSize.height))
    }

    /// One block from `y`: the header beside its button, the box, the notes. Returns where it ends.
    private func layout(_ block: Block, x: CGFloat, y top: CGFloat, width: CGFloat) -> CGFloat {
        let button = NSSize(width: ceil(block.button.intrinsicContentSize.width) + 6, height: 22)
        let headerWidth = max(0, width - button.width - 8)
        let headerHeight = Self.height(of: block.header, width: headerWidth)
        let row = max(button.height, headerHeight)
        block.button.frame = NSRect(x: x + width - button.width, y: top, width: button.width, height: button.height)
        block.header.frame = NSRect(x: x, y: top + max(0, (button.height - headerHeight) / 2), width: headerWidth, height: headerHeight)
        var y = top + row + 4
        if !block.box.isHidden {
            if case .bytes(let bytes) = block.flavor.content {
                let perRow = Self.bytesPerRow(fitting: width - Self.textInset.width * 2)
                if perRow != block.bytesPerRow {
                    block.bytesPerRow = perRow
                    block.setContent(bytes.dump(bytesPerRow: perRow))
                }
            }
            let height = Self.height(of: block.text, width: width)
            block.box.frame = NSRect(x: x, y: y, width: width, height: height)
            block.text.frame = block.box.bounds
            y = block.box.frame.maxY + 4
        }
        if !block.notes.isHidden {
            let height = Self.height(of: block.notes, width: width)
            block.notes.frame = NSRect(x: x, y: y, width: width, height: height)
            y += height + 4
        }
        return y - 4
    }

    /// The most bytes a hex dump row can show in `width` points: 16, 8 or 4.
    static func bytesPerRow(fitting width: CGFloat) -> Int {
        let advance = ("0" as NSString).size(withAttributes: [.font: contentFont]).width
        return [16, 8, 4].first { CGFloat(ClipboardRawData.hexLineLength(bytesPerRow: $0)) * advance <= width - 1 } ?? 4
    }

    private static func height(of label: NSTextField, width: CGFloat) -> CGFloat {
        ceil(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 100_000)).height ?? 0)
    }
    /// The text's whole height at this width, laid out now: the column scrolls, the text view never does.
    private static func height(of text: NSTextView, width: CGFloat) -> CGFloat {
        text.setFrameSize(NSSize(width: width, height: max(1, text.frame.height)))
        guard let layout = text.layoutManager, let container = text.textContainer else { return 0 }
        layout.ensureLayout(for: container)
        return ceil(layout.usedRect(for: container).height + text.textContainerInset.height * 2)
    }

    /// Selectable, never editable or rich: what it holds is shown as characters, nothing is
    /// loaded, linked or rendered. TextKit 1, so its height can be measured before it shows.
    private static func textView() -> ClipboardReadingTextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        let text = ClipboardReadingTextView(frame: .zero, textContainer: container)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.importsGraphics = false
        text.allowsImageEditing = false
        text.isAutomaticLinkDetectionEnabled = false
        text.isAutomaticDataDetectionEnabled = false
        text.usesFontPanel = false
        text.drawsBackground = false
        text.isVerticallyResizable = false
        text.isHorizontallyResizable = false
        text.textContainerInset = textInset
        text.font = contentFont
        text.textColor = .labelColor
        return text
    }

    private static func headerText(_ flavor: ClipboardRawData.Flavor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let header = NSMutableAttributedString(string: flavor.type.rawValue, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
        header.append(NSAttributedString(string: "  " + flavor.details.joined(separator: " · "), attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph]))
        return header
    }

    /// Each row's label in a column, its value after a tab stop; a value that wraps stays in its column.
    private static func overviewText(_ overview: ClipboardRawData.Overview) -> NSAttributedString {
        let labelFont = NSFont.systemFont(ofSize: 11)
        let rows = overview.rows
        let labelWidth = ceil(rows.map { ($0.label as NSString).size(withAttributes: [.font: labelFont]).width }.max() ?? 0) + 12
        func paragraph(_ wrapping: NSLineBreakMode) -> NSParagraphStyle {
            let paragraph = NSMutableParagraphStyle()
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: labelWidth)]
            paragraph.headIndent = labelWidth
            paragraph.lineBreakMode = wrapping
            paragraph.paragraphSpacing = 2
            return paragraph
        }
        let words = paragraph(.byWordWrapping), code = paragraph(.byCharWrapping)
        let text = NSMutableAttributedString()
        for (index, row) in rows.enumerated() {
            // A fingerprint has no spaces: broken anywhere, it starts beside its label.
            let style = row.isCode ? code : words
            text.append(NSAttributedString(string: row.label + "\t", attributes: [
                .font: labelFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style]))
            text.append(NSAttributedString(string: row.value + (index < rows.count - 1 ? "\n" : ""), attributes: [
                .font: row.isCode ? contentFont : NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor, .paragraphStyle: style]))
        }
        return text
    }

    // MARK: Parts

    /// The column the scroll view moves: top-down, as the card is.
    private final class Column: NSView {
        override var isFlipped: Bool { true }
    }

    /// What is still to be built: "Item 1 of 2" before that item's flavors, when an entry has several.
    private enum Planned {
        case itemHeading(Int, of: Int)
        case flavor(ClipboardRawData.Flavor)
    }

    private enum Part {
        /// "Item 1 of 2", before that item's flavors, when an entry has several.
        case itemHeading(NSTextField)
        case flavor(Block)
        var views: [NSView] {
            switch self {
            case .itemHeading(let label): return [label]
            case .flavor(let block): return [block.header, block.button, block.box, block.notes]
            }
        }
    }

    /// One flavor's views.
    private final class Block {
        let flavor: ClipboardRawData.Flavor
        let header = NSTextField(wrappingLabelWithString: "")
        let button = ClipboardKeyedButton(title: "Copy", target: nil, action: nil)
        let box = ClipboardSurfaceView()
        let text = ClipboardRawDataView.textView()
        let notes = NSTextField(wrappingLabelWithString: "")
        /// The hex dump's row length the text was last built for; 0 before the first layout.
        var bytesPerRow = 0
        init(flavor: ClipboardRawData.Flavor) { self.flavor = flavor }

        /// Characters only, in the content font: never markup that something could render.
        func setContent(_ string: String) {
            text.textStorage?.setAttributedString(NSAttributedString(string: string, attributes: [
                .font: ClipboardRawDataView.contentFont, .foregroundColor: NSColor.labelColor]))
        }
    }
}
