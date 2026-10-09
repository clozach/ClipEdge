import AppKit

@MainActor final class FakePublisher {
    var replies: [[String: Any]] = []
    var calls: [[String]] = []
    var approved = false
    var reviews: [PublishCandidate] = []
    var failures: [String] = []
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var onExecute: (([String]) -> Void)?
    /// Progress lines the fake helper reports for a command before replying.
    var progress: [String: [PublishProgressEvent]] = [:]
    var sinks: [String: PublishProgressSink] = [:]
    /// Commands that wait for `release()`, so a test can watch them run.
    var held: Set<String> = []
    var gate: CheckedContinuation<Void, Never>?
    func release() { let gate = self.gate; self.gate = nil; gate?.resume() }
    func controller(publicBuild: Bool = false) -> PublishController {
        PublishController(environment: PublishController.Environment(
            fingerprint: publicBuild ? nil : PublishTests.fingerprint,
            execute: { arguments, sink in
                self.calls.append(arguments)
                self.sinks[arguments[0]] = sink
                self.onExecute?(arguments)
                for event in self.progress[arguments[0]] ?? [] { sink(event) }
                if self.held.contains(arguments[0]) { await withCheckedContinuation { self.gate = $0 } }
                await Task.yield()
                guard !self.replies.isEmpty else { throw PublishFailure.message("Offline") }
                return try JSONSerialization.data(withJSONObject: self.replies.removeFirst())
            }, review: { candidate, _ in self.reviews.append(candidate); return self.approved },
            reportFailure: { self.failures.append($0.localizedDescription) }, now: { self.now }))
    }
}

@main enum PublishTests {
    static var assertions = 0
    static let fingerprint = String(repeating: "a", count: 64)
    static let digest = String(repeating: "b", count: 64)
    static let receiptDigest = String(repeating: "c", count: 64)
    static var different: [String: Any] { ["kind": "different", "latestVersion": "2.3", "message": "This copy differs from release 2.3."] }
    static var equal: [String: Any] { ["kind": "equal", "latestVersion": "2.3.1", "latestFingerprint": fingerprint] }
    static var ready: [String: Any] {
        ["kind": "ready", "candidate": "candidate-123", "version": "2.3.1", "fingerprint": fingerprint,
         "archiveSHA256": digest, "receiptSHA256": receiptDigest, "changes": "Adds the publish control.", "previousVersion": "2.3"]
    }
    static func check(_ condition: Bool, _ message: String) {
        assertions += 1
        guard condition else { fatalError("FAIL: \(message)") }
    }
    static func decode(_ json: [String: Any]) throws -> PublishReply {
        try PublishReply.decode(JSONSerialization.data(withJSONObject: json), runningFingerprint: fingerprint)
    }

    @MainActor static func main() async throws {
        boundary()
        wording()
        await comparisons()
        await consent()
        await publication()
        await failures()
        await observers()
        await progressLifecycle()
        await progressClears()
        try await process()
        print("Publish tests passed: \(assertions) assertions")
    }

