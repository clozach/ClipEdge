import AppKit

extension UpdateController.Environment {
    /// Wires the updater to the running app. Only the test fixture passes a different bundle name.
    @MainActor
    static func live(bundle: Bundle = .main, support: URL, archiveBundleName: String = "ClipEdge.app",
                     isBusy: @escaping () -> Bool, saveBeforeQuit: @escaping () -> Bool,
                     quit: @escaping () -> Void) -> UpdateController.Environment {
        let target = bundle.bundleURL
        let identifier = bundle.bundleIdentifier ?? "local.codex.ClipEdge"
        let version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppVersion.init) ?? AppVersion("0")!
        let availability = UpdateAvailability.resolve(
            bundle: target, feedText: bundle.object(forInfoDictionaryKey: "ClipEdgeUpdateFeed") as? String,
            isAdHoc: { UpdateVerifier.isAdHoc(appAt: target) },
            folderWritable: { FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) })
        let session = UpdateFetcher.session()
        let verify: (URL) throws -> Void = { candidate in
            try UpdateVerifier.check(candidate, satisfies: UpdateVerifier.requirementOfRunningApp())
        }
        return UpdateController.Environment(
            runningVersion: version, availability: availability, support: support,
            fetchRelease: { feed in
                try await UpdateFetcher.release(feed: feed, runningVersion: version.description, session: session)
            },
            fetchApp: { release, folder in
                try await UpdateFetcher.app(for: release, bundleName: archiveBundleName, runningVersion: version.description,
                                            in: folder, session: session)
            },
            verify: verify,
            installedVersion: UpdateVerifier.version(ofAppAt:),
            install: { staged, receipts in
                try UpdateInstaller.install(staged, over: target, identifier: identifier, receipts: receipts, verify: verify)
            },
            goBack: { receipt in try UpdateInstaller.goBack(using: receipt, identifier: identifier) },
            canGoBack: UpdateInstaller.canGoBack(using:),
            isBusy: isBusy,
            secondsSinceInput: {
                CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
            },
            saveBeforeQuit: saveBeforeQuit,
            reopenAndQuit: {
                UpdateInstaller.reopenAfterExit(target)
                quit()
            })
    }

    /// Beside the clipboard history, outside the app, so it survives each update.
    static var defaultSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipEdge/Updates", isDirectory: true)
    }
}
