import AppKit

enum ClipboardDrawerDirection: CaseIterable {
    case opening, closing
}

/// One direction of the drawer's slide: how long it takes. Every slide starts and
/// stops softly, on one curve. Settings keeps one per direction.
struct ClipboardDrawerMotionProfile: Equatable {
    /// Seconds for the whole travel; 0 moves at once.
    var duration: TimeInterval
    static let standard = ClipboardDrawerMotionProfile(duration: 0.3)
    static let longestDuration: TimeInterval = 1.5

    /// An out-of-range duration clamps; an unreadable one takes the standard.
    static func valid(duration: TimeInterval) -> ClipboardDrawerMotionProfile {
        ClipboardDrawerMotionProfile(duration: duration.isFinite ? min(longestDuration, max(0, duration)) : standard.duration)
    }
}

/// Slides fixed-size content instead of resizing its text and tiles every frame.
/// The clock is injectable: reversals and completion need no synthetic input.
final class ClipboardDrawerMotion {
    private struct Transition {
        let from: CGFloat
        let to: CGFloat
        let started: TimeInterval
        let duration: TimeInterval
        /// The slide's starting speed, as travel over its whole duration: 0 starts softly (the curve
        /// is then smoothstep), more carries a released drag's speed into the slide.
        let launch: CGFloat
    }
    private let clock: () -> TimeInterval
    private var transition: Transition?
    private var timer: Timer?
    private(set) var fraction: CGFloat = 0
    var isAnimating: Bool { transition != nil }
    /// A drag on the tab holds the drawer where the pointer puts it (`hold`), until it lets go.
    private(set) var isHeld = false
    /// Sliding, or held part-way by a drag: either way the drawer's body is drawn.
    var isMoving: Bool { isAnimating || isHeld }
    var onFrame: (() -> Void)?
    /// Read at each move; a transition already under way keeps the values it started with.
    var profiles: (ClipboardDrawerDirection) -> ClipboardDrawerMotionProfile = { _ in .standard }

    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
    }

    /// Puts the drawer where a drag on its tab has it, `fraction` open, until the next `move`.
    func hold(at fraction: CGFloat) {
        timer?.invalidate()
        timer = nil
        transition = nil
        isHeld = true
        self.fraction = min(1, max(0, fraction))
        onFrame?()
    }

    /// Slides to `target`. `velocity` (fractions per second) is a released drag's speed toward the
    /// target: the slide starts at that speed and still stops softly, never overshooting; a slide
    /// started faster than its usual pace takes less time. Speed away from the target is dropped.
    func move(to target: CGFloat, animated: Bool, velocity: CGFloat = 0) {
        advance(at: clock())
        timer?.invalidate()
        timer = nil
        isHeld = false
        let target = min(1, max(0, target))
        let profile = profiles(target > fraction ? .opening : .closing)
        guard animated, target != fraction, profile.duration > 0 else {
            transition = nil
            fraction = target
            onFrame?()
            return
        }
        let distance = abs(target - fraction)
        let speed = velocity * (target > fraction ? 1 : -1)
        var duration = profile.duration * Double(distance)
        // A cubic launched faster than three times its distance overshoots before it rests: a fast
        // release shortens the slide to stay within that.
        if speed > 0 { duration = min(duration, Double(3 * distance / speed)) }
        let launch = speed > 0 ? min(3 * distance, speed * CGFloat(duration)) : 0
        transition = Transition(from: fraction, to: target, started: clock(), duration: duration,
                                launch: launch * (target > fraction ? 1 : -1))
        onFrame?()
        let timer = Timer(timeInterval: 1 / 120, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.advance(at: self.clock())
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func advance(at now: TimeInterval) {
        guard let transition else { return }
        let t = CGFloat(min(1, max(0, (now - transition.started) / transition.duration)))
        // A Hermite cubic: at rest at the end, starting at the launch speed (smoothstep when that is 0),
        // without bounce or overshoot.
        let toward = t * t * (3 - 2 * t), launched = t * (1 - t) * (1 - t)
        fraction = min(1, max(0, transition.from + (transition.to - transition.from) * toward + transition.launch * launched))
        if t >= 1 {
            fraction = transition.to
            self.transition = nil
            timer?.invalidate()
            timer = nil
        }
        onFrame?()
    }

    deinit { timer?.invalidate() }
}
