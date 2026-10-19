import Foundation

/// The tab cannot be visible while its drawer is disabled.
enum ClipboardDrawerAvailability: String, CaseIterable {
    case visibleTab, hiddenTab, disabled
    var drawerEnabled: Bool { self != .disabled }
    var tabVisible: Bool { self == .visibleTab }
}

enum ClipboardShortcutAction {
    case quickLook, drawer
}

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
    private static let drawerShortcutKey = "ClipEdgeDrawerShortcut"
    private static let drawerAvailabilityKey = "ClipEdgeDrawerAvailability"
    private static let magnetsKey = "ClipEdgeMagnetsEnabled"
    private static let magnetSourcesKey = "ClipEdgeMagnetSources"
    /// One key per direction: only its current duration is kept. (Each direction's ease, under
    /// ClipEdgeDrawer…Ease, is no longer read or written; a stored one is ignored.)
    private static let motionKeys: [ClipboardDrawerDirection: String] = [
        .opening: "ClipEdgeDrawerOpeningDuration", .closing: "ClipEdgeDrawerClosingDuration"]
    /// Percentages, one key each (2026-10-16).
    private static let textSizeKey = "ClipEdgeTextSize"
    private static let thumbnailSizeKey = "ClipEdgeThumbnailSize"
    private static let previewSizeKey = "ClipEdgePreviewSize"
    /// The hover delay, in seconds: as shipped, and the longest.
    static let standardDelay: TimeInterval = 0.35
    static let longestDelay: TimeInterval = 2
    /// The longest close delay near the edge, in seconds: as shipped, and the longest.
    static let standardDismissalDelay: TimeInterval = 0.5
    static let longestDismissalDelay: TimeInterval = 3
    private let defaults: UserDefaults?
    private var storedMode: ClipboardRevealMode
    private var storedDelay: TimeInterval
    private var storedDismissalDelay: TimeInterval
    private var storedShortcut: ClipboardShortcut
    private var storedDrawerShortcut: ClipboardShortcut
    private var storedDrawerAvailability: ClipboardDrawerAvailability
    private var storedMagnetsEnabled: Bool
    private var storedMagnetSources: Set<ClipboardMagnetSource>
    private var storedMotion: [ClipboardDrawerDirection: ClipboardDrawerMotionProfile] = [:]
    private var storedSizes: ClipboardSizes

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        storedMode = defaults?.string(forKey: Self.modeKey).flatMap(ClipboardRevealMode.init(rawValue:)) ?? .instant
        storedDelay = Self.validDelay((defaults?.object(forKey: Self.delayKey) as? NSNumber)?.doubleValue ?? Self.standardDelay)
        storedDismissalDelay = Self.validDismissalDelay((defaults?.object(forKey: Self.dismissalKey) as? NSNumber)?.doubleValue ?? Self.standardDismissalDelay)
        storedShortcut = defaults?.data(forKey: Self.shortcutKey)
            .flatMap { try? JSONDecoder().decode(ClipboardShortcut.self, from: $0) } ?? .defaultQuickLook
        if [ClipboardShortcut.history, .plainPaste].contains(storedShortcut) { storedShortcut = .defaultQuickLook }
        let drawerCandidate = defaults?.data(forKey: Self.drawerShortcutKey)
            .flatMap { try? JSONDecoder().decode(ClipboardShortcut.self, from: $0) } ?? .defaultDrawer
        storedDrawerShortcut = [storedShortcut, .history, .plainPaste].contains(drawerCandidate)
            ? (storedShortcut == .defaultDrawer ? .alternateDrawer : .defaultDrawer) : drawerCandidate
        storedDrawerAvailability = defaults?.string(forKey: Self.drawerAvailabilityKey)
            .flatMap(ClipboardDrawerAvailability.init(rawValue:)) ?? .visibleTab
        storedMagnetsEnabled = (defaults?.object(forKey: Self.magnetsKey) as? NSNumber)?.boolValue ?? true
        storedMagnetSources = (defaults?.stringArray(forKey: Self.magnetSourcesKey))
            .map { Set($0.compactMap(ClipboardMagnetSource.init(rawValue:))) } ?? Set(ClipboardMagnetSource.allCases)
        func percent(_ key: String) -> Double { (defaults?.object(forKey: key) as? NSNumber)?.doubleValue ?? 100 }
        storedSizes = ClipboardSizes(text: percent(Self.textSizeKey), thumbnails: percent(Self.thumbnailSizeKey), preview: percent(Self.previewSizeKey)).valid
        for (direction, key) in Self.motionKeys {
            storedMotion[direction] = .valid(duration: (defaults?.object(forKey: key) as? NSNumber)?.doubleValue
                                             ?? ClipboardDrawerMotionProfile.standard.duration)
        }
    }

    /// How large ClipEdge draws its text, its list thumbnails and Quick Look's preview.
    var sizes: ClipboardSizes {
        get { storedSizes }
        set {
            let valid = newValue.valid
            guard valid != storedSizes else { return }
            storedSizes = valid
            defaults?.set(valid.text, forKey: Self.textSizeKey)
            defaults?.set(valid.thumbnails, forKey: Self.thumbnailSizeKey)
            defaults?.set(valid.preview, forKey: Self.previewSizeKey)
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    /// How the drawer slides in one direction; the drawer reads it at each move.
    func drawerMotion(for direction: ClipboardDrawerDirection) -> ClipboardDrawerMotionProfile {
        storedMotion[direction] ?? .standard
    }

    func setDrawerMotion(_ profile: ClipboardDrawerMotionProfile, for direction: ClipboardDrawerDirection) {
        let valid = ClipboardDrawerMotionProfile.valid(duration: profile.duration)
        guard valid != drawerMotion(for: direction), let key = Self.motionKeys[direction] else { return }
        storedMotion[direction] = valid
        defaults?.set(valid.duration, forKey: key)
        NotificationCenter.default.post(name: Self.didChange, object: self)
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
        // A hidden tab has no click target. Preserve the user's visible-tab
        // preference while keeping its saved edge location available on hover.
        if drawerAvailability == .hiddenTab, mode == .click { return .instant }
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
            guard newValue != storedShortcut, shortcutConflict(newValue, for: .quickLook) == nil else { return }
            storedShortcut = newValue
            defaults?.set(try? JSONEncoder().encode(newValue), forKey: Self.shortcutKey)
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    var drawerShortcut: ClipboardShortcut {
        get { storedDrawerShortcut }
        set {
            guard newValue != storedDrawerShortcut, shortcutConflict(newValue, for: .drawer) == nil else { return }
            storedDrawerShortcut = newValue
            defaults?.set(try? JSONEncoder().encode(newValue), forKey: Self.drawerShortcutKey)
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    var drawerAvailability: ClipboardDrawerAvailability {
        get { storedDrawerAvailability }
        set {
            guard newValue != storedDrawerAvailability else { return }
            storedDrawerAvailability = newValue
            defaults?.set(newValue.rawValue, forKey: Self.drawerAvailabilityKey)
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    /// Reject ClipEdge's own collisions before touching a live registration.
    func shortcutConflict(_ shortcut: ClipboardShortcut, for action: ClipboardShortcutAction) -> String? {
        if shortcut == .history { return "Clipboard History" }
        if shortcut == .plainPaste { return "Paste Top Item as Plain Text" }
        if action == .drawer, shortcut == storedShortcut { return "Quick Look" }
        if action == .quickLook, shortcut == storedDrawerShortcut { return "Show / Hide Clipboard" }
        return nil
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
        value.isFinite ? min(longestDelay, max(0, value)) : standardDelay
    }

    private static func validDismissalDelay(_ value: TimeInterval) -> TimeInterval {
        value.isFinite ? min(longestDismissalDelay, max(0, value)) : standardDismissalDelay
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
