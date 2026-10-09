import AppKit

/// One shared state drives both publish controls. Only deliberate review approval can upload.
@MainActor
final class PublishController {
    struct Environment {
        var fingerprint: String?
        /// The sink receives helper progress for prepare and publish, on the main actor.
        var execute: ([String], @escaping PublishProgressSink) async throws -> Data
        var setupFailure: String? = nil
        var review: @MainActor (PublishCandidate, NSWindow?) async -> Bool = PublishReview.confirm
        var reportFailure: @MainActor (PublishFailure) -> Void = PublishReview.failure
        var now: () -> Date = Date.init
    }

    static let shared = PublishController(environment: .live())
    private let environment: Environment
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var lastCheck: Date?
    private struct Observer {
        weak var owner: AnyObject?
        var callback: (PublishPresentation) -> Void
    }
    private var observers: [ObjectIdentifier: Observer] = [:]
    private(set) var state: PublishState {
        didSet {
            guard state != oldValue else { return }
            updateProgressTrack(leaving: oldValue)
            notifyObservers()
        }
    }
    /// Exists only while preparing or publishing; telemetry never changes `state`.
    private(set) var progress: PublishProgressTrack?
    private var progressGeneration = 0
    private var progressTimer: Timer?
    private var notifiedProgress: (fraction: Double, label: String?)?
    private var verifyingUpload = false

    var presentation: PublishPresentation {
        var shown = state.presentation
        if let progress, let label = progress.label {
            shown.progress = progress.fraction
            shown.help += " Now: \(label) (\(shown.percent ?? 0)%)"
        } else if verifyingUpload {
            shown.progress = 1
        }
        return shown
    }

    init(environment: Environment) {
        self.environment = environment
        if let failure = environment.setupFailure { state = .unknown(failure) }
        else { state = environment.fingerprint == nil ? .hidden : .unknown("The first release check has not finished.") }
    }

