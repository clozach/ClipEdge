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

    /// Every visible subview of `container` but Publish keeps out of the band above Publish and the band
    /// to its right, each reaching the container's edges, so the corner between them is clear too. Both
    /// containers are flipped: y grows down from the top edge.
    private static func cornerIsClear(_ control: ClipboardPublishControl, in container: NSView) -> Bool {
        let publish = control.frame, bounds = container.bounds
        let above = NSRect(x: publish.minX, y: bounds.minY, width: bounds.maxX - publish.minX, height: publish.minY - bounds.minY)
        let right = NSRect(x: publish.maxX, y: bounds.minY, width: bounds.maxX - publish.maxX, height: publish.maxY - bounds.minY)
        return container.subviews.allSatisfy { view in
            view === control || view.isHidden || view.frame.isEmpty || (!view.frame.intersects(above) && !view.frame.intersects(right))
        }
    }

    /// Al, 2026-10-12: nothing above Publish or to its right, it disturbs the corner's symmetry. In the
    /// window Publish has the top-right corner alone (Delete all is gone) and the tabs end 8 points short
    /// of it; in the drawer's header it takes the right edge, the gear 6 points to its left, and the gear
    /// keeps the edge while Publish is hidden. Every state that shows Publish, at the window's own size.
    private static func cornerChecks(header: ClipboardDrawerHeader, window: ClipboardHistoryView, difference: PublishDifference) {
        let candidate = PublishCandidate(id: "fixture", version: "2.3.1", fingerprint: String(repeating: "a", count: 64),
            archiveSHA256: String(repeating: "b", count: 64), changes: "Fixture", previousVersion: "2.3")
        let shown: [PublishState] = [.checking, .unknown("Offline"), .rebuildRequired("Source changed"), .different(difference), .preparing(difference),
            .ready(candidate, difference), .reviewing(candidate, difference), .publishing(candidate, difference), .verifying(candidate, difference),
            .failed("Fixture", difference), .publishFailed("Fixture", candidate, difference)]
        check(window.frame.size == ClipboardHistoryController.preferredSize, "the window is checked at its own size")
        check(!window.subviews.contains { ($0 as? NSButton)?.title.hasPrefix("Delete all") == true }, "the window has no Delete all button")
        for state in shown {
            let presentation = state.presentation
            for control in [header.publishControl, window.publishControl] { control.apply(presentation) }
            header.layoutSubtreeIfNeeded(); window.layoutSubtreeIfNeeded()
            let name = presentation.title
            for (place, control, container) in [("drawer", header.publishControl, header as NSView), ("window", window.publishControl, window as NSView)] {
                check(!control.isHidden && control.frame.maxX == container.bounds.maxX - 16, "\(name): \(place)'s Publish sits 16 points from the right edge")
                check(cornerIsClear(control, in: container), "\(name): nothing in the \(place) sits above Publish or to its right")
            }
            check(window.publishControl.frame.minY == 12 && window.publishControl.frame.height == 22, "\(name): the window's Publish is level with the tabs, at the top")
            let tabs = window.tabs
            check(tabs.frame.maxX + 8 <= window.publishControl.frame.minX && (0..<tabs.segmentCount).allSatisfy { tabs.width(forSegment: $0) >= tabs.titles[$0].size(font: tabs.font!).width + 2 * ClipboardTabBar.padding },
                  "\(name): the window's tabs, each at its whole label, end at least 8 points short of Publish (\(tabs.frame.maxX) + 8 ≤ \(window.publishControl.frame.minX))")
            let gear = header.settingsButton.frame
            check(gear.maxX + 6 == header.publishControl.frame.minX, "\(name): the drawer's gear sits 6 points left of Publish")
        }
        header.publishControl.apply(PublishState.current(version: "2.3.1").presentation)
        header.layoutSubtreeIfNeeded()
        check(header.publishControl.isHidden && header.settingsButton.frame == NSRect(x: header.bounds.width - 42, y: 5, width: 28, height: 26),
              "with Publish hidden, the gear keeps its place at the right edge")
    }

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
        let cardFrame = window.flip.frame
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
        check(cardFrame == window.flip.frame, "release states never move clipboard card")
        check(!header.publishControl.frame.intersects(header.settingsButton.frame), "drawer action avoids Settings")
        cornerChecks(header: header, window: window, difference: difference)
        progressFill(difference)
        print("Publish control tests passed (\(assertions) assertions)")
    }
}
