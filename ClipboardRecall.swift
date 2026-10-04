import Foundation

/// The entry last used from the drawer or the ⌥⌘\ window, with the tab and
/// search that found it, so either can reopen there for a few minutes.
struct ClipboardRecall: Equatable {
    let entryID: UUID
    let title: String
    let tab: ClipboardBrowserTab
    /// Empty when the entry was used without searching.
    let query: String
    let usedAt: Date

    /// What the search reopens on: the search that found the entry, else its title.
    var search: String { query.isEmpty ? title : query }

    /// Still offered back at `now`; 0 minutes turns recall off.
    func isFresh(at now: Date, minutes: Int) -> Bool {
        let elapsed = now.timeIntervalSince(usedAt)
        return minutes > 0 && elapsed >= 0 && elapsed < TimeInterval(minutes * 60)
    }
}

/// One memory for both surfaces: each records the entry it uses and asks it
/// when opening. Held in memory only, so quitting forgets it.
final class ClipboardRecallMemory {
    private(set) var last: ClipboardRecall?
    private let minutes: () -> Int
    let now: () -> Date

    init(minutes: @escaping () -> Int, now: @escaping () -> Date = Date.init) {
        self.minutes = minutes
        self.now = now
    }

    func remember(_ entry: ClipboardEntry, tab: ClipboardBrowserTab, query: String) {
        last = ClipboardRecall(entryID: entry.id, title: entry.title, tab: tab,
                               query: query.trimmingCharacters(in: .whitespaces), usedAt: now())
    }

    /// The recall to open on, if fresh. A surface that kept its own search
    /// passes when it last closed, so an older use never replaces it.
    func recall(usedAfter closed: Date? = nil) -> ClipboardRecall? {
        guard let last, last.isFresh(at: now(), minutes: minutes()) else { return nil }
        if let closed, last.usedAt <= closed { return nil }
        return last
    }
}
