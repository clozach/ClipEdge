import AppKit
import UniformTypeIdentifiers

enum ClipboardSummary {
    static func make(from payloads: [ClipboardPayload]) -> (
        title: String,
        detail: String,
        kind: ClipboardKind,
        thumbnail: NSImage?
    ) {
        let values = payloads.flatMap(\.values)

        let fileURLStrings = values.compactMap { value -> String? in
            guard value.type == .fileURL else { return nil }
            return String(data: value.data, encoding: .utf8)
        }
        if let fileURLString = fileURLStrings.first,
           let url = URL(string: fileURLString) {
            let count = fileURLStrings.count
            let detail = count > 1 ? "\(count) files" : url.deletingLastPathComponent().path
            if count == 1, let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
               let image = NSImage(contentsOf: url) {
                return (url.lastPathComponent, detail, .image, image)
            }
            return (url.lastPathComponent, detail, .file, NSWorkspace.shared.icon(forFile: url.path))
        }

        if let image = values.lazy.compactMap({ value -> NSImage? in
            guard ClipboardFlavors.images.contains(value.type) else { return nil }
            return NSImage(data: value.data)
        }).first {
            let size = image.size
            let detail = "\(Int(size.width)) × \(Int(size.height)) image"
            return ("Image", detail, .image, image)
        }

        if let string = values.lazy.compactMap({ value -> String? in
            guard value.type == .string else { return nil }
            return String(data: value.data, encoding: .utf8)
        }).first {
            let normalized = string.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let display = normalized.isEmpty ? "Empty text" : normalized
            let title = String(display.prefix(90))

            if let url = URL(string: display), let scheme = url.scheme, ["http", "https", "mailto"].contains(scheme) {
                return (title, url.host ?? scheme.uppercased(), .link, nil)
            }

            let characters = string.count
            let detail = characters == 1 ? "1 character" : "\(characters) characters"
            return (title, detail, .text, nil)
        }

        let typeNames = Set(values.map { $0.type.rawValue })
        let detail = typeNames.sorted().prefix(2).joined(separator: ", ")
        return ("Clipboard item", detail, .other, nil)
    }
}
