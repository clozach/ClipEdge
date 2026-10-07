import AppKit

@main enum BrowserTests {
    static var assertions = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError("FAIL: \(message)") }
    }
    static func entry(_ title: String, kind: ClipboardKind = .text) -> ClipboardEntry {
        ClipboardEntry(fingerprint: title, capturedAt: Date(timeIntervalSince1970: 1_780_000_000),
                       payloads: [ClipboardPayload(values: [(.string, Data(title.utf8))])],
                       title: title, detail: "Fixture", kind: kind, thumbnail: nil)
    }
    static func main() {
        _ = NSApplication.shared
        let browser = ClipboardBrowserView(frame: NSRect(x: 0, y: 0, width: 390, height: 700))
        let a = entry("A"), b = entry("B", kind: .image), c = entry("C")
        let original = [a, b, c]
        browser.update(entries: original, attachedID: nil)
        let firstTiles = browser.canvas.tiles
        check(firstTiles.allSatisfy { $0.acceptsFirstMouse(for: nil) }, "all tile types accept an inactive-window first click")
        check(firstTiles.flatMap(\.subviews).compactMap { $0 as? NSButton }.allSatisfy { $0.acceptsFirstMouse(for: nil) }, "sibling Preview/delete buttons accept the first click")
        let firstFrames = firstTiles.map(\.frame)
        browser.canvas.choose(c.id, reveal: false)
        browser.update(entries: [c, a, b], attachedID: c.id)
        check(browser.canvas.tiles[0] === firstTiles[2], "promoted tile retains view identity")
        check(browser.canvas.tiles[1] === firstTiles[0] && browser.canvas.tiles[2] === firstTiles[1], "displaced rows retain view identity")
        check(browser.canvas.tiles.map(\.frame) == firstFrames, "hidden browser reaches final row positions immediately")
        check(browser.canvas.selectedID == c.id && browser.canvas.tiles[0].isAttached, "selection and attachment follow promoted row")
        check(browser.canvas.subviews.last === firstTiles[2], "promoted row paints above displaced siblings")

        c.searchIndex = .ready("OCR completion")
        browser.update(entries: [c, a, b], attachedID: c.id)
        check(browser.canvas.tiles[0] === firstTiles[2] && browser.canvas.tiles.map(\.frame) == firstFrames, "OCR refresh preserves identities and target geometry")
        c.capturedAt = c.capturedAt.addingTimeInterval(120)
        browser.update(entries: [c, a, b], attachedID: c.id)
        check(firstTiles[2].tooltipText.contains(c.fullDateTimeStamp), "recopy refreshes existing tile timestamp tooltip")
        let legend = ClipboardTileTooltip.legendText
        check(legend.contains("Paste held item ← ⌘click") && legend.contains("Keep holding ← click") && !legend.contains("⇧click"),
              "help legend matches Command-click paste")

        var picked: UUID?, hovered: UUID?, deleted: UUID?, opened: UUID?
        browser.canvas.onPick = { picked = $0.id }
        browser.onHover = { hovered = $0.id }
        browser.canvas.onDelete = { deleted = $0.id }
        browser.canvas.onOpen = { opened = $0.id }
        firstTiles[2].onPick?(); firstTiles[2].onHover?(); firstTiles[2].onDelete?(); firstTiles[2].onOpen?()
        check([picked, hovered, deleted, opened].allSatisfy { $0 == c.id }, "reused tile callbacks remain attached to the right entry")
        for tile in firstTiles {
            tile.onHover?()
            check(browser.canvas.tiles.filter(\.isChosen).count == 1 && tile.isChosen, "hover has exactly one list-owned selection")
        }
        // Reproduce missed mouseExited after Space, then a mid-list click.
        let hoverEvent = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                               windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        firstTiles[0].mouseEntered(with: hoverEvent)
        var previewed: UUID?
        browser.canvas.onPreview = { previewed = $0.id }
        let space = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                    context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
        browser.canvas.keyDown(with: space)
        check(previewed == a.id, "Space previews hovered tile without a click")
        firstTiles[1].mouseEntered(with: hoverEvent)
        firstTiles[1].onPick?()
        check(browser.canvas.tiles.filter(\.isChosen).count == 1 && firstTiles[1].isChosen, "missed mouse exit cannot leave duplicate purple selection")
        browser.update(entries: [c, a, b], attachedID: b.id)
        check(firstTiles[1].isAttached && browser.canvas.tiles.filter(\.isAttached).count == 1, "only picked-up slot becomes empty")
        check(browser.canvas.tiles.map(\.frame) == firstFrames, "pickup does not move its slot")

        browser.search.stringValue = "B"
        browser.update(entries: [c, a, b], attachedID: c.id)
        check(browser.canvas.tiles.count == 1 && browser.canvas.tiles[0] === firstTiles[1], "search retains matching tile")
        check(firstTiles[0].superview == nil && firstTiles[2].superview == nil, "filtered rows leave hierarchy")
        browser.search.stringValue = ""
        browser.update(entries: [c, a, b], attachedID: nil)
        check(browser.canvas.tiles[0] === firstTiles[2], "clearing filter reuses cached rows")
        browser.tabs.selectedSegment = 1
        browser.update(entries: [c, a, b], attachedID: nil)
        let imageTile = browser.canvas.tiles[0]
        check(imageTile !== firstTiles[1] && imageTile.imageOnly, "image mode uses separate tile presentation")
        browser.tabs.selectedSegment = 0
        browser.update(entries: [c, a, b], attachedID: nil)
        check(browser.canvas.tiles[2] === firstTiles[1], "returning to All restores its row view")
        browser.tabs.selectedSegment = 1
        browser.update(entries: [c, a, b], attachedID: nil)
        check(browser.canvas.tiles[0] === imageTile, "image mode view also survives switching tabs")
        browser.tabs.selectedSegment = 0
        browser.update(entries: [a, b], attachedID: nil)
        browser.update(entries: [c, a, b], attachedID: nil)
        check(browser.canvas.tiles[0] !== firstTiles[2], "removed history entries are evicted from cache")

        let ids = original.map(\.id)
        check(ClipboardBrowserView.promotedEntry(from: ids, to: [c.id, a.id, b.id]) == c.id, "move-to-front qualifies for animation")
        check(ClipboardBrowserView.promotedEntry(from: ids, to: ids) == nil, "same-order attachment and OCR updates do not animate")
        check(ClipboardBrowserView.promotedEntry(from: ids, to: [b.id, c.id]) == nil, "filtering does not animate as promotion")
        check(ClipboardBrowserView.promotedEntry(from: ids, to: [c.id, b.id, a.id]) == nil, "unrelated reorder does not animate as promotion")
        check(browser.tabs.segmentCount == 3 && (0..<3).map { browser.tabs.label(forSegment: $0)! } == ["All", "Images", "Text"], "Text follows Images")
        let link = entry("https://example.com", kind: .link), file = entry("file path", kind: .file), other = entry("opaque", kind: .other)
        let opaque = ClipboardEntry(fingerprint: "opaque", capturedAt: Date(), payloads: [], title: "Opaque", detail: "", kind: .other, thumbnail: nil)
        let rtf = ClipboardEntry(fingerprint: "rtf", capturedAt: Date(), payloads: [ClipboardPayload(values: [(.rtf, Data("{\\rtf1\\ansi Rich note}".utf8))])], title: "Clipboard item", detail: "", kind: .other, thumbnail: nil)
        browser.tabs.selectedSegment = 2
        browser.update(entries: [a, b, link, file, other, opaque, rtf], attachedID: nil)
        check(browser.visibleEntries.map(\.id) == [a, link, other, rtf].map(\.id), "Text includes text/link/RTF; excludes images and files even with text payloads")
        check(browser.columns == 1 && browser.zoom.isHidden && browser.canvas.tiles.allSatisfy { !$0.imageOnly }, "Text uses summary rows without image zoom")
        browser.search.stringValue = "Rich"
        browser.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        check(browser.visibleEntries.map(\.id) == [rtf.id], "Text search includes RTF content")
        func commandKey(_ character: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                             characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)!
        }
        var finds = 0
        browser.canvas.onFind = { finds += 1 }
        browser.canvas.keyDown(with: commandKey("f", 3, [.command]))
        check(finds == 1, "Command-F from the tiles asks for the search field")
        browser.canvas.keyDown(with: commandKey("f", 3, [.command, .shift]))
        browser.canvas.keyDown(with: commandKey("f", 3, []))
        check(finds == 1, "only plain Command-F does")
        check(ClipboardTileTooltip.rows.contains { $0 == ("Search", "⌘F") }, "the tile help names Command-F")

        // A card's info rides the card, never the pointer, and never covers the card.
        check(ClipboardTileTooltip.delay == 2, "a card's info waits 2 seconds of hovering")
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let card = NSRect(x: 1000, y: 500, width: 400, height: 90)
        let size = NSSize(width: 360, height: 300)
        let beside = NSRect(x: 632, y: 395, width: 360, height: 300)
        let placed = ClipboardTileTooltip.frame(fitting: size, card: card, screen: screen, beside: beside)
        check(placed == beside && !placed.intersects(card), "with room beside the drawer, the info opens there, level with the card")
        let narrow = ClipboardTileTooltip.frame(fitting: size, card: card, screen: screen,
                                                beside: NSRect(x: 0, y: 395, width: 200, height: 300))
        check(!narrow.intersects(card) && narrow.maxY <= card.minY && screen.contains(narrow), "without that room, the info opens just below the card")
        let low = NSRect(x: 1000, y: 40, width: 400, height: 90)
        let raised = ClipboardTileTooltip.frame(fitting: size, card: low, screen: screen, beside: nil)
        check(!raised.intersects(low) && raised.minY >= low.maxY && screen.contains(raised), "near the screen's bottom it opens above the card")
        let edge = NSRect(x: 1300, y: 500, width: 400, height: 90)
        let clamped = ClipboardTileTooltip.frame(fitting: size, card: edge, screen: screen, beside: nil)
        check(screen.contains(clamped) && !clamped.intersects(edge), "it stays on screen beside a card at the screen's edge")
        print("PASS: \(assertions) browser assertions")
    }
}
