import Foundation
import Testing
@testable import RegattaCore

/// The debug tuning panel's generated data files (#232, #229, ADR 0004): a bundled file's bytes with the panel's
/// values written in at their JSON Pointers, loaded as a tuned copy, resolved from the race's catalog, and saved
/// beside the practice log that sailed it so the log replays.
@Suite struct TuningFileTests {
    static let conditionsKey = DataFileKey(id: "classic-oscillating", version: 3)
    /// #221's values on the conditions sliders: a slower oscillation, a wider puff fan and softer lulls.
    static let conditionsValues: [String: Double] = [
        "/shift/periodSeconds/min": 100, "/shift/periodSeconds/max": 120, "/puffs/fanDegrees": 12,
        "/puffs/lullLoss/max": 0.25,
    ]

    static func bytes<Content: DataFileContent>(_ kind: Content.Type, _ key: DataFileKey) throws -> Data {
        try #require(try DataFile<Content>.bundledData(id: key.id, version: key.version))
    }

    /// A tuned copy keeps its base file's id and version, has its own hash and its tune, and changes only the
    /// tuned numbers: writing the file's own values back gives the bundled bytes again. The race's catalog
    /// resolves it by its whole ref, and the bundled file still resolves beside it.
    @Test func generatedFileHasOwnHashAndResolvesFromCatalog() throws {
        let base = try Self.bytes(Conditions.self, Self.conditionsKey)
        let bundled = try ConditionsFile.bundled(id: Self.conditionsKey.id, version: Self.conditionsKey.version)
        let tuned = try TunedCopy.make(Conditions.self, base: base, values: Self.conditionsValues, tune: 3)

        #expect(tuned.isTuned)
        #expect(tuned.ref == FileRef(id: "classic-oscillating", version: 3, hash: ContentHash(of: tuned.data), tune: 3))
        #expect(tuned.ref.hash != bundled.ref.hash)
        #expect(tuned.file.content.shift.period == 100...120)
        #expect(tuned.file.content.puffs.fan == deg2rad(12))
        #expect(tuned.file.content.puffs.lullLoss == 0.15...0.25)
        // Every other byte is kept: the header, notes, placeholders and untouched values read as the bundle's.
        #expect(tuned.file.header == bundled.header)
        let restored = try TunedCopy.patched(tuned.data, values: [
            "/shift/periodSeconds/min": 70, "/shift/periodSeconds/max": 90, "/puffs/fanDegrees": 9, "/puffs/lullLoss/max": 0.2,
        ])
        // The bundled file writes the lull loss as 0.20, which a tuned value (0.2) can't restore byte for byte.
        #expect(String(decoding: restored, as: UTF8.self)
            == String(decoding: base, as: UTF8.self).replacingOccurrences(of: #""max": 0.20 }"#, with: #""max": 0.2 }"#))
        #expect(restored.count == base.count - 1)

        var catalog = RaceFileCatalog()
        try catalog.conditions.add(tuned.file)
        let venue = try VenueFile.bundled(id: "dev-venue", version: 3)
        try catalog.venues.add(venue)
        let setup = try RaceSetup(raceSeed: RaceSeed(232), seats: [.human, .bot], venue: venue.ref, conditions: tuned.ref)
        let files = try RaceFiles(resolving: setup, from: catalog)
        #expect(files.conditions.ref == tuned.ref)
        #expect(files.conditions.content == tuned.file.content)
        #expect(files.pairing == venue.content.pairing(for: Self.conditionsKey))
        // The bundled ref still finds the bundled file: a tuned copy never shadows it.
        let untuned = try RaceSetup(raceSeed: RaceSeed(232), seats: [.human, .bot], venue: venue.ref, conditions: bundled.ref)
        #expect(try RaceFiles(resolving: untuned, from: catalog).conditions.content == bundled.content)
    }

    /// A saved tuning that changes nothing (no values, or only the files' own) gives each bundled file back
    /// untuned: the same bytes, hash and ref, with no `tune`, so its race is a bundled race.
    @Test func untunedSavedTuningProducesBundledFileHash() throws {
        let conditions = try Self.bytes(Conditions.self, Self.conditionsKey)
        let skiff = try Self.bytes(BoatClass.self, RaceFiles.defaults.boatClass.ref.key)
        let rules = try Self.bytes(RulesConfig.self, RaceFiles.defaults.rulesConfiguration.ref.key)
        let own: [String: Double] = ["/shift/periodSeconds/min": 70, "/shift/wobbleDegrees": 3, "/puffs/fanDegrees": 9.0,
                                     "/puffs/lullLoss/max": 0.2, "/shift/amplitudeDegrees": 8]

        for values in [[:], own] {
            let file = try TunedCopy.make(Conditions.self, base: conditions, values: values, tune: 1)
            #expect(!file.isTuned)
            #expect(file.data == conditions)
            #expect(file.ref == (try ConditionsFile.bundled(id: Self.conditionsKey.id, version: Self.conditionsKey.version)).ref)
            #expect(try TunedCopy.changedPointers(in: conditions, values: values).isEmpty)
        }
        let boatClass = try TunedCopy.make(BoatClass.self, base: skiff, values: ["/steering/autohelm/upwindSnapDegrees": 3], tune: 1)
        #expect(boatClass.ref == RaceFiles.defaults.boatClass.ref)
        let rulesConfiguration = try TunedCopy.make(
            RulesConfig.self, base: rules, values: ["/raceFormat/raceArea/acrossAxisBeatFraction": 0.75], tune: 1)
        #expect(rulesConfiguration.ref == RaceFiles.defaults.rulesConfiguration.ref)
    }

    /// A practice race on tuned copies of all three tunable kinds, saved as a folder with its tuned files beside
    /// its log, replays from that folder to the race's own digest. Without the files the log can't replay: the
    /// bundle has other bytes under those ids and versions.
    @Test func tunedPracticeLogReplaysWithSavedFiles() throws {
        let conditions = try TunedCopy.make(
            Conditions.self, base: Self.bytes(Conditions.self, Self.conditionsKey), values: Self.conditionsValues, tune: 1)
        let boatClass = try TunedCopy.make(
            BoatClass.self, base: Self.bytes(BoatClass.self, DataFileKey(id: "skiff", version: 1)),
            values: ["/momentum/speedingUpSeconds": 2, "/steering/autohelm/upwindSnapDegrees": 5], tune: 2)
        let rules = try TunedCopy.make(
            RulesConfig.self, base: Self.bytes(RulesConfig.self, DataFileKey(id: "fleet-rules", version: 1)),
            values: ["/raceFormat/raceArea/acrossAxisBeatFraction": 0.9, "/raceFormat/startRow/spreadLineLengths": 1], tune: 7)
        let venue = try VenueFile.bundled(id: "dev-venue", version: 3)

        var catalog = RaceFileCatalog()
        try catalog.conditions.add(conditions.file)
        try catalog.boatClasses.add(boatClass.file)
        try catalog.rulesConfigurations.add(rules.file)
        let setup = try RaceSetup(raceSeed: RaceSeed(0x232), seats: [.human, .bot, .bot], laps: 1,
                                  startSequenceTicks: 10 * Race.tickRate, boatClass: boatClass.ref, venue: venue.ref,
                                  conditions: conditions.ref, rulesConfiguration: rules.ref)
        let race = try Race(setup: setup, files: RaceFiles(resolving: setup, from: catalog),
                            mode: .authoritative(windSeed: WindSeed(0xF00D)))
        #expect(race.boatClass == boatClass.file.content)
        while race.tick < 40 * Race.tickRate {
            let next = race.tick + 1
            for seat in 0..<3 where next % (4 * Race.tickRate) == seat * 20 {
                race.apply(BoatInput(rudder: seat == 1 ? -0.6 : 0.4), seat: seat, atTick: next)
            }
            if next == 20 * Race.tickRate { race.tap(.tackGybe, seat: 2, atTick: next) }
            race.step()
        }
        let log = try #require(race.log)
        #expect(log.header.setup.conditions.tune == 1 && log.header.setup.boatClass.tune == 2)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tuned-race-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let tunedFiles = [conditions.ref: conditions.data, boatClass.ref: boatClass.data, rules.ref: rules.data]
        try RaceLogFolder.write(log, tunedFiles: tunedFiles, to: folder)
        let saved = try FileManager.default.subpathsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".json") }.sorted()
        #expect(saved == ["boat-classes/skiff@1+tune2.json", "conditions/classic-oscillating@3+tune1.json",
                          "race.racelog.json", "rules/fleet-rules@1+tune7.json"])

        let (read, savedCatalog) = try RaceLogFolder.read(folder)
        #expect(read == log)
        #expect(try Replayer.digest(of: read, catalog: savedCatalog) == race.digest())
        let bundledSkiff = try BoatClassFile.bundled(id: "skiff", version: 1).ref.hash
        #expect(throws: DataFileError.refMismatch(expected: boatClass.ref, foundHash: bundledSkiff)) {
            try Replayer.replay(read)
        }

        // A folder missing a tuned copy, or holding other bytes for one, is refused before anything is sailed.
        try FileManager.default.removeItem(at: folder.appendingPathComponent("rules/fleet-rules@1+tune7.json"))
        #expect(throws: RaceLogFolderError.missingTunedFile(rules.ref)) { try RaceLogFolder.read(folder) }
        #expect(throws: RaceLogFolderError.missingTunedFile(rules.ref)) {
            try RaceLogFolder.write(log, tunedFiles: [conditions.ref: conditions.data, boatClass.ref: boatClass.data],
                                    to: folder)
        }
        try Data(rules.data.dropLast()).write(to: folder.appendingPathComponent("rules/fleet-rules@1+tune7.json"))
        #expect(throws: DataFileError.self) { try RaceLogFolder.read(folder) }
    }

    /// The export: the next version of the file, with the tuned values, each changed pointer listed under
    /// `placeholders` and the note added, loading as that version. Nothing else changes.
    @Test func nextVersionIsReadyForResources() throws {
        let skiff = try Self.bytes(BoatClass.self, DataFileKey(id: "skiff", version: 1))
        let values: [String: Double] = ["/steering/autohelm/upwindSnapDegrees": 4.5, "/momentum/noGoSeconds": 4.8]
        let next = try TunedCopy.nextVersion(of: skiff, values: values, note: "Version 2: a 4.5 deg upwind snap (#232).")
        let file = try BoatClassFile(data: next)
        #expect(file.version == 2)
        #expect(file.ref.tune == nil)
        #expect(file.content.steering.autohelm.upwindSnap == deg2rad(4.5))
        let original = try BoatClassFile(data: skiff)
        // The unchanged value (4.8 s no-go) isn't listed; the changed one is, after the file's own.
        #expect(file.header.placeholders == original.header.placeholders + ["/steering/autohelm/upwindSnapDegrees"])
        let text = String(decoding: next, as: UTF8.self)
        #expect(text.contains(#"    "Version 2: a 4.5 deg upwind snap (#232)."\#n  ],"#))
        #expect(text.contains(#"    "/byTheLee",\#n    "/steering/autohelm/upwindSnapDegrees"\#n  ],"#))

        // A file without placeholders gets them after its version.
        let bare = Data(#"{"schemaVersion": 1, "id": "x", "version": 4, "a": { "b": 1 }}"#.utf8)
        #expect(String(decoding: try TunedCopy.nextVersion(of: bare, values: ["/a/b": 2]), as: UTF8.self)
            == #"{"schemaVersion": 1, "id": "x", "version": 5,\#n"placeholders": [\#n  "/a/b"\#n], "a": { "b": 2 }}"#)
    }

    /// Pointers name numbers only, anywhere in the file: in nested objects, arrays and with escaped keys.
    @Test func pointersNameOnlyNumbers() throws {
        let data = Data(#"{"a": {"b/c": [1, 2.5, {"d": -3e2}]}, "s": "x", "t": true, "n": null, "m~": 7}"#.utf8)
        #expect(TunedCopy.number(at: "/a/b~1c/1", in: data) == 2.5)
        #expect(TunedCopy.number(at: "/a/b~1c/2/d", in: data) == -300)
        #expect(TunedCopy.number(at: "/m~0", in: data) == 7)
        #expect(TunedCopy.numbers(at: "/a/b~1c", in: data) == nil)
        for pointer in ["/s", "/t", "/n", "/a", "/a/b~1c/3", "/a/b~1c/01", "/missing", "a"] {
            #expect(TunedCopy.number(at: pointer, in: data) == nil, "\(pointer)")
            #expect(throws: TunedCopyError.notANumber(pointer: pointer)) { try TunedCopy.patched(data, values: [pointer: 1]) }
        }
        #expect(throws: TunedCopyError.notFinite(pointer: "/m~0")) { try TunedCopy.patched(data, values: ["/m~0": .nan]) }
        #expect(String(decoding: try TunedCopy.patched(data, values: ["/a/b~1c/2/d": 0.1 + 0.2, "/m~0": 8]), as: UTF8.self)
            == #"{"a": {"b/c": [1, 2.5, {"d": 0.3}]}, "s": "x", "t": true, "n": null, "m~": 8}"#)
        #expect(TunedCopy.numbers(at: "/columns", in: Data(#"{"columns": [0, 1.5, 3]}"#.utf8)) == [0, 1.5, 3])
    }

    /// The polar's upwind-angle sliders: warping one column moves its groove to about the angle asked for,
    /// keeps its best VMG, and leaves the other columns and the rows from 90° on alone.
    @Test func upwindAngleWarpMovesTheGroove() throws {
        let base = try Self.bytes(BoatClass.self, DataFileKey(id: "skiff", version: 1))
        let original = try BoatClassFile(data: base).content.polar
        let rows = try #require(TunedCopy.numbers(at: "/polar/twaDegrees", in: base))
        let column = 5 // 12 kn
        let speeds = try #require(TunedCopy.numbers(at: "/polar/columns/\(column)/speedKnots", in: base))
        let from = rad2deg(original.upwindOptima[column].twa)
        #expect(TunedCopy.bestUpwindAngle(twaDegrees: rows, speedKnots: speeds).map { abs($0 - from) < 1e-9 } == true)

        for target in [from - 5, from + 4] {
            let warped = TunedCopy.upwindAngleSpeeds(twaDegrees: rows, speedKnots: speeds, to: target)
            var values: [String: Double] = [:]
            for (r, speed) in warped.enumerated() { values["/polar/columns/\(column)/speedKnots/\(r)"] = speed }
            let polar = try TunedCopy.make(BoatClass.self, base: base, values: values, tune: 1).file.content.polar
            #expect(abs(rad2deg(polar.upwindOptima[column].twa) - target) <= 2, "asked \(target)°")
            #expect(abs(polar.upwindOptima[column].vmg / original.upwindOptima[column].vmg - 1) < 0.02)
            #expect(polar.upwindOptima[column - 1] == original.upwindOptima[column - 1])
            #expect(polar.downwindOptima == original.downwindOptima)
            for (r, twa) in rows.enumerated() where twa == 0 || twa >= 90 { #expect(warped[r] == speeds[r]) }
        }
        #expect(TunedCopy.upwindAngleSpeeds(twaDegrees: rows, speedKnots: speeds, to: from) == speeds)
        // Every driving column's groove lands within 2° of any angle from 38° to 52°: the rows are 5-7° apart.
        for c in 1..<original.twsAxis.count {
            let column = try #require(TunedCopy.numbers(at: "/polar/columns/\(c)/speedKnots", in: base))
            for target in stride(from: 38.0, through: 52, by: 2) {
                let found = TunedCopy.bestUpwindAngle(
                    twaDegrees: rows, speedKnots: TunedCopy.upwindAngleSpeeds(twaDegrees: rows, speedKnots: column, to: target))
                #expect(found.map { abs($0 - target) <= 2 } == true, "column \(c) asked \(target)°, found \(found ?? .nan)°")
            }
        }
        let calm = try #require(TunedCopy.numbers(at: "/polar/columns/0/speedKnots", in: base))
        #expect(TunedCopy.upwindAngleSpeeds(twaDegrees: rows, speedKnots: calm, to: 40) == calm)
    }

    /// The files the panel can tune are the bundle's, listed by id and version, each one `bundledData` reads;
    /// another bundle lists its own folder, or nothing where it has none.
    @Test func bundledKeysListTheBundle() throws {
        let conditions = ConditionsFile.bundledKeys()
        #expect(conditions.contains(Self.conditionsKey))
        #expect(conditions.count == 12)
        #expect(BoatClassFile.bundledKeys().contains(DataFileKey(id: "skiff", version: 1)))
        #expect(RulesConfigFile.bundledKeys() == [1, 2, 3, 4].map { DataFileKey(id: "fleet-rules", version: $0) })
        #expect(VenueFile.bundledKeys().map(\.version) == [1, 2, 3])
        for key in conditions {
            #expect(try ConditionsFile.bundledData(id: key.id, version: key.version) != nil, "\(key)")
        }
        #expect(VenueFile.bundledKeys(in: .module) == [DataFileKey(id: "test-venue", version: 1)])
        #expect(BoatClassFile.bundledKeys(in: .module).isEmpty)
    }
}
