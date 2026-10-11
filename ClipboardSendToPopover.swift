import AppKit

/// The drawer's Send to list, in its own panel beside the selected tile.
final class ClipboardSendToPopover {
    let view = ClipboardSendToView(frame: .zero)
    var onClose: (() -> Void)?
    private let panel: NSPanel
    private var resignObserver: NSObjectProtocol?
    static let width: CGFloat = 260
    var isVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }

    init(panel suppliedPanel: NSPanel? = nil) {
        panel = suppliedPanel ?? ClipboardWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                                 backing: .buffered, defer: true)
        panel.title = "ClipEdge Send To"
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        view.surface = .card(radius: 10)
        panel.contentView = view
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: nil) { [weak self] _ in
            self?.close()
        }
    }
    deinit { if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) } }

    /// `place` receives the list's wanted size and returns its on-screen frame.
    func show(_ targets: [ClipboardSendTarget], place: (NSSize) -> NSRect) {
        view.show(targets)
        let frame = place(NSSize(width: Self.width, height: view.fittingHeight(limit: 380)))
        panel.setFrame(frame, display: true)
        view.frame = NSRect(origin: .zero, size: frame.size)
        view.layoutSubtreeIfNeeded()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
    }

    func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        onClose?()
    }
}
