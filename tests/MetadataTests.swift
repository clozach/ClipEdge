import AppKit

@main enum MetadataTests {
    private static var assertions = 0
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError("FAIL: \(message)") }
    }
    private static func png(_ width: Int, _ height: Int) -> Data {
        NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            .representation(using: .png, properties: [:])!
    }
    /// Uncompressed 8-bit mono sound at 8 kHz: one byte per sample.
    private static func wav(seconds: Int) -> Data {
        func little<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        let samples = Data(repeating: 0x80, count: 8_000 * seconds)
        var data = Data("RIFF".utf8) + little(UInt32(36 + samples.count)) + Data("WAVEfmt ".utf8)
        data += little(UInt32(16)) + little(UInt16(1)) + little(UInt16(1)) + little(UInt32(8_000)) + little(UInt32(8_000))
        data += little(UInt16(1)) + little(UInt16(8)) + Data("data".utf8) + little(UInt32(samples.count)) + samples
        return data
    }
    private static func entry(_ values: [(NSPasteboard.PasteboardType, Data)], kind: ClipboardKind, detail: String = "") -> ClipboardEntry {
        ClipboardEntry(fingerprint: UUID().uuidString, capturedAt: Date(), payloads: [ClipboardPayload(values: values)],
                       title: "Fixture", detail: detail, kind: kind, thumbnail: nil)
    }

    static func main() throws {
        check(ClipboardMetadata.text("one two\nthree").facts == ["3 words", "13 characters"], "text counts words and characters")
        check(ClipboardMetadata.text("a").line == "1 word · 1 character", "singular counts read naturally")
        check(ClipboardMetadata.text("  spaced \t out  ").facts[0] == "2 words", "runs of whitespace separate words once")
        check(ClipboardMetadata.text("").facts == ["0 words", "0 characters"], "empty text has zero counts")
        check(ClipboardMetadata.text("naïve 👩‍👩‍👧 café").facts == ["3 words", "12 characters"], "characters are what a reader sees, not bytes")

        let picture = png(40, 20)
        let image = ClipboardMetadata.image(picture, type: .png)
        check(image.facts.count == 3 && image.facts[0] == "40 × 20" && image.facts[2] == "PNG", "clipboard picture shows pixel dimensions and type")
        check(image.facts[1] == ByteCountFormatter.string(fromByteCount: Int64(picture.count), countStyle: .file), "clipboard picture shows its size")
        check(image.paths.isEmpty && image.pasteText == image.line, "a picture without a file pastes its facts as plain text")
        let undecodable = ClipboardMetadata.image(Data([1, 2, 3]), type: .pdf)
        check(undecodable.facts == ["3 bytes", "PDF"], "a flavor without pixel dimensions still shows size and type")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ClipEdge-metadata-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pictureURL = folder.appendingPathComponent("Sunset plan.png")
        let soundURL = folder.appendingPathComponent("Tide.wav")
        let noteURL = folder.appendingPathComponent("README")
        try picture.write(to: pictureURL); try wav(seconds: 2).write(to: soundURL); try Data("note".utf8).write(to: noteURL)

        let pictureFile = ClipboardMetadata.files([pictureURL])
        check(pictureFile.facts.first == "40 × 20" && pictureFile.facts.last == "PNG" && pictureFile.facts.count == 3, "picture file: dimensions, size, extension")
        check(pictureFile.paths == [pictureURL.path], "a Finder item keeps its full path")
        let sound = ClipboardMetadata.files([soundURL])
        check(sound.facts.first == "0:02" && sound.facts.last == "WAV" && sound.facts.count == 3, "sound file: duration, size, extension (\(sound.facts))")
        let note = ClipboardMetadata.files([noteURL])
        check(note.facts.count == 2 && note.facts[0] == "4 bytes" && !note.facts[1].isEmpty && note.facts[1] != "README", "no extension falls back to the type's name")
        let directory = ClipboardMetadata.files([folder])
        check(directory.facts.count == 1 && !directory.facts[0].contains("bytes"), "a folder shows its kind, not a misleading size")
        check(ClipboardMetadata.files([folder.appendingPathComponent("gone.txt")]).facts == ["File not found"], "a moved file says so")
        let several = ClipboardMetadata.files([pictureURL, soundURL, folder])
        check(several.facts[0] == "3 items" && several.facts.count == 2 && several.paths.count == 3, "several items: count, combined file size, every path")
        check(several.pasteText.components(separatedBy: "\n") == several.paths + [several.line], "plain-text paste lists each path, then the facts")
        check(sound.compact == "\(sound.line) · \(soundURL.path)" && sound.lines == [sound.line, soundURL.path], "rows get one line; previews get facts then paths")

        let home = ClipboardMetadata(facts: [], paths: [NSHomeDirectory() + "/Documents/plan.pdf"])
        check(home.displayPaths == ["~/Documents/plan.pdf"] && home.pasteText == NSHomeDirectory() + "/Documents/plan.pdf", "display shortens the home folder; paste keeps the real path")
        check(ClipboardMetadata.duration(42) == "0:42" && ClipboardMetadata.duration(185) == "3:05" && ClipboardMetadata.duration(3_723) == "1:02:03", "durations read as clocks")
        check(ClipboardMetadata().isEmpty && ClipboardMetadata().lines.isEmpty && ClipboardMetadata().pasteText.isEmpty, "no facts, no lines")

        let text = entry([(.string, Data("Trip: pack a notebook".utf8))], kind: .text, detail: "21 characters")
        check(text.metadata.line == "4 words · 21 characters" && text.edgeText == text.metadata.line, "a text entry carries its counts")
        check(text.plainTextForPaste == "Trip: pack a notebook", "text pastes as itself")
        let link = entry([(.string, Data("https://example.com/a/b?c=1".utf8))], kind: .link)
        check(link.metadata.facts == ["example.com"], "a link shows its host; nothing is fetched")
        let clip = entry([(.png, picture), (.tiff, Data([0]))], kind: .image)
        check(clip.metadata.facts.first == "40 × 20" && clip.metadata.facts.last == "PNG", "an image entry reads its first picture flavor")
        check(clip.plainTextForPaste == clip.metadata.line, "an image pastes its facts as plain text")
        let file = entry([(.fileURL, Data(pictureURL.absoluteString.utf8))], kind: .file)
        check(file.metadata == ClipboardMetadata(paths: [pictureURL.path]) && file.plainTextForPaste == pictureURL.path, "a Finder item starts with its path before the disk is read")
        let opaque = entry([(NSPasteboard.PasteboardType("com.example.opaque"), Data([9]))], kind: .other, detail: "com.example.opaque")
        check(opaque.metadata.isEmpty && opaque.edgeText == "com.example.opaque", "an unknown flavor keeps its summary detail")

        // Copies from web pages, recognized as captured.
        func captured(_ values: ClipboardWebCopies.Values) -> ClipboardEntry {
            let summary = ClipboardSummary.make(from: [ClipboardPayload(values: values)])
            return entry(values.map { ($0.type, $0.data) }, kind: summary.kind, detail: summary.detail)
        }
        let layers = captured(ClipboardWebCopies.figma())
        check(layers.metadata.facts == ["Figma Design", "figma.com"] && layers.edgeText == "Figma Design · figma.com", "Figma layers: editor and site, not type names")
        check(layers.plainTextForPaste == "https://www.figma.com/design/\(ClipboardWebCopies.fileKey)/ClipEdge-Fixture-Board?node-id=1-2",
              "Figma layers paste their link as plain text, share token dropped and layer kept")
        check(!layers.metadata.pasteText.contains("figma.com/design"), "the link is the paste, not one of the facts")
        let page = captured(ClipboardWebCopies.html(ClipboardWebCopies.plainHTML))
        check(page.metadata.facts == ["5 words", "33 characters"] && page.plainTextForPaste == "ClipEdge fixture & HTML-only copy", "an HTML-only copy counts and pastes its words")
        let chat = captured(ClipboardWebCopies.chatReply)
        check(chat.metadata.site == "claude.ai" && chat.edgeText.hasSuffix("· from claude.ai"), "a copy from a web page names the site")
        check(!chat.metadata.pasteText.contains("claude.ai") && ClipboardMetadata(site: "claude.ai").pasteText.isEmpty && !ClipboardMetadata(site: "claude.ai").isEmpty,
              "the site shows along the edge but is never pasted")
        let caption = captured(ClipboardWebCopies.figma(text: "Fixture caption"))
        check(caption.metadata.facts == ["Figma text from ClipEdge Fixture Board", "Figma Design", "figma.com"] && caption.plainTextForPaste == "Fixture caption",
              "Figma text: where it came from, then editor and site; it pastes its words")
        let local = captured(ClipboardWebCopies.html("<p>local words</p>", source: "app://-/index.html"))
        check(!local.metadata.line.contains("from"), "an app's own page names no site")
        let rich = captured(ClipboardWebCopies.rtf("Rich only"))
        check(rich.metadata.facts == ["2 words", "9 characters"] && rich.plainTextForPaste == "Rich only", "rich text alone counts and pastes its text")
        print("PASS: \(assertions) metadata assertions; temporary fixture files only")
    }
}
