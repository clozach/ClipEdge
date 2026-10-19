import AppKit
import UniformTypeIdentifiers

/// Everything a history entry holds, as the pasteboard handed it over: the back
/// of a flipped card. An overview, then each pasteboard item's flavors in their
/// stored order, each read as text or as bytes. Nothing here is rendered: HTML,
/// RTF and the rest are their source text, and the view shows them as plain text.
struct ClipboardRawData {
    /// Text past this many bytes is shown in part; Copy still copies all of it.
    /// 64,000 rather than 65,536 so the note reads "64 KB" in the same decimal
    /// units as every other size ClipEdge shows (ByteCountFormatter's file style).
    static let textCap = 64_000
    /// Bytes past this many are left out of the hex dump and counted instead.
    static let dumpCap = 512

    struct Row: Equatable {
        let label: String
        let value: String
        /// A machine string (the fingerprint): set in a fixed-width font, broken anywhere to wrap.
        var isCode = false
    }

    /// The entry as a whole: when it was copied, what it is, how much it holds.
    struct Overview: Equatable {
        let copied: String
        let kind: String
        let title: String
        let itemCount: Int
        let flavorCount: Int
        let byteCount: Int
        let fingerprint: String

        var rows: [Row] {
            let items = itemCount == 1 ? "1 pasteboard item" : "\(itemCount) pasteboard items"
            let flavors = flavorCount == 1 ? "1 flavor" : "\(flavorCount) flavors"
            return [Row(label: "Copied", value: copied), Row(label: "Kind", value: kind), Row(label: "Title", value: title),
                    Row(label: "Holds", value: "\(items) · \(flavors)"), Row(label: "Size", value: ClipboardRawData.size(byteCount)),
                    Row(label: "SHA-256", value: fingerprint, isCode: true)]
        }
    }

    /// One type and its bytes, numbered from 1 across the whole entry: Copy ⌥n copies flavor n.
    /// What it reads as, and its type's name, are worked out the first time they are asked for, so a
    /// view reads only the flavors it shows (a Finder copy of a thousand files holds a thousand).
    struct Flavor {
        let number: Int
        let type: NSPasteboard.PasteboardType
        let data: Data
        private let reading: ClipboardRawReading
        /// UTType's name for the type, or ClipEdge's for a browser type it knows; nil for neither.
        var typeDescription: String? { reading.typeDescription }
        var content: ClipboardRawContent { reading.content }
        /// Whether its content has been read yet (fixtures check what showing reads).
        var isRead: Bool { reading.isRead }

        init(number: Int, type: NSPasteboard.PasteboardType, data: Data) {
            self.number = number
            self.type = type
            self.data = data
            reading = ClipboardRawReading(data: data, type: type)
        }

        /// What follows the type on its header line: its description, size and, for text, encoding.
        var details: [String] {
            var details = typeDescription.map { [$0] } ?? []
            details.append(ClipboardRawData.size(data.count))
            if case .text(let text) = content { details.append(text.encoding.name) }
            return details
        }
        /// The quiet lines beneath the content: how much is shown, a picture's size.
        var notes: [String] {
            switch content {
            case .empty: return ["Empty: this flavor holds no bytes."]
            case .text(let text): return text.isWhole ? [] : [text.capNote]
            case .bytes(let bytes): return bytes.notes
            }
        }
        /// Text copies as the whole decoded text, a plain string; bytes as the original data
        /// under their own type. Nil for an empty flavor: there is nothing to copy.
        var copy: ClipboardRawCopy? {
            switch content {
            case .empty: return nil
            case .text(let text): return text.whole(of: data).map(ClipboardRawCopy.text) ?? .bytes(type, data)
            case .bytes: return .bytes(type, data)
            }
        }
    }

    /// One pasteboard item: "Item 1 of 2" when there are several.
    struct Item {
        let number: Int
        let flavors: [Flavor]
    }

    let overview: Overview
    let items: [Item]
    var flavors: [Flavor] { items.flatMap(\.flavors) }

