import AppKit

/// Two faces of one place and the turn between them: the window's card and its raw data,
/// Quick Look beside the drawer and its raw data. A turn rotates about the vertical axis (about
/// 0.35 s), drawn from snapshots of both faces in a layer of its own, swapping snapshots halfway,
/// where the face is edge-on. Under Reduce Motion, or when a face cannot be snapshotted (Quick
/// Look's preview is drawn by another process, so a snapshot of it is blank), it crossfades
/// instead. Only one face is live at rest; the other is hidden, so neither the keyboard, the
/// pointer nor VoiceOver reaches it. One view for both places; each container gives it its faces.
/// A face that lets go as it is turned away, so every place that turns it behaves alike: the raw
/// data gives the keyboard back to its container's home as the turn starts, and once it is hidden
/// lets go of what it read, a deleted entry's bytes included (it reads again when next turned to).
protocol ClipboardFlipFace: AnyObject {
    /// A turn away from this face begins: what it holds of the keyboard goes back.
    func faceWillTurnAway()
    /// The turn is done and this face is hidden.
    func faceDidTurnAway()
}

/// A zoomed face (the raw data behind Quick Look at the Text size) still hears the turn.
extension ClipboardZoomHost: ClipboardFlipFace {
    func faceWillTurnAway() { (content as? ClipboardFlipFace)?.faceWillTurnAway() }
    func faceDidTurnAway() { (content as? ClipboardFlipFace)?.faceDidTurnAway() }
}

final class ClipboardFlipView: NSView {
    enum Side: Equatable {
        case front, back
        var other: Side { self == .front ? .back : .front }
    }
    /// How a change of side looks.
    enum Transition: Equatable {
        /// The rotation, from snapshots.
        case turn
        /// Both faces at once, one fading out as the other fades in.
        case crossfade
        /// Not shown in a window, or asked to be at once (every opening starts on the front).
        case instant
    }

    let front: NSView
    let back: NSView
    /// The face showing, or the one a turn under way is heading to.
    private(set) var side: Side = .front
    /// The turn under way; nil at rest.
    private(set) var turning: Transition?
    /// Which face's snapshot a rotation shows: the outgoing one until halfway, then the incoming.
    private(set) var turningFace: Side?
    /// The snapshot a rotation is showing now.
    var turningImage: NSImage? { turnView.isHidden ? nil : turnView.face.contents as? NSImage }
    /// The half-turn a rotation is running now, as its layer holds it (fixtures check its axis,
    /// angles, length and perspective); nil at rest or in a crossfade.
    var turningRotation: (keyPath: String?, from: CGFloat, to: CGFloat, duration: TimeInterval, perspective: CGFloat)? {
        guard !turnView.isHidden, let rotation = turnView.face.animation(forKey: "turn") as? CABasicAnimation,
              let from = rotation.fromValue as? CGFloat, let to = rotation.toValue as? CGFloat else { return nil }
        return (rotation.keyPath, from, to, rotation.duration, turnView.layer?.sublayerTransform.m34 ?? 0)
    }

    var duration: TimeInterval = 0.35
    var fadeDuration: TimeInterval = 0.18
    /// Read at each turn, so a change in System Settings applies to the next one.
    var reducesMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Whether a snapshot of this face shows what is on screen.
    var canSnapshot: (NSView) -> Bool = ClipboardFlipView.drawsItself
    /// Runs work after a delay: the main queue in the app; tests step it by hand.
    var after: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    /// A change of side begins: the container moves the keyboard off the outgoing face here.
    var onTurn: ((Side) -> Void)?
    /// A change of side is done (at once, for an instant one).
    var onTurned: ((Side) -> Void)?

    private let turnView = TurnView()
    /// Bumped by every change of side, so work scheduled for an earlier one does nothing.
    private var generation = 0
    override var isFlipped: Bool { true }

