import AppKit

/// A stand-in app for the end-to-end update check. It carries ClipEdge's real updater and nothing
/// else: no clipboard, no shortcuts, no windows. It has its own bundle identifier, so it can run
/// while ClipEdge runs. Each launch appends what it did to `log.txt` two folders above the bundle.
@main enum UpdateFixture {
    @MainActor static func main() {
        let bundle = Bundle.main
        let root = bundle.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        let log = root.appendingPathComponent("log.txt")
        func note(_ text: String) {
            let line = Data((text + "\n").utf8)
            if let handle = try? FileHandle(forWritingTo: log) {
                handle.seekToEndOfFile(); handle.write(line); try? handle.close()
            } else {
                try? line.write(to: log)
            }
        }
        let controller = UpdateController(environment: .live(
            support: root.appendingPathComponent("support"), archiveBundleName: bundle.bundleURL.lastPathComponent,
            isBusy: { false }, saveBeforeQuit: { true },
            quit: { note("quit \(ProcessInfo.processInfo.processIdentifier)"); exit(EXIT_SUCCESS) }))
        let version = controller.runningVersion
        note("launch \(version) pid \(ProcessInfo.processInfo.processIdentifier) availability \(controller.availability)")
        controller.start(repeating: false)

        Task { @MainActor in
            if let record = controller.lastUpdate {
                note("updated from \(record.from) to \(record.to); way back: \(controller.canGoBack)")
                if let failure = controller.goBack() { note("go back failed: \(UpdateStatus.message(for: failure))"); exit(EXIT_FAILURE) }
                return
            }
            if controller.preference == .manual {
                note("back on \(version); automatic updates off; done")
                exit(EXIT_SUCCESS)
            }
            controller.choose(.automatic)
            switch await controller.check() {
            case .ready(let staged):
                note("ready \(staged.release.version)")
                if let failure = controller.installNow() { note("install failed: \(UpdateStatus.message(for: failure)); done"); exit(EXIT_FAILURE) }
            case .resting(.failed(_, let failure)):
                note("refused: \(UpdateStatus.message(for: failure)); done")
                exit(EXIT_SUCCESS)
            case .resting(.current):
                note("newest; done")
                exit(EXIT_SUCCESS)
            case .resting(nil), .checking, .downloading:
                note("no check ran; done")
                exit(EXIT_SUCCESS)
            }
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.run()
    }
}
