import Foundation
import CryptoKit

/// Content identity is independent of the release label, local paths, documentation and tests.
/// Git's blob hashes let the same recipe read an older public tag that has no build manifest.
enum ContentIdentity {
    static let algorithm = "clipedge-content-v1"

    static func included(_ path: String) -> Bool {
        if !path.contains("/") && path.hasSuffix(".swift") { return true }
        // build.sh bundles this icon. Other Resources files include historical backups that
        // are deliberately excluded from the public export and cannot affect the running app.
        if path == "Resources/AppIcon.icns" { return true }
        return ["tools/build.sh", "tools/publisher/Identity.swift", "tools/publisher/IdentityMain.swift"].contains(path)
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func blob(_ data: Data) -> String {
        let header = Data("blob \(data.count)\0".utf8)
        return Insecure.SHA1.hash(data: header + data).map { String(format: "%02x", $0) }.joined()
    }

    static func fingerprint(_ blobs: [String: String]) throws -> String {
        let selected = blobs.filter { included($0.key) }
        guard selected.keys.contains(where: { !$0.contains("/") && $0.hasSuffix(".swift") }),
              selected["tools/build.sh"] != nil else { throw IdentityError.incomplete }
        let record = selected.keys.sorted().map { "\($0)\t\(selected[$0]!)\n" }.joined()
        return sha256(Data((algorithm + "\n" + record).utf8))
    }

    static func files(at root: URL, excludingBuild: Bool = true) throws -> [String: URL] {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let manager = FileManager.default
        guard let iterator = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                                 options: [.skipsHiddenFiles]) else { throw IdentityError.incomplete }
        var result: [String: URL] = [:]
        for case let file as URL in iterator {
            let normalized = file.resolvingSymlinksInPath().standardizedFileURL
            guard normalized.path.hasPrefix(root.path + "/") else { throw IdentityError.incomplete }
            let relative = String(normalized.path.dropFirst(root.path.count + 1))
            if excludingBuild && (relative == ".build" || relative.hasPrefix(".build/")) { iterator.skipDescendants(); continue }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { throw IdentityError.symlink(relative) }
            if values.isRegularFile == true { result[relative] = normalized }
        }
        return result
    }

    static func local(_ root: URL) throws -> String {
        var blobs: [String: String] = [:]
        for (path, file) in try files(at: root) where included(path) { blobs[path] = blob(try Data(contentsOf: file)) }
        return try fingerprint(blobs)
    }
}

enum IdentityError: Error, CustomStringConvertible {
    case incomplete
    case symlink(String)
    var description: String {
        switch self {
        case .incomplete: return "The source content could not be identified completely."
        case .symlink(let path): return "Source contains a symbolic link: \(path)."
        }
    }
}
