import AppKit

/// Named boards only; no keyboard-layout switch or global input events.
@main enum AccessKeysTests {
    static var count = 0
    static func check(_ value: Bool, _ why: String) { count += 1; precondition(value, why) }
    static func key(_ code: UInt16, _ text: String, _ flags: NSEvent.ModifierFlags = .command) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                        context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
    }
    static func main() {
        _ = NSApplication.shared
        let commands: [(UInt16, String, ClipboardFieldEditing.Command)] = [(0, "ф", .selectAll), (8, "с", .copy), (7, "ч", .cut), (9, "м", .paste), (6, "я", .undo)]
        for (code, letter, expected) in commands {
            check(ClipboardFieldEditing.command(for: key(code, letter)) == expected, "Cyrillic editing chord")
            check(ClipboardFieldEditing.command(for: key(code, letter, [.command, .option])) == nil, "extra modifiers do not edit")
        }
        check(ClipboardFieldEditing.command(for: key(6, "я", [.command, .shift])) == .redo, "Cyrillic redo")
        check(ClipboardFieldEditing.command(for: key(8, "j")) == nil, "Dvorak J at QWERTY C is not Copy")
        check(ClipboardFieldEditing.command(for: key(34, "c")) == .copy, "Latin C follows its layout")
        for letter in ["α", "ש", "ش"] {
            check(ClipboardFieldEditing.command(for: key(0, letter)) == .selectAll, "Greek, Hebrew and Arabic select all")
        }
        let publish = ClipboardPublishControl()
        publish.apply(PublishState.different(.init(latestVersion: "2.3", detail: "fixture")).presentation)
        check(publish.accessibilityLabel()?.contains("Shift-Command-P") == true, "Publish speaks its chord")
        publish.isHidden = false; publish.isEnabled = true
        var presses = 0; publish.onPress = { presses += 1 }
        check(publish.handleKey(key(35, "з", [.command, .shift])) && presses == 1, "non-Latin Publish reaches action")
        check(!publish.handleKey(key(35, "l", [.command, .shift])), "other Latin letter does not publish")
        let value = ClipboardPayload(values: [(.string, Data("A long fixture title with the complete path /Users/fixture/Documents/very-long-name.txt".utf8))])
        let item = ClipboardEntry(fingerprint: "fixture", capturedAt: Date(timeIntervalSince1970: 1791225000), payloads: [value], title: "A long fixture title", detail: "", kind: .text, thumbnail: nil)
        let row = ClipboardTile(entry: item, style: .compact, keymap: .window)
        check(row.toolTip == nil, "a row out of the list's view tree is dormant: no tooltip yet")
        // In the list's view tree, as a row near what shows is (`ClipboardCanvas.attachVisible`).
        NSView().addSubview(row)
        check(row.toolTip?.contains("very-long-name.txt") == true, "whole text available without selecting")
        let spoken = ClipboardTileTooltip.legendText(.drawer, asker: nil, spoken: true)
        check(spoken.contains("Command-O") && spoken.contains("Shift-Up Arrow") && spoken.contains("Command-click"), "legend uses spoken chord names")
        check(!spoken.contains("⌘") && !spoken.contains("⇧"), "legend has no spoken key symbols")
        for theme in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp.appearance = NSAppearance(named: theme)
            let held = ClipboardAttachmentView.makeHeldPreview(for: item, maximumAttachmentPixels: 480, holdingGlyphHeight: 25).view
            let captions = held.subviews.compactMap { $0 as? NSTextField }
            check(!captions.isEmpty && captions.allSatisfy { !$0.drawsBackground }, "caption does not paint square blocks in \(theme)")
        }
        print("PASS: \(count) accessibility/key assertions")
    }
}
