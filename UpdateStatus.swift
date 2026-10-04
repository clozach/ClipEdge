import Foundation

/// One row of the Updates menu, in display order.
enum UpdateMenuRow: Equatable {
    case status(String)
    case automatic(isOn: Bool)
    case check(enabled: Bool)
    case install(String)
    case whatsNew(String)
    case goBack(String)
    case getRelease
    case separator
}

/// Every sentence the updater shows, in one place.
enum UpdateStatus {
    struct Snapshot {
        var version: AppVersion
        var availability: UpdateAvailability
        var preference: UpdatePreference
        var phase: UpdatePhase
        var lastUpdate: UpdateRecord?
        var canGoBack: Bool
        var now: Date
    }

    static func when(_ date: Date, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = Calendar.current.isDate(date, inSameDayAs: now) ? .short : .none
        formatter.formattingContext = .middleOfSentence
        return formatter.string(from: date)
    }

    static func message(for failure: UpdateFailure) -> String {
        switch failure {
        case .offline(let detail): return detail
        case .feedUnreadable(let detail): return "GitHub's release list could not be read (\(detail))."
        case .noArchive: return "The newest release has no ClipEdge download attached."
        case .archiveTooLarge(let bytes): return "The download is an unexpected size (\(bytes / 1_048_576) MB), so it was not used."
        case .unsafeArchive(let entry): return "The download was not used: it holds something unexpected (\(entry))."
        case .notClipEdge(let detail): return "The download was not used: \(detail)."
        case .signatureMismatch(let detail): return "The download was not installed: \(detail)."
        case .versionMismatch(let expected, let found): return "The download was not installed: it is ClipEdge \(found), not the \(expected) the release names."
        case .historyNotSaved: return "ClipEdge could not save your clipboard history, so it did not restart."
        case .installFailed(let detail): return "The new version could not be put in place, so the one you have was kept (\(detail))."
        case .cannotGoBack(let detail): return "The earlier version could not be brought back (\(detail))."
        }
    }

    static func line(_ snapshot: Snapshot) -> String {
        let name = "ClipEdge \(snapshot.version)"
        switch snapshot.availability {
        case .blocked(.builtFromSource): return "\(name) was built on this Mac. It changes when it is rebuilt."
        case .blocked(.unsigned): return "\(name) can't update itself: this copy has no developer signature."
        case .blocked(.movedByMacOS): return "\(name) can't update itself from here. Move it to your Applications folder, then open it again."
        case .blocked(.folderLocked(let folder)): return "\(name) can't update itself: this account can't change \(folder)."
        case .available: break
        }
        let off = snapshot.preference == .automatic ? "" : " Automatic updates are off."
        switch snapshot.phase {
        case .checking: return "Looking for a newer version…"
        case .downloading(let release): return "Downloading ClipEdge \(release.version)…"
        case .ready(let staged):
            return snapshot.preference == .automatic
                ? "ClipEdge \(staged.release.version) is ready. It installs when ClipEdge is not in use."
                : "ClipEdge \(staged.release.version) is ready to install."
        case .resting(nil):
            switch snapshot.preference {
            case .unasked: return "\(name). Updates wait for your answer."
            case .automatic: return "\(name). The first check runs within a minute."
            case .manual: return "\(name).\(off)"
            }
        case .resting(.current(let date)):
            return "\(name) is the newest version. Checked \(when(date, now: snapshot.now)).\(off)"
        case .resting(.failed(let date, let failure)):
            let retry = snapshot.preference == .automatic ? " ClipEdge tries again within the hour." : ""
            return "\(name). The last check (\(when(date, now: snapshot.now))) did not finish: \(message(for: failure))\(retry)"
        }
    }

    /// A short note after "Updates" in the menu, shown only when something is worth a glance.
    static func badge(_ snapshot: Snapshot) -> String? {
        guard case .available = snapshot.availability else { return nil }
        if case .ready(let staged) = snapshot.phase { return "\(staged.release.version) ready" }
        if let record = currentRecord(snapshot), snapshot.now.timeIntervalSince(record.date) < 7 * 24 * 60 * 60 {
            return "updated to \(record.to)"
        }
        return nil
    }

    static func rows(_ snapshot: Snapshot) -> [UpdateMenuRow] {
        var rows: [UpdateMenuRow] = [.status(line(snapshot))]
        switch snapshot.availability {
        case .available:
            rows += [.separator, .automatic(isOn: snapshot.preference == .automatic)]
            switch snapshot.phase {
            case .ready(let staged): rows.append(.install("Install ClipEdge \(staged.release.version) and Reopen"))
            case .resting: rows.append(.check(enabled: true))
            case .checking, .downloading: rows.append(.check(enabled: false))
            }
        case .blocked(.builtFromSource), .blocked(.unsigned):
            rows += [.separator, .getRelease]
        case .blocked:
            break
        }
        if let record = currentRecord(snapshot) {
            var extra: [UpdateMenuRow] = []
            if record.page != nil { extra.append(.whatsNew("What's New in ClipEdge \(record.to)")) }
            if snapshot.canGoBack { extra.append(.goBack("Go Back to ClipEdge \(record.from)…")) }
            if !extra.isEmpty { rows += [.separator] + extra }
        }
        return rows
    }

    private static func currentRecord(_ snapshot: Snapshot) -> UpdateRecord? {
        guard let record = snapshot.lastUpdate, AppVersion(record.to) == snapshot.version else { return nil }
        return record
    }
}
