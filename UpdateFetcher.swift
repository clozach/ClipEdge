import Foundation

/// The updater's only network use: one request for GitHub's latest release, and, when that
/// release is newer, one download. Nothing about the person or the clipboard is sent.
enum UpdateFetcher {
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 10 * 60
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    static func release(feed: URL, runningVersion: String, session: URLSession) async throws -> UpdateRelease {
        let (data, response) = try await answer { try await session.data(for: request(feed, runningVersion)) }
        try expectSuccess(response)
        return try UpdateFeed.release(from: data, allowLocal: feed.isFileURL).get()
    }

    /// Downloads the release into `folder` and returns the unpacked app. Nothing is run or installed.
    static func app(for release: UpdateRelease, bundleName: String, runningVersion: String,
                    in folder: URL, session: URLSession) async throws -> URL {
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let (downloaded, response) = try await answer { try await session.download(for: request(release.archive, runningVersion)) }
        try expectSuccess(response)
        let archive = folder.appendingPathComponent("download.zip")
        try fm.moveItem(at: downloaded, to: archive)
        let bytes = (try fm.attributesOfItem(atPath: archive.path)[.size] as? Int) ?? 0
        guard bytes > 0, bytes <= UpdateFeed.archiveLimit else { throw UpdateFailure.archiveTooLarge(bytes) }

        let entries = try run("/usr/bin/zipinfo", ["-1", archive.path]).split(separator: "\n").map(String.init)
        if let entry = UpdateArchive.unsafeEntry(in: entries, bundleName: bundleName) {
            throw UpdateFailure.unsafeArchive(entry)
        }
        let unpacked = folder.appendingPathComponent("unpacked")
        try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
        _ = try run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])
        try? fm.removeItem(at: archive)

        let app = unpacked.appendingPathComponent(bundleName)
        let values = try? app.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else {
            throw UpdateFailure.notClipEdge("the download does not contain \(bundleName)")
        }
        return app
    }

    private static func request(_ url: URL, _ runningVersion: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("ClipEdge/\(runningVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json, application/octet-stream", forHTTPHeaderField: "Accept")
        return request
    }

    private static func answer<T>(_ work: () async throws -> T) async throws -> T {
        do { return try await work() }
        catch let error as UpdateFailure { throw error }
        catch { throw UpdateFailure.offline(error.localizedDescription) }
    }

    private static func expectSuccess(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard http.statusCode == 200 else {
            throw UpdateFailure.feedUnreadable(http.statusCode == 404 ? "no release is published yet"
                                                                       : "GitHub answered \(http.statusCode)")
        }
    }

    private static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch { throw UpdateFailure.unsafeArchive("could not open the download") }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateFailure.unsafeArchive("the download is not a readable archive") }
        return String(decoding: data, as: UTF8.self)
    }
}
