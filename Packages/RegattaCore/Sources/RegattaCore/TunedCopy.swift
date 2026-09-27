import Foundation

// Tuned copies (#229, #232, ADR 0004): the debug tuning panel's sliders become data files, never overrides in
// the simulation. A tuned copy is a bundled file's exact bytes with the numbers at some JSON Pointers
// rewritten and every other byte kept, so it keeps its base file's id and version, has its own hash, and
// carries a `tune` number in its ref. Nothing here runs in a race: a race loads a tuned copy like any other
// file, through `DataFile` and `RaceFiles(resolving:from:)`.

/// A generated data file: its exact bytes and the file they load as. A tuned copy's ref has a `tune`; the
/// panel's values that change nothing give back the base file itself, with none.
public struct TunedFile<Content: DataFileContent>: Sendable {
    public let file: DataFile<Content>
    public let data: Data

    public var ref: FileRef { file.ref }
    /// Whether this is a tuned copy rather than the base file's own bytes.
    public var isTuned: Bool { file.ref.tune != nil }

    public init(file: DataFile<Content>, data: Data) {
        self.file = file
        self.data = data
    }
}

public enum TunedCopyError: Error, Equatable, CustomStringConvertible {
    /// The pointer names nothing in the file, or something other than a number.
    case notANumber(pointer: String)
    /// A tuned value has to be a finite number to be written as JSON.
    case notFinite(pointer: String)
    /// A tune number is 1 or more: nil is the bundled file's.
    case invalidTune(Int)

    public var description: String {
        switch self {
        case .notANumber(let pointer): "\(pointer) names no number in the file"
        case .notFinite(let pointer): "\(pointer) must be a finite number"
        case .invalidTune(let tune): "tune \(tune) must be at least 1"
        }
    }
}

public enum TunedCopy {
    /// The number at `pointer` (RFC 6901) in a data file's bytes, or nil if it names anything else.
    public static func number(at pointer: String, in data: Data) -> Double? {
        let bytes = [UInt8](data)
        return JSONTextSpan.span(of: pointer, in: bytes).flatMap { number(in: bytes[$0]) }
    }

    /// The numbers of the array at `pointer`, or nil if it names anything but an array of numbers.
    public static func numbers(at pointer: String, in data: Data) -> [Double]? {
        let bytes = [UInt8](data)
        guard let span = JSONTextSpan.span(of: pointer, in: bytes),
              let elements = JSONTextSpan.elements(ofArrayAt: span.lowerBound, in: bytes) else { return nil }
        var numbers: [Double] = []
        for element in elements {
            guard let number = number(in: bytes[element]) else { return nil }
            numbers.append(number)
        }
        return numbers
    }

    /// `data` with the number at each pointer in `values` rewritten and every other byte kept. A value the file
    /// already holds (as `jsonText` writes it) is left as the file writes it, so values that change nothing give
    /// back `data` itself, byte for byte. Throws if a pointer names no number or a value isn't finite.
    public static func patched(_ data: Data, values: [String: Double]) throws -> Data {
        var bytes = [UInt8](data)
        var edits: [(span: Range<Int>, text: [UInt8])] = []
        // Sorted, so the first bad pointer reported is the same on every run.
        for (pointer, value) in values.sorted(by: { $0.key < $1.key }) {
            guard value.isFinite else { throw TunedCopyError.notFinite(pointer: pointer) }
            guard let span = JSONTextSpan.span(of: pointer, in: bytes), let current = number(in: bytes[span]) else {
                throw TunedCopyError.notANumber(pointer: pointer)
            }
            let text = jsonText(value)
            // Defensive: were two pointers to name one number, the first sorted would win.
            guard Double(text) != current, !edits.contains(where: { $0.span == span }) else { continue }
            edits.append((span, Array(text.utf8)))
        }
        // Back to front, so each span still points at its own bytes. Spans are numbers, so they never overlap.
        for edit in edits.sorted(by: { $0.span.lowerBound > $1.span.lowerBound }) {
            bytes.replaceSubrange(edit.span, with: edit.text)
        }
        return Data(bytes)
    }

    /// The pointers in `values` whose value differs from the file's own, sorted.
    public static func changedPointers(in data: Data, values: [String: Double]) throws -> [String] {
        let bytes = [UInt8](data)
        return try values.keys.sorted().filter { pointer in
            guard let value = values[pointer], value.isFinite else { throw TunedCopyError.notFinite(pointer: pointer) }
            guard let span = JSONTextSpan.span(of: pointer, in: bytes), let current = number(in: bytes[span]) else {
                throw TunedCopyError.notANumber(pointer: pointer)
            }
            return Double(jsonText(value)) != current
        }
    }

