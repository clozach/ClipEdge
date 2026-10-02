import AppKit

/// Short-lived, in-memory undo for pickup. Never indexed, persisted or logged.
/// Empty and untracked clipboards are real restore points, not missing IDs.
struct ClipboardRestorePoint {
    let payloads: [ClipboardPayload]
    let historyID: UUID?

    static func capture(_ board: NSPasteboard, historyID: UUID?, limit: Int) -> ClipboardRestorePoint? {
        var bytes = 0
        var payloads: [ClipboardPayload] = []
        for item in board.pasteboardItems ?? [] {
            var values: [(type: NSPasteboard.PasteboardType, data: Data)] = []
            for type in item.types {
                guard let data = item.data(forType: type), data.count <= limit - bytes else { return nil }
                bytes += data.count
                values.append((type, data))
            }
            payloads.append(ClipboardPayload(values: values))
        }
        return ClipboardRestorePoint(payloads: payloads, historyID: historyID)
    }

    func restore(to board: NSPasteboard) -> Bool {
        let items = payloads.map { payload in
            let item = NSPasteboardItem()
            for value in payload.values { item.setData(value.data, forType: value.type) }
            return item
        }
        board.clearContents()
        return items.isEmpty || board.writeObjects(items)
    }
}
