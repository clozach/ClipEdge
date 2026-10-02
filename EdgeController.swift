import AppKit

final class EdgeController {
    private weak var drawerController: ClipboardDrawerController?
    private var timer: Timer?
    private var screenObserver: NSObjectProtocol?
    private let pointerLocation: () -> NSPoint
    private let clock: () -> TimeInterval
    private let settings: ClipboardRevealSettings
    private var revealTrigger = ClipboardRevealTrigger()
    private var exitPolicy = ClipboardDrawerExitPolicy()

    init(drawerController: ClipboardDrawerController, settings: ClipboardRevealSettings = ClipboardRevealSettings(),
         pointerLocation: @escaping () -> NSPoint = { NSEvent.mouseLocation },
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.drawerController = drawerController
        self.settings = settings
        self.pointerLocation = pointerLocation
        self.clock = clock
    }

    func start() {
        guard timer == nil, let drawerController else { return }
        drawerController.showCollapsedTab(on: drawerController.preferredScreen())
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
            self?.drawerController?.refreshScreenGeometry()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.samplePointer()
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        revealTrigger.reset()
        exitPolicy.reset()
        drawerController?.stop()
    }

    func samplePointer(at suppliedPointer: NSPoint? = nil) {
        guard let drawerController else { return }
        guard !drawerController.isInteractingWithTab else { revealTrigger.reset(); exitPolicy.reset(); return }
        let pointer = suppliedPointer ?? pointerLocation()

        if drawerController.isVisible {
            revealTrigger.reset()
            guard drawerController.allowsAutomaticHiding else { exitPolicy.reset(); return }
            let shouldHide = exitPolicy.shouldHide(pointer: pointer, containsPointer: drawerController.contains(pointer),
                body: drawerController.bodyFrame, tab: drawerController.tabFrame,
                maximumDelay: settings.dismissalDelaySeconds, now: clock())
            if shouldHide {
                drawerController.hide(animated: true)
                exitPolicy.reset()
            }
            return
        }

        exitPolicy.reset()
        if revealTrigger.shouldReveal(pointerOverTab: drawerController.tabContains(pointer), behavior: settings.behavior, now: clock()) {
            drawerController.showAtTab()
            exitPolicy.reset()
        }
    }
}

/// Finite grace measured from the first outside sample. Its deadline follows
/// the current distance; moving back buys time but cannot retain it forever.
struct ClipboardDrawerExitPolicy {
    private enum State {
        case idle
        case waiting(startedAt: TimeInterval, deadline: TimeInterval)
        case dismissed
    }
    static let graceDistance: CGFloat = 200
    private var state = State.idle

    mutating func reset() { state = .idle }

    static func delay(distance: CGFloat, maximum: TimeInterval) -> TimeInterval {
        let bounded = maximum.isFinite ? min(3, max(0, maximum)) : 0.5
        return bounded * Double(max(0, 1 - max(0, distance) / graceDistance))
    }

    mutating func shouldHide(pointer: NSPoint, containsPointer: Bool, body: NSRect?, tab: NSRect?,
                             maximumDelay: TimeInterval, now: TimeInterval) -> Bool {
        if containsPointer { state = .idle; return false }
        let regions = [body, tab].compactMap { $0 }.filter { !$0.isEmpty }
        guard !regions.isEmpty else { state = .dismissed; return true }
        let distance = Self.distance(pointer, from: regions)
        let grace = Self.delay(distance: distance, maximum: maximumDelay)
        guard grace > 0 else { state = .dismissed; return true }
        let start: TimeInterval
        switch state {
        case .idle: start = now
        case .waiting(let startedAt, _): start = startedAt
        case .dismissed: return true
        }
        let deadline = start + grace
        if now >= deadline { state = .dismissed; return true }
        state = .waiting(startedAt: start, deadline: deadline)
        return false
    }

    private static func distance(_ point: NSPoint, from regions: [NSRect]) -> CGFloat {
        regions.map { rect in
            let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
            let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
            if dx == 0, dy == 0 {
                return -min(point.x - rect.minX, rect.maxX - point.x, point.y - rect.minY, rect.maxY - point.y)
            }
            return hypot(dx, dy)
        }.min() ?? .infinity
    }
}
