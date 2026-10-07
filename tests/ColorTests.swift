import AppKit

@main enum ColorTests {
    static func main() {
        var checks = 0
        func expect(_ ok: Bool, _ message: String) { checks += 1; precondition(ok, message) }
        func color(_ literal: String, _ rgba: [CGFloat]) {
            guard let value = ClipboardColor.parse(literal)?.usingColorSpace(.sRGB) else { fatalError("Missing \(literal)") }
            let actual = [value.redComponent, value.greenComponent, value.blueComponent, value.alphaComponent]
            expect(zip(actual, rgba).allSatisfy { abs($0 - $1) < 0.0001 }, literal)
        }
        color(" #F6C0A6\n", [246/255, 192/255, 166/255, 1])
        color("#abc", [170/255, 187/255, 204/255, 1])
        color("#abcd", [170/255, 187/255, 204/255, 221/255])
        color("#10203080", [16/255, 32/255, 48/255, 128/255])
        color("rgb(255, 0, 128)", [1, 0, 128/255, 1])
        color("rgba(100%, 0%, 50%, 25%)", [1, 0, 0.5, 0.25])
        color("rgb(255 0 0 / .5)", [1, 0, 0, 0.5])
        color("hsl(120, 100%, 50%)", [0, 1, 0, 1])
        color("hsla(-120deg, 100%, 50%, .2)", [0, 0, 1, 0.2])
        color("hsl(480 100% 50% / 50%)", [0, 1, 0, 0.5])
        for invalid in ["", "F6C0A6", "#12", "#12345", "#xyz", "#１２３", "Use #F6C0A6", "#fff\n#000", "rgb(256, 0, 0)", "rgb(-1, 0, 0)", "rgb(nan, 0, 0)", "rgb(1,2,3,4)", "rgba(1,2,3)", "rgb(1,,3)", "rgb(1 2 3 / 2)", "hsl(0, 1, .5)", "hsl(inf, 100%, 50%)", "rgb(1,2,3) trailing"] {
            expect(ClipboardColor.parse(invalid) == nil, "Reject \(invalid)")
        }
        let payload = ClipboardPayload(values: [(.string, Data("#F6C0A6".utf8))])
        let entry = ClipboardEntry(fingerprint: "color", capturedAt: Date(), payloads: [payload], title: "#F6C0A6", detail: "", kind: .text, thumbnail: nil)
        expect(entry.swatchColor != nil, "text color")
        expect(entry.plainTextForPaste == "#F6C0A6", "swatch preserves paste text")
        expect(ClipboardBrowserTab.text.includes(entry), "color stays Text")
        expect(!ClipboardBrowserTab.images.includes(entry), "color stays out of Images")
        let file = ClipboardEntry(fingerprint: "file", capturedAt: Date(), payloads: [payload], title: "#F6C0A6", detail: "", kind: .file, thumbnail: nil)
        expect(file.swatchColor == nil, "file flavor wins")
        let card = ClipboardHistoryCard(frame: NSRect(x: 0, y: 0, width: 400, height: 350))
        card.show(entry); card.layoutSubtreeIfNeeded()
        let swatch = card.subviews.compactMap { $0 as? ClipboardSwatchView }.first!
        expect(!swatch.isHidden && swatch.frame.width == swatch.frame.height, "preview circle")
        card.show(nil)
        expect(swatch.isHidden, "empty card clears color")
        let ordinary = ClipboardEntry(fingerprint: "text", capturedAt: Date(), payloads: [ClipboardPayload(values: [(.string, Data("ordinary".utf8))])], title: "ordinary", detail: "", kind: .text, thumbnail: nil)
        card.show(ordinary)
        expect(swatch.isHidden, "ordinary text clears color")
        print("Color tests passed: \(checks) assertions")
    }
}
