import AppKit
import UniformTypeIdentifiers

final class ClipboardStore {
    /// Posted with every `onChange`, for surfaces other than the drawer.
    static let didChange = Notification.Name("ClipEdgeHistoryDidChange")
    private(set) var entries: [ClipboardEntry] = []
    var onChange: (() -> Void)?
    var onStagingChange: ((ClipboardStagingChange) -> Void)?
    var onPasteCommitted: (() -> Void)?

    private let pasteboard: NSPasteboard
    private var persistenceURL: URL?
    private let persistenceQueue = DispatchQueue(label: "local.codex.ClipEdge.persistence", qos: .utility)
    /// What the history may hold: 1% of the free space on its disk (Al, 2026-10-16), read at most
    /// once a minute; `measureStorage` reads it (tests give their own).
    var measureStorage: () -> ClipboardStorageBudget? = { nil }
    private var budget: ClipboardStorageBudget?
    /// The most items kept, whatever the budget (`ClipboardStorageBudget.ceiling`; tests lower it).
    var itemCeiling = ClipboardStorageBudget.ceiling
    private var budgetMeasuredAt: Date?
    /// Every format's bytes of every item kept.
    var usedBytes: Int64 { entries.reduce(0) { $0 + $1.byteCount } }
    /// The budget and the bytes kept, for the floppy warning; nil when the disk cannot be read.
    var storageReport: ClipboardStorageReport? { currentBudget().map { ClipboardStorageReport(budget: $0, usedBytes: usedBytes) } }
    private let maximumPayloadBytes = 32 * 1_024 * 1_024
    private var timer: Timer?
    private var lastChangeCount: Int
    private var pendingPersistenceWorkItem: DispatchWorkItem?
    private var currentClipboardEntryID: UUID?
    private enum HeldItem {
        case pickedUp(ClipboardEntry, original: ClipboardRestorePoint, from: ClipboardMagnetSource)
        case previewed(ClipboardEntry, original: ClipboardRestorePoint)
        case copied(ClipboardEntry)
        var entry: ClipboardEntry {
            switch self { case .pickedUp(let e, _, _), .previewed(let e, _), .copied(let e): return e }
        }
        var restorePoint: ClipboardRestorePoint? {
            switch self { case .pickedUp(_, let point, _), .previewed(_, let point): return point; case .copied: return nil }
        }
    }
    private var holdingRevision: UInt64 = 0
    private var heldItem: HeldItem? { didSet { holdingRevision &+= 1 } }
    private var stagedEntry: ClipboardEntry? { heldItem?.entry }
    private var cycle = ClipboardCycle()
    var onExternalCopy: (() -> Void)?
    /// Settings › Cursor magnets › On copy: when false, a copy joins the history without riding the cursor.
    var attachesCopiesToCursor: () -> Bool = { true }
    var onRemove: ((ClipboardEntry) -> Void)?
    private let searchIndexer: ClipboardSearchIndexer
    private let fileInspector: ClipboardFileInspector
    private var plainLoan: (token: Int, original: ClipboardRestorePoint, changeCount: Int)?
    private var plainLoanTokens = 0
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    var stagedEntryID: UUID? { stagedEntry?.id }
    var liftedEntryID: UUID? {
        if case .pickedUp(let entry, _, _) = heldItem { return entry.id }
        return nil
    }

    /// Which Settings › Cursor magnets choice covers what is held, if it rides the pointer.
    /// A preview rides it only after the drawer hands it over, so it counts as the drawer's.
    var heldMagnetSource: ClipboardMagnetSource? {
        switch heldItem {
        case .copied: return .copy
        case .pickedUp(_, _, let source): return source
        case .previewed: return .drawer
        case nil: return nil
        }
    }

    convenience init() {
        self.init(pasteboard: .general, persistenceURL: Self.defaultPersistenceURL())
    }

    init(pasteboard: NSPasteboard, persistenceURL: URL? = nil,
         fileInspector: ClipboardFileInspector = ClipboardFileInspector(),
         searchIndexer: ClipboardSearchIndexer = ClipboardSearchIndexer()) {
        self.pasteboard = pasteboard
        self.persistenceURL = persistenceURL
        self.fileInspector = fileInspector
        self.searchIndexer = searchIndexer
        lastChangeCount = pasteboard.changeCount
        measureStorage = { [weak self] in
            ClipboardStorageBudget.measure(at: self?.persistenceURL ?? FileManager.default.homeDirectoryForCurrentUser)
        }
    }

