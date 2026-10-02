import AppKit
import ApplicationServices

/// Read-only destination inspection. Never reads text, selection contents, titles,
/// document URLs or clipboard data, and never changes another app's AX settings.
enum ClickPasteTarget {
    struct Node: Equatable {
        var role = ""
        var enabled: Bool? = nil
        var valueWritable = false
        var selectedTextWritable = false
        var hasTextSelection = false
        var bounds: CGRect? = nil

        var writable: Bool { valueWritable || selectedTextWritable }
        var fieldRole: Bool { ["AXTextArea", "AXTextField", "AXComboBox"].contains(role) }
        var textLike: Bool { hasTextSelection || fieldRole }
        var boundary: Bool { ["AXWindow", "AXApplication", "AXSystemWide"].contains(role) }
        var chrome: Bool {
            ["AXMenuBar", "AXMenuBarItem", "AXMenu", "AXMenuItem", "AXButton", "AXPopUpButton",
             "AXCheckBox", "AXRadioButton", "AXSlider", "AXToolbar", "AXDockItem", "AXTabGroup",
             "AXTab", "AXLink", "AXScrollBar", "AXIncrementor", "AXSplitter"].contains(role)
        }
    }

    enum Assessment: Equatable {
        case ready
        case retry(String)
        case reject(String)
    }

    struct Snapshot {
        var trusted = false
        var hitOwnedByTarget = false
        var focusOwnedByTarget = false
        var hitPath: [Node] = []
        var focused: Node? = nil
        var focusInHitPath = false
        var sameWindow = false
        var point = CGPoint.zero
        var pasteEnabled: Bool? = nil
        var windowInterior: CGRect? = nil

        var assessment: Assessment {
            guard trusted else { return .reject("accessibility-denied") }
            guard hitOwnedByTarget else { return .retry("hit-unavailable") }
            // A text field inside a toolbar is valid; decorative text inside a
            // button is not. Stop at the first field/control on the hit path.
            for node in hitPath {
                if node.enabled == false { return .reject("disabled-hit") }
                if node.chrome { return .reject("control-click") }
                if node.writable || node.fieldRole { break }
                if node.boundary { break }
            }
            guard focusOwnedByTarget, let focused else { return .retry("focus-unavailable") }
            guard focused.enabled != false else { return .reject("disabled-focus") }
            if focused.role == "AXWindow", focusInHitPath, sameWindow {
                // Window-only AX apps (for example an inaccessible custom
                // renderer) cannot prove editability. Honor the intentional raw
                // click only in a conservative interior and only when the app
                // advertises its ordinary Paste command as enabled.
                guard windowInterior?.contains(point) == true else { return .reject("window-chrome") }
                if pasteEnabled == true { return .ready }
                if pasteEnabled == false { return .reject("paste-disabled") }
                return .retry("window-paste-unavailable")
            }
            guard !focused.chrome, !focused.boundary else { return .retry("focus-not-content") }
            guard sameWindow else { return .retry("different-window") }
            let containsPoint = focused.bounds?.contains(point) == true
            guard focusInHitPath || containsPoint else { return .retry("stale-focus") }
            if focused.writable { return .ready }
            // Some custom editors do not implement AXValue setters. Their
            // actual focused content plus an enabled standard Paste command is
            // a usable signal; an app-level enabled Paste alone is not enough.
            if pasteEnabled == true, focused.textLike || (focusInHitPath && containsPoint) { return .ready }
            if pasteEnabled == false { return .reject("paste-disabled") }
            return .retry("editability-unavailable")
        }

        var diagnostics: [String: Any] {
            ["trusted": trusted, "hitOwnedByTarget": hitOwnedByTarget,
             "focusOwnedByTarget": focusOwnedByTarget, "hitRoles": hitPath.map(\.role),
             "focusedRole": focused?.role ?? "", "focusInHitPath": focusInHitPath,
             "sameWindow": sameWindow, "focusContainsPoint": focused?.bounds?.contains(point) == true,
             "windowInteriorContainsPoint": windowInterior?.contains(point) == true,
             "valueWritable": focused?.valueWritable ?? false,
             "selectedTextWritable": focused?.selectedTextWritable ?? false,
             "hasTextSelection": focused?.hasTextSelection ?? false,
             "pasteEnabled": pasteEnabled.map { $0 as Any } ?? NSNull(),
             "assessment": String(describing: assessment)]
        }
    }

