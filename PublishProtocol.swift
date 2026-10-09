import Foundation

/// Decode the helper's untrusted output before it can influence state or command arguments.
enum PublishReply: Equatable {
    case status(PublishState)
    case ready(PublishCandidate)
    case published(fingerprint: String)

    static func decode(_ data: Data, runningFingerprint: String) throws -> PublishReply {
        let object: [String: Any]
        guard data.count <= 524_288,
              let decoded = try? JSONSerialization.jsonObject(with: data),
              let dictionary = decoded as? [String: Any],
              dictionary["kind"] is String else {
            throw PublishFailure.message("The release helper returned an unreadable response.")
        }
        object = dictionary
        func string(_ key: String, limit: Int = 12_000) throws -> String {
            guard let value = object[key] as? String, !value.isEmpty, value.count <= limit else {
                throw PublishFailure.message("The release helper's response is missing a valid \(key).")
            }
            return value
        }
        func message(_ fallback: String) -> String {
            (object["message"] as? String) ?? fallback
        }
        switch try string("kind", limit: 40) {
        case "equal":
            let fingerprint = try string("latestFingerprint", limit: 64)
            guard isFingerprint(fingerprint), fingerprint == runningFingerprint else {
                throw PublishFailure.message("The release could not be verified as matching this copy.")
            }
            return .status(.current(version: try string("latestVersion", limit: 60)))
        case "different":
            return .status(.different(PublishDifference(latestVersion: try string("latestVersion", limit: 60),
                detail: message("This copy differs from the latest published release."))))
        case "unknown":
            return .status(.unknown(message("The latest release could not be checked. Try again when you are online.")))
        case "rebuildRequired":
            return .status(.rebuildRequired(message("The source has changed since this copy was built. Rebuild and reopen ClipEdge before preparing a release.")))
        case "ready":
            let id = try string("candidate", limit: 160)
            let fingerprint = try string("fingerprint", limit: 64)
            let digest = try string("archiveSHA256", limit: 64)
            let receipt = try string("receiptSHA256", limit: 64)
            guard id.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil,
                  isFingerprint(fingerprint), fingerprint == runningFingerprint,
                  isFingerprint(digest), isFingerprint(receipt) else {
                throw PublishFailure.message("The prepared release does not match this running copy, or its receipt is invalid. Rebuild and try again.")
            }
            return .ready(PublishCandidate(id: id, version: try string("version", limit: 60),
                fingerprint: fingerprint, archiveSHA256: digest, changes: try string("changes"),
                previousVersion: try string("previousVersion", limit: 60), receiptSHA256: receipt))
        case "published":
            let fingerprint = try string("latestFingerprint", limit: 64)
            guard isFingerprint(fingerprint) else { throw PublishFailure.message("The published release has no valid identity.") }
            return .published(fingerprint: fingerprint)
        case "error":
            let detail = message("The release operation did not finish. Try again.")
            var log: URL?
            if let path = object["logPath"] as? String, path.hasPrefix("/"), path.hasSuffix(".log"),
               path.contains("/.build/publish-candidates/"), !path.contains("/../") {
                log = URL(fileURLWithPath: path)
            }
            if object["recovery"] as? String == "prepare" { throw PublishFailure.prepareAgain(detail, log) }
            if let log { throw PublishFailure.logged(detail, log) }
            throw PublishFailure.message(detail)
        default: throw PublishFailure.message("The release helper returned an unsupported response.")
        }
    }

    static func isFingerprint(_ text: String) -> Bool {
        text.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
    }
}
