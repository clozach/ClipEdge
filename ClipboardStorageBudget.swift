import Foundation

/// How much history ClipEdge may keep (Al, 2026-10-16: *"Go by storage limit instead. Max at 1% of
/// total free space"*): 1% of the free space on the disk that holds the history, as macOS counts it
/// for important use (purgeable space included), measured as copies arrive.
struct ClipboardStorageBudget: Equatable {
    /// The disk's size and its free space, in bytes.
    let totalBytes: Int64
    let freeBytes: Int64

    static let share = 0.01
    /// Below this maximum (1 GB, as Finder counts), the count line shows the floppy warning.
    static let lowLimit: Int64 = 1_000_000_000
    /// A safety limit, however much room the budget leaves: past it a copy's save and a first
    /// opening start to take a noticeable part of a second (measured 2026-10-16: 20,000 rows open in
    /// 0.4 s, 50,000 in about 2 s). 1% of a typical disk's free space holds far fewer items.
    static let ceiling = 20_000

    var limit: Int64 { Int64(Double(max(0, freeBytes)) * Self.share) }
    var isLow: Bool { limit < Self.lowLimit }

    /// The disk holding `url` (or the nearest folder of it that exists), or nil when it cannot be read.
    static func measure(at url: URL) -> ClipboardStorageBudget? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 { probe.deleteLastPathComponent() }
        guard let values = try? probe.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = values.volumeTotalCapacity, let free = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return ClipboardStorageBudget(totalBytes: Int64(total), freeBytes: free)
    }
}

/// The budget and what the history holds now: what the floppy warning shows.
struct ClipboardStorageReport: Equatable {
    let budget: ClipboardStorageBudget
    /// Every format's bytes of every item kept.
    let usedBytes: Int64

    var isLow: Bool { budget.isLow }

    private static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    private static func percent(_ part: Int64, of whole: Int64) -> String {
        guard whole > 0 else { return "0%" }
        let share = Double(part) / Double(whole) * 100
        return share < 0.1 && part > 0 ? "under 0.1%" : String(format: share < 10 ? "%.1f%%" : "%.0f%%", share)
    }

    /// The disk in three parts, each a share of its size: what everything else uses, what ClipEdge's
    /// history uses, and what is free. They add up to 1.
    var shares: (used: Double, clipEdge: Double, free: Double) {
        let total = Double(max(1, budget.totalBytes))
        let free = min(1, max(0, Double(budget.freeBytes) / total))
        let clipEdge = min(1 - free, max(0, Double(usedBytes) / total))
        return (1 - free - clipEdge, clipEdge, free)
    }

    /// Each part's bytes, as the shares divide the disk.
    var bytes: (used: Int64, clipEdge: Int64, free: Int64) {
        let free = max(0, min(budget.totalBytes, budget.freeBytes))
        let clipEdge = max(0, min(budget.totalBytes - free, usedBytes))
        return (max(0, budget.totalBytes - free - clipEdge), clipEdge, free)
    }
    /// A part's size as its label shows it: whole GB, or whole MB under 1 GB (Finder's 1,000s).
    static func roundedSize(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb.rounded() >= 1 { return "\(Int(gb.rounded())) GB" }
        let mb = (Double(bytes) / 1_000_000).rounded()
        return bytes > 0 && mb < 1 ? "<1 MB" : "\(Int(mb)) MB"
    }
    /// A share as its label shows it: a whole percent, or finer under 1% ("0.08%").
    static func roundedPercent(_ share: Double) -> String {
        let percent = share * 100
        if percent <= 0 { return "0%" }
        if percent >= 1 { return "\(Int(percent.rounded()))%" }
        if percent < 0.01 { return "<0.01%" }
        return String(format: "%.1g%%", percent)
    }
    /// What follows a part's name on the bar: "358 GB | 17%".
    var usage: (used: String, clipEdge: String, free: String) {
        let b = bytes, s = shares
        func line(_ size: Int64, _ share: Double) -> String { "\(Self.roundedSize(size)) | \(Self.roundedPercent(share))" }
        return (line(b.used, s.used), line(b.clipEdge, s.clipEdge), line(b.free, s.free))
    }

    static let heading = "This Mac is low on space"
    static let advice = "Free up space, or add storage, so ClipEdge can keep more of your history."
    /// Every number behind the bar, for its tooltip and VoiceOver: the disk, what is used, what is
    /// free, and ClipEdge's history against the disk and against what it may keep.
    var summary: String {
        let total = budget.totalBytes, used = max(0, total - budget.freeBytes)
        return "Disk \(Self.size(total)): used \(Self.size(used)) (\(Self.percent(used, of: total))), "
            + "free \(Self.size(budget.freeBytes)) (\(Self.percent(budget.freeBytes, of: total))). "
            + "ClipEdge's history \(Self.size(usedBytes)) (\(Self.percent(usedBytes, of: total)) of the disk), "
            + "\(Self.percent(usedBytes, of: budget.limit)) of the \(Self.size(budget.limit)) it may keep, 1% of free space."
    }
}
