import AppKit

/// The drawer's Send to list, in its own panel beside the selected tile.
final class ClipboardSendToPopover {
    let view = ClipboardSendToView(frame: .zero)
    var onClose: (() -> Void)? {
        get { host.onClose }
        set { host.onClose = newValue }
    }
    private let host: ClipboardDrawerSidePanel
    static let width: CGFloat = 260
    var isVisible: Bool { host.isVisible }
    var textScale: () -> CGFloat { get { host.textScale } set { host.textScale = newValue } }
    var frame: NSRect { host.frame }

    init(panel suppliedPanel: NSPanel? = nil) {
        host = ClipboardDrawerSidePanel(title: "ClipEdge Send To", content: view, panel: suppliedPanel)
    }

    /// `place` receives the list's wanted size and returns its on-screen frame.
    func show(_ targets: [ClipboardSendTarget], place: (NSSize) -> NSRect) {
        view.show(targets)
        host.show(at: place(host.scaled(NSSize(width: Self.width, height: view.fittingHeight(limit: 380)))), keyboardOn: view)
    }

    func close() { host.close() }
}
