import AppKit

@main enum Installer {
    static func trash(_ url: URL) throws -> URL {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        guard let result else { throw installationError("Trash did not return an undo location") }
        return result as URL
    }

    static func quit() throws -> [URL] {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "local.codex.ClipEdge")
        for app in apps { _ = app.terminate() }
        let deadline = Date().addingTimeInterval(15)
        while apps.contains(where: { !$0.isTerminated }) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        guard apps.allSatisfy({ $0.isTerminated }) else {
            throw installationError("ClipEdge is still running. Resolve its save dialog or quit it, then retry. Nothing has been trashed.")
        }
        return apps.compactMap(\.bundleURL)
    }

    static func verify(_ url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--strict", url.path]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw installationError("App signature verification failed") }
    }

    static func main() {
        do {
            let args = CommandLine.arguments
            guard args.count >= 3 else { throw installationError("Usage: installer prepare RECEIPT [TARGET] | finish RECEIPT SOURCE | restore RECEIPT") }
            let receipt = URL(fileURLWithPath: args[2])
            let home = FileManager.default.homeDirectoryForCurrentUser
            switch args[1] {
            case "prepare":
                let target = args.count > 3 ? URL(fileURLWithPath: args[3]) : home.appendingPathComponent("Applications/ClipEdge.app")
                let standard = [home.appendingPathComponent("Applications/ClipEdge.app"), URL(fileURLWithPath: "/Applications/ClipEdge.app")]
                // Reject wrong-identity bundles before asking any app to quit.
                for app in standard + [target] where FileManager.default.fileExists(atPath: app.path) { try validateApp(app) }
                let running = try quit()
                try prepareInstall(target: target, candidates: standard + running, receiptURL: receipt, trash: trash)
            case "finish":
                guard args.count == 4 else { throw installationError("finish requires a source app") }
                try finishInstall(source: URL(fileURLWithPath: args[3]), receiptURL: receipt, verify: verify)
            case "restore":
                _ = try quit()
                try restoreInstall(receiptURL: receipt, trash: trash)
            default: throw installationError("Unknown installer command")
            }
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