    /// Reads nothing yet: each flavor is read when it is first shown or copied.
    init(entry: ClipboardEntry) {
        var number = 0
        items = entry.payloads.enumerated().map { index, payload in
            Item(number: index + 1, flavors: payload.values.map { value in
                number += 1
                return Flavor(number: number, type: value.type, data: value.data)
            })
        }
        overview = Self.overview(of: entry)
    }

    /// The entry as a whole, read afresh: what follows a copy made again, which moves only its time.
    static func overview(of entry: ClipboardEntry) -> Overview {
        Overview(copied: entry.fullDateTimeStamp, kind: kindName(entry), title: entry.title, itemCount: entry.payloads.count,
                 flavorCount: entry.payloads.reduce(0) { $0 + $1.values.count },
                 byteCount: entry.values.reduce(0) { $0 + $1.data.count }, fingerprint: entry.fingerprint)
    }
}

// MARK: Reading a flavor

/// A flavor's reading and its type's name, each worked out once, when first asked for.
private final class ClipboardRawReading {
    let data: Data
    let type: NSPasteboard.PasteboardType
    private var read: ClipboardRawContent?
    private var described: String??

    init(data: Data, type: NSPasteboard.PasteboardType) {
        self.data = data
        self.type = type
    }
    var isRead: Bool { read != nil }
    var content: ClipboardRawContent {
        if let read { return read }
        let content = ClipboardRawData.content(of: data, type: type)
        read = content
        return content
    }
    var typeDescription: String? {
        if let described { return described }
        let name = ClipboardRawData.description(of: type)
        described = .some(name)
        return name
    }
}

/// How one flavor reads: nothing, text, or bytes.
enum ClipboardRawContent: Equatable {
    case empty
    case text(ClipboardRawText)
    case bytes(ClipboardRawBytes)
}

/// A flavor that reads as text, decoded, and the part of it shown.
struct ClipboardRawText: Equatable {
    enum Encoding: Equatable {
        case utf8
        case utf16(bigEndian: Bool)
        var name: String {
            switch self {
            case .utf8: return "UTF-8"
            case .utf16(let bigEndian): return bigEndian ? "UTF-16 BE" : "UTF-16 LE"
            }
        }
        var stringEncoding: String.Encoding {
            switch self {
            case .utf8: return .utf8
            case .utf16(let bigEndian): return bigEndian ? .utf16BigEndian : .utf16LittleEndian
            }
        }
    }
    let encoding: Encoding
    /// The byte-order mark's length (0, 2 or 3), never shown or copied.
    let markLength: Int
    /// All of the text, or the first `ClipboardRawData.textCap` bytes' worth.
    let shown: String
    /// How many of the flavor's bytes `shown` covers, its mark included.
    let shownBytes: Int
    let totalBytes: Int

    var isWhole: Bool { shownBytes >= totalBytes }
    /// "First 64 KB of 3 MB shown; Copy copies all."
    var capNote: String {
        let shownSize = ByteCountFormatter.string(fromByteCount: Int64(shownBytes), countStyle: .file)
        let totalSize = ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)
        return "First \(shownSize) of \(totalSize) shown; Copy copies all."
    }
    /// The whole text, decoded again from the flavor's bytes, for Copy.
    func whole(of data: Data) -> String? {
        String(data: data.dropFirst(markLength), encoding: encoding.stringEncoding)
    }
}

/// A flavor that does not read as text: the start of its bytes, and a picture's size.
struct ClipboardRawBytes: Equatable {
    /// The first `ClipboardRawData.dumpCap` bytes.
    let head: Data
    let totalBytes: Int
    /// "96 × 64 pixels" for a picture flavor NSImage decodes; nil otherwise.
    let pictureSize: String?
    /// The type says text, but the bytes are neither UTF-8 nor UTF-16.
    let isUndecodableText: Bool

    var remaining: Int { totalBytes - head.count }
    func dump(bytesPerRow: Int) -> String { ClipboardRawData.hexDump(head, bytesPerRow: bytesPerRow) }
    var notes: [String] {
        var notes: [String] = []
        if remaining > 0 { notes.append("… \(remaining.formatted()) more byte\(remaining == 1 ? "" : "s")") }
        if let pictureSize { notes.append(pictureSize) }
        if isUndecodableText { notes.append("Declared as text, but not valid UTF-8 or UTF-16.") }
        return notes
    }
}

