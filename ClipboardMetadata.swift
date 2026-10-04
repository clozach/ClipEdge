import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Quiet facts along the edge of history cards, drawer tiles and cursor magnets:
/// counts for text, size facts for pictures and sound, paths for Finder items.
struct ClipboardMetadata: Equatable {
    var facts: [String] = []
    var paths: [String] = []

    var isEmpty: Bool { facts.isEmpty && paths.isEmpty }
    var line: String { facts.joined(separator: " · ") }
    /// Paths with the home folder shortened. Display only; paste uses `paths`.
    var displayPaths: [String] { paths.map { ($0 as NSString).abbreviatingWithTildeInPath } }
    /// Facts first, then each path, for surfaces that wrap.
    var lines: [String] { ([line] + displayPaths).filter { !$0.isEmpty } }
    /// One line for a narrow row; `lines` stays within reach in previews and help.
    var compact: String { lines.joined(separator: " · ") }
    /// What a plain-text paste inserts for an item with no text of its own.
    var pasteText: String { (paths + [line]).filter { !$0.isEmpty }.joined(separator: "\n") }
}

extension ClipboardMetadata {
    static func text(_ string: String) -> ClipboardMetadata {
        var characters = 0, words = 0, inWord = false
        for character in string {
            characters += 1
            let isSpace = character.isWhitespace
            if !isSpace && !inWord { words += 1 }
            inWord = !isSpace
        }
        return ClipboardMetadata(facts: [count(words, "word"), count(characters, "character")])
    }

    static func image(_ data: Data, type: NSPasteboard.PasteboardType) -> ClipboardMetadata {
        var facts: [String] = []
        if let source = CGImageSourceCreateWithData(data as CFData, nil), let size = pixelSize(source) {
            facts.append(dimensions(size))
        }
        facts.append(bytes(data.count))
        facts.append(UTType(type.rawValue)?.preferredFilenameExtension?.uppercased() ?? "Image")
        return ClipboardMetadata(facts: facts)
    }

    /// Reads the disk and media headers; call it off the main thread.
    static func files(_ urls: [URL]) -> ClipboardMetadata {
        let paths = urls.map(\.path)
        guard urls.count == 1, let url = urls.first else {
            let sizes = urls.compactMap { url -> Int? in
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                return values?.isDirectory == true ? nil : values?.fileSize
            }
            return ClipboardMetadata(facts: ["\(urls.count) items"] + (sizes.isEmpty ? [] : [bytes(sizes.reduce(0, +))]), paths: paths)
        }
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .contentTypeKey, .localizedTypeDescriptionKey]) else {
            return ClipboardMetadata(facts: ["File not found"], paths: paths)
        }
        var facts: [String] = []
        if values.contentType?.conforms(to: .image) == true,
           let source = CGImageSourceCreateWithURL(url as CFURL, nil), let size = pixelSize(source) {
            facts.append(dimensions(size))
        }
        if values.contentType?.conforms(to: .audiovisualContent) == true {
            let media = mediaFacts(url)
            if let size = media.size { facts.append(dimensions(size)) }
            if let seconds = media.seconds { facts.append(duration(seconds)) }
        }
        if values.isDirectory != true, let size = values.fileSize { facts.append(bytes(size)) }
        facts.append(url.pathExtension.isEmpty ? (values.localizedTypeDescription ?? "File") : url.pathExtension.uppercased())
        return ClipboardMetadata(facts: facts, paths: paths)
    }

    /// No disk reads. A Finder item starts with its paths; `files` adds the rest.
    static func immediate(for entry: ClipboardEntry) -> ClipboardMetadata {
        if !entry.fileURLs.isEmpty { return ClipboardMetadata(paths: entry.fileURLs.map(\.path)) }
        switch entry.kind {
        case .image:
            guard let value = entry.values.first(where: { ClipboardFlavors.images.contains($0.type) }) else { return ClipboardMetadata() }
            return image(value.data, type: value.type)
        case .link:
            let host = entry.plainText.flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }?.host
            return ClipboardMetadata(facts: [host ?? "Link"])
        case .text, .file, .other:
            return entry.plainText.map(text) ?? ClipboardMetadata()
        }
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let (hours, minutes, rest) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }

    private static func count(_ value: Int, _ noun: String) -> String {
        "\(value.formatted()) \(noun)\(value == 1 ? "" : "s")"
    }
    private static func dimensions(_ size: CGSize) -> String { "\(Int(size.width)) × \(Int(size.height))" }
    private static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
    private static func pixelSize(_ source: CGImageSource) -> CGSize? {
        guard CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }
    /// Sound and video headers load asynchronously; wait briefly off the main thread.
    private static func mediaFacts(_ url: URL) -> (seconds: Double?, size: CGSize?) {
        final class Result: @unchecked Sendable { var seconds: Double?; var size: CGSize? }
        let result = Result()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let asset = AVURLAsset(url: url)
            if let time = try? await asset.load(.duration), time.isNumeric { result.seconds = time.seconds }
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let natural = try? await track.load(.naturalSize), natural.width > 0 { result.size = natural }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 3)
        return (result.seconds, result.size)
    }
}
