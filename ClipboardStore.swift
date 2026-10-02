import AppKit
import CryptoKit
import UniformTypeIdentifiers

final class ClipboardStore {
    private(set) var entries: [ClipboardEntry] = []
    var onChange: (() -> Void)?
    var onStagingChange: ((ClipboardStagingChange) -> Void)?
    var onPasteCommitted: (() -> Void)?

    private let pasteboard: NSPasteboard
    private let persistenceURL: URL?
    private let persistenceQueue = DispatchQueue(label: "local.codex.ClipEdge.persistence", qos: .utility)
    private let maximumEntries = 50
    private let maximumPayloadBytes = 32 * 1_024 * 1_024
    private var timer: Timer?
    private var lastChangeCount: Int
    private var pendingPersistenceWorkItem: DispatchWorkItem?
    private var currentClipboardEntryID: UUID?
    private enum HeldItem {
        case pickedUp(ClipboardEntry, original: ClipboardRestorePoint)
        case previewed(ClipboardEntry, original: ClipboardRestorePoint)
        case copied(ClipboardEntry)
        var entry: ClipboardEntry {
            switch self { case .pickedUp(let e, _), .previewed(let e, _), .copied(let e): return e }
        }
        var restorePoint: ClipboardRestorePoint? {
            switch self { case .pickedUp(_, let point), .previewed(_, let point): return point; case .copied: return nil }
        }
    }
    private var holdingRevision: UInt64 = 0
    private var heldItem: HeldItem? { didSet { holdingRevision &+= 1 } }
    private var stagedEntry: ClipboardEntry? { heldItem?.entry }
    private var cycle = ClipboardCycle()
    var onExternalCopy: (() -> Void)?
    var onRemove: ((ClipboardEntry) -> Void)?
    private let searchIndexer = ClipboardSearchIndexer()

    var stagedEntryID: UUID? { stagedEntry?.id }
    var liftedEntryID: UUID? {
        if case .pickedUp(let entry, _) = heldItem { return entry.id }
        return nil
    }

    convenience init() {
        self.init(pasteboard: .general, persistenceURL: Self.defaultPersistenceURL())
    }

    init(pasteboard: NSPasteboard, persistenceURL: URL? = nil) {
        self.pasteboard = pasteboard
        self.persistenceURL = persistenceURL
        lastChangeCount = pasteboard.changeCount
    }

    func start() {
        loadPersistedHistory()
        captureCurrentPasteboard(attach: false)
        lastChangeCount = pasteboard.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            self?.checkForChanges()
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        _ = prepareForTermination()
    }

    @discardableResult
    func prepareForTermination() -> Bool {
        checkForChanges()
        resolveStagingForShutdown()
        return saveNow()
    }

    @discardableResult
    func saveNow() -> Bool {
        checkForChanges()
        pendingPersistenceWorkItem?.cancel()
        pendingPersistenceWorkItem = nil
        guard let persistenceURL else { return true }
        let archive = makePersistedHistory()
        var didSave = false
        persistenceQueue.sync {
            didSave = Self.write(archive, to: persistenceURL)
        }
        return didSave
    }

    func clear() {
        checkForChanges()
        let removed = entries
        entries = []
        heldItem = nil
        cycle.reset()
        if currentClipboardEntryID != nil {
            pasteboard.clearContents()
            lastChangeCount = pasteboard.changeCount
        }
        currentClipboardEntryID = nil
        onStagingChange?(.invalidated)
        removed.forEach { onRemove?($0) }
        historyDidChange()
        _ = saveNow()
    }

    func selectForPaste(_ entry: ClipboardEntry) {
        checkForChanges()
        resetCycle()
        guard entries.contains(where: { $0.id == entry.id }) else { return }
        if liftedEntryID == entry.id { cancelStaging(); return }
        _ = stage(entry, preview: false)
    }

    func resetCycle() { cycle.reset() }

    @discardableResult
    func quickLookNext() -> ClipboardEntry? {
        checkForChanges()
        guard let entry = cycle.next(in: entries), stage(entry) else { return nil }
        return entry
    }

