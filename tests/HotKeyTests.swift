import AppKit
import Carbon

@main enum HotKeyTests {
    private static var count = 0
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        count += 1
        guard condition() else { fatalError("FAIL: \(message)") }
    }
    static func main() throws {
        _ = NSApplication.shared
        let baseline = ClipboardShortcut.defaultQuickLook
        check(baseline.displayString == "⌃⌥Space", "default has one reusable glyph description")
        check(baseline.accessibilityDescription == "Control–Option–Space", "spoken description names modifiers")
        check(ClipboardShortcut(keyCode: 49, modifiers: []) == nil, "bare key cannot be global shortcut")
        check(ClipboardShortcut(keyCode: 49, modifiers: .shift) == nil, "Shift-only key cannot steal typing")
        check(ClipboardShortcut(keyCode: 56, modifiers: .command) == nil, "modifier itself is not a key")
        check(ClipboardShortcut(keyCode: 255, modifiers: .command) == nil, "out-of-range key rejected")
        let candidate = ClipboardShortcut(keyCode: 40, modifiers: [.control, .option, .capsLock])!
        check(candidate.modifiers == [.control, .option], "Caps Lock does not become part of combination")
        check(!candidate.displayString.isEmpty, "printable key description resolves current keyboard layout")
        let encoded = try JSONEncoder().encode(candidate)
        let decoded = try JSONDecoder().decode(ClipboardShortcut.self, from: encoded)
        check(candidate == decoded, "validated shortcut round trips")
        check((try? JSONDecoder().decode(ClipboardShortcut.self, from: Data("{\"keyCode\":49,\"modifierBits\":0}".utf8))) == nil, "malformed stored shortcut cannot bypass validation")

        var leases: [UInt32: () -> Void] = [:]
        var registered: [(UInt32, NSEvent.ModifierFlags)] = []
        var cancelled: [UInt32] = []
        var nextStatus: OSStatus = noErr
        var presses = 0
        let key = ClipboardHotKey(registrar: { code, modifiers, callback in
            registered.append((code, modifiers))
            guard nextStatus == noErr else { return .failed(nextStatus) }
            leases[code] = callback
            return .registered(cancel: { cancelled.append(code); leases.removeValue(forKey: code) })
        })
        key.onPress = { presses += 1 }
        check(key.register(shortcut: baseline) == noErr && leases.count == 1, "initial registration succeeds")
        leases[49]?()
        check(presses == 1, "live registration dispatches")
        check(key.register(shortcut: baseline) == noErr && registered.count == 1, "unchanged shortcut avoids duplicate registration")
        nextStatus = -9878
        check(key.register(shortcut: candidate) == -9878 && leases[49] != nil && cancelled.isEmpty, "conflict preserves old live registration")
        leases[49]?()
        check(presses == 2, "old shortcut still works after rejection")
        nextStatus = noErr
        check(key.register(shortcut: candidate) == noErr && leases[49] == nil && leases[40] != nil, "successful replacement retires old shortcut")
        check(cancelled == [49], "old registration released exactly once")
        key.unregister(); key.unregister()
        check(cancelled == [49, 40] && leases.isEmpty, "unregister is idempotent")
        check(key.register() == noErr && leases[40] != nil, "reregister uses last accepted shortcut")
        key.unregister()

        let recorder = ClipboardShortcutRecorder(frame: .zero)
        var recorded: ClipboardShortcut?
        var message = ""
        recorder.onRecord = { recorded = $0 }
        recorder.onValidationError = { message = $0 }
        func event(_ code: UInt16, _ flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                            isARepeat: false, keyCode: code)!
        }
        _ = recorder.sendAction(recorder.action, to: recorder.target)
        check(recorder.title == "Type shortcut…", "native button begins recording")
        recorder.keyDown(with: event(40, []))
        check(recorded == nil && message.contains("Include"), "invalid typing keeps recorder active with explanation")
        check(recorder.performKeyEquivalent(with: event(40, [.control, .option])), "recording consumes modified key equivalent")
        check(recorded == candidate && recorder.title == baseline.displayString, "recorder submits candidate without pretending it was accepted")
        recorded = nil
        _ = recorder.sendAction(recorder.action, to: recorder.target)
        recorder.keyDown(with: event(53, []))
        check(recorded == nil && recorder.title == baseline.displayString, "Escape cancels recording without changing shortcut")
        print("PASS: \(count) shortcut/registration/recorder assertions; no OS registration or input")
    }
}
