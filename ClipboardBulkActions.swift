import AppKit

/// What the selection's actions do with the marked cards, alike in the drawer and the ⌥⌘\ window
/// (Al, 2026-10-12, in place of Delete all). Each container says only where it happens (the window
/// closes first, as its own ⌘C and ⌘O do) and how a delete asks (an alert, or a second press).
/// `marked` is always the list's marked cards, still shown, in the order shown.
enum ClipboardBulkActions {
    /// The marked cards' plain text, in the order shown, one card per line: what Copy as text and
    /// Paste as text carry. A card's text is what a plain-text paste of it inserts.
    static func text(_ marked: [ClipboardEntry]) -> String {
        marked.map(\.plainTextForPaste).joined(separator: "\n")
    }

    /// Why `action` cannot act on `marked` now, in words for its button's tooltip; nil when it can.
    /// The container adds its own reasons (the window's Paste as text needs an app to paste into).
    static func unavailable(_ action: ClipboardBrowserAction, _ marked: [ClipboardEntry]) -> String? {
        reason(action, marked) { marked.contains(where: \.hasPlainTextForPaste) }
    }

    /// Why each of `actions` cannot act on `marked` now, absent for those that can: what the selection
    /// panel shows on every change of the marks, the marked items' text read at most once for all of them.
    static func reasons(_ actions: [ClipboardBrowserAction], _ marked: [ClipboardEntry]) -> [ClipboardBrowserAction: String] {
        var known: Bool?
        func hasText() -> Bool {
            if let known { return known }
            let found = marked.contains(where: \.hasPlainTextForPaste)
            known = found
            return found
        }
        var reasons: [ClipboardBrowserAction: String] = [:]
        for action in actions { reasons[action] = reason(action, marked, hasText: hasText) }
        return reasons
    }

    private static func reason(_ action: ClipboardBrowserAction, _ marked: [ClipboardEntry], hasText: () -> Bool) -> String? {
        guard !marked.isEmpty else { return "Nothing is selected." }
        switch action {
        case .pickUp, .plainPaste: return hasText() ? nil : "None of the selected items has text."
        default: return nil
        }
    }

    /// Copy as text: the text goes on the clipboard as one plain copy, which the history takes as
    /// any copy, its newest entry. False when there was nothing to copy.
    @discardableResult
    static func copy(_ marked: [ClipboardEntry], to store: ClipboardStore) -> Bool {
        store.copyText(text(marked))
    }

    /// Open in Preview: each card, as ⌘O opens one. Every failure is said once, together, after
    /// the last card has answered.
    static func open(_ marked: [ClipboardEntry], with open: (ClipboardEntry, @escaping (Error?) -> Void) -> Void,
                     failed: @escaping (Error) -> Void) {
        var waiting = marked.count
        var failures: [ClipboardOpenFailures.Failure] = []
        for entry in marked {
            open(entry) { error in
                if let error { failures.append(.init(title: entry.title, reason: error.localizedDescription)) }
                waiting -= 1
                if waiting == 0, !failures.isEmpty { failed(ClipboardOpenFailures(failures: failures, of: marked.count)) }
            }
        }
    }
}

/// Selected items Preview could not open, said in one alert: which, and why.
struct ClipboardOpenFailures: LocalizedError {
    struct Failure: Equatable { let title: String; let reason: String }
    let failures: [Failure]
    /// How many were asked for.
    let of: Int
    var errorDescription: String? {
        let lead = failures.count == 1 && of == 1 ? "The item could not be opened in Preview."
            : "\(failures.count) of the \(of) selected items could not be opened in Preview."
        return ([lead] + failures.map { "\($0.title): \($0.reason)" }).joined(separator: "\n\n")
    }
}
