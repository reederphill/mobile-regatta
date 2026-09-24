import Foundation
import Testing

/// The client package is transport-free and UI-free (#64): no WebSocket, networking or UIKit, so the app
/// (#68) and the load client (#67) each bring their own transport, and it builds on Linux. Deterministic
/// like the simulation it drives: time only comes in through `update(now:)`, and faults only from seeded
/// SplitMix64 streams.
@Suite struct SourceTests {
    static func sources() throws -> [(name: String, text: String)] {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/RegattaClient")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }.sorted()
        return try names.map { ($0, try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8)) }
    }

    @Test func importsOnlyRegattaCoreAndRegattaProtocol() throws {
        let files = try Self.sources()
        #expect(files.count >= 7)
        let imports = try Regex(#"^\s*(?:@\w+(?:\([^)]*\))?\s+)*import\s+(?:\w+\s+)?(\w+)"#)
        var imported: [String] = []
        for file in files {
            for line in file.text.split(separator: "\n") {
                if let match = String(line).firstMatch(of: imports), let module = match.output[1].substring {
                    imported.append("\(file.name): \(module)")
                }
            }
        }
        #expect(!imported.isEmpty)
        #expect(imported.filter { !$0.hasSuffix(": RegattaCore") && !$0.hasSuffix(": RegattaProtocol") } == [])
    }

    @Test func noTransportOrUITypes() throws {
        let transport = try Regex(#"WebSocket|URLSession|NWConnection|NWListener|Socket\b|NIO|UIKit|SwiftUI|SpriteKit"#)
        // Code only: the docs name the transports the owners bring.
        let hits = try Self.sources().flatMap { file in
            file.text.split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") && $0.contains(transport) }
                .map { "\(file.name): \($0)" }
        }
        #expect(hits == [])
    }

    // The determinism scans RegattaCore runs over its own sources (ADR 0002; RegattaCore's
    // `SourceScanTests`), repeated here for the client's, as RegattaProtocol does for its own: the client
    // drives the simulation, and its tests replay exactly. Copied rather than shared, so no package's
    // tests depend on another's.

    /// Word boundaries are the simple kind: with Unicode's default, `a.keys` is one word, so
    /// `\bkeys` wouldn't match inside `lastFoul.keys.sorted()`.
    static func violations(_ pattern: String, in files: [(name: String, text: String)]) throws -> [String] {
        let regex = try Regex(pattern).wordBoundaryKind(.simple)
        return files.flatMap { file in
            file.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                .filter { $0.element.contains(regex) }
                .map { "\(file.name):\($0.offset + 1): \($0.element.trimmingCharacters(in: .whitespaces))" }
        }
    }

    static let stdlibRandom = [
        #"\.random\("#, #"\b[A-Z]\w*\.random\b"#, #"randomElement\("#, #"shuffled\("#, #"shuffle\(using"#,
        #"\.shuffle\(\)"#, #"RandomNumberGenerator"#, #"arc4random"#, #"drand48"#, #"\bs?rand\("#,
    ].joined(separator: "|")

    static let wallClock = [
        #"\bDate\("#, #"Date\.now"#, #"timeIntervalSince"#, #"CFAbsoluteTime"#, #"DispatchTime"#,
        #"ContinuousClock"#, #"SuspendingClock"#, #"clock_gettime"#, #"gettimeofday"#,
        #"mach_absolute_time"#, #"ProcessInfo"#,
    ].joined(separator: "|")

    @Test func noStdlibRandomnessInSources() throws {
        #expect(try Self.violations(Self.stdlibRandom, in: Self.sources()) == [])
    }

    @Test func noWallClockInSources() throws {
        #expect(try Self.violations(Self.wallClock, in: Self.sources()) == [])
    }

    /// Names declared as a `Set` or `Dictionary`, by `var`/`let` with a type annotation or initialiser.
    static func unorderedNames(in files: [(name: String, text: String)]) throws -> [String] {
        let declaration = try Regex(
            #"(?:var|let)\s+(\w+)\s*(?::\s*(?:Set<|Dictionary<|\[[^\[\]]+:[^\[\]]+\])|=\s*(?:Set[<(]|Dictionary[<(]|\[[^\[\]]+:[^\[\]]+\]\(|\[:\]))"#
        )
        return Array(Set(files.flatMap { file in
            file.text.matches(of: declaration).compactMap { $0.output[1].substring.map(String.init) }
        })).sorted()
    }

    /// Lines that iterate one of `names`: a `for … in`, or an order-dependent collection method.
    static func iterations(of names: [String], in files: [(name: String, text: String)]) throws -> [String] {
        let methods = "forEach|map|compactMap|flatMap|filter|reduce|keys|values|first|last|sorted|min|max|"
            + "allSatisfy|contains\\(where|enumerated|makeIterator|lazy|indices|popFirst|removeFirst|joined|prefix|dropFirst"
        return try names.flatMap { name in
            try violations(#"for\s+.+\s+in\s+(?:self\.)?\#(name)\b|\b\#(name)\s*\.\s*(?:\#(methods))\b|Array\(\#(name)\)"#, in: files)
        }
    }

    @Test func iterationScanCatchesAnIteratedSet() throws {
        let sample = [(name: "Sample.swift", text: [
            "var contacts = Set<Pair>()", "for p in contacts { use(p) }", "let ok = contacts.contains(p)",
            "let k = self.contacts.keys.sorted()", "let all = snapshot.contacts.allSatisfy(valid)",
        ].joined(separator: "\n"))]
        let names = try Self.unorderedNames(in: sample)
        #expect(names == ["contacts"])
        #expect(try Self.iterations(of: names, in: sample) == [
            "Sample.swift:2: for p in contacts { use(p) }",
            "Sample.swift:4: let k = self.contacts.keys.sorted()",
            "Sample.swift:5: let all = snapshot.contacts.allSatisfy(valid)",
        ])
    }

    /// Nothing the client does depends on a `Set` or `Dictionary`'s order, which changes with the
    /// per-process hash seed.
    @Test func noSetOrDictionaryIterationInSources() throws {
        let files = try Self.sources()
        let hits = try Self.iterations(of: Self.unorderedNames(in: files), in: files)
        #expect(hits == [], "\(hits.joined(separator: "\n"))")
    }
}
