import AppKit
import ApplicationServices

/// Watches explicit paste/cancel gestures only while a clipboard item is held.
/// Clipboard reads are deliberately unrelated to these callbacks.
final class PasteMonitor {
    var onPaste: ((NSPoint) -> Void)?
    var onCancel: (() -> Void)?

    enum KeyAction: Equatable { case paste, cancel }
    enum DeliverySource: String { case quartzSession, quartzProcess, appKitGlobal, appKitLocal, polling, injected }

    // A menu's cached geometry remains valid while that menu is open. On close,
    // only a trailing mouse-up/Return may use it, for a bounded interval.
    enum MenuLifetime {
        case absent, open, closed(TimeInterval)
        func permitsCachedCandidate(at now: TimeInterval, trailingEvent: Bool) -> Bool {
            switch self {
            case .absent: return false
            case .open: return true
            case .closed(let time): return trailingEvent && now >= time && now - time <= 0.15
            }
        }
    }

    /// Diagnostic metadata only: no clipboard content or ordinary typed text.
    var diagnostics: [String: Any] {
        ["sessionTapCreated": eventTap != nil,
         "sessionTapEnabled": eventTap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false,
         "processTapCreated": processTap != nil,
         "processTapEnabled": processTap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false,
         "processPID": processPID.map { Int($0) } ?? -1,
         "deliveries": deliveryCounts, "recognizedActions": actionCounts,
         "lastCandidateKeyCode": lastCandidateKeyCode ?? -1,
         "lastCandidateModifiers": lastCandidateModifiers ?? 0,
         "axRegistration": axRegistration, "pasteCallbacks": pasteCallbacks]
    }

    /// The gesture lifecycle does not depend on installing macOS event sources.
    /// Keeping these few inputs together also permits isolated delivery checks.
    struct Environment {
        var accessibilityTrusted: () -> Bool = { AXIsProcessTrusted() }
        var listenAccess: () -> Bool = { CGPreflightListenEventAccess() }
        var externalApplication: () -> Bool = {
            NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        var keyAction: () -> KeyAction? = { PasteMonitor.polledKeyAction() }
        var pointerLocation: () -> NSPoint = { NSEvent.mouseLocation }
        var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        var beginObservation: (PasteMonitor) -> Void = { $0.beginSystemObservation() }
        var refreshObservation: (PasteMonitor) -> Void = { $0.refreshSystemObservation() }
    }

    private let environment: Environment

    init(environment: Environment = Environment()) {
        self.environment = environment
    }

    /// Kept separate from event delivery so shortcut rules can be verified without
    /// monitoring another application or touching the user's clipboard.
    static func keyAction(keyCode: UInt16, flags: CGEventFlags) -> KeyAction? {
        let modifiers = flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        if keyCode == 53 && modifiers.isEmpty { return .cancel }
        let pasteModifiers: [CGEventFlags] = [.maskCommand, .maskControl,
                                               [.maskCommand, .maskShift],
                                               [.maskCommand, .maskAlternate, .maskShift]]
        if keyCode == 9 && pasteModifiers.contains(modifiers) { return .paste }
        return nil
    }

    static func requestPermissionIfNeeded() {
        guard !AXIsProcessTrusted(), !UserDefaults.standard.bool(forKey: permissionPromptKey) else { return }
        configurePermissions()
    }

