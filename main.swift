import AppKit

if CommandLine.arguments.contains("--demo") { ClipboardDemo.run(); exit(EXIT_SUCCESS) }

// A bounded diagnostic uses the installed binary's real macOS permissions.
// It observes one paste gesture without creating a store or reading a clipboard.
if let flag = CommandLine.arguments.firstIndex(of: "--verify-paste-listener"),
   CommandLine.arguments.indices.contains(flag + 1) {
    PasteDetectionDiagnostic.run(reportURL: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
    exit(EXIT_SUCCESS)
}

// The packaged development copy and /Applications copy share one archive.
// Keep the oldest session as its only writer, even when opened by a new URL.
let current = NSRunningApplication.current
let identifier = Bundle.main.bundleIdentifier ?? "local.codex.ClipEdge"
let launchedAt = current.launchDate ?? Date()
if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first(where: {
    guard $0.processIdentifier != current.processIdentifier, !$0.isTerminated else { return false }
    let otherLaunch = $0.launchDate ?? .distantPast
    return otherLaunch < launchedAt || (otherLaunch == launchedAt && $0.processIdentifier < current.processIdentifier)
}) {
    existing.activate(options: [.activateAllWindows])
    exit(EXIT_SUCCESS)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
signal(SIGTERM, SIG_IGN)
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termination.setEventHandler { application.terminate(nil) }
termination.resume()
application.run()
