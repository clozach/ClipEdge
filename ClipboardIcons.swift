import AppKit

/// Action glyphs share a 22-point grid, 1.5-point stroke and round ends.
enum ClipboardIcons {
    static let strokeWidth: CGFloat = 1.5
    static let delete = glyph { path in
        path.move(to: NSPoint(x: 6, y: 6)); path.line(to: NSPoint(x: 16, y: 16))
        path.move(to: NSPoint(x: 6, y: 16)); path.line(to: NSPoint(x: 16, y: 6))
    }
    static let openInPreview = glyph { path in
        path.move(to: NSPoint(x: 3, y: 10))
        path.curve(to: NSPoint(x: 19, y: 10), controlPoint1: NSPoint(x: 7, y: 16), controlPoint2: NSPoint(x: 15, y: 16))
        path.curve(to: NSPoint(x: 3, y: 10), controlPoint1: NSPoint(x: 15, y: 4), controlPoint2: NSPoint(x: 7, y: 4))
        path.close()
        path.appendOval(in: NSRect(x: 8.5, y: 7.5, width: 5, height: 5))
        for (a, b) in [(NSPoint(x: 6, y: 13), NSPoint(x: 4.5, y: 15)),
                       (NSPoint(x: 11, y: 14.5), NSPoint(x: 11, y: 17)),
                       (NSPoint(x: 16, y: 13), NSPoint(x: 17.5, y: 15))] {
            path.move(to: a); path.line(to: b)
        }
    }
    static let previous = chevron(left: true)
    static let next = chevron(left: false)
    static func symbol(_ name: String, description: String? = nil) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
    }
    private static func chevron(left: Bool) -> NSImage {
        glyph { path in
            let outer: CGFloat = left ? 13.5 : 8.5
            let inner: CGFloat = left ? 8.5 : 13.5
            path.move(to: NSPoint(x: outer, y: 16))
            path.line(to: NSPoint(x: inner, y: 11)); path.line(to: NSPoint(x: outer, y: 6))
        }
    }
    private static func glyph(_ draw: @escaping (NSBezierPath) -> Void) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 22), flipped: false) { _ in
            let path = NSBezierPath()
            path.lineWidth = strokeWidth; path.lineCapStyle = .round; path.lineJoinStyle = .round
            draw(path)
            NSColor.black.setStroke(); path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
