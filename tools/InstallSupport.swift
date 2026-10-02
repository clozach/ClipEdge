import Foundation

struct ReplacedApp: Codable {
    let original: URL
    let trashed: URL
}

struct InstallReceipt: Codable {
    let target: URL
    var replaced: [ReplacedApp] = []
    var installed = false
}

func installationError(_ message: String) -> NSError {
    NSError(domain: "ClipEdge installer", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

func saveReceipt(_ receipt: InstallReceipt, to url: URL) throws {
    try JSONEncoder().encode(receipt).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

func validateApp(_ app: URL, identifier: String = "local.codex.ClipEdge") throws {
    let plist = app.appendingPathComponent("Contents/Info.plist")
    let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any]
    guard info?["CFBundleIdentifier"] as? String == identifier,
          FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/ClipEdge").path),
          (try app.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
        throw installationError("Not a regular ClipEdge app bundle: \(app.path)")
    }
}

// The caller quits applications before entering this file-only transaction.
// Neither preferences nor clipboard history is read, copied or rewritten here.
func prepareInstall(target: URL, candidates: [URL], receiptURL: URL,
                    trash: (URL) throws -> URL) throws {
    let fm = FileManager.default
    guard !fm.fileExists(atPath: receiptURL.path) else {
        throw installationError("Receipt already exists; restore or use a new receipt: \(receiptURL.path)")
    }
    let existing = Array(Set(candidates + [target])).filter { fm.fileExists(atPath: $0.path) }
    for app in existing {
        try validateApp(app)
        guard fm.isWritableFile(atPath: app.deletingLastPathComponent().path) else {
            throw installationError("No permission to replace \(app.path); move it to Trash in Finder, then retry.")
        }
    }
    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    var receipt = InstallReceipt(target: target)
    try saveReceipt(receipt, to: receiptURL)
    for app in existing {
        let trashed = try trash(app)
        receipt.replaced.append(ReplacedApp(original: app, trashed: trashed))
        // If persisting the undo handle fails, restore this move immediately.
        do { try saveReceipt(receipt, to: receiptURL) }
        catch { try fm.moveItem(at: trashed, to: app); throw error }
        print("Previous app moved to Trash: \(trashed.path)")
    }
}

func finishInstall(source: URL, receiptURL: URL, verify: (URL) throws -> Void) throws {
    let fm = FileManager.default
    var receipt = try JSONDecoder().decode(InstallReceipt.self, from: Data(contentsOf: receiptURL))
    try validateApp(source)
    try verify(source)
    guard !receipt.installed, !fm.fileExists(atPath: receipt.target.path) else {
        throw installationError("Destination changed during update; no app overwritten: \(receipt.target.path)")
    }
    // A staging copy ensures a failed copy cannot leave a partial installed app.
    let stage = receipt.target.deletingLastPathComponent().appendingPathComponent(".ClipEdge-\(UUID().uuidString).app")
    defer { try? fm.removeItem(at: stage) }
    try fm.copyItem(at: source, to: stage)
    try verify(stage)
    try fm.moveItem(at: stage, to: receipt.target)
    receipt.installed = true
    do { try saveReceipt(receipt, to: receiptURL) }
    catch { try fm.moveItem(at: receipt.target, to: stage); throw error }
    print("Installed: \(receipt.target.path)")
}

func restoreInstall(receiptURL: URL, trash: (URL) throws -> URL) throws {
    let fm = FileManager.default
    var receipt = try JSONDecoder().decode(InstallReceipt.self, from: Data(contentsOf: receiptURL))
    // Refuse conflicts before changing anything. Rollback never overwrites files.
    for app in receipt.replaced {
        if fm.fileExists(atPath: app.original.path) && !(receipt.installed && app.original == receipt.target) {
            throw installationError("Restore destination occupied: \(app.original.path)")
        }
        guard fm.fileExists(atPath: app.trashed.path) else {
            throw installationError("Previous app is no longer in Trash: \(app.trashed.path)")
        }
    }
    if receipt.installed && fm.fileExists(atPath: receipt.target.path) {
        try validateApp(receipt.target)
        _ = try trash(receipt.target)
    }
    receipt.installed = false
    try saveReceipt(receipt, to: receiptURL)
    while let app = receipt.replaced.last {
        try fm.moveItem(at: app.trashed, to: app.original)
        receipt.replaced.removeLast()
        try saveReceipt(receipt, to: receiptURL)
        print("Restored: \(app.original.path)")
    }
}
