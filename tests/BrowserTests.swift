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
    /// Al, 2026-10-15: each tab's key sits in its own darker-gray cap after its name, on a 28-point
    /// bar, so "Images 2" never reads as one label; Select, beside the tabs, shows its key the same way.
    static func testKeyCaps() {
        let browser = ClipboardBrowserView(frame: NSRect(x: 0, y: 0, width: 380, height: 500))
        browser.layoutSubtreeIfNeeded()
        let tabs = browser.tabs, select = browser.selectButton
        check(tabs.cell is ClipboardKeyedSegmentCell && tabs.controlSize == .large && tabs.frame.height == 28,
              "the tabs draw their names and caps on the system's 28-point bar (\(tabs.frame.height))")
        check((0..<4).map { tabs.label(forSegment: $0)! } == ["All, 0", "Text, 1", "Images, 2", "Other, 3"], "VoiceOver reads each tab's name, then its key")
        let font = tabs.font!
        check((0..<4).allSatisfy { tabs.width(forSegment: $0) >= tabs.titles[$0].size(font: font).width + 2 * ClipboardTabBar.padding }
              && tabs.fittingSize.width <= tabs.frame.width && tabs.frame.maxX + 8 <= select.frame.minX,
              "every name and cap fits whole at the drawer's width, ending 8 points short of Select (\(tabs.fittingSize.width) in \(tabs.frame.width))")
        check(abs(tabs.frame.midY - select.frame.midY) <= 0.5 && browser.search.frame.minY == tabs.frame.maxY + 10, "Select sits level with the taller tabs; the search follows them")
        check(select.title == "Select" && select.image != nil && select.imagePosition == .imageTrailing && select.accessibilityLabel() == "Select, S"
              && select.keyedTitle == ClipboardKeymap.drawer.keyed("Select", .selecting), "Select shows its key in the same cap, after its name")
        let bare = ClipboardKeyedTitle(name: "Paste", key: nil)
        check(bare.plain == "Paste" && bare.spoken == "Paste" && bare.size(font: font).width == ceil(("Paste" as NSString).size(withAttributes: [.font: font]).width),
              "a name without a key here is the name alone, with no cap")
        check(ClipboardKeymap.window.keyed("Images", .tab(.images)).spoken == "Images, Command-2" && ClipboardKeyCap.size("1", beside: font).width == ClipboardKeyCap.size("1", beside: font).height
              && ClipboardKeyCap.size("⌘1", beside: font).width > ClipboardKeyCap.size("1", beside: font).width, "a one-character cap is square; a chord's is wider")
        // The cap, drawn on the bar's own grays in each appearance: darker than the ground inside it,
        // its key drawn in it.
        for (theme, appearance, ground) in [("light", NSAppearance.Name.aqua, 0.89), ("dark", .darkAqua, 0.27)] {
            NSApp.appearance = NSAppearance(named: appearance)
            let cap = ClipboardKeyCap.image("2", beside: font)
            let size = cap.size, scale = 2
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                NSColor(white: ground, alpha: 1).setFill(); NSRect(origin: .zero, size: size).fill()
                cap.draw(in: NSRect(origin: .zero, size: size))
            }
            NSGraphicsContext.restoreGraphicsState()
            func white(_ x: Int, _ y: Int) -> CGFloat { rep.colorAt(x: x, y: y)!.usingColorSpace(.deviceGray)!.whiteComponent }
            let inside = white(5, rep.pixelsHigh / 2)
            let glyph = (0..<rep.pixelsWide).map { white($0, rep.pixelsHigh / 2) }
            check(inside < CGFloat(ground) - 0.05, "\(theme): the cap is darker than the gray it sits on (\(inside) on \(ground))")
            check(glyph.contains { abs($0 - inside) > 0.15 }, "\(theme): its key is drawn in it")
        }
        NSApp.appearance = nil
    }

    static func main() {
        _ = NSApplication.shared
        let browser = ClipboardBrowserView(frame: NSRect(x: 0, y: 0, width: 390, height: 700))
        // Here the pointer moves onto every card it hovers (a still one is TabNavigationTests').
        var moved = 0.0
        browser.canvas.pointer = { moved += 1; return NSPoint(x: moved, y: 0) }
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
        let legend = ClipboardTileTooltip.legendText(.drawer, asker: nil)
        check(legend.contains("Paste held item ← ⌘click") && legend.contains("Keep holding ← click") && !legend.contains("⇧click"),
              "help legend matches Command-click paste")
        check(ClipboardTile(entry: entry("w"), style: .compact, keymap: .window).accessibilityHelp() == nil && ClipboardTile(entry: entry("d"), style: .row, keymap: .drawer).accessibilityHelp() == ClipboardTileTooltip.legendText(.drawer, asker: nil, spoken: true),
              "the ⌥⌘\\ window's rows carry no drawer key legend; the drawer's rows still do")

        var picked: UUID?, hovered: UUID?, deleted: UUID?, opened: UUID?, previewed: UUID?, finds = 0
        // The drawer's answers, standing in for its controller's; the search and the tabs stay the view's.
        browser.perform = { action, entry in
            switch action {
            case .primary: picked = entry?.id
            case .delete: deleted = entry?.id
            case .open: opened = entry?.id
            case .quickLook: previewed = entry?.id
            case .find: finds += 1
            default: return false
            }
            return true
        }
        browser.onHover = { hovered = $0.id }
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
        browser.tabs.selectedSegment = ClipboardBrowserTab.images.rawValue
        browser.update(entries: [c, a, b], attachedID: nil)
        let imageTile = browser.canvas.tiles[0]
        check(imageTile !== firstTiles[1] && imageTile.imageOnly, "image mode uses separate tile presentation")
        browser.tabs.selectedSegment = 0
        browser.update(entries: [c, a, b], attachedID: nil)
        check(browser.canvas.tiles[2] === firstTiles[1], "returning to All restores its row view")
        browser.tabs.selectedSegment = ClipboardBrowserTab.images.rawValue
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
        check(browser.tabs.segmentCount == 4 && browser.tabs.titles.map(\.plain) == ["All 0", "Text 1", "Images 2", "Other 3"]
              && browser.tabs.toolTip(forSegment: 3) == "Other ← 3", "Text follows Images, Other follows Text, each tab showing its key")
        testKeyCaps()
        // Built as captured, so the kind is the one ClipboardSummary decides.
        func captured(_ values: ClipboardWebCopies.Values) -> ClipboardEntry {
            let summary = ClipboardSummary.make(from: [ClipboardPayload(values: values)])
            return ClipboardEntry(fingerprint: UUID().uuidString, capturedAt: Date(), payloads: [ClipboardPayload(values: values)],
                                  title: summary.title, detail: summary.detail, kind: summary.kind, thumbnail: summary.thumbnail)
        }
        let link = entry("https://example.com", kind: .link), file = entry("file path", kind: .file)
        let opaque = captured([(NSPasteboard.PasteboardType("com.example.opaque"), Data([1]))])
        let rtf = captured(ClipboardWebCopies.rtf("Rich note"))
        let page = captured(ClipboardWebCopies.html(ClipboardWebCopies.plainHTML)), layers = captured(ClipboardWebCopies.figma())
        check(rtf.kind == .text && rtf.title == "Rich note", "rich text alone is text, titled by its words")
        browser.tabs.selectedSegment = ClipboardBrowserTab.text.rawValue
        browser.update(entries: [a, b, link, file, opaque, rtf, page, layers], attachedID: nil)
        check(browser.visibleEntries.map(\.id) == [a, link, rtf, page].map(\.id), "Text includes text/link/RTF/HTML-only; excludes images, files, app data and Figma layers")
        browser.tabs.selectedSegment = 3
        browser.update(entries: [a, b, link, file, opaque, rtf, page, layers], attachedID: nil)
        check(browser.visibleEntries.map(\.id) == [file, opaque, layers].map(\.id) && browser.zoom.isHidden, "Other lists Finder items, app data and Figma layers, as rows")
        browser.tabs.selectedSegment = 0
        browser.update(entries: [a, b, link, file, opaque, rtf, page, layers], attachedID: nil)
        check(browser.visibleEntries.count == 8, "All lists everything, Figma layers included")
        browser.search.stringValue = "Fixture Board"
        browser.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        check(browser.visibleEntries.map(\.id) == [layers.id], "search finds Figma layers by their file's name")
        browser.search.stringValue = ""
        browser.tabs.selectedSegment = ClipboardBrowserTab.text.rawValue
        browser.update(entries: [a, b, link, file, opaque, rtf, page, layers], attachedID: nil)
        check(browser.columns == 1 && browser.zoom.isHidden && browser.canvas.tiles.allSatisfy { !$0.imageOnly }, "Text uses summary rows without image zoom")
        browser.search.stringValue = "Rich"
        browser.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        check(browser.visibleEntries.map(\.id) == [rtf.id], "Text search includes RTF content")
        // The search's clear button empties it and sends the field's action, not a text change.
        let clearButton = (browser.search.cell as! NSSearchFieldCell).cancelButtonCell!
        NSApp.sendAction(clearButton.action!, to: clearButton.target, from: clearButton)
        check(browser.search.stringValue.isEmpty && browser.canvas.tiles.map(\.entry.id) == [a, link, rtf, page].map(\.id),
              "the search's clear button shows every card of the tab again (\(browser.canvas.tiles.count) shown)")
        func commandKey(_ character: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                             characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)!
        }
        browser.canvas.keyDown(with: commandKey("f", 3, [.command]))
        check(finds == 1, "Command-F from the tiles asks for the search field")
        browser.canvas.keyDown(with: commandKey("/", 44, []))
        check(finds == 2, "and so does the slash alone, as in Gmail")
        browser.canvas.keyDown(with: commandKey("f", 3, []))
        check(finds == 2, "F alone no longer does")
        // Rejected keys pass on, and a key nothing takes beeps: they are read, not pressed.
        for (character, code, flags) in [("F", UInt16(3), NSEvent.ModifierFlags.shift), ("f", 3, [.command, .shift]), ("ƒ", 3, [.option]), ("f", 3, [.control]),
                                         ("!", 18, [.shift]), ("1", 18, [.command]), ("2", 19, [.control]), ("<", 43, [.shift]), (",", 43, [.command])] {
            check(ClipboardKeymap.drawer.action(for: commandKey(character, code, flags)) == nil, "\(flags) \(character) is no drawer key")
        }
        // ⌥ and a digit is never a tab: it copies that flavor of Quick Look's raw data (2026-10-12).
        check(ClipboardKeymap.drawer.action(for: commandKey("™", 19, [.option])) == .copyFlavor(2), "⌥2 copies flavor 2, never a tab")
        check(ClipboardKeymap.drawer.action(for: commandKey(",", 43, [])) == .settings && ClipboardKeymap.drawer.action(for: commandKey("5", 23, [])) == nil
              && ClipboardKeymap.drawer.action(for: commandKey("4", 21, [])) == nil
              && ClipboardKeymap.drawer.action(for: commandKey("à", 29, [])) == .tab(.all), "\",\" is Settings, 4 and 5 are nothing, and the 0 key is All on any layout")
        // Layouts without Latin letters reach ⌘F by its key, as their ⌘ shortcuts do (plain F is no key since the slash, 2026-10-16);
        // a comma or slash that needs Shift is still itself.
        for (character, code, flags, key) in [("а", UInt16(3), NSEvent.ModifierFlags.command, ClipboardBrowserAction.find), ("φ", 3, [.command], .find), ("/", 44, [], .find), ("/", 26, [.shift], .find),
                                              (",", 44, [.shift], .settings), (",", 22, [.shift], .settings)] {
            check(ClipboardKeymap.drawer.action(for: commandKey(character, code, flags)) == key, "\(flags) \(character) on key \(code) is \(key)")
        }
        // Where the F key types another Latin letter (Dvorak's u), F is the key that types it.
        check(ClipboardKeymap.drawer.action(for: commandKey("u", 3, [])) == nil, "Dvorak's u, on the F key's place, is no drawer key")
        // The keypad's 0–3 choose the tabs as the top row's do.
        check([82, 83, 84, 85].map { ClipboardKeymap.drawer.action(for: commandKey(String($0 - 82), UInt16($0), [])) } == ClipboardBrowserTab.allCases.map { .tab($0) },
              "the keypad's 0–3 choose the tabs")
        // ⌘O is exactly ⌘ in the drawer, as in the window.
        opened = nil
        browser.canvas.keyDown(with: commandKey("o", 31, [.option, .command]))
        browser.canvas.keyDown(with: commandKey("o", 31, [.control, .command]))
        check(opened == nil && ClipboardKeymap.drawer.action(for: commandKey("o", 31, [.shift, .command])) == nil, "⌥⌘O, ⌃⌘O and ⇧⌘O do not open Preview from the drawer's cards")
        browser.canvas.keyDown(with: commandKey("o", 31, [.command]))
        check(opened == browser.canvas.selected?.entry.id, "⌘O does")
        // The drawer deletes with ⌫, ⌦ and ⌘⌫, and nothing else held.
        deleted = nil
        for (code, flags) in [(UInt16(51), NSEvent.ModifierFlags.option), (51, .shift), (51, .control), (51, [.shift, .command]), (117, .option), (117, .command)] {
            browser.canvas.keyDown(with: commandKey("\u{7F}", code, flags))
        }
        check(deleted == nil, "⌥⌫, ⇧⌫, ⌃⌫, ⇧⌘⌫, ⌥⌦ and ⌘⌦ do not delete from the drawer's cards")
        for (code, flags) in [(UInt16(51), NSEvent.ModifierFlags()), (117, []), (51, .command)] {
            deleted = nil
            browser.canvas.keyDown(with: commandKey("\u{7F}", code, flags))
            check(deleted == browser.canvas.selected?.entry.id, "\(code == 117 ? "⌦" : flags.isEmpty ? "⌫" : "⌘⌫") asks to delete the chosen card")
        }
        browser.search.stringValue = ""
        browser.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        for (character, code, tab) in [("2", UInt16(19), ClipboardBrowserTab.images), ("3", 20, .other), ("1", 18, .text), ("0", 29, .all)] {
            browser.canvas.keyDown(with: commandKey(character, code, []))
            check(browser.currentTab == tab && browser.tabs.selectedSegment == tab.rawValue, "\(character) from the cards shows \(tab.title)")
        }
        check(ClipboardTileTooltip.groups(.drawer, asker: nil)[1].map { "\($0.0) ← \($0.1)" } == ["Search ← /", "Tabs ← 0–3", "Settings ← ,"], "the card's info lists the drawer's single keys")

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
        // Where a container's keyboard rests decides whether its cards take it; there is nothing else
        // to set (Al, 2026-10-11: differences between containers only as injected enums or functions).
        check(ClipboardCanvas(keymap: .drawer, home: .tiles).acceptsFirstResponder && !ClipboardCanvas(keymap: .window, home: .search).acceptsFirstResponder,
              "cards whose container keeps the keyboard on them take it; where its search keeps it, they refuse it")
        check(browser.canvas.acceptsFirstResponder && !ClipboardBrowserList(keymap: .window, home: .search, tooltips: .none, indexing: .appendedToCount).canvas.acceptsFirstResponder,
              "so the drawer's cards take the keyboard and the window's rows never do")
        // A step past an end stops there (the arrows), or goes round to the other end (the window's shortcut).
        let rows = ClipboardCanvas(keymap: .window, home: .search)
        rows.tiles = ["1", "2", "3"].map { ClipboardTile(entry: entry($0), style: .compact, keymap: .window) }
        rows.tiles.forEach(rows.addSubview)
        rows.reconcile(liftedID: nil)
        rows.choose(rows.tiles[2].entry.id)
        check(rows.step(.older, ends: .stop) && rows.selected === rows.tiles[2], "an arrow stops at the last row")
        check(rows.step(.older, ends: .wrap) && rows.selected === rows.tiles[0], "going round from the last row reaches the first")
        check(rows.step(.newer, ends: .wrap) && rows.selected === rows.tiles[2], "and back round to the last")
        check(rows.step(.newer) && rows.selected === rows.tiles[1], "a step stops at the ends unless told to go round")
        print("PASS: \(assertions) browser assertions")
    }
}
