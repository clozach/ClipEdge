import AppKit

/// History kept by storage (Al, 2026-10-16): the store folder on disk, the move from the old single
/// file, the budget of 1% of free space, the ceiling, a picture's text read once, and the floppy
/// warning in both containers. Temporary folders, named boards and made-up bytes only; the disk's
/// size and free space are the tests' own.
@main enum StorageTests {
    static var count = 0
    static func check(_ value: @autoclosure () -> Bool, _ why: String) { count += 1; guard value() else { fatalError("FAIL: \(why)") } }
    static func spin(_ seconds: TimeInterval = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    typealias Values = [(type: NSPasteboard.PasteboardType, data: Data)]
    static func record(_ values: Values, _ seconds: Double = 0) -> ClipboardHistoryFile.Record {
        let payloads = [ClipboardPayload(values: values)]
        return ClipboardHistoryFile.Record(fingerprint: ClipboardHistoryFile.fingerprint(for: payloads),
                                           capturedAt: Date(timeIntervalSince1970: 1_790_000_000 + seconds), payloads: payloads)
    }
    static func text(_ words: String) -> Values { [(.string, Data(words.utf8))] }
    static func folder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clipedge-storage-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func picture(_ hue: CGFloat) -> Data {
        NSImage(size: NSSize(width: 60, height: 40), flipped: false) { rect in
            NSColor(hue: hue, saturation: 0.5, brightness: 0.8, alpha: 1).setFill(); rect.fill(); return true
        }.tiffRepresentation!
    }

    static func main() {
        _ = NSApplication.shared
        storeFolder()
        oldFileMoves()
        budget()
        trimming()
        pictureText()
        launchTime()
        rowsNearView()
        warning()
        print("PASS: \(count) storage assertions; temporary folders, named boards, made-up bytes and disk sizes")
    }

    /// One folder per item, written once; the index lists them; what is no longer listed goes.
    static func storeFolder() {
        let base = folder()
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent("History.plist")
        let a = record(text("Harbor notes"), 2), b = record([(.string, Data("Ferry".utf8)), (.html, Data("<b>Ferry</b>".utf8))], 1)
        check(ClipboardHistoryFile.write([a, b], to: url), "a history saves")
        let store = ClipboardHistoryFile.storeFolder(for: url), fm = FileManager.default
        let itemB = store.appendingPathComponent("Items/\(b.fingerprint)")
        check(store.lastPathComponent == "History.store" && fm.fileExists(atPath: store.appendingPathComponent("Index.plist").path)
              && fm.fileExists(atPath: itemB.appendingPathComponent("0-1").path) && !fm.fileExists(atPath: url.path),
              "into History.store beside the old file's name: an index, and each format's bytes in its item's folder")
        let mode = (try? fm.attributesOfItem(atPath: itemB.appendingPathComponent("0-0").path)[.posixPermissions] as? Int) ?? 0
        check(mode == 0o600, "each file is the person's alone")
        let read = (try? ClipboardHistoryFile.read(url)) ?? nil ?? []
        check(read.map(\.fingerprint) == [a.fingerprint, b.fingerprint] && read.allSatisfy(\.fromStore)
              && read[1].payloads[0].values.map(\.type) == [.string, .html] && read[1].payloads[0].values[1].data == Data("<b>Ferry</b>".utf8),
              "it reads back in order, every format and byte, marked as from the store")
        let big = record([(.tiff, Data(repeating: 7, count: ClipboardHistoryFile.mappedFrom + 10))], 9)
        check(ClipboardHistoryFile.write([big], to: base.appendingPathComponent("Big.plist"))
              && ((try? ClipboardHistoryFile.read(base.appendingPathComponent("Big.plist"))) ?? nil)?.first?.payloads[0].values[0].data == big.payloads[0].values[0].data,
              "a large format, read back mapped, holds every byte")
        let written = (try? fm.attributesOfItem(atPath: itemB.appendingPathComponent("0-0").path)[.modificationDate] as? Date) ?? nil
        spin(1.1)
        let c = record(text("Tide table"), 3)
        check(ClipboardHistoryFile.write([c, a, b], to: url), "a new copy saves")
        let after = (try? fm.attributesOfItem(atPath: itemB.appendingPathComponent("0-0").path)[.modificationDate] as? Date) ?? nil
        check(written != nil && written == after, "an item already on disk is not written again")
        check(ClipboardHistoryFile.write([c, a], to: url) && !fm.fileExists(atPath: itemB.path), "an item no longer listed is removed")
        try? fm.removeItem(at: store.appendingPathComponent("Items/\(a.fingerprint)/0-0"))
        check(((try? ClipboardHistoryFile.read(url)) ?? nil)?.map(\.fingerprint) == [c.fingerprint], "an item whose bytes are missing is left out")
        try? Data("not a list".utf8).write(to: store.appendingPathComponent("Index.plist"))
        check((try? ClipboardHistoryFile.read(url)) == nil, "an unreadable index throws")
        ClipboardHistoryFile.quarantine(url)
        let aside = (try? fm.contentsOfDirectory(atPath: store.path)) ?? []
        check(aside.contains { $0.hasPrefix("Index-corrupt-") } && !aside.contains("Index.plist"), "and is moved aside, not deleted")
        check(!ClipboardHistoryFile.write([record(text("odd"))].map { ClipboardHistoryFile.Record(fingerprint: "../x", capturedAt: $0.capturedAt, payloads: $0.payloads) }, to: url)
              || !fm.fileExists(atPath: store.deletingLastPathComponent().appendingPathComponent("x").path), "a fingerprint never names a folder outside the store")
    }

    /// The old single file is read once; the first save writes the store, and the old file stays.
    static func oldFileMoves() {
        struct Value: Codable { let type: String; let data: Data }
        struct Payload: Codable { let values: [Value] }
        struct Saved: Codable { let fingerprint: String; let capturedAt: Date; let payloads: [Payload] }
        struct Archive: Codable { let version: Int; let entries: [Saved] }
        let base = folder()
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent("History.plist")
        let old = [record(text("Old one"), 2), record(text("Old two"), 1)]
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let archive = Archive(version: 1, entries: old.map { r in
            Saved(fingerprint: r.fingerprint, capturedAt: r.capturedAt, payloads: r.payloads.map { Payload(values: $0.values.map { Value(type: $0.type.rawValue, data: $0.data) }) })
        })
        try! encoder.encode(archive).write(to: url)
        let oldBytes = try! Data(contentsOf: url)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let store = ClipboardStore(pasteboard: board, persistenceURL: url)
        store.measureStorage = { ClipboardStorageBudget(totalBytes: 1_000_000_000_000, freeBytes: 500_000_000_000) }
        store.start()
        store.stop()
        check(store.entries.map(\.title) == ["Old one", "Old two"], "a history from the old file opens")
        let moved = (try? ClipboardHistoryFile.read(url)) ?? nil ?? []
        check(moved.map(\.fingerprint) == old.map(\.fingerprint) && moved.allSatisfy(\.fromStore), "and is saved into its store")
        check((try? Data(contentsOf: url)) == oldBytes, "the old file is left as it was, for an older ClipEdge")
        let again = ClipboardStore(pasteboard: board, persistenceURL: url)
        again.start(); again.stop()
        check(again.entries.map(\.title) == ["Old one", "Old two"], "the next launch reads the store")
    }

    static func budget() {
        let roomy = ClipboardStorageBudget(totalBytes: 4_000_000_000_000, freeBytes: 1_600_000_000_000)
        check(roomy.limit == 16_000_000_000 && !roomy.isLow, "1% of 1.6 TB free is 16 GB, not low")
        let tight = ClipboardStorageBudget(totalBytes: 500_000_000_000, freeBytes: 62_000_000_000)
        check(tight.limit == 620_000_000 && tight.isLow, "1% of 62 GB free is 620 MB, under 1 GB: low")
        check(ClipboardStorageBudget(totalBytes: 1, freeBytes: -5).limit == 0, "no free space is no budget")
        check(ClipboardStorageBudget.measure(at: URL(fileURLWithPath: "/no/such/folder/History.plist")).map { $0.totalBytes > 0 } == true,
              "a folder not made yet is measured on the disk that would hold it")
        let report = ClipboardStorageReport(budget: tight, usedBytes: 412_000_000)
        let shares = report.shares
        check(abs(shares.free - 0.124) < 0.0001 && abs(shares.clipEdge - 0.000824) < 0.000001 && abs(shares.used + shares.clipEdge + shares.free - 1) < 1e-9,
              "the disk in three shares: everything else, ClipEdge's history, free; they add up to the whole")
        let summary = report.summary
        check(summary.contains("500 GB") && summary.contains("438 GB") && summary.contains("88%") && summary.contains("62 GB") && summary.contains("12%")
              && summary.contains("412 MB") && summary.contains("66%") && summary.contains("620 MB"),
              "the numbers behind the bar: the disk, used and free with percentages, ClipEdge's share of the disk and of what it may keep: \(summary)")
        check(ClipboardStorageReport.roundedSize(358_400_000_000) == "358 GB" && ClipboardStorageReport.roundedSize(412_000_000) == "412 MB"
              && ClipboardStorageReport.roundedSize(999_000_000) == "1 GB" && ClipboardStorageReport.roundedSize(499_000_000) == "499 MB",
              "sizes round to whole GB, or whole MB under 1 GB")
        check(ClipboardStorageReport.roundedPercent(0.172) == "17%" && ClipboardStorageReport.roundedPercent(0.000824) == "0.08%"
              && ClipboardStorageReport.roundedPercent(0.006) == "0.6%" && ClipboardStorageReport.roundedPercent(0) == "0%"
              && ClipboardStorageReport.roundedPercent(0.00000005) == "<0.01%" && ClipboardStorageReport.roundedSize(12) == "<1 MB",
              "shares read as a whole percent, or finer under 1%")
        check(report.usage.used == "438 GB | 88%" && report.usage.clipEdge == "412 MB | 0.08%" && report.usage.free == "62 GB | 12%",
              "each part's usage: \(report.usage)")
        let full = ClipboardStorageReport(budget: ClipboardStorageBudget(totalBytes: 100, freeBytes: 0), usedBytes: 500).shares
        check(full.free == 0 && full.clipEdge == 1 && full.used == 0, "shares never pass the whole, whatever the numbers say")
    }

    /// The oldest go once the history is past its budget or the ceiling; the newest always stays.
    static func trimming() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let store = ClipboardStore(pasteboard: board, persistenceURL: nil)
        let free: Int64 = 100_000  // 1,000 bytes of budget
        store.measureStorage = { ClipboardStorageBudget(totalBytes: 1_000_000, freeBytes: free) }
        var removed: [String] = []
        store.onRemove = { removed.append($0.title) }
        func copy(_ words: String) { board.clearContents(); board.setString(words, forType: .string); _ = store.saveNow(); store.cancelStaging() }
        let block = String(repeating: "x", count: 390)
        for name in ["A", "B", "C"] { copy(name + block) }
        check(store.entries.count == 2 && store.usedBytes <= 1_000 && removed.count == 1 && removed[0].hasPrefix("A"),
              "three 391-byte copies in a 1,000-byte budget keep the newest two (\(store.usedBytes) bytes)")
        copy("D" + String(repeating: "y", count: 3_000))
        check(store.entries.count == 1 && store.entries[0].title.hasPrefix("D"), "a copy larger than the whole budget still stays, alone")
        store.stop()
        // The budget is read at most once a minute: a roomy one, from a fresh store.
        let roomy = ClipboardStore(pasteboard: board, persistenceURL: nil)
        roomy.measureStorage = { ClipboardStorageBudget(totalBytes: 4_000_000_000_000, freeBytes: 1_600_000_000_000) }
        roomy.itemCeiling = 30
        for n in 0..<35 {
            board.clearContents(); board.setString("Item \(n)", forType: .string); _ = roomy.saveNow(); roomy.cancelStaging()
        }
        check(roomy.entries.count == 30 && roomy.entries[0].title == "Item 34", "however roomy the budget, the item ceiling holds")
        check(ClipboardStore(pasteboard: board, persistenceURL: nil).itemCeiling == 20_000, "a safety ceiling of 20,000 items, as measured")
        roomy.stop()
    }