    static func configurePermissions() {
        UserDefaults.standard.set(true, forKey: permissionPromptKey)
        if AXIsProcessTrusted() {
            let alert = NSAlert()
            alert.messageText = "Paste detection has Accessibility access"
            alert.informativeText = "ClipEdge can listen for paste shortcuts and inspect Paste menu clicks while you hold an item."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Let ClipEdge detect when you paste"
        alert.informativeText = "Allow ClipEdge in System Settings → Privacy & Security → Accessibility so it can recognize Paste menu clicks and keyboard shortcuts while you hold an item. If ClipEdge is already switched on after an update but this message still appears, remove its old entry and add ~/Applications/ClipEdge.app again to refresh access for this build. ClipEdge does not record your typing."
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private static let permissionPromptKey = "ClipEdgePasteDetectionPermissionExplained"
    private let axQueue = DispatchQueue(label: "ClipEdge.PasteMenuInspection", qos: .userInitiated)
    private var eventTap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var processTap: CFMachPort?
    private var processTapSource: CFRunLoopSource?
    private var processPID: pid_t?
    private var deliveryCounts: [String: Int] = [:]
    private var actionCounts: [String: Int] = [:]
    private var lastCandidateKeyCode: Int?
    private var lastCandidateModifiers: UInt64?
    private var axRegistration: [String: Int] = [:]
    private var pasteCallbacks = 0
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var samplingTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var axObserver: AXObserver?
    private var observedPID: pid_t?
    private var observationGeneration = 0
    private var generation = 0
    private var active = false
    private var pastePending = false
    private var axQueryInFlight = false
    private var trusted = false
    private var listenAccess = false
    private var lastPermissionCheck = 0.0
    private var previousFallbackAction: KeyAction?
    private var menuCandidates: [MenuCandidate] = []
    private var hoveredCandidate: MenuCandidate?
    private var press: MenuPress?
    private var pressSequence = 0
    private var menuLifetime = MenuLifetime.absent
    private var selectedMenuCandidate: MenuCandidate?
    private var menuSelectionSequence = 0
    private var menuGeneration = 0
    private var pendingMenuReturn: (time: TimeInterval, pointer: NSPoint)?

    private struct MenuCandidate {
        let element: AXUIElement
        let bounds: CGRect // Accessibility/Quartz coordinates, including other displays.
        let pid: pid_t
        let sampledAt: TimeInterval
    }

    private struct MenuPress {
        let sequence: Int
        let downLocation: CGPoint
        let downTime: TimeInterval
        let rightButton: Bool
        var candidate: MenuCandidate?
        var releaseLocation: CGPoint?
        var releasePointer: NSPoint?
    }

    deinit { stop() }

    func start() {
        stop()
        active = true
        pastePending = false
        deliveryCounts = [:]
        actionCounts = [:]
        lastCandidateKeyCode = nil
        lastCandidateModifiers = nil
        pasteCallbacks = 0
        trusted = environment.accessibilityTrusted()
        listenAccess = environment.listenAccess()
        lastPermissionCheck = environment.uptime()
        previousFallbackAction = environment.keyAction()
        environment.beginObservation(self)
    }

    private func beginSystemObservation() {
        installEventDelivery()
        refreshObservedApplication()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshObservedApplication() }
        samplingTimer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in self?.sample() }
        if let samplingTimer { RunLoop.main.add(samplingTimer, forMode: .common) }
    }

    private func refreshSystemObservation() {
        // Permission can change while an item is being held. Replace only the
        // event sources: the active pickup and its duplicate-paste gate survive.
        removeEventDelivery()
        installEventDelivery()
        refreshObservedApplication()
    }

    func stop() {
        active = false
        generation += 1
        observationGeneration += 1
        samplingTimer?.invalidate()
        samplingTimer = nil
        removeEventDelivery()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        removeAXObserver()
        menuCandidates = []
        hoveredCandidate = nil
        press = nil
        menuLifetime = .absent
        menuGeneration += 1
        selectedMenuCandidate = nil
        pendingMenuReturn = nil
        axQueryInFlight = false
    }

    private func removeEventDelivery() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        tapSource = nil
        eventTap = nil
        removeProcessTap()
    }

