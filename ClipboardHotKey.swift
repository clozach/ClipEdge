import AppKit
import Carbon

/// Acquire a replacement before releasing the old shortcut. Tests inject a
/// registrar instead of reserving combinations in the running OS.
final class ClipboardHotKey {
    enum Registration { case registered(cancel: () -> Void), failed(OSStatus) }
    typealias Registrar = (UInt32, NSEvent.ModifierFlags, @escaping () -> Void) -> Registration
    private enum State {
        case inactive
        case registered(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, cancel: () -> Void)
    }
    private var state = State.inactive
    private var keyCode: UInt32
    private var modifiers: NSEvent.ModifierFlags
    private let registrar: Registrar
    var onPress: (() -> Void)?

    init(keyCode: UInt32 = UInt32(kVK_Space), modifiers: NSEvent.ModifierFlags = [.control, .option],
         registrar: @escaping Registrar = ClipboardHotKey.nativeRegistration) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection([.command, .control, .option, .shift])
        self.registrar = registrar
    }

    func register() -> OSStatus { replace(keyCode: keyCode, modifiers: modifiers) }
    func register(shortcut: ClipboardShortcut) -> OSStatus { replace(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) }

    private func replace(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) -> OSStatus {
        if case .registered(let currentCode, let currentFlags, _) = state,
           currentCode == keyCode, currentFlags == modifiers { return noErr }
        switch registrar(keyCode, modifiers, { [weak self] in self?.onPress?() }) {
        case .failed(let status): return status
        case .registered(let cancel):
            unregister()
            self.keyCode = keyCode
            self.modifiers = modifiers
            state = .registered(keyCode: keyCode, modifiers: modifiers, cancel: cancel)
            return noErr
        }
    }

    func unregister() {
        if case .registered(_, _, let cancel) = state { cancel() }
        state = .inactive
    }
    deinit { unregister() }

    private static func nativeRegistration(keyCode: UInt32, modifiers: NSEvent.ModifierFlags,
                                           onPress: @escaping () -> Void) -> Registration {
        let registration = NativeRegistration(keyCode: keyCode, modifiers: modifiers, onPress: onPress)
        let status = registration.register()
        return status == noErr ? .registered(cancel: { registration.unregister() }) : .failed(status)
    }
}

/// Each Carbon handler consumes only its own ID. A local monitor exists only
/// after successful global registration, never as a partial conflict fallback.
private final class NativeRegistration {
    private static var nextID: UInt32 = 0
    private let id: UInt32
    private let keyCode: UInt32
    private let modifiers: NSEvent.ModifierFlags
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var localMonitor: Any?
    private let onPress: () -> Void

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, onPress: @escaping () -> Void) {
        Self.nextID += 1; id = Self.nextID
        self.keyCode = keyCode; self.modifiers = modifiers; self.onPress = onPress
    }
    func register() -> OSStatus {
        unregister()
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<NativeRegistration>.fromOpaque(context).takeUnretainedValue()
            var received = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &received) == noErr,
                  received.signature == 0x434C5045, received.id == owner.id else { return OSStatus(eventNotHandledErr) }
            owner.onPress(); return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { return status }
        var carbon: UInt32 = 0
        for (flag, value) in [(NSEvent.ModifierFlags.command, cmdKey), (.control, controlKey), (.option, optionKey), (.shift, shiftKey)] {
            if modifiers.contains(flag) { carbon |= UInt32(value) }
        }
        let registered = RegisterEventHotKey(keyCode, carbon, EventHotKeyID(signature: 0x434C5045, id: id), GetApplicationEventTarget(), 0, &hotKey)
        guard registered == noErr else { unregister(); return registered }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == UInt16(self.keyCode), !event.isARepeat,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]) == self.modifiers else { return event }
            self.onPress(); return nil
        }
        return registered
    }
    func unregister() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }; localMonitor = nil
        if let hotKey { UnregisterEventHotKey(hotKey) }; hotKey = nil
        if let handler { RemoveEventHandler(handler) }; handler = nil
    }
    deinit { unregister() }
}
