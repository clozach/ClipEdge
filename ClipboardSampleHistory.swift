import AppKit

/// Which history ClipEdge shows and records into: the person's own, or the sample kept for
/// decks, stills and videos. One at a time; switching saves one and loads the other, and the
/// choice survives relaunch.
enum ClipboardHistorySource: String {
    case real, sample

    static let defaultsKey = "ClipEdgeHistorySource"

    static var directory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ClipEdge", isDirectory: true)
    }

    /// The real history keeps its original place, so updates and old copies still find it.
    func url(in directory: URL? = Self.directory) -> URL? {
        switch self {
        case .real: return directory?.appendingPathComponent("History.plist", isDirectory: false)
        case .sample: return directory?.appendingPathComponent("Sample", isDirectory: true)
            .appendingPathComponent("History.plist", isDirectory: false)
        }
    }

    var other: Self { self == .real ? .sample : .real }

    static func saved(in defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .real
    }

    func save(in defaults: UserDefaults = .standard) { defaults.set(rawValue, forKey: Self.defaultsKey) }
}

/// The sample history: seeded once from the real one, then changed only on purpose (deleting
/// in the drawer or window, copying while it is shown, adding the newest real item, or the
/// --sample-history command). It holds real clipboard content, so it lives beside the real
/// history and never in the source tree.
enum ClipboardSampleHistory {
    /// How many items a sample history keeps: a mock is curated, so a count, not the real
    /// history's storage budget.
    static let capacity = 50
    /// What a seed takes from the real history, newest first, in this order of kinds.
    static let seedLimits: [(kind: String, count: Int)] = [("prose", 6), ("figma", 4), ("link", 4), ("image", 4)]

    /// A sentence or more of words: no single URL, color or token.
    static func isProse(_ entry: ClipboardEntry) -> Bool {
        switch entry.kind {
        case .text, .html: break
        default: return false
        }
        guard entry.swatchColor == nil, let text = entry.plainText?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.count <= 2_000 else { return false }
        let words = text.split(whereSeparator: \.isWhitespace).filter { $0.contains(where: \.isLetter) }
        return words.count >= 6
    }

    static func seedKind(_ entry: ClipboardEntry) -> String? {
        switch entry.kind {
        case .figma: return "figma"
        case .link: return "link"
        case .image: return "image"
        default: return isProse(entry) ? "prose" : nil
        }
    }

    /// Up to six prose copies, four Figma copies, four links and four pictures, keeping the real
    /// history's order. Files, app data and everything else stay out: paths and app formats are
    /// the likeliest to be private or to need their app.
    static func seed(from entries: [ClipboardEntry]) -> [ClipboardEntry] {
        var taken: [String: Int] = [:]
        return entries.filter { entry in
            guard let kind = seedKind(entry), let limit = seedLimits.first(where: { $0.kind == kind })?.count,
                  taken[kind, default: 0] < limit else { return false }
            taken[kind, default: 0] += 1
            return true
        }
    }

    /// The record first; an equal copy already there moves to the front instead of repeating.
    static func adding(_ record: ClipboardHistoryFile.Record, to records: [ClipboardHistoryFile.Record]) -> [ClipboardHistoryFile.Record] {
        Array(([record] + records.filter { $0.fingerprint != record.fingerprint }).prefix(Self.capacity))
    }

    /// One-based positions, as `list` prints them. Nil when either is out of range.
    static func moving(_ records: [ClipboardHistoryFile.Record], from: Int, to: Int) -> [ClipboardHistoryFile.Record]? {
        guard records.indices.contains(from - 1), records.indices.contains(to - 1) else { return nil }
        var moved = records
        moved.insert(moved.remove(at: from - 1), at: to - 1)
        return moved
    }

    static func removing(_ records: [ClipboardHistoryFile.Record], at position: Int) -> [ClipboardHistoryFile.Record]? {
        guard records.indices.contains(position - 1) else { return nil }
        var kept = records
        kept.remove(at: position - 1)
        return kept
    }

    /// A short label for a menu: the title, cut at a word near 32 characters.
    static func menuLabel(_ title: String) -> String {
        let flat = title.split(whereSeparator: \.isNewline).first.map(String.init) ?? title
        guard flat.count > 32 else { return flat }
        let cut = flat.prefix(32)
        let word = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return word.trimmingCharacters(in: .whitespaces) + "…"
    }
}
