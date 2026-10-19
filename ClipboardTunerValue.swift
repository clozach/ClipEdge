import Foundation

/// What one tuner counts: its range, its step per arrow press and per point of
/// drag, and how its value reads ("300ms", "0.35s").
struct ClipboardTunerSpec: Equatable {
    let label: String
    let accessibilityLabel: String
    let unit: String
    let minimum: Double
    let maximum: Double
    let step: Double
    let defaultValue: Double
    /// The symbol on the drag handle, and the text that stands in where the symbol is missing.
    let symbol: String
    let glyph: String

    /// Milliseconds, 0–1500; 0 is instant.
    static func duration(_ label: String, standard: Double) -> ClipboardTunerSpec {
        ClipboardTunerSpec(label: label, accessibilityLabel: "\(label) in milliseconds", unit: "ms", minimum: 0, maximum: 1500,
                           step: 10, defaultValue: standard, symbol: "clock", glyph: "◷")
    }

    /// Seconds, 0 to `maximum` in twentieths; 0 is at once.
    static func seconds(_ label: String, maximum: Double, standard: Double) -> ClipboardTunerSpec {
        ClipboardTunerSpec(label: label, accessibilityLabel: "\(label) in seconds", unit: "s", minimum: 0, maximum: maximum,
                           step: 0.05, defaultValue: standard, symbol: "clock", glyph: "◷")
    }

    /// A percentage of the size ClipEdge shipped with, in steps of 5 (2026-10-16).
    static func percent(_ label: String, range: ClosedRange<Double>, symbol: String, glyph: String) -> ClipboardTunerSpec {
        ClipboardTunerSpec(label: label, accessibilityLabel: "\(label) in percent", unit: "%", minimum: range.lowerBound,
                           maximum: range.upperBound, step: 5, defaultValue: 100, symbol: symbol, glyph: glyph)
    }

    /// Digits after the point, from the step: a step of 10 shows none, 0.05 two.
    var decimals: Int { max(0, Int(ceil(-log10(step) - 1e-9))) }

    /// Rounded to the shown digits and kept in range; a value that is not a number takes the default.
    func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        let scale = pow(10, Double(decimals))
        return min(maximum, max(minimum, (value * scale).rounded() / scale))
    }

    /// "300ms", "0.35s", "0.5s", "2s": trailing zeros go, and the unit follows the number directly.
    func text(_ value: Double) -> String {
        var number = String(format: "%.\(decimals)f", value)
        if decimals > 0, number.contains(".") {
            while number.hasSuffix("0") { number.removeLast() }
            if number.hasSuffix(".") { number.removeLast() }
        }
        return number + unit
    }

    /// Typed text with everything but digits, a leading minus and one point stripped:
    /// "300ms" is 300, "1.2.3" is 1.2, "garbage" is nothing. Where the value has decimals a
    /// comma counts as the point ("0,5s" is 0.5); elsewhere it is stripped ("1,200ms" is 1200).
    func parsed(_ typed: String) -> Double? {
        var cleaned = ""
        var pointed = false
        for character in typed {
            if character.isASCII, character.isNumber { cleaned.append(character) }
            else if character == "." || (character == "," && decimals > 0) { if pointed { break }; pointed = true; cleaned.append(".") }
            else if character == "-", cleaned.isEmpty { cleaned.append(character) }
        }
        return Double(cleaned).map(clamped)
    }

    func nudged(_ value: Double, by presses: Int, large: Bool) -> Double {
        clamped(value + Double(presses) * step * (large ? 10 : 1))
    }

    /// Dragging right raises the value one step per point.
    func scrubbed(from start: Double, points: CGFloat) -> Double {
        clamped(start + Double(points) * step)
    }
}

/// A tuner's submitted values, in memory only: what came before, the value now, what was undone.
struct ClipboardTunerHistory: Equatable {
    private(set) var current: Double
    private(set) var past: [Double] = []
    private(set) var undone: [Double] = []
    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !undone.isEmpty }

    init(current: Double) { self.current = current }

    /// A changed value is one undo step and forgets what was undone.
    mutating func submit(_ value: Double) {
        guard value != current else { return }
        past.append(current)
        current = value
        undone = []
    }

    /// The value as found, with no step to undo: at first showing, or changed elsewhere.
    mutating func load(_ value: Double) { current = value }

    /// Replaces the value within the last step: consecutive arrow presses stay one step.
    mutating func amend(_ value: Double) {
        guard value != current else { return }
        current = value
        undone = []
        if past.last == value { past.removeLast() }
    }

    mutating func undo() -> Bool {
        guard let previous = past.popLast() else { return false }
        undone.append(current)
        current = previous
        return true
    }

    mutating func redo() -> Bool {
        guard let next = undone.popLast() else { return false }
        past.append(current)
        current = next
        return true
    }
}