    /// The budget, read again when a minute old (or when asked to).
    private func currentBudget(remeasure: Bool = false) -> ClipboardStorageBudget? {
        if remeasure || budgetMeasuredAt.map({ Date().timeIntervalSince($0) > 60 }) ?? true {
            budget = measureStorage()
            budgetMeasuredAt = Date()
        }
        return budget
    }

    /// Lets go of the oldest items until the history fits its budget and the ceiling; the newest
    /// always stays. Returns what went.
    @discardableResult
    private func trimToBudget(remeasure: Bool = false) -> [ClipboardEntry] {
        let limit = currentBudget(remeasure: remeasure)?.limit ?? .max
        var used = usedBytes, evicted: [ClipboardEntry] = []
        while entries.count > 1, entries.count > itemCeiling || used > limit {
            let oldest = entries.removeLast()
            used -= oldest.byteCount
            evicted.append(oldest)
        }
        return evicted
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
        endPlainTextPaste()
        resolveStagingForShutdown()
        return saveNow()
    }

    @discardableResult
    func saveNow() -> Bool {
        checkForChanges()
        pendingPersistenceWorkItem?.cancel()
        pendingPersistenceWorkItem = nil
        guard let persistenceURL else { return true }
        let records = entries.map(ClipboardHistoryFile.record)
        var didSave = false
        persistenceQueue.sync {
            didSave = ClipboardHistoryFile.write(records, to: persistenceURL)
        }
        return didSave
    }

    /// The file this history saves to.
    var historyURL: URL? { persistenceURL }

