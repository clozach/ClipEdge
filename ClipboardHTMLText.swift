import Foundation

/// The words a person would read in a copy that carries only HTML, found by
/// one pass over the bytes: no regular expressions, no WebKit, nothing loaded.
/// Scripts, styles and comments are dropped, block tags become line breaks and
/// common entities are decoded.
struct ClipboardHTMLText: Equatable {
    /// Summaries run on the main thread for every saved item at launch, so they
    /// read at most this much HTML. Anything longer is read in full on demand.
    static let summaryLimit = 2 << 20

    let text: String
    /// False when the HTML ran past the limit: `text` is then its beginning only.
    let isComplete: Bool

    /// Nil when nothing readable remains, so an HTML item never holds empty text.
    init?(html: Data, limit: Int = ClipboardHTMLText.summaryLimit) {
        let text = Self.readable(html, limit: limit)
        guard !text.isEmpty else { return nil }
        self.text = text
        isComplete = html.count <= limit
    }

    /// The text of `html`, from at most `limit` bytes.
    static func readable(_ html: Data, limit: Int) -> String {
        let bytes = utf8Bytes(html, limit: limit)
        var scanner = Scanner(bytes: bytes)
        scanner.run()
        return String(decoding: scanner.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// UTF-8 HTML, or UTF-16 with a byte-order mark, cut at a whole character.
    private static func utf8Bytes(_ html: Data, limit: Int) -> [UInt8] {
        let head = html.prefix(2)
        if head.elementsEqual([0xFF, 0xFE]) || head.elementsEqual([0xFE, 0xFF]) {
            let even = html.prefix(min(html.count, limit) & ~1)
            return Array((String(data: even, encoding: .utf16) ?? "").utf8)
        }
        var bytes = Array(html.prefix(limit))
        guard html.count > limit, let last = bytes.lastIndex(where: { $0 & 0xC0 != 0x80 }) else { return bytes }
        let lead = bytes[last]
        let length = lead < 0x80 ? 1 : lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : 2
        if last + length > bytes.count { bytes.removeSubrange(last...) }
        return bytes
    }

    /// Tags that end a line of text.
    private static let blocks: Set<String> = [
        "address", "article", "aside", "blockquote", "dd", "div", "dl", "dt", "figcaption", "figure", "footer",
        "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li", "main", "nav", "ol", "p", "pre", "section",
        "table", "tbody", "td", "th", "thead", "tr", "ul"
    ]
    /// Tags whose contents are never read: code, styling, the window title.
    private static let hidden: Set<String> = ["script", "style", "title", "template", "noscript"]
    private static let named: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "]

    /// Every byte is visited a bounded number of times; nothing backtracks.
    private struct Scanner {
        let bytes: [UInt8]
        var output: [UInt8] = []
        var index = 0
        var pendingSpace = false
        var preformatted = 0

        init(bytes: [UInt8]) { self.bytes = bytes; output.reserveCapacity(bytes.count / 4) }

        mutating func run() {
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: "<"): tag()
                case UInt8(ascii: "&"): entity()
                case 0x20, 0x09, 0x0A, 0x0D, 0x0C:
                    if preformatted > 0 { emit(bytes[index]) } else { pendingSpace = !output.isEmpty && output.last != 0x0A }
                    index += 1
                default:
                    emit(bytes[index]); index += 1
                }
            }
        }

        private mutating func emit(_ byte: UInt8) {
            if pendingSpace { output.append(0x20); pendingSpace = false }
            output.append(byte)
        }
        private mutating func emit(_ text: String) { text.utf8.forEach { emit($0) } }
        /// A block boundary starts a new line once; <br> always does.
        private mutating func lineBreak(always: Bool) {
            pendingSpace = false
            while output.last == 0x20 { output.removeLast() }
            if always || (!output.isEmpty && output.last != 0x0A) { output.append(0x0A) }
        }

