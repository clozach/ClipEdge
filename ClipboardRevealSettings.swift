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

/// Where a cursor magnet can come from; each can be turned off on its own.
enum ClipboardMagnetSource: String, CaseIterable {
    case copy, drawer, window
    var title: String {
        switch self {
        case .copy: return "On copy"
        case .drawer: return "From the drawer"
        case .window: return "From the window"
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
    private static let magnetsKey = "ClipEdgeMagnetsEnabled"
    private static let magnetSourcesKey = "ClipEdgeMagnetSources"
    private let defaults: UserDefaults?
    private var storedMode: ClipboardRevealMode
    private var storedDelay: TimeInterval
    private var storedDismissalDelay: TimeInterval
    private var storedShortcut: ClipboardShortcut
    private var storedMagnetsEnabled: Bool
    private var storedMagnetSources: Set<ClipboardMagnetSource>

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        storedMode = defaults?.string(forKey: Self.modeKey).flatMap(ClipboardRevealMode.init(rawValue:)) ?? .instant
        storedDelay = Self.validDelay((defaults?.object(forKey: Self.delayKey) as? NSNumber)?.doubleValue ?? 0.35)
        storedDismissalDelay = Self.validDismissalDelay((defaults?.object(forKey: Self.dismissalKey) as? NSNumber)?.doubleValue ?? 0.5)
        storedShortcut = defaults?.data(forKey: Self.shortcutKey)
            .flatMap { try? JSONDecoder().decode(ClipboardShortcut.self, from: $0) } ?? .defaultQuickLook
        storedMagnetsEnabled = (defaults?.object(forKey: Self.magnetsKey) as? NSNumber)?.boolValue ?? true
        storedMagnetSources = (defaults?.stringArray(forKey: Self.magnetSourcesKey))
            .map { Set($0.compactMap(ClipboardMagnetSource.init(rawValue:))) } ?? Set(ClipboardMagnetSource.allCases)
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

    /// The one switch for every cursor magnet; turning it off keeps the per-source choices.
    var magnetsEnabled: Bool {
        get { storedMagnetsEnabled }
        set {
            guard newValue != storedMagnetsEnabled else { return }
            storedMagnetsEnabled = newValue
            defaults?.set(newValue, forKey: Self.magnetsKey)
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    var magnetSources: Set<ClipboardMagnetSource> {
        get { storedMagnetSources }
        set {
            guard newValue != storedMagnetSources else { return }
            storedMagnetSources = newValue
            defaults?.set(ClipboardMagnetSource.allCases.filter(newValue.contains).map(\.rawValue), forKey: Self.magnetSourcesKey)
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    /// A magnet shows only when the switch is on and its source is chosen.
    func showsMagnet(for source: ClipboardMagnetSource) -> Bool {
        storedMagnetsEnabled && storedMagnetSources.contains(source)
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
