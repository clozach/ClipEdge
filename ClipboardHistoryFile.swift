import AppKit
import CryptoKit

/// A history as saved on disk, newest first. The store reads and writes it; so do the sample
/// history and its command. A history is named by its old file's URL (`…/History.plist`) and kept
/// beside it in a store folder (`…/History.store/`, 2026-10-16), so it can grow to gigabytes:
///
/// - `Index.plist`: every item's fingerprint, copy time and the types of its formats, small enough
///   to rewrite on every change;
/// - `Items/<fingerprint>/<payload>-<value>`: each format's bytes in its own file, written once
///   (into a temporary folder, then renamed into place); a large one (64 KB or more) is read back
///   mapped, so its bytes stay on disk until something reads them, a small one is simply read (a
///   mapping takes at least a 16 KB page, more than a short text needs);
/// - `Text/<fingerprint>.txt`: the text read from a picture, so it is read once, not at every launch.
///
/// A history saved before the store folder existed (one binary property list holding every byte)
/// is read from its old file, which is left as it was; the first save writes the store.
enum ClipboardHistoryFile {
    struct Record {
        let fingerprint: String
        let capturedAt: Date
        let payloads: [ClipboardPayload]
        /// Read from the store, whose folders are named by the fingerprint of what they hold: no
        /// need to hash every byte again at launch. A record from the old file, or made in memory,
        /// is checked.
        var fromStore = false
        init(fingerprint: String, capturedAt: Date, payloads: [ClipboardPayload], fromStore: Bool = false) {
            self.fingerprint = fingerprint
            self.capturedAt = capturedAt
            self.payloads = payloads
            self.fromStore = fromStore
        }
    }

    enum Failure: Error { case unsupportedVersion }

