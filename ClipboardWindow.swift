import AppKit

/// A borderless nonactivating panel needs an explicit key-window opt-in for search.
final class ClipboardWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
