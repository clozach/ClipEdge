import AppKit

/// The menu bar menu's part in the sample history: the visible way back while the sample
/// shows, the two Option items (*Use Sample History*, *Add “…” to Sample History*), and the
/// icon that says which history is showing, so the sample is never left on unnoticed.
final class ClipboardSampleHistoryMenu: NSObject, NSMenuDelegate, NSMenuItemValidation {
    private let store: ClipboardStore
    private weak var statusItem: NSStatusItem?
    private(set) var source: ClipboardHistorySource
    /// The sample's fingerprints as of the file's last change; Terminal edits change the file.
    private var known: (changed: Date?, fingerprints: Set<String>)?
    let banner = NSMenuItem(title: "Showing Sample History · Use Real History", action: #selector(toggle), keyEquivalent: "")
    let toggleItem = NSMenuItem(title: "Use Sample History", action: #selector(toggle), keyEquivalent: "")
    let addItem = NSMenuItem(title: "Add Newest Item to Sample History", action: #selector(addNewest), keyEquivalent: "")

    init(store: ClipboardStore, source: ClipboardHistorySource) {
        self.store = store
        self.source = source
        super.init()
        for item in [banner, toggleItem, addItem] { item.target = self }
        // The easter egg: holding Option turns the items just above these into them.
        for item in [toggleItem, addItem] {
            item.keyEquivalentModifierMask = [.option]
            item.isAlternate = true
        }
    }

    func attach(to statusItem: NSStatusItem) {
        self.statusItem = statusItem
        statusItem.menu?.delegate = self
        refreshIcon()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let onSample = source == .sample
        banner.isHidden = !onSample
        toggleItem.title = onSample ? "Use Real History" : "Use Sample History"
        addItem.title = Self.addTitle(onSample: onSample, newest: store.entries.first, inSample: { [weak self] in
            self?.sampleFingerprints.contains($0) ?? false
        })
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem === addItem else { return true }
        guard source == .real, let newest = store.entries.first else { return false }
        return !sampleFingerprints.contains(newest.fingerprint)
    }

    /// What Add would do, said before it is chosen: which item, or why it can't.
    static func addTitle(onSample: Bool, newest: ClipboardEntry?, inSample: (String) -> Bool) -> String {
        if onSample { return "Copy Something to Add It to Sample History" }
        guard let newest else { return "Add Newest Item to Sample History" }
        let label = "“\(ClipboardSampleHistory.menuLabel(newest.title))”"
        return inSample(newest.fingerprint) ? "\(label) Is in Sample History" : "Add \(label) to Sample History"
    }

    private var sampleFingerprints: Set<String> {
        guard let url = ClipboardHistorySource.sample.url() else { return [] }
        let changed = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if let known, known.changed == changed { return known.fingerprints }
        let fingerprints = Set(((try? ClipboardHistoryFile.read(url)) ?? nil ?? []).map(\.fingerprint))
        known = (changed, fingerprints)
        return fingerprints
    }

    @objc private func toggle() {
        let next = source.other
        if next == .sample { seedIfNeeded() }
        store.switchHistory(to: next.url())
        source = next
        next.save()
        refreshIcon()
    }

    /// The first switch seeds the sample from the real history in memory; later ones keep it.
    private func seedIfNeeded() {
        guard let url = ClipboardHistorySource.sample.url(), !ClipboardHistoryFile.exists(url) else { return }
        ClipboardHistoryFile.write(ClipboardSampleHistory.seed(from: store.entries).map(ClipboardHistoryFile.record), to: url)
    }

    @objc private func addNewest() {
        guard source == .real, let newest = store.entries.first, let url = ClipboardHistorySource.sample.url() else { return }
        seedIfNeeded()
        let records: [ClipboardHistoryFile.Record]
        do { records = try ClipboardHistoryFile.read(url) ?? [] } catch {
            return alert("ClipEdge couldn't read the sample history")
        }
        let updated = ClipboardSampleHistory.adding(ClipboardHistoryFile.record(newest), to: records)
        guard ClipboardHistoryFile.write(updated, to: url) else { return alert("ClipEdge couldn't save the sample history") }
    }

    private func alert(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = "It was left as it is."
        alert.runModal()
    }

    private func refreshIcon() {
        let onSample = source == .sample
        statusItem?.button?.image = ClipboardIcons.symbol(onSample ? "theatermasks" : "list.clipboard",
                                                          description: onSample ? "ClipEdge, showing sample history" : "ClipEdge")
        statusItem?.button?.toolTip = onSample ? "ClipEdge · Sample History" : "ClipEdge"
    }
}
