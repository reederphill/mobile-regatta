import Foundation
import Testing
@testable import RegattaCore

/// The bundled schema-2 boat class, ilca-dinghy@3 (races sailed it by default before #248), and edited
/// copies of its bytes. `SkiffFixtures` is the schema-3 class races sail now.
enum Fixtures {
    static let classID = "ilca-dinghy"
    static let version = 3
    /// SHA-256 of each bundled `Resources/boat-classes/ilca-dinghy@<version>.json`. A released file
    /// never changes (ADR 0004): if one fails, ship the change as the next version instead of editing it.
    /// Versions 1 and 2 are schema 1, which this build refuses: they stay bundled for the builds that
    /// replay the logs sailed on them (ADR 0002).
    static let pinnedHashes = [
        1: "8eb6e20398d859edafec53ef904227672dd5ef081d1611fcb2e89d7e9da5849d",
        2: "f5c8f1677a45f76c2ffe27914671ea0ce615614944f331027c506cafb6caa12d",
        3: "0796b93570fb9723697162f3da4617b28ee0100f693116f1574a198c4c3bf792",
    ]

    static func bytes(version: Int = version) throws -> Data {
        try #require(try BoatClassFile.bundledData(id: classID, version: version))
    }

    static func text(version: Int = version) throws -> String {
        String(decoding: try bytes(version: version), as: UTF8.self)
    }

    /// The bundled file with each `(of, with)` replacement applied, each of which must match.
    static func edited(_ replacements: [(of: String, with: String)], version: Int = version) throws -> Data {
        var text = try text(version: version)
        for r in replacements {
            #expect(text.contains(r.of), "fixture no longer contains \(r.of)")
            text = text.replacingOccurrences(of: r.of, with: r.with)
        }
        return Data(text.utf8)
    }

    static func boatClass() throws -> BoatClass {
        try BoatClassFile.bundled(id: classID, version: version).content
    }
}

/// The bundled schema-3 boat class races sail by default (`Race.defaultBoatClass`, #248): skiff@3 since #263,
/// and edited copies of its bytes.
enum SkiffFixtures {
    static let classID = "skiff"
    static let version = 3
    /// SHA-256 of each bundled `Resources/boat-classes/skiff@<version>.json`. A released file never changes
    /// (ADR 0004): if one fails, ship the change as the next version instead of editing it. Version 1 stays
    /// bundled for the logs sailed on it (ADR 0002).
    static let pinnedHashes = [
        1: "826fa149ace5a1d876829129216281725001f43c99c247e074582cd99f2ed6f4",
        2: "32e5162d6caf3e32280ca754c1381e1012e4db4ef04252bf278b96dd796f5cd1",
        3: "8bfa7a344f3eeda1c9fb0c80e9ca39a972de184a37317e0db2cf9df4876ba723",
    ]

    static func bytes(version: Int = version) throws -> Data {
        try #require(try BoatClassFile.bundledData(id: classID, version: version))
    }

    /// The bundled file with each `(of, with)` replacement applied, each of which must match.
    static func edited(_ replacements: [(of: String, with: String)], version: Int = version) throws -> Data {
        var text = String(decoding: try bytes(version: version), as: UTF8.self)
        for r in replacements {
            #expect(text.contains(r.of), "fixture no longer contains \(r.of)")
            text = text.replacingOccurrences(of: r.of, with: r.with)
        }
        return Data(text.utf8)
    }

    static func boatClass(version: Int = version) throws -> BoatClass {
        try BoatClassFile.bundled(id: classID, version: version).content
    }
}

@Suite struct ContentHashTests {
    @Test func sha256MatchesKnownVectors() {
        #expect(ContentHash(of: Data()).hex == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(ContentHash(of: Data("abc".utf8)).hex == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func hexRoundTripsAndRejectsJunk() throws {
        let hash = ContentHash(of: Data("abc".utf8))
        #expect(ContentHash(hex: hash.hex) == hash)
        #expect(ContentHash(hex: String(hash.hex.dropLast())) == nil)
        #expect(ContentHash(hex: hash.hex.uppercased()) == nil)
        #expect(ContentHash(hex: String(repeating: "g", count: 64)) == nil)
        #expect(hash.description == "sha256:" + hash.hex)
    }

    @Test func fileRefRoundTripsThroughJSON() throws {
        let ref = try BoatClassFile.bundled(id: Fixtures.classID, version: Fixtures.version).ref
        let decoded = try JSONDecoder().decode(FileRef.self, from: JSONEncoder().encode(ref))
        #expect(decoded == ref)
    }
}

@Suite struct DataFileLoaderTests {
    @Test func bundledBoatClassDecodes() throws {
        let file = try BoatClassFile.bundled(id: Fixtures.classID, version: Fixtures.version)
        #expect(file.schemaVersion == 2)
        #expect(file.id == "ilca-dinghy")
        #expect(file.version == Fixtures.version)
        #expect(file.ref.id == "ilca-dinghy" && file.ref.version == Fixtures.version)
        #expect(file.content.name == "Dinghy")
    }

    @Test func decodesFromDataNotPaths() throws {
        let data = try Fixtures.bytes()
        let file = try BoatClassFile(data: data)
        #expect(file.ref == (try BoatClassFile.bundled(id: Fixtures.classID, version: Fixtures.version)).ref)
    }

    @Test(arguments: Fixtures.pinnedHashes.keys.sorted())
    func hashOfBundledFileIsPinned(version: Int) throws {
        let data = try #require(try BoatClassFile.bundledData(id: Fixtures.classID, version: version))
        #expect(ContentHash(of: data).hex == Fixtures.pinnedHashes[version])
    }

