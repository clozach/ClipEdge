import Foundation

enum ClipboardRevealMode: String, CaseIterable {
    case instant, delayed, click

    var title: String {
        switch self {
        case .instant: return "Instant on hover"
        case .delayed: return "Delayed hover"
        case .click: return "Click to open"
        }
    }
}

enum ClipboardRevealBehavior: Equatable {
    case instant
    case delayed(TimeInterval)
    case click
}

/// One shared preference object for the pointer sampler and native settings.
/// A nil defaults store keeps fixtures separate from the installed app.
final class ClipboardRevealSettings {
    static let didChange = Notification.Name("ClipEdgeRevealSettingsDidChange")
    private static let modeKey = "ClipEdgeRevealMode"
    private static let delayKey = "ClipEdgeRevealDelay"
    private static let dismissalKey = "ClipEdgeDismissalDelay"
    private static let shortcutKey = "ClipEdgeQuickLookShortcut"
    private let defaults: UserDefaults?
    private var storedMode: ClipboardRevealMode
    private var storedDelay: TimeInterval
    private var storedDismissalDelay: TimeInterval
    private var storedShortcut: ClipboardShortcut

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        storedMode = defaults?.string(forKey: Self.modeKey).flatMap(ClipboardRevealMode.init(rawValue:)) ?? .instant
        storedDelay = Self.validDelay((defaults?.object(forKey: Self.delayKey) as? NSNumber)?.doubleValue ?? 0.35)
        storedDismissalDelay = Self.validDismissalDelay((defaults?.object(forKey: Self.dismissalKey) as? NSNumber)?.doubleValue ?? 0.5)
        storedShortcut = defaults?.data(forKey: Self.shortcutKey)
            .flatMap { try? JSONDecoder().decode(ClipboardShortcut.self, from: $0) } ?? .defaultQuickLook
    }

    var mode: ClipboardRevealMode {
        get { storedMode }
        set {
            guard newValue != storedMode else { return }
            storedMode = newValue
            defaults?.set(newValue.rawValue, forKey: Self.modeKey)
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    var delaySeconds: TimeInterval {
        get { storedDelay }
        set {
            let delay = Self.validDelay(newValue)
            guard delay != storedDelay else { return }
            storedDelay = delay
            defaults?.set(delay, forKey: Self.delayKey)
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    var behavior: ClipboardRevealBehavior {
        switch mode {
        case .instant: return .instant
        case .delayed: return .delayed(delaySeconds)
        case .click: return .click
        }
    }

    var dismissalDelaySeconds: TimeInterval {
        get { storedDismissalDelay }
        set {
            let delay = Self.validDismissalDelay(newValue)
            guard delay != storedDismissalDelay else { return }
            storedDismissalDelay = delay
            defaults?.set(delay, forKey: Self.dismissalKey)
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    var quickLookShortcut: ClipboardShortcut {
        get { storedShortcut }
        set {
            guard newValue != storedShortcut else { return }
            storedShortcut = newValue
            defaults?.set(try? JSONEncoder().encode(newValue), forKey: Self.shortcutKey)
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    private static func validDelay(_ value: TimeInterval) -> TimeInterval {
        value.isFinite ? min(2, max(0, value)) : 0.35
    }

    private static func validDismissalDelay(_ value: TimeInterval) -> TimeInterval {
        value.isFinite ? min(3, max(0, value)) : 0.5
    }
}

/// Time is injected so leaving/re-entering and changing mode can be verified
/// without sleeping or moving the user's pointer.
struct ClipboardRevealTrigger {
    private var enteredAt: TimeInterval?
    private var previousBehavior: ClipboardRevealBehavior?

    mutating func reset() { enteredAt = nil; previousBehavior = nil }

    mutating func shouldReveal(pointerOverTab: Bool, behavior: ClipboardRevealBehavior, now: TimeInterval) -> Bool {
        if previousBehavior != behavior { enteredAt = nil; previousBehavior = behavior }
        guard pointerOverTab else { enteredAt = nil; return false }
        switch behavior {
        case .click: return false
        case .instant: return true
        case .delayed(let delay):
            if enteredAt == nil { enteredAt = now }
            return now - (enteredAt ?? now) >= delay
        }
    }
}
