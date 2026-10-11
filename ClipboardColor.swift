import AppKit

/// Only a complete color literal is a swatch; prose containing one stays prose.
enum ClipboardColor {
    static func parse(_ text: String) -> NSColor? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("#") {
            let hex = String(value.dropFirst())
            guard [3, 4, 6, 8].contains(hex.count), hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
            let expanded = hex.count <= 4 ? hex.map { "\($0)\($0)" }.joined() : hex
            guard let bits = UInt64(expanded, radix: 16) else { return nil }
            let rgba = expanded.count == 8 ? bits : (bits << 8) | 255
            return NSColor(srgbRed: CGFloat((rgba >> 24) & 255) / 255,
                           green: CGFloat((rgba >> 16) & 255) / 255,
                           blue: CGFloat((rgba >> 8) & 255) / 255, alpha: CGFloat(rgba & 255) / 255)
        }
        guard let open = value.firstIndex(of: "("), value.hasSuffix(")") else { return nil }
        let name = String(value[..<open])
        guard ["rgb", "rgba", "hsl", "hsla"].contains(name) else { return nil }
        let body = String(value[value.index(after: open)..<value.index(before: value.endIndex)])
        let parts: [String]
        if body.contains(",") {
            guard !body.contains("/") else { return nil }
            parts = body.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == (name.hasSuffix("a") ? 4 : 3) else { return nil }
        } else {
            let sides = body.components(separatedBy: "/")
            guard sides.count <= 2 else { return nil }
            let channels = sides[0].split(whereSeparator: \.isWhitespace).map(String.init)
            guard channels.count == 3 else { return nil }
            parts = channels + (sides.count == 2 ? [sides[1].trimmingCharacters(in: .whitespaces)] : [])
        }
        let alpha = parts.count == 4 ? component(parts[3], maximum: 1) : 1
        guard let alpha else { return nil }
        if name.hasPrefix("rgb") {
            guard let r = component(parts[0], maximum: 255), let g = component(parts[1], maximum: 255),
                  let b = component(parts[2], maximum: 255) else { return nil }
            return NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
        }
        let hueText = parts[0].hasSuffix("deg") ? String(parts[0].dropLast(3)) : parts[0]
        guard let hue = Double(hueText), hue.isFinite, parts[1].hasSuffix("%"), parts[2].hasSuffix("%"),
              let s = component(parts[1], maximum: 1), let l = component(parts[2], maximum: 1) else { return nil }
        let h = CGFloat((hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)) / 60
        let c = (1 - abs(2 * l - 1)) * s
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c / 2
        let channels: (CGFloat, CGFloat, CGFloat)
        switch h {
        case ..<1: channels = (c, x, 0)
        case ..<2: channels = (x, c, 0)
        case ..<3: channels = (0, c, x)
        case ..<4: channels = (0, x, c)
        case ..<5: channels = (x, 0, c)
        default: channels = (c, 0, x)
        }
        return NSColor(srgbRed: channels.0 + m, green: channels.1 + m, blue: channels.2 + m, alpha: alpha)
    }

    private static func component(_ text: String, maximum: Double) -> CGFloat? {
        let percent = text.hasSuffix("%")
        guard let number = Double(percent ? String(text.dropLast()) : text), number.isFinite,
              number >= 0, number <= (percent ? 100 : maximum) else { return nil }
        return CGFloat(number / (percent ? 100 : maximum))
    }
}

extension ClipboardEntry {
    /// Text, rich text included, or an HTML-only copy's text; never Figma layers.
    var swatchColor: NSColor? {
        switch kind {
        case .text, .html: return readableText.flatMap(ClipboardColor.parse)
        default: return nil
        }
    }
}

/// The circle alone gets an inset shadow and one rendered-pixel outline in previews.
final class ClipboardSwatchView: NSView {
    var color: NSColor? { didSet { isHidden = color == nil; needsDisplay = true } }
    override init(frame: NSRect) { super.init(frame: frame); isHidden = true }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        guard let color else { return }
        let side = max(0, min(bounds.width, bounds.height) - 2)
        let rect = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        let circle = NSBezierPath(ovalIn: rect)
        color.setFill(); circle.fill()
        NSGraphicsContext.saveGraphicsState()
        circle.addClip()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 5
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        let outside = NSBezierPath(rect: rect.insetBy(dx: -20, dy: -20))
        outside.append(circle); outside.windingRule = .evenOdd
        NSColor.black.setFill(); outside.fill()
        NSGraphicsContext.restoreGraphicsState()
        let hairline = 1 / max(1, window?.backingScaleFactor ?? 2)
        // Resolved here, in this view's appearance: dark on a light ground, light on a dark one.
        NSColor.labelColor.withAlphaComponent(0.22).setStroke()
        let border = NSBezierPath(ovalIn: rect.insetBy(dx: hairline / 2, dy: hairline / 2))
        border.lineWidth = hairline; border.stroke()
    }
}
