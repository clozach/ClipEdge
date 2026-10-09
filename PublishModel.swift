import Foundation

struct PublishDifference: Equatable {
    var latestVersion: String
    var detail: String
}

struct PublishCandidate: Equatable {
    var id: String
    var version: String
    var fingerprint: String
    var archiveSHA256: String
    var changes: String
    var previousVersion: String
    var receiptSHA256: String = ""
}

/// A missing comparison is deliberately different from a verified match.
enum PublishState: Equatable {
    case hidden
    case checking
    case current(version: String)
    case unknown(String)
    case rebuildRequired(String)
    case different(PublishDifference)
    case preparing(PublishDifference)
    case ready(PublishCandidate, PublishDifference)
    case reviewing(PublishCandidate, PublishDifference)
    case publishing(PublishCandidate, PublishDifference)
    case verifying(PublishCandidate, PublishDifference)
    case failed(String, PublishDifference?)
    case publishFailed(String, PublishCandidate, PublishDifference)

    var isBusy: Bool {
        switch self {
        case .checking, .preparing, .reviewing, .publishing, .verifying: return true
        default: return false
        }
    }

    var presentation: PublishPresentation {
        func shown(_ title: String, _ help: String, bright: Bool = false) -> PublishPresentation {
            PublishPresentation(isVisible: true, title: title, help: help, isBusy: isBusy,
                                isEnabled: !isBusy, emphasis: bright ? .bright : .neutral)
        }
        switch self {
        case .hidden, .current:
            return PublishPresentation(isVisible: false, title: "", help: "", isBusy: false,
                                       isEnabled: false, emphasis: .neutral)
        case .checking:
            return shown("Checking release…", "Checking whether this copy matches the latest published release.")
        case .unknown(let detail):
            return shown("Check release ⇧⌘P", "Release status unavailable. \(detail) Click to retry.")
        case .rebuildRequired(let detail):
            return shown("Rebuild needed ⇧⌘P", detail)
        case .different(let difference):
            return shown("Publish… ⇧⌘P", difference.detail + " Prepare and test a release for review. A published match cannot confirm which version Mom has installed.", bright: true)
        case .preparing:
            return shown("Preparing release…", "Freezing, testing and signing this copy. Nothing is published yet.", bright: true)
        case .ready:
            return shown("Review release… ⇧⌘P", "A frozen, tested release is ready for your decision. Nothing new will be built.", bright: true)
        case .reviewing:
            return shown("Review release…", "The tested release is waiting for your decision.", bright: true)
        case .publishing:
            return shown("Publishing…", "Uploading the exact release you approved.", bright: true)
        case .verifying:
            return shown("Verifying release…", "Checking that the latest public release matches this copy.", bright: true)
        case .failed(let detail, let difference):
            return shown("Retry release ⇧⌘P", detail + " Click to check the release again.", bright: difference != nil)
        case .publishFailed(let detail, _, _):
            return shown("Retry release ⇧⌘P", detail + " Publication is unverified. Retry checks the public release, then resumes the same frozen candidate.")
        }
    }
}

struct PublishPresentation: Equatable {
    enum Emphasis { case bright, neutral }
    var isVisible: Bool
    var title: String
    var help: String
    var isBusy: Bool
    var isEnabled: Bool
    var emphasis: Emphasis
    /// Fraction of the current prepare or publish command, 0...1; nil draws no fill.
    var progress: Double? = nil

    /// Whole percent, rounded down so only a finished command reads 100.
    var percent: Int? {
        guard let progress, progress.isFinite else { return nil }
        return Int((min(max(progress, 0), 1) * 100 + 1e-9).rounded(.down))
    }
}

enum PublishFailure: LocalizedError, Equatable {
    case message(String)
    case logged(String, URL)
    case prepareAgain(String, URL?)
    var errorDescription: String? {
        switch self { case .message(let text), .logged(let text, _), .prepareAgain(let text, _): return text }
    }
    var log: URL? {
        switch self { case .message: return nil; case .logged(_, let url): return url; case .prepareAgain(_, let url): return url }
    }
    var needsNewCandidate: Bool { if case .prepareAgain = self { return true }; return false }
}
