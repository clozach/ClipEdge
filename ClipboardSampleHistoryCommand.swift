import AppKit

/// `ClipEdge --sample-history <command>`: curates the sample history from Terminal, for agents
/// staging a scenario. It edits the file only while ClipEdge is not showing it (a running
/// ClipEdge on the sample history would save over the edit).
enum ClipboardSampleHistoryCommand {
    static let usage = """
    usage: ClipEdge --sample-history <command>
      list                 numbered entries, newest first (1 shows at the top)
      move FROM TO         move entry FROM to position TO
      remove N             delete entry N (the file's previous version goes to the Trash)
      seed [--replace]     fill an empty sample from the real history; --replace moves the old one to the Trash
      path                 print the sample history's file
    """

    struct Environment {
        var directory: URL?
        var sampleIsShowing: () -> Bool
        var trash: (URL) throws -> Void
        var print: (String) -> Void

        static var live: Environment {
            Environment(directory: ClipboardHistorySource.directory, sampleIsShowing: {
                let me = ProcessInfo.processInfo.processIdentifier
                let running = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.codex.ClipEdge")
                    .contains { $0.processIdentifier != me && !$0.isTerminated }
                return running && ClipboardHistorySource.saved() == .sample
            }, trash: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
            print: { Swift.print($0) })
        }
    }

    /// The exit status: 0 done, 1 refused or failed, 64 a malformed command.
    static func run(_ arguments: [String], environment env: Environment = .live) -> Int32 {
        guard let sampleURL = ClipboardHistorySource.sample.url(in: env.directory),
              let realURL = ClipboardHistorySource.real.url(in: env.directory) else {
            env.print("No Application Support folder."); return 1
        }
        let command = arguments.first ?? ""
        let numbers = arguments.dropFirst().compactMap { Int($0) }
        let writes = ["move", "remove", "seed"].contains(command)
        if writes && env.sampleIsShowing() {
            env.print("ClipEdge is showing the sample history. Switch it to the real history first (hold Option in its menu), then run this again.")
            return 1
        }
        do {
            switch (command, numbers.count) {
            case ("path", _):
                env.print(sampleURL.path); return 0
            case ("list", _):
                let records = try ClipboardHistoryFile.read(sampleURL) ?? []
                if records.isEmpty { env.print("The sample history is empty or not seeded yet.") }
                for (index, record) in records.enumerated() {
                    let entry = ClipboardHistoryFile.entry(record)
                    let kind = ClipboardSampleHistory.seedKind(entry) ?? "other"
                    env.print("\(index + 1)\t\(kind)\t\(ClipboardSampleHistory.menuLabel(entry.title))")
                }
                return 0
            case ("move", 2):
                let records = try ClipboardHistoryFile.read(sampleURL) ?? []
                guard let moved = ClipboardSampleHistory.moving(records, from: numbers[0], to: numbers[1]) else {
                    env.print("Positions run from 1 to \(records.count)."); return 1
                }
                return save(moved, to: sampleURL, env)
            case ("remove", 1):
                let records = try ClipboardHistoryFile.read(sampleURL) ?? []
                guard let kept = ClipboardSampleHistory.removing(records, at: numbers[0]) else {
                    env.print("Positions run from 1 to \(records.count)."); return 1
                }
                try keepPrevious(sampleURL, env)
                return save(kept, to: sampleURL, env)
            case ("seed", _):
                if ClipboardHistoryFile.exists(sampleURL) {
                    guard arguments.contains("--replace") else {
                        env.print("A sample history exists. Add --replace to move it to the Trash and seed a new one."); return 1
                    }
                    try ClipboardHistoryFile.parts(of: sampleURL).forEach(env.trash)
                }
                let real = (try ClipboardHistoryFile.read(realURL) ?? []).map(ClipboardHistoryFile.entry)
                let seeded = ClipboardSampleHistory.seed(from: real)
                env.print("Seeded \(seeded.count) entries from the real history.")
                return save(seeded.map(ClipboardHistoryFile.record), to: sampleURL, env)
            default:
                env.print(usage); return 64
            }
        } catch {
            env.print("The sample history could not be read: \(error.localizedDescription)"); return 1
        }
    }

    /// A removal can't be undone from the history alone, so its previous version goes to the Trash:
    /// a copy of each part (the old file, the store folder) under a dated name.
    private static func keepPrevious(_ url: URL, _ env: Environment) throws {
        let stamp = Int(Date().timeIntervalSince1970)
        for part in ClipboardHistoryFile.parts(of: url) {
            let copy = part.deletingLastPathComponent()
                .appendingPathComponent("History before removal \(stamp).\(part.pathExtension)")
            try FileManager.default.copyItem(at: part, to: copy)
            try env.trash(copy)
        }
    }

    private static func save(_ records: [ClipboardHistoryFile.Record], to url: URL, _ env: Environment) -> Int32 {
        guard ClipboardHistoryFile.write(records, to: url) else { env.print("The sample history could not be saved."); return 1 }
        return 0
    }
}
