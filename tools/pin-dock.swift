// Explicit opt-in Dock pin. Preserves every unrelated tile.
import AppKit
import CoreFoundation

let domain = "com.apple.dock" as CFString
let key = "persistent-apps" as CFString
let target = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/ClipEdge.app")
guard FileManager.default.fileExists(atPath: target.appendingPathComponent("Contents/Info.plist").path) else {
    fatalError("Install ClipEdge before pinning it")
}
func tiles() -> [[String: Any]] {
    guard let current = CFPreferencesCopyAppValue(key, domain) as? [[String: Any]] else {
        fatalError("Cannot read existing Dock tiles; no preferences changed")
    }
    return current
}
func matches(_ tile: [String: Any]) -> Bool {
    guard let data = tile["tile-data"] as? [String: Any],
          let file = data["file-data"] as? [String: Any],
          let path = file["_CFURLString"] as? String else { return false }
    return path == target.path || URL(string: path)?.standardizedFileURL == target.standardizedFileURL
}
let before = tiles()
if before.contains(where: matches) {
    print("ClipEdge already pinned; no preferences changed")
} else {
    let tile: [String: Any] = [
        "GUID": UInt32.random(in: 1...UInt32.max),
        "tile-type": "file-tile",
        "tile-data": [
            "file-data": ["_CFURLString": target.path, "_CFURLStringType": 0],
            "file-label": "ClipEdge", "file-type": 41,
            "bundle-identifier": "local.codex.ClipEdge"
        ]
    ]
    CFPreferencesSetAppValue(key, (before + [tile]) as CFArray, domain)
    guard CFPreferencesAppSynchronize(domain), tiles().contains(where: matches) else {
        fatalError("Dock pin did not synchronize")
    }
    print("Appended one ClipEdge pin; preserved \(before.count) existing tiles")
    for dock in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock") {
        print("Requested graceful Dock reload: \(dock.terminate())")
    }
}
