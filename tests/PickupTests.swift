import AppKit

@main enum PickupTests {
    private static var assertions = 0
    private static var failures: [String] = []
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() { failures.append(message) }
    }

    private static func fixture(_ body: (ClipboardStore, NSPasteboard) -> Void) {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let store = ClipboardStore(pasteboard: board, persistenceURL: nil)
        for value in ["A", "B", "C"] { write(value, board); _ = store.saveNow() }
        store.cancelStaging()
        body(store, board)
    }

    private static func write(_ string: String, _ board: NSPasteboard) {
        board.clearContents()
        board.setString(string, forType: .string)
    }

    static func main() {
        _ = NSApplication.shared
        fixture { store, board in
            let order = store.entries.map(\.id)
            let dates = store.entries.map(\.capturedAt)
            let middle = store.entries[1], bottom = store.entries[2]
            store.selectForPaste(middle)
            check(store.liftedEntryID == middle.id && board.string(forType: .string) == "B", "pickup stages the chosen clipboard payload")
            check(store.entries.map(\.id) == order && store.entries.map(\.capturedAt) == dates, "pickup leaves row order and timestamps intact")
            store.selectForPaste(bottom)
            check(store.liftedEntryID == bottom.id, "another pickup replaces exactly one held item")
            store.cancelStaging()
            check(board.string(forType: .string) == "C" && store.stagedEntryID == nil, "cancel restores clipboard preceding the whole pickup sequence")
            check(store.entries.map(\.id) == order, "cancel restores without history promotion")
            store.selectForPaste(middle); store.selectForPaste(middle)
            check(board.string(forType: .string) == "C" && store.liftedEntryID == nil, "second click on picked-up slot cancels")
            store.previewInCarousel(bottom)
            check(store.stagedEntryID == bottom.id && store.liftedEntryID == nil, "preview does not create a lifted slot")
            store.cancelStaging()
            check(board.string(forType: .string) == "C" && store.entries.map(\.id) == order, "closing preview restores prior clipboard and unchanged history")
            var committed = 0
            store.onPasteCommitted = { committed += 1 }
            store.selectForPaste(middle); store.commitStagedPaste(); store.commitStagedPaste()
            check(store.entries.map(\.id) == [middle.id, order[0], order[2]], "paste commits one move to front")
            check(store.entries.map(\.capturedAt).sorted() == dates.sorted(), "paste promotion preserves timestamps")
            check(store.stagedEntryID == nil && board.string(forType: .string) == "B" && committed == 1, "paste detaches once and leaves payload available")
        }
        fixture { store, board in
            let middle = store.entries[1]
            board.clearContents(); _ = store.saveNow()
            store.selectForPaste(middle); store.cancelStaging()
            check(board.pasteboardItems?.isEmpty != false, "cancel restores an originally empty clipboard")
        }
        fixture { store, board in
            let middle = store.entries[1]
            let item = NSPasteboardItem()
            item.setString("synthetic concealed original", forType: .string)
            item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            board.clearContents(); board.writeObjects([item]); _ = store.saveNow()
            store.selectForPaste(middle); store.cancelStaging()
            check(board.string(forType: .string) == "synthetic concealed original", "cancel preserves an original payload excluded from history")
            check(store.entries.count == 3, "excluded original never enters history")
        }
        fixture { store, board in
            let middle = store.entries[1]
            store.selectForPaste(middle)
            write("newer external copy", board)
            store.cancelStaging()
            check(board.string(forType: .string) == "newer external copy", "cancel cannot overwrite a newer unpolled external copy")
            check(store.stagedEntryID != nil, "stale cancellation cannot detach the newly copied item")
        }
        fixture { store, board in
            let middle = store.entries[1]
            store.selectForPaste(middle)
            write("newer external copy", board)
            store.commitStagedPaste()
            check(store.stagedEntryID != nil && board.string(forType: .string) == "newer external copy", "late paste completion leaves a different newer copy held")
        }
        fixture { store, board in
            let middle = store.entries[1]
            store.selectForPaste(middle)
            write("B", board)
            store.commitStagedPaste()
            check(store.stagedEntryID == middle.id, "late paste completion leaves an identical newer copy held")
        }
        fixture { store, board in
            store.selectForPaste(store.entries[1])
            check(store.prepareForTermination(), "shutdown preparation succeeds without persistence")
            check(board.string(forType: .string) == "C" && store.stagedEntryID == nil, "shutdown restores cancelled pickup clipboard")
        }
        fixture { store, board in
            let original = store.entries[0], picked = store.entries[1]
            store.selectForPaste(picked)
            check(store.remove(original), "original history item can be explicitly deleted during another pickup")
            store.cancelStaging()
            check(board.pasteboardItems?.isEmpty != false, "cancel cannot resurrect an explicitly deleted original clipboard item")
            check(!store.entries.contains(where: { $0.id == original.id }), "deleted original remains absent from history")
        }
        fixture { store, board in
            let order = store.entries.map(\.id)
            store.selectForPaste(store.entries[1])
            var commits = 0
            store.onPasteCommitted = { commits += 1 }
            store.dropStaging()
            check(store.stagedEntryID == nil && store.liftedEntryID == nil, "non-editable click drops magnet and restores filled slot")
            check(store.entries.map(\.id) == order && commits == 0, "non-paste drop does not reorder or report a paste")
            check(board.string(forType: .string) == "B", "drop retains selected payload for a later explicit paste")
            store.selectForPaste(store.entries[2])
            write("newer copy", board)
            store.dropStaging()
            check(store.stagedEntryID != nil && board.string(forType: .string) == "newer copy", "late drop cannot consume a newer external copy")
        }
        testSelectionAndKeys()
        for failure in failures { print("FAIL: \(failure)") }
        print("\(failures.isEmpty ? "PASS" : "FAIL"): \(assertions) pickup/browser assertions, \(failures.count) failures; no runtime input")
        if !failures.isEmpty { exit(1) }
    }

    private static func testSelectionAndKeys() {
        func entry(_ name: String) -> ClipboardEntry {
            ClipboardEntry(fingerprint: name, capturedAt: Date(), payloads: [ClipboardPayload(values: [(.string, Data(name.utf8))])],
                           title: name, detail: "", kind: .text, thumbnail: nil)
        }
        let entries = [entry("A"), entry("B"), entry("C")]
        let browser = ClipboardBrowserView(frame: NSRect(x: 0, y: 0, width: 390, height: 700))
        browser.update(entries: entries, attachedID: nil)
        for tile in browser.canvas.tiles {
            tile.onHover?()
            check(browser.canvas.tiles.filter(\.isChosen).count == 1 && tile.isChosen, "hover has one canonical selected row")
        }
        browser.update(entries: entries, attachedID: entries[0].id)
        check(browser.canvas.tiles.filter(\.isChosen).count == 1 && browser.canvas.tiles.filter(\.isAttached).count == 1, "lifted slot and hover cannot create duplicate selection")
        var previewed: UUID?
        browser.canvas.onPreview = { previewed = $0.id }
        func key(_ code: UInt16, repeatKey: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                            context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: repeatKey, keyCode: code)!
        }
        browser.canvas.keyDown(with: key(49))
        check(previewed == entries[2].id, "Space targets hovered row without a pickup click")
        previewed = nil
        browser.canvas.keyDown(with: key(49, repeatKey: true))
        check(previewed == nil, "held Space does not repeat preview toggling")
        var escaped = false
        browser.canvas.onEscape = { escaped = true }
        browser.search.stringValue = "no matches"
        browser.update(entries: entries, attachedID: entries[0].id)
        browser.canvas.keyDown(with: key(53))
        check(escaped, "Escape cancels held item even when search hides every row")
        ClipboardTileTooltip.shared.hide()
    }
}