    /// A picture's text is read once and kept with its item; the next launch does not read it again.
    static func pictureText() {
        let base = folder()
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent("History.plist")
        var reads = 0
        let indexer = ClipboardSearchIndexer(environment: .init(fileText: { _ in nil }, recognize: { _ in reads += 1; return "Ferry at noon" }))
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let store = ClipboardStore(pasteboard: board, persistenceURL: url, searchIndexer: indexer)
        store.start()
        board.clearContents(); board.setData(picture(0.3), forType: .tiff); _ = store.saveNow(); store.cancelStaging()
        let deadline = Date().addingTimeInterval(5)
        while store.entries.first?.recognizedText != "Ferry at noon", Date() < deadline { spin() }
        store.stop()
        check(reads == 1 && store.entries[0].recognizedText == "Ferry at noon", "a copied picture's text is read")
        let fingerprint = store.entries[0].fingerprint
        check(ClipboardHistoryFile.savedText(of: fingerprint, in: url) == "Ferry at noon", "and kept beside its item")
        let reopened = ClipboardStore(pasteboard: board, persistenceURL: url, searchIndexer: indexer)
        reopened.start()
        check(reopened.entries.first?.recognizedText == "Ferry at noon" && reads == 1, "the next launch finds it without reading the picture again")
        reopened.stop()
    }

