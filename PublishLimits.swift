import Foundation

/// What the release helper may send and the app accepts. Both compile this one file, so the helper
/// refuses notes the app would reject before it spends minutes testing and building (2026-10-13:
/// 19,562 characters of notes met the app's old 12,000-character cap only after a full preparation).
enum PublishLimits {
    /// GitHub's limit on a release's description.
    static let releaseNotes = 125_000
    /// The notes in UTF-8, kept well inside `reply` with room for every other field.
    static let releaseNoteBytes = 400_000
    /// The largest reply the app reads from the helper.
    static let reply = 524_288

    /// "19,562" for messages people read.
    static func counted(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: number)) ?? String(number)
    }
}