    /// Saves this history, then shows and records into the one at `url`. Whatever is held goes
    /// back first. The clipboard's present contents join neither history: switching is not a copy.
    func switchHistory(to url: URL?) {
        checkForChanges()
        cancelStaging()
        endPlainTextPaste()
        _ = saveNow()
        let leaving = entries
        entries = []
        heldItem = nil
        cycle.reset()
        currentClipboardEntryID = nil
        onStagingChange?(.invalidated)
        leaving.forEach { onRemove?($0) }
        persistenceURL = url
        loadPersistedHistory()
        lastChangeCount = pasteboard.changeCount
        notifyChange()
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

    func selectForPaste(_ entry: ClipboardEntry, from source: ClipboardMagnetSource = .drawer) {
        checkForChanges()
        resetCycle()
        guard entries.contains(where: { $0.id == entry.id }) else { return }
        if liftedEntryID == entry.id { cancelStaging(); return }
        _ = stage(entry, pickedUpFrom: source)
    }

    /// Make an entry the clipboard's current item and the top of history with
    /// nothing held: the history window and Send to paste it straight away.
    @discardableResult
    func makeCurrent(_ entry: ClipboardEntry) -> Bool {
        checkForChanges()
        resetCycle()
        endPlainTextPaste()
        guard entries.contains(where: { $0.id == entry.id }) else { return false }
        if heldItem != nil {
            heldItem = nil
            onStagingChange?(.invalidated)
        }
        guard writeMaterializedToPasteboard(entry) else { return false }
        promote(entry)
        return true
    }

    /// Text ClipEdge itself copies (a selection's Copy as text): one plain copy on the
    /// clipboard, which the history then takes as it takes any copy, as its newest entry.
    @discardableResult
    func copyText(_ text: String) -> Bool {
        guard !text.isEmpty else { checkForChanges(); endPlainTextPaste(); return false }
        return copy(.text(text))
    }

    /// One part of an entry copied from its raw data (a flavor, or text selected in it), or a
    /// selection's text: the history takes it as any copy, as its newest entry.
    @discardableResult
    func copy(_ part: ClipboardRawCopy) -> Bool {
        checkForChanges()
        endPlainTextPaste()
        guard part.write(to: pasteboard) else { return false }
        checkForChanges()
        return true
    }

    /// Lend the clipboard a plain-text copy of what it holds, for one paste.
    /// A tracked entry lends its text (or its facts and paths); an untracked
    /// clipboard lends its own string; an empty one takes the top entry first.
    /// Given `text` (a selection's Paste as text), it lends that instead, and
    /// what the clipboard held returns afterwards all the same.
    func beginPlainTextPaste(lending given: String? = nil) -> Int? {
        checkForChanges()
        endPlainTextPaste()
        if given == nil, currentClipboardEntryID == nil, pasteboard.pasteboardItems?.isEmpty != false, let top = entries.first {
            guard makeCurrent(top) else { return nil }
        }
        let tracked = entries.first { $0.id == currentClipboardEntryID }
        let text = given ?? tracked?.plainTextForPaste ?? pasteboard.string(forType: .string) ?? ""
        guard !text.isEmpty, let original = ClipboardRestorePoint.capture(
            pasteboard, historyID: currentClipboardEntryID, limit: maximumPayloadBytes) else { return nil }
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        // Clipboard managers, this one included, skip a transient copy.
        item.setData(Data(), forType: Self.transientType)
        if original.payloads.contains(where: { $0.values.contains { $0.type == Self.concealedType } }) {
            item.setData(Data(), forType: Self.concealedType)
        }
        pasteboard.clearContents()
        let didWrite = pasteboard.writeObjects([item])
        if !didWrite { _ = original.restore(to: pasteboard) }
        lastChangeCount = pasteboard.changeCount
        guard didWrite else { return nil }
        plainLoanTokens += 1
        plainLoan = (plainLoanTokens, original, lastChangeCount)
        return plainLoanTokens
    }

    /// Put the lent clipboard back, unless something newer was copied meanwhile.
    func endPlainTextPaste(_ token: Int? = nil) {
        guard let loan = plainLoan, token == nil || token == loan.token else { return }
        plainLoan = nil
        guard pasteboard.changeCount == loan.changeCount, loan.original.restore(to: pasteboard) else { return }
        lastChangeCount = pasteboard.changeCount
        currentClipboardEntryID = loan.original.historyID
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
    func remove(_ entry: ClipboardEntry) -> Bool { remove([entry]) }

    /// Deletes these entries for good, those still in the history, saving once: a selection's
    /// Delete N… as one change. An entry already gone is skipped, never an error.
    @discardableResult
    func remove(_ doomed: [ClipboardEntry]) -> Bool {
        checkForChanges()
        resetCycle()
        let present = doomed.filter { entry in entries.contains { $0.id == entry.id } }
        guard !present.isEmpty else { return true }
        present.forEach(drop)
        historyDidChange()
        return saveNow()
    }

    /// One entry out of the history, with everything that still pointed at it.
    private func drop(_ entry: ClipboardEntry) {
        entries.removeAll { $0.id == entry.id }
        // Deleting a history item also retires any temporary undo copy of it.
        // Cancelling another pickup must not resurrect that deleted payload.
        if heldItem?.restorePoint?.historyID == entry.id {
            let empty = ClipboardRestorePoint(payloads: [], historyID: nil)
            switch heldItem {
            case .pickedUp(let held, _, let source): heldItem = .pickedUp(held, original: empty, from: source)
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
        let digest = ClipboardHistoryFile.fingerprint(for: payloads)

        if let existingIndex = entries.firstIndex(where: { $0.fingerprint == digest }) {
            let existing = entries.remove(at: existingIndex)
            if attach { existing.capturedAt = Date() }
            entries.insert(existing, at: 0)
            currentClipboardEntryID = existing.id
            if attach, attachesCopiesToCursor() { attachToCursor(existing) }
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
        deriveDetails(entry)
        if attach, attachesCopiesToCursor() { attachToCursor(entry) }
        trimToBudget().forEach { onRemove?($0) }
        historyDidChange()
    }

    @discardableResult
    /// Without a source the entry is previewed; with one it is picked up from there.
    private func stage(_ entry: ClipboardEntry, pickedUpFrom source: ClipboardMagnetSource? = nil) -> Bool {
        let original: ClipboardRestorePoint
        switch heldItem {
        case .pickedUp(_, let point, _), .previewed(_, let point): original = point
        default:
            guard let point = ClipboardRestorePoint.capture(pasteboard, historyID: currentClipboardEntryID, limit: maximumPayloadBytes) else { return false }
            original = point
        }
        guard writeMaterializedToPasteboard(entry) else { return false }
        currentClipboardEntryID = entry.id
        heldItem = source.map { .pickedUp(entry, original: original, from: $0) } ?? .previewed(entry, original: original)
        onStagingChange?(.pickedUp(entry))
        return true
    }

    private func attachToCursor(_ entry: ClipboardEntry) {
        heldItem = .copied(entry)
        onStagingChange?(.pickedUp(entry))
    }

    /// Searchable text, disk facts and thumbnails arrive later, off the main thread.
    private func deriveDetails(_ entry: ClipboardEntry) {
        indexText(entry)
        guard !entry.fileURLs.isEmpty else { return }
        let retained: (ClipboardEntry?) -> ClipboardEntry? = { [weak self] entry in
            guard let self, let entry, self.entries.contains(where: { $0.id == entry.id }) else { return nil }
            return entry
        }
        fileInspector.inspect(entry.fileURLs, facts: { [weak self, weak entry] metadata in
            guard let entry = retained(entry) else { return }
            entry.metadata = metadata
            self?.notifyChange()
        }, preview: { [weak self, weak entry] preview in
            guard let entry = retained(entry) else { return }
            switch preview {
            case .image(let image):
                entry.kind = .image
                entry.thumbnail = image.preview
                self?.indexText(entry, image: image.pixels)
            case .icon(let image), .thumbnail(let image):
                // A late lower-quality result must not replace a confirmed image.
                guard !entry.isImage else { return }
                entry.thumbnail = image
            }
            self?.notifyChange()
        })
    }

    /// A picture's text is read once and kept beside its item, so a launch does not read every
    /// picture again; a file's text is read afresh, since the file can change.
    private func indexText(_ entry: ClipboardEntry, image: CGImage? = nil) {
        guard entry.isImage || !entry.fileURLs.isEmpty else { return }
        let keepsText = entry.isImage && entry.fileURLs.isEmpty && image == nil
        if keepsText, let url = persistenceURL, let saved = ClipboardHistoryFile.savedText(of: entry.fingerprint, in: url) {
            entry.searchIndex = .ready(saved)
            return
        }
        entry.searchGeneration &+= 1
        let generation = entry.searchGeneration
        entry.searchIndex = .pending
        searchIndexer.index(entry, image: image) { [weak self, weak entry] result in
            guard let self, let entry, entry.searchGeneration == generation,
                  self.entries.contains(where: { $0.id == entry.id }) else { return }
            entry.searchIndex = result
            if keepsText, case .ready(let text) = result, let url = self.persistenceURL {
                let fingerprint = entry.fingerprint
                // After the item's own save, which runs first on the same queue.
                self.persistenceQueue.async { ClipboardHistoryFile.saveText(text, of: fingerprint, in: url) }
            }
            self.notifyChange()
        }
    }

    private func notifyChange() {
        onChange?()
        NotificationCenter.default.post(name: Self.didChange, object: self)
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
        notifyChange()
        schedulePersistence()
    }

    private func schedulePersistence() {
        guard let persistenceURL else { return }
        let records = entries.map(ClipboardHistoryFile.record)
        pendingPersistenceWorkItem?.cancel()

        let workItem = DispatchWorkItem {
            ClipboardHistoryFile.write(records, to: persistenceURL)
        }
        pendingPersistenceWorkItem = workItem
        persistenceQueue.async(execute: workItem)
    }

    private func loadPersistedHistory() {
        guard let persistenceURL else { return }

        do {
            guard let records = try ClipboardHistoryFile.read(persistenceURL) else { return }
            var loadedEntries: [ClipboardEntry] = []
            var seenFingerprints = Set<String>()
            for record in records.prefix(itemCeiling) {
                guard isValidForPersistence(record.payloads) else { continue }
                // An item from the store is in a folder named by its fingerprint; hashing every byte
                // of a large history at launch would read all of it from disk.
                let fingerprint = record.fromStore ? record.fingerprint : ClipboardHistoryFile.fingerprint(for: record.payloads)
                guard fingerprint == record.fingerprint,
                      seenFingerprints.insert(fingerprint).inserted else { continue }
                loadedEntries.append(ClipboardHistoryFile.entry(record))
            }

            entries = loadedEntries
            let trimmed = !trimToBudget(remeasure: true).isEmpty
            entries.forEach(deriveDetails)
            notifyChange()
            // A history read from its old file moves into its store now (the old file stays as it
            // was); one that lost items to the budget saves without them.
            if records.contains(where: { !$0.fromStore }) || trimmed { schedulePersistence() }
        } catch {
            ClipboardHistoryFile.quarantine(persistenceURL)
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

    private static func defaultPersistenceURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ClipEdge", isDirectory: true)
            .appendingPathComponent("History.plist", isDirectory: false)
    }
}