    @Test(arguments: [0, 1, 4, 99])
    func wrongSchemaVersionThrows(schemaVersion: Int) throws {
        let data = try Fixtures.edited([(of: #""schemaVersion": 2,"#, with: #""schemaVersion": \#(schemaVersion),"#)])
        #expect(throws: DataFileError.unsupportedSchemaVersion(kind: "boat class", found: schemaVersion, supported: [2, 3])) {
            try BoatClassFile(data: data)
        }
    }

    /// #230: schema 1 has no autohelm values and RegattaCore holds no boat constants to fill them with
    /// (ADR 0004), so this build refuses a schema-1 class: the bundled versions 1 and 2, a race that
    /// names one, and version 3's own content headed as schema 1.
    @Test func schemaOneBoatClassIsRefused() throws {
        for version in [1, 2] {
            let data = try #require(try BoatClassFile.bundledData(id: Fixtures.classID, version: version))
            #expect(throws: DataFileError.unsupportedSchemaVersion(kind: "boat class", found: 1, supported: [2, 3])) {
                try BoatClassFile(data: data)
            }
            #expect(throws: DataFileError.unsupportedSchemaVersion(kind: "boat class", found: 1, supported: [2, 3])) {
                try BoatClassFile.bundled(id: Fixtures.classID, version: version)
            }
            let ref = FileRef(id: Fixtures.classID, version: version, hash: ContentHash(of: data))
            let setup = try RaceSetup(raceSeed: RaceSeed(1), seats: [.human, .bot], boatClass: ref)
            #expect(throws: DataFileError.unsupportedSchemaVersion(kind: "boat class", found: 1, supported: [2, 3])) {
                try RaceFiles(resolving: setup)
            }
        }
        let headedOne = try Fixtures.edited([(of: #""schemaVersion": 2,"#, with: #""schemaVersion": 1,"#)])
        #expect(throws: DataFileError.unsupportedSchemaVersion(kind: "boat class", found: 1, supported: [2, 3])) {
            try BoatClassFile(data: headedOne)
        }
        #expect(BoatClass.supportedSchemaVersions == [2, 3])
        #expect(RaceFiles.defaults.boatClass.ref == (try BoatClassFile.bundled(id: SkiffFixtures.classID, version: SkiffFixtures.version)).ref,
                "races sail skiff@3 unless told otherwise (#248, #89, #263)")
    }