    var carouselPosition: (index: Int, count: Int)? { cycle.position }

    @discardableResult
    func moveCarousel(_ direction: Int, among candidates: [ClipboardEntry]? = nil) -> ClipboardEntry? {
        checkForChanges()
        let available = carouselEntries(among: candidates)
        if candidates != nil {
            if let id = stagedEntryID { _ = cycle.select(id, in: available) }
            else { cycle.reset() }
        }
        guard let entry = cycle.move(direction, in: available), stage(entry) else { return nil }
        return entry
    }

    func previewInCarousel(_ entry: ClipboardEntry, among candidates: [ClipboardEntry]? = nil) {
        checkForChanges()
        guard let selected = cycle.select(entry.id, in: carouselEntries(among: candidates)) else { return }
        _ = stage(selected)
    }

    private func carouselEntries(among candidates: [ClipboardEntry]?) -> [ClipboardEntry] {
        guard let candidates else { return entries }
        let retained = Set(entries.map(\.id))
        return candidates.filter { retained.contains($0.id) }
    }

    func cancelStaging() {
        let cancelRevision = holdingRevision
        checkForChanges()
        guard holdingRevision == cancelRevision else { return }
        resetCycle()
        guard let entry = stagedEntry else { return }
        let cancelled = heldItem
        heldItem = nil
        if let point = cancelled?.restorePoint, point.restore(to: pasteboard) {
            lastChangeCount = pasteboard.changeCount
            currentClipboardEntryID = point.historyID
        }
        onStagingChange?(.cancelled(entry))
    }

    /// A non-editable/failed click ends the hold, but is not a history use.
    /// Keep the selected payload available for a subsequent explicit paste.
    func dropStaging() {
        let dropRevision = holdingRevision
        checkForChanges()
        guard heldItem != nil, holdingRevision == dropRevision else { return }
        resetCycle()
        heldItem = nil
        onStagingChange?(.invalidated)
    }

    func commitStagedPaste() {
        let pastedRevision = holdingRevision
        checkForChanges()
        // An external copy can land during the dismissal delay, before our
        // regular poll sees it. Leave that newly attached payload in hand.
        guard let entry = stagedEntry, holdingRevision == pastedRevision else { return }
        resetCycle()
        heldItem = nil
        promote(entry)
        onStagingChange?(.pasted(entry))
        onPasteCommitted?()
    }

    @discardableResult
    func remove(_ entry: ClipboardEntry) -> Bool {
        checkForChanges()
        resetCycle()
        guard entries.contains(where: { $0.id == entry.id }) else { return true }
        entries.removeAll { $0.id == entry.id }
        // Deleting a history item also retires any temporary undo copy of it.
        // Cancelling another pickup must not resurrect that deleted payload.
        if heldItem?.restorePoint?.historyID == entry.id {
            let empty = ClipboardRestorePoint(payloads: [], historyID: nil)
            switch heldItem {
            case .pickedUp(let held, _): heldItem = .pickedUp(held, original: empty)
            case .previewed(let held, _): heldItem = .previewed(held, original: empty)
            default: break
            }
        }
        if currentClipboardEntryID == entry.id {
            pasteboard.clearContents()
            lastChangeCount = pasteboard.changeCount
            currentClipboardEntryID = nil
        }
        if stagedEntry?.id == entry.id {
            heldItem = nil
            onStagingChange?(.invalidated)
        }
        onRemove?(entry)
        historyDidChange()
        return saveNow()
    }

    private func promote(_ entry: ClipboardEntry) {
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        currentClipboardEntryID = entry.id
        historyDidChange()
    }

