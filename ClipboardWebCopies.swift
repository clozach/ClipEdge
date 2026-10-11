import AppKit

/// Made-up copies shaped like those a web page leaves on the clipboard: Figma
/// layers, HTML-only text, rich text without plain text, a page's address.
/// Every key, name and word is invented; the demo (--demo-web-copies) and the
/// tests share them. Never put a real clipboard capture here.
enum ClipboardWebCopies {
    typealias Values = [(type: NSPasteboard.PasteboardType, data: Data)]

    static let fileKey = "CLIPEDGEFIXTURE0000001"
    static let fileName = "ClipEdge Fixture Board"
    /// Chromium's private note of the frame a copy came from; ClipEdge keeps it and never shows it.
    static let frameToken = NSPasteboard.PasteboardType("org.chromium.internal.source-rfh-token")

    /// Figma layers as Chrome puts them on the clipboard: HTML holding the copy's
    /// description and a stand-in buffer, the page's address, and the frame token.
    /// The address names a different layer and carries a share token and a
    /// viewport, as a real tab's address does; none of that reaches the link.
    static func figma(editorType: String = "design", route: String = "design", nodes: String = "1:2|31|0|0", dataType: String = "scene",
                      slug: String = "ClipEdge-Fixture-Board", source: Bool = true, text: String? = nil, figmeta: String? = nil) -> Values {
        let description = #"{"fileKey":"\#(fileKey)","pasteID":271828,"dataType":"\#(dataType)","editorType":"\#(editorType)","environment":"www.figma.com","selectedNodeData":"\#(nodes)","imageHashes":{}}"#
        let meta = figmeta ?? Data(description.utf8).base64EncodedString()
        let buffer = (Data("fig-kiwi".utf8) + Data([106, 0, 0, 0]) + Data(repeating: 0x2A, count: 48)).base64EncodedString()
        let html = "<meta charset='utf-8'><meta charset=\"utf-8\"><span data-metadata=\"<!--(figmeta)\(meta)(/figmeta)-->\"></span>"
            + "<span data-buffer=\"<!--(figma)\(buffer)(/figma)-->\"></span><span style=\"white-space:pre-wrap;\">\(text ?? "")</span>"
        var values: Values = [(.html, Data(html.utf8)), (frameToken, Data(repeating: 7, count: 24))]
        if source {
            let address = "https://www.figma.com/\(route)/\(fileKey)/\(slug)?node-id=9-9&t=fixture&viewport=-120%2C40%2C0.5"
            values.append((ClipboardFlavors.sourceURL, Data(address.utf8)))
        }
        if let text { values.append((.string, Data(text.utf8))) }
        return sorted(values)
    }
    static func html(_ html: String, source: String? = nil) -> Values {
        var values: Values = [(.html, Data(html.utf8))]
        if let source { values += [(ClipboardFlavors.sourceURL, Data(source.utf8)), (frameToken, Data(repeating: 8, count: 24))] }
        return sorted(values)
    }
    static func rtf(_ text: String) -> Values { [(.rtf, Data("{\\rtf1\\ansi \(text)}".utf8))] }
    /// Text copied from a chat page, with the page's address beside it.
    static let chatReply: Values = sorted([(.string, Data("ClipEdge fixture reply from a chat page".utf8)),
                                           (.html, Data("<p>ClipEdge fixture reply from a chat page</p>".utf8)),
                                           (ClipboardFlavors.sourceURL, Data("https://claude.ai/chat/clipedge-fixture".utf8)),
                                           (frameToken, Data(repeating: 8, count: 24))])

    static let plainHTML = "<p>ClipEdge <b>fixture</b> &amp; HTML-only copy</p><script>ignored()</script><style>.x{}</style>"

    /// The demo's copies, oldest first, each named for what it shows.
    static let demo: [(name: String, values: Values)] = [
        ("Figma Design layer", figma()),
        ("Five Figma layers", figma(nodes: "1:2|23|0|0,1:3|23|0|0,1:4|6|0|0,1:6|23|0|0,1:5|23|0|0")),
        ("Figma cut", figma(nodes: "")),
        ("FigJam layer", figma(editorType: "whiteboard", route: "board", nodes: "4:7|6|0|0")),
        ("Figma layer without an address", figma(source: false)),
        ("Figma layer with empty text", figma(text: "")),
        ("Figma text layer", figma(nodes: "1:9|31|0|0", text: "ClipEdge fixture caption")),
        ("Damaged Figma description", figma(figmeta: "not-base64-json")),
        ("HTML-only text", html(plainHTML)),
        ("HTML-only color", html("<span>#F6C0A6</span>")),
        ("HTML with nothing to read", html("<span style=\"color:red\"></span><!-- nothing -->")),
        ("Rich text only", rtf("ClipEdge fixture rich note")),
        ("Text from a chat page", chatReply)
    ]

    /// One clipboard item holding these flavors.
    static func item(_ values: Values) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        for value in values { item.setData(value.data, forType: value.type) }
        return item
    }
    /// In type-name order, as ClipEdge captures them.
    private static func sorted(_ values: Values) -> Values { values.sorted { $0.type.rawValue < $1.type.rawValue } }
}