    deinit {
        timer?.invalidate()
        progressTimer?.invalidate()
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    func observe(owner: AnyObject, _ callback: @escaping (PublishPresentation) -> Void) {
        observers[ObjectIdentifier(owner)] = Observer(owner: owner, callback: callback)
        callback(presentation)
    }

    func start() {
        guard environment.fingerprint != nil, timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
    }

    /// Reopening either surface checks at most once a minute. No check runs in public builds.
    func refresh() {
        guard environment.fingerprint != nil, !state.isBusy,
              lastCheck.map({ environment.now().timeIntervalSince($0) >= 60 }) ?? true else { return }
        Task { await check() }
    }

    @discardableResult
    func check() async -> PublishState {
        guard environment.fingerprint != nil, !state.isBusy else { return state }
        let previous = state
        state = .checking
        lastCheck = environment.now()
        do {
            guard case .status(let status) = try await command(["status"]) else {
                throw PublishFailure.message("The helper did not return a release comparison.")
            }
            applyComparison(status, previous: previous)
        } catch { applyComparison(.unknown(error.localizedDescription), previous: previous) }
        return state
    }

    func performAction(presenting window: NSWindow? = nil) {
        guard presentation.isEnabled else { return }
        Task { await act(presenting: window) }
    }

    /// Public for the fixture tests; ordinary UI enters through performAction.
    func act(presenting window: NSWindow? = nil) async {
        switch state {
        case .different(let difference): await prepareAndReview(difference, presenting: window)
        case .ready(let candidate, let difference): await reviewAndPublish(candidate, difference, presenting: window)
        case .publishFailed(_, let candidate, let difference): await retry(candidate, difference, presenting: window)
        case .unknown, .failed:
            if let message = environment.setupFailure { environment.reportFailure(.message(message)) }
            else { _ = await check() }
        case .rebuildRequired(let message):
            environment.reportFailure(.message(message))
            _ = await check()
        default: break
        }
    }

    private func prepareAndReview(_ difference: PublishDifference, presenting window: NSWindow?) async {
        state = .preparing(difference)
        do {
            let reply = try await command(["prepare"])
            if case .status(let status) = reply { state = status; return }
            guard case .ready(let candidate) = reply else {
                throw PublishFailure.message("No tested release was prepared. Try again.")
            }
            await reviewAndPublish(candidate, difference, presenting: window)
        } catch {
            state = .failed(error.localizedDescription, difference)
            environment.reportFailure(error as? PublishFailure ?? .message(error.localizedDescription))
        }
    }

    private func reviewAndPublish(_ candidate: PublishCandidate, _ difference: PublishDifference, presenting window: NSWindow?) async {
        state = .reviewing(candidate, difference)
        guard await environment.review(candidate, window) else { state = .ready(candidate, difference); return }
        state = .publishing(candidate, difference)
        do {
            let published = try await command(["publish", "--candidate", candidate.id,
                "--archive-sha256", candidate.archiveSHA256, "--receipt-sha256", candidate.receiptSHA256, "--approve"])
            guard case .published(let fingerprint) = published, fingerprint == environment.fingerprint else {
                throw PublishFailure.message("Publication could not be verified. Check the latest release before trying again.")
            }
            // A successful upload alone never hides the button. Fetch a fresh comparison.
            state = .verifying(candidate, difference)
            guard case .status(let verified) = try await command(["status"]) else {
                throw PublishFailure.message("The latest release could not be checked after publishing.")
            }
            lastCheck = environment.now()
            retainCandidateUnlessCurrent(verified, candidate: candidate, difference: difference)
        } catch {
            publicationFailure(error, candidate: candidate, difference: difference)
        }
    }

    private func retry(_ candidate: PublishCandidate, _ difference: PublishDifference, presenting window: NSWindow?) async {
        state = .verifying(candidate, difference)
        do {
            guard case .status(let comparison) = try await command(["status"]) else {
                throw PublishFailure.message("The public release could not be checked.")
            }
            lastCheck = environment.now()
            if case .different(let freshDifference) = comparison {
                await reviewAndPublish(candidate, freshDifference, presenting: window)
            } else if case .rebuildRequired = comparison {
                // The editable source can move on after preparation; retry still
                // publishes the reviewed candidate that matches the running app.
                await reviewAndPublish(candidate, difference, presenting: window)
            } else {
                retainCandidateUnlessCurrent(comparison, candidate: candidate, difference: difference)
            }
        } catch {
            publicationFailure(error, candidate: candidate, difference: difference)
        }
    }

    private func publicationFailure(_ error: Error, candidate: PublishCandidate, difference: PublishDifference) {
        let failure = error as? PublishFailure ?? .message(error.localizedDescription)
        state = failure.needsNewCandidate ? .failed(failure.localizedDescription, difference)
            : .publishFailed(failure.localizedDescription, candidate, difference)
        environment.reportFailure(failure)
    }

    private func retainCandidateUnlessCurrent(_ comparison: PublishState, candidate: PublishCandidate, difference: PublishDifference) {
        switch comparison {
        case .current: state = comparison
        case .unknown(let message), .rebuildRequired(let message): state = .publishFailed(message, candidate, difference)
        default: state = .publishFailed("The latest release still differs from this copy.", candidate, difference)
        }
    }

    private func applyComparison(_ comparison: PublishState, previous: PublishState) {
        switch previous {
        case .ready(let candidate, let difference):
            if case .different(let freshDifference) = comparison { state = .ready(candidate, freshDifference) }
            else { retainCandidateUnlessCurrent(comparison, candidate: candidate, difference: difference) }
        case .publishFailed(_, let candidate, let difference):
            retainCandidateUnlessCurrent(comparison, candidate: candidate, difference: difference)
        default: state = comparison
        }
    }

    private func command(_ arguments: [String]) async throws -> PublishReply {
        guard let fingerprint = environment.fingerprint else {
            throw PublishFailure.message("Publishing is available only in the maintainer's local build.")
        }
        // A late event from an earlier command carries an old generation and is ignored.
        let generation = progressGeneration
        let data = try await environment.execute(arguments + ["--running-fingerprint", fingerprint]) { [weak self] event in
            self?.receiveProgress(event, generation: generation)
        }
        return try PublishReply.decode(data, runningFingerprint: fingerprint)
    }

    // MARK: Progress

    /// Public for the fixture tests; the ten-a-second timer calls it in the app.
    func tickProgress() {
        guard var track = progress else { return }
        track.advance(to: environment.now())
        progress = track
        notifyProgressIfChanged()
    }

    private func receiveProgress(_ event: PublishProgressEvent, generation: Int) {
        guard var track = progress, track.generation == generation,
              track.accept(event, at: environment.now()) else { return }
        progress = track
        notifyProgressIfChanged()
    }

    private func updateProgressTrack(leaving previous: PublishState) {
        verifyingUpload = { if case .verifying = state, case .publishing = previous { return true }; return false }()
        let command: String? = {
            switch state {
            case .preparing: return "prepare"
            case .publishing: return "publish"
            default: return nil
            }
        }()
        guard let command else {
            progress = nil
            notifiedProgress = nil
            progressTimer?.invalidate()
            progressTimer = nil
            return
        }
        guard progress?.command != command else { return }
        progressGeneration += 1
        progress = PublishProgressTrack(command: command, generation: progressGeneration)
        notifiedProgress = (0, nil)
        guard progressTimer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickProgress() }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    /// Small movements are batched so observers redraw at most every 0.2%.
    private func notifyProgressIfChanged() {
        guard let progress else { return }
        if let notifiedProgress, notifiedProgress.label == progress.label,
           abs(progress.fraction - notifiedProgress.fraction) < 0.002 { return }
        notifiedProgress = (progress.fraction, progress.label)
        notifyObservers()
    }

    private func notifyObservers() {
        observers = observers.filter { $0.value.owner != nil }
        for observer in Array(observers.values) { observer.callback(presentation) }
    }
}
