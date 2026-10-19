import AppKit

/// A name and the key that reaches it, shown apart (Al, 2026-10-15): the name in the control's own
/// type, then the key in a darker-gray rounded rectangle, so *Images 2* never reads as two images.
/// Tabs draw it in their segments; a button shows the cap as its image, after its title.
struct ClipboardKeyedTitle: Equatable {
    let name: String
    /// Nil where the action has no key in this container: the name alone.
    let key: ClipboardKeyLabel?

    /// The same words as plain text, for a place that cannot draw a key cap: "Images 2".
    var plain: String { key.map { "\(name) \($0.shown)" } ?? name }
    /// As VoiceOver says it: "Images, 2"; "Images, Command-2".
    var spoken: String { key.map { "\(name), \($0.spoken)" } ?? name }

    /// Name, gap and key cap, at `font`.
    func size(font: NSFont) -> NSSize {
        let name = (self.name as NSString).size(withAttributes: [.font: font])
        guard let key else { return NSSize(width: ceil(name.width), height: ceil(name.height)) }
        let cap = ClipboardKeyCap.size(key.shown, beside: font)
        return NSSize(width: ceil(name.width) + ClipboardKeyCap.gap + cap.width, height: max(ceil(name.height), cap.height))
    }

    /// Drawn centered in `rect`, the name in `color` and the key cap after it.
    /// `glyph`: the key's color inside its cap (gray by default; on an accent-filled selected tab,
    /// the selected text's color, so it reads there too).
    func draw(centeredIn rect: NSRect, font: NSFont, color: NSColor, glyph: NSColor = .secondaryLabelColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let nameSize = (name as NSString).size(withAttributes: attributes)
        let x = round(rect.midX - size(font: font).width / 2)
        (name as NSString).draw(at: NSPoint(x: x, y: round(rect.midY - nameSize.height / 2)), withAttributes: attributes)
        guard let key else { return }
        let cap = ClipboardKeyCap.size(key.shown, beside: font)
        ClipboardKeyCap.draw(key.shown, in: NSRect(x: x + ceil(nameSize.width) + ClipboardKeyCap.gap,
                                                   y: round(rect.midY - cap.height / 2), width: cap.width, height: cap.height),
                             beside: font, glyph: glyph)
    }

    /// In running text: the name, then the key in its cap.
    func attributed(font: NSFont, color: NSColor) -> NSAttributedString {
        ClipboardHint(self).attributed(font: font, color: color)
    }

    /// On a button: the name as its title and the key cap as its image after it, so the button keeps
    /// its own title color and states; VoiceOver reads the spoken form.
    func apply(to button: NSButton) {
        button.title = name
        button.image = key.map { ClipboardKeyCap.image($0.shown, beside: button.font ?? .systemFont(ofSize: NSFont.systemFontSize)) }
        button.imagePosition = key == nil ? .noImage : .imageTrailing
        button.imageHugsTitle = true
        button.setAccessibilityLabel(spoken)
    }
}

/// A button whose title is a name and a key in its cap: every keyed button is one of these, so its
/// plain words ("Paste ⏎") stay readable where the cap is drawn as an image.
class ClipboardKeyedButton: NSButton {
    var keyedTitle = ClipboardKeyedTitle(name: "", key: nil) {
        didSet {
            keyedTitle.apply(to: self)
            if let spokenLabel { setAccessibilityLabel(spokenLabel) }
        }
    }
    /// What VoiceOver says where it says more than the title ("Paste the selected item where you
    /// were (Return)"), kept as the title changes; nil for the title's own spoken form.
    var spokenLabel: String? { didSet { setAccessibilityLabel(spokenLabel ?? keyedTitle.spoken) } }
}

/// The darker-gray rounded rectangle a key sits in: two points smaller than the name beside it, as
/// tall as the name's line and a little more, never narrower than it is tall.
enum ClipboardKeyCap {
    /// Between the name and its cap.
    static let gap: CGFloat = 5