    /// A tuned copy of the file `base` holds, with `values` at their pointers, loaded as tune `tune`, through
    /// every check a bundled file goes through (a value its kind refuses throws `DataFileError.invalidContent`).
    /// When the values change nothing it is `base` itself, untuned: the same ref and hash as the bundled file.
    public static func make<Content: DataFileContent>(
        _ kind: Content.Type = Content.self, base: Data, values: [String: Double], tune: Int
    ) throws -> TunedFile<Content> {
        guard tune >= 1 else { throw TunedCopyError.invalidTune(tune) }
        let data = try patched(base, values: values)
        return try TunedFile(file: DataFile<Content>(data: data, tune: data == base ? nil : tune), data: data)
    }

    /// The next version of `base` with `values` in it, ready for the package's `Resources` (#232's export): the
    /// values rewritten, `version` one more, each changed pointer added to `placeholders` (they await
    /// confirming), and `note`, if given, added to `notes`. Every other byte is kept.
    public static func nextVersion(of base: Data, values: [String: Double], note: String? = nil) throws -> Data {
        let changed = try changedPointers(in: base, values: values)
        var bytes = [UInt8](try patched(base, values: values))
        // Each edit finds its span afresh, so none depends on where the others sit in the file.
        if let note, let span = JSONTextSpan.span(of: "/notes", in: bytes) {
            appendToArray(&bytes, span: span, items: [jsonString(note)])
        }
        guard let versionSpan = JSONTextSpan.span(of: "/version", in: bytes) else {
            throw TunedCopyError.notANumber(pointer: "/version")
        }
        if let span = JSONTextSpan.span(of: "/placeholders", in: bytes) {
            let listed = (try? JSONSerialization.jsonObject(with: Data(bytes[span]), options: [])) as? [String] ?? []
            appendToArray(&bytes, span: span, items: changed.filter { !listed.contains($0) }.map(jsonString))
        } else if !changed.isEmpty {
            let indent = indentation(of: versionSpan.lowerBound, in: bytes)
            let items = changed.map { "\(indent)  \(jsonString($0))" }.joined(separator: ",\n")
            let member = ",\n\(indent)\"placeholders\": [\n\(items)\n\(indent)]"
            bytes.insert(contentsOf: Array(member.utf8), at: versionSpan.upperBound)
        }
        guard let span = JSONTextSpan.span(of: "/version", in: bytes), let version = number(in: bytes[span]) else {
            throw TunedCopyError.notANumber(pointer: "/version")
        }
        bytes.replaceSubrange(span, with: Array(jsonText(version + 1).utf8))
        return Data(bytes)
    }

    /// The best upwind angle of one polar column (knots by the rows' TWA in degrees), in degrees, found as the
    /// simulation finds its groove (`PolarTable`). Nil for a column with no drive (0 kn).
    public static func bestUpwindAngle(twaDegrees rows: [Double], speedKnots column: [Double]) -> Double? {
        guard rows.count == column.count, column.contains(where: { $0 > 0 }) else { return nil }
        return rad2deg(PolarTable.optima(twaAxis: rows.map(deg2rad), speeds: [column], direction: 1)[0].twa)
    }

    /// A polar column's boat speeds (knots, by the rows' TWA in degrees) with its best upwind angle moved
    /// towards `target` degrees, so the groove can sit higher in a breeze and lower in light air (pinch and foot,
    /// #232). The rows between 0° and 90° take the speed the column had at a warped angle (the old best angle
    /// lands on the new one, 0° and 90° stay put) and are scaled so the column's best VMG stays what it was,
    /// tapering to no scaling at 90°. Rows at 0° and from 90° on are kept; speeds are rounded to 0.01 knots.
    ///
    /// The groove the simulation finds (`bestUpwindAngle`) settles on a row unless the speeds between rows beat
    /// it, and the rows are 5-7° apart, so not every angle is reachable: the warp is aimed again, up to eight
    /// times, and the try whose groove lands closest to `target` is kept (within about 2°). A column with no
    /// drive, or a target outside 20°…80°, comes back as it was.
    public static func upwindAngleSpeeds(twaDegrees rows: [Double], speedKnots column: [Double], to target: Double) -> [Double] {
        guard let old = bestUpwindAngle(twaDegrees: rows, speedKnots: column), (20...80).contains(target),
              abs(old - target) >= 0.05 else { return column }
        let radians = rows.map(deg2rad)
        func speed(at twa: Double) -> Double {
            guard let upper = rows.firstIndex(where: { $0 >= twa }) else { return column.last ?? 0 }
            guard upper > 0 else { return column[0] }
            let t = (twa - rows[upper - 1]) / (rows[upper] - rows[upper - 1])
            return column[upper - 1] + (column[upper] - column[upper - 1]) * t
        }
        func groove(_ speeds: [Double]) -> PolarTable.Optimum {
            PolarTable.optima(twaAxis: radians, speeds: [speeds], direction: 1)[0]
        }
        let vmg = groove(column).vmg
        func warped(to aim: Double) -> [Double] {
            var speeds = column
            for (r, twa) in rows.enumerated() where twa > 0 && twa < 90 {
                speeds[r] = speed(at: twa <= aim ? twa * old / aim : old + (twa - aim) * (90 - old) / (90 - aim))
            }
            // Scaled until the groove makes the column's VMG again: tapering the scale moves the groove a little.
            for _ in 0..<3 {
                let after = groove(speeds).vmg
                let scale = after > 0 ? vmg / after : 1
                for (r, twa) in rows.enumerated() where twa > 0 && twa < 90 {
                    speeds[r] *= twa <= aim ? scale : scale + (1 - scale) * (twa - aim) / (90 - aim)
                }
            }
            return speeds.map { ($0 * 100).rounded() / 100 }
        }
        var aim = target
        var best = (speeds: column, miss: abs(old - target))
        for _ in 0..<8 {
            let speeds = warped(to: aim)
            let found = rad2deg(groove(speeds).twa)
            if abs(found - target) < best.miss { best = (speeds, abs(found - target)) }
            guard best.miss >= 0.1 else { break }
            aim = min(max(aim + target - found, 10), 85)
        }
        return best.speeds
    }

