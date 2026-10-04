import Foundation

/// What the updater remembers between launches, in one small file beside the clipboard history.
struct UpdateState: Codable, Equatable {
    var preference = UpdatePreference.unasked
    var lastCheck: UpdateCheck?
    var lastUpdate: UpdateRecord?

    static func load(from folder: URL) -> UpdateState {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("state.json")),
              let state = try? JSONDecoder().decode(UpdateState.self, from: data) else { return UpdateState() }
        return state
    }

    func save(in folder: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent("state.json")
        guard let data = try? JSONEncoder().encode(self), (try? data.write(to: file, options: .atomic)) != nil else { return }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

/// Checks for a newer release, downloads and verifies it, and installs it at a quiet moment.
/// Everything that touches the network, the disk or the running app arrives through `Environment`.
@MainActor
final class UpdateController {
    struct Environment {
        var runningVersion: AppVersion
        var availability: UpdateAvailability
        var support: URL
        var now: () -> Date = Date.init
        var fetchRelease: (URL) async throws -> UpdateRelease
        var fetchApp: (UpdateRelease, URL) async throws -> URL
        /// Throws unless the copy is signed by the signer of the running app.
        var verify: (URL) throws -> Void
        var installedVersion: (URL) -> AppVersion?
        /// Swaps the copy in and returns the receipt that undoes it.
        var install: (URL, URL) throws -> URL
        var goBack: (URL) throws -> Void
        var canGoBack: (URL) -> Bool
        var isBusy: () -> Bool
        var secondsSinceInput: () -> TimeInterval
        var saveBeforeQuit: () -> Bool
        var reopenAndQuit: () -> Void
    }

    private let environment: Environment
    private var state: UpdateState { didSet { if state != oldValue { state.save(in: environment.support); onChange?() } } }
    private(set) var phase: UpdatePhase { didSet { if phase != oldValue { onChange?() } } }
    private var timer: Timer?
    var onChange: (() -> Void)?
    var onNeedsChoice: (() -> Void)?

    var availability: UpdateAvailability { environment.availability }
    var runningVersion: AppVersion { environment.runningVersion }
    var preference: UpdatePreference { state.preference }
    var lastUpdate: UpdateRecord? { state.lastUpdate }
    var canGoBack: Bool { state.lastUpdate.map { environment.canGoBack($0.receipt) } ?? false }
    var now: Date { environment.now() }

    init(environment: Environment) {
        self.environment = environment
        state = UpdateState.load(from: environment.support)
        phase = .resting(state.lastCheck)
    }

    /// Called once at launch. Asks the standing question if it has never been answered.
    func start(repeating: Bool = true) {
        try? FileManager.default.removeItem(at: stagingFolder)
        if let record = state.lastUpdate, AppVersion(record.to) != environment.runningVersion { state.lastUpdate = nil }
        guard case .available = environment.availability else { return }
        if state.preference == .unasked { onNeedsChoice?() }
        guard repeating else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 15
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func choose(_ preference: UpdatePreference) {
        state.preference = preference
    }

    /// One beat of the schedule: install a waiting update when things are quiet, or check when one is due.
    func tick() {
        guard case .available = environment.availability, state.preference == .automatic else { return }
        switch phase {
        case .ready(let staged):
            if !environment.isBusy(), environment.secondsSinceInput() >= UpdateSchedule.quietSeconds { _ = install(staged) }
        case .resting(let last):
            if UpdateSchedule.isDue(last: last, now: environment.now()) { Task { await check() } }
        case .checking, .downloading:
            break
        }
    }

    /// Looks for a newer release and, if there is one, downloads and verifies it. Installs nothing.
    @discardableResult
    func check() async -> UpdatePhase {
        guard case .available(let feed) = environment.availability, case .resting = phase else { return phase }
        phase = .checking
        do {
            let release = try await environment.fetchRelease(feed)
            guard release.version > environment.runningVersion else { return rest(.current(environment.now())) }
            phase = .downloading(release)
            let app = try await environment.fetchApp(release, stagingFolder)
            try environment.verify(app)
            let found = environment.installedVersion(app)
            guard found == release.version else {
                throw UpdateFailure.versionMismatch(expected: release.version.description, found: found?.description ?? "unknown")
            }
            state.lastCheck = .current(environment.now())
            phase = .ready(StagedUpdate(release: release, app: app))
        } catch {
            try? FileManager.default.removeItem(at: stagingFolder)
            let failure = error as? UpdateFailure ?? .offline(error.localizedDescription)
            return rest(.failed(environment.now(), failure))
        }
        return phase
    }

    /// Installs the waiting update now, whether or not things are quiet. Returns why it could not.
    func installNow() -> UpdateFailure? {
        guard case .ready(let staged) = phase else { return nil }
        return install(staged)
    }

    /// Brings back the copy the last update replaced and turns automatic updates off.
    func goBack() -> UpdateFailure? {
        guard let record = state.lastUpdate else { return .cannotGoBack("no earlier copy is recorded") }
        guard environment.saveBeforeQuit() else { return .historyNotSaved }
        do { try environment.goBack(record.receipt) }
        catch { return error as? UpdateFailure ?? .cannotGoBack(error.localizedDescription) }
        state.preference = .manual
        state.lastUpdate = nil
        environment.reopenAndQuit()
        return nil
    }

    private var stagingFolder: URL { environment.support.appendingPathComponent("staged") }

    private func rest(_ check: UpdateCheck) -> UpdatePhase {
        state.lastCheck = check
        phase = .resting(check)
        return phase
    }

    private func install(_ staged: StagedUpdate) -> UpdateFailure? {
        guard environment.saveBeforeQuit() else { return .historyNotSaved }
        let receipt: URL
        do { receipt = try environment.install(staged.app, environment.support.appendingPathComponent("receipts")) }
        catch {
            let failure = error as? UpdateFailure ?? .installFailed(error.localizedDescription)
            try? FileManager.default.removeItem(at: stagingFolder)
            _ = rest(.failed(environment.now(), failure))
            return failure
        }
        state.lastUpdate = UpdateRecord(from: environment.runningVersion.description, to: staged.release.version.description,
                                        date: environment.now(), receipt: receipt, page: staged.release.page)
        try? FileManager.default.removeItem(at: stagingFolder)
        environment.reopenAndQuit()
        return nil
    }
}
