import Foundation
import Testing
@testable import RegattaCore

/// The bundled v1.0 boat class and edited copies of its bytes.
enum Fixtures {
    static let classID = "ilca-dinghy"
    /// SHA-256 of `Resources/boat-classes/ilca-dinghy@1.json`. A released file never changes (ADR 0004):
    /// if this fails, ship the change as `ilca-dinghy@2.json` instead of editing version 1.
    static let pinnedHash = "8eb6e20398d859edafec53ef904227672dd5ef081d1611fcb2e89d7e9da5849d"

    static func bytes() throws -> Data {
        try #require(try BoatClassFile.bundledData(id: classID, version: 1))
    }

    static func text() throws -> String {
        String(decoding: try bytes(), as: UTF8.self)
    }

    /// The bundled file with each `(of, with)` replacement applied, each of which must match.
    static func edited(_ replacements: [(of: String, with: String)]) throws -> Data {
        var text = try text()
        for r in replacements {
            #expect(text.contains(r.of), "fixture no longer contains \(r.of)")
            text = text.replacingOccurrences(of: r.of, with: r.with)
        }
        return Data(text.utf8)
    }

    static func boatClass() throws -> BoatClass {
        try BoatClassFile.bundled(id: classID, version: 1).content
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
        let ref = try BoatClassFile.bundled(id: Fixtures.classID, version: 1).ref
        let decoded = try JSONDecoder().decode(FileRef.self, from: JSONEncoder().encode(ref))
        #expect(decoded == ref)
    }
}

@Suite struct DataFileLoaderTests {
    @Test func bundledBoatClassDecodes() throws {
        let file = try BoatClassFile.bundled(id: Fixtures.classID, version: 1)
        #expect(file.schemaVersion == 1)
        #expect(file.id == "ilca-dinghy")
        #expect(file.version == 1)
        #expect(file.ref.id == "ilca-dinghy" && file.ref.version == 1)
        #expect(file.content.name == "Dinghy")
    }

    @Test func decodesFromDataNotPaths() throws {
        let data = try Fixtures.bytes()
        let file = try BoatClassFile(data: data)
        #expect(file.ref == (try BoatClassFile.bundled(id: Fixtures.classID, version: 1)).ref)
    }

    @Test func hashOfBundledFileIsPinned() throws {
        let file = try BoatClassFile.bundled(id: Fixtures.classID, version: 1)
        #expect(file.ref.hash.hex == Fixtures.pinnedHash)
        #expect(file.ref.hash == ContentHash(of: try Fixtures.bytes()))
    }

    @Test(arguments: [0, 2, 99])
    func wrongSchemaVersionThrows(schemaVersion: Int) throws {
        let data = try Fixtures.edited([(of: #""schemaVersion": 1,"#, with: #""schemaVersion": \#(schemaVersion),"#)])
        #expect(throws: DataFileError.unsupportedSchemaVersion(kind: "boat class", found: schemaVersion, supported: [1])) {
            try BoatClassFile(data: data)
        }
    }

    @Test func missingHeaderIsMalformed() throws {
        let data = try Fixtures.edited([(of: #""schemaVersion": 1,"#, with: "")])
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
        (#""schemaVersion": 1,"#, #""schemaVersion": 1, "schemaVersion": 2,"#, "/schemaVersion"),
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
        let badVersion = try Fixtures.edited([(of: #""version": 1,"#, with: #""version": 0,"#)])
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
        for wrong in [FileRef(id: "other-boat", version: 1, hash: ref.hash), FileRef(id: ref.id, version: 2, hash: ref.hash)] {
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
        let v1 = try BoatClassFile.bundled(id: Fixtures.classID, version: 1)
        let v2 = try BoatClassFile(data: Fixtures.edited([
            (of: #""version": 1,"#, with: #""version": 2,"#),
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

        // A released version never changes: a second, different "version 2" is refused.
        let otherV2 = try BoatClassFile(data: Fixtures.edited([
            (of: #""version": 1,"#, with: #""version": 2,"#),
            (of: #""boatSpeedFactor": 0.6"#, with: #""boatSpeedFactor": 0.8"#),
        ]))
        #expect(throws: DataFileError.conflictingVersion(existing: v2.ref, new: otherV2.ref)) {
            try catalog.add(otherV2)
        }
        #expect(catalog.files.count == 2)
    }

    @Test func placeholdersResolveAndCoverTheTuningList() throws {
        let file = try BoatClassFile.bundled(id: Fixtures.classID, version: 1)
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

        #expect(c.momentum == .init(speedingUp: 4, slowingDown: 5, noGo: 3))
        #expect(c.steering.topTurnRate == deg2rad(30))
        #expect(c.steering.minTurnRate == deg2rad(10))
        #expect(c.steering.rudderSlew > 0 && c.steering.rudderDrag >= 0 && c.steering.headToWindFallOffRate > 0)

        #expect(c.windShadow.coneLength == 8 * length)
        #expect(c.windShadow.lossCloseIn == 0.25)
        #expect(c.windShadow.stackingFloor == 0.6)
        #expect(c.windShadow.coneWidthAtEnd > c.windShadow.coneWidthAtBoat)
        #expect(c.windShadow.backwindLength > 0 && c.windShadow.backwindWidth > 0)
        #expect(c.windShadow.backwindLoss > 0 && c.windShadow.backwindLoss < c.windShadow.lossCloseIn)

        #expect(c.contact == .init(boat: 0.6, mark: 0.5))
        #expect(c.ease.speedFraction > 0 && c.ease.speedFraction < 1 && c.ease.timeConstant > 0)
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

    @Test func bundledOutlineMatchesThePrototypeHull() throws {
        let hull = try Fixtures.boatClass().hull
        let boat = Boat(id: 0, name: "", isPlayer: false, colorIndex: 0, position: .zero, heading: 0, speed: 0)
        // Heading 0 is north, so the boat's frame is the world frame.
        let prototype = boat.hull()
        #expect(hull.outline.count == prototype.count)
        for (a, b) in zip(hull.outline, prototype) {
            #expect((a - b).length < 1e-9)
        }
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