/// What Copy puts on the clipboard for one flavor, or for a selection in it.
enum ClipboardRawCopy: Equatable {
    /// A plain string.
    case text(String)
    /// The original bytes under their own type, and nothing else.
    case bytes(NSPasteboard.PasteboardType, Data)

    /// Replaces the clipboard's contents. Written to the general pasteboard, it becomes
    /// the newest history entry the normal way.
    @discardableResult
    func write(to pasteboard: NSPasteboard) -> Bool {
        let item = NSPasteboardItem()
        switch self {
        case .text(let text): item.setString(text, forType: .string)
        case .bytes(let type, let data): item.setData(data, forType: type)
        }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }
}

extension ClipboardRawData {
    /// Text when the type says so and the bytes decode, or when undeclared bytes decode
    /// as UTF-8 (or BOM-led UTF-16) with no control characters beyond tab and line ends.
    /// Everything else is bytes.
    static func content(of data: Data, type: NSPasteboard.PasteboardType) -> ClipboardRawContent {
        guard !data.isEmpty else { return .empty }
        let declared = isTextual(type)
        if let decoded = decode(data, type: type), declared || !decoded.hasControls {
            return .text(decoded.text)
        }
        let picture = ClipboardFlavors.isPicture(type) ? pictureSize(data) : nil
        return .bytes(ClipboardRawBytes(head: data.prefix(dumpCap), totalBytes: data.count, pictureSize: picture,
                                        isUndecodableText: declared))
    }

    /// Types that hold text by definition: any kind of text (plain, HTML, RTF source, JSON, XML,
    /// XML property lists), URLs, and the page address a Chromium browser notes.
    static func isTextual(_ type: NSPasteboard.PasteboardType) -> Bool {
        if type == ClipboardFlavors.sourceURL { return true }
        guard let declared = UTType(type.rawValue) else { return false }
        return declared.conforms(to: .text) || declared.conforms(to: .url)
    }

    /// UTF-16 for the UTF-16 text types (host order, little-endian, unless a mark says
    /// otherwise; the external type defaults to big-endian) and for any data led by a UTF-16
    /// mark; UTF-8 otherwise. Nil when the bytes are not valid in that encoding. Every byte is
    /// checked, for validity and for control characters, in one pass that builds nothing; only
    /// the part shown is decoded (a 30 MB flavor is never copied into a string to be shown).
    private static func decode(_ data: Data, type: NSPasteboard.PasteboardType) -> (text: ClipboardRawText, hasControls: Bool)? {
        let bytes = [UInt8](data.prefix(3))
        let encoding: ClipboardRawText.Encoding
        let mark: Int
        if bytes.starts(with: [0xFF, 0xFE]) { (encoding, mark) = (.utf16(bigEndian: false), 2) }
        else if bytes.starts(with: [0xFE, 0xFF]) { (encoding, mark) = (.utf16(bigEndian: true), 2) }
        else if type.rawValue == "public.utf16-plain-text" { (encoding, mark) = (.utf16(bigEndian: false), 0) }
        else if type.rawValue == "public.utf16-external-plain-text" { (encoding, mark) = (.utf16(bigEndian: true), 0) }
        else if bytes == [0xEF, 0xBB, 0xBF] { (encoding, mark) = (.utf8, 3) }
        else { (encoding, mark) = (.utf8, 0) }
        let body = data.dropFirst(mark)
        // Foundation drops a final odd byte of UTF-16 without complaint; that is not text.
        if case .utf16 = encoding, body.count % 2 != 0 { return nil }
        let scanned = scan(body, encoding: encoding)
        guard scanned.valid else { return nil }
        let end = mark + shownLength(of: body, encoding: encoding)
        guard let shown = String(data: data[data.startIndex + mark ..< data.startIndex + end], encoding: encoding.stringEncoding) else { return nil }
        return (ClipboardRawText(encoding: encoding, markLength: mark, shown: shown, shownBytes: end, totalBytes: data.count), scanned.hasControls)
    }