    static func boundary() {
        check((try? decode(equal)) == .status(.current(version: "2.3.1")), "verified fingerprint match is current")
        var falseMatch = equal; falseMatch["latestFingerprint"] = digest
        check((try? decode(falseMatch)) == nil, "helper cannot claim equality with a different fingerprint")
        var noIdentity = equal; noIdentity.removeValue(forKey: "latestFingerprint")
        check((try? decode(noIdentity)) == nil, "version number alone cannot hide control")
        var unsafe = ready; unsafe["candidate"] = "../../release"
        check((try? decode(unsafe)) == nil, "candidate path traversal is refused")
        unsafe["candidate"] = "candidate-123"; unsafe["fingerprint"] = digest
        check((try? decode(unsafe)) == nil, "prepared source must match the running copy")
        unsafe = ready; unsafe["archiveSHA256"] = "short"
        check((try? decode(unsafe)) == nil, "prepared archive requires a full digest")
        check((try? PublishReply.decode(Data("html".utf8), runningFingerprint: fingerprint)) == nil, "invalid JSON is refused")
        let info: [String: Any] = ["ClipEdgePublisherEnabled": true, "ClipEdgeContentFingerprint": fingerprint,
            "ClipEdgePublisherTool": "/Users/al/amaanah/projects/clipedge/src/tools/publisher.sh"]
        check(PublishCapability.resolve(info: info, fileExists: { _ in true }) != nil, "explicit local maintainer capability is accepted")
        check(PublishCapability.resolve(info: [:], fileExists: { _ in true }) == nil, "ordinary source build is hidden")
        var release = info; release["ClipEdgeUpdateFeed"] = "https://api.github.com/release"
        check(PublishCapability.resolve(info: release, fileExists: { _ in true }) == nil, "release copy cannot publish even with stray metadata")
        check(PublishCapability.resolve(info: info, fileExists: { _ in false }) == nil, "missing canonical helper cannot execute")
        release = info; release["ClipEdgePublisherTool"] = "/tmp/publish.sh"
        check(PublishCapability.resolve(info: release, fileExists: { _ in true }) == nil, "unrelated executable cannot become publisher")
    }

    static func wording() {
        let difference = PublishDifference(latestVersion: "2.3", detail: "This copy differs from release 2.3.")
        check(PublishState.different(difference).presentation.emphasis == .bright, "difference gets bright action")
        check(PublishState.different(difference).presentation.title == "Publish… ⇧⌘P", "publish action announces its local key")
        check(PublishState.different(difference).presentation.help.contains("cannot confirm"), "difference does not claim to know Mom's version")
        check(PublishState.unknown("Offline").presentation.isVisible, "offline cannot look synchronized")
        check(PublishState.unknown("Offline").presentation.emphasis == .neutral, "unknown is visibly different from publishable")
        check(PublishState.unknown("Offline").presentation.help.contains("Release status unavailable"), "unknown explains the uncertainty")
        check(!PublishState.current(version: "2.3").presentation.isVisible, "verified match hides control")
        check(!PublishState.hidden.presentation.isVisible, "public control is hidden")
        check(!PublishState.preparing(difference).presentation.isEnabled, "preparation cannot start twice")
    }

    @MainActor static func comparisons() async {
        let fake = FakePublisher(); let controller = fake.controller()
        fake.replies = [different, equal, ["kind": "unknown", "message": "Offline"], ["kind": "rebuildRequired", "message": "Rebuild ClipEdge."]]
        _ = await controller.check()
        check(controller.presentation.emphasis == .bright, "running mismatch offers publish")
        _ = await controller.check()
        check(!controller.presentation.isVisible, "later equality hides both surfaces' shared state")
        _ = await controller.check()
        check(controller.state == .unknown("Offline"), "a failed later check removes stale certainty")
        _ = await controller.check()
        check(controller.state == .rebuildRequired("Rebuild ClipEdge."), "source edits require rebuilding")
        let publicFake = FakePublisher(); let publicController = publicFake.controller(publicBuild: true)
        publicController.start(); publicController.refresh(); _ = await publicController.check(); await publicController.act()
        check(publicController.state == .hidden && publicFake.calls.isEmpty, "customer/source copies never invoke helper or network")
        let broken = PublishController(environment: .configured(info: ["ClipEdgePublisherEnabled": true], fileExists: { _ in false }))
        check(broken.presentation.isVisible && broken.presentation.emphasis == .neutral, "broken maintainer metadata stays visibly unknown")
        broken.start(); _ = await broken.check()
        check(broken.presentation.isVisible, "missing helper cannot become false synchronization")
    }

