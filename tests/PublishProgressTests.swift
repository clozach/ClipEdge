import AppKit

/// Progress telemetry from the release helper: the line contract, the eased
/// fill, and the file tail the app reads while prepare or publish runs.
@main enum PublishProgressTests {
    static var assertions = 0
    static func check(_ condition: Bool, _ message: String) {
        assertions += 1
        guard condition else { fatalError("FAIL: \(message)") }
    }
    static var line: [String: Any] {
        ["schema": 1, "command": "prepare", "step": "tests", "label": "Running the regression checks",
         "index": 1, "count": 6, "start": 0.1, "end": 0.6, "expectedSeconds": 120]
    }
    static func data(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
    static func decode(_ object: [String: Any], command: String = "prepare") -> PublishProgressEvent? {
        PublishProgressEvent.decode(data(object), command: command)
    }
    static func with(_ key: String, _ value: Any?) -> [String: Any] { var copy = line; copy[key] = value; return copy }

    @MainActor static func main() async throws {
        decoding()
        easing()
        reading()
        try await polling()
        print("Publish progress tests passed: \(assertions) assertions")
    }

    static func decoding() {
        let event = decode(line)
        check(event == PublishProgressEvent(command: "prepare", step: "tests", label: "Running the regression checks",
                                            index: 1, count: 6, start: 0.1, end: 0.6, expectedSeconds: 120), "a contract line decodes")
        let done: [String: Any] = ["schema": 1, "command": "prepare", "step": "done", "label": "Done",
                                   "index": 6, "count": 6, "start": 1, "end": 1, "expectedSeconds": 0]
        check(decode(done)?.isDone == true, "done may use index == count")
        check(decode(done, command: "publish") == nil, "a line for another command is refused")
        var bad = done; bad["start"] = 0.9
        check(decode(bad) == nil, "done must sit at the end")
        check(decode(with("index", 6)) == nil, "only done may use index == count")
        check(decode(with("step", "done")) == nil, "done must use index == count")
        let refused: [(String, Any?, String)] = [
            ("schema", 2, "a future schema"), ("schema", true, "a boolean schema"), ("schema", nil, "a missing field"),
            ("command", "status", "a status command"), ("step", "Tests", "an uppercase step"), ("step", "1tests", "a step starting with a digit"),
            ("step", String(repeating: "a", count: 33), "a step over 32 characters"), ("step", "tests\n", "a step with a newline"),
            ("step", "", "an empty step"), ("label", "", "an empty label"), ("label", "   ", "a blank label"),
            ("label", String(repeating: "x", count: 81), "a label over 80 characters"), ("label", "Running\nchecks", "a label with a newline"),
            ("label", "Running\u{202E}checks", "a label with a direction override"), ("label", "Run\u{0007}", "a label with a control character"),
            ("label", 7, "a numeric label"), ("index", -1, "a negative index"), ("index", 1.5, "a fractional index"),
            ("index", true, "a boolean index"), ("count", 0, "an empty plan"), ("count", 33, "a plan over 32 steps"),
            ("start", -0.1, "a negative start"), ("start", 1.1, "a start past the end"), ("end", 0.05, "an end before its start"),
            ("end", 1.01, "an end past 1"), ("expectedSeconds", -1, "a negative duration"),
            ("expectedSeconds", 3_601, "a duration over an hour"), ("expectedSeconds", "120", "a duration as text"),
            ("extra", "x", "an unknown field"),
        ]
        for (key, value, name) in refused { check(decode(with(key, value)) == nil, "\(name) is refused") }
        check(decode(with("label", String(repeating: "x", count: 80))) != nil, "an 80-character label is allowed")
        check(decode(with("label", "Signing ClipEdge 2.3.1 — universal")) != nil, "ordinary punctuation is allowed")
        check(decode(with("step", "sign-universal-2")) != nil, "hyphens and digits are allowed after the first letter")
        check(decode(with("index", 1.0)) != nil, "an integral number is an integer")
        check(PublishProgressEvent.decode(Data("[1]".utf8), command: "prepare") == nil, "a non-object is refused")
        check(PublishProgressEvent.decode(Data("{\"schema\":1".utf8), command: "prepare") == nil, "a partial object is refused")
        let utf16 = String(data: data(line), encoding: .utf8)!.data(using: .utf16)!
        check(PublishProgressEvent.decode(utf16, command: "prepare") == nil, "only UTF-8 is read")
        var long = data(with("label", "Short"))
        long.append(Data(repeating: 0x20, count: 1_025 - long.count))
        check(long.count == 1_025 && PublishProgressEvent.decode(long, command: "prepare") == nil, "a line over 1024 bytes is refused")
        check(PublishProgressEvent.decode(long.dropLast(), command: "prepare") != nil, "a 1024-byte line is allowed")
    }

    static func easing() {
        let step = PublishProgressEvent(command: "publish", step: "push", label: "Pushing", index: 0, count: 2,
                                        start: 0.2, end: 0.6, expectedSeconds: 10)
        check(PublishProgressTrack.estimate(step, elapsed: 0) == 0.2, "a step begins at its start")
        check(abs(PublishProgressTrack.estimate(step, elapsed: 6) - (0.2 + 0.4 * (1 - exp(-1)))) < 1e-12, "the fill eases with a 0.6 × expected time constant")
        check(abs(PublishProgressTrack.estimate(step, elapsed: 1e9) - 0.596) < 1e-12, "the fill stops 1% of the step short of its end")
        check(PublishProgressTrack.estimate(step, elapsed: -5) == 0.2, "a clock moving backwards cannot move the fill back")
        var instant = step; instant.expectedSeconds = 0
        check(abs(PublishProgressTrack.estimate(instant, elapsed: 0.5) - (0.2 + 0.4 * (1 - exp(-1)))) < 1e-12, "an instant step still eases over at least half a second")
        var track = PublishProgressTrack(command: "publish", generation: 1)
        let begin = Date(timeIntervalSince1970: 0)
        check(track.label == nil && track.fraction == 0, "a new track has no step")
        check(track.accept(step, at: begin) && track.fraction == 0.2, "the first step is accepted")
        track.advance(to: begin.addingTimeInterval(1_000))
        let high = track.fraction
        var behind = step; behind.index = 1; behind.start = 0.3; behind.end = 0.9; behind.step = "release"
        check(track.accept(behind, at: begin.addingTimeInterval(1_000)) && track.fraction == high, "a later step that starts behind the fill does not move it back")
        check(!track.accept(step, at: begin), "an earlier step is ignored")
        var otherPlan = behind; otherPlan.index = 2; otherPlan.count = 5
        check(!track.accept(otherPlan, at: begin), "a step from a different plan is ignored")
        let finished = PublishProgressEvent(command: "publish", step: "done", label: "Done", index: 2, count: 2, start: 1, end: 1, expectedSeconds: 0)
        check(track.accept(finished, at: begin) && track.fraction == 1, "done fills the track")
    }

    static func reading() {
        let reader = PublishProgressReader(url: nil, command: "prepare")
        let first = data(with("step", "freeze")), second = data(line)
        var events = reader.consume(first + Data("\n".utf8) + second.prefix(20))
        check(events.map(\.step) == ["freeze"], "a complete line is read and a partial one waits")
        events = reader.consume(second.dropFirst(20) + Data("\nnot json\n{}\n".utf8))
        check(events.map(\.step) == ["tests"], "a split line joins its parts; garbage lines are skipped")
        events = reader.consume(Data(repeating: 0x7B, count: 900))
        events += reader.consume(Data(repeating: 0x7B, count: 900))
        events += reader.consume(Data(repeating: 0x7D, count: 10) + Data("\n".utf8) + data(with("step", "sign")) + Data("\n".utf8))
        check(events.map(\.step) == ["sign"], "an over-long line is dropped whole, and reading resumes after its newline")
        check(PublishProgressReader(url: URL(fileURLWithPath: "/nonexistent/progress.jsonl"), command: "prepare").poll().isEmpty,
              "a missing progress file yields nothing")
        let capped = PublishProgressReader(url: nil, command: "prepare")
        let row = data(line) + Data("\n".utf8)
        var total = 0
        for _ in 0..<(PublishProgressReader.byteLimit / row.count + 20) { total += capped.consume(row).count }
        check(total == PublishProgressReader.byteLimit / row.count, "no more than 256 KiB is ever read")
    }

    @MainActor static func polling() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ClipEdge-progress-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("fixture.sh")
        func line(_ step: String, _ index: Int, _ label: String, _ start: Double, _ end: Double, command: String = "prepare") -> String {
            String(data: data(["schema": 1, "command": command, "step": step, "label": label, "index": index, "count": 3,
                               "start": start, "end": end, "expectedSeconds": 1]), encoding: .utf8)!
        }
        let tests = line("tests", 1, "Running the regression checks", 0.2, 0.7)
        let cut = tests.index(tests.startIndex, offsetBy: 30)
        let fixture = """
        #!/bin/bash
        file=""; while (( $# )); do [[ $1 == --progress-file ]] && file=$2; shift; done
        [[ -n $file ]] || { echo '{"kind":"error","message":"no progress file"}'; exit 0; }
        mode=$(stat -f %Lp "$file")
        printf '%s\\n' '\(line("freeze", 0, "Freezing the source", 0, 0.2))' >> "$file"
        sleep 0.5
        printf '%s' '\(tests[..<cut])' >> "$file"
        sleep 0.5
        printf '%s\\n' '\(tests[cut...])' >> "$file"
        printf '%s\\n' 'garbage' '\(line("push", 2, "Pushing", 0.7, 1, command: "publish"))' >> "$file"
        printf '%s\\n' '\(line("done", 3, "Done", 1, 1))' >> "$file"
        printf '%s' '{"schema":1,"unterminated":' >> "$file"
        echo "{\\"kind\\":\\"unknown\\",\\"message\\":\\"mode $mode\\"}"
        """
        try Data(fixture.utf8).write(to: script)
        var received: [PublishProgressEvent] = []
        var mainThread = true
        let output = try await PublishProcess.run(tool: script, arguments: ["prepare", "--running-fingerprint", "x"], timeout: 10) {
            mainThread = mainThread && Thread.isMainThread; received.append($0)
        }
        for _ in 0..<1_000 where received.count < 3 { await Task.yield() }
        check(String(data: output, encoding: .utf8)?.contains("mode 600") == true, "the app creates a private progress file and passes its path")
        check(received.map(\.step) == ["freeze", "tests", "done"], "events arrive in order across a split line, skipping garbage and other commands")
        check(mainThread, "events are delivered on the main thread")
        try Data("#!/bin/bash\nprintf '%s' \"$*\"\n".utf8).write(to: script)
        let status = try await PublishProcess.run(tool: script, arguments: ["status"], timeout: 5) { _ in }
        check(String(data: status, encoding: .utf8) == "status", "status is never given a progress file")
        let silent = try await PublishProcess.run(tool: script, arguments: ["publish"], timeout: 5)
        check(String(data: silent, encoding: .utf8) == "publish", "no sink means no progress file")
        try Data("""
        #!/bin/bash
        file=""; while (( $# )); do [[ $1 == --progress-file ]] && file=$2; shift; done
        rm -f "$file"; chmod 000 "$(dirname "$file")" 2>/dev/null; chmod 700 "$(dirname "$file")"
        echo '{"kind":"different","latestVersion":"2.3","message":"Still works"}'
        """.utf8).write(to: script)
        let removed = try await PublishProcess.run(tool: script, arguments: ["publish"], timeout: 5) { _ in }
        check(String(data: removed, encoding: .utf8)?.contains("Still works") == true, "a removed progress file never fails the command")
    }
}
