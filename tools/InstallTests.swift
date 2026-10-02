import Foundation

@main enum InstallTests {
    static var count = 0
    static func check(_ condition: Bool, _ message: String) {
        count += 1
        precondition(condition, message)
    }
    static func rejects(_ message: String, _ body: () throws -> Void) {
        do { try body(); fatalError("Expected rejection: \(message)") } catch { count += 1 }
    }
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ClipEdge-install-test-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let trashDir = root.appendingPathComponent("Trash")
        try fm.createDirectory(at: trashDir, withIntermediateDirectories: true)
        func trash(_ app: URL) throws -> URL {
            let result = trashDir.appendingPathComponent(UUID().uuidString + ".app")
            try fm.moveItem(at: app, to: result)
            return result
        }
        func app(_ path: String, _ value: String) throws -> URL {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "local.codex.ClipEdge"], format: .xml, options: 0)
            try plist.write(to: url.appendingPathComponent("Contents/Info.plist"))
            let binary = url.appendingPathComponent("Contents/MacOS/ClipEdge")
            try Data(value.utf8).write(to: binary)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
            return url
        }
        func bytes(_ app: URL) throws -> String {
            try String(contentsOf: app.appendingPathComponent("Contents/MacOS/ClipEdge"), encoding: .utf8)
        }
        let old = try app("Mom With Spaces/Applications/ClipEdge.app", "old")
        let duplicate = try app("System Applications/ClipEdge.app", "duplicate")
        let new = try app("build/ClipEdge.app", "new")
        let receipt = root.appendingPathComponent("receipt.json")
        // Private fixture stand-ins: installation must not touch user-state files.
        let preferences = root.appendingPathComponent("local.codex.ClipEdge.plist")
        let history = root.appendingPathComponent("History.plist")
        let marker = Data("fixture tab placement and history".utf8)
        try marker.write(to: preferences); try marker.write(to: history)
        try prepareInstall(target: old, candidates: [old, duplicate, old], receiptURL: receipt, trash: trash)
        check(!fm.fileExists(atPath: old.path), "old app removed")
        check(!fm.fileExists(atPath: duplicate.path), "duplicate removed")
        var record = try JSONDecoder().decode(InstallReceipt.self, from: Data(contentsOf: receipt))
        check(record.replaced.count == 2, "deduplicated Trash receipts")
        check(record.replaced.allSatisfy { fm.fileExists(atPath: $0.trashed.path) }, "old bundles recoverable")
        let permissions = try fm.attributesOfItem(atPath: receipt.path)[.posixPermissions] as? Int
        check(permissions == 0o600, "receipt private")
        var verified = 0
        try finishInstall(source: new, receiptURL: receipt) { _ in verified += 1 }
        check(verified == 2, "source and staged copy verified")
        check(try bytes(old) == "new", "new app installed")
        check(try bytes(new) == "new", "build source retained")
        check(try Data(contentsOf: preferences) == marker, "preferences unchanged")
        check(try Data(contentsOf: history) == marker, "history unchanged")
        rejects("finish cannot overwrite") { try finishInstall(source: new, receiptURL: receipt, verify: { _ in }) }
        try restoreInstall(receiptURL: receipt, trash: trash)
        check(try bytes(old) == "old", "old version restored")
        check(try bytes(duplicate) == "duplicate", "duplicate restored to original location")
        record = try JSONDecoder().decode(InstallReceipt.self, from: Data(contentsOf: receipt))
        check(!record.installed && record.replaced.isEmpty, "rollback receipt consumed")
        try restoreInstall(receiptURL: receipt, trash: trash)
        check(try bytes(old) == "old", "repeat rollback safe")

        let failed = root.appendingPathComponent("failed.json")
        try prepareInstall(target: old, candidates: [], receiptURL: failed, trash: trash)
        rejects("bad signature") {
            try finishInstall(source: new, receiptURL: failed) { _ in throw installationError("fixture signature failure") }
        }
        check(!fm.fileExists(atPath: old.path), "failed signature never installed")
        try restoreInstall(receiptURL: failed, trash: trash)
        check(try bytes(old) == "old", "build/signature failure rollback")

        let partial = root.appendingPathComponent("partial.json")
        var moves = 0
        rejects("second Trash failure") {
            try prepareInstall(target: old, candidates: [duplicate], receiptURL: partial) { url in
                moves += 1
                if moves == 2 { throw installationError("fixture Trash failure") }
                return try trash(url)
            }
        }
        try restoreInstall(receiptURL: partial, trash: trash)
        check(try bytes(old) == "old", "partial prepare restored target")
        check(try bytes(duplicate) == "duplicate", "partial prepare restored duplicate")
        let wrong = root.appendingPathComponent("wrong.app")
        try fm.createDirectory(at: wrong, withIntermediateDirectories: true)
        rejects("unrecognized bundle") { try prepareInstall(target: wrong, candidates: [], receiptURL: root.appendingPathComponent("wrong.json"), trash: trash) }
        check(fm.fileExists(atPath: wrong.path), "unrecognized bundle preserved")
        let link = root.appendingPathComponent("symlink.app")
        try fm.createSymbolicLink(at: link, withDestinationURL: old)
        rejects("symlink") { try validateApp(link) }
        rejects("reused receipt") { try prepareInstall(target: old, candidates: [], receiptURL: receipt, trash: trash) }
        let clean = root.appendingPathComponent("New User/Applications/ClipEdge.app")
        let first = root.appendingPathComponent("first.json")
        try prepareInstall(target: clean, candidates: [], receiptURL: first, trash: trash)
        try finishInstall(source: new, receiptURL: first, verify: { _ in })
        check(try bytes(clean) == "new", "first installation")
        try restoreInstall(receiptURL: first, trash: trash)
        check(!fm.fileExists(atPath: clean.path), "first installation undo")
        if CommandLine.arguments.count > 1 {
            // Real signed bundle + real macOS Trash, still isolated from installed apps.
            let source = URL(fileURLWithPath: CommandLine.arguments[1])
            let target = root.appendingPathComponent("Real Bundle/ClipEdge.app")
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: target)
            var trashedFixtures: [URL] = []
            defer { for url in trashedFixtures { try? fm.removeItem(at: url) } }
            func systemTrash(_ url: URL) throws -> URL {
                var moved: NSURL?
                try fm.trashItem(at: url, resultingItemURL: &moved)
                let result = moved! as URL
                trashedFixtures.append(result)
                return result
            }
            func signature(_ url: URL) throws {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
                process.arguments = ["--verify", "--strict", url.path]
                try process.run(); process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw installationError("signature") }
            }
            let realReceipt = root.appendingPathComponent("real.json")
            try prepareInstall(target: target, candidates: [], receiptURL: realReceipt, trash: systemTrash)
            check(!fm.fileExists(atPath: target.path), "real macOS Trash moved bundle")
            try finishInstall(source: source, receiptURL: realReceipt, verify: signature)
            try signature(target)
            check(fm.fileExists(atPath: target.path), "real signed bundle installed")
            try restoreInstall(receiptURL: realReceipt, trash: systemTrash)
            try signature(target)
            check(fm.fileExists(atPath: target.path), "real signed bundle restored")
        }
        print("PASS: \(count) installer assertions; fixture-only paths, no running applications touched")
    }
}