    /// How a tuned value is written: at most nine significant digits (a slider's steps never need more, and it
    /// keeps 0.1 + 0.2 from writing 0.30000000000000004), whole numbers without a point.
    public static func jsonText(_ value: Double) -> String {
        let rounded = Double(String(format: "%.9g", value)) ?? value
        if rounded == rounded.rounded(), abs(rounded) < 1e15 { return String(Int64(rounded)) }
        return "\(rounded)"
    }

    // MARK: - Text

    private static func number(in text: ArraySlice<UInt8>) -> Double? {
        guard let first = text.first, first == UInt8(ascii: "-") || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(first)
        else { return nil }
        return Double(String(decoding: text, as: UTF8.self))
    }

    private static func jsonString(_ text: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return (try? String(decoding: encoder.encode(text), as: UTF8.self)) ?? "\"\""
    }

    /// The spaces and tabs the line holding `index` starts with.
    private static func indentation(of index: Int, in bytes: [UInt8]) -> String {
        var start = index
        while start > 0, bytes[start - 1] != UInt8(ascii: "\n") { start -= 1 }
        var end = start
        while end < bytes.count, bytes[end] == UInt8(ascii: " ") || bytes[end] == UInt8(ascii: "\t") { end += 1 }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    /// Adds `items` (JSON texts) to the end of the array at `span`, laid out like its last element: on a line of
    /// its own at the same indent if the array has one element per line, else after ", ".
    private static func appendToArray(_ bytes: inout [UInt8], span: Range<Int>, items: [String]) {
        guard !items.isEmpty else { return }
        let open = span.lowerBound, close = span.upperBound - 1
        var last = close - 1
        while last > open, bytes[last] == 0x20 || bytes[last] == 0x09 || bytes[last] == 0x0A || bytes[last] == 0x0D { last -= 1 }
        guard last > open else {
            // Empty: one item per line, a step in from the line the array opens on.
            let indent = indentation(of: open, in: bytes)
            let text = "\n" + items.map { "\(indent)  \($0)" }.joined(separator: ",\n") + "\n" + indent
            bytes.replaceSubrange((open + 1)..<close, with: Array(text.utf8))
            return
        }
        let text: String
        if bytes[open..<last].contains(0x0A) {
            let indent = indentation(of: last, in: bytes)
            text = items.map { ",\n\(indent)\($0)" }.joined()
        } else {
            text = items.map { ", \($0)" }.joined()
        }
        bytes.insert(contentsOf: Array(text.utf8), at: last + 1)
    }
}

/// Where a JSON Pointer's value sits in a data file's bytes, so a tuned copy rewrites that value's text and
/// keeps every other byte. Reads files `DataFile` accepts: UTF-8, well formed, no key repeated in an object.
enum JSONTextSpan {
    static func span(of pointer: String, in bytes: [UInt8]) -> Range<Int>? {
        guard pointer.isEmpty || pointer.hasPrefix("/") else { return nil }
        let tokens = pointer.isEmpty ? [] : pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map {
            $0.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
        }
        var i = skipWhitespace(bytes, 0)
        for token in tokens {
            guard i < bytes.count else { return nil }
            switch bytes[i] {
            case UInt8(ascii: "{"):
                guard let member = member(token, ofObjectAt: i, in: bytes) else { return nil }
                i = member
            case UInt8(ascii: "["):
                guard let element = element(token, ofArrayAt: i, in: bytes) else { return nil }
                i = element
            default:
                return nil
            }
        }
        guard let end = valueEnd(bytes, i) else { return nil }
        return i..<end
    }

