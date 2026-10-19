import AppKit

/// Whether a drawer side panel takes the keyboard as it shows (Send to, the preview ask), or leaves
/// it where it is (the selection's actions: the cards keep it, so marking goes on by key).
enum ClipboardSidePanelKeyboard {
    case takes, leaves
}

/// A panel beside the drawer for one of its companions (Send to, the preview ask, the selection's
/// actions): it shows at the frame it is given. One that takes the keyboard closes when it stops
/// being key; one that leaves it never becomes key (its buttons refuse the keyboard) and closes
/// when its owner says.
final class ClipboardDrawerSidePanel {
    /// Told when it closes still holding the keyboard (Esc, Back, a send), so the drawer takes the
    /// keyboard back. A close because the person clicked into another app or window is not told:
    /// what they clicked keeps the keyboard (`ClipboardKeyboardReturn`).
    var onClose: (() -> Void)?
    private let panel: NSPanel
    private let keyboard: ClipboardSidePanelKeyboard
    private let zoom: ClipboardZoomHost
    /// The Text size it draws at, read as it shows.
    var textScale: () -> CGFloat = { 1 }
    private var resignObserver: NSObjectProtocol?
    var isVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }

    init(title: String, content: ClipboardSurfaceView, keyboard: ClipboardSidePanelKeyboard = .takes, panel suppliedPanel: NSPanel? = nil) {
        panel = suppliedPanel ?? ClipboardWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                                 backing: .buffered, defer: true)
        self.keyboard = keyboard
        panel.title = title
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        content.surface = .card(radius: 10)
        zoom = ClipboardZoomHost(content)
        panel.contentView = zoom
        switch keyboard {
        case .takes:
            resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: nil) { [weak self] _ in
                self?.close()
            }
        case .leaves:
            // A click on a button there leaves the drawer's cards with the keyboard.
            panel.becomesKeyOnlyIfNeeded = true
        }
    }
    deinit { if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) } }

    /// `size`, its content's wanted size at 100%, at the Text size: the size to place it at.
    func scaled(_ size: NSSize) -> NSSize {
        zoom.scale = textScale()
        return zoom.scaled(size)
    }

    /// On screen at `frame`, its content zoomed by the Text size; a panel that takes the keyboard puts
    /// it on `responder`.
    func show(at frame: NSRect, keyboardOn responder: NSView?) {
        zoom.scale = textScale()
        panel.setFrame(frame, display: true)
        zoom.frame = NSRect(origin: .zero, size: frame.size)
        zoom.layoutSubtreeIfNeeded()
        zoom.content.layoutSubtreeIfNeeded()
        switch keyboard {
        case .takes:
            panel.makeKeyAndOrderFront(nil)
            if let responder { panel.makeFirstResponder(responder) }
        case .leaves:
            panel.orderFrontRegardless()
        }
    }

    func close() {
        guard panel.isVisible else { return }
        // Decided before it goes, while it may still hold the keyboard.
        let keyboard = ClipboardKeyboardReturn.after(.besideDrawer, holdingKeyboard: panel.isKeyWindow)
        panel.orderOut(nil)
        if keyboard == .takeBack { onClose?() }
    }
}
