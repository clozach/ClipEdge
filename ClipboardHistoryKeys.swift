import AppKit

/// What a key press means in the history window while browsing. Keys with no
/// command (letters, ⌫, ⌥⌫) go to the search field, which keeps the keyboard.
enum ClipboardHistoryCommand: Equatable {
    case newer, older, paste, plainPaste, pickUp, sendTo, openInPreview, delete, deleteAll, escape
    /// ⌘F: select the search text, so the next letter starts a new search.
    case find
    case tab(ClipboardBrowserTab)
    /// Keys that would otherwise move the keyboard out of the search field.
    case ignore

    static func command(for event: NSEvent) -> ClipboardHistoryCommand? {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let character = event.charactersIgnoringModifiers?.lowercased()
        switch (event.keyCode, modifiers) {
        // Left and right select too, so the caret stays at the end of the search.
        case (126, []), (123, []): return .newer
        case (125, []), (124, []): return .older
        case (36, []), (76, []): return .paste
        case (36, [.control, .command]), (76, [.control, .command]): return .plainPaste
        case (36, _), (76, _): return .ignore
        case (48, []): return .sendTo
        case (48, [.shift]): return .ignore
        case (53, []): return .escape
        case (51, [.command]): return .delete
        case (51, [.shift, .command]): return .deleteAll
        case (_, [.command]):
            // Number keys by position, so ⌘1–⌘3 work on layouts without digits there.
            if let tab = [18: ClipboardBrowserTab.all, 19: .images, 20: .text][event.keyCode] { return .tab(tab) }
            if character == "c" { return .pickUp }
            if character == "o" { return .openInPreview }
            if character == "f" { return .find }
            return nil
        default: return nil
        }
    }
}