    /// A full history, 1,000 items (every fourth a picture, its text already kept), opens quickly:
    /// nothing is hashed, read or recognized again at launch.
    static func launchTime() {
        let base = folder()
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent("History.plist")
        let records = (0..<1_000).map { n -> ClipboardHistoryFile.Record in
            let hue = CGFloat(n) / 1_000
            let values: Values = n % 4 == 0 ? [(.tiff, picture(hue))] : text("Fixture item \(n) with a few words")
            return record(values, Double(n))
        }
        let written = Date()
        check(ClipboardHistoryFile.write(records, to: url), "a full history saves")
        let writeSeconds = Date().timeIntervalSince(written)
        for r in records where r.payloads[0].values[0].type == .tiff { ClipboardHistoryFile.saveText("Fixture text", of: r.fingerprint, in: url) }
        var reads = 0
        let indexer = ClipboardSearchIndexer(environment: .init(fileText: { _ in nil }, recognize: { _ in reads += 1; return "" }))
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let store = ClipboardStore(pasteboard: board, persistenceURL: url, searchIndexer: indexer)
        store.measureStorage = { ClipboardStorageBudget(totalBytes: 4_000_000_000_000, freeBytes: 1_600_000_000_000) }
        let started = Date()
        store.start()
        let seconds = Date().timeIntervalSince(started)
        spin(0.2)
        check(store.entries.count == 1_000 && reads == 0, "all \(store.entries.count) open, no picture read again (\(reads))")
        check(seconds < 2, "in under 2 seconds (\(String(format: "%.2f", seconds)) s; the save took \(String(format: "%.2f", writeSeconds)) s)")
        print("launch of 1,000 items: \(String(format: "%.2f", seconds)) s; first save \(String(format: "%.2f", writeSeconds)) s")
        board.clearContents(); board.setString("One more", forType: .string)
        let copied = Date()
        _ = store.saveNow()
        print("a copy's save with \(store.entries.count) items: \(String(format: "%.3f", Date().timeIntervalSince(copied))) s")
        store.stop()
    }