    init(front: NSView, back: NSView) {
        self.front = front
        self.back = back
        super.init(frame: .zero)
        wantsLayer = true
        back.isHidden = true
        turnView.isHidden = true
        [front, back, turnView].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// To the other side.
    func flip(animated: Bool = true) { turn(to: side.other, animated: animated) }

    /// Turns to `target`. A turn under way lands at once first; the side already showing stays.
    func turn(to target: Side, animated: Bool = true) {
        if turning != nil { settle(on: side) }
        guard target != side else { return }
        let outgoing = side
        let transition = Self.transition(animated: animated, reducesMotion: reducesMotion(),
                                         canDraw: window != nil && !bounds.isEmpty && !isHiddenOrHasHiddenAncestor,
                                         snapshottable: canSnapshot(face(outgoing)) && canSnapshot(face(target)))
        (face(outgoing) as? ClipboardFlipFace)?.faceWillTurnAway()
        onTurn?(target)
        side = target
        switch transition {
        case .turn: if !rotate(from: outgoing, to: target) { crossfade(from: outgoing, to: target) }
        case .crossfade: crossfade(from: outgoing, to: target)
        case .instant: settle(on: target)
        }
    }

    /// `target` now, with no turn: what every opening uses to start on the front.
    func show(_ target: Side) { turn(to: target, animated: false) }

    static func transition(animated: Bool, reducesMotion: Bool, canDraw: Bool, snapshottable: Bool) -> Transition {
        guard animated, canDraw else { return .instant }
        return reducesMotion || !snapshottable ? .crossfade : .turn
    }

    /// False when the face shows a Quick Look preview (or is one): another process draws it.
    static func drawsItself(_ view: NSView) -> Bool {
        guard let remote = NSClassFromString("QLPreviewView") else { return true }
        func showsRemote(_ view: NSView) -> Bool { view.subviews.contains { !$0.isHidden && ($0.isKind(of: remote) || showsRemote($0)) } }
        return !view.isKind(of: remote) && !showsRemote(view)
    }

    override func layout() {
        super.layout()
        for view in [front, back, turnView] { view.frame = bounds }
    }

    // MARK: Changing side

    private func face(_ side: Side) -> NSView { side == .front ? front : back }

    /// The rotation: snapshots of both faces taken now, in one pass, so no frame shows both.
    /// False when either face gives no snapshot; nothing has changed then.
    private func rotate(from outgoing: Side, to incoming: Side) -> Bool {
        let leaving = face(outgoing), arriving = face(incoming)
        leaving.frame = bounds
        arriving.frame = bounds
        guard let first = Self.snapshot(leaving) else { return false }
        arriving.isHidden = false
        let second = Self.snapshot(arriving)
        arriving.isHidden = true
        guard let second else { return false }
        leaving.isHidden = true
        generation += 1
        let turn = generation
        turning = .turn
        turningFace = outgoing
        turnView.frame = bounds
        turnView.isHidden = false
        // To the back the right edge goes away from you; back to the front, the left edge does.
        let direction: CGFloat = incoming == .back ? 1 : -1
        turnView.show(first, from: 0, to: direction * .pi / 2, duration: duration / 2, timing: .easeIn)
        after(duration / 2) { [weak self] in
            guard let self, self.generation == turn else { return }
            self.turningFace = incoming
            self.turnView.show(second, from: -direction * .pi / 2, to: 0, duration: self.duration / 2, timing: .easeOut)
            self.after(self.duration / 2) { [weak self] in
                guard let self, self.generation == turn else { return }
                self.settle(on: incoming)
            }
        }
        return true
    }

    private func crossfade(from outgoing: Side, to incoming: Side) {
        generation += 1
        let fade = generation
        turning = .crossfade
        turningFace = nil
        let leaving = face(outgoing), arriving = face(incoming)
        arriving.frame = bounds
        arriving.alphaValue = 0
        arriving.isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadeDuration
            leaving.animator().alphaValue = 0
            arriving.animator().alphaValue = 1
        }
        after(fadeDuration) { [weak self] in
            guard let self, self.generation == fade else { return }
            self.settle(on: incoming)
        }
    }

    /// At rest on `target`: it alone shows, fully opaque, and the turning layer is gone.
    private func settle(on target: Side) {
        generation += 1
        turning = nil
        turningFace = nil
        turnView.clear()
        turnView.isHidden = true
        for side in [Side.front, .back] {
            face(side).alphaValue = 1
            face(side).isHidden = side != target
        }
        side = target
        (face(target.other) as? ClipboardFlipFace)?.faceDidTurnAway()
        NSAccessibility.post(element: face(target), notification: .layoutChanged)
        onTurned?(target)
    }

    /// The face as it draws now, at the screen's scale.
    private static func snapshot(_ view: NSView) -> NSImage? {
        guard !view.bounds.isEmpty else { return nil }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    /// The turning face: a snapshot in a layer tree of its own, seen in perspective. Never hit,
    /// never in the key loop, never read by VoiceOver.
    private final class TurnView: NSView {
        let face = CALayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            let root = CALayer()
            var perspective = CATransform3DIdentity
            perspective.m34 = -1 / 900
            root.sublayerTransform = perspective
            layer = root // Hosting its own layers: AppKit leaves them alone.
            wantsLayer = true
            face.contentsGravity = .resize
            root.addSublayer(face)
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// Half a turn: this snapshot, rotating about the vertical axis from one angle to another.
        func show(_ image: NSImage, from start: CGFloat, to end: CGFloat, duration: TimeInterval, timing: CAMediaTimingFunctionName) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            face.frame = bounds
            face.contents = image
            face.contentsScale = window?.backingScaleFactor ?? 2
            face.transform = CATransform3DMakeRotation(end, 0, 1, 0)
            CATransaction.commit()
            let rotation = CABasicAnimation(keyPath: "transform.rotation.y")
            rotation.fromValue = start
            rotation.toValue = end
            rotation.duration = duration
            rotation.timingFunction = CAMediaTimingFunction(name: timing)
            face.add(rotation, forKey: "turn")
        }
        func clear() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            face.removeAllAnimations()
            face.contents = nil
            face.transform = CATransform3DIdentity
            CATransaction.commit()
        }
    }
}
