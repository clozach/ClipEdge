import AppKit

/// What the fixture's --demo-report says about who holds the keyboard and where a real click can
/// land, for tools/sibling-keyboard-check.sh. Fixture-only: the normal app never builds any of it,
/// and nothing here changes a window. Frames are AppKit global points (NSStringFromRect).
enum ClipboardDemoReport {
    /// The drawer and the update question are both titled "ClipEdge", so a title alone cannot say which holds the keyboard.
    static func role(of window: NSWindow?) -> String {
        guard let window else { return "none" }
        if window is UpdateConsentPanel { return "consent" }
        switch window.title {
        case "ClipEdge": return window is ClipboardWindow ? "drawer" : "ClipEdge"
        case "ClipEdge History": return "history"
        case "ClipEdge Send To": return "sendTo"
        case "ClipEdge Settings": return "settings"
        case "ClipEdge Cursor Magnet": return "magnet"
        default: return window.title.isEmpty ? String(describing: type(of: window)) : window.title
        }
    }

    static func keyboard(_ app: NSApplication) -> [String: Any] {
        // Asked of each window rather than app.keyWindow, which can lag for a nonactivating panel.
        let key = app.windows.first { $0.isKeyWindow }
        return ["pid": Int(ProcessInfo.processInfo.processIdentifier),
                "frontmostPID": Int(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1),
                "keyWindowID": key?.windowNumber ?? -1, "keyWindowRole": role(of: key),
                "windows": app.windows.filter(\.isVisible).map { window -> [String: Any] in
                    ["title": window.title, "id": window.windowNumber, "frame": NSStringFromRect(window.frame),
                     "role": role(of: window), "key": window.isKeyWindow]
                }]
    }

    static func drawer(_ drawer: ClipboardDrawerController, in app: NSApplication) -> [String: Any] {
        let panel = app.windows.first { $0 is ClipboardWindow && $0.title == "ClipEdge" }
        let browser = drawer.browser
        func screen(_ view: NSView) -> String {
            guard drawer.isVisible, let window = view.window else { return "none" }
            return NSStringFromRect(window.convertToScreen(view.convert(view.bounds, to: nil)))
        }
        let responder = panel?.firstResponder
        let holder: String
        if let editor = browser.search.currentEditor(), responder === editor { holder = "search" }
        else if responder === browser.canvas { holder = "canvas" }
        else { holder = responder.map { String(describing: type(of: $0)) } ?? "none" }
        // Where the drawer opens, known while it is still collapsed (aligned as applyDockLayout aligns it).
        let visible = drawer.preferredScreen().visibleFrame
        let open = ClipboardTabGeometry.layout(placement: drawer.tabPlacement, in: visible)
        func aligned(_ r: NSRect) -> NSRect { NSRect(x: floor(r.minX), y: floor(r.minY), width: floor(r.width), height: floor(r.height)) }
        let sendTo = app.windows.first { $0.title == "ClipEdge Send To" }
        return ["drawerID": panel?.windowNumber ?? -1, "drawerKey": panel?.isKeyWindow ?? false,
                "drawerExpanded": drawer.isVisible, "drawerResponder": holder,
                "drawerAllowsHiding": drawer.allowsAutomaticHiding,
                "drawerFrame": panel.map { NSStringFromRect($0.frame) } ?? "none",
                "drawerTabFrame": drawer.tabFrame.map(NSStringFromRect) ?? "none",
                "drawerBodyFrame": drawer.bodyFrame.map(NSStringFromRect) ?? "none",
                "drawerClosedTabFrame": NSStringFromRect(aligned(open.tabFrame)),
                "drawerOpenTabFrame": NSStringFromRect(aligned(open.expandedTabFrame)),
                "drawerOpenBodyFrame": NSStringFromRect(aligned(open.bodyFrame)),
                "drawerOpenFrame": NSStringFromRect(aligned(open.expandedTabFrame).union(aligned(open.bodyFrame))),
                "screenVisibleFrame": NSStringFromRect(visible),
                "drawerSearchFrame": screen(browser.search), "drawerHeaderFrame": screen(drawer.header),
                "drawerSelected": browser.canvas.selected?.entry.title ?? "none",
                "drawerReturnsTo": drawer.previousApplication?.localizedName ?? "none",
                "sendToVisible": drawer.sendToPopover.isVisible, "sendToKey": sendTo?.isKeyWindow ?? false,
                "sendToID": sendTo?.windowNumber ?? -1,
                "sendToFrame": drawer.sendToPopover.isVisible ? NSStringFromRect(drawer.sendToPopover.frame) : "none"]
    }