    @Test func missingHeaderIsMalformed() throws {
        let data = try Fixtures.edited([(of: #""schemaVersion": 2,"#, with: "")])
        #expect {
            try BoatClassFile(data: data)
        } throws: { error in
            if case .malformed(kind: "boat class", reason: _) = error as? DataFileError { return true }
            return false
        }
        #expect(throws: DataFileError.self) { try BoatClassFile(data: Data("not json".utf8)) }
    }

    @Test(arguments: [
        (#""name": "Dinghy","#, #""name": "Dinghy", "name": "Other","#, "/name"),
        (#""beamMetres": 1.5,"#, #""beamMetres": 1.5, "beamMetres": 2,"#, "/hull/beamMetres"),
        (#""schemaVersion": 2,"#, #""schemaVersion": 2, "schemaVersion": 1,"#, "/schemaVersion"),
    ])
    func duplicateKeyIsMalformed(of: String, with: String, pointer: String) throws {
        // Refused before anything parses the file, whatever the kind: parsers disagree on which copy wins.
        let data = try Fixtures.edited([(of: of, with: with)])
        #expect(throws: DataFileError.malformed(kind: "boat class", reason: "duplicate field \(pointer)")) {
            try BoatClassFile(data: data)
        }
    }

    @Test func badIDOrVersionThrows() throws {
        let badID = try Fixtures.edited([(of: #""id": "ilca-dinghy""#, with: #""id": "ILCA dinghy""#)])
        let badVersion = try Fixtures.edited([(of: #""version": \#(Fixtures.version),"#, with: #""version": 0,"#)])
        for data in [badID, badVersion] {
            #expect {
                try BoatClassFile(data: data)
            } throws: { error in
                if case .invalidHeader = error as? DataFileError { return true }
                return false
            }
        }
    }

    @Test func invalidContentThrows() throws {
        // One speed short in the 6 kn column: the polar isn't rectangular.
        let data = try Fixtures.edited([(of: "[0, 2.4, 3.0, 3.4, 3.7,", with: "[2.4, 3.0, 3.4, 3.7,")])
        #expect {
            try BoatClassFile(data: data)
        } throws: { error in
            if case .invalidContent(kind: "boat class", id: "ilca-dinghy", reason: _) = error as? DataFileError { return true }
            return false
        }
    }

    @Test func expectedRefIsChecked() throws {
        let data = try Fixtures.bytes()
        let ref = try BoatClassFile(data: data).ref
        #expect(try BoatClassFile(data: data, expecting: ref).ref == ref)

        // Same id and version, one byte different: a different file.
        var changed = data
        changed.append(UInt8(ascii: "\n"))
        #expect(throws: DataFileError.refMismatch(expected: ref, foundHash: ContentHash(of: changed))) {
            try BoatClassFile(data: changed, expecting: ref)
        }
        // Checked before parsing: bytes that aren't even JSON fail on the hash.
        let junk = Data("not json".utf8)
        #expect(throws: DataFileError.refMismatch(expected: ref, foundHash: ContentHash(of: junk))) {
            try BoatClassFile(data: junk, expecting: ref)
        }
        // The right bytes named with the wrong id or version: the ref itself is wrong.
        for wrong in [FileRef(id: "other-boat", version: 1, hash: ref.hash), FileRef(id: ref.id, version: ref.version + 1, hash: ref.hash)] {
            #expect {
                try BoatClassFile(data: data, expecting: wrong)
            } throws: { error in
                if case .invalidHeader(kind: "boat class", reason: _) = error as? DataFileError { return true }
                return false
            }
        }
    }

    @Test func notBundledThrows() {
        #expect(throws: DataFileError.notBundled(kind: "boat class", id: "ilca-dinghy", version: 99)) {
            try BoatClassFile.bundled(id: "ilca-dinghy", version: 99)
        }
    }

    @Test(arguments: ["", "../boat-classes/ilca-dinghy", "ILCA-dinghy", "ilca dinghy", "ilca/dinghy"])
    func bundledRejectsInvalidIDs(id: String) {
        #expect(throws: DataFileError.invalidID(kind: "boat class", id: id)) {
            try BoatClassFile.bundled(id: id, version: 1)
        }
        #expect(throws: DataFileError.invalidID(kind: "boat class", id: id)) {
            try BoatClassFile.bundledData(id: id, version: 1)
        }
    }

    @Test func multipleVersionsLoadSideBySide() throws {
        // Version 3 as bundled, and "versions" 1 and 2 of its content: any two versions of a class.
        let v1 = try BoatClassFile(data: Fixtures.edited([(of: #""version": 3,"#, with: #""version": 1,"#)]))
        let v2 = try BoatClassFile(data: Fixtures.edited([
            (of: #""version": 3,"#, with: #""version": 2,"#),
            (of: #""boatSpeedFactor": 0.6"#, with: #""boatSpeedFactor": 0.7"#),
        ]))
        #expect(v2.version == 2 && v2.id == v1.id)
        #expect(v2.ref.hash != v1.ref.hash)
        #expect(v1.content.contact.boat == 0.6)
        #expect(v2.content.contact.boat == 0.7)

        var catalog = DataFileCatalog<BoatClass>()
        try catalog.add(v2)
        try catalog.add(v1)
        try catalog.add(v1) // the same bytes again: no-op
        #expect(catalog.files.count == 2)
        #expect(catalog.versions(of: Fixtures.classID) == [1, 2])
        #expect(catalog.file(v1.ref)?.content.contact.boat == 0.6)
        #expect(catalog.file(id: Fixtures.classID, version: 2)?.content.contact.boat == 0.7)
        #expect(catalog.file(FileRef(id: v1.id, version: 1, hash: v2.ref.hash)) == nil)
    }

    /// A released version never changes (ADR 0004): a second, different untuned "version 2" is refused,
    /// whatever tuned copies of that version the catalog holds.
    @Test func untunedDuplicateVersionStillConflicts() throws {
        let v2 = try BoatClassFile(data: Fixtures.edited([
            (of: #""version": 3,"#, with: #""version": 2,"#),
            (of: #""boatSpeedFactor": 0.6"#, with: #""boatSpeedFactor": 0.7"#),
        ]))
        let otherBytes = try Fixtures.edited([
            (of: #""version": 3,"#, with: #""version": 2,"#),
            (of: #""boatSpeedFactor": 0.6"#, with: #""boatSpeedFactor": 0.8"#),
        ])
        let otherV2 = try BoatClassFile(data: otherBytes)
        var catalog = DataFileCatalog<BoatClass>()
        try catalog.add(v2)
        // The same bytes as a tuned copy sit beside version 2; untuned, they conflict with it.
        try catalog.add(try BoatClassFile(data: otherBytes, tune: 1))
        #expect(throws: DataFileError.conflictingVersion(existing: v2.ref, new: otherV2.ref)) {
            try catalog.add(otherV2)
        }
        #expect(catalog.files.count == 2)
        #expect(catalog.file(id: Fixtures.classID, version: 2)?.ref == v2.ref)
    }

    /// A tuned copy (#229) keeps its base file's id and version and is added beside it, told apart by
    /// its hash and tune. Only its own ref finds it, so it never shadows the bundled file, in the
    /// catalog or when a race resolves its files.
    @Test func tunedCopyWithSameVersionIsAccepted() throws {
        let bundled = try BoatClassFile.bundled(id: Fixtures.classID, version: Fixtures.version)
        let tunedBytes = try Fixtures.edited([(of: #""boatSpeedFactor": 0.6"#, with: #""boatSpeedFactor": 0.7"#)])
        let tuned = try BoatClassFile(data: tunedBytes, tune: 1)
        // The header's id and version, and the hash of the bytes alone.
        #expect(tuned.ref == FileRef(id: bundled.id, version: bundled.version, hash: ContentHash(of: tunedBytes), tune: 1))
        #expect(bundled.ref.tune == nil)
        // Another copy of the same version, and one with the bundled bytes: each tuned copy is its own file.
        let retuned = try BoatClassFile(
            data: try Fixtures.edited([(of: #""boatSpeedFactor": 0.6"#, with: #""boatSpeedFactor": 0.8"#)]), tune: 2)
        let untouched = try BoatClassFile(data: try Fixtures.bytes(), tune: 3)
        #expect(untouched.ref.hash == bundled.ref.hash && untouched.ref != bundled.ref)

        // The tuned copies first: finding the bundled file mustn't depend on the order they were added.
        var catalog = DataFileCatalog<BoatClass>()
        #expect(try catalog.add(tuned) == tuned.ref)
        try catalog.add(retuned)
        try catalog.add(untouched)
        #expect(catalog.file(id: Fixtures.classID, version: Fixtures.version) == nil)
        #expect(catalog.versions(of: Fixtures.classID).isEmpty)
        #expect(try catalog.add(bundled) == bundled.ref)
        #expect(try catalog.add(tuned) == tuned.ref) // the same copy again: no-op
        #expect(catalog.files.count == 4)
        #expect(catalog.versions(of: Fixtures.classID) == [Fixtures.version])
        #expect(catalog.file(id: Fixtures.classID, version: Fixtures.version)?.ref == bundled.ref)
        #expect(catalog.file(bundled.ref)?.content.contact.boat == 0.6)
        #expect(catalog.file(tuned.ref)?.content.contact.boat == 0.7)
        #expect(catalog.file(retuned.ref)?.content.contact.boat == 0.8)
        #expect(catalog.file(untouched.ref)?.ref == untouched.ref)

        // A race resolves each ref to exactly its own file, by id, version and hash at once.
        var files = RaceFileCatalog()
        files.boatClasses = catalog
        for file in [bundled, tuned, retuned, untouched] {
            let setup = try RaceSetup(raceSeed: RaceSeed(239), seats: [.human, .bot], boatClass: file.ref)
            #expect(try RaceFiles(resolving: setup, from: files).boatClass.ref == file.ref)
        }
        // A tuned copy's bytes aren't in the bundle: without its file beside it, its ref doesn't resolve.
        let setup = try RaceSetup(raceSeed: RaceSeed(239), seats: [.human, .bot], boatClass: tuned.ref)
        #expect(throws: DataFileError.refMismatch(expected: tuned.ref, foundHash: bundled.ref.hash)) {
            try RaceFiles(resolving: setup)
        }
    }

    /// The race-log header records a tuned copy's ref with its tune, and the log replays with that copy
    /// beside it (ADR 0004). An untuned ref leaves `tune` out, keeping #58's {id, version, hash} shape.
    @Test func tunedRefRoundTripsInTheRaceLogHeader() throws {
        let tuned = try BoatClassFile(
            data: try Fixtures.edited([(of: #""boatSpeedFactor": 0.6"#, with: #""boatSpeedFactor": 0.7"#)]), tune: 4)
        let bundled = try BoatClassFile.bundled(id: Fixtures.classID, version: Fixtures.version).ref
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(String(decoding: try encoder.encode(tuned.ref), as: UTF8.self)
            == #"{"hash":"\#(tuned.ref.hash.hex)","id":"ilca-dinghy","tune":4,"version":3}"#)
        #expect(String(decoding: try encoder.encode(bundled), as: UTF8.self)
            == #"{"hash":"\#(bundled.hash.hex)","id":"ilca-dinghy","version":3}"#)

        var catalog = RaceFileCatalog()
        try catalog.boatClasses.add(tuned)
        let setup = try RaceSetup(raceSeed: RaceSeed(239), seats: [.human, .bot], startSequenceTicks: 30, boatClass: tuned.ref)
        let race = try Race(setup: setup, files: RaceFiles(resolving: setup, from: catalog),
                            mode: .authoritative(windSeed: WindSeed(239)))
        for _ in 0..<45 { race.step() }
        let log = try #require(race.log)
        #expect(log.header.setup.boatClass == tuned.ref)

        let data = try log.jsonData()
        let decoded = try RaceLog(jsonData: data)
        #expect(decoded == log)
        #expect(decoded.header.setup.boatClass.tune == 4)
        // Only the boat class is tuned: the other three refs have no `tune` key.
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.components(separatedBy: #""tune""#).count == 2)
        #expect(text.contains(#""tune" : 4"#))

        #expect(try Replayer.digest(of: decoded, catalog: catalog) == race.digest())
        #expect(throws: DataFileError.refMismatch(expected: tuned.ref, foundHash: bundled.hash)) {
            try Replayer.replay(decoded)
        }
    }

    @Test func placeholdersResolveAndCoverTheTuningList() throws {
        let file = try BoatClassFile.bundled(id: Fixtures.classID, version: Fixtures.version)
        let placeholders = file.header.placeholders
        let polar = file.content.polar
        // The 0, 4 and 25 kn polar columns.
        for (pointer, knots) in [("/polar/columns/0", 0.0), ("/polar/columns/1", 4.0), ("/polar/columns/9", 25.0)] {
            #expect(placeholders.contains(pointer))
            let column = try #require(Int(pointer.split(separator: "/").last!))
            #expect(polar.twsAxis[column] == metresPerSecond(knots: knots))
        }
        for pointer in ["/steering/rudderSlewPerSecond", "/windShadow/backwind", "/windShadow/stackingFloor"] {
            #expect(placeholders.contains(pointer), "\(pointer) should be marked as a placeholder")
        }
        // #230: every autohelm value is a placeholder until it's tuned as a debug slider (ADR 0007).
        for field in ["upwindSnapDegrees", "downwindSnapDegrees", "gainRudderPerDegree", "deadRunMarginDegrees", "byTheLeeMarginDegrees"] {
            #expect(placeholders.contains("/steering/autohelm/" + field), "\(field) should be marked as a placeholder")
        }
    }

    @Test func unresolvedPlaceholderThrows() throws {
        let data = try Fixtures.edited([(of: #""/steering/rudderSlewPerSecond""#, with: #""/steering/rudderSlew""#)])
        #expect(throws: DataFileError.unresolvedPlaceholder(kind: "boat class", id: "ilca-dinghy", pointer: "/steering/rudderSlew")) {
            try BoatClassFile(data: data)
        }
        let pastEnd = try Fixtures.edited([(of: #""/polar/columns/9""#, with: #""/polar/columns/10""#)])
        #expect(throws: DataFileError.self) { try BoatClassFile(data: pastEnd) }
    }
}

@Suite struct BoatClassTests {
    @Test func valuesAreConvertedToCodeUnitsOnce() throws {
        let c = try Fixtures.boatClass()
        let length = 4.2
        #expect(c.hull.length == length && c.hull.beam == 1.5)
        #expect(c.hull.outline.count == 5 && c.hull.outline[0] == Vec2(0, 2.1))

        #expect(c.polar.twaAxis[4] == deg2rad(45))
        #expect(c.polar.twsAxis[5] == metresPerSecond(knots: 12))
        #expect(c.polar.speeds[5][4] == metresPerSecond(knots: 5.3))

        #expect(c.momentum == .init(speedingUp: 4, slowingDown: 5, noGo: 4))
        #expect(c.steering.topTurnRate == deg2rad(30))
        #expect(c.steering.minTurnRate == deg2rad(10))
        #expect(c.steering.rudderSlew > 0 && c.steering.rudderDrag >= 0 && c.steering.headToWindFallOffRate > 0)
        #expect(c.steering.autohelm == .init(upwindSnap: deg2rad(3), downwindSnap: deg2rad(5), gain: 0.1 * 180 / .pi,
                                             deadRunMargin: deg2rad(3), byTheLeeMargin: deg2rad(3), grooveWindAverage: 0))
        // Schema 2 (#248): no planing, no spinnaker, no graded by-the-lee loss, grooves in the wind right now.
        #expect(c.planing == nil && c.spinnaker == nil && c.byTheLee == nil)

        #expect(c.windShadow.coneLength == 8 * length)
        #expect(c.windShadow.lossCloseIn == 0.25)
        #expect(c.windShadow.stackingFloor == 0.6)
        #expect(c.windShadow.coneWidthAtEnd > c.windShadow.coneWidthAtBoat)
        #expect(c.windShadow.backwindLength > 0 && c.windShadow.backwindWidth > 0)
        #expect(c.windShadow.backwindLoss > 0 && c.windShadow.backwindLoss < c.windShadow.lossCloseIn)

        #expect(c.contact == .init(boat: 0.6, mark: 0.5))
        #expect(c.ease.speedFraction > 0 && c.ease.speedFraction < 1 && c.ease.timeConstant > 0)
    }

    /// #230: the autohelm's values are checked at load like the rest of the steering.
    @Test(arguments: [
        (#""gainRudderPerDegree": 0.1"#, #""gainRudderPerDegree": 0"#),
        (#""upwindSnapDegrees": 3"#, #""upwindSnapDegrees": -1"#),
        (#""downwindSnapDegrees": 5"#, #""downwindSnapDegrees": 90"#),
        (#""deadRunMarginDegrees": 3"#, #""deadRunMarginDegrees": 95"#),
    ])
    func autohelmValuesAreChecked(of: String, with: String) throws {
        let data = try Fixtures.edited([(of: of, with: with)])
        #expect {
            try BoatClassFile(data: data)
        } throws: { error in
            if case .invalidContent(kind: "boat class", id: "ilca-dinghy", reason: let reason) = error as? DataFileError {
                return reason.contains("autohelm")
            }
            return false
        }
    }

    static let outline = "[[0, 2.1], [0.75, 0.21], [0.63, -2.1], [-0.63, -2.1], [-0.75, 0.21]]"

    @Test(arguments: [
        // A notch in the transom: concave.
        "[[0, 2.1], [0.75, 0.21], [0.63, -2.1], [0, -1.0], [-0.63, -2.1], [-0.75, 0.21]]",
        // The same hull wound the other way (anticlockwise).
        "[[-0.75, 0.21], [-0.63, -2.1], [0.63, -2.1], [0.75, 0.21], [0, 2.1]]",
        // A five-pointed star: every corner turns the same way, but it winds twice.
        "[[0, 2], [1.18, -1.62], [-1.9, 0.62], [1.9, 0.62], [-1.18, -1.62]]",
        // Three points on a line.
        "[[0, 2], [0, 0], [0, -2]]",
    ])
    func nonConvexOrMiswoundOutlineThrows(outline: String) throws {
        let data = try Fixtures.edited([(of: Self.outline, with: outline)])
        #expect {
            try BoatClassFile(data: data)
        } throws: { error in
            if case .invalidContent(kind: "boat class", id: "ilca-dinghy", reason: let reason) = error as? DataFileError {
                return reason.contains("convex")
            }
            return false
        }
    }

    @Test func hullOutlinePlacesTheBundledOutlineInTheWorld() throws {
        let hull = try Fixtures.boatClass().hull
        var boat = Boat(id: 0, isPlayer: false, colorIndex: 0, position: .zero, heading: 0, speed: 0)
        // Heading 0 is north, so the boat's frame is the world frame.
        let placed = boat.hull(outline: hull.outline)
        #expect(placed.count == hull.outline.count)
        for (a, b) in zip(hull.outline, placed) {
            #expect((a - b).length < 1e-9)
        }
        // Heading east at (10, 5): the bow (0, length / 2) lands half a hull length east of the boat.
        boat.heading = .pi / 2
        boat.position = Vec2(10, 5)
        #expect((boat.hull(outline: hull.outline)[0] - Vec2(10 + hull.length / 2, 5)).length < 1e-9)
    }

    @Test func turnRateRisesWithSpeedFromMinToTop() throws {
        let steering = try Fixtures.boatClass().steering
        #expect(steering.turnRate(speed: 0) == deg2rad(10))
        #expect(steering.turnRate(speed: metresPerSecond(knots: 5)) == deg2rad(30))
        var previous = 0.0
        for tenths in 0...60 {
            let rate = steering.turnRate(speed: metresPerSecond(knots: Double(tenths) / 10))
            #expect(rate >= previous && rate >= deg2rad(10) && rate <= deg2rad(30))
            previous = rate
        }
    }

    @Test func byTheLeeLimitFallsFrom30At6KnotsTo15From15Knots() throws {
        let polar = try Fixtures.boatClass().polar
        func limit(_ knots: Double) -> Double { rad2deg(polar.byTheLeeLimit(tws: metresPerSecond(knots: knots))) }
        #expect(abs(limit(4) - 30) < 1e-9)
        #expect(abs(limit(6) - 30) < 1e-9)
        #expect(abs(limit(10.5) - 22.5) < 1e-9)
        #expect(abs(limit(15) - 15) < 1e-9)
        #expect(abs(limit(20) - 15) < 1e-9)
        #expect(polar.byTheLeePenalty == 0.02)
    }
}

@Suite struct JSONPointerTests {
    static var document: Any {
        try! JSONSerialization.jsonObject(with: Data(#"""
            {"a": {"b": [10, {"c": null}], "x/y": 1, "m~n": 2, "": 3}, "list": [[0, 1], [2]], "s": "text"}
            """#.utf8))
    }

    @Test(arguments: ["", "/a", "/a/b", "/a/b/0", "/a/b/1/c", "/a/x~1y", "/a/m~0n", "/a/", "/list/1/0", "/s"])
    func resolves(pointer: String) {
        #expect(JSONPointer.resolve(pointer, in: Self.document) != nil)
    }

    @Test(arguments: ["a", "/b", "/a/b/2", "/a/b/01", "/a/b/-1", "/a/b/-", "/a/b/x", "/a/b/", "/a/b/0/c", "/s/0", "/a/x/y",
                      "/list/99999999999999999999999"])
    func pointsAtNothing(pointer: String) {
        #expect(JSONPointer.resolve(pointer, in: Self.document) == nil)
    }
}

@Suite struct JSONPrecheckTests {
    static func problem(_ json: String) -> JSONPrecheck.Problem? { JSONPrecheck.problem(in: Data(json.utf8)) }

    @Test func duplicatesAreFoundWithTheirPointer() {
        #expect(Self.problem(#"{"a": 1, "b": {"c": [1, 2]}, "s": "{\"a\": 1, \"a\": 2}", "t": "\\"}"#) == nil)
        #expect(Self.problem(#"{"a": [{"x": 1}, {"x": 1, "y": {"z": 1, "z": 2}}]}"#) == .duplicate(pointer: "/a/1/y/z"))
        #expect(Self.problem(#"{"a/b": {"~": 1, "~": 2}}"#) == .duplicate(pointer: "/a~1b/~0"))
        #expect(Self.problem(#"[{"k": 1}, {"k": 2}]"#) == nil)
        #expect(Self.problem(#"{"k": "x", "v": "k", "k": 2}"#) == .duplicate(pointer: "/k"))
        #expect(Self.problem(#"[[0], [1, {"q": {}, "q": 2}]]"#) == .duplicate(pointer: "/1/1/q"))
        #expect(Self.problem(#"{"a\u0062": 1, "ab": 2}"#) == .duplicate(pointer: "/ab"))
    }

    @Test func undecodableEscapedKeyFailsClosed() throws {
        // A lone surrogate: the scan can't decode the key, so it refuses the file rather than skip the rest.
        #expect(Self.problem(#"{"\ud800":1,"a":1,"a":2}"#) == .badKey(pointer: #"/\ud800"#))
        #expect(Self.problem(#"{"x": [{"ok\n": 1, "b\udfff": 2}]}"#) == .badKey(pointer: #"/x/0/b\udfff"#))
        #expect(throws: DataFileError.malformed(kind: "boat class", reason: #"undecodable key at /\ud800"#)) {
            try BoatClassFile(data: Data(#"{"\ud800":1,"a":1,"a":2}"#.utf8))
        }
        // Every other malformed escape, and escapes that do decode.
        for key in [#"\udc00"#, #"\ud800\u0041"#, #"\ud800x"#, #"\u12"#, #"\u12g4"#, #"\x41"#, #"\ud83d\ud83d"#] {
            #expect(Self.problem(#"{"\#(key)": 1}"#) == .badKey(pointer: "/" + key), "\(key)")
        }
        #expect(Self.problem(#"{"\ud83d\ude00": 1, "😀": 2}"#) == .duplicate(pointer: "/😀"))
        #expect(Self.problem(#"{"\"\\\/\b\f\n\r\t": 1, "\u0022\u005c/\u0008\u000C\u000a\u000D\u0009": 2}"#)
                == .duplicate(pointer: "/\"\\~1\u{08}\u{0C}\n\r\t"))
        #expect(Self.problem(#"{"caf\u00e9": 1, "café": 2}"#) == .duplicate(pointer: "/café"))
        // An unterminated string is left to the parser.
        #expect(Self.problem(#"{"a": "b"#) == nil)
    }

    @Test func onlyUTF8IsAccepted() throws {
        let json = #"{"name": "∞ Ģ", "other": 1}"#
        #expect(Self.problem(json) == nil)
        for encoding: String.Encoding in [.utf16LittleEndian, .utf16BigEndian, .utf16, .utf32LittleEndian, .utf32BigEndian, .utf32] {
            let data = try #require(json.data(using: encoding))
            #expect(JSONPrecheck.problem(in: data) == .notUTF8, "\(encoding)")
        }
        // Invalid UTF-8 (a lone continuation byte, an overlong "/"), and a raw NUL.
        #expect(JSONPrecheck.problem(in: Data([0x7B, 0x22, 0x80, 0x22, 0x3A, 0x31, 0x7D])) == .notUTF8)
        #expect(JSONPrecheck.problem(in: Data([0x7B, 0x22, 0xC0, 0xAF, 0x22, 0x3A, 0x31, 0x7D])) == .notUTF8)
        #expect(JSONPrecheck.problem(in: Data([0x7B, 0x7D, 0x00])) == .notUTF8)
        #expect(JSONPrecheck.problem(in: Data()) == nil)
    }

    @Test func nestingIsCappedAtJSONDecodersLimit() {
        func nested(_ depth: Int) -> String { String(repeating: "[", count: depth) + String(repeating: "]", count: depth) }
        #expect(Self.problem(nested(JSONPrecheck.maxDepth)) == nil)
        #expect(Self.problem(nested(JSONPrecheck.maxDepth + 1)) == .tooDeep)
        let objects = String(repeating: #"{"a":"#, count: 513) + "1" + String(repeating: "}", count: 513)
        #expect(Self.problem(objects) == .tooDeep)
        // Deep input used to build a pointer string per level: quadratic. Now it stops at the cap.
        let clock = ContinuousClock()
        let elapsed = clock.measure { #expect(Self.problem(String(repeating: "[", count: 200_000)) == .tooDeep) }
        #expect(elapsed < .seconds(2))
    }

    @Test func manyKeysScanInLinearTime() {
        // Inserting used to copy the object's whole key set: 40k keys took seconds.
        let count = 50_000
        var json = "{" + (0..<count).map { #""k\#($0)": 0"# }.joined(separator: ", ")
        let clock = ContinuousClock()
        var result: JSONPrecheck.Problem?
        let elapsed = clock.measure { result = Self.problem(json + "}") }
        #expect(result == nil)
        #expect(elapsed < .seconds(3), "\(elapsed) for \(count) keys")
        json += #", "k0": 1}"#
        #expect(Self.problem(json) == .duplicate(pointer: "/k0"))
    }

    @Test func dataFileRefusesEachProblemAsMalformed() throws {
        let deep = Data((String(repeating: "[", count: 600) + String(repeating: "]", count: 600)).utf8)
        #expect(throws: DataFileError.malformed(kind: "boat class", reason: "nested deeper than 512")) {
            try BoatClassFile(data: deep)
        }
        let utf16 = try #require(String(decoding: try Fixtures.bytes(), as: UTF8.self).data(using: .utf16LittleEndian))
        #expect(throws: DataFileError.malformed(kind: "boat class", reason: "not UTF-8")) {
            try BoatClassFile(data: utf16)
        }
    }
}

/// #248: the skiff, the schema-3 boat class. Schema 3 is schema 2 plus planing, the automatic spinnaker, the
/// graded by-the-lee loss and the autohelm's averaged groove wind, every one of them required (ADR 0004).
@Suite struct SkiffClassFileTests {
    @Test(arguments: SkiffFixtures.pinnedHashes.keys.sorted())
    func bundledSkiffIsPinnedAndSchemaThree(version: Int) throws {
        let data = try SkiffFixtures.bytes(version: version)
        #expect(ContentHash(of: data).hex == SkiffFixtures.pinnedHashes[version],
                "a released file never changes (ADR 0004): ship the change as the next version")
        let file = try BoatClassFile.bundled(id: SkiffFixtures.classID, version: version)
        #expect(file.schemaVersion == 3 && file.id == "skiff" && file.version == version)
        #expect(file.content.name == "Skiff")
        // Every value is a placeholder: every top-level block is listed.
        for block in ["/hull", "/polar", "/momentum", "/steering", "/windShadow", "/contact", "/ease", "/planing", "/spinnaker", "/byTheLee"] {
            #expect(file.header.placeholders.contains(block), "\(block) should be a placeholder")
        }
        // #263's roll tack, from version 3 on.
        #expect(file.header.placeholders.contains("/rollTack") == (file.content.rollTack != nil))
        #expect((file.content.rollTack != nil) == (version >= 3))
        // The ILCA files stay bundled for replays (ADR 0002): version 3 still loads beside it.
        #expect(try BoatClassFile.bundled(id: Fixtures.classID, version: 3).schemaVersion == 2)
    }

    /// #89 (the owner): skiff@2 is skiff@1 turning quicker, so a hard-over 360 takes about 10 s, not 14–22 s
    /// (`PenaltyTurnTests.skiffCleanTurnTakesAboutTenSeconds`): a 36°/s top turn rate (30), reached from 1.5 kn
    /// (6) with a 10°/s floor (5), and twice the rudder drag (0.4 a second at full rudder), which keeps a tack
    /// and a gybe close to their costs (`SkiffTests`). Every other value is version 1's.
    @Test func version2IsVersion1TurningQuicker() throws {
        let v1 = try BoatClassFile.bundled(id: SkiffFixtures.classID, version: 1)
        let v2 = try BoatClassFile.bundled(id: SkiffFixtures.classID, version: 2)
        #expect(v2.header.placeholders == v1.header.placeholders)
        let (a, b) = (v1.content, v2.content)
        #expect(b.name == a.name && b.hull == a.hull && b.polar == a.polar && b.momentum == a.momentum)
        #expect(b.windShadow == a.windShadow && b.contact == a.contact && b.ease == a.ease)
        #expect(b.planing == a.planing && b.spinnaker == a.spinnaker && b.byTheLee == a.byTheLee)
        #expect(b.steering.autohelm == a.steering.autohelm && b.steering.rudderSlew == a.steering.rudderSlew)
        #expect(b.steering.headToWindFallOffRate == a.steering.headToWindFallOffRate)
        #expect(a.steering.topTurnRate == deg2rad(30) && a.steering.minTurnRate == deg2rad(5) && a.steering.rudderDrag == 0.2)
        #expect(a.steering.turnRateCurveSpeeds == [0, metresPerSecond(knots: 6)] && a.steering.turnRateCurveFractions == [0, 1])
        #expect(b.steering.topTurnRate == deg2rad(36) && b.steering.minTurnRate == deg2rad(10) && b.steering.rudderDrag == 0.4)
        #expect(b.steering.turnRateCurveSpeeds == [0, metresPerSecond(knots: 1.5)] && b.steering.turnRateCurveFractions == [0, 1])
    }

    /// #263: skiff@3 is skiff@2 with #220's momentum pair (speeding up 1.5 s, slowing down 10 s), the owner's rudder
    /// drag (0.25 a second at full rudder), a shadow that is a speed loss (0.65 close in, its own 2 s slowing down,
    /// stacking floor 0.3) and #222's roll tack. Every other value is version 2's; versions 1 and 2 have neither the
    /// shadow's slowing down nor a roll tack, so their shadow still slows the wind.
    @Test func version3IsVersion2WithMomentumShadowCostAndRollTack() throws {
        let v2 = try BoatClassFile.bundled(id: SkiffFixtures.classID, version: 2)
        let v3 = try BoatClassFile.bundled(id: SkiffFixtures.classID, version: 3)
        #expect(v3.header.placeholders == v2.header.placeholders + ["/rollTack"])
        let (a, b) = (v2.content, v3.content)
        #expect(b.name == a.name && b.hull == a.hull && b.polar == a.polar && b.contact == a.contact && b.ease == a.ease)
        #expect(b.planing == a.planing && b.spinnaker == a.spinnaker && b.byTheLee == a.byTheLee)
        var steering = b.steering
        steering.rudderDrag = a.steering.rudderDrag
        #expect(steering == a.steering && b.steering.rudderDrag == 0.25)
        #expect(a.momentum == .init(speedingUp: 2.8, slowingDown: 4, noGo: 4.8))
        #expect(b.momentum == .init(speedingUp: 1.5, slowingDown: 10, noGo: 4.8))
        var shadow = b.windShadow
        shadow.lossCloseIn = a.windShadow.lossCloseIn
        shadow.stackingFloor = a.windShadow.stackingFloor
        shadow.slowingDown = nil
        #expect(shadow == a.windShadow)
        #expect(!a.windShadow.isSpeedLoss && a.rollTack == nil)
        #expect(b.windShadow.isSpeedLoss && b.windShadow.slowingDown == 2)
        #expect(b.windShadow.lossCloseIn == 0.65 && b.windShadow.stackingFloor == 0.3)
        #expect(b.rollTack == .init(window: 0.25, hitLossFraction: 0.5, missSpeedFactor: 0.8))
    }

    @Test func schemaThreeValuesAreConvertedToCodeUnits() throws {
        let c = try SkiffFixtures.boatClass()
        let knot = metresPerSecond(knots: 1)
        #expect(c.hull.length == 4.9 && c.hull.beam == 1.8 && c.hull.outline.count == 5)
        #expect(c.polar.twaAxis.count == 18 && c.polar.twaAxis[10] == deg2rad(120) && c.polar.twaAxis[15] == deg2rad(155))
        #expect(c.polar.speeds[3][13] == metresPerSecond(knots: 10.1)) // 8 kn, 145°
        #expect(c.momentum == .init(speedingUp: 1.5, slowingDown: 10, noGo: 4.8))
        #expect(c.steering.topTurnRate == deg2rad(36) && c.steering.minTurnRate == deg2rad(10))
        #expect(c.steering.autohelm.downwindSnap == deg2rad(8) && c.steering.autohelm.grooveWindAverage == 30)
        #expect(c.windShadow.coneLength == 9 * 4.9)
        let planing = try #require(c.planing)
        #expect(planing == .init(fromTWA: deg2rad(65), offBelowTWA: deg2rad(55), onSpeed: metresPerSecond(knots: 8),
                                 onMaxAWA: deg2rad(90), offSpeed: metresPerSecond(knots: 6),
                                 offPlaneReferenceTWS: metresPerSecond(knots: 6), offPlaneGain: 0.035 / knot))
        #expect(c.spinnaker == .init(hoistAboveTWA: deg2rad(115), dropBelowTWA: deg2rad(105), transitionTime: 4,
                                     twoSailSpeedFactor: 0.65, twoSailFromTWA: deg2rad(90), twoSailFullTWA: deg2rad(110)))
        #expect(c.byTheLee == .init(speedLossPerRadian: 0.02 * 180 / .pi, spinnakerCollapse: deg2rad(10)))
        // Off the plane at 8 kn, 145°: the 6 kn column's 6.9 kn, 7% up for the 2 kn more wind.
        let off = planing.offPlaneSpeed(twa: deg2rad(145), tws: metresPerSecond(knots: 8), polar: c.polar)
        #expect(abs(off / knot - 6.9 * 1.07) < 1e-9)
    }

    /// Schema 3 has no defaults in code (ADR 0004): each block it adds is required.
    @Test(arguments: ["planing", "spinnaker", "byTheLee", "grooveWindAverageSeconds"])
    func aMissingSchemaThreeFieldIsRefused(key: String) throws {
        var edits = [(of: "\"\(key)\":", with: "\"renamed\":")]
        if key != "grooveWindAverageSeconds" { edits.append((of: "\"/\(key)\"", with: "\"/renamed\"")) }
        let data = try SkiffFixtures.edited(edits)
        #expect {
            try BoatClassFile(data: data)
        } throws: { error in
            if case .malformed(kind: "boat class", reason: let reason) = error as? DataFileError { return reason.contains(key) }
            return false
        }
    }

    @Test(arguments: [
        (#""offSpeedKnots": 6,"#, #""offSpeedKnots": 9,"#, "planing speeds"),
        (#""offBelowTWADegrees": 55,"#, #""offBelowTWADegrees": 70,"#, "planing angles"),
        (#""dropBelowTWADegrees": 105,"#, #""dropBelowTWADegrees": 120,"#, "spinnaker angles"),
        (#""transitionSeconds": 4,"#, #""transitionSeconds": 9,"#, "spinnaker transition"),
        (#""speedFactor": 0.65,"#, #""speedFactor": 1.5,"#, "two-sail speed factor"),
        (#""grooveWindAverageSeconds": 30"#, #""grooveWindAverageSeconds": -1"#, "groove wind average"),
        (#""spinnakerCollapseDegrees": 10"#, #""spinnakerCollapseDegrees": 100"#, "spinnaker collapse"),
    ])
    func schemaThreeValuesAreChecked(of: String, with: String, reason expected: String) throws {
        let data = try SkiffFixtures.edited([(of: of, with: with)])
        #expect {
            try BoatClassFile(data: data)
        } throws: { error in
            if case .invalidContent(kind: "boat class", id: "skiff", reason: let reason) = error as? DataFileError {
                return reason.contains(expected)
            }
            return false
        }
    }

    /// Schema 2's content headed as schema 3 lacks the additions: refused, never sailed with made-up values.
    @Test func schemaTwoContentHeadedThreeIsRefused() throws {
        let data = try Fixtures.edited([(of: #""schemaVersion": 2,"#, with: #""schemaVersion": 3,"#)])
        #expect(throws: (any Error).self) { try BoatClassFile(data: data) }
    }
}