    /// Thousands of rows: only those within a screen of what shows are in the view tree, so the
    /// list opens and moves quickly; scrolling and the arrows bring the rest in as they arrive.
    static func rowsNearView() {
        let entries: [ClipboardEntry] = (0..<3_000).map { n in
            let words: Values = text("Fixture row \(n) with a few words")
            return ClipboardHistoryFile.entry(record(words, Double(-n)))
        }
        let drawer = ClipboardBrowserView(frame: NSRect(x: 0, y: 0, width: 390, height: 700))
        let started = Date()
        drawer.update(entries: entries, attachedID: nil)
        drawer.layoutSubtreeIfNeeded()
        let seconds = Date().timeIntervalSince(started)
        let canvas = drawer.canvas
        let attached = canvas.tiles.filter(canvas.isAttached)
        check(canvas.tiles.count == 3_000 && attached.count < 40 && attached.contains(canvas.tiles[0]) && !canvas.isAttached(canvas.tiles[2_999]),
              "3,000 rows, \(attached.count) of them built near the top (in \(String(format: "%.2f", seconds)) s)")
        check(seconds < 1, "the drawer opens 3,000 rows in under a second")
        // Rebuilt while the drawer is still slid out of its window (it opens from closed), the rows the
        // scroll view shows are still built: where the window is never decides (2026-10-16, one row of 94).
        let small = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 28, height: 40), styleMask: [.borderless], backing: .buffered, defer: true)
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 28, height: 40))
        small.contentView = holder
        holder.addSubview(drawer)
        drawer.frame.origin.x = 40
        canvas.attachVisible()
        let shownInSmall = canvas.tiles.filter(canvas.isAttached).count
        check(shownInSmall > 5, "a drawer slid out of its window still has every shown row built (\(shownInSmall))")
        drawer.removeFromSuperview()
        canvas.chooseByKey(canvas.tiles[2_999].entry.id)
        check(canvas.selectedID == canvas.tiles[2_999].entry.id && canvas.isAttached(canvas.tiles[2_999]) && !canvas.isAttached(canvas.tiles[0]),
              "choosing the last row scrolls to it and builds it; the top row goes dormant")
        let last = entries[2_999], fifth = entries[5]
        let lastLabel = canvas.tiles[2_999].accessibilityLabel() ?? "", fifthLabel = canvas.tiles[5].accessibilityLabel() ?? ""
        check(lastLabel == "\(last.title), copied \(last.fullDateTimeStamp)" && fifthLabel.hasPrefix(fifth.title), "every row, built or dormant, says what it is")
    }

    /// 💾⚠️ before the count, in the drawer and the window, while the budget is under 1 GB.
    static func warning() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let store = ClipboardStore(pasteboard: board, persistenceURL: nil)
        var free: Int64 = 1_600_000_000_000
        store.measureStorage = { ClipboardStorageBudget(totalBytes: 4_000_000_000_000, freeBytes: free) }
        board.clearContents(); board.setString("Harbor notes", forType: .string); _ = store.saveNow(); store.cancelStaging()
        let browser = ClipboardBrowserView(frame: NSRect(x: 0, y: 0, width: 390, height: 600))
        browser.list.storageReport = { store.storageReport }
        browser.update(entries: store.entries, attachedID: nil)
        browser.layoutSubtreeIfNeeded()
        let line = browser.list.countLine
        check(line.storage.isHidden && line.storageWidth == 0, "with room to spare there is no warning")
        // The budget is read at most once a minute: a tight one, from a fresh store.
        free = 62_000_000_000
        let fresh = ClipboardStore(pasteboard: board, persistenceURL: nil)
        fresh.measureStorage = { ClipboardStorageBudget(totalBytes: 500_000_000_000, freeBytes: free) }
        browser.list.storageReport = { fresh.storageReport }
        browser.update(entries: store.entries, attachedID: nil)
        browser.layoutSubtreeIfNeeded()
        check(!line.storage.isHidden && line.storage.frame.maxX <= line.count.frame.minX && line.note.frame.maxX <= line.storage.frame.minX,
              "under 1 GB the floppy shows just before the count, the Quick Look note making room (\(line.storage.frame), \(line.count.frame))")
        check(line.storage.detailText.contains("62 GB") && line.storage.accessibilityLabel() == ClipboardStorageReport.heading
              && line.storage.accessibilityHelp()?.contains("Free up space") == true, "it carries the numbers, and VoiceOver hears them")
        let window = ClipboardHistoryView(frame: NSRect(x: 0, y: 0, width: 800, height: 470))
        window.list.storageReport = { fresh.storageReport }
        window.update(entries: store.entries)
        window.layoutSubtreeIfNeeded()
        let windowLine = window.list.countLine
        check(!windowLine.storage.isHidden && windowLine.storage.frame.minX == 18 && windowLine.count.frame.minX >= windowLine.storage.frame.maxX,
              "in the window it starts the count line, the count after it (\(windowLine.storage.frame), \(windowLine.count.frame))")
        // The hover's popover is not opened here (it would appear on the screen); its content is
        // laid out as the popover would size it: heading, bar, then what to do, all whole.
        let content = line.storage.detailContent
        content.setFrameSize(content.fittingSize)
        content.layoutSubtreeIfNeeded()
        let fields = content.subviews.compactMap { $0 as? NSTextField }
        let advice = fields.first { $0.stringValue == ClipboardStorageReport.advice }!
        let needed = advice.attributedStringValue.boundingRect(with: NSSize(width: ClipboardStorageDetail.width, height: 1_000), options: .usesLineFragmentOrigin).height
        let bar = line.storage.bar
        check(fields.map(\.stringValue) == [ClipboardStorageReport.heading, ClipboardStorageReport.advice] && bar.frame.width == ClipboardStorageDetail.width
              && bar.frame.minY >= advice.frame.maxY - 0.5,  // the stack runs top down in unflipped points
              "the popover holds the heading, the bar, then what to do (\(bar.frame), \(advice.frame))")
        check(advice.frame.height >= needed - 0.5, "what to do shows whole (\(advice.frame.height) for \(needed))")
        check(bar.toolTip == fresh.storageReport?.summary && bar.accessibilityValue() as? String == bar.toolTip, "the bar's numbers are its tooltip and VoiceOver's")
        bar.layoutSubtreeIfNeeded()
        let parts = bar.parts, labels = bar.labelFrames
        check(parts.used.minX == parts.bar.minX && parts.clipEdge.minX == parts.used.maxX && parts.free.minX == parts.clipEdge.maxX
              && abs(parts.free.maxX - parts.bar.maxX) < 0.01 && parts.clipEdge.width == ClipboardStorageBar.sliver,
              "used, then ClipEdge's half-point sliver (412 MB of 500 GB), then free, filling the bar (\(parts))")
        let words = bar.labels
        check(words.used.string == "Used · 438 GB | 88%" && words.free.string == "Free · 62 GB | 12%" && words.clipEdge.string == "ClipEdge · 0 MB | 0%",
              "each label is its name, then its size and share: \(words.used.string), \(words.free.string), \(words.clipEdge.string)")
        let faded = words.used.attribute(.foregroundColor, at: words.used.length - 1, effectiveRange: nil) as? NSColor
        check(faded?.alphaComponent == ClipboardStorageBar.usageAlpha && (words.used.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?.alphaComponent == 1,
              "the name in full color, its usage fainter")
        let width = ClipboardStorageDetail.width
        check(abs(parts.free.width - width * 0.124) < 0.5 && labels.used.maxY <= parts.bar.minY && labels.free.maxY <= parts.bar.minY
              && labels.clipEdge.minY >= parts.bar.maxY && abs(labels.used.midX - parts.used.midX) < 0.5
              && labels.free.maxX <= width + 0.5 && labels.clipEdge.maxX <= width + 0.5 && !labels.used.intersects(labels.free)
              && abs(labels.used.width - ceil(words.used.size().width)) < 0.5,
              "Used centered as one (name and usage) over its part; Free and ClipEdge kept whole inside the bar, never over each other (\(labels))")
        let crowded = ClipboardStorageBar(frame: NSRect(x: 0, y: 0, width: ClipboardStorageDetail.width, height: 44))
        crowded.report = ClipboardStorageReport(budget: ClipboardStorageBudget(totalBytes: 100, freeBytes: 99), usedBytes: 0)
        let edge = crowded.labelFrames
        check(edge.used.minX >= 0 && edge.clipEdge.minX >= 0 && edge.free.maxX <= ClipboardStorageDetail.width && !edge.used.intersects(edge.free),
              "a part too narrow for its label keeps the label whole, inside the bar's width, never over the other (\(edge))")
        // The count shows the same bar on hover, with no heading or advice, whatever the free space.
        let count = line.count
        check(count.report == fresh.storageReport && count.bar.report == fresh.storageReport, "the count carries the same report")
        let countFields = count.detailContent.subviews.compactMap { $0 as? NSTextField }
        check(countFields.map(\.stringValue) == [ClipboardStorageDetail.usageHeading] && count.detailContent.subviews.contains { $0 === count.bar },
              "its popover is headed Disk usage, then the bar, with no advice")
        count.detailContent.setFrameSize(count.detailContent.fittingSize)
        count.detailContent.layoutSubtreeIfNeeded()
        check(count.bar.frame.minX >= 13.5 && count.detailContent.bounds.width - count.bar.frame.maxX >= 13.5,
              "the bar keeps 14 points of padding either side (\(count.bar.frame) in \(count.detailContent.bounds))")
        let roomyLine = ClipboardBrowserView(frame: NSRect(x: 0, y: 0, width: 390, height: 600))
        roomyLine.list.storageReport = { store.storageReport }
        roomyLine.update(entries: store.entries, attachedID: nil)
        check(roomyLine.list.countLine.count.report != nil && roomyLine.list.countLine.storage.isHidden, "with room to spare the count still has its bar; only the floppy hides")
    }
}
