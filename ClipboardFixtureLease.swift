import AppKit
import CryptoKit

/// Explicit integration-fixture mode keeps the real clipboard only in memory.
/// Restore it only if a known fixture payload is still there: a new user copy wins.
final class ClipboardFixtureLease {
    private let original: [ClipboardPayload]
    private var owned: Set<String> = []
    init() {
        original = Self.read(.general)
        NSPasteboard.general.clearContents()
    }
    func register(_ entries: [ClipboardEntry]) { owned = Set(entries.map { Self.signature($0.payloads) }) }
    func restore() {
        let board = NSPasteboard.general
        guard owned.contains(Self.signature(Self.read(board))) else { return }
        board.clearContents()
        let items = original.map { payload in
            let item = NSPasteboardItem()
            for value in payload.values { item.setData(value.data, forType: value.type) }
            return item
        }
        if !items.isEmpty { board.writeObjects(items) }
    }
    private static func read(_ board: NSPasteboard) -> [ClipboardPayload] {
        (board.pasteboardItems ?? []).map { item in
            ClipboardPayload(values: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
    }
    private static func signature(_ payloads: [ClipboardPayload]) -> String {
        var hash = SHA256()
        for payload in payloads {
            for value in payload.values.sorted(by: { $0.type.rawValue < $1.type.rawValue }) {
                hash.update(data: Data(value.type.rawValue.utf8)); hash.update(data: value.data)
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

final class ClipboardDemoDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        stop(); return .terminateCancel
    }
    @objc func stop() {
        NSApp.stop(nil)
        if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
            NSApp.postEvent(event, atStart: true)
        }
    }
}