    @MainActor static func consent() async {
        let fake = FakePublisher(); fake.replies = [different, ready]
        let controller = fake.controller(); _ = await controller.check(); await controller.act()
        check(fake.reviews.count == 1, "prepared artifact gets an explicit review")
        check(fake.calls.map { $0[0] } == ["status", "prepare"], "cancel does not execute publish")
        check(controller.presentation.emphasis == .bright && controller.presentation.isEnabled, "cancel retains the action")
        check(fake.reviews[0].archiveSHA256 == digest && fake.reviews[0].changes == "Adds the publish control.", "review names exact bytes and changes")
        let alert = PublishReview.alert(candidate: fake.reviews[0])
        check(alert.buttons[0].title == "Cancel" && alert.buttons[1].title == "Publish 2.3.1 ⌘Return", "review's primary choice cancels and publish names version and key")
        check(alert.buttons[0].keyEquivalent == "\r" && alert.buttons[0].keyEquivalentModifierMask.isEmpty, "plain Return keeps release private")
        check(alert.buttons[1].keyEquivalent == "\r" && alert.buttons[1].keyEquivalentModifierMask == .command, "only deliberate Command-Return publishes")
    }

    @MainActor static func publication() async {
        let fake = FakePublisher(); fake.approved = true
        fake.replies = [different, ready, ["kind": "published", "latestFingerprint": fingerprint], equal]
        let controller = fake.controller(); _ = await controller.check()
        var states: [PublishState] = []; let owner = NSObject()
        controller.observe(owner: owner) { _ in states.append(controller.state) }
        await controller.act()
        check(fake.calls.map { $0[0] } == ["status", "prepare", "publish", "status"], "approved frozen candidate is published then checked anew")
        let call = fake.calls[2]
        check(call.contains("candidate-123") && call.contains(digest) && call.contains("--approve"), "publish binds explicit approval to candidate and digest")
        check(call.contains("--receipt-sha256") && call.contains(receiptDigest), "publish binds approval to the reviewed notes and receipt")
        check(call.suffix(2) == ["--running-fingerprint", fingerprint], "publish includes the installed identity")
        check(states.contains { if case .verifying = $0 { return true }; return false }, "upload success passes through visible verification")
        check(controller.state == .current(version: "2.3.1"), "only fresh exact equality hides action after publishing")
    }

