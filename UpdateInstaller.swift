import Foundation

/// Puts a verified copy in place of the running one, reusing the installer's transaction:
/// the old copy goes to the Trash with a receipt, and the receipt can bring it back.
enum UpdateInstaller {
    static func trash(_ url: URL) throws -> URL {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        guard let result else { throw installationError("Trash did not return an undo location") }
        return result as URL
    }

    /// Returns the receipt that undoes this install. On failure the previous copy is put back.
    static func install(_ staged: URL, over target: URL, identifier: String, receipts: URL,
                        trash: (URL) throws -> URL = UpdateInstaller.trash,
                        verify: (URL) throws -> Void) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: receipts, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let receipt = receipts.appendingPathComponent("update-\(UUID().uuidString).json")
        do {
            try prepareInstall(target: target, candidates: [], receiptURL: receipt, identifier: identifier, trash: trash)
            try finishInstall(source: staged, receiptURL: receipt, identifier: identifier, verify: verify)
        } catch {
            var detail = error.localizedDescription
            if fm.fileExists(atPath: receipt.path) {
                do {
                    try restoreInstall(receiptURL: receipt, identifier: identifier, trash: trash)
                    try? fm.removeItem(at: receipt)
                } catch {
                    detail += "; the previous copy is in the Trash and could not be put back: \(error.localizedDescription)"
                }
            }
            throw UpdateFailure.installFailed(detail)
        }
        return receipt
    }

    /// True while the copy this receipt replaced is still in the Trash.
    static func canGoBack(using receipt: URL) -> Bool {
        guard let data = try? Data(contentsOf: receipt),
              let decoded = try? JSONDecoder().decode(InstallReceipt.self, from: data) else { return false }
        return decoded.installed && !decoded.replaced.isEmpty
            && decoded.replaced.allSatisfy { FileManager.default.fileExists(atPath: $0.trashed.path) }
    }

    static func goBack(using receipt: URL, identifier: String,
                       trash: (URL) throws -> URL = UpdateInstaller.trash) throws {
        do { try restoreInstall(receiptURL: receipt, identifier: identifier, trash: trash) }
        catch { throw UpdateFailure.cannotGoBack(error.localizedDescription) }
    }

    /// Opens `app` once this process has exited. ClipEdge keeps one running copy (the oldest wins),
    /// so the new copy has to start after this one is gone. Gives up waiting after a minute.
    static func reopenAfterExit(_ app: URL, pid: Int32 = ProcessInfo.processInfo.processIdentifier) {
        let script = #"i=0; while kill -0 "$1" 2>/dev/null && [ "$i" -lt 600 ]; do sleep 0.1; i=$((i+1)); done; exec /usr/bin/open "$2""#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "clipedge-reopen", String(pid), app.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
