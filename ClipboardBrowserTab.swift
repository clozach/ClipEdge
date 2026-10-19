import Foundation

/// The four tabs, by position: 0–3 in the drawer while its cards hold the keyboard, ⌘0–⌘3 in
/// the history window, whose search always does (Al, 2026-10-16: All 0, Text 1, Images 2, Other 3;
/// Text first since later that day, so Images is on 2, the easier reach).
/// They overlap: All shows everything, and a copy can be a picture and app data at once.
enum ClipboardBrowserTab: Int, CaseIterable {
    case all, text, images, other
    var title: String { switch self { case .all: return "All"; case .images: return "Images"; case .text: return "Text"; case .other: return "Other" } }
    /// Its number key, as its label shows it: "0" for All.
    var numberKey: String { String(rawValue) }
    /// Where its number key is, on the top row and on the keypad (the keys 0–9, in order),
    /// so layouts without digits there still reach it.
    var keyCodes: (row: UInt16, keypad: UInt16) {
        ([29, 18, 19, 20, 21, 23, 22, 26, 28, 25][rawValue], [82, 83, 84, 85, 86, 87, 88, 89, 91, 92][rawValue])
    }
    func includes(_ entry: ClipboardEntry) -> Bool {
        switch self {
        case .all: return true
        case .images: return entry.isImage
        case .text:
            // Figma layers are text only when they carry it; their link alone is a way to paste them.
            switch entry.kind {
            case .text, .link, .html: return true
            case .figma(let copy): return copy.carriedText != nil
            case .image, .file, .appData, .other: return false
            }
        case .other:
            // What one app or Finder pastes back: Finder items, Figma layers (text
            // layers too, since they carry layers), app data with or without a
            // picture or text, and copies that read as nothing.
            if entry.appData != nil { return true }
            switch entry.kind {
            case .file, .figma, .appData, .other: return true
            case .text, .link, .html, .image: return false
            }
        }
    }
    /// One filter for the drawer and the history window: this tab's entries
    /// that match every search word.
    func visible(_ entries: [ClipboardEntry], query: String) -> [ClipboardEntry] {
        entries.filter { includes($0) && $0.matches(query) }
    }
}
