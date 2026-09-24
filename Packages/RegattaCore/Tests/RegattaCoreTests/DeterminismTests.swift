import Foundation
import Testing
@testable import RegattaCore

@Suite struct TickTests {
    @Test func sixtySecondSequenceStartsAtMinus1800AndFiresTheGunOnce() {
        let race = testRace(opponents: 3, prestartSeconds: 60, seed: 7)
        #expect(race.tick == -1800)
        var guns = 0
        for step in 1...1800 {
            race.step()
            let fired = race.drainEvents().filter { $0.kind == .gun }.count
            guns += fired
            if step < 1800 { #expect(fired == 0) }
        }
        #expect(race.tick == 0)
        #expect(race.time == 0)
        #expect(guns == 1)
        for _ in 0..<60 { race.step() }
        #expect(!race.drainEvents().contains { $0.kind == .gun })
    }

    @Test func timeIsDerivedFromTheTickExactly() {
        let race = testRace(opponents: 1, prestartSeconds: 60, seed: 11, brains: [])
        for _ in 0..<10_000 { race.step() }
        #expect(!race.isOver)
        #expect(race.tick == -1800 + 10_000)
        #expect(race.time == Double(race.tick) / 30)
        #expect(race.wind.time == Double(race.wind.tick) / 30)
    }
}

@Suite struct RandomTests {
    @Test func unitFirstValuesArePinned() {
        var rng = SplitMix64(seed: 1)
        let values = (0..<3).map { _ in rng.unit() }
        #expect(values == [0x1.22145bd91204bp-1, 0x1.7dd71b42cb1ddp-1, 0x1.f12745ddf664ap-1])
        #expect(values.allSatisfy { $0 >= 0 && $0 < 1 })
    }

    @Test func unitStaysInTheHalfOpenInterval() {
        var rng = SplitMix64(seed: 2)
        for _ in 0..<10_000 {
            let u = rng.unit()
            #expect(u >= 0 && u < 1)
        }
    }

    @Test func rangeIntAndBoolStayInBounds() {
        var rng = SplitMix64(seed: 3)
        var heads = 0
        for _ in 0..<1_000 {
            let x = rng.range(-2.5, 5)
            #expect(x >= -2.5 && x < 5)
            let n = rng.int(in: -3...3)
            #expect((-3...3).contains(n))
            #expect((10..<11).contains(rng.int(in: 10..<11)))
            if rng.bool() { heads += 1 }
        }
        #expect(heads > 400 && heads < 600)
    }

    @Test func closedIntRangesReachTheEndsOfInt() {
        var rng = SplitMix64(seed: 5)
        for _ in 0..<100 {
            #expect(rng.int(in: (Int.max - 1)...Int.max) >= Int.max - 1)
            #expect(rng.int(in: Int.min...Int.min) == Int.min)
            _ = rng.int(in: Int.min...Int.max)
        }
    }

    @Test func shuffleIsASeededPermutation() {
        var a = SplitMix64(seed: 4), b = SplitMix64(seed: 4)
        var x = Array(0..<20), y = Array(0..<20)
        a.shuffle(&x)
        b.shuffle(&y)
        #expect(x == y)
        #expect(x != Array(0..<20))
        #expect(x.sorted() == Array(0..<20))
    }
}

/// Golden replay: the checked-in 16-seat scripted log (`Tests/Fixtures`), replayed with no bot brains
/// (ADR 0002), so retuning bots never moves it. Pinned only on the replay platform.
@Suite struct GoldenTests {
    static func goldenDigest() throws -> UInt64 {
        // The fixture outlives simulation revisions; Goldens.json has a row per version.
        try Replayer.digest(of: ScriptedLog.fixture(), requireMatchingVersion: false)
    }

    static func goldenTable() throws -> [String: String] {
        let url = testsDirectory.appendingPathComponent("Goldens.json")
        struct Table: Decodable { let digests: [String: String] }
        return try JSONDecoder().decode(Table.self, from: Data(contentsOf: url)).digests
    }

    @Test func digestIsStableWithinAProcess() throws {
        #expect(try Self.goldenDigest() == Self.goldenDigest())
    }