    @MainActor static func failures() async {
        for final in [["kind": "unknown", "message": "Offline"], different] {
            let fake = FakePublisher(); fake.approved = true
            fake.replies = [different, ready, ["kind": "published", "latestFingerprint": fingerprint], final]
            let controller = fake.controller(); _ = await controller.check(); await controller.act()
            check(controller.presentation.isVisible, "upload success without current public equality cannot hide control")
        }
        let fake = FakePublisher(); fake.approved = true
        fake.replies = [different, ready, ["kind": "error", "message": "Sign in with gh auth login."], different,
            ["kind": "published", "latestFingerprint": fingerprint], equal]
        let controller = fake.controller(); _ = await controller.check(); await controller.act()
        check(controller.presentation.isEnabled && controller.presentation.isVisible, "auth failure leaves retry action")
        check(fake.failures == ["Sign in with gh auth login."], "auth instructions are reported")
        await controller.act()
        check(fake.calls.map { $0[0] } == ["status", "prepare", "publish", "status", "publish", "status"], "retry checks then resumes exact candidate without preparing again")
        check(fake.reviews.count == 2 && fake.reviews[0] == fake.reviews[1], "retry reviews the same frozen bytes and notes again")
        check(controller.state == .current(version: "2.3.1"), "retry hides only after public equality")
        let edited = FakePublisher(); edited.approved = true
        edited.replies = [different, ready, ["kind": "error", "message": "Upload interrupted"],
            ["kind": "rebuildRequired", "message": "Source moved on"], ["kind": "published", "latestFingerprint": fingerprint], equal]
        let frozen = edited.controller(); _ = await frozen.check(); await frozen.act(); await frozen.act()
        check(frozen.state == .current(version: "2.3.1") && edited.reviews.count == 2 && edited.reviews[0] == edited.reviews[1], "later editable source changes do not prevent retrying the same approved running content")
        let cancelled = FakePublisher(); cancelled.replies = [different, ready, different]
        let paused = cancelled.controller(); _ = await paused.check(); await paused.act(); _ = await paused.check()
        if case .ready = paused.state { check(true, "background refresh retains a cancelled frozen candidate") }
        else { check(false, "background refresh retains a cancelled frozen candidate") }
        let stale = FakePublisher(); stale.approved = true
        stale.replies = [different, ready, ["kind": "error", "message": "Another release appeared.", "recovery": "prepare"], different, ready]
        let invalid = stale.controller(); _ = await invalid.check(); await invalid.act()
        await invalid.act(); stale.approved = false; await invalid.act()
        check(stale.calls.map { $0[0] } == ["status", "prepare", "publish", "status", "prepare"], "definitely invalid candidate is discarded so the user can prepare a new one")
        // Publication always carries its log; recovery, not the log, decides whether the candidate survives.
        let unreconciled = "Public main has changes that are not in this candidate: 4e984f8 Load previews off the main thread. Apply them to the ClipEdge source in the vault, rebuild, and prepare again."
        let refusing = FakePublisher(); refusing.approved = true
        refusing.replies = [different, ready, ["kind": "error", "message": unreconciled, "recovery": "prepare",
            "logPath": "/Users/al/clipedge/.build/publish-candidates/candidate-123/publication.log"], different, ready]
        let refused = refusing.controller(); _ = await refused.check(); await refused.act()
        if case .failed(let detail, let kept) = refused.state {
            check(detail == unreconciled && kept != nil && refused.presentation.help.contains(unreconciled) && refused.presentation.title == "Retry release ⇧⌘P",
                  "a logged refusal needing a new candidate keeps its reconcile advice and drops the candidate")
        } else { check(false, "a logged refusal needing a new candidate keeps its reconcile advice and drops the candidate") }
        check(refusing.failures == [unreconciled], "the refusal is reported once with its advice")
        await refused.act(); refusing.approved = false; await refused.act()
        check(refusing.calls.map { $0[0] } == ["status", "prepare", "publish", "status", "prepare"], "a logged refusal never republishes the refused candidate")
    }

    @MainActor static func observers() async {
        let fake = FakePublisher(); fake.replies = [different]; let controller = fake.controller()
        let drawer = NSObject(), window = NSObject(); var drawerUpdates = 0, windowUpdates = 0
        controller.observe(owner: drawer) { _ in drawerUpdates += 1 }
        controller.observe(owner: window) { _ in windowUpdates += 1 }
        _ = await controller.check()
        check(drawerUpdates == windowUpdates && drawerUpdates >= 3, "drawer and window observe the same transitions")
        controller.refresh(); await Task.yield()
        check(fake.calls.count == 1, "fresh surface reopen does not check or flicker")
    }

    static func step(_ command: String, _ step: String, _ index: Int, _ label: String, start: Double, end: Double,
                     expected: Double = 10, count: Int = 3) -> PublishProgressEvent {
        PublishProgressEvent(command: command, step: step, label: label, index: index, count: count,
                             start: start, end: end, expectedSeconds: expected)
    }
    static func done(_ command: String, count: Int = 3) -> PublishProgressEvent {
        step(command, "done", count, "Done", start: 1, end: 1, expected: 0, count: count)
    }
    @MainActor static func waitUntil(_ condition: () -> Bool) async {
        var tries = 0
        while !condition() && tries < 10_000 { tries += 1; await Task.yield() }
        check(condition(), "fixture command reached its pause")
    }