    /// How many bytes of valid text to show: all of it up to the cap, else the cap
    /// moved back to the start of a character (a UTF-8 sequence, a UTF-16 surrogate pair).
    private static func shownLength(of body: Data, encoding: ClipboardRawText.Encoding) -> Int {
        guard body.count > textCap else { return body.count }
        var end = textCap
        let start = body.startIndex
        switch encoding {
        case .utf8:
            while end > 0, body[start + end] & 0xC0 == 0x80 { end -= 1 }
        case .utf16(let bigEndian):
            end -= end % 2
            let unit = bigEndian ? UInt16(body[start + end - 2]) << 8 | UInt16(body[start + end - 1])
                                 : UInt16(body[start + end - 1]) << 8 | UInt16(body[start + end - 2])
            if (0xD800...0xDBFF).contains(unit) { end -= 2 }
        }
        return end
    }

    /// Whether `bytes` are valid in `encoding`, as Foundation reads them (UTF-8 by RFC 3629: no
    /// overlong forms, surrogates or values past U+10FFFF; UTF-16 with every surrogate paired), and
    /// whether any character is a control character other than tab, line feed and carriage return
    /// (C0, DEL and C1: the mark of bytes that happen to decode; the joiners inside emoji are format
    /// characters, not control). One pass over the bytes, building nothing.
    static func scan(_ bytes: Data, encoding: ClipboardRawText.Encoding) -> (valid: Bool, hasControls: Bool) {
        bytes.withUnsafeBytes { raw in
            switch encoding {
            case .utf8: return scanUTF8(raw)
            case .utf16(let bigEndian): return scanUTF16(raw, bigEndian: bigEndian)
            }
        }
    }

    /// U+0000–U+001F but tab, line feed and carriage return; U+007F–U+009F.
    private static func isControl(_ value: UInt32) -> Bool {
        (value < 0x20 && value != 0x09 && value != 0x0A && value != 0x0D) || (0x7F...0x9F).contains(value)
    }

    private static func scanUTF8(_ bytes: UnsafeRawBufferPointer) -> (valid: Bool, hasControls: Bool) {
        var controls = false, index = 0
        let count = bytes.count
        while index < count {
            let lead = bytes[index]
            if lead < 0x80 {
                if !controls, isControl(UInt32(lead)) { controls = true }
                index += 1
                continue
            }
            // The sequence's length and its second byte's range, by its lead byte (Unicode's table 3-7).
            let length: Int, second: ClosedRange<UInt8>
            switch lead {
            case 0xC2...0xDF: (length, second) = (2, 0x80...0xBF)
            case 0xE0: (length, second) = (3, 0xA0...0xBF)
            case 0xE1...0xEC, 0xEE...0xEF: (length, second) = (3, 0x80...0xBF)
            case 0xED: (length, second) = (3, 0x80...0x9F)
            case 0xF0: (length, second) = (4, 0x90...0xBF)
            case 0xF1...0xF3: (length, second) = (4, 0x80...0xBF)
            case 0xF4: (length, second) = (4, 0x80...0x8F)
            default: return (false, controls)
            }
            guard index + length <= count, second.contains(bytes[index + 1]) else { return (false, controls) }
            for offset in 2..<length where !(0x80...0xBF).contains(bytes[index + offset]) { return (false, controls) }
            // C2 80 to C2 9F: U+0080–U+009F, the C1 controls.
            if lead == 0xC2, bytes[index + 1] <= 0x9F { controls = true }
            index += length
        }
        return (true, controls)
    }