    /// Prints the digest for `scripts/check-digest-stable.sh` and CI, then checks it against
    /// the table row for this simulation version. Changing a digest without a new version row fails.
    @Test func goldenDigestMatchesTheTableOnTheReplayPlatform() throws {
        let digest = hex64(try Self.goldenDigest())
        print("GOLDEN simulationVersion=\(simulationVersion) digest=\(digest)")

        let expectReplayPlatform = ProcessInfo.processInfo.environment["REGATTA_EXPECT_REPLAY_PLATFORM"] == "1"
        if expectReplayPlatform {
            #expect(isReplayPlatform, "expected replay platform \(replayPlatform), running on \(simulationPlatform)")
        }
        // Other platforms only need to be close, so no golden constant is asserted there.
        guard isReplayPlatform else { return }

        let row = try Self.goldenTable()[simulationVersion]
        #expect(row != nil, "Tests/Goldens.json has no row for \(simulationVersion); this build's digest is \(digest)")
        if let row { #expect(row == digest, "simulation output changed: bump simulationRevision and add a Goldens.json row") }
    }

    /// `regatta-replay`, in its own process, prints the same digest as the in-process replay, and the
    /// pinned one on the replay platform.
    @Test func regattaReplayPrintsTheGoldenDigest() throws {
        let executable = try #require(Self.replayExecutable(), "regatta-replay not found next to the test bundle")
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--any-version", ScriptedLog.fixtureURL.path]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        _ = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        let digest = printed.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(digest == hex64(try Self.goldenDigest()))
        if isReplayPlatform {
            #expect(digest == (try Self.goldenTable()[simulationVersion]))
        }
    }

    private final class BundleMarker {}

    /// SwiftPM builds `regatta-replay` into the same products directory as the test bundle.
    static func replayExecutable() -> URL? {
        var directories: [URL] = []
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            directories.append(bundle.bundleURL.deletingLastPathComponent())
        }
        let marker = Bundle(for: BundleMarker.self).bundleURL
        directories.append(marker.pathExtension == "xctest" ? marker.deletingLastPathComponent() : marker)
        directories.append(Bundle.main.bundleURL)
        directories.append(URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent())
        let build = testsDirectory.deletingLastPathComponent().appendingPathComponent(".build")
        directories.append(build.appendingPathComponent("debug"))
        directories.append(build.appendingPathComponent("release"))
        return directories.lazy
            .map { $0.appendingPathComponent("regatta-replay") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    @Test func goldenRowsAreWellFormed() throws {
        for (version, digest) in try Self.goldenTable() {
            guard let revision = version.split(separator: "/", maxSplits: 1).first.flatMap({ Int($0) }) else {
                Issue.record("golden key \(version) has no revision")
                continue
            }
            #expect(revision <= simulationRevision, "bad golden key \(version)")
            #expect(version.hasSuffix("/" + replayPlatform) || revision < simulationRevision,
                    "golden row \(version) is not for the replay platform")
            #expect(digest.count == 18 && digest.hasPrefix("0x") && UInt64(digest.dropFirst(2), radix: 16) != nil,
                    "bad golden digest \(digest)")
        }
    }
}

/// Source scans for the determinism rules in ADR 0002 and on `Race`.
@Suite struct SourceScanTests {
    static func sources() throws -> [(name: String, text: String)] {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/RegattaCore")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }.sorted()
        #expect(!names.isEmpty)
        return try names.map { ($0, try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8)) }
    }

    static func violations(_ pattern: String, in files: [(name: String, text: String)]) throws -> [String] {
        let regex = try Regex(pattern)
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
        let sample = [(name: "Sample.swift", text: "var contacts = Set<Pair>()\nfor p in contacts { use(p) }\nlet ok = contacts.contains(p)")]
        let names = try Self.unorderedNames(in: sample)
        #expect(names == ["contacts"])
        #expect(try Self.iterations(of: names, in: sample) == ["Sample.swift:2: for p in contacts { use(p) }"])
    }

    /// The step path never iterates a `Set` or `Dictionary`: their order changes with the per-process hash seed.
    @Test func noSetOrDictionaryIterationInSources() throws {
        let files = try Self.sources()
        let names = try Self.unorderedNames(in: files)
        #expect(names.contains("boatContacts"))
        #expect(try Self.iterations(of: names, in: files) == [])
    }
}