    private func checkForChanges() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        resetCycle()
        onExternalCopy?()
        if stagedEntry != nil {
            heldItem = nil
            onStagingChange?(.invalidated)
        }
        captureCurrentPasteboard()
    }

    private func captureCurrentPasteboard(attach: Bool = true) {
        currentClipboardEntryID = nil
        guard let pasteboardItems = pasteboard.pasteboardItems, !pasteboardItems.isEmpty else { return }

        // Respect the conventions used by password managers and ephemeral clipboard providers.
        let excludedTypes = [
            NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
            NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
            NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
        ]
        guard !pasteboardItems.contains(where: { item in
            excludedTypes.contains(where: { item.types.contains($0) })
        }) else { return }

        var byteCount = 0
        var payloads: [ClipboardPayload] = []
        for item in pasteboardItems {
            var values: [(type: NSPasteboard.PasteboardType, data: Data)] = []
            for type in item.types.sorted(by: { $0.rawValue < $1.rawValue }) {
                guard let data = item.data(forType: type) else { continue }
                byteCount += data.count
                guard byteCount <= maximumPayloadBytes else { return }
                values.append((type, data))
            }
            if !values.isEmpty {
                payloads.append(ClipboardPayload(values: values))
            }
        }

        guard !payloads.isEmpty else { return }
        let digest = Self.fingerprint(for: payloads)

        if let existingIndex = entries.firstIndex(where: { $0.fingerprint == digest }) {
            let existing = entries.remove(at: existingIndex)
            if attach { existing.capturedAt = Date() }
            entries.insert(existing, at: 0)
            currentClipboardEntryID = existing.id
            if attach { attachToCursor(existing) }
            historyDidChange()
            return
        }

        let preview = ClipboardSummary.make(from: payloads)
        let entry = ClipboardEntry(
            fingerprint: digest,
            capturedAt: Date(),
            payloads: payloads,
            title: preview.title,
            detail: preview.detail,
            kind: preview.kind,
            thumbnail: preview.thumbnail
        )
        entries.insert(entry, at: 0)
        currentClipboardEntryID = entry.id
        indexText(entry)
        if attach { attachToCursor(entry) }
        if entries.count > maximumEntries {
            let evicted = Array(entries.suffix(entries.count - maximumEntries))
            entries.removeLast(entries.count - maximumEntries)
            evicted.forEach { onRemove?($0) }
        }
        historyDidChange()
    }

    @discardableResult
    private func stage(_ entry: ClipboardEntry, preview: Bool = true) -> Bool {
        let original: ClipboardRestorePoint
        switch heldItem {
        case .pickedUp(_, let point), .previewed(_, let point): original = point
        default:
            guard let point = ClipboardRestorePoint.capture(pasteboard, historyID: currentClipboardEntryID, limit: maximumPayloadBytes) else { return false }
            original = point
        }
        guard writeMaterializedToPasteboard(entry) else { return false }
        currentClipboardEntryID = entry.id
        heldItem = preview ? .previewed(entry, original: original) : .pickedUp(entry, original: original)
        onStagingChange?(.pickedUp(entry))
        return true
    }

    private func attachToCursor(_ entry: ClipboardEntry) {
        heldItem = .copied(entry)
        onStagingChange?(.pickedUp(entry))
    }

    private func indexText(_ entry: ClipboardEntry) {
        guard entry.isImage || !entry.fileURLs.isEmpty else { return }
        entry.searchIndex = .pending
        searchIndexer.index(entry) { [weak self, weak entry] result in
            guard let self, let entry, self.entries.contains(where: { $0.id == entry.id }) else { return }
            entry.searchIndex = result
            self.onChange?()
        }
    }

    @discardableResult
    private func writeMaterializedToPasteboard(_ entry: ClipboardEntry) -> Bool {
        let items = entry.payloads.compactMap { payload -> NSPasteboardItem? in
            let item = NSPasteboardItem()
            var wroteValue = false
            for value in payload.values {
                wroteValue = item.setData(value.data, forType: value.type) || wroteValue
            }
            return wroteValue ? item : nil
        }

        guard !items.isEmpty else { return false }
        pasteboard.clearContents()
        let didWrite = pasteboard.writeObjects(items)
        lastChangeCount = pasteboard.changeCount
        return didWrite
    }

    private func historyDidChange() {
        onChange?()
        schedulePersistence()
    }

    private func schedulePersistence() {
        guard let persistenceURL else { return }
        let archive = makePersistedHistory()
        pendingPersistenceWorkItem?.cancel()

        let workItem = DispatchWorkItem {
            Self.write(archive, to: persistenceURL)
        }
        pendingPersistenceWorkItem = workItem
        persistenceQueue.async(execute: workItem)
    }

    private func makePersistedHistory() -> PersistedHistory {
        PersistedHistory(
            version: 1,
            entries: entries.map { entry in
                PersistedEntry(
                    fingerprint: entry.fingerprint,
                    capturedAt: entry.capturedAt,
                    payloads: entry.payloads.map { payload in
                        PersistedPayload(values: payload.values.map { value in
                            PersistedValue(type: value.type.rawValue, data: value.data)
                        })
                    }
                )
            }
        )
    }

    private func loadPersistedHistory() {
        guard let persistenceURL, FileManager.default.fileExists(atPath: persistenceURL.path) else { return }

        do {
            let data = try Data(contentsOf: persistenceURL, options: .mappedIfSafe)
            let archive = try PropertyListDecoder().decode(PersistedHistory.self, from: data)
            guard archive.version == 1 else { throw PersistenceError.unsupportedVersion }

            var loadedEntries: [ClipboardEntry] = []
            var seenFingerprints = Set<String>()
            for persisted in archive.entries.prefix(maximumEntries) {
                let payloads = persisted.payloads.map { payload in
                    ClipboardPayload(values: payload.values.map { value in
                        (NSPasteboard.PasteboardType(value.type), value.data)
                    })
                }
                guard isValidForPersistence(payloads) else { continue }

                let fingerprint = Self.fingerprint(for: payloads)
                guard fingerprint == persisted.fingerprint,
                      seenFingerprints.insert(fingerprint).inserted else { continue }

                let preview = ClipboardSummary.make(from: payloads)
                loadedEntries.append(ClipboardEntry(
                    fingerprint: fingerprint,
                    capturedAt: persisted.capturedAt,
                    payloads: payloads,
                    title: preview.title,
                    detail: preview.detail,
                    kind: preview.kind,
                    thumbnail: preview.thumbnail
                ))
            }

            entries = loadedEntries
            entries.forEach(indexText)
            onChange?()
        } catch {
            quarantineUnreadableHistory(at: persistenceURL)
        }
    }

    private func isValidForPersistence(_ payloads: [ClipboardPayload]) -> Bool {
        guard !payloads.isEmpty else { return false }
        let excludedTypes = Set([
            "org.nspasteboard.ConcealedType",
            "org.nspasteboard.TransientType",
            "org.nspasteboard.AutoGeneratedType"
        ])

        var byteCount = 0
        for payload in payloads {
            guard !payload.values.isEmpty else { return false }
            for value in payload.values {
                guard !value.type.rawValue.isEmpty,
                      !excludedTypes.contains(value.type.rawValue),
                      value.data.count <= maximumPayloadBytes - byteCount else { return false }
                byteCount += value.data.count
            }
        }
        return true
    }

    private func resolveStagingForShutdown() {
        cancelStaging()
    }

    private func quarantineUnreadableHistory(at url: URL) {
        let suffix = Int(Date().timeIntervalSince1970)
        let quarantineURL = url.deletingLastPathComponent()
            .appendingPathComponent("History-corrupt-\(suffix).plist")
        try? FileManager.default.moveItem(at: url, to: quarantineURL)
    }

    private static func defaultPersistenceURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ClipEdge", isDirectory: true)
            .appendingPathComponent("History.plist", isDirectory: false)
    }

    @discardableResult
    private static func write(_ archive: PersistedHistory, to url: URL) -> Bool {
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(archive)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }

    private static func fingerprint(for payloads: [ClipboardPayload]) -> String {
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


}

private enum PersistenceError: Error {
    case unsupportedVersion
}

private struct PersistedHistory: Codable {
    let version: Int
    let entries: [PersistedEntry]
}

private struct PersistedEntry: Codable {
    let fingerprint: String
    let capturedAt: Date
    let payloads: [PersistedPayload]
}

private struct PersistedPayload: Codable {
    let values: [PersistedValue]
}

private struct PersistedValue: Codable {
    let type: String
    let data: Data
}
