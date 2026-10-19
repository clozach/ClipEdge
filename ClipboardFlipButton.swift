import AppKit

/// The control that turns a card over to its raw data and back (Al, 2026-10-12): *Raw data ⌘I* on
/// the front, *Preview ⌘I* on the back. One button for both places, titled from its container's
/// keymap: the ⌥⌘\ window's magnet at its card's corner (its footer item reads the same words), and
/// Quick Look beside the drawer (*Raw data I*). It never takes the keyboard: the search or the cards
/// keep it, and the key in its title acts from there.
final class ClipboardFlipButton: ClipboardKeyedButton {
    var onPress: (() -> Void)?
    /// The side its card shows; the button offers the other.
    private(set) var side: ClipboardFlipView.Side = .front
    private let keymap: ClipboardKeymap

    init(keymap: ClipboardKeymap) {
        self.keymap = keymap
        super.init(frame: .zero)
        setButtonType(.momentaryPushIn)
        bezelStyle = .accessoryBarAction
        font = .systemFont(ofSize: 11, weight: .medium)
        refusesFirstResponder = true
        target = self
        action = #selector(pressed)
        reflect(.front)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// What it reads with its card on `side`: the face it turns to.
    static func name(for side: ClipboardFlipView.Side) -> String { side == .front ? "Raw data" : "Preview" }
    /// What it does, for its tooltip and the footer's.
    static func help(for side: ClipboardFlipView.Side) -> String {
        side == .front ? "Turn the card over: every flavor this copy holds, as copied, each part selectable and copyable"
            : "Turn the card back to its preview"
    }

    /// The card turned (or is turning) to `side`.
    func reflect(_ side: ClipboardFlipView.Side) {
        self.side = side
        let name = Self.name(for: side)
        keyedTitle = keymap.keyed(name, .flip)
        toolTip = Self.help(for: side) + (keymap.spoken(.flip).map { " (\($0))" } ?? "")
        setAccessibilityHelp(Self.help(for: side))
    }

    @objc private func pressed() { onPress?() }
}
