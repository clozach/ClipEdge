import AppKit

/// Every surface ClipEdge paints itself follows the app's appearance: built in
/// light then switched to dark (a light login turned dark), built in dark, and
/// back again. Fixture panels are real windows that are never ordered on screen.
@main enum AppearanceTests {
    private static var assertions = 0
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError("FAIL: \(message)") }
    }
    private static func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
    /// Built now (defer: false); a hidden deferred panel keeps an old appearance until shown.
    private static func host(_ view: NSView) -> NSPanel {
        let panel = HiddenPanel(contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = view
        return panel
    }
    private static func isDark(_ view: NSView) -> Bool { view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
    private static func components(_ color: CGColor?) -> [CGFloat]? {
        guard let color, let srgb = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return nil }
        return [srgb.redComponent, srgb.greenComponent, srgb.blueComponent, srgb.alphaComponent]
    }
    private static func luminance(_ color: NSColor?) -> CGFloat {
        guard let c = color?.usingColorSpace(.sRGB) else { return -1 }
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    }
    private static func luminance(_ color: CGColor?) -> CGFloat { luminance(color.flatMap { NSColor(cgColor: $0) }) }
    /// The color a dynamic system color should have in this appearance.
    private static func resolved(_ color: NSColor, opacity: CGFloat? = nil, in name: NSAppearance.Name) -> CGColor {
        var result = color.cgColor
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance { result = (opacity.map(color.withAlphaComponent) ?? color).cgColor }
        return result
    }
    private static func same(_ a: CGColor?, _ b: CGColor?) -> Bool {
        switch (components(a), components(b)) {
        case (nil, nil): return true
        case let (x?, y?): return zip(x, y).allSatisfy { abs($0 - $1) < 0.02 }
        default: return false
        }
    }
    /// No rim means no outline drawn, whatever color the layer keeps by default.
    private static func rimMatches(_ layer: CALayer?, _ rim: CGColor?) -> Bool {
        guard let rim else { return (layer?.borderWidth ?? 0) == 0 }
        return layer?.borderWidth == 1 && same(layer?.borderColor, rim)
    }
    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    /// Where card info's arrow and key columns start, in the info's own points.
    /// The shortcut list hugs its columns, so a relayout (an appearance switch) never spreads them.
    private static func keyColumns(_ built: (surfaces: [Painted], panels: [NSPanel], history: ClipboardHistoryView, transparent: NSView)) -> [CGFloat] {
        guard let info = built.surfaces.first(where: { $0.name == "card info" })?.view,
              let grid = descendants(info).lazy.compactMap({ $0 as? NSGridView }).first else { return [] }
        info.layoutSubtreeIfNeeded()
        return [1, 2].compactMap { column in
            grid.cell(atColumnIndex: column, rowIndex: 0).contentView.map { $0.convert($0.bounds, to: info).minX }
        }
    }

    /// One painted surface: the view whose layer it paints and the look it should have.
    struct Painted {
        let name: String
        let view: NSView
        let fill: NSColor
        let opacity: CGFloat?
        let rim: NSColor?
    }

    /// An item with no text and no picture, like a browser's internal copy: the card shows its symbol and title.
    static let opaque = ClipboardEntry(fingerprint: "opaque", capturedAt: Date(timeIntervalSince1970: 1791225000),
        payloads: [ClipboardPayload(values: [(NSPasteboard.PasteboardType("org.clipedge.fixture-opaque"), Data())])],
        title: "Clipboard item", detail: "", kind: .other, thumbnail: nil)

    /// Each surface, built and hosted under whatever appearance the app has now.
    static func build() -> (surfaces: [Painted], panels: [NSPanel], history: ClipboardHistoryView, transparent: NSView) {
        let history = ClipboardHistoryView(frame: NSRect(x: 0, y: 0, width: 800, height: 470))
        history.update(entries: [opaque])
        history.card.show(opaque)
        let carousel = ClipboardCarouselView(entry: opaque, urls: [], position: 0, count: 1)
        let sendToPanel = HiddenPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 200),
                                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let sendTo = ClipboardSendToPopover(panel: sendToPanel)
        let selectionPanel = HiddenPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 160),
                                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let selection = ClipboardSelectionPopover(keymap: .drawer, panel: selectionPanel)
        selection.show(.init(count: 2)) { NSRect(origin: .zero, size: $0) }
        let info = ClipboardTileTooltip.content(for: "Clipboard item", keymap: .drawer, asker: nil)
        let held = ClipboardAttachmentView.makeHeldPreview(for: opaque, maximumAttachmentPixels: 480, holdingGlyphHeight: 25).view
        let card = descendants(held).first { $0.layer?.cornerRadius == 11 }
        check(card != nil, "the held magnet has its small card")
        // The drawer's body and tab paint the window's ground over their glass (2026-10-16).
        let glass = ClipboardGlassView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        glass.updateLayout(bodyRect: NSRect(x: 0, y: 0, width: 380, height: 600), tabRect: NSRect(x: 380, y: 280, width: 20, height: 40), edge: .right)
        let panels = [host(history), host(carousel), sendToPanel, selectionPanel, host(info), host(held), host(glass)]
        return ([Painted(name: "history window", view: history, fill: .windowBackgroundColor, opacity: nil, rim: .separatorColor),
                 Painted(name: "Quick Look chrome", view: carousel, fill: .windowBackgroundColor, opacity: nil, rim: .separatorColor),
                 Painted(name: "drawer Send to", view: sendTo.view, fill: .windowBackgroundColor, opacity: nil, rim: .separatorColor),
                 Painted(name: "selection's actions", view: selection.view, fill: .windowBackgroundColor, opacity: nil, rim: .separatorColor),
                 Painted(name: "card info", view: info, fill: .windowBackgroundColor, opacity: nil, rim: nil),
                 Painted(name: "small magnet card", view: card ?? held, fill: .windowBackgroundColor, opacity: 0.96, rim: .separatorColor),
                 Painted(name: "drawer's ground", view: glass.bodyGround, fill: .windowBackgroundColor, opacity: ClipboardSurface.glassGroundOpacity, rim: nil),
                 Painted(name: "drawer tab's ground", view: glass.tabGround, fill: .windowBackgroundColor, opacity: ClipboardSurface.glassGroundOpacity, rim: nil)],
                panels, history, history.sendTo)
    }

    static func expect(_ built: (surfaces: [Painted], panels: [NSPanel], history: ClipboardHistoryView, transparent: NSView),
                       _ name: NSAppearance.Name, _ moment: String) {
        let dark = name == .darkAqua
        for surface in built.surfaces {
            // AppKit itself must have moved the view; otherwise the colors below prove nothing.
            check(isDark(surface.view) == dark, "\(moment): AppKit gave the \(surface.name) the \(dark ? "dark" : "light") appearance")
            let layer = surface.view.layer
            check(same(layer?.backgroundColor, resolved(surface.fill, opacity: surface.opacity, in: name)),
                  "\(moment): the \(surface.name) ground is the \(dark ? "dark" : "light") one")
            check(rimMatches(layer, surface.rim.map { resolved($0, in: name) }), "\(moment): the \(surface.name) rim matches")
            if surface.opacity == nil {
                let ground = luminance(layer?.backgroundColor)
                check(dark ? ground < 0.3 : ground > 0.9, "\(moment): the \(surface.name) ground reads \(dark ? "dark" : "light") (\(ground))")
            } else if surface.name.hasPrefix("drawer") {
                // Over the brightest window behind the glass in dark, and the darkest in light, the
                // ground still reads in ClipEdge's own appearance.
                let own = luminance(resolved(surface.fill, in: name)), opacity = surface.opacity!
                let worst = own * opacity + (dark ? 1 : 0) * (1 - opacity)
                check(dark ? worst < 0.35 : worst > 0.75, "\(moment): the \(surface.name) reads \(dark ? "dark over a white" : "light over a black") window behind (\(worst))")
            }
        }
        check(built.transparent.layer?.backgroundColor == nil, "\(moment): the window's own Send to list stays transparent")
        // Whatever paints itself, everywhere: each surface view's layer is its look in its own appearance.
        for view in built.surfaces.map(\.view).flatMap(descendants).compactMap({ $0 as? ClipboardSurfaceView }) {
            var fill: CGColor?, rim: CGColor?
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                fill = view.surface.fill?.resolved.cgColor
                rim = view.surface.rim?.cgColor
            }
            check(same(view.layer?.backgroundColor, fill) && rimMatches(view.layer, rim),
                  "\(moment): \(type(of: view)) paints its surface in its own appearance")
        }
    }

    /// A view as a bitmap, the way cacheDisplay draws it for a held magnet.
    static func snapshot(_ view: NSView) -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }
    /// Opaque pixel luminances inside a rectangle given in the view's flipped points.
    static func luminances(_ rep: NSBitmapImageRep, in box: NSRect, viewWidth: CGFloat) -> [CGFloat] {
        let scale = CGFloat(rep.pixelsWide) / viewWidth
        var values: [CGFloat] = []
        for y in Int(box.minY * scale)..<Int(box.maxY * scale) {
            for x in Int(box.minX * scale)..<Int(box.maxX * scale) {
                guard let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.9 else { continue }
                values.append(luminance(color))
            }
        }
        return values
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .aqua)

        // 1. Built light, as at a light login, then the Mac switches to dark and back.
        let atLogin = build()
        settle()
        expect(atLogin, .aqua, "built light")
        let columnsBuiltLight = keyColumns(atLogin)
        check(columnsBuiltLight.count == 2, "card info has its arrow and key columns")
        app.appearance = NSAppearance(named: .darkAqua)
        settle()
        expect(atLogin, .darkAqua, "switched to dark")
        let columnsSwitchedDark = keyColumns(atLogin)
        app.appearance = NSAppearance(named: .aqua)
        settle()
        expect(atLogin, .aqua, "switched back to light")
        let columnsBackLight = keyColumns(atLogin)

        // 2. Built while dark, as at a dark login or a magnet made after the switch.
        app.appearance = NSAppearance(named: .darkAqua)
        let inDark = build()
        settle()
        expect(inDark, .darkAqua, "built dark")
        // Card info's shortcut list keeps its light layout through every switch: the keys stay beside their names.
        for (moment, columns) in [("switched to dark", columnsSwitchedDark), ("switched back to light", columnsBackLight),
                                  ("built dark", keyColumns(inDark))] {
            check(columns.count == 2 && zip(columns, columnsBuiltLight).allSatisfy { abs($0 - $1) < 0.5 },
                  "\(moment): card info's arrow and key columns stay where they are built light (\(columns) vs \(columnsBuiltLight))")
        }
        // The fixture's --demo-report reads the same grounds, so a live check needs no pixels.
        let sendTo = inDark.surfaces.lazy.compactMap { $0.view as? ClipboardSendToView }.first!
        let report = ClipboardDemoReport.surfaces(history: inDark.history, sendTo: sendTo, in: app)
        check(JSONSerialization.isValidJSONObject(report), "the surface report is JSON")
        check(report["historyAppearance"] as? String == "dark" && (report["historyGround"] as? CGFloat ?? 1) < 0.3
              && report["sendToAppearance"] as? String == "dark" && (report["sendToGround"] as? CGFloat ?? 1) < 0.3,
              "the demo report names the dark history window and Send to grounds")
        check(report["quickLookAppearance"] as? String == "none", "a surface that is not showing reports none")

        // 3. The history card is legible in dark: its symbol and title stand out from the ground.
        check(isDark(atLogin.history), "the history window built in light is dark now")
        let window = snapshot(atLogin.history)
        let card = atLogin.history.flip.frame
        let cardPixels = luminances(window, in: card.insetBy(dx: 10, dy: 10), viewWidth: atLogin.history.bounds.width)
        let ground = luminance(atLogin.history.layer?.backgroundColor)
        check(cardPixels.contains { abs($0 - ground) > 0.3 }, "the dark history card shows its symbol and title, not a blank card")

        // 4. Kind symbols drawn into rows take the row's appearance (a template draws black).
        for (style, place, size, iconBox) in [(ClipboardTileStyle.compact, "history window", NSSize(width: 310, height: 44), NSRect(x: 9, y: 7, width: 32, height: 32)),
                                              (.row, "drawer", NSSize(width: 300, height: 90), NSRect(x: 11, y: 14, width: 46, height: 46))] {
            for theme in [NSAppearance.Name.darkAqua, .aqua] {
                app.appearance = NSAppearance(named: theme)
                let tile = ClipboardTile(entry: opaque, style: style, keymap: .drawer)
                tile.frame = NSRect(origin: .zero, size: size)
                let icon = withExtendedLifetime(host(tile)) { () -> [CGFloat] in
                    settle()
                    return luminances(snapshot(tile), in: iconBox, viewWidth: size.width)
                }
                if theme == .darkAqua {
                    check((icon.max() ?? 0) > 0.4, "a \(place) row's symbol is light on a dark row (\(icon.max() ?? 0))")
                } else {
                    check((icon.min() ?? 1) < 0.6, "a \(place) row's symbol is dark on a light row (\(icon.min() ?? 1))")
                }
            }
        }

        // 5. A dark color swatch keeps its hairline edge on a dark ground.
        app.appearance = NSAppearance(named: .darkAqua)
        let swatch = ClipboardSwatchView(frame: NSRect(x: 0, y: 0, width: 120, height: 120))
        swatch.color = .black
        let swatchPixels = withExtendedLifetime(host(swatch)) { () -> NSBitmapImageRep in settle(); return snapshot(swatch) }
        // Along the middle row from the left, the first inked pixels are the circle's outline.
        let row = swatchPixels.pixelsHigh / 2
        let outline = (0..<swatchPixels.pixelsWide).compactMap { x -> CGFloat? in
            guard let color = swatchPixels.colorAt(x: x, y: row), color.alphaComponent > 0.05 else { return nil }
            return luminance(color.usingColorSpace(.sRGB)?.withAlphaComponent(1))
        }.prefix(3)
        check((outline.max() ?? 0) > 0.1, "a black swatch keeps a light hairline in dark (\(outline.max() ?? 0))")

        // 6. A held small magnet is a snapshot; a switch while holding redraws it.
        app.appearance = NSAppearance(named: .aqua)
        let magnetPanel = HiddenPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let quiet = PasteMonitor(environment: .init(accessibilityTrusted: { false }, listenAccess: { false },
            externalApplication: { false }, keyAction: { nil }, pointerLocation: { .zero },
            beginObservation: { _ in }, refreshObservation: { _ in }))
        let magnet = ClipboardMagnetController(pasteMonitor: quiet, panel: magnetPanel, commandClickEnabled: false,
            systemEffects: .init(setCursor: { _ in }, registerArrow: { _ in }, startCommandClick: { _ in }))
        func heldGround() -> CGFloat {
            guard let image = (magnetPanel.contentView as? NSImageView)?.image,
                  let rep = image.representations.first as? NSBitmapImageRep else { return -1 }
            let opaque = luminances(rep, in: NSRect(origin: .zero, size: image.size), viewWidth: image.size.width)
            return opaque.isEmpty ? -1 : opaque.reduce(0, +) / CGFloat(opaque.count)
        }
        magnet.show(entry: opaque, from: nil)
        settle()
        check(magnet.presentation == .small && heldGround() > 0.6, "a magnet held in light is light (\(heldGround()))")
        app.appearance = NSAppearance(named: .darkAqua)
        settle()
        check(magnet.presentation == .small && heldGround() >= 0 && heldGround() < 0.4, "the held magnet turns dark with the Mac (\(heldGround()))")
        magnet.hide()
        app.appearance = NSAppearance(named: .aqua)
        withExtendedLifetime((atLogin, inDark)) {}
        print("Appearance tests passed (\(assertions) assertions)")
    }
}

/// A real window that is never ordered on screen.
private final class HiddenPanel: NSPanel {
    private var fixtureVisible = false
    override var isVisible: Bool { fixtureVisible }
    override func orderFrontRegardless() { fixtureVisible = true }
    override func makeKeyAndOrderFront(_ sender: Any?) { fixtureVisible = true }
    override func orderOut(_ sender: Any?) { fixtureVisible = false }
    override func makeKey() {}
    override func resignKey() {}
}
