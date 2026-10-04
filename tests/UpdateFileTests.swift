import Foundation
import Security

/// The updater against real app bundles, real signatures, real archives and a real install transaction.
/// Everything lives in a temporary folder; the Trash here is a folder inside it.
@main enum UpdateFileTests {
    static var assertions = 0
    static let fm = FileManager.default
    static func check(_ condition: Bool, _ message: String) {
        assertions += 1
        guard condition else { fatalError("FAIL: \(message)") }
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String], in directory: URL? = nil) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try! process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// A small real bundle. This test binary stands in for ClipEdge's executable.
    @discardableResult
    static func makeApp(_ url: URL, version: String, identifier: String = "local.codex.ClipEdge", sign identity: String? = nil) throws -> URL {
        try fm.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: url.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "ClipEdge", "CFBundlePackageType": "APPL",
                                   "CFBundleShortVersionString": version, "CFBundleVersion": version]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
        try fm.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath(), to: url.appendingPathComponent("Contents/MacOS/ClipEdge"))
        try Data("version \(version)".utf8).write(to: url.appendingPathComponent("Contents/Resources/note.txt"))
        if let identity {
            let result = run("/usr/bin/codesign", ["--force", "--sign", identity, "--identifier", identifier, url.path])
            precondition(result.status == 0, "codesign failed: \(result.output)")
        }
        return url
    }

    /// A code-signing certificate on this Mac, if there is one. Certificate checks are skipped without it.
    static func certificate() -> String? {
        if let chosen = ProcessInfo.processInfo.environment["CLIPEDGE_SIGN_IDENTITY"], !chosen.isEmpty, chosen != "-" { return chosen }
        let listing = run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"]).output
        for line in listing.split(separator: "\n") {
            let words = line.split(separator: " ")
            if words.count > 2, words[0].hasSuffix(")"), words[1].count == 40 { return String(words[1]) }
        }
        return nil
    }

    static func refusal(_ candidate: URL, _ requirement: SecRequirement) -> String? {
        do { try UpdateVerifier.check(candidate, satisfies: requirement); return nil }
        catch UpdateFailure.signatureMismatch(let reason) { return reason }
        catch { return "\(error)" }
    }

    static func main() async throws {
        let root = fm.temporaryDirectory.appendingPathComponent("ClipEdge-update-file-tests-" + UUID().uuidString).resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try localSignatures(root.appendingPathComponent("local"))
        try certificateSignatures(root.appendingPathComponent("certificate"))
        try installAndGoBack(root.appendingPathComponent("install"))
        try await fetching(root.appendingPathComponent("fetch"))
        print("Update file tests passed: \(assertions) assertions")
    }

    /// Copies built without a certificate: macOS knows each only by its exact bytes.
    static func localSignatures(_ root: URL) throws {
        let first = try makeApp(root.appendingPathComponent("a/ClipEdge.app"), version: "2.1", sign: "-")
        check(UpdateVerifier.isAdHoc(appAt: first), "a copy signed without a certificate is recognised")
        let requirement = try UpdateVerifier.requirement(ofAppAt: first)
        check(UpdateVerifier.text(of: requirement).contains("cdhash"), "such a copy is identified by its exact bytes")
        let twin = root.appendingPathComponent("twin/ClipEdge.app")
        try fm.createDirectory(at: twin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: first, to: twin)
        check(refusal(twin, requirement) == nil, "an identical copy matches")
        let rebuilt = try makeApp(root.appendingPathComponent("b/ClipEdge.app"), version: "2.2", sign: "-")
        check(refusal(rebuilt, requirement) == "it is not signed by the same developer as this copy", "a rebuild without a certificate never matches: the reason approvals are lost")
        try Data("changed".utf8).write(to: twin.appendingPathComponent("Contents/Resources/note.txt"))
        check(refusal(twin, requirement) != nil, "a copy altered after signing is refused")
        let bare = try makeApp(root.appendingPathComponent("c/ClipEdge.app"), version: "2.2")
        check(refusal(bare, requirement) != nil, "an unsigned bundle is refused")
        check(UpdateVerifier.version(ofAppAt: rebuilt) == AppVersion("2.2") && UpdateVerifier.version(ofAppAt: root) == nil, "version is read from the bundle")
    }

    /// Copies signed with one certificate: a later build matches an earlier one, so approvals carry over.
    static func certificateSignatures(_ root: URL) throws {
        guard let identity = certificate() else {
            print("Skipped: no code-signing certificate on this Mac, so same-signer checks did not run.")
            return
        }
        let running = try makeApp(root.appendingPathComponent("v1/ClipEdge.app"), version: "2.1", sign: identity)
        check(!UpdateVerifier.isAdHoc(appAt: running), "a certificate-signed copy is recognised")
        let requirement = try UpdateVerifier.requirement(ofAppAt: running)
        let text = UpdateVerifier.text(of: requirement)
        check(text.contains("identifier \"local.codex.ClipEdge\"") && text.contains("certificate leaf"), "it is identified by its name and its signer")
        let next = try makeApp(root.appendingPathComponent("v2/ClipEdge.app"), version: "2.2", sign: identity)
        check(refusal(next, requirement) == nil, "a later build from the same signer matches")
        let stranger = try makeApp(root.appendingPathComponent("adhoc/ClipEdge.app"), version: "2.2", sign: "-")
        check(refusal(stranger, requirement) == "it is not signed by the same developer as this copy", "a build without the certificate is refused")
        let other = try makeApp(root.appendingPathComponent("other/ClipEdge.app"), version: "2.2", identifier: "local.codex.Other", sign: identity)
        check(refusal(other, requirement) == "it is not signed by the same developer as this copy", "a different app from the same signer is refused")
        try Data("changed".utf8).write(to: next.appendingPathComponent("Contents/Resources/note.txt"))
        check(refusal(next, requirement) != nil, "a signed copy altered afterwards is refused")
        try Data("extra".utf8).write(to: stranger.appendingPathComponent("Contents/Resources/added.txt"))
        check(refusal(stranger, try UpdateVerifier.requirement(ofAppAt: stranger)) != nil, "a file added after signing is refused")
    }

    static func installAndGoBack(_ root: URL) throws {
        let trashFolder = root.appendingPathComponent("Trash")
        try fm.createDirectory(at: trashFolder, withIntermediateDirectories: true)
        func trash(_ app: URL) throws -> URL {
            let destination = trashFolder.appendingPathComponent(UUID().uuidString + ".app")
            try fm.moveItem(at: app, to: destination)
            return destination
        }
        let identifier = "local.codex.ClipEdge"
        let target = try makeApp(root.appendingPathComponent("Mom's Applications/ClipEdge.app"), version: "2.1")
        let staged = try makeApp(root.appendingPathComponent("staged/unpacked/ClipEdge.app"), version: "2.2")
        let receipts = root.appendingPathComponent("receipts")
        var verified = 0
        let receipt = try UpdateInstaller.install(staged, over: target, identifier: identifier, receipts: receipts, trash: trash) { _ in verified += 1 }
        check(UpdateVerifier.version(ofAppAt: target) == AppVersion("2.2"), "the new version is in place")
        check(verified == 2, "the copy is verified again after it is moved beside the destination")
        check((try fm.contentsOfDirectory(atPath: trashFolder.path)).count == 1 && UpdateInstaller.canGoBack(using: receipt), "the old version waits in the Trash")
        try UpdateInstaller.goBack(using: receipt, identifier: identifier, trash: trash)
        check(UpdateVerifier.version(ofAppAt: target) == AppVersion("2.1"), "Go Back returns the old version")
        check(!UpdateInstaller.canGoBack(using: receipt), "a used receipt offers nothing further")

        func failure(_ body: () throws -> Void) -> UpdateFailure? {
            do { try body(); return nil } catch { return error as? UpdateFailure }
        }
        let refused = failure { _ = try UpdateInstaller.install(staged, over: target, identifier: identifier, receipts: receipts, trash: trash) { _ in throw UpdateFailure.signatureMismatch("no") } }
        if case .installFailed = refused {} else { fatalError("FAIL: a copy that fails verification is not installed") }
        check(UpdateVerifier.version(ofAppAt: target) == AppVersion("2.1"), "a refused install leaves the running version in place")
        let leftovers = (try? fm.contentsOfDirectory(atPath: receipts.path))?.filter { $0 != receipt.lastPathComponent } ?? []
        check(leftovers.isEmpty, "a refused install leaves no receipt behind")
        let wrong = try makeApp(root.appendingPathComponent("wrong/ClipEdge.app"), version: "2.2", identifier: "local.codex.Other")
        if case .installFailed = failure({ _ = try UpdateInstaller.install(wrong, over: target, identifier: identifier, receipts: receipts, trash: trash) { _ in } }) {} else { fatalError("FAIL: another app is not installed over ClipEdge") }
        check(UpdateVerifier.version(ofAppAt: target) == AppVersion("2.1"), "the running version survives a wrong download")

        let second = try UpdateInstaller.install(staged, over: target, identifier: identifier, receipts: receipts, trash: trash) { _ in }
        for item in try fm.contentsOfDirectory(at: trashFolder, includingPropertiesForKeys: nil) { try fm.removeItem(at: item) }
        check(!UpdateInstaller.canGoBack(using: second), "an emptied Trash ends the way back")
        if case .cannotGoBack = failure({ try UpdateInstaller.goBack(using: second, identifier: identifier, trash: trash) }) {} else { fatalError("FAIL: Go Back reports an emptied Trash") }
        check(UpdateVerifier.version(ofAppAt: target) == AppVersion("2.2"), "a failed Go Back leaves the current version running")
        check(!UpdateInstaller.canGoBack(using: root.appendingPathComponent("missing.json")), "no receipt, no way back")
    }

    static func fetching(_ root: URL) async throws {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let session = UpdateFetcher.session()
        let app = try makeApp(root.appendingPathComponent("build/ClipEdge.app"), version: "2.2", sign: "-")
        let archive = root.appendingPathComponent("ClipEdge-2.2-macOS-universal.zip")
        check(run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", app.path, archive.path]).status == 0, "release archive made")
        let size = (try fm.attributesOfItem(atPath: archive.path)[.size] as? Int) ?? 0
        func writeFeed(_ name: String, archive: URL) throws -> URL {
            let feed = root.appendingPathComponent(name)
            let text = #"{"tag_name":"v2.2.0","html_url":"https://github.com/clozach/ClipEdge/releases/tag/v2.2.0","assets":[{"name":"ClipEdge-2.2-macOS-universal.zip","browser_download_url":"\#(archive.absoluteString)","size":\#(size)}]}"#
            try Data(text.utf8).write(to: feed)
            return feed
        }
        let release = try await UpdateFetcher.release(feed: try writeFeed("latest.json", archive: archive), runningVersion: "2.1", session: session)
        check(release.version == AppVersion("2.2") && release.archive == archive, "the release list is fetched and read")
        let folder = root.appendingPathComponent("staged")
        let unpacked = try await UpdateFetcher.app(for: release, bundleName: "ClipEdge.app", runningVersion: "2.1", in: folder, session: session)
        check(UpdateVerifier.version(ofAppAt: unpacked) == AppVersion("2.2"), "the download unpacks to the app")
        check(refusal(unpacked, try UpdateVerifier.requirement(ofAppAt: app)) == nil, "the signature survives download and unpacking")
        check(!fm.fileExists(atPath: folder.appendingPathComponent("download.zip").path), "the archive is removed once unpacked")
        let mode = (try fm.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int) ?? 0
        check(mode == 0o700, "the download folder is private")

        func failure(_ archive: URL) async -> UpdateFailure? {
            let release = UpdateRelease(version: AppVersion("2.2")!, archive: archive, archiveBytes: 1, page: nil)
            do { _ = try await UpdateFetcher.app(for: release, bundleName: "ClipEdge.app", runningVersion: "2.1", in: folder, session: session); return nil }
            catch { return error as? UpdateFailure }
        }
        let inner = root.appendingPathComponent("slip/inner")
        try fm.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data("evil".utf8).write(to: root.appendingPathComponent("slip/evil.txt"))
        run("/usr/bin/zip", ["-q", "../slip.zip", "../evil.txt"], in: inner)
        check(await failure(root.appendingPathComponent("slip/slip.zip")) == .unsafeArchive("../evil.txt"), "an archive that reaches outside its folder is refused before unpacking")
        check(!fm.fileExists(atPath: root.appendingPathComponent("evil.txt").path) && !fm.fileExists(atPath: folder.appendingPathComponent("unpacked").path), "nothing from it is written")
        let other = try makeApp(root.appendingPathComponent("build/Other.app"), version: "2.2")
        let otherArchive = root.appendingPathComponent("other.zip")
        run("/usr/bin/ditto", ["-c", "-k", "--keepParent", other.path, otherArchive.path])
        if case .unsafeArchive = await failure(otherArchive) {} else { fatalError("FAIL: an archive of something else is refused") }
        let text = root.appendingPathComponent("not-a.zip")
        try Data("hello".utf8).write(to: text)
        check(await failure(text) == .unsafeArchive("the download is not a readable archive"), "a file that is not an archive is refused")
        if case .offline = await failure(root.appendingPathComponent("missing.zip")) {} else { fatalError("FAIL: a missing download is reported as unreachable") }
        do {
            _ = try await UpdateFetcher.release(feed: root.appendingPathComponent("missing.json"), runningVersion: "2.1", session: session)
            fatalError("FAIL: a missing release list is reported")
        } catch { check(error is UpdateFailure, "a missing release list is reported, not crashed on") }
    }
}