        private func startsWith(_ text: String, at position: Int, ignoringCase: Bool = false) -> Bool {
            let pattern = text.utf8
            guard position + pattern.count <= bytes.count else { return false }
            for (offset, expected) in pattern.enumerated() {
                let byte = bytes[position + offset]
                guard (ignoringCase ? lowercased(byte) : byte) == expected else { return false }
            }
            return true
        }
        private func lowercased(_ byte: UInt8) -> UInt8 { byte >= 65 && byte <= 90 ? byte + 32 : byte }
        /// The position just past the first `text` at or after `position`, else the end.
        private func after(_ text: String, from position: Int, ignoringCase: Bool = false) -> Int {
            var cursor = position
            while cursor < bytes.count {
                if startsWith(text, at: cursor, ignoringCase: ignoringCase) { return cursor + text.utf8.count }
                cursor += 1
            }
            return bytes.count
        }

        /// Past a comment's end: '-->', or '--!>' as a browser also reads it.
        private func afterComment(from position: Int) -> Int {
            var cursor = position
            while cursor < bytes.count {
                if startsWith("-->", at: cursor) { return cursor + 3 }
                if startsWith("--!>", at: cursor) { return cursor + 4 }
                cursor += 1
            }
            return bytes.count
        }

        private mutating func tag() {
            if startsWith("<!--", at: index) {
                // '<!-->' and '<!--->' are empty comments, as a browser reads them.
                index = startsWith(">", at: index + 4) ? index + 5 : startsWith("->", at: index + 4) ? index + 6 : afterComment(from: index + 4)
                return
            }
            let next = index + 1 < bytes.count ? bytes[index + 1] : 0
            let opensTag = (97...122).contains(lowercased(next)) || [UInt8(ascii: "/"), UInt8(ascii: "!"), UInt8(ascii: "?")].contains(next)
            guard opensTag else {
                emit(UInt8(ascii: "<")); index += 1; return
            }
            var cursor = index + 1
            let closing = bytes[cursor] == UInt8(ascii: "/")
            if closing { cursor += 1 }
            var name: [UInt8] = []
            while cursor < bytes.count, name.count < 16 {
                let byte = lowercased(bytes[cursor])
                guard (97...122).contains(byte) || (48...57).contains(byte) else { break }
                name.append(byte); cursor += 1
            }
            // Skip to the tag's end; a quoted attribute may itself contain '>'.
            // As in a browser, a quote opens a value only as the first byte after '=' and spaces.
            var quote: UInt8?
            var valueNext = false
            while cursor < bytes.count {
                let byte = bytes[cursor]
                cursor += 1
                if let open = quote { if byte == open { quote = nil } }
                else if byte == UInt8(ascii: ">") { break }
                else if valueNext, byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") { quote = byte; valueNext = false }
                else if byte == UInt8(ascii: "=") { valueNext = true }
                else if ![0x20, 0x09, 0x0A, 0x0D, 0x0C].contains(byte) { valueNext = false }
            }
            index = cursor
            let tagName = String(decoding: name, as: UTF8.self)
            if !closing, ClipboardHTMLText.hidden.contains(tagName) {
                index = after("</\(tagName)", from: index, ignoringCase: true)
                index = after(">", from: index)
                return
            }
            if tagName == "br" { lineBreak(always: true); return }
            if tagName == "pre" { preformatted = max(0, preformatted + (closing ? -1 : 1)) }
            if ClipboardHTMLText.blocks.contains(tagName) { lineBreak(always: false) }
        }

        private mutating func entity() {
            var cursor = index + 1
            var body: [UInt8] = []
            while cursor < bytes.count, body.count < 10, bytes[cursor] != UInt8(ascii: ";") {
                body.append(bytes[cursor]); cursor += 1
            }
            guard cursor < bytes.count, bytes[cursor] == UInt8(ascii: ";"), let decoded = decode(body) else {
                emit(UInt8(ascii: "&")); index += 1; return
            }
            emit(decoded)
            index = cursor + 1
        }
        private func decode(_ body: [UInt8]) -> String? {
            let name = String(decoding: body, as: UTF8.self)
            if let text = ClipboardHTMLText.named[name] { return text }
            guard name.hasPrefix("#") else { return nil }
            let digits = name.dropFirst()
            let value = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits, radix: 10)
            guard let value, value != 0, let scalar = Unicode.Scalar(value) else { return nil }
            return value == 0xA0 ? " " : String(Character(scalar))
        }
    }
}