    /// The store folder for a history named by `url`.
    static func storeFolder(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("store")
    }
    /// What holds a history on disk, of those that exist: its old file and its store folder.
    static func parts(of url: URL) -> [URL] {
        [url, storeFolder(for: url)].filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    static func exists(_ url: URL) -> Bool { !parts(of: url).isEmpty }

    private static func index(_ store: URL) -> URL { store.appendingPathComponent("Index.plist") }
    private static func items(_ store: URL) -> URL { store.appendingPathComponent("Items", isDirectory: true) }
    private static func texts(_ store: URL) -> URL { store.appendingPathComponent("Text", isDirectory: true) }
    private static func valueName(_ payload: Int, _ value: Int) -> String { "\(payload)-\(value)" }
    /// From this size up, a format's bytes are mapped rather than read.
    static let mappedFrom = 65_536

    /// The saved records in order, or nil when there is no history. Throws when it is unreadable.
    /// An item whose files are missing or the wrong size is left out.
    static func read(_ url: URL) throws -> [Record]? {
        let store = storeFolder(for: url)
        if FileManager.default.fileExists(atPath: index(store).path) {
            let data = try Data(contentsOf: index(store))
            let saved = try PropertyListDecoder().decode(Index.self, from: data)
            guard saved.version == 2 else { throw Failure.unsupportedVersion }
            return saved.entries.compactMap { entry in
                let folder = items(store).appendingPathComponent(entry.fingerprint, isDirectory: true)
                var payloads: [ClipboardPayload] = []
                for (p, payload) in entry.payloads.enumerated() {
                    var values: [(type: NSPasteboard.PasteboardType, data: Data)] = []
                    for (v, value) in payload.enumerated() {
                        let options: Data.ReadingOptions = value.bytes >= mappedFrom ? .alwaysMapped : []
                        guard let bytes = try? Data(contentsOf: folder.appendingPathComponent(valueName(p, v)), options: options),
                              bytes.count == value.bytes else { return nil }
                        values.append((NSPasteboard.PasteboardType(value.type), bytes))
                    }
                    payloads.append(ClipboardPayload(values: values))
                }
                return Record(fingerprint: entry.fingerprint, capturedAt: entry.capturedAt, payloads: payloads, fromStore: true)
            }
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let archive = try PropertyListDecoder().decode(Archive.self, from: data)
        guard archive.version == 1 else { throw Failure.unsupportedVersion }
        return archive.entries.map { saved in
            Record(fingerprint: saved.fingerprint, capturedAt: saved.capturedAt, payloads: saved.payloads.map { payload in
                ClipboardPayload(values: payload.values.map { (NSPasteboard.PasteboardType($0.type), $0.data) })
            })
        }
    }

    /// Saves `records` as the whole history: each item not yet on disk gets its folder, the index is
    /// rewritten, and any item (and its text) no longer listed is removed. False when it cannot.
    @discardableResult
    static func write(_ records: [Record], to url: URL) -> Bool {
        let store = storeFolder(for: url), fm = FileManager.default
        // A fingerprint names a folder: only letters, digits and hyphens may (a SHA-256 is hex).
        let records = records.filter { !$0.fingerprint.isEmpty && $0.fingerprint.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }
        do {
            for folder in [url.deletingLastPathComponent(), store, items(store), texts(store)] {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            }
            for record in records {
                let folder = items(store).appendingPathComponent(record.fingerprint, isDirectory: true)
                guard !fm.fileExists(atPath: folder.path) else { continue }
                let pending = items(store).appendingPathComponent(".\(record.fingerprint)-\(UUID().uuidString)", isDirectory: true)
                try fm.createDirectory(at: pending, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                for (p, payload) in record.payloads.enumerated() {
                    for (v, value) in payload.values.enumerated() {
                        let file = pending.appendingPathComponent(valueName(p, v))
                        try value.data.write(to: file)
                        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                    }
                }
                do { try fm.moveItem(at: pending, to: folder) } catch {
                    // Another save wrote the same item first: its folder is as good as this one.
                    try? fm.removeItem(at: pending)
                    guard fm.fileExists(atPath: folder.path) else { throw error }
                }
            }
            let saved = Index(version: 2, entries: records.map { record in
                IndexEntry(fingerprint: record.fingerprint, capturedAt: record.capturedAt, payloads: record.payloads.map { payload in
                    payload.values.map { IndexValue(type: $0.type.rawValue, bytes: $0.data.count) }
                })
            })
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(saved).write(to: index(store), options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: index(store).path)
            let kept = Set(records.map(\.fingerprint))
            for folder in (try? fm.contentsOfDirectory(at: items(store), includingPropertiesForKeys: nil)) ?? []
            where !kept.contains(folder.lastPathComponent) && !folder.lastPathComponent.hasPrefix(".") {
                try? fm.removeItem(at: folder)
            }
            for file in (try? fm.contentsOfDirectory(at: texts(store), includingPropertiesForKeys: nil)) ?? []
            where !kept.contains(file.deletingPathExtension().lastPathComponent) {
                try? fm.removeItem(at: file)
            }
            return true
        } catch {
            return false
        }
    }

    /// Moves an unreadable history aside, its index or its old file, so the next launch starts empty
    /// rather than failing again; nothing is deleted.
    static func quarantine(_ url: URL) {
        let suffix = Int(Date().timeIntervalSince1970)
        let store = storeFolder(for: url)
        let unreadable = FileManager.default.fileExists(atPath: index(store).path) ? index(store) : url
        let aside = unreadable.deletingLastPathComponent()
            .appendingPathComponent("\(unreadable.deletingPathExtension().lastPathComponent)-corrupt-\(suffix).plist")
        try? FileManager.default.moveItem(at: unreadable, to: aside)
    }

    /// The text read from an item's picture, if it was saved.
    static func savedText(of fingerprint: String, in url: URL) -> String? {
        try? String(contentsOf: texts(storeFolder(for: url)).appendingPathComponent("\(fingerprint).txt"), encoding: .utf8)
    }
    /// Keeps the text read from an item's picture, for the next launch. Only for an item on disk.
    static func saveText(_ text: String, of fingerprint: String, in url: URL) {
        let store = storeFolder(for: url)
        guard FileManager.default.fileExists(atPath: items(store).appendingPathComponent(fingerprint).path) else { return }
        let file = texts(store).appendingPathComponent("\(fingerprint).txt")
        guard (try? text.write(to: file, atomically: true, encoding: .utf8)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func record(_ entry: ClipboardEntry) -> Record {
        Record(fingerprint: entry.fingerprint, capturedAt: entry.capturedAt, payloads: entry.payloads)
    }

    /// A new entry for a record, summarized from its formats as a fresh copy would be.
    static func entry(_ record: Record) -> ClipboardEntry {
        let preview = ClipboardSummary.make(from: record.payloads)
        return ClipboardEntry(fingerprint: record.fingerprint, capturedAt: record.capturedAt, payloads: record.payloads,
                              title: preview.title, detail: preview.detail, kind: preview.kind, thumbnail: preview.thumbnail)
    }

    static func fingerprint(for payloads: [ClipboardPayload]) -> String {
        var digestMaterial = Data()
        for payload in payloads {
            for value in payload.values {
                digestMaterial.append(contentsOf: value.type.rawValue.utf8)
                digestMaterial.append(0)
                digestMaterial.append(value.data)
                digestMaterial.append(0)
            }
        }
        return SHA256.hash(data: digestMaterial).map { String(format: "%02x", $0) }.joined()
    }

    // The store's index (version 2).
    private struct Index: Codable {
        let version: Int
        let entries: [IndexEntry]
    }
    private struct IndexEntry: Codable {
        let fingerprint: String
        let capturedAt: Date
        /// Each payload's formats, in order: its type and how many bytes its file holds.
        let payloads: [[IndexValue]]
    }
    private struct IndexValue: Codable {
        let type: String
        let bytes: Int
    }

    // The old single file (version 1), read once to move a history into its store.
    private struct Archive: Codable {
        let version: Int
        let entries: [SavedEntry]
    }
    private struct SavedEntry: Codable {
        let fingerprint: String
        let capturedAt: Date
        let payloads: [SavedPayload]
    }
    private struct SavedPayload: Codable {
        let values: [SavedValue]
    }
    private struct SavedValue: Codable {
        let type: String
        let data: Data
    }
}