    /// The first-launch question's window and the spots a real click can use. The icon makes the panel key without answering.
    static func consent(_ app: NSApplication) -> [String: Any] {
        guard let panel = app.windows.first(where: { $0 is UpdateConsentPanel && $0.isVisible }) else {
            return ["consentVisible": false, "consentKey": false, "consentID": -1, "consentFrame": "none",
                    "consentIconFrame": "none", "consentHeadingFrame": "none", "consentAcceptFrame": "none", "consentDeclineFrame": "none"]
        }
        return consent(panel: panel)
    }

    static func consent(panel: NSWindow) -> [String: Any] {
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let views = panel.contentView.map(all) ?? []
        let buttons = views.compactMap { $0 as? NSButton }
        func screen(_ view: NSView?) -> String {
            view.map { NSStringFromRect(panel.convertToScreen($0.convert($0.bounds, to: nil))) } ?? "none"
        }
        return ["consentVisible": panel.isVisible, "consentKey": panel.isKeyWindow, "consentID": panel.windowNumber,
                "consentFrame": NSStringFromRect(panel.frame),
                "consentIconFrame": screen(views.first { $0 is NSImageView }),
                "consentHeadingFrame": screen(views.first { ($0 as? NSTextField)?.stringValue == UpdateConsentPanel.question }),
                "consentAcceptFrame": screen(buttons.first { $0.keyEquivalent == "\r" }),
                "consentDeclineFrame": screen(buttons.first { $0.keyEquivalent == "\u{1b}" })]
    }
}

/// Every keyboard and activation change in the fixture, timed on the system uptime clock that the
/// paste-check app also uses, so a change shorter than the report timer is not missed.
final class DemoKeyTimeline {
    private(set) var events: [[String: Any]] = []
    private var observers: [NSObjectProtocol] = []

    init(onChange: @escaping () -> Void) {
        let names = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let window = note.object as? NSWindow
                self?.events.append(["t": ProcessInfo.processInfo.systemUptime, "event": name.rawValue,
                                     "role": window.map { ClipboardDemoReport.role(of: $0) } ?? "app",
                                     "id": window?.windowNumber ?? -1, "active": NSApplication.shared.isActive])
                if let count = self?.events.count, count > 60 { self?.events.removeFirst(count - 60) }
                onChange()
            }
        }
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}

/// The first-launch update question for real-input checks (--demo-update-question). It runs the real
/// decision: UpdateController.start() finds availability .available and preference .unasked, so
/// UpdateMenu.ask() presents the real UpdateConsentPanel. State lives in a temporary folder removed
/// at exit, and every network, install and quit hook refuses or does nothing, so an answer never
/// reaches ~/Library/Application Support/ClipEdge/Updates. Choosing "automatic" makes tick() start a
/// check, which fails at once without contacting the network.
@MainActor
final class DemoUpdateQuestion {
    nonisolated let support: URL
    private let controller: UpdateController
    private let menu: UpdateMenu

    init() {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipedge-demo-updates-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        support = folder
        let refuse = UpdateFailure.offline("the fixture never contacts the network")
        controller = UpdateController(environment: UpdateController.Environment(
            runningVersion: AppVersion("0.0.1")!, availability: .available(feed: folder.appendingPathComponent("feed.json")),
            support: folder,
            fetchRelease: { _ in throw refuse },
            fetchApp: { _, _ in throw refuse },
            verify: { _ in throw refuse },
            installedVersion: { _ in nil },
            install: { _, _ in throw refuse },
            goBack: { _ in throw refuse },
            canGoBack: { _ in false },
            isBusy: { true },
            secondsSinceInput: { 0 },
            saveBeforeQuit: { false },
            reopenAndQuit: {}))
        menu = UpdateMenu(controller: controller)
    }

    /// What the app does at launch; with nothing saved, it asks.
    func ask() { controller.start(repeating: false) }
    /// unasked, automatic or manual.
    var choice: String { controller.preference.rawValue }
    nonisolated func discard() { try? FileManager.default.removeItem(at: support) }
}
