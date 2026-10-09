import Foundation

typealias PublishProgressSink = @MainActor (PublishProgressEvent) -> Void

/// One line of the release helper's progress telemetry. The helper is a local
/// script, but its output is still decoded strictly: telemetry can only move
/// the Publish lozenge's fill, never state or command arguments.
struct PublishProgressEvent: Equatable {
    var command: String
    var step: String
    var label: String
    var index: Int
    var count: Int
    var start: Double
    var end: Double
    var expectedSeconds: Double

    var isDone: Bool { step == "done" }

    static let maximumLineBytes = 1_024
    static let commands: Set<String> = ["prepare", "publish"]
    private static let fields: Set<String> = ["schema", "command", "step", "label", "index", "count", "start", "end", "expectedSeconds"]

    /// `line` excludes its newline. Anything off the contract decodes to nil.
    static func decode(_ line: Data, command expected: String) -> PublishProgressEvent? {
        guard !line.isEmpty, line.count <= maximumLineBytes, String(data: line, encoding: .utf8) != nil,
              let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              Set(object.keys) == fields else { return nil }
        func number(_ key: String) -> NSNumber? {
            guard let value = object[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite else { return nil }
            return value
        }
        guard number("schema") as? Int == 1,
              let command = object["command"] as? String, command == expected, commands.contains(command),
              let step = object["step"] as? String, isStepID(step),
              let label = object["label"] as? String, isLabel(label),
              let index = number("index") as? Int, let count = number("count") as? Int, (1...32).contains(count),
              let start = number("start")?.doubleValue, let end = number("end")?.doubleValue,
              let expectedSeconds = number("expectedSeconds")?.doubleValue,
              (0...1).contains(start), (start...1).contains(end), (0...3_600).contains(expectedSeconds) else { return nil }
        if step == "done" {
            guard index == count, start == 1, end == 1 else { return nil }
        } else {
            guard (0..<count).contains(index) else { return nil }
        }
        return PublishProgressEvent(command: command, step: step, label: label, index: index, count: count,
                                    start: start, end: end, expectedSeconds: expectedSeconds)
    }

    static func isStepID(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard (1...32).contains(bytes.count), (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(bytes[0]) else { return false }
        return bytes.allSatisfy { (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || $0 == UInt8(ascii: "-") }
    }

    /// Labels reach the tooltip and VoiceOver, so control, format and line
    /// separator characters are refused rather than rendered.
    static func isLabel(_ text: String) -> Bool {
        guard (1...80).contains(text.count), !text.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return !text.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
                || CharacterSet.illegalCharacters.contains($0)
        }
    }
}

/// The fill shown for one prepare or publish command. Between helper events it
/// eases toward the current step's end, never reaching it, and never moves back.
struct PublishProgressTrack: Equatable {
    let command: String
    let generation: Int
    private(set) var event: PublishProgressEvent?
    private(set) var began: Date?
    private(set) var fraction: Double = 0

    init(command: String, generation: Int) {
        self.command = command
        self.generation = generation
    }

    var label: String? { event?.label }

    /// Events must belong to this command's plan and arrive in step order.
    @discardableResult mutating func accept(_ next: PublishProgressEvent, at now: Date) -> Bool {
        guard next.command == command else { return false }
        if let event, next.count != event.count || next.index <= event.index { return false }
        event = next
        began = now
        advance(to: now)
        return true
    }

    mutating func advance(to now: Date) {
        guard let event, let began else { return }
        fraction = min(1, max(fraction, Self.estimate(event, elapsed: now.timeIntervalSince(began))))
    }

    static func estimate(_ event: PublishProgressEvent, elapsed: TimeInterval) -> Double {
        if event.isDone { return 1 }
        let span = event.end - event.start
        let eased = event.start + span * (1 - exp(-max(0, elapsed) / max(event.expectedSeconds * 0.6, 0.5)))
        return min(eased, event.end - 0.01 * span)
    }
}

/// Tails the helper's progress file: only appended bytes, at most 256 KiB in
/// all, and an unterminated last line waits for its newline. It never throws.
final class PublishProgressReader {
    static let byteLimit = 262_144
    private let handle: FileHandle?
    private let command: String
    private var consumed = 0
    private var pending = Data()
    private var skippingLongLine = false

    /// A nil or unreadable file yields no events; `consume` still works for tests.
    init(url: URL?, command: String) {
        handle = url.flatMap { try? FileHandle(forReadingFrom: $0) }
        self.command = command
    }

    var isReadable: Bool { handle != nil }

    func poll() -> [PublishProgressEvent] {
        guard let handle, consumed < Self.byteLimit,
              let chunk = try? handle.read(upToCount: Self.byteLimit - consumed), !chunk.isEmpty else { return [] }
        return consume(chunk)
    }

    /// Splits appended bytes into lines. A line longer than the contract allows
    /// is dropped whole, including the part that arrives after its first chunk.
    func consume(_ chunk: Data) -> [PublishProgressEvent] {
        let chunk = Data(chunk.prefix(max(0, Self.byteLimit - consumed)))
        consumed += chunk.count
        var events: [PublishProgressEvent] = []
        var lineStart = chunk.startIndex
        for position in chunk.indices where chunk[position] == 0x0A {
            if skippingLongLine { skippingLongLine = false }
            else {
                pending.append(chunk[lineStart..<position])
                if let event = PublishProgressEvent.decode(pending, command: command) { events.append(event) }
            }
            pending.removeAll(keepingCapacity: true)
            lineStart = chunk.index(after: position)
        }
        if !skippingLongLine {
            pending.append(chunk[lineStart...])
            if pending.count > PublishProgressEvent.maximumLineBytes {
                pending.removeAll()
                skippingLongLine = true
            }
        }
        return events
    }

    func close() { try? handle?.close() }
}