    private static func scanUTF16(_ bytes: UnsafeRawBufferPointer, bigEndian: Bool) -> (valid: Bool, hasControls: Bool) {
        guard bytes.count % 2 == 0 else { return (false, false) }
        func unit(_ at: Int) -> UInt16 {
            bigEndian ? UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1]) : UInt16(bytes[at + 1]) << 8 | UInt16(bytes[at])
        }
        var controls = false, index = 0
        while index < bytes.count {
            let value = unit(index)
            switch value {
            case 0xD800...0xDBFF:
                guard index + 4 <= bytes.count, (0xDC00...0xDFFF).contains(unit(index + 2)) else { return (false, controls) }
                index += 4
            case 0xDC00...0xDFFF: return (false, controls)
            default:
                if !controls, isControl(UInt32(value)) { controls = true }
                index += 2
            }
        }
        return (true, controls)
    }

    /// "96 × 64 pixels"; a PDF, which has no pixels, in points.
    private static func pictureSize(_ data: Data) -> String? {
        guard let image = NSImage(data: data) else { return nil }
        if let rep = image.representations.max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }),
           rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return "\(rep.pixelsWide) × \(rep.pixelsHigh) pixels"
        }
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        return "\(Int(image.size.width.rounded())) × \(Int(image.size.height.rounded())) points"
    }

    /// Browser types UTType has no name for.
    private static let knownDescriptions: [String: String] = [
        ClipboardFlavors.sourceURL.rawValue: "the page it was copied from",
        "org.chromium.internal.source-rfh-token": "the browser's token for the frame it was copied from",
        "com.apple.WebKit.custom-pasteboard-data": "the page's own clipboard data",
        "com.apple.linkpresentation.metadata": "link preview data"
    ]
    static func description(of type: NSPasteboard.PasteboardType) -> String? {
        knownDescriptions[type.rawValue] ?? UTType(type.rawValue)?.localizedDescription
    }

    /// What the entry is, in the words its card and tabs use.
    static func kindName(_ entry: ClipboardEntry) -> String {
        let kind: String
        switch entry.kind {
        case .text: kind = "Text"
        case .image: kind = "Picture"
        case .file: kind = entry.fileURLs.count == 1 ? "Finder item" : "\(entry.fileURLs.count) Finder items"
        case .link: kind = "Link"
        case .figma(let copy): kind = "Figma copy (\(copy.editor.name))"
        case .html: kind = "HTML-only text"
        case .appData(let data): kind = "App data (\(data.title))"
        case .other: kind = "Clipboard item"
        }
        // A picture or text that also carries an app's own format says so, as its facts do.
        if case .appData = entry.kind { return kind }
        return entry.appData.map { "\(kind), with \($0.title)" } ?? kind
    }

    /// "24 bytes"; "3 MB (3,000,000 bytes)" once the short form rounds.
    static func size(_ count: Int) -> String {
        let short = ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
        return count < 1_000 ? short : "\(short) (\(count.formatted()) bytes)"
    }

    // MARK: Hex dump

    /// One line per `bytesPerRow` bytes: a four-digit offset, the bytes in hex in groups of
    /// eight, and the printable ASCII between bars, "." for the rest. A short last line keeps
    /// its ASCII column in place.
    ///
    ///     0000  89 50 4e 47 0d 0a 1a 0a  00 00 00 0d 49 48 44 52  |.PNG........IHDR|
    static func hexDump(_ bytes: Data, bytesPerRow: Int) -> String {
        let row = max(1, bytesPerRow)
        let values = [UInt8](bytes)
        let hexWidth = hexColumnWidth(bytesPerRow: row)
        return stride(from: 0, to: values.count, by: row).map { offset in
            let slice = values[offset ..< min(offset + row, values.count)]
            var hex = ""
            for (index, byte) in slice.enumerated() {
                if index > 0 { hex += index % 8 == 0 ? "  " : " " }
                hex += String(format: "%02x", byte)
            }
            let ascii = String(slice.map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "." })
            return String(format: "%04x", offset) + "  " + hex.padding(toLength: hexWidth, withPad: " ", startingAt: 0) + "  |\(ascii)|"
        }.joined(separator: "\n")
    }
    /// The characters one full line of the dump takes, so a view can choose a row that fits.
    static func hexLineLength(bytesPerRow: Int) -> Int {
        let row = max(1, bytesPerRow)
        return 4 + 2 + hexColumnWidth(bytesPerRow: row) + 2 + row + 2
    }
    private static func hexColumnWidth(bytesPerRow row: Int) -> Int { row * 3 - 1 + (row - 1) / 8 }
}
