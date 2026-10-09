import AppKit

/// Isolated referenced-file fixtures. No general clipboard, user archive,
/// preferences, preview windows, or application lifecycle are involved.
@main enum FileInspectionTests {
    private static var assertions = 0
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError("FAIL: \(message)") }
    }
    private static func awaitResult(_ message: String, timeout: TimeInterval = 4,
                                    _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        check(condition(), message)
    }
    private static func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    private static func payloads(_ urls: [URL]) -> [ClipboardPayload] {
        urls.map { ClipboardPayload(values: [(.fileURL, Data($0.absoluteString.utf8))]) }
    }
    private static func copy(_ urls: [URL], to board: NSPasteboard, store: ClipboardStore) {
        let items = urls.map { url -> NSPasteboardItem in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            return item
        }
        board.clearContents()
        check(board.writeObjects(items), "fixture file URLs reach a named pasteboard")
        check(store.saveNow(), "synthetic file payload is captured and saved")
    }
    private static func image(_ width: Int, _ height: Int) -> (NSImage, CGImage, Data) {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        // Fill every byte so the test fixture does not contain uninitialized memory.
        bitmap.bitmapData!.initialize(repeating: 255, count: bitmap.bytesPerRow * height)
        let pixels = bitmap.cgImage!
        return (NSImage(cgImage: pixels, size: NSSize(width: width, height: height)), pixels,
                bitmap.representation(using: .png, properties: [:])!)
    }
    private static func inertIndexer() -> ClipboardSearchIndexer {
        ClipboardSearchIndexer(environment: .init(fileText: { _ in nil }, recognize: { _ in "" }))
    }
    private static func inertInspector(_ icon: NSImage) -> ClipboardFileInspector {
        ClipboardFileInspector(environment: .init(
            metadata: { ClipboardMetadata(paths: $0.map(\.path)) }, fullImage: { _ in nil },
            icon: { _ in icon }, thumbnail: { _, done in done(nil) }))
    }

    static func main() throws {
        check(Thread.isMainThread, "fixtures run from the main thread")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ClipEdge-file-inspection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (icon, _, _) = image(16, 16)
        let (thumbnail, _, _) = image(32, 24)
        let (fullPreview, fullPixels, png) = image(2304, 2112)
        let readable = root.appendingPathComponent("readable.png")
        try png.write(to: readable)
        try verifyIndependentWork(root, icon: icon, fullPreview: fullPreview, fullPixels: fullPixels)
        verifyFullResolution(readable, icon: icon)
        verifyEmbeddedImages(png)
        try verifyFallbacks(root, icon: icon, thumbnail: thumbnail)
        verifyMultipleFiles(root, icon: icon)
        verifyStartup(root, icon: icon, fullPreview: fullPreview, fullPixels: fullPixels)
        verifySearchGeneration(root, icon: icon, fullPreview: fullPreview, fullPixels: fullPixels)
        verifyRemovedCallbacks(root, icon: icon, fullPreview: fullPreview, fullPixels: fullPixels)
        verifyReplacedCallbacks(root, icon: icon, fullPreview: fullPreview, fullPixels: fullPixels)
        print("PASS: \(assertions) asynchronous file-inspection assertions; named pasteboards and temporary fixtures only")
    }

    private static func verifyIndependentWork(_ root: URL, icon: NSImage,
                                              fullPreview: NSImage, fullPixels: CGImage) throws {
        let slow = root.appendingPathComponent("slow.png")
        let fast = root.appendingPathComponent("fast.txt")
        try Data("fixture".utf8).write(to: fast)
        let metadataGate = InspectionGate(), imageGate = InspectionGate()
        defer { metadataGate.open(); imageGate.open() }
        let threads = InspectionBox((workOffMain: true, callbacksOnMain: true, thumbnails: 0))
        let inspector = ClipboardFileInspector(environment: .init(
            metadata: { urls in
                threads.update { $0.workOffMain = $0.workOffMain && !Thread.isMainThread }
                if urls.first == slow { metadataGate.block() }
                return ClipboardMetadata(facts: ["fixture facts"], paths: urls.map(\.path))
            }, fullImage: { _ in
                threads.update { $0.workOffMain = $0.workOffMain && !Thread.isMainThread }
                imageGate.block()
                return .init(preview: fullPreview, pixels: fullPixels)
            }, icon: { _ in
                threads.update { $0.workOffMain = $0.workOffMain && !Thread.isMainThread }
                return icon
            }, thumbnail: { _, done in
                threads.update { $0.workOffMain = $0.workOffMain && !Thread.isMainThread; $0.thumbnails += 1 }
                done(nil)
            }))
        var slowFacts = false, slowImage = false, fastFacts = false, fastPreview = false
        let started = ProcessInfo.processInfo.systemUptime
        inspector.inspect([slow], facts: { _ in
            threads.update { $0.callbacksOnMain = $0.callbacksOnMain && Thread.isMainThread }
            slowFacts = true
        }, preview: { preview in
            threads.update { $0.callbacksOnMain = $0.callbacksOnMain && Thread.isMainThread }
            if case .image = preview { slowImage = true }
        })
        check(ProcessInfo.processInfo.systemUptime - started < 1, "inspection returns before a slow file read")
        awaitResult("metadata and image loader start independently") { metadataGate.started && imageGate.started }
        inspector.inspect([fast], facts: { _ in
            threads.update { $0.callbacksOnMain = $0.callbacksOnMain && Thread.isMainThread }
            fastFacts = true
        }, preview: { _ in
            threads.update { $0.callbacksOnMain = $0.callbacksOnMain && Thread.isMainThread }
            fastPreview = true
        })
        awaitResult("an unrelated inspection finishes while both slow reads wait") { fastFacts && fastPreview }
        check(!slowFacts && !slowImage, "blocked fixture has not completed either read")
        imageGate.open()
        awaitResult("image preview arrives while metadata still waits") { slowImage }
        check(!slowFacts, "image preview does not depend on metadata completion")
        metadataGate.open()
        awaitResult("metadata eventually arrives independently") { slowFacts }
        let result = threads.read { $0 }
        check(result.workOffMain, "metadata, image, icon, and thumbnail work run off main")
        check(result.callbacksOnMain, "all inspector callbacks return on main")
        check(result.thumbnails == 1, "full image success bypasses Quick Look")
        check(!metadataGate.timedOut && !imageGate.timedOut, "controlled reads were released before their bounds")
    }

    private static func verifyFullResolution(_ readable: URL, icon: NSImage) {
        let summary = ClipboardSummary.make(from: payloads([readable]))
        check(summary.kind == .file, "even a readable image starts as a file until inspection confirms decoding")
        let calls = InspectionBox((icons: 0, thumbnails: 0))
        let inspector = ClipboardFileInspector(environment: .init(
            metadata: { ClipboardMetadata(paths: $0.map(\.path)) }, icon: { _ in
                calls.update { $0.icons += 1 }; return icon
            }, thumbnail: { _, done in
                calls.update { $0.thumbnails += 1 }; done(nil)
            }))
        var loaded: ClipboardFileInspector.FullImage?
        var factsArrived = false, callbacksOnMain = true
        inspector.inspect([readable], facts: { _ in
            callbacksOnMain = callbacksOnMain && Thread.isMainThread; factsArrived = true
        }, preview: { preview in
            callbacksOnMain = callbacksOnMain && Thread.isMainThread
            if case .image(let value) = preview { loaded = value }
        })
        awaitResult("the real loader decodes a readable large image") { loaded != nil && factsArrived }
        check(loaded?.pixels?.width == 2304 && loaded?.pixels?.height == 2112,
              "OCR pixels retain the complete image beyond Quick Look's size")
        let displayPixels = loaded?.preview.cgImage(forProposedRect: nil, context: nil, hints: nil)
        check(displayPixels?.width == 2304 && displayPixels?.height == 2112,
              "preview retains full image resolution")
        check(calls.read { $0.icons == 0 && $0.thumbnails == 0 },
              "a decoded image does not request an icon or smaller Quick Look replacement")
        check(callbacksOnMain, "default loader also delivers results on main")
    }

    private static func verifyEmbeddedImages(_ png: Data) {
        var mediaBox = CGRect(x: 0, y: 0, width: 64, height: 32)
        let data = NSMutableData()
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(mediaBox)
        context.endPDFPage()
        context.closePDF()
        let fixtures: [[ClipboardPayload]] = [
            [ClipboardPayload(values: [(.pdf, data as Data)])],
            [ClipboardPayload(values: [(.png, Data([0, 1, 2])), (.tiff, png)])]
        ]
        for (index, payload) in fixtures.enumerated() {
            let summary = ClipboardSummary.make(from: payload)
            check(summary.kind == .image && summary.thumbnail != nil,
                  "embedded fixture \(index) keeps its existing image classification")
            let entry = ClipboardEntry(fingerprint: "embedded-\(index)", capturedAt: Date(), payloads: payload,
                                       title: summary.title, detail: summary.detail, kind: summary.kind, thumbnail: summary.thumbnail)
            let observed = InspectionBox((fileCalls: 0, recognitions: 0, offMain: true))
            let indexer = ClipboardSearchIndexer(environment: .init(fileText: { _ in
                observed.update { $0.fileCalls += 1 }; return nil
            }, recognize: { pixels in
                observed.update { $0.recognitions += 1; $0.offMain = $0.offMain && !Thread.isMainThread }
                return "embedded \(pixels.width)"
            }))
            var result: ClipboardSearchState?, completionOnMain = false
            indexer.index(entry) { result = $0; completionOnMain = Thread.isMainThread }
            awaitResult("embedded fixture \(index) indexing completes") { result != nil }
            if case .ready(let text) = result { check(text.hasPrefix("embedded "), "embedded fixture \(index) still receives OCR") }
            else { check(false, "embedded fixture \(index) still receives OCR") }
            check(observed.read { $0.fileCalls == 0 && $0.recognitions == 1 && $0.offMain } && completionOnMain,
                  "embedded fixture \(index) indexes its in-memory pixels without referenced-file reads")
        }
    }

    private static func verifyFallbacks(_ root: URL, icon: NSImage, thumbnail: NSImage) throws {
        let corrupt = root.appendingPathComponent("corrupt.png")
        let missing = root.appendingPathComponent("missing.png")
        let note = root.appendingPathComponent("note.txt")
        try Data("not an image".utf8).write(to: corrupt)
        try Data("plain text fixture".utf8).write(to: note)
        let calls = InspectionBox((fullImages: [URL](), icons: [URL](), thumbnails: [URL](), offMain: true))
        let loadImage = ClipboardFileInspector.Environment().fullImage
        let inspector = ClipboardFileInspector(environment: .init(fullImage: { url in
            calls.update { $0.fullImages.append(url); $0.offMain = $0.offMain && !Thread.isMainThread }
            return loadImage(url)
        }, icon: { url in
            calls.update { $0.icons.append(url); $0.offMain = $0.offMain && !Thread.isMainThread }
            return icon
        }, thumbnail: { url, done in
            calls.update { $0.thumbnails.append(url); $0.offMain = $0.offMain && !Thread.isMainThread }
            done(thumbnail)
        }))
        let board = NSPasteboard.withUniqueName()
        let store = ClipboardStore(pasteboard: board, fileInspector: inspector, searchIndexer: inertIndexer())
        defer { store.stop(); board.releaseGlobally() }
        for url in [corrupt, missing, note] { copy([url], to: board, store: store) }
        awaitResult("corrupt, missing, and nonimage fixtures receive fallback thumbnails") {
            store.entries.count == 3 && store.entries.allSatisfy { $0.thumbnail === thumbnail }
        }
        check(store.entries.allSatisfy { $0.kind == .file && !$0.isImage },
              "failed image decodes and a text file stay in Files after Quick Look")
        check(Set(calls.read { $0.icons }) == Set([corrupt, missing, note]), "every fallback retains a file icon first")
        check(Set(calls.read { $0.thumbnails }) == Set([corrupt, missing, note]), "each single-file fallback requests Quick Look")
        check(Set(calls.read { $0.fullImages }) == Set([corrupt, missing]),
              "corrupt and missing images attempt real decoding; nonimage files bypass image reads")
        check(calls.read { $0.offMain }, "fallback icon and thumbnail creation stay off main")
        awaitResult("missing fixture facts arrive") {
            store.entries.first { $0.fileURLs == [missing] }?.metadata.facts == ["File not found"]
        }
    }

    private static func verifyMultipleFiles(_ root: URL, icon: NSImage) {
        let urls = [root.appendingPathComponent("first.png"), root.appendingPathComponent("second.png")]
        let calls = InspectionBox((icons: [URL](), fullImages: 0, thumbnails: 0))
        let inspector = ClipboardFileInspector(environment: .init(
            metadata: { ClipboardMetadata(facts: ["2 items"], paths: $0.map(\.path)) },
            fullImage: { _ in calls.update { $0.fullImages += 1 }; return nil },
            icon: { url in calls.update { $0.icons.append(url) }; return icon },
            thumbnail: { _, done in calls.update { $0.thumbnails += 1 }; done(nil) }))
        var facts: ClipboardMetadata?, previews = 0
        inspector.inspect(urls, facts: { facts = $0 }, preview: { preview in
            previews += 1
            if case .icon(let value) = preview { check(value === icon, "multiple files use the first file icon") }
            else { check(false, "multiple files do not become one image") }
        })
        awaitResult("multiple-file metadata and icon arrive") { facts != nil && previews == 1 }
        check(facts?.paths == urls.map(\.path), "multiple-file metadata retains every path")
        check(calls.read { $0.icons == [urls[0]] && $0.fullImages == 0 && $0.thumbnails == 0 },
              "multiple files request one icon without image decoding or Quick Look")
    }

    private static func writeFixtureHistory(_ urls: [URL], to history: URL, icon: NSImage) {
        let board = NSPasteboard.withUniqueName()
        let store = ClipboardStore(pasteboard: board, persistenceURL: history,
                                   fileInspector: inertInspector(icon), searchIndexer: inertIndexer())
        copy(urls, to: board, store: store)
        store.stop()
        board.releaseGlobally()
    }

    private static func verifyStartup(_ root: URL, icon: NSImage, fullPreview: NSImage, fullPixels: CGImage) {
        let url = root.appendingPathComponent("startup.png")
        let history = root.appendingPathComponent("StartupHistory.plist")
        writeFixtureHistory([url], to: history, icon: icon)
        let gate = InspectionGate()
        defer { gate.open() }
        let inspector = ClipboardFileInspector(environment: .init(
            metadata: { ClipboardMetadata(facts: ["startup facts"], paths: $0.map(\.path)) },
            fullImage: { _ in gate.block(); return .init(preview: fullPreview, pixels: fullPixels) },
            icon: { _ in icon }, thumbnail: { _, done in done(nil) }))
        let board = NSPasteboard.withUniqueName()
        let store = ClipboardStore(pasteboard: board, persistenceURL: history,
                                   fileInspector: inspector, searchIndexer: inertIndexer())
        defer { store.stop(); board.releaseGlobally() }
        let summaryStarted = ProcessInfo.processInfo.systemUptime
        let summary = ClipboardSummary.make(from: payloads([url]))
        check(summary.kind == .file && ProcessInfo.processInfo.systemUptime - summaryStarted < 1,
              "file summary returns a file placeholder without reading image contents")
        let started = ProcessInfo.processInfo.systemUptime
        store.start()
        check(ProcessInfo.processInfo.systemUptime - started < 1,
              "persisted-history startup returns before referenced image loading")
        check(store.entries.count == 1 && store.entries[0].kind == .file,
              "startup immediately publishes a file placeholder")
        awaitResult("startup image load begins in the background") { gate.started }
        awaitResult("startup metadata is independent of the blocked image") {
            store.entries[0].metadata.facts == ["startup facts"]
        }
        board.clearContents(); board.setString("unrelated fixture copy", forType: .string)
        check(store.saveNow() && store.entries.first?.plainText == "unrelated fixture copy",
              "the store captures an unrelated copy while image loading waits")
        gate.open()
        awaitResult("loaded history image is promoted after decoding") { store.entries.contains { $0.fileURLs == [url] && $0.isImage } }
        let loaded = store.entries.first { $0.fileURLs == [url] }!
        check(loaded.thumbnail === fullPreview && loaded.fileURLs == [url],
              "image promotion preserves the file payload and full preview")
        check(!gate.timedOut, "startup fixture was explicitly released")
    }

    private static func verifySearchGeneration(_ root: URL, icon: NSImage,
                                                fullPreview: NSImage, fullPixels: CGImage) {
        let url = root.appendingPathComponent("search-generation.png")
        let imageGate = InspectionGate(), initialIndexGate = InspectionGate(), ocrGate = InspectionGate()
        defer { imageGate.open(); initialIndexGate.open(); ocrGate.open() }
        let observed = InspectionBox((fileCalls: 0, ocrSize: CGSize.zero, offMain: true, qlCalls: 0))
        let inspector = ClipboardFileInspector(environment: .init(
            metadata: { ClipboardMetadata(paths: $0.map(\.path)) },
            fullImage: { _ in imageGate.block(); return .init(preview: fullPreview, pixels: fullPixels) },
            icon: { _ in icon }, thumbnail: { _, done in observed.update { $0.qlCalls += 1 }; done(icon) }))
        let indexer = ClipboardSearchIndexer(environment: .init(fileText: { _ in
            let call = observed.update { value -> Int in
                value.fileCalls += 1; value.offMain = value.offMain && !Thread.isMainThread
                return value.fileCalls
            }
            if call == 1 { initialIndexGate.block(); return "STALE SPOTLIGHT" }
            return nil
        }, recognize: { pixels in
            observed.update { $0.ocrSize = CGSize(width: pixels.width, height: pixels.height); $0.offMain = $0.offMain && !Thread.isMainThread }
            ocrGate.block()
            return "FULL IMAGE OCR 2304"
        }))
        let board = NSPasteboard.withUniqueName()
        let store = ClipboardStore(pasteboard: board, fileInspector: inspector, searchIndexer: indexer)
        defer { store.stop(); board.releaseGlobally() }
        var notificationsOnMain = true
        store.onChange = { notificationsOnMain = notificationsOnMain && Thread.isMainThread }
        copy([url], to: board, store: store)
        let entry = store.entries[0]
        awaitResult("initial file index and full image load start") { initialIndexGate.started && imageGate.started }
        imageGate.open()
        awaitResult("full image promotion requests a fresh pending index") { entry.isImage }
        initialIndexGate.open()
        awaitResult("full-resolution OCR starts after the first file result returns") { ocrGate.started && initialIndexGate.returned }
        drain()
        if case .pending = entry.searchIndex { check(true, "stale file text cannot replace pending full-image OCR") }
        else { check(false, "stale file text cannot replace pending full-image OCR") }
        ocrGate.open()
        awaitResult("full-image OCR becomes searchable") { entry.recognizedText == "FULL IMAGE OCR 2304" }
        check(entry.matches("FULL IMAGE OCR 2304") && !entry.matches("STALE SPOTLIGHT"),
              "search uses the completed full-image generation")
        check(entry.isImage && entry.thumbnail === fullPreview && observed.read { $0.qlCalls == 0 },
              "Quick Look cannot demote or replace a successful full image")
        check(observed.read { $0.ocrSize == CGSize(width: 2304, height: 2112) && $0.offMain },
              "recognition receives full decoded pixels off main, rather than an icon or thumbnail")
        check(notificationsOnMain, "store notifications for preview and index changes arrive on main")
        check(!imageGate.timedOut && !initialIndexGate.timedOut && !ocrGate.timedOut,
              "index generation ordering is controlled without timed-out reads")
    }

    private static func verifyRemovedCallbacks(_ root: URL, icon: NSImage,
                                               fullPreview: NSImage, fullPixels: CGImage) {
        let url = root.appendingPathComponent("removed.png")
        let metadataGate = InspectionGate(), imageGate = InspectionGate(), indexGate = InspectionGate()
        defer { metadataGate.open(); imageGate.open(); indexGate.open() }
        let inspector = ClipboardFileInspector(environment: .init(
            metadata: { urls in metadataGate.block(); return ClipboardMetadata(facts: ["late facts"], paths: urls.map(\.path)) },
            fullImage: { _ in imageGate.block(); return .init(preview: fullPreview, pixels: fullPixels) },
            icon: { _ in icon }, thumbnail: { _, done in done(icon) }))
        let indexer = ClipboardSearchIndexer(environment: .init(
            fileText: { _ in indexGate.block(); return "LATE SEARCH TEXT" }, recognize: { _ in "unexpected OCR" }))
        let board = NSPasteboard.withUniqueName()
        let store = ClipboardStore(pasteboard: board, fileInspector: inspector, searchIndexer: indexer)
        defer { store.stop(); board.releaseGlobally() }
        copy([url], to: board, store: store)
        let removed = store.entries[0]
        let initialThumbnail = removed.thumbnail
        awaitResult("all removed-entry derivations are waiting") { metadataGate.started && imageGate.started && indexGate.started }
        check(store.remove(removed) && store.entries.isEmpty, "removing the synthetic entry empties its store")
        var changes = 0
        store.onChange = { changes += 1 }
        metadataGate.open(); imageGate.open(); indexGate.open()
        awaitResult("removed-entry workers finish") { metadataGate.returned && imageGate.returned && indexGate.returned }
        drain()
        check(removed.kind == .file && removed.thumbnail === initialThumbnail && removed.metadata == ClipboardMetadata(paths: [url.path]),
              "late metadata and image callbacks do not mutate a removed entry")
        if case .pending = removed.searchIndex { check(true, "late search completion leaves removed entry untouched") }
        else { check(false, "late search completion leaves removed entry untouched") }
        check(changes == 0 && store.entries.isEmpty, "late callbacks neither notify nor restore a removed entry")
    }

    private static func verifyReplacedCallbacks(_ root: URL, icon: NSImage,
                                                fullPreview: NSImage, fullPixels: CGImage) {
        let url = root.appendingPathComponent("replaced.png")
        let history = root.appendingPathComponent("ReplacedHistory.plist")
        writeFixtureHistory([url], to: history, icon: icon)
        let oldMetadata = InspectionGate(), oldImage = InspectionGate(), oldIndex = InspectionGate()
        defer { oldMetadata.open(); oldImage.open(); oldIndex.open() }
        let counts = InspectionBox((metadata: 0, image: 0, index: 0))
        let inspector = ClipboardFileInspector(environment: .init(metadata: { urls in
            let call = counts.update { $0.metadata += 1; return $0.metadata }
            if call == 1 { oldMetadata.block() }
            return ClipboardMetadata(facts: [call == 1 ? "old facts" : "new facts"], paths: urls.map(\.path))
        }, fullImage: { _ in
            let call = counts.update { $0.image += 1; return $0.image }
            if call == 1 { oldImage.block(); return .init(preview: icon, pixels: fullPixels) }
            return .init(preview: fullPreview, pixels: fullPixels)
        }, icon: { _ in icon }, thumbnail: { _, done in done(icon) }))
        let indexer = ClipboardSearchIndexer(environment: .init(fileText: { _ in
            let call = counts.update { $0.index += 1; return $0.index }
            if call == 1 { oldIndex.block(); return "OLD SEARCH" }
            return nil
        }, recognize: { _ in "NEW OCR" }))
        let board = NSPasteboard.withUniqueName()
        let store = ClipboardStore(pasteboard: board, persistenceURL: history,
                                   fileInspector: inspector, searchIndexer: indexer)
        defer { store.stop(); board.releaseGlobally() }
        store.start()
        let old = store.entries[0]
        let initialThumbnail = old.thumbnail
        awaitResult("first history load is awaiting derived details") { oldMetadata.started && oldImage.started && oldIndex.started }
        store.stop()
        store.start()
        let replacement = store.entries[0]
        check(replacement !== old && replacement.fingerprint == old.fingerprint,
              "a reload creates a distinct retained object for the same synthetic payload")
        awaitResult("replacement preview and facts arrive without waiting for old work") {
            replacement.isImage && replacement.metadata.facts == ["new facts"]
        }
        oldMetadata.open(); oldImage.open(); oldIndex.open()
        awaitResult("replacement OCR completes") { replacement.recognizedText == "NEW OCR" }
        awaitResult("replaced-entry workers finish") { oldMetadata.returned && oldImage.returned && oldIndex.returned }
        drain()
        check(old.kind == .file && old.thumbnail === initialThumbnail && old.metadata.facts.isEmpty && old.recognizedText.isEmpty,
              "callbacks for replaced objects do not mutate discarded history entries")
        check(store.entries.count == 1 && store.entries[0] === replacement && replacement.thumbnail === fullPreview &&
              replacement.metadata.facts == ["new facts"] && !replacement.matches("OLD SEARCH"),
              "old derivations cannot overwrite the replacement's image, metadata, or search")
    }
}

private final class InspectionBox<Value> {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func read<Result>(_ action: (Value) -> Result) -> Result {
        lock.lock(); defer { lock.unlock() }; return action(value)
    }
    @discardableResult func update<Result>(_ action: (inout Value) -> Result) -> Result {
        lock.lock(); defer { lock.unlock() }; return action(&value)
    }
}

/// A bounded slow dependency: accidental main-thread use fails instead of hanging.
private final class InspectionGate {
    private let semaphore = DispatchSemaphore(value: 0)
    private let state = InspectionBox((started: false, returned: false, timedOut: false))
    var started: Bool { state.read { $0.started } }
    var returned: Bool { state.read { $0.returned } }
    var timedOut: Bool { state.read { $0.timedOut } }
    func block() {
        state.update { $0.started = true }
        let timedOut = semaphore.wait(timeout: .now() + 5) == .timedOut
        state.update { $0.returned = true; $0.timedOut = timedOut }
    }
    func open() { semaphore.signal() }
}
