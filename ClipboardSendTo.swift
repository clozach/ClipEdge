import AppKit

/// One place an item can be sent: opened in an app, or pasted into a running one.
enum ClipboardSendTarget: Equatable {
    case open(app: URL, items: [URL])
    case paste(pid: pid_t, name: String, app: URL?)

    var name: String {
        switch self {
        case .open(let app, _): return FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        case .paste(_, let name, _): return name
        }
    }
    var appURL: URL? {
        switch self {
        case .open(let app, _): return app
        case .paste(_, _, let app): return app
        }
    }
    var isOpen: Bool { if case .open = self { return true }; return false }
}

enum ClipboardSendTo {
    struct RunningApp: Equatable { let pid: pid_t; let name: String; let url: URL? }
    struct Sources {
        var openers: (URL) -> [URL] = { NSWorkspace.shared.urlsForApplications(toOpen: $0) }
        var running: () -> [RunningApp] = ClipboardSendTo.runningApps
        /// The running app to bring forward and paste into.
        var pasteTarget: (pid_t) -> ClipboardPaster.Target? = { NSRunningApplication(processIdentifier: $0).map(ClipboardPaster.target(for:)) }
    }

    /// What an app would open: Finder files, a web link, or a derived picture.
    /// Plain text has none, so it can only be pasted.
    static func openItems(for entry: ClipboardEntry, materializer: ClipboardMaterializer) -> [URL] {
        if !entry.fileURLs.isEmpty { return entry.fileURLs }
        switch entry.kind {
        case .link:
            return entry.plainText.flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }.map { [$0] } ?? []
        case .image: return (try? materializer.urls(for: entry)) ?? []
        case .text, .file, .other: return []
        }
    }

    /// Apps that can open every item, best first, then running apps front to back.
    static func targets(opening items: [URL], sources: Sources = Sources()) -> [ClipboardSendTarget] {
        var openers: [URL] = []
        if let first = items.first {
            let others = items.dropFirst().map { Set(sources.openers($0)) }
            var seen = Set<String>()
            openers = sources.openers(first).filter { app in
                others.allSatisfy { $0.contains(app) } && seen.insert(app.lastPathComponent).inserted
            }
        }
        return openers.map { .open(app: $0, items: items) } +
            sources.running().map { .paste(pid: $0.pid, name: $0.name, app: $0.url) }
    }

    /// Regular apps other than ClipEdge, ordered by their frontmost window.
    static func runningApps() -> [RunningApp] {
        let own = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != own
        }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var order: [pid_t: Int] = [:]
        for window in windows where window[kCGWindowLayer as String] as? Int == 0 {
            if let pid = window[kCGWindowOwnerPID as String] as? pid_t, order[pid] == nil { order[pid] = order.count }
        }
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier { order[front] = -1 }
        return apps.sorted {
            let (a, b) = (order[$0.processIdentifier] ?? Int.max, order[$1.processIdentifier] ?? Int.max)
            return a != b ? a < b : ($0.localizedName ?? "") < ($1.localizedName ?? "")
        }.map { RunningApp(pid: $0.processIdentifier, name: $0.localizedName ?? "App", url: $0.bundleURL) }
    }

    static func send(_ entry: ClipboardEntry, to target: ClipboardSendTarget, paster: ClipboardPaster,
                     sources: Sources = Sources(), failed: @escaping (Error) -> Void) {
        switch target {
        case .open(let app, let items):
            NSWorkspace.shared.open(items, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { DispatchQueue.main.async { failed(error) } }
            }
        case .paste(let pid, _, _):
            paster.paste(entry, into: sources.pasteTarget(pid))
        }
    }
}