    @MainActor static func progressLifecycle() async {
        let fake = FakePublisher(); fake.approved = true; fake.held = ["prepare", "publish"]
        fake.replies = [different, ready, ["kind": "published", "latestFingerprint": fingerprint], equal]
        let controller = fake.controller(); _ = await controller.check()
        var seen: [(PublishState, PublishPresentation)] = []; let owner = NSObject()
        controller.observe(owner: owner) { seen.append((controller.state, $0)) }
        check(controller.presentation.progress == nil && controller.progress == nil, "no fill or track before preparing")
        let run = Task { await controller.act() }
        await waitUntil { fake.gate != nil }
        check(controller.progress?.command == "prepare" && controller.presentation.progress == nil,
              "preparing keeps a track but shows no fill until the helper reports")
        let title = controller.presentation.title
        let prepare = fake.sinks["prepare"]!
        prepare(step("prepare", "freeze", 0, "Freezing the source", start: 0, end: 0.1, expected: 5))
        check(controller.presentation.progress == 0 && controller.presentation.help.hasSuffix(" Now: Freezing the source (0%)"),
              "first step shows its label and percent in the help text")
        check(controller.presentation.title == title, "progress never changes the title, so the header cannot reflow")
        fake.now += 3; controller.tickProgress()
        let eased = controller.presentation.progress ?? -1
        check(eased > 0 && eased < 0.099, "the fill eases within the current step between events")
        fake.now += 100_000; controller.tickProgress()
        check(abs((controller.presentation.progress ?? 0) - 0.099) < 1e-9, "a slow step stops just short of its end")
        prepare(step("prepare", "freeze", 0, "Freezing again", start: 0, end: 0.1))
        prepare(step("publish", "push", 1, "Pushing", start: 0.1, end: 0.5))
        check(controller.presentation.help.contains("Freezing the source"), "repeated steps and other commands' events are ignored")
        let updates = seen.count
        fake.now += 0.0001; controller.tickProgress()
        check(seen.count == updates, "movement below 0.2% does not redraw both surfaces")
        prepare(step("prepare", "tests", 1, "Running the regression checks", start: 0.1, end: 0.8, expected: 200))
        check(seen.count == updates + 1 && controller.presentation.progress == 0.1, "a new step redraws at its start")
        check(controller.presentation.help.hasSuffix(" Now: Running the regression checks (10%)"), "help names the current step")
        var last = 0.1, monotonic = true
        for _ in 0..<50 { fake.now += 7; controller.tickProgress(); let shown = controller.presentation.progress ?? 0
            monotonic = monotonic && shown >= last && shown < 0.8; last = shown }
        check(monotonic && last > 0.7, "the fill only moves forward and stays inside the step")
        prepare(step("prepare", "sign", 2, "Signing the release", start: 0.75, end: 1, expected: 20))
        check((controller.presentation.progress ?? 0) >= last, "a step starting behind the eased fill never moves it back")
        prepare(done("prepare"))
        check(controller.presentation.progress == 1 && controller.presentation.percent == 100, "done fills the lozenge")
        fake.release()
        await waitUntil { fake.gate != nil }
        check(controller.progress?.command == "publish" && controller.presentation.progress == nil,
              "publishing starts its own empty track")
        prepare(step("prepare", "late", 1, "Late preparation line", start: 0.5, end: 0.6, count: 3))
        check(controller.presentation.progress == nil, "a late line from preparation cannot fill the publish track")
        fake.sinks["publish"]!(step("publish", "push", 0, "Pushing the release", start: 0, end: 0.6))
        check(controller.presentation.help.hasSuffix(" Now: Pushing the release (0%)"), "publish reports its own steps")
        fake.release(); await run.value
        check(controller.state == .current(version: "2.3.1") && controller.progress == nil && controller.presentation.progress == nil,
              "finishing removes the track and the fill")
        let verifying = seen.filter { if case .verifying = $0.0 { return true }; return false }
        check(!verifying.isEmpty && verifying.allSatisfy { $0.1.progress == 1 }, "verification after an upload shows a full bar")
        let reviewing = seen.filter { if case .reviewing = $0.0 { return true }; return false }
        check(!reviewing.isEmpty && reviewing.allSatisfy { $0.1.progress == nil && !$0.1.help.contains("Now:") }, "review shows no fill")
    }

