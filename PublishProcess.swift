import Foundation
import Darwin

extension PublishController.Environment {
    @MainActor static func live(bundle: Bundle = .main) -> Self {
        let info = bundle.infoDictionary ?? [:]
        return configured(info: info)
    }

    @MainActor static func configured(info: [String: Any], fileExists: (String) -> Bool = FileManager.default.isReadableFile) -> Self {
        guard info["ClipEdgePublisherEnabled"] as? Bool == true, info["ClipEdgeUpdateFeed"] == nil else {
            return Self(fingerprint: nil, execute: { _, _ in
                throw PublishFailure.message("This copy does not publish releases.")
            })
        }
        guard let capability = PublishCapability.resolve(info: info, fileExists: fileExists) else {
            return Self(fingerprint: nil, execute: { _, _ in Data() }, setupFailure:
                "This maintainer copy cannot find its release helper or build identity. Restore the ClipEdge source folder, then rebuild and reopen ClipEdge. Its published status is unknown.")
        }
        return Self(fingerprint: capability.fingerprint, execute: { arguments, progress in
            try await PublishProcess.run(tool: capability.tool, arguments: arguments,
                timeout: arguments.first == "status" ? 45 : 1_200, progress: progress)
        })
    }
}

struct PublishCapability: Equatable {
    var fingerprint: String
    var tool: URL

    static func resolve(info: [String: Any], fileExists: (String) -> Bool = FileManager.default.isReadableFile) -> Self? {
        guard info["ClipEdgePublisherEnabled"] as? Bool == true,
              info["ClipEdgeUpdateFeed"] == nil,
              let fingerprint = info["ClipEdgeContentFingerprint"] as? String, PublishReply.isFingerprint(fingerprint),
              let path = info["ClipEdgePublisherTool"] as? String, path.hasPrefix("/"),
              path.hasSuffix("/projects/clipedge/src/tools/publisher.sh"),
              !path.contains("/../"), !path.contains("/./"), fileExists(path) else { return nil }
        return Self(fingerprint: fingerprint, tool: URL(fileURLWithPath: path))
    }
}

/// Runs only the helper named by the maintainer build, never a shell command assembled from text.
enum PublishProcess {
    /// prepare and publish report progress; status is quick and reports nothing.
    static func run(tool: URL, arguments: [String], timeout: TimeInterval,
                    progress: PublishProgressSink? = nil) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do { continuation.resume(returning: try runBlocking(tool: tool, arguments: arguments, timeout: timeout, progress: progress)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func runBlocking(tool: URL, arguments: [String], timeout: TimeInterval,
                                    progress: PublishProgressSink?) throws -> Data {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("ClipEdge-publish-" + UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: folder) }
        let outputURL = folder.appendingPathComponent("response.json")
        let errorURL = folder.appendingPathComponent("details.log")
        for url in [outputURL, errorURL] {
            guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw PublishFailure.message("The release helper's temporary log could not be created.")
            }
        }
        let output = try FileHandle(forWritingTo: outputURL)
        let errors = try FileHandle(forWritingTo: errorURL)
        defer { try? output.close(); try? errors.close() }
        // Telemetry is best effort: without a readable progress file the helper simply isn't asked for one.
        var arguments = arguments
        var poller: ProgressPoller?
        if let progress, let command = arguments.first, PublishProgressEvent.commands.contains(command) {
            let progressURL = folder.appendingPathComponent("progress.jsonl")
            if fm.createFile(atPath: progressURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) {
                let reader = PublishProgressReader(url: progressURL, command: command)
                if reader.isReadable {
                    arguments += ["--progress-file", progressURL.path]
                    poller = ProgressPoller(reader: reader, sink: progress)
                }
            }
        }
        // Runs before the folder is removed and before the reply returns, so the last events arrive first.
        defer { poller?.finish() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [tool.path] + arguments
        process.currentDirectoryURL = tool.deletingLastPathComponent().deletingLastPathComponent()
        let inherited = ProcessInfo.processInfo.environment
        let allowed = ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "SSH_AUTH_SOCK"]
        var environment = inherited.filter { allowed.contains($0.key) }
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        poller?.start()
        let deadline = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
        process.waitUntilExit()
        deadline.cancel()
        if process.terminationReason == .uncaughtSignal {
            throw PublishFailure.message("The release helper stopped or took too long. Check the latest release, then try again.")
        }
        let size = (try fm.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= 524_288 else { throw PublishFailure.message("The release helper returned too much output.") }
        let response = try Data(contentsOf: outputURL)
        // Error replies carry a concise JSON message. Keep raw build logs out of native dialogs.
        if !response.isEmpty {
            let reply = (try? JSONSerialization.jsonObject(with: response)) as? [String: Any]
            guard process.terminationStatus == 0 || reply?["kind"] as? String == "error" else {
                throw PublishFailure.message("The release helper failed (exit \(process.terminationStatus)). Check the release before trying again.")
            }
            return response
        }
        throw PublishFailure.message("The release helper stopped without a response (exit \(process.terminationStatus)). Run tools/publisher.sh status from the ClipEdge source folder to diagnose it.")
    }
}

/// Polls the progress file about five times a second on its own queue and
/// hands decoded events to the main actor in batches.
private final class ProgressPoller {
    private let queue = DispatchQueue(label: "local.codex.ClipEdge.publish-progress", qos: .utility)
    private let reader: PublishProgressReader
    private let sink: PublishProgressSink
    private var timer: DispatchSourceTimer?

    init(reader: PublishProgressReader, sink: @escaping PublishProgressSink) {
        self.reader = reader
        self.sink = sink
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.2, repeating: 0.2, leeway: .milliseconds(40))
        timer.setEventHandler { [weak self] in self?.deliver() }
        timer.resume()
        self.timer = timer
    }

    /// The final drain waits for any poll in flight, then reads what is left.
    func finish() {
        timer?.cancel()
        queue.sync {
            deliver()
            reader.close()
        }
    }

    private func deliver() {
        let events = reader.poll()
        guard !events.isEmpty else { return }
        let sink = self.sink
        DispatchQueue.main.async { MainActor.assumeIsolated { for event in events { sink(event) } } }
    }
}