    private func removeProcessTap() {
        if let processTapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), processTapSource, .commonModes) }
        if let processTap { CFMachPortInvalidate(processTap) }
        processTapSource = nil
        processTap = nil
        processPID = nil
    }

    private func installProcessTap(for pid: pid_t) {
        removeProcessTap()
        processPID = pid
        guard trusted || listenAccess else { return }
        // Targeted event delivery can bypass the session stream. Observe its
        // destination too; both taps are passive and share pastePending.
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        processTap = CGEvent.tapCreateForPid(pid: pid, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<PasteMonitor>.fromOpaque(context).takeUnretainedValue()
                monitor.receive(event, type: type, source: .quartzProcess)
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        if let processTap {
            processTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, processTap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), processTapSource, .commonModes)
            CGEvent.tapEnable(tap: processTap, enable: true)
        }
    }

    private func installEventDelivery() {
        // Keep keyboard and mouse delivery independent. A mouse-capable tap
        // does not establish that macOS permits keyboard events. Both keyboard
        // paths are passive; pastePending coalesces duplicate deliveries.
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        eventTap = (trusted || listenAccess) ? CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<PasteMonitor>.fromOpaque(context).takeUnretainedValue()
                monitor.receive(event, type: type, source: .quartzSession)
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) : nil
        if let eventTap {
            tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]) { [weak self] event in
            self?.receive(event, source: .appKitGlobal)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.active, !self.pastePending else { return event }
            let cancels = Self.keyAction(keyCode: event.keyCode, flags: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))) == .cancel
            self.receive(event, source: .appKitLocal)
            return cancels ? nil : event
        }
    }

    func receive(_ event: NSEvent, source: DeliverySource = .injected) {
        // Some AppKit key events have no CGEvent backing. They still carry all
        // information needed to recognize the shortcut and capture its pointer.
        if event.type == .keyDown {
            recordKey(keyCode: event.keyCode, flags: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)), source: source)
            handle(type: .keyDown, keyCode: event.keyCode,
                   flags: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)),
                   location: quartzPoint(environment.pointerLocation()))
            return
        }
        guard let cgEvent = event.cgEvent else { return }
        receive(cgEvent, source: source)
    }

    func receive(_ event: CGEvent, type: CGEventType? = nil, source: DeliverySource = .injected) {
        let type = type ?? event.type
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let tap = source == .quartzProcess ? processTap : eventTap
            if active, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        if type == .keyDown {
            recordKey(keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)), flags: event.flags, source: source)
        }
        handle(type: type, keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
               flags: event.flags, location: event.location)
    }

    private func recordKey(keyCode: UInt16, flags: CGEventFlags, source: DeliverySource) {
        guard active else { return }
        deliveryCounts[source.rawValue, default: 0] += 1
        if [9, 53, 36, 76].contains(keyCode) {
            lastCandidateKeyCode = Int(keyCode)
            lastCandidateModifiers = flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).rawValue
        }
        if let action = Self.keyAction(keyCode: keyCode, flags: flags) {
            actionCounts["\(source.rawValue).\(action)", default: 0] += 1
        }
    }

    private func handle(type: CGEventType, keyCode: UInt16, flags: CGEventFlags, location: CGPoint) {
        guard active, !pastePending else { return }
        if type == .keyDown {
            switch Self.keyAction(keyCode: keyCode, flags: flags) {
            case .cancel: onCancel?()
            case .paste: reportPaste(at: appKitPoint(location))
            case nil:
                let modifiers = flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
                if [36, 76].contains(keyCode), modifiers.isEmpty,
                   menuLifetime.permitsCachedCandidate(at: environment.uptime(), trailingEvent: true) {
                    pendingMenuReturn = (environment.uptime(), appKitPoint(location))
                    finishMenuReturnIfPossible()
                }
            }
            return
        }
        guard trusted, isExternalApplication else { return }
        if type == .leftMouseDown || type == .rightMouseDown {
            pressSequence += 1
            let sequence = pressSequence
            press = MenuPress(sequence: sequence, downLocation: location, downTime: ProcessInfo.processInfo.systemUptime,
                              rightButton: type == .rightMouseDown, candidate: candidate(at: location, allowJustClosed: false))
            // Inspect before mouse-up can close the menu. The tap only enqueues
            // work; bounded Accessibility calls never block event delivery.
            inspectPoint(location, pressSequence: sequence)
        } else if type == .leftMouseUp || type == .rightMouseUp {
            guard var current = press, current.rightButton == (type == .rightMouseUp) else { return }
            // Releasing an ordinary right-click opens the context menu; it does
            // not activate the item that the newly opened menu puts under the
            // cursor. Only a deliberate right-button drag can select on release.
            if current.rightButton && hypot(location.x - current.downLocation.x, location.y - current.downLocation.y) < 4 {
                press = nil
                return
            }
            current.releaseLocation = location
            current.releasePointer = appKitPoint(location)
            // Supports both click-to-select and a right-button drag through the
            // context menu. A release outside the Paste row never commits.
            if current.candidate == nil {
                current.candidate = candidate(at: location, allowJustClosed: true)
            }
            press = current
            finishMenuPressIfPossible()
        }
    }

    private var isExternalApplication: Bool {
        environment.externalApplication()
    }

    private func reportPaste(at point: NSPoint) {
        // A nonactivating drawer/magnet can retain app ownership while input
        // is being delivered elsewhere. A paste gesture is sufficient; do not
        // gate keyboard dismissal on the asynchronous frontmost-app snapshot.
        guard active, !pastePending else { return }
        pastePending = true
        pasteCallbacks += 1
        onPaste?(point)
    }

    private func finishMenuReturnIfPossible() {
        guard let pending = pendingMenuReturn, environment.uptime() - pending.time <= 0.15,
              menuLifetime.permitsCachedCandidate(at: environment.uptime(), trailingEvent: true),
              let selected = selectedMenuCandidate,
              selected.pid == NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        reportPaste(at: pending.pointer)
    }

    private func finishMenuPressIfPossible() {
        guard let press, let candidate = press.candidate,
              let location = press.releaseLocation, let pointer = press.releasePointer,
              candidate.bounds.contains(location),
              candidate.pid == NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        reportPaste(at: pointer)
    }

    private func candidate(at point: CGPoint, allowJustClosed: Bool) -> MenuCandidate? {
        let now = ProcessInfo.processInfo.systemUptime
        if case .closed = menuLifetime,
           !menuLifetime.permitsCachedCandidate(at: now, trailingEvent: allowJustClosed) { return nil }
        if let hoveredCandidate, now - hoveredCandidate.sampledAt < 0.25, hoveredCandidate.bounds.contains(point) {
            return hoveredCandidate
        }
        return menuCandidates.first {
            menuLifetime.permitsCachedCandidate(at: now, trailingEvent: allowJustClosed) && $0.bounds.contains(point)
        }
    }

    func sample() {
        guard active, !pastePending else { return }
        let now = environment.uptime()
        if now - lastPermissionCheck > 1 {
            lastPermissionCheck = now
            let hasTrust = environment.accessibilityTrusted()
            let canListen = environment.listenAccess()
            if hasTrust != trusted || canListen != listenAccess {
                trusted = hasTrust
                listenAccess = canListen
                environment.refreshObservation(self)
            } else if processPID != nil, processPID != NSWorkspace.shared.frontmostApplication?.processIdentifier {
                refreshObservedApplication()
            }
        }
        // A valid tap or an Accessibility grant is not proof of delivery (for
        // example during a permission transition). Keep this scoped backup.
        let action = environment.keyAction()
        if action != previousFallbackAction {
            if let action { actionCounts["polling.\(action)", default: 0] += 1 }
            if action == .cancel { onCancel?() }
            if action == .paste { reportPaste(at: environment.pointerLocation()) }
        }
        previousFallbackAction = action
        guard active, !pastePending, trusted, isExternalApplication, !axQueryInFlight else { return }
        axQueryInFlight = true
        inspectPoint(quartzPoint(environment.pointerLocation()), pressSequence: nil)
    }

    private static func polledKeyAction() -> KeyAction? {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        if CGEventSource.keyState(.combinedSessionState, key: 53) { return Self.keyAction(keyCode: 53, flags: flags) }
        if CGEventSource.keyState(.combinedSessionState, key: 9) { return Self.keyAction(keyCode: 9, flags: flags) }
        return nil
    }

    private func inspectPoint(_ point: CGPoint, pressSequence: Int?) {
        let expectedGeneration = generation
        let sampledAt = ProcessInfo.processInfo.systemUptime
        axQueue.async { [weak self] in
            guard let self else { return }
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.06)
            var element: AXUIElement?
            let result = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element)
            let match = result == .success ? element.flatMap { self.pasteCandidate($0, sampledAt: sampledAt) } : nil
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active, self.generation == expectedGeneration else { return }
                if pressSequence == nil { self.axQueryInFlight = false }
                self.hoveredCandidate = match
                if let sequence = pressSequence, self.press?.sequence == sequence, let match {
                    self.press?.candidate = match
                    self.finishMenuPressIfPossible()
                }
            }
        }
    }

    private func refreshObservedApplication() {
        removeAXObserver()
        removeProcessTap()
        observationGeneration += 1
        menuCandidates = []
        hoveredCandidate = nil
        selectedMenuCandidate = nil
        pendingMenuReturn = nil
        menuSelectionSequence += 1
        menuGeneration += 1
        menuLifetime = .absent
        axRegistration = [:]
        guard active, let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        installProcessTap(for: pid)
        guard trusted, pid != ProcessInfo.processInfo.processIdentifier else { return }
        observedPID = pid
        let expected = observationGeneration
        axQueue.async { [weak self] in
            guard let self else { return }
            var observer: AXObserver?
            let creation = AXObserverCreate(pid, { _, element, notification, context in
                guard let context else { return }
                let monitor = Unmanaged<PasteMonitor>.fromOpaque(context).takeUnretainedValue()
                monitor.menuNotification(element: element, notification: notification as String)
            }, &observer)
            guard creation == .success, let observer else {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.active, self.observationGeneration == expected else { return }
                    self.axRegistration = ["observer": Int(creation.rawValue)]
                }
                return
            }
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.06)
            var registrations: [String: Int] = [:]
            for name in [kAXMenuOpenedNotification, kAXMenuClosedNotification, kAXMenuItemSelectedNotification] {
                registrations[name] = Int(AXObserverAddNotification(observer, application, name as CFString,
                    Unmanaged.passUnretained(self).toOpaque()).rawValue)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active, self.observationGeneration == expected else { return }
                self.axRegistration = registrations
                self.axObserver = observer
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
        }
    }

    private func removeAXObserver() {
        if let axObserver { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .commonModes) }
        axObserver = nil
        observedPID = nil
    }

    private func menuNotification(element: AXUIElement, notification: String) {
        guard active, !pastePending else { return }
        if notification == kAXMenuClosedNotification {
            // Retain the rectangles briefly: menu-close and mouse-up arrive via
            // different run-loop sources and may be delivered in either order.
            menuLifetime = .closed(environment.uptime())
            return
        }
        if notification == kAXMenuItemSelectedNotification {
            // Selection may mean highlight, not execution. Record the row but
            // require a real Return/Enter or matching mouse-up before dropping.
            menuSelectionSequence += 1
            selectedMenuCandidate = nil
            if let cached = menuCandidates.first(where: { CFEqual($0.element, element) }) {
                selectedMenuCandidate = cached
                finishMenuReturnIfPossible()
                return
            }
            let sequence = menuSelectionSequence
            let expected = observationGeneration
            let sampledAt = environment.uptime()
            axQueue.async { [weak self] in
                guard let self else { return }
                let candidate = self.pasteCandidate(element, sampledAt: sampledAt)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.active, self.observationGeneration == expected,
                          self.menuSelectionSequence == sequence else { return }
                    self.selectedMenuCandidate = candidate
                    self.finishMenuReturnIfPossible()
                }
            }
            return
        }
        guard notification == kAXMenuOpenedNotification else { return }
        menuLifetime = .open
        selectedMenuCandidate = nil
        pendingMenuReturn = nil
        menuSelectionSequence += 1
        menuGeneration += 1
        let expectedMenu = menuGeneration
        let expected = observationGeneration
        let sampledAt = ProcessInfo.processInfo.systemUptime
        axQueue.async { [weak self] in
            guard let self else { return }
            AXUIElementSetMessagingTimeout(element, 0.06)
            let children = self.attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
            let deadline = ProcessInfo.processInfo.systemUptime + 0.25
            var candidates: [MenuCandidate] = []
            for child in children.prefix(80) {
                guard ProcessInfo.processInfo.systemUptime < deadline else { break }
                if let candidate = self.pasteCandidate(child, sampledAt: sampledAt) { candidates.append(candidate) }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active, self.observationGeneration == expected,
                      self.menuGeneration == expectedMenu else { return }
                self.menuCandidates = candidates
            }
        }
    }

    private func pasteCandidate(_ element: AXUIElement, sampledAt: TimeInterval) -> MenuCandidate? {
        AXUIElementSetMessagingTimeout(element, 0.06)
        guard attribute(element, kAXRoleAttribute) as? String == kAXMenuItemRole else { return nil }
        let names = [kAXEnabledAttribute, kAXTitleAttribute, kAXMenuItemCmdCharAttribute,
                     kAXMenuItemCmdModifiersAttribute, kAXPositionAttribute, kAXSizeAttribute]
        var copied: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &copied) == .success,
              let values = copied as? [Any], values.count == names.count,
              values[0] as? Bool == true else { return nil }
        let title = values[1] as? String ?? ""
        let shortcut = values[2] as? String ?? ""
        let modifiers = (values[3] as? NSNumber)?.uint32Value
        // AX shortcut metadata recognizes localized standard Paste items. Some
        // context menus omit it, so their explicit English Paste titles are a
        // fallback. Never infer a paste from arbitrary clipboard reads/changes.
        guard Self.isPasteMenuCommand(title: title, shortcut: shortcut, modifiers: modifiers),
              CFGetTypeID(values[4] as CFTypeRef) == AXValueGetTypeID(),
              CFGetTypeID(values[5] as CFTypeRef) == AXValueGetTypeID() else { return nil }
        let positionValue = values[4] as! AXValue
        let sizeValue = values[5] as! AXValue
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size), size.width > 0, size.height > 0 else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return MenuCandidate(element: element, bounds: CGRect(origin: position, size: size), pid: pid, sampledAt: sampledAt)
    }

    static func isPasteMenuCommand(title: String, shortcut: String, modifiers: UInt32?) -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let titles = ["paste", "paste and match style", "paste without formatting", "paste as plain text", "paste item", "paste items"]
        // AX uses zero to mean Command alone, 1 for Command-Shift, and 3
        // for Command-Option-Shift. This works for translated menu titles.
        let isPasteShortcut = shortcut.lowercased() == "v" && modifiers.map { [0, 1, 3].contains($0) } == true
        return titles.contains(title) || isPasteShortcut
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func appKitPoint(_ point: CGPoint) -> NSPoint {
        NSPoint(x: point.x, y: CGDisplayBounds(CGMainDisplayID()).height - point.y)
    }

    private func quartzPoint(_ point: NSPoint) -> CGPoint {
        CGPoint(x: point.x, y: CGDisplayBounds(CGMainDisplayID()).height - point.y)
    }
}
