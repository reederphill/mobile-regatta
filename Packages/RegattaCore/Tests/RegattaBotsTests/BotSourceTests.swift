import Foundation
import Testing

/// #98: a bot's brain holds no `Race`. It is handed its seat's `SeatView` and nothing else (#19: only what a
/// player can see), so no brain code may name the race, or a type that carries what the race holds beyond
/// the present: the wind's keys and seed, the whole world, the log, the umpire's memory. The brain's
/// sources are every `BotBrain*.swift` file in RegattaBots, and every file that declares or extends
/// `BotBrain` must be one of them.
@Suite struct BotSourceTests {
    /// RegattaBots' sources, by file name.
    static func sources() throws -> [(name: String, text: String)] {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/RegattaBots")
        let names = try FileManager.default.subpathsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }.sorted()
        return try names.map { ($0, try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8)) }
    }

    static func isBrain(_ name: String) -> Bool {
        (name.split(separator: "/").last ?? "").hasPrefix("BotBrain")
    }

    /// `text` with its comments blanked out, line for line: a doc comment may name the race it never sees.
    /// String literals are kept, comment markers inside them aside, which no brain has.
    static func code(_ text: String) -> [Substring] {
        var inBlock = false
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            var kept = ""
            var rest = line[...]
            while !rest.isEmpty {
                if inBlock {
                    guard let end = rest.range(of: "*/") else { rest = ""; break }
                    rest = rest[end.upperBound...]
                    inBlock = false
                } else if let start = rest.range(of: "/*"), rest.range(of: "//").map({ start.lowerBound < $0.lowerBound }) ?? true {
                    kept += rest[..<start.lowerBound]
                    rest = rest[start.upperBound...]
                    inBlock = true
                } else if let comment = rest.range(of: "//") {
                    kept += rest[..<comment.lowerBound]
                    rest = ""
                } else {
                    kept += rest
                    rest = ""
                }
            }
            return Substring(kept)
        }
    }

    /// The race, and the types that hold what it holds beyond the present tick or beyond one seat.
    static let forbidden = #"\b(?:Race|WorldSnapshot|WindField|WindKeyChain|WindKey|WindKeyGenerator|WindSeed|RaceLog|Replayer|IncidentIndex|UmpireState|OverlapTracker)\b"#

    /// Lines of `files`' code (comments aside) that name a forbidden type.
    static func violations(in files: [(name: String, text: String)]) throws -> [String] {
        let regex = try Regex(forbidden).wordBoundaryKind(.simple)
        return files.flatMap { file in
            code(file.text).enumerated().filter { $0.element.contains(regex) }
                .map { "\(file.name):\($0.offset + 1): \($0.element.trimmingCharacters(in: .whitespaces))" }
        }
    }

    @Test func brainSourceNeverReferencesRace() throws {
        let files = try Self.sources()
        let brain = files.filter { Self.isBrain($0.name) }
        #expect(brain.map(\.name).contains("BotBrain.swift"))
        #expect(brain.contains { $0.text.contains("func decide(_ view: SeatView)") }, "the brain decides on a SeatView")

        // Every declaration of the brain is in a brain file, so none can reach the race from elsewhere.
        let declaration = try Regex(#"\b(?:struct|extension|class|enum)\s+BotBrain\b"#)
        let elsewhere = files.filter { !Self.isBrain($0.name) && Self.code($0.text).contains { $0.contains(declaration) } }
        #expect(elsewhere.map(\.name) == [])

        let hits = try Self.violations(in: brain)
        #expect(hits == [], "\(hits.joined(separator: "\n"))")

        // The driver, outside the brain, does hold the race: the scan would see it there.
        #expect(try !Self.violations(in: files.filter { $0.name == "BotDriver.swift" }).isEmpty)
    }

    /// The scan finds the race in code, whatever it's called through, and never in a comment.
    @Test func scanSeesCodeNotComments() throws {
        let sample = [(name: "BotBrain+Sample.swift", text: [
            "/// Never holds a Race.", "func f(_ race: Race) {}", "let t = x.time // not Race", "/* a Race",
            "   still a Race */ let k: WindKey? = nil", "let area: RaceArea", "let n = Race.tickRate",
        ].joined(separator: "\n"))]
        #expect(try Self.violations(in: sample) == [
            "BotBrain+Sample.swift:2: func f(_ race: Race) {}",
            "BotBrain+Sample.swift:5: let k: WindKey? = nil",
            "BotBrain+Sample.swift:7: let n = Race.tickRate",
        ])
    }
}
