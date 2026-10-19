import AppKit

extension NSEvent.ModifierFlags {
    /// The modifiers a chord is made of, ⌘ ⌃ ⌥ ⇧, without Caps Lock, Fn or the keypad's flag.
    var chord: NSEvent.ModifierFlags { intersection([.command, .control, .option, .shift]) }
}

extension NSEvent {
    /// The chord modifiers held for this key press.
    var chordModifiers: NSEvent.ModifierFlags { modifierFlags.chord }
}

/// One key press a keymap answers: a key, by position or by what it types, and its modifiers.
struct ClipboardChord: Equatable {
    enum Key: Equatable {
        /// By position, whatever the layout types there: arrows, Return, the number row.
        case code(UInt16)
        /// By the character it types, wherever the layout puts it: the comma.
        case character(String)
        /// By the letter it types, or by its position on layouts without Latin letters
        /// (Cyrillic, Greek, Hebrew), as their own ⌘ tables do. Dvorak's u on F's place is u.
        case letter(String, position: UInt16)
    }
    enum Modifiers: Equatable {
        case exactly(NSEvent.ModifierFlags)
        /// With or without any modifier.
        case any
    }
    let key: Key
    let modifiers: Modifiers

    func matches(_ event: NSEvent) -> Bool {
        switch modifiers {
        case .exactly(let flags): guard event.chordModifiers == flags else { return false }
        case .any: break
        }
        let typed = event.charactersIgnoringModifiers?.lowercased()
        switch key {
        case .code(let code): return event.keyCode == code
        case .character(let character): return typed == character
        case .letter(let letter, let position):
            return typed == letter || (event.keyCode == position && typed?.unicodeScalars.contains { !$0.isASCII } == true)
        }
    }
}
