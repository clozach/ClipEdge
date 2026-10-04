import Foundation

/// Stand-ins for the network, the disk and the running app, with counters the checks read.
@MainActor
final class FakeUpdates {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var release: Result<UpdateRelease, UpdateFailure>
    var foundVersion: AppVersion?
    var verifyFailure: UpdateFailure?
    var installFailure: UpdateFailure?
    var goBackFailure: UpdateFailure?
    var busy = false
    var idle: TimeInterval = 1_000
    var saves = true
    var trashHoldsPrevious = true
    var fetches = 0, downloads = 0, installs = 0, reopens = 0, goBacks = 0
    let support: URL

    init(offering version: String, support: URL) {
        self.support = support
        foundVersion = AppVersion(version)
        release = .success(UpdateRelease(version: AppVersion(version)!, archive: URL(string: "https://example.com/ClipEdge.zip")!,
                                         archiveBytes: 10, page: URL(string: "https://example.com/notes")))
    }

    func controller(running: String = "2.1", availability: UpdateAvailability = .available(feed: URL(string: "https://example.com/feed")!)) -> UpdateController {
        UpdateController(environment: UpdateController.Environment(
            runningVersion: AppVersion(running)!, availability: availability, support: support,
            now: { self.now },
            fetchRelease: { _ in
                self.fetches += 1
                await Task.yield()
                return try self.release.get()
            },
            fetchApp: { _, folder in
                self.downloads += 1
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                return folder.appendingPathComponent("ClipEdge.app")
            },
            verify: { _ in if let failure = self.verifyFailure { throw failure } },
            installedVersion: { _ in self.foundVersion },
            install: { _, receipts in
                self.installs += 1
                if let failure = self.installFailure { throw failure }
                return receipts.appendingPathComponent("receipt.json")
            },
            goBack: { _ in
                self.goBacks += 1
                if let failure = self.goBackFailure { throw failure }
            },
            canGoBack: { _ in self.trashHoldsPrevious },
            isBusy: { self.busy },
            secondsSinceInput: { self.idle },
            saveBeforeQuit: { self.saves },
            reopenAndQuit: { self.reopens += 1 }))
    }
}

@main enum UpdateTests {
    static var assertions = 0
    static func check(_ condition: Bool, _ message: String) {
        assertions += 1
        guard condition else { fatalError("FAIL: \(message)") }
    }

    @MainActor static func main() async throws {
        versions()
        feed()
        archiveAndSchedule()
        availability()
        wording()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClipEdge-update-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var folders = 0
        func support() -> URL { folders += 1; return root.appendingPathComponent("support-\(folders)") }
        persistence(in: support())
        await consentAndBlocking(support: support)
        await checking(support: support)
        await installing(support: support)
        await goingBack(support: support)
        print("Update tests passed: \(assertions) assertions")
    }

    static func versions() {
        check(AppVersion("2.1") == AppVersion("v2.1.0"), "2.1 equals v2.1.0")
        check(AppVersion("2.10")! > AppVersion("2.9")!, "parts compare as numbers")
        check(AppVersion("2.1.1")! > AppVersion("2.1")!, "a third part counts")
        check(AppVersion("2.0")! < AppVersion("2.0.1")!, "a missing part is zero")
        check(!(AppVersion("2.1")! > AppVersion("2.1.0")!), "an equal version is not newer")
        check(AppVersion(" 2.1\n")?.description == "2.1" && AppVersion("3")?.description == "3.0", "display form")
        for bad in ["", "v", "2.x", "2..1", "1.2.3.4.5", "２.1", "-1", "2.1 beta", "2.1-rc1", "9999999999.0"] {
            check(AppVersion(bad) == nil, "rejects version text '\(bad)'")
        }
    }