    static func font(beside font: NSFont) -> NSFont {
        .monospacedDigitSystemFont(ofSize: max(9, font.pointSize - 2), weight: .medium)
    }
    /// A key the keymap names with an alternative, "⌫ or ⌘⌫", is two caps with *or* between, in
    /// the name's type: never "or" inside a cap.
    private static let alternative = " or "
    static func size(_ key: String, beside font: NSFont) -> NSSize {
        let pieces = key.components(separatedBy: alternative)
        guard pieces.count > 1 else { return single(key, beside: font) }
        let or = ceil((alternative as NSString).size(withAttributes: [.font: font]).width)
        let caps = pieces.map { single($0, beside: font) }
        return NSSize(width: caps.reduce(0) { $0 + $1.width } + or * CGFloat(pieces.count - 1), height: caps.map(\.height).max() ?? 0)
    }
    private static func single(_ key: String, beside font: NSFont) -> NSSize {
        let capFont = Self.font(beside: font)
        let text = (key as NSString).size(withAttributes: [.font: capFont])
        let height = ceil(capFont.ascender - capFont.descender) + 5
        return NSSize(width: max(height, ceil(text.width) + 9), height: height)
    }
    /// Darker than whatever it sits on, in light and dark alike.
    static let fill = NSColor(name: "ClipEdgeKeyCap") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.black.withAlphaComponent(0.32) : NSColor.black.withAlphaComponent(0.11)
    }
    /// The cap inside running text at `font`, centred on its letters' middle.
    static func attachment(_ key: String, beside font: NSFont) -> NSAttributedString {
        let attachment = NSTextAttachment()
        let image = image(key, beside: font)
        attachment.image = image
        let middle = (font.ascender + font.descender) / 2
        attachment.bounds = NSRect(x: 0, y: round(middle - image.size.height / 2), width: image.size.width, height: image.size.height)
        return NSAttributedString(attachment: attachment)
    }

    /// The cap alone, drawn whenever it is drawn, so it follows the appearance it is drawn in.
    static func image(_ key: String, beside font: NSFont) -> NSImage {
        NSImage(size: size(key, beside: font), flipped: false) { rect in
            draw(key, in: rect, beside: font)
            return true
        }
    }
    static func draw(_ key: String, in rect: NSRect, beside font: NSFont, glyph: NSColor = .secondaryLabelColor) {
        let pieces = key.components(separatedBy: alternative)
        guard pieces.count > 1 else { return drawSingle(key, in: rect, beside: font, glyph: glyph) }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: glyph]
        let or = (alternative as NSString).size(withAttributes: attributes)
        var x = rect.minX
        for (index, piece) in pieces.enumerated() {
            if index > 0 {
                (alternative as NSString).draw(at: NSPoint(x: x, y: round(rect.midY - or.height / 2)), withAttributes: attributes)
                x += ceil(or.width)
            }
            let cap = single(piece, beside: font)
            drawSingle(piece, in: NSRect(x: x, y: round(rect.midY - cap.height / 2), width: cap.width, height: cap.height), beside: font, glyph: glyph)
            x += cap.width
        }
    }
    private static func drawSingle(_ key: String, in rect: NSRect, beside font: NSFont, glyph: NSColor) {
        let radius = rect.height / 4
        fill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        // Gray, so the name beside it leads (Al chose this look on 2026-10-15).
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font(beside: font), .foregroundColor: glyph]
        let text = (key as NSString).size(withAttributes: attributes)
        // Its line's box centered on the cap, in flipped views and others alike.
        (key as NSString).draw(at: NSPoint(x: round(rect.midX - text.width / 2), y: round(rect.midY - text.height / 2)), withAttributes: attributes)
    }
}

/// A line naming keys among its words, each key in its cap (2026-10-16): *Quick Look* [Space] · [⌃⌥Space],
/// [⏎] *or click selects* · [⇧⌘A] *all*. Its parts keep words and keys apart, so a key is never
/// glued into the words by string building.
struct ClipboardHint: Equatable, ExpressibleByStringLiteral {
    enum Part: Equatable {
        case words(String)
        case key(ClipboardKeyLabel)
    }
    private(set) var parts: [Part]

    init(_ parts: [Part]) { self.parts = parts }
    init(stringLiteral words: String) { parts = words.isEmpty ? [] : [.words(words)] }
    init(_ words: String) { self.init(stringLiteral: words) }
    /// A name and its key, as a title shows them.
    init(_ title: ClipboardKeyedTitle) {
        parts = [.words(title.name)] + (title.key.map { [.words(" "), .key($0)] } ?? [])
    }
    static func key(_ label: ClipboardKeyLabel) -> ClipboardHint { ClipboardHint([.key(label)]) }

    var isEmpty: Bool { parts.isEmpty }
    /// As plain text, keys shown as typed: "⏎ or click selects".
    var plain: String { parts.map { part in switch part { case .words(let words): return words; case .key(let key): return key.shown } }.joined() }
    /// As VoiceOver says it: "Return or click selects".
    var spoken: String { parts.map { part in switch part { case .words(let words): return words; case .key(let key): return key.spoken } }.joined() }

    static func + (left: ClipboardHint, right: ClipboardHint) -> ClipboardHint { ClipboardHint(left.parts + right.parts) }
    /// Several hints in a row, with `separator` between each two.
    static func joined(_ hints: [ClipboardHint], separator: String) -> ClipboardHint {
        hints.filter { !$0.isEmpty }.enumerated().reduce(ClipboardHint([])) { line, item in
            item.offset == 0 ? item.element : line + ClipboardHint(stringLiteral: separator) + item.element
        }
    }

    /// The words in `color` and each key in its cap, at `font`; aligned, when `alignment` is given,
    /// since a label's own alignment does not reach an attributed value.
    func attributed(font: NSFont, color: NSColor, alignment: NSTextAlignment? = nil) -> NSAttributedString {
        let line = NSMutableAttributedString()
        for part in parts {
            switch part {
            case .words(let words): line.append(NSAttributedString(string: words, attributes: [.font: font, .foregroundColor: color]))
            case .key(let key): line.append(ClipboardKeyCap.attachment(key.shown, beside: font))
            }
        }
        if let alignment {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = alignment
            line.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: line.length))
        }
        return line
    }
}