    /// The OS click is already delivered before this asynchronous inspection.
    /// AX IPC cannot block the event tap or ClipEdge's UI/animation thread.
    static func inspect(at point: CGPoint, pid: pid_t, completion: @escaping (Assessment) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = snapshot(at: point, pid: pid).assessment
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Public to the fixture diagnostic, which records metadata only.
    static func snapshot(at point: CGPoint, pid: pid_t) -> Snapshot {
        var result = Snapshot(point: point)
        result.trusted = AXIsProcessTrusted()
        guard result.trusted else { return result }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.025)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success,
              let hit, owner(of: hit) == pid else { return result }
        result.hitOwnedByTarget = true
        let focus = element(app, kAXFocusedUIElementAttribute)
        result.focusOwnedByTarget = focus.map { owner(of: $0) == pid } ?? false
        result.focused = focus.map(describe)
        let hitWindow = (attribute(hit, kAXRoleAttribute) as? String) == "AXWindow" ? hit : element(hit, kAXWindowAttribute)
        let focusWindow = result.focused?.role == "AXWindow" ? focus : focus.flatMap { element($0, kAXWindowAttribute) }
        let frontWindow = element(app, kAXFocusedWindowAttribute)
        result.sameWindow = hitWindow != nil && focusWindow != nil && frontWindow != nil &&
            CFEqual(hitWindow, focusWindow) && CFEqual(focusWindow, frontWindow)
        if let frontWindow, let frame = bounds(of: frontWindow), frame.width > 16, frame.height > 72 {
            // No public remote NSWindow.contentLayoutRect exists. This is
            // deliberately an interior heuristic, not an AX editability claim:
            // keep away from standard title/tab bars and resize borders.
            result.windowInterior = CGRect(x: frame.minX + 8, y: frame.minY + 64,
                                           width: frame.width - 16, height: frame.height - 72)
        }
        var current: AXUIElement? = hit
        let deadline = ProcessInfo.processInfo.systemUptime + 0.32
        for _ in 0..<12 {
            guard let node = current, ProcessInfo.processInfo.systemUptime < deadline else { break }
            let description = describe(node)
            result.hitPath.append(description)
            if let focus, CFEqual(node, focus) { result.focusInHitPath = true }
            if description.boundary { break }
            current = element(node, kAXParentAttribute)
        }
        // Avoid walking all menus when explicit capabilities already suffice,
        // or when the click is clearly unrelated to the focused destination.
        if [.retry("editability-unavailable"), .retry("window-paste-unavailable")].contains(result.assessment) {
            result.pasteEnabled = pasteCommandEnabled(in: app)
        }
        // AX work is asynchronous and some apps rebuild the tree on a click.
        // A result about an input that has since lost focus must not authorize
        // pasting into a different input in that same app.
        if let focus, let latestFocus = element(app, kAXFocusedUIElementAttribute) {
            result.focusOwnedByTarget = result.focusOwnedByTarget && CFEqual(focus, latestFocus)
        } else { result.focusOwnedByTarget = false }
        return result
    }

    private static func describe(_ element: AXUIElement) -> Node {
        AXUIElementSetMessagingTimeout(element, 0.025)
        var names: CFArray?
        _ = AXUIElementCopyAttributeNames(element, &names)
        let attributes = names as? [String] ?? []
        return Node(role: attribute(element, kAXRoleAttribute) as? String ?? "",
                    enabled: attribute(element, kAXEnabledAttribute) as? Bool,
                    valueWritable: settable(element, kAXValueAttribute),
                    selectedTextWritable: settable(element, kAXSelectedTextAttribute),
                    hasTextSelection: attributes.contains(kAXSelectedTextRangeAttribute),
                    bounds: bounds(of: element))
    }

    private static func pasteCommandEnabled(in app: AXUIElement) -> Bool? {
        guard let menuBar = element(app, kAXMenuBarAttribute) else { return nil }
        var pending: [(AXUIElement, Int)] = [(menuBar, 0)]
        var visited = 0
        // Read only the ordinary menu tree. No opening/highlighting/performing
        // menu actions, and no localized menu titles are needed.
        let deadline = ProcessInfo.processInfo.systemUptime + 0.16
        while !pending.isEmpty, visited < 160, ProcessInfo.processInfo.systemUptime < deadline {
            let (node, depth) = pending.removeFirst()
            visited += 1
            AXUIElementSetMessagingTimeout(node, 0.015)
            if let key = attribute(node, kAXMenuItemCmdCharAttribute) as? String, key.lowercased() == "v",
               let modifiers = attribute(node, kAXMenuItemCmdModifiersAttribute) as? Int, modifiers == 0 {
                return attribute(node, kAXEnabledAttribute) as? Bool
            }
            if depth < 4, let children = attribute(node, kAXChildrenAttribute) as? [AXUIElement] {
                pending.append(contentsOf: children.prefix(60).map { ($0, depth + 1) })
            }
        }
        return nil
    }

    private static func owner(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }
    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    private static func element(_ parent: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(parent, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private static func settable(_ element: AXUIElement, _ name: String) -> Bool {
        var result = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &result) == .success && result.boolValue
    }
    private static func bounds(of element: AXUIElement) -> CGRect? {
        guard let positionValue = attribute(element, kAXPositionAttribute), CFGetTypeID(positionValue) == AXValueGetTypeID(),
              let sizeValue = attribute(element, kAXSizeAttribute), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero; var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size), size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: point, size: size)
    }
}