    /// Where the value of member `key` of the object opening at `open` starts.
    private static func member(_ key: String, ofObjectAt open: Int, in bytes: [UInt8]) -> Int? {
        var i = skipWhitespace(bytes, open + 1)
        while i < bytes.count, bytes[i] != UInt8(ascii: "}") {
            guard bytes[i] == UInt8(ascii: "\""), let keyEnd = stringEnd(bytes, i) else { return nil }
            let name = decodeString(bytes[i..<keyEnd])
            i = skipWhitespace(bytes, keyEnd)
            guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { return nil }
            i = skipWhitespace(bytes, i + 1)
            if name == key { return i }
            guard let end = valueEnd(bytes, i) else { return nil }
            i = skipWhitespace(bytes, end)
            if i < bytes.count, bytes[i] == UInt8(ascii: ",") { i = skipWhitespace(bytes, i + 1) }
        }
        return nil
    }

    /// Where element `token` (decimal, no leading zero) of the array opening at `open` starts.
    private static func element(_ token: String, ofArrayAt open: Int, in bytes: [UInt8]) -> Int? {
        guard !token.isEmpty, token.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
              token == "0" || !token.hasPrefix("0"), let index = Int(token) else { return nil }
        var i = skipWhitespace(bytes, open + 1)
        for _ in 0..<index {
            guard i < bytes.count, bytes[i] != UInt8(ascii: "]"), let end = valueEnd(bytes, i) else { return nil }
            i = skipWhitespace(bytes, end)
            guard i < bytes.count, bytes[i] == UInt8(ascii: ",") else { return nil }
            i = skipWhitespace(bytes, i + 1)
        }
        guard i < bytes.count, bytes[i] != UInt8(ascii: "]") else { return nil }
        return i
    }

    /// The spans of the elements of the array opening at `open`, or nil if nothing opens there.
    static func elements(ofArrayAt open: Int, in bytes: [UInt8]) -> [Range<Int>]? {
        guard open < bytes.count, bytes[open] == UInt8(ascii: "[") else { return nil }
        var spans: [Range<Int>] = []
        var i = skipWhitespace(bytes, open + 1)
        while i < bytes.count, bytes[i] != UInt8(ascii: "]") {
            guard let end = valueEnd(bytes, i) else { return nil }
            spans.append(i..<end)
            i = skipWhitespace(bytes, end)
            if i < bytes.count, bytes[i] == UInt8(ascii: ",") { i = skipWhitespace(bytes, i + 1) }
        }
        return spans
    }

    /// The index just past the value starting at `start`.
    static func valueEnd(_ bytes: [UInt8], _ start: Int) -> Int? {
        guard start < bytes.count else { return nil }
        switch bytes[start] {
        case UInt8(ascii: "\""):
            return stringEnd(bytes, start)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            var i = start
            while i < bytes.count {
                switch bytes[i] {
                case UInt8(ascii: "\""):
                    guard let end = stringEnd(bytes, i) else { return nil }
                    i = end
                    continue
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 { return i + 1 }
                default:
                    break
                }
                i += 1
            }
            return nil
        default:
            // A number or a literal runs to the next delimiter.
            var i = start
            while i < bytes.count, !isDelimiter(bytes[i]) { i += 1 }
            return i > start ? i : nil
        }
    }

    /// The index just past the string whose opening quote is at `start`.
    private static func stringEnd(_ bytes: [UInt8], _ start: Int) -> Int? {
        var i = start + 1
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "\\") {
                i += 2
                continue
            }
            if bytes[i] == UInt8(ascii: "\"") { return i + 1 }
            i += 1
        }
        return nil
    }

    private static func decodeString(_ text: ArraySlice<UInt8>) -> String? {
        let inner = text.dropFirst().dropLast()
        if !inner.contains(UInt8(ascii: "\\")) { return String(decoding: inner, as: UTF8.self) }
        return (try? JSONSerialization.jsonObject(with: Data(text), options: [.fragmentsAllowed])) as? String
    }

    private static func skipWhitespace(_ bytes: [UInt8], _ start: Int) -> Int {
        var i = start
        while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x09 || bytes[i] == 0x0A || bytes[i] == 0x0D { i += 1 }
        return i
    }

    private static func isDelimiter(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == UInt8(ascii: ",")
            || byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]")
    }
}
