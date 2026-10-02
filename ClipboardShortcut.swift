import AppKit
import Carbon

/// A global shortcut always has a supported key and a non-Shift modifier.
/// Invalid persisted values cannot bypass the same rules as the recorder.
struct ClipboardShortcut: Equatable, Codable {
    let keyCode: UInt32
    private let modifierBits: UInt
    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierBits) }
    static let defaultQuickLook = ClipboardShortcut(keyCode: UInt32(kVK_Space), modifiers: [.control, .option])!

    init?(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        let flags = modifiers.intersection([.control, .option, .shift, .command])
        guard keyCode < 128, !Self.modifierKeys.contains(keyCode),
              !flags.intersection([.control, .option, .command]).isEmpty else { return nil }
        self.keyCode = keyCode
        modifierBits = flags.rawValue
    }

    private enum CodingKeys: String, CodingKey { case keyCode, modifierBits }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let code = try values.decode(UInt32.self, forKey: .keyCode)
        let flags = try values.decode(UInt.self, forKey: .modifierBits)
        guard let value = Self(keyCode: code, modifiers: NSEvent.ModifierFlags(rawValue: flags)) else {
            throw DecodingError.dataCorruptedError(forKey: .keyCode, in: values, debugDescription: "Not a modified global shortcut")
        }
        self = value
    }

    var displayString: String {
        [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { modifiers.contains($0.0) }.map(\.1).joined() + keyName
    }

    var accessibilityDescription: String {
        ([(NSEvent.ModifierFlags.control, "Control"), (.option, "Option"), (.shift, "Shift"), (.command, "Command")]
            .filter { modifiers.contains($0.0) }.map(\.1) + [keyName]).joined(separator: "–")
    }

    private var keyName: String {
        if let name = Self.namedKeys[keyCode] { return name }
        // Resolve printable keys through the current keyboard layout, not US-only
        // labels saved on the day the shortcut was recorded.
        let source = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        if let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
            let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
            let layout = unsafeBitCast(CFDataGetBytePtr(data), to: UnsafePointer<UCKeyboardLayout>.self)
            var dead: UInt32 = 0
            var count = 0
            var buffer = [UniChar](repeating: 0, count: 8)
            if UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                              UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                              &dead, buffer.count, &count, &buffer) == noErr, count > 0 {
                return String(utf16CodeUnits: buffer, count: count).uppercased()
            }
        }
        return "Key \(keyCode)"
    }

    private static let modifierKeys: Set<UInt32> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
    private static let namedKeys: [UInt32: String] = [
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape", 71: "Clear", 76: "Enter",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        105: "F13", 106: "F16", 107: "F14", 109: "F10", 111: "F12", 113: "F15",
        114: "Help", 115: "Home", 116: "Page Up", 117: "Forward Delete", 118: "F4",
        119: "End", 120: "F2", 121: "Page Down", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑"
    ]
}
