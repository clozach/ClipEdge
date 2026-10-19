import AppKit

/// How large ClipEdge draws, each a percentage of the size it shipped with (Al, 2026-10-16): its
/// text, the thumbnails in its lists, and Quick Look's preview. Settings keeps one of each.
struct ClipboardSizes: Equatable {
    /// Every window's content zooms by it (`ClipboardZoom`): text, symbols and spacing grow
    /// together, so every view follows without code of its own. A window with a set size grows
    /// with it; the drawer keeps its width and lays out within it.
    var text: Double
    /// The picture or symbol at the start of each row in the drawer and the ⌥⌘\ window; the
    /// Images grid keeps its own slider.
    var thumbnails: Double
    /// Quick Look's preview, beside the drawer and at the pointer.
    var preview: Double

    static let standard = ClipboardSizes(text: 100, thumbnails: 100, preview: 100)
    static let textRange: ClosedRange<Double> = 80...200
    static let thumbnailRange: ClosedRange<Double> = 50...300
    static let previewRange: ClosedRange<Double> = 50...200

    var textScale: CGFloat { CGFloat(text / 100) }
    var thumbnailScale: CGFloat { CGFloat(thumbnails / 100) }
    var previewScale: CGFloat { CGFloat(preview / 100) }

    /// Each kept in its range, in steps of 5; one that is not a number takes 100.
    var valid: ClipboardSizes {
        func fit(_ value: Double, _ range: ClosedRange<Double>) -> Double {
            value.isFinite ? min(range.upperBound, max(range.lowerBound, (value / 5).rounded() * 5)) : 100
        }
        return ClipboardSizes(text: fit(text, Self.textRange), thumbnails: fit(thumbnails, Self.thumbnailRange), preview: fit(preview, Self.previewRange))
    }
}

/// A view's content, zoomed: its bounds are its frame over the scale, so what it lays out in points
/// draws that many times larger. AppKit backs each layer under it at the zoomed resolution, so text
/// stays sharp (checked 2026-10-16: a label under a 1.5× zoom on a 2× screen draws at 3×).
enum ClipboardZoom {
    static func apply(_ scale: CGFloat, to view: NSView) {
        let scale = scale.isFinite && scale > 0 ? scale : 1
        let size = NSSize(width: view.frame.width / scale, height: view.frame.height / scale)
        let wasScale = view.bounds.width > 0 ? view.frame.width / view.bounds.width : 1
        if view.bounds.size != size { view.setBoundsSize(size) }
        if view.bounds.origin != .zero { view.setBoundsOrigin(.zero) }
        // AppKit keeps each tracking area and cursor rect where it was in the window: after a new
        // zoom, every view under it registers them again, or hover finds nothing (checked 2026-10-16:
        // Settings' magnets stopped appearing under the pointer at 200%).
        if abs(wasScale - scale) > 0.001 { refreshTracking(in: view) }
    }

    /// Every view under `view` registers its tracking areas and cursor rects again: after a zoom
    /// changes and its window has its new size.
    static func refreshTracking(in view: NSView) {
        view.updateTrackingAreas()
        view.window?.invalidateCursorRects(for: view)
        view.subviews.forEach(refreshTracking)
    }
}

/// A panel's content view that draws its one child at `scale` (Text size, 2026-10-16): the child is
/// placed by hand at the host's bounds, which `ClipboardZoom` shrinks by the scale, since Auto Layout
/// would place it by the host's frame. Below the child, layout goes on as at 100%.
final class ClipboardZoomHost: NSView {
    let content: NSView
    var scale: CGFloat = 1 { didSet { needsLayout = true } }

    init(_ content: NSView) {
        self.content = content
        super.init(frame: .zero)
        addSubview(content)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// What the child wants, `size` at 100%, as the host's frame: `size` times the scale.
    func scaled(_ size: NSSize) -> NSSize { NSSize(width: ceil(size.width * scale), height: ceil(size.height * scale)) }

    override func layout() {
        super.layout()
        ClipboardZoom.apply(scale, to: self)
        content.frame = bounds
    }
}
