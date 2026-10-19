import AppKit

/// Where a brief may be written: the vault holding this ClipEdge's source, found
/// from the maintainer build's publisher tool and nowhere else. Ordinary and
/// released copies have no tool, so they have no vault and no brief.
struct ClipboardPreviewBriefVault: Equatable {
    let root: URL
    private static let toolSuffix = ["projects", "clipedge", "src", "tools", "publisher.sh"]

    /// Nil unless the tool sits at <vault>/projects/clipedge/src/tools/publisher.sh
    /// and that source folder exists.
    init?(publisherTool: URL) {
        let tool = publisherTool.standardizedFileURL
        let components = tool.pathComponents
        guard components.count > Self.toolSuffix.count, Array(components.suffix(Self.toolSuffix.count)) == Self.toolSuffix else { return nil }
        var ancestor = tool
        for _ in Self.toolSuffix { ancestor.deleteLastPathComponent() }
        var isDirectory: ObjCBool = false
        let source = ancestor.appendingPathComponent("projects/clipedge/src", isDirectory: true)
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        self.root = ancestor
    }
    /// "amaanah": the vault as Obsidian names it, from its folder.
    var name: String { root.lastPathComponent }
    var projects: URL { root.appendingPathComponent("projects", isDirectory: true) }
    func contract(slug: String) -> URL {
        projects.appendingPathComponent("clipedge-preview-\(slug)", isDirectory: true).appendingPathComponent("AGENTS.md")
    }
}

/// One written brief: where it landed and the text to hand an agent.
struct ClipboardPreviewBriefRecord: Equatable {
    /// "projects/clipedge-preview-iwork/AGENTS.md", as the vault reads it.
    let path: String
    let url: URL
    let obsidianURL: URL
    /// The whole file after writing, for Copy prompt.
    let prompt: String
    /// True when the project already existed and gained a request instead.
    let appended: Bool
    var sentence: String { "\(appended ? "Request added to" : "Brief written"): \(path)" }
}

enum ClipboardPreviewBriefResult: Equatable {
    case written(ClipboardPreviewBriefRecord)
    /// A plain sentence for the form's place; never a modal.
    case failed(String)
}

/// Writes briefs into the vault and hands them on: the one object the window's
/// form and the drawer's form share. Absent in ordinary and released copies.
struct ClipboardPreviewAsker {
    let vault: ClipboardPreviewBriefVault
    var now: () -> Date = Date.init
    /// Copy prompt writes here, marked transient so ClipEdge never records it.
    var pasteboard: NSPasteboard = .general
    var open: (URL) -> Void = { NSWorkspace.shared.open($0) }
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    func write(_ entry: ClipboardEntry, note: String?) -> ClipboardPreviewBriefResult {
        write(ClipboardPreviewBrief(entry: entry, note: note))
    }

    /// True for a ClipEdge brief still open: the alias is its own, and it is not
    /// completed or abandoned. A closed brief, or another project at its place,
    /// is left as found.
    static func isOpenBrief(_ text: String, alias: String) -> Bool {
        guard text.hasPrefix("---\n"), let end = text.range(of: "\n---\n") else { return false }
        let lines = text[text.startIndex..<end.lowerBound].split(separator: "\n")
        func value(_ key: String) -> String? { lines.first { $0.hasPrefix(key) }.map { $0.dropFirst(key.count).trimmingCharacters(in: .whitespaces) } }
        let aliases = (value("aliases:") ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[]")).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let status = value("status:") ?? ""
        return aliases.contains(alias) && status != "completed" && status != "abandoned"
    }

    /// Creates the project, or appends a request to an open brief at its place;
    /// past a closed brief or another project there, the brief is written beside
    /// it, dated. Never overwrites.
    func write(_ brief: ClipboardPreviewBrief) -> ClipboardPreviewBriefResult {
        let fm = FileManager.default
        var file = vault.contract(slug: brief.slug)
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: vault.projects.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failed("The vault's projects folder is not at \(vault.projects.path), so no brief was written.")
        }
        // The slug cannot hold a separator, and this is the check that says so;
        // every later candidate shares the prefix.
        guard file.standardizedFileURL.path.hasPrefix(vault.projects.standardizedFileURL.path + "/clipedge-preview-") else {
            return .failed("The brief's place is outside the vault's projects folder, so it was not written.")
        }
        let day = Self.day(now())
        var name = "clipedge-preview-\(brief.slug)", appended = false, extra = 0
        while fm.fileExists(atPath: file.path) {
            if let text = try? String(contentsOf: file, encoding: .utf8), Self.isOpenBrief(text, alias: name) { appended = true; break }
            extra += 1
            let dated = "\(brief.slug)-\(day)" + (extra > 1 ? "-\(extra)" : "")
            name = "clipedge-preview-\(dated)"
            file = vault.contract(slug: dated)
        }
        do {
            if appended {
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(brief.request(on: day).utf8))
            } else {
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(brief.document(on: day, project: name).utf8).write(to: file, options: .withoutOverwriting)
            }
            let prompt = try String(contentsOf: file, encoding: .utf8)
            let path = "projects/\(name)/AGENTS.md"
            return .written(ClipboardPreviewBriefRecord(path: path, url: file, obsidianURL: Self.obsidianURL(vault: vault.name, path: path),
                                                        prompt: prompt, appended: appended))
        } catch {
            return .failed("The brief could not be written to \(file.path): \(error.localizedDescription)")
        }
    }

    /// The brief's text on the clipboard, marked transient: ClipEdge's own
    /// capture skips it, so the history never shows it.
    @discardableResult
    func copyPrompt(_ record: ClipboardPreviewBriefRecord) -> Bool {
        let item = NSPasteboardItem()
        item.setString(record.prompt, forType: .string)
        item.setData(Data(), forType: Self.transientType)
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    func openInObsidian(_ record: ClipboardPreviewBriefRecord) { open(record.obsidianURL) }

    /// obsidian://open?vault=amaanah&file=projects/clipedge-preview-iwork/AGENTS (no .md).
    static func obsidianURL(vault: String, path: String) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._/"))
        let note = path.hasSuffix(".md") ? String(path.dropLast(3)) : path
        let file = note.addingPercentEncoding(withAllowedCharacters: allowed) ?? note
        let name = vault.addingPercentEncoding(withAllowedCharacters: allowed) ?? vault
        return URL(string: "obsidian://open?vault=\(name)&file=\(file)")!
    }

    /// Today as the vault dates things: 2026-10-11, in the Mac's own time zone.
    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