    static func json(tag: String = "v2.2.0", assets: String = #"[{"name":"SHA256SUMS","browser_download_url":"https://github.com/clozach/ClipEdge/releases/download/v2.2.0/SHA256SUMS","size":96},{"name":"ClipEdge-2.2-macOS-universal.zip","browser_download_url":"https://github.com/clozach/ClipEdge/releases/download/v2.2.0/ClipEdge-2.2-macOS-universal.zip","size":2400000}]"#) -> Data {
        Data(#"{"tag_name":"\#(tag)","html_url":"https://github.com/clozach/ClipEdge/releases/tag/\#(tag)","draft":false,"assets":\#(assets)}"#.utf8)
    }

    static func feed() {
        guard case .success(let release) = UpdateFeed.release(from: json()) else { fatalError("FAIL: GitHub's release shape parses") }
        check(release.version == AppVersion("2.2") && release.archiveBytes == 2_400_000, "version and size are read")
        check(release.archive.lastPathComponent == "ClipEdge-2.2-macOS-universal.zip", "the zip is chosen, not the checksum file")
        check(release.page?.absoluteString.hasSuffix("/v2.2.0") == true, "release page is kept for What's New")
        func failure(_ data: Data, local: Bool = false) -> UpdateFailure? {
            if case .failure(let failure) = UpdateFeed.release(from: data, allowLocal: local) { return failure }
            return nil
        }
        check(failure(Data("<html>".utf8)) == .feedUnreadable("the release list was not readable"), "garbage is refused")
        check(failure(Data(#"{"assets":[]}"#.utf8)) == .feedUnreadable("the release has no version number"), "a release needs a version")
        check(failure(json(tag: "latest")) == .feedUnreadable("the release has no version number"), "a tag must be a version")
        check(failure(json(assets: "[]")) == .noArchive, "no download attached")
        check(failure(json(assets: #"[{"name":"SHA256SUMS","browser_download_url":"https://x.test/SHA256SUMS","size":1}]"#)) == .noArchive, "a checksum file is not a download")
        check(failure(json(assets: #"[{"name":"ClipEdge.zip","browser_download_url":"http://x.test/ClipEdge.zip","size":1}]"#)) == .noArchive, "plain http is refused")
        let local = json(assets: #"[{"name":"ClipEdge.zip","browser_download_url":"file:///tmp/ClipEdge.zip","size":1}]"#)
        check(failure(local) == .noArchive, "a local file is refused for a network feed")
        check(failure(local, local: true) == nil, "a local feed (tests) may name a local file")
        check(failure(json(assets: #"[{"name":"ClipEdge.zip","browser_download_url":"https://x.test/ClipEdge.zip","size":200000000}]"#)) == .archiveTooLarge(200_000_000), "an oversized download is refused")
    }

    static func archiveAndSchedule() {
        let good = ["ClipEdge.app/", "ClipEdge.app/Contents/Info.plist", "ClipEdge.app/Contents/MacOS/ClipEdge", "__MACOSX/ClipEdge.app/._Icon"]
        check(UpdateArchive.unsafeEntry(in: good, bundleName: "ClipEdge.app") == nil, "a normal release archive passes")
        for bad in ["../evil.txt", "/etc/hosts", "ClipEdge.app/../../evil", "Other.app/Contents/Info.plist", "ClipEdge.app\\..\\evil", "evil.txt"] {
            check(UpdateArchive.unsafeEntry(in: good + [bad], bundleName: "ClipEdge.app") == bad, "refuses archive entry \(bad)")
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let hour: TimeInterval = 3_600
        check(UpdateSchedule.isDue(last: nil, now: now), "never checked is due")
        check(!UpdateSchedule.isDue(last: .current(now - 23 * hour), now: now), "23 hours after a good check is not due")
        check(UpdateSchedule.isDue(last: .current(now - 24 * hour), now: now), "a day after a good check is due")
        check(!UpdateSchedule.isDue(last: .failed(now - 0.9 * hour, .noArchive), now: now), "a failed check waits")
        check(UpdateSchedule.isDue(last: .failed(now - hour, .noArchive), now: now), "a failed check retries after an hour")
        check(UpdateSchedule.isDue(last: .current(now + hour), now: now), "a clock set back does not stall checks")
    }

    static func availability() {
        let app = URL(fileURLWithPath: "/Users/mom/Applications/ClipEdge.app")
        func resolve(_ feed: String?, adHoc: Bool = false, writable: Bool = true, at bundle: URL = app) -> UpdateAvailability {
            UpdateAvailability.resolve(bundle: bundle, feedText: feed, isAdHoc: { adHoc }, folderWritable: { writable })
        }
        let feed = "https://api.github.com/repos/clozach/ClipEdge/releases/latest"
        check(resolve(nil) == .blocked(.builtFromSource), "no feed: a source build never updates itself")
        check(resolve("http://example.com/feed") == .blocked(.builtFromSource), "a plain-http feed is no feed")
        check(resolve(feed, adHoc: true) == .blocked(.unsigned), "a copy without a certificate cannot be matched")
        check(resolve(feed, at: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/y/d/ClipEdge.app")) == .blocked(.movedByMacOS), "a translocated copy cannot replace itself")
        check(resolve(feed, writable: false) == .blocked(.folderLocked("/Users/mom/Applications")), "a locked folder is named")
        check(resolve(feed) == .available(feed: URL(string: feed)!), "a signed release in a writable folder can update")
    }

    static func wording() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let feed = UpdateAvailability.available(feed: URL(string: "https://example.com")!)
        func snapshot(_ availability: UpdateAvailability, _ preference: UpdatePreference, _ phase: UpdatePhase,
                      record: UpdateRecord? = nil, canGoBack: Bool = false) -> UpdateStatus.Snapshot {
            UpdateStatus.Snapshot(version: AppVersion("2.1")!, availability: availability, preference: preference, phase: phase,
                                  lastUpdate: record, canGoBack: canGoBack, now: now)
        }
        let source = snapshot(.blocked(.builtFromSource), .unasked, .resting(nil))
        check(UpdateStatus.rows(source) == [.status("ClipEdge 2.1 was built on this Mac. It changes when it is rebuilt."), .separator, .getRelease], "a source build offers the release, no toggle")
        check(UpdateStatus.badge(source) == nil, "a source build shows no badge")
        check(UpdateStatus.rows(snapshot(.blocked(.movedByMacOS), .unasked, .resting(nil))).count == 1, "a translocated copy explains itself only")
        let fresh = snapshot(feed, .unasked, .resting(nil))
        check(UpdateStatus.rows(fresh) == [.status("ClipEdge 2.1. Updates wait for your answer."), .separator, .automatic(isOn: false), .check(enabled: true)], "before the answer")
        check(UpdateStatus.line(snapshot(feed, .manual, .resting(nil))) == "ClipEdge 2.1. Automatic updates are off.", "off is said plainly")
        check(UpdateStatus.rows(snapshot(feed, .automatic, .checking)).contains(.check(enabled: false)), "no second check while one runs")
        let release = UpdateRelease(version: AppVersion("2.2")!, archive: URL(string: "https://example.com/a.zip")!, archiveBytes: 1, page: nil)
        let ready = snapshot(feed, .automatic, .ready(StagedUpdate(release: release, app: URL(fileURLWithPath: "/tmp/ClipEdge.app"))))
        check(UpdateStatus.rows(ready).contains(.install("Install ClipEdge 2.2 and Reopen")) && UpdateStatus.badge(ready) == "2.2 ready", "a waiting update is offered and badged")
        check(UpdateStatus.line(ready) == "ClipEdge 2.2 is ready. It installs when ClipEdge is not in use.", "a waiting update says when it installs")
        check(UpdateStatus.line(snapshot(feed, .automatic, .downloading(release))) == "Downloading ClipEdge 2.2…", "downloading names the version")
        let failed = UpdateStatus.line(snapshot(feed, .automatic, .resting(.failed(now, .offline("The Internet connection appears to be offline.")))))
        check(failed.contains("did not finish: The Internet connection appears to be offline.") && failed.hasSuffix("ClipEdge tries again within the hour."), "a failed check says why and what happens next")
        check(UpdateStatus.line(snapshot(feed, .manual, .resting(.current(now)))).hasSuffix("Automatic updates are off."), "newest, with updates off")
        let record = UpdateRecord(from: "2.0", to: "2.1", date: now - 86_400, receipt: URL(fileURLWithPath: "/tmp/r.json"), page: URL(string: "https://example.com/notes"))
        let updated = snapshot(feed, .automatic, .resting(.current(now)), record: record, canGoBack: true)
        check(Array(UpdateStatus.rows(updated).suffix(3)) == [.separator, .whatsNew("What's New in ClipEdge 2.1"), .goBack("Go Back to ClipEdge 2.0…")], "after an update: what changed and the way back")
        check(UpdateStatus.badge(updated) == "updated to 2.1", "a recent update is badged")
        var old = updated; old.now = now + 8 * 86_400
        check(UpdateStatus.badge(old) == nil, "the badge retires after a week")
        check(!UpdateStatus.rows(snapshot(feed, .automatic, .resting(nil), record: record, canGoBack: false)).contains(.goBack("Go Back to ClipEdge 2.0…")), "no way back once the Trash is emptied")
        let stale = UpdateRecord(from: "1.9", to: "2.0", date: now, receipt: record.receipt, page: record.page)
        check(UpdateStatus.rows(snapshot(feed, .automatic, .resting(nil), record: stale, canGoBack: true)).count == 4, "a record for another version shows nothing")
        let failures: [UpdateFailure] = [.offline("x"), .feedUnreadable("x"), .noArchive, .archiveTooLarge(1), .unsafeArchive("x"), .notClipEdge("x"),
                                         .signatureMismatch("x"), .versionMismatch(expected: "2.2", found: "2.0"), .historyNotSaved, .installFailed("x"), .cannotGoBack("x")]
        check(failures.allSatisfy { !UpdateStatus.message(for: $0).isEmpty && !UpdateStatus.message(for: $0).contains("Optional") }, "every failure has a sentence")
    }

    static func persistence(in folder: URL) {
        check(UpdateState.load(from: folder) == UpdateState(), "no file means the question has not been asked")
        var state = UpdateState()
        state.preference = .automatic
        state.lastCheck = .failed(Date(timeIntervalSince1970: 1_800_000_000), .signatureMismatch("why"))
        state.lastUpdate = UpdateRecord(from: "2.0", to: "2.1", date: Date(timeIntervalSince1970: 1_799_000_000), receipt: URL(fileURLWithPath: "/tmp/r.json"), page: nil)
        state.save(in: folder)
        check(UpdateState.load(from: folder) == state, "state survives a relaunch")
        let file = folder.appendingPathComponent("state.json")
        let mode = (try? FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) ?? 0
        check(mode == 0o600, "state file is private")
        try? Data("{".utf8).write(to: file)
        check(UpdateState.load(from: folder).preference == .unasked, "an unreadable file falls back to asking again")
    }

    @MainActor static func consentAndBlocking(support: () -> URL) async {
        let fake = FakeUpdates(offering: "2.2", support: support())
        let controller = fake.controller()
        var asked = 0
        controller.onNeedsChoice = { asked += 1 }
        controller.start(repeating: false)
        check(asked == 1 && controller.preference == .unasked, "first launch asks once")
        controller.tick()
        await Task.yield()
        check(fake.fetches == 0, "nothing is fetched before the answer")
        controller.choose(.manual)
        controller.tick()
        await Task.yield()
        check(fake.fetches == 0 && UpdateState.load(from: fake.support).preference == .manual, "No Thanks is remembered and nothing is fetched")
        let again = fake.controller()
        again.onNeedsChoice = { asked += 1 }
        again.start(repeating: false)
        check(asked == 1, "an answered question is not asked again")

        let source = FakeUpdates(offering: "2.2", support: support())
        let blocked = source.controller(availability: .blocked(.builtFromSource))
        blocked.onNeedsChoice = { asked += 1 }
        blocked.start(repeating: false)
        blocked.choose(.automatic)
        blocked.tick()
        let phase = await blocked.check()
        check(asked == 1 && source.fetches == 0 && phase == .resting(nil), "a source build never asks and never fetches")
    }

    @MainActor static func checking(support: () -> URL) async {
        let same = FakeUpdates(offering: "2.1.0", support: support())
        let current = same.controller()
        current.choose(.automatic)
        check(await current.check() == .resting(.current(same.now)), "the same version is up to date")
        check(same.downloads == 0, "the same version is not downloaded")
        current.tick(); await Task.yield(); await Task.yield()
        check(same.fetches == 1, "no second check within a day")
        same.now += 24 * 3_600
        current.tick()
        for _ in 0..<5 { await Task.yield() }
        check(same.fetches == 2, "the next day's check runs on the schedule")
        check(same.controller().phase == .resting(.current(same.now)), "the last check is remembered across launches")

        let older = FakeUpdates(offering: "2.0.9", support: support())
        let ahead = older.controller()
        check(await ahead.check() == .resting(.current(older.now)) && older.downloads == 0, "an older release is never downloaded")

        let forged = FakeUpdates(offering: "2.2", support: support())
        forged.verifyFailure = .signatureMismatch("it is not signed by the same developer as this copy")
        let guarded = forged.controller()
        guarded.choose(.automatic)
        check(await guarded.check() == .resting(.failed(forged.now, forged.verifyFailure!)), "a download from another signer is refused")
        check(!FileManager.default.fileExists(atPath: forged.support.appendingPathComponent("staged").path), "a refused download is removed")
        guarded.tick()
        check(forged.installs == 0 && forged.reopens == 0, "a refused download is never installed")
        forged.now += 30 * 60
        guarded.tick(); await Task.yield()
        check(forged.fetches == 1, "a failed check is not retried within the hour")

        let mislabeled = FakeUpdates(offering: "2.2", support: support())
        mislabeled.foundVersion = AppVersion("2.0")
        check(await mislabeled.controller().check() == .resting(.failed(mislabeled.now, .versionMismatch(expected: "2.2", found: "2.0"))), "an old build relabeled as new is refused")

        let offline = FakeUpdates(offering: "2.2", support: support())
        offline.release = .failure(.offline("The Internet connection appears to be offline."))
        check(await offline.controller().check() == .resting(.failed(offline.now, .offline("The Internet connection appears to be offline."))), "offline is reported, not hidden")

        let twice = FakeUpdates(offering: "2.2", support: support())
        let busy = twice.controller()
        async let first = busy.check()
        async let second = busy.check()
        _ = await (first, second)
        check(twice.fetches == 1 && twice.downloads == 1, "two checks at once make one request")
    }

    @MainActor static func installing(support: () -> URL) async {
        let fake = FakeUpdates(offering: "2.2", support: support())
        let controller = fake.controller()
        controller.choose(.automatic)
        guard case .ready(let staged) = await controller.check() else { fatalError("FAIL: a newer signed release is staged") }
        check(staged.release.version == AppVersion("2.2") && fake.installs == 0, "staging installs nothing")
        fake.busy = true
        controller.tick()
        check(fake.installs == 0, "waits while ClipEdge is in use")
        fake.busy = false; fake.idle = 30
        controller.tick()
        check(fake.installs == 0, "waits until input has been still for two minutes")
        fake.idle = 121; fake.saves = false
        controller.tick()
        check(fake.installs == 0 && controller.phase == .ready(staged), "does not restart when the history cannot be saved")
        fake.saves = true
        controller.tick()
        check(fake.installs == 1 && fake.reopens == 1, "installs and reopens at a quiet moment")
        check(controller.lastUpdate?.from == "2.1" && controller.lastUpdate?.to == "2.2" && controller.lastUpdate?.page != nil, "records what was replaced")
        check(UpdateState.load(from: fake.support).lastUpdate == controller.lastUpdate, "the record survives the restart")

        let off = FakeUpdates(offering: "2.2", support: support())
        let manual = off.controller()
        manual.choose(.manual)
        _ = await manual.check()
        manual.tick()
        check(off.installs == 0, "with automatic updates off, a staged update waits for the person")
        check(manual.installNow() == nil && off.installs == 1 && off.reopens == 1, "Install Now installs it")

        let broken = FakeUpdates(offering: "2.2", support: support())
        broken.installFailure = .installFailed("disk full")
        let failing = broken.controller()
        failing.choose(.automatic)
        _ = await failing.check()
        failing.tick()
        check(failing.phase == .resting(.failed(broken.now, .installFailed("disk full"))) && broken.reopens == 0 && failing.lastUpdate == nil, "a failed install keeps the running copy and says why")
    }

    @MainActor static func goingBack(support: () -> URL) async {
        let fake = FakeUpdates(offering: "2.2", support: support())
        var state = UpdateState()
        state.preference = .automatic
        state.lastUpdate = UpdateRecord(from: "2.0", to: "2.1", date: fake.now, receipt: fake.support.appendingPathComponent("receipts/r.json"), page: nil)
        state.save(in: fake.support)
        try? FileManager.default.createDirectory(at: fake.support.appendingPathComponent("staged"), withIntermediateDirectories: true)
        let controller = fake.controller()
        controller.start(repeating: false)
        check(controller.lastUpdate != nil && controller.canGoBack, "the last update can be undone while the Trash holds the old copy")
        check(!FileManager.default.fileExists(atPath: fake.support.appendingPathComponent("staged").path), "launch clears a leftover download")
        fake.goBackFailure = .cannotGoBack("Previous app is no longer in Trash")
        check(controller.goBack() == fake.goBackFailure && controller.preference == .automatic && fake.reopens == 0, "a failed way back changes nothing")
        fake.goBackFailure = nil
        check(controller.goBack() == nil && fake.goBacks == 2 && fake.reopens == 1, "Go Back restores and reopens")
        check(controller.preference == .manual && controller.lastUpdate == nil, "going back turns automatic updates off, so the old version stays")
        check(controller.goBack() == .cannotGoBack("no earlier copy is recorded"), "nothing to go back to twice")

        let stale = FakeUpdates(offering: "2.2", support: support())
        state.save(in: stale.support)
        let other = stale.controller(running: "2.3")
        other.start(repeating: false)
        check(other.lastUpdate == nil, "a record for a different version is dropped at launch")
    }
}
