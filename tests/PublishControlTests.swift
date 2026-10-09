import AppKit

@main enum PublishControlTests {
    private static var assertions = 0
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError("FAIL: \(message)") }
    }
    private static func key(_ modifiers: NSEvent.ModifierFlags = [.command, .shift]) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
            context: nil, characters: "p", charactersIgnoringModifiers: "p", isARepeat: false, keyCode: 35)!
    }
    /// Samples a row above the title so the text cannot hide the fill boundary.
    private static func alphas(_ control: ClipboardPublishControl, at points: [CGFloat]) -> [CGFloat] {
        alphas(control, at: points.map { CGPoint(x: $0, y: 4) })
    }
    /// Top-left origin, in points; each sample reads the device pixel that contains it.
    private static func alphas(_ control: ClipboardPublishControl, at points: [CGPoint]) -> [CGFloat] {
        let rep = control.bitmapImageRepForCachingDisplay(in: control.bounds)!
        control.cacheDisplay(in: control.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / control.bounds.width
        return points.map { rep.colorAt(x: Int($0.x * scale), y: Int($0.y * scale))?.alphaComponent ?? -1 }
    }
    /// Pixels inside the bounds but outside the 1 pt inset and the 6 pt corner, at 1x and 2x alike,
    /// and one just inside the curve, which the fill must reach.
    private static let leftCorner = [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 1, y: 1), CGPoint(x: 1.5, y: 1.5)]
    private static let rightCorner = [CGPoint(x: 198.5, y: 0.5), CGPoint(x: 198, y: 2)]
    private static let insideCurve = [CGPoint(x: 4, y: 4)]

    private static func progressFill(_ difference: PublishDifference) {
        let candidate = PublishCandidate(id: "fixture", version: "2.3.1", fingerprint: String(repeating: "a", count: 64),
            archiveSHA256: String(repeating: "b", count: 64), changes: "Fixture", previousVersion: "2.3")
        let control = ClipboardPublishControl()
        control.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
        let plain = PublishState.publishing(candidate, difference).presentation
        control.apply(plain)
        let width = control.intrinsicContentSize.width
        let busy = alphas(control, at: [20, 95, 105, 180])
        check(control.progress == nil && control.accessibilityValue() == nil, "no telemetry draws no fill")
        check(busy.allSatisfy { abs($0 - 0.55) < 0.05 }, "without telemetry the busy lozenge keeps its even dimmed pink")
        var posts = 0
        control.postValueChange = { _ in posts += 1 }
        var half = plain; half.progress = 0.5
        control.apply(half)
        let filled = alphas(control, at: [20, 95, 105, 180])
        check(filled[0] > 0.95 && filled[1] > 0.95, "the finished half fills from the left at full strength")
        check(abs(filled[2] - 0.55) < 0.05 && abs(filled[3] - 0.55) < 0.05, "the unfinished half stays the dimmed track")
        check(alphas(control, at: leftCorner).allSatisfy { $0 < 0.05 } && alphas(control, at: insideCurve).allSatisfy { $0 > 0.95 },
              "the fill keeps the lozenge's rounded, inset corner")
        check(control.accessibilityValue() as? String == "50 percent", "VoiceOver hears the percent")
        check(posts == 1, "a new percent posts one value-changed notice")
        half.progress = 0.504
        control.apply(half)
        check(posts == 1, "a redraw within the same percent stays silent")
        check(control.intrinsicContentSize.width == width && control.title == plain.title, "the fill never resizes or retitles the lozenge")
        half.progress = 7
        control.apply(half)
        check(alphas(control, at: [195]).allSatisfy { $0 > 0.95 } && control.accessibilityValue() as? String == "100 percent",
              "an out-of-range fraction is clamped to a full lozenge")
        check(alphas(control, at: leftCorner + rightCorner).allSatisfy { $0 < 0.05 } && alphas(control, at: insideCurve).allSatisfy { $0 > 0.95 },
              "a full fill keeps every corner rounded and inset")
        check(posts == 2, "reaching 100 percent is announced")
        control.apply(PublishState.different(difference).presentation)
        check(control.progress == nil && alphas(control, at: [20, 180]).allSatisfy { $0 > 0.95 }, "leaving progress restores the bright action")
        control.apply(half)
        check(posts == 3, "a later command announces its progress afresh")
    }

    static func main() {
        _ = NSApplication.shared
        let isolated = FileManager.default.temporaryDirectory.appendingPathComponent("ClipEdge-publish-preview-test-" + UUID().uuidString)
        let previousOverride = ProcessInfo.processInfo.environment["CLIPEDGE_TEST_PREVIEW_ROOT"]
        setenv("CLIPEDGE_TEST_PREVIEW_ROOT", isolated.path, 1)
        let materializer = ClipboardMaterializer()
        let entry = ClipboardEntry(fingerprint: "isolated", capturedAt: Date(), payloads: [ClipboardPayload(values: [(.string, Data("Fixture only".utf8))])], title: "Fixture only", detail: "", kind: .text, thumbnail: nil)
        let files = try! materializer.urls(for: entry)
        check(files.count == 1 && files[0].path.hasPrefix(isolated.path + "/") && FileManager.default.fileExists(atPath: files[0].path), "preparation fixtures create real previews only in their isolated namespace")
        materializer.removeAll()
        try? FileManager.default.removeItem(at: isolated)
        if let previousOverride { setenv("CLIPEDGE_TEST_PREVIEW_ROOT", previousOverride, 1) } else { unsetenv("CLIPEDGE_TEST_PREVIEW_ROOT") }
        let difference = PublishDifference(latestVersion: "2.3", detail: "Unpublished changes")
        let header = ClipboardDrawerHeader(appIcon: nil)
        header.frame = NSRect(x: 0, y: 0, width: 380, height: 36)
        let window = ClipboardHistoryView(frame: NSRect(x: 0, y: 0, width: 800, height: 470))
        window.layoutSubtreeIfNeeded()
        let cardFrame = window.card.frame
        for control in [header.publishControl, window.publishControl] {
            var pressed = 0
            control.onPress = { pressed += 1 }
            check(control.isHidden && !control.handleKey(key()), "no action before maintainer status")
            control.apply(PublishState.different(difference).presentation)
            control.superview?.layoutSubtreeIfNeeded()
            check(!control.isHidden && control.isEnabled, "unpublished content exposes enabled action")
            let size = (control.title as NSString).size(withAttributes: [.font: control.font!])
            check(control.bounds.width >= size.width + 6, "complete title and shortcut fit")
            check(control.handleKey(key()) && pressed == 1, "explicit shortcut invokes preparation once")
            check(!control.handleKey(key(.command)) && pressed == 1, "ordinary command-P does not publish")
            control.apply(PublishState.preparing(difference).presentation)
            check(!control.isEnabled && control.handleKey(key()) && pressed == 1, "busy shortcut cannot start a second preparation")
            control.apply(PublishState.current(version: "2.3.1").presentation)
            check(control.isHidden && !control.handleKey(key()), "verified equality removes control and shortcut")
            control.apply(PublishState.unknown("Offline").presentation)
            check(!control.isHidden && control.title.contains("Check release"), "unavailable check stays visible and distinct")
        }
        window.layoutSubtreeIfNeeded()
        check(cardFrame == window.card.frame, "release states never move clipboard card")
        check(!header.publishControl.frame.intersects(header.settingsButton.frame), "drawer action avoids Settings")
        check(!window.publishControl.frame.intersects(window.deleteAll.frame), "window action avoids Delete all")
        progressFill(difference)
        print("Publish control tests passed (\(assertions) assertions)")
    }
}