    @MainActor static func progressClears() async {
        let failing = FakePublisher()
        failing.replies = [different, ["kind": "error", "message": "The regression checks failed."]]
        failing.progress["prepare"] = [step("prepare", "tests", 0, "Running the regression checks", start: 0, end: 0.7)]
        let failed = failing.controller(); _ = await failed.check(); await failed.act()
        check(failed.progress == nil && failed.presentation.progress == nil && !failed.presentation.help.contains("Now:"),
              "a failed preparation clears the fill")
        let cancelling = FakePublisher(); cancelling.replies = [different, ready]
        cancelling.progress["prepare"] = [step("prepare", "tests", 0, "Running the regression checks", start: 0, end: 0.7), done("prepare")]
        let cancelled = cancelling.controller(); _ = await cancelled.check(); await cancelled.act()
        check(cancelled.progress == nil && cancelled.presentation.progress == nil, "cancelling at review clears the fill")
        let retrying = FakePublisher(); retrying.approved = true
        retrying.replies = [different, ready, ["kind": "error", "message": "Upload interrupted"], different,
            ["kind": "published", "latestFingerprint": fingerprint], equal]
        retrying.progress["publish"] = [step("publish", "push", 0, "Pushing the release", start: 0, end: 0.5)]
        let retried = retrying.controller(); _ = await retried.check(); await retried.act()
        check(retried.presentation.progress == nil && retried.presentation.title.hasPrefix("Retry"), "a failed upload clears the fill")
        var seen: [(PublishState, PublishPresentation)] = []; let owner = NSObject()
        retried.observe(owner: owner) { seen.append((retried.state, $0)) }
        await retried.act()
        let checks = seen.prefix { if case .reviewing = $0.0 { return false }; return true }
        check(checks.contains { if case .verifying = $0.0 { return $0.1.progress == nil }; return false },
              "the retry's opening release check is not shown as a finished upload")
        check(retried.state == .current(version: "2.3.1") && retried.progress == nil, "retry finishes without a leftover track")
        let quiet = FakePublisher(); quiet.replies = [different]
        quiet.progress["status"] = [step("prepare", "tests", 0, "Running the regression checks", start: 0, end: 0.7)]
        let checking = quiet.controller(); _ = await checking.check()
        check(checking.presentation.progress == nil, "status checks never show a fill")
    }

    @MainActor static func process() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ClipEdge-publisher-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("fixture.sh")
        let sentinel = folder.appendingPathComponent("must-not-exist")
        try Data("#!/bin/bash\nprintf '%s' \"$1\"\n".utf8).write(to: script)
        let argument = "$(touch \(sentinel.path)); unexpected shell"
        let output = try await PublishProcess.run(tool: script, arguments: [argument], timeout: 5)
        check(String(data: output, encoding: .utf8) == argument, "arguments stay literal instead of shell interpolation")
        check(!FileManager.default.fileExists(atPath: sentinel.path), "untrusted argument text never executes")
        try Data("#!/bin/bash\necho '{\"kind\":\"equal\"}'\nexit 1\n".utf8).write(to: script)
        do {
            _ = try await PublishProcess.run(tool: script, arguments: [], timeout: 5)
            check(false, "failed helper must not return equality")
        } catch { check(true, "failed helper cannot falsely claim equality") }
        try Data("#!/bin/bash\nexec /bin/sleep 30\n".utf8).write(to: script)
        let began = Date()
        do {
            _ = try await PublishProcess.run(tool: script, arguments: [], timeout: 0.1)
            check(false, "hung helper must time out")
        } catch { check(Date().timeIntervalSince(began) < 5, "hung helper is terminated without blocking the main thread") }
    }
}
