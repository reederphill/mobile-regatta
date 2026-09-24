import Foundation
import Testing
@testable import RegattaCore

/// The test venue fixture (a test resource), the bundled dev venue, and edited copies of their bytes.
enum VenueFixtures {
    static let testID = "test-venue"
    static let devID = "dev-venue"
    /// SHA-256 of `Tests/RegattaCoreTests/Resources/venues/test-venue@1.json`. A released file never
    /// changes (ADR 0004): ship `test-venue@2.json` rather than editing version 1.
    static let testPinnedHash = "a6006f51d15b369557181ce4da8744b633df8c96eb3441fbc415ae20ccc1ab5f"
    /// SHA-256 of `Resources/venues/dev-venue@1.json`.
    static let devPinnedHash = "5f114297c5191a38366f9b38a59460023e5e08dbe295f1af6f1e8ff19d8df958"

    static func testFile() throws -> VenueFile {
        try VenueFile.bundled(id: testID, version: 1, in: .module)
    }

    static func testVenue() throws -> Venue { try testFile().content }

    static func bytes() throws -> Data {
        try #require(try VenueFile.bundledData(id: testID, version: 1, in: .module))
    }

    /// The test venue with each `(of, with)` replacement applied, each of which must match.
    static func edited(_ replacements: [(of: String, with: String)]) throws -> Data {
        var text = String(decoding: try bytes(), as: UTF8.self)
        for r in replacements {
            #expect(text.contains(r.of), "fixture no longer contains \(r.of)")
            text = text.replacingOccurrences(of: r.of, with: r.with)
        }
        return Data(text.utf8)
    }

    /// Expects loading `data` to throw `invalidContent` for the test venue with a reason containing `reason`.
    static func expectInvalid(_ data: Data, _ reason: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(sourceLocation: sourceLocation) {
            try VenueFile(data: data)
        } throws: { error in
            guard case .invalidContent(kind: "venue", id: "test-venue", reason: let found) = error as? DataFileError else { return false }
            return found.contains(reason)
        }
    }

    static let land0Ring = "[[-600, -200], [-400, -200], [-400, 100], [-500, 150], [-400, 200], [-400, 600], [-600, 600], [-600, -200]]"
}

@Suite struct VenueFileTests {
    @Test func testFixtureDecodes() throws {
        let file = try VenueFixtures.testFile()
        #expect(file.schemaVersion == 1 && file.id == "test-venue" && file.version == 1)
        let venue = file.content
        #expect(venue.displayName == "Test Water")
        #expect(venue.landmarks == [
            .init(asset: "test-lighthouse", position: Vec2(-450, 300)),
            .init(asset: "test-clubhouse", position: Vec2(450, -100)),
        ])
        #expect(venue.land.count == 2)
        #expect(venue.land[0].points.count == 7) // closing point dropped
        #expect(venue.pairings.map(\.conditions) == [
            DataFileKey(id: "classic-oscillating", version: 1), DataFileKey(id: "gusty-offshore", version: 2),
        ])
        #expect(venue.hasCurrent)
    }

    @Test func bundledDevVenueDecodes() throws {
        let file = try VenueFile.bundled(id: VenueFixtures.devID, version: 1)
        let venue = file.content
        #expect(venue.displayName == "Dev Water")
        #expect(!venue.hasCurrent)
        #expect(venue.pairings.map(\.conditions.id) == ["light-and-patchy", "classic-oscillating", "sea-breeze", "gusty-offshore"])
        for pairing in venue.pairings {
            #expect(pairing.startLineCentre == .zero && pairing.meanDirection == 0)
            #expect(!venue.isLand(pairing.startLineCentre))
            #expect(pairing.geographicGrid.grid.nodeCount == 21 * 16)
        }
        #expect(venue.pairing(for: DataFileKey(id: "sea-breeze", version: 1))?.trendDirection == .veer)
        #expect(file.header.placeholders.contains("/pairings/0/geographicGrid"))
    }

    @Test func hashesArePinned() throws {
        let test = try VenueFixtures.testFile()
        #expect(test.ref.hash.hex == VenueFixtures.testPinnedHash)
        #expect(test.ref.hash == ContentHash(of: try VenueFixtures.bytes()))
        let dev = try VenueFile.bundled(id: VenueFixtures.devID, version: 1)
        #expect(dev.ref.hash.hex == VenueFixtures.devPinnedHash)
    }

    @Test(arguments: [0, 2, 99])
    func unknownSchemaVersionThrows(schemaVersion: Int) throws {
        let data = try VenueFixtures.edited([(of: #""schemaVersion": 1,"#, with: #""schemaVersion": \#(schemaVersion),"#)])
        #expect(throws: DataFileError.unsupportedSchemaVersion(kind: "venue", found: schemaVersion, supported: [1])) {
            try VenueFile(data: data)
        }
    }

    @Test func bundledInLooksOnlyInThatBundle() throws {
        // The test bundle has venues but no boat classes; the package bundle has no test venue.
        #expect(throws: DataFileError.notBundled(kind: "boat class", id: "ilca-dinghy", version: 1)) {
            try BoatClassFile.bundled(id: "ilca-dinghy", version: 1, in: .module)
        }
        #expect(throws: DataFileError.notBundled(kind: "venue", id: VenueFixtures.testID, version: 1)) {
            try VenueFile.bundled(id: VenueFixtures.testID, version: 1)
        }
        #expect(throws: DataFileError.invalidID(kind: "venue", id: "../venues/test-venue")) {
            try VenueFile.bundled(id: "../venues/test-venue", version: 1, in: .module)
        }
    }

    @Test func expectedRefIsChecked() throws {
        let data = try VenueFixtures.bytes()
        let ref = try VenueFixtures.testFile().ref
        #expect(try VenueFile(data: data, expecting: ref).ref == ref)
        #expect(ref.key == DataFileKey(id: "test-venue", version: 1))
        #expect(ref.key.description == "test-venue@1")
    }

    @Test func placeholdersResolve() throws {
        let file = try VenueFixtures.testFile()
        #expect(file.header.placeholders == ["/pairings/1/geographicGrid", "/current/eddies/0/peakKnots"])
        let data = try VenueFixtures.edited([(of: #""/current/eddies/0/peakKnots""#, with: #""/current/eddies/1/peakKnots""#)])
        #expect(throws: DataFileError.unresolvedPlaceholder(kind: "venue", id: "test-venue", pointer: "/current/eddies/1/peakKnots")) {
            try VenueFile(data: data)
        }
    }
}

@Suite struct VenueCodableTests {
    /// decode → encode → decode gives an equal file, and the re-encoded file loads to an equal venue.
    @Test(arguments: ["test", "dev"])
    func codableRoundTripIsEqual(which: String) throws {
        let data = which == "test"
            ? try VenueFixtures.bytes()
            : try #require(try VenueFile.bundledData(id: VenueFixtures.devID, version: 1))
        let decoded = try JSONDecoder().decode(VenueSchema1.self, from: data)
        let encoded = try JSONEncoder().encode(decoded)
        let again = try JSONDecoder().decode(VenueSchema1.self, from: encoded)
        #expect(again == decoded)

        let original = try VenueFile(data: data)
        let reloaded = try VenueFile(data: encoded)
        #expect(reloaded.content == original.content)
        #expect(reloaded.header == original.header)
        #expect(reloaded.ref.key == original.ref.key)
    }

    /// Every object, or array of objects, that a fully populated file has must be an object node in the
    /// strict-field tree, so a nested field added later can't silently be treated as a leaf.
    @Test func fieldTreeCoversEveryNestedObject() throws {
        var document = try JSONDecoder().decode(VenueSchema1.self, from: VenueFixtures.bytes())
        // Every optional field present (the fixture already has them all; keep it that way).
        #expect(document.placeholders != nil && document.notes != nil && document.current.eddies?.isEmpty == false)
        #expect(document.current.tideClockRate != nil && document.current.byDepth != nil && !document.landmarks.isEmpty)
        document.notes = ["n"]
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(document))

        var checked: [String] = []
        func walk(_ value: Any, _ node: FieldTree, _ path: String) {
            if let members = value as? [String: Any] {
                guard case .object(let fields) = node else {
                    Issue.record("\(path) is an object but the field tree has no object node for it")
                    return
                }
                checked.append(path)
                for (key, member) in members.sorted(by: { $0.key < $1.key }) {
                    guard let field = fields[key] else {
                        Issue.record("\(path)/\(key) is missing from the field tree")
                        continue
                    }
                    walk(member, field, path + "/" + key)
                }
            } else if let elements = value as? [Any], elements.contains(where: { $0 is [String: Any] }) {
                guard case .array(let element) = node else {
                    Issue.record("\(path) is an array of objects but the field tree has no array node for it")
                    return
                }
                for (k, member) in elements.enumerated() { walk(member, element, path + "/\(k)") }
            }
        }
        walk(json, VenueSchema1.fields, "")
        for path in ["", "/landmarks/0", "/land/0", "/pairings/0", "/pairings/0/conditionsRef", "/pairings/0/geographicGrid",
                     "/current", "/current/allowedTideStatesAtGun", "/current/grid", "/current/byDepth", "/current/eddies/0"] {
            #expect(checked.contains(path), "\(path) wasn't checked")
        }
    }

    @Test func encodingKeepsOptionalFieldsOut() throws {
        let data = try #require(try VenueFile.bundledData(id: VenueFixtures.devID, version: 1))
        let decoded = try JSONDecoder().decode(VenueSchema1.self, from: data)
        let current = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded.current)) as? [String: Any]
        #expect(current?.keys.sorted() == ["hasCurrent"])
    }
}

@Suite struct VenueContentTests {
    @Test func pairingsAreConvertedToCodeUnits() throws {
        let venue = try VenueFixtures.testVenue()
        let p0 = venue.pairings[0]
        #expect(p0.meanDirection == deg2rad(10))
        #expect(p0.trendDirection == .either)
        #expect(p0.startLineCentre == Vec2(0, 0))
        let g0 = p0.geographicGrid
        #expect(g0.grid.origin == Vec2(-500, -300) && g0.grid.cellSize == 250 && g0.grid.orientation == 0)
        #expect(g0.grid.columns == 5 && g0.grid.rows == 5)
        // Row 0 passes through the origin; columns run east when the grid isn't rotated.
        #expect(g0.directionDelta(column: 0, row: 0) == deg2rad(4))
        #expect(g0.directionDelta(column: 3, row: 1) == deg2rad(-1.5))
        #expect(g0.speedFactor(column: 2, row: 3) == 1.1)
        #expect(g0.grid.position(column: 4, row: 4) == Vec2(500, 700))

        let p1 = venue.pairings[1]
        #expect(p1.meanDirection == deg2rad(270))
        #expect(p1.trendDirection == .veer)
        let g1 = p1.geographicGrid.grid
        #expect(g1.orientation == deg2rad(30))
        #expect(g1.rowAxis == Vec2.heading(deg2rad(30)))
        let east = g1.position(column: 1, row: 0) - g1.origin
        let north = g1.position(column: 0, row: 1) - g1.origin
        #expect(abs(east.bearing - deg2rad(120)) < 1e-12 && abs(east.length - 300) < 1e-9)
        #expect(abs(north.bearing - deg2rad(30)) < 1e-12 && abs(north.length - 300) < 1e-9)
        #expect(p1.geographicGrid.speedFactor(column: 1, row: 1) == 0.85)
        #expect(venue.pairing(for: DataFileKey(id: "gusty-offshore", version: 2)) == p1)
        #expect(venue.pairing(for: DataFileKey(id: "classic-oscillating", version: 1)) == p0)
        // The pairing is pinned to its conditions version: any other version has no pairing.
        #expect(venue.pairing(for: DataFileKey(id: "gusty-offshore", version: 1)) == nil)
        #expect(venue.pairing(for: DataFileKey(id: "classic-oscillating", version: 2)) == nil)
        #expect(venue.pairing(for: DataFileKey(id: "sea-breeze", version: 1)) == nil)
        // As #81 will look it up, from the conditions FileRef in the race setup.
        let ref = FileRef(id: "gusty-offshore", version: 2, hash: ContentHash(of: Data()))
        #expect(venue.pairing(for: ref.key) == p1)
    }

    @Test func landIsConcaveAndWoundAnticlockwise() throws {
        let venue = try VenueFixtures.testVenue()
        for polygon in venue.land {
            #expect(VenueSchema1.signedArea(polygon.points) > 0)
        }
        // Land 1 was written clockwise: turned round.
        #expect(venue.land[1].points == [Vec2(600, -200), Vec2(600, 600), Vec2(400, 600), Vec2(400, -200)])
        // The notch in land 0 is water.
        #expect(venue.isLand(Vec2(-500, 0)))
        #expect(!venue.isLand(Vec2(-420, 150)))
        #expect(venue.isLand(Vec2(-550, 150)))
        #expect(venue.isLand(Vec2(500, 0)))
        #expect(!venue.isLand(Vec2(0, 0)))
    }

    @Test func currentIsConvertedToCodeUnits() throws {
        let current = try #require(try VenueFixtures.testVenue().current)
        #expect(current.peak == metresPerSecond(knots: 1.5))
        #expect(current.isTidal && current.tideClockRate == 19)
        #expect(current.allowedTideStatesAtGun == .init(from: deg2rad(330), to: deg2rad(30)))
        #expect(current.grid.columns == 5 && current.grid.rows == 6 && current.depths.count == 30)
        #expect(current.maxDepth == 8)
        #expect(current.depth(column: 2, row: 0) == 8 && current.depth(column: 0, row: 3) == 0)
        #expect(current.floodDirection(column: 3, row: 0) == deg2rad(355))
        #expect(current.strengthExponent == 0.6667)
        #expect(current.shallowsLead == deg2rad(20))
        #expect(current.eddies == [.init(
            floodCentre: Vec2(300, 400), ebbCentre: Vec2(300, 0), coreRadius: 40, outerRadius: 150,
            peak: metresPerSecond(knots: 0.45), floodRotation: .clockwise)])
        #expect(current.eddies[0].ebbRotation == .anticlockwise)
    }

    @Test func strengthAndLeadFollowDepth() throws {
        let current = try #require(try VenueFixtures.testVenue().current)
        #expect(current.relativeStrength(depth: 0) == 0)
        #expect(current.relativeStrength(depth: 8) == 1)
        #expect(current.relativeStrength(depth: 20) == 1)
        #expect(abs(current.relativeStrength(depth: 1) - pow(1.0 / 8, 0.6667)) < 1e-12)
        var previous = 0.0
        for depth in stride(from: 0.5, through: 8, by: 0.5) {
            let s = current.relativeStrength(depth: depth)
            #expect(s > previous)
            previous = s
        }
        #expect(current.phaseLead(depth: 0) == deg2rad(20))
        #expect(current.phaseLead(depth: 8) == 0)
        #expect(abs(current.phaseLead(depth: 4) - deg2rad(10)) < 1e-12)
    }

    @Test func tidalCycleIsTheM2Period() {
        // 360° / 28.9841042° per hour = 12.4206012 h.
        #expect(abs(Venue.Current.tidalCycle - 44_714.164_394) < 1e-5)
    }

    @Test func tidalClockTakesAboutTenMinutesFromSlackToPeak() throws {
        let current = try #require(try VenueFixtures.testVenue().current)
        let slackToPeak = Venue.Current.tidalCycle / 4 / current.tideClockRate
        #expect(abs(slackToPeak - 600) <= 30)
    }

    @Test func tideStateRangeWrapsThroughZero() {
        let range = Venue.TideStateRange(from: deg2rad(330), to: deg2rad(30))
        #expect(abs(range.width - deg2rad(60)) < 1e-12)
        for degrees: Double in [330, 345, 0, 15, 30, 370, -20] {
            #expect(range.contains(deg2rad(degrees)), "\(degrees)°")
        }
        for degrees: Double in [31, 90, 180, 329] {
            #expect(!range.contains(deg2rad(degrees)), "\(degrees)°")
        }
        let single = Venue.TideStateRange(from: deg2rad(90), to: deg2rad(90))
        #expect(single.width == 0 && single.contains(deg2rad(90)) && !single.contains(deg2rad(91)))
        #expect(!range.isWholeCycle && !single.isWholeCycle)
    }

    @Test func wholeTideCycleIsZeroTo360() throws {
        let data = try VenueFixtures.edited([(of: #""fromDegrees": 330, "toDegrees": 30"#, with: #""fromDegrees": 0, "toDegrees": 360"#)])
        let range = try #require(try VenueFile(data: data).content.current).allowedTideStatesAtGun
        #expect(range == .init(from: 0, to: 2 * .pi))
        #expect(range.isWholeCycle && range.width == 2 * .pi)
        for degrees in stride(from: -360.0, through: 720, by: 7.5) {
            #expect(range.contains(deg2rad(degrees)), "\(degrees)°")
        }
        // 360 means the whole cycle only from 0.
        let partial = try VenueFixtures.edited([(of: #""fromDegrees": 330, "toDegrees": 30"#, with: #""fromDegrees": 10, "toDegrees": 360"#)])
        VenueFixtures.expectInvalid(partial, "toDegrees (or 0 to 360 for the whole cycle) must be in [0, 360)")
    }

    @Test func eddySpeedIsRankineTaperedToZeroAtTheOuterRadius() throws {
        let eddy = try #require(try VenueFixtures.testVenue().current?.eddies.first)
        #expect(eddy.coreRadius == 40 && eddy.outerRadius == 150)
        #expect(eddy.relativeSpeed(atDistance: 0) == 0)
        #expect(eddy.relativeSpeed(atDistance: 20) == 0.5)
        #expect(eddy.relativeSpeed(atDistance: 40) == 1)
        #expect(eddy.relativeSpeed(atDistance: 150) == 0)
        #expect(eddy.relativeSpeed(atDistance: 1000) == 0)
        // Rankine 1/r outside the core, times a linear taper.
        #expect(abs(eddy.relativeSpeed(atDistance: 80) - 40.0 / 80 * 70 / 110) < 1e-12)
        // Continuous: no jump anywhere, in particular at the core and outer radii.
        var previous = 0.0
        for tenth in 0...2000 {
            let s = eddy.relativeSpeed(atDistance: Double(tenth) / 10)
            #expect(s >= 0 && s <= 1 && abs(s - previous) < 0.01)
            previous = s
        }
    }
}

@Suite struct VenueValidationTests {
    @Test func openPolygonIsRejected() throws {
        let open = "[[-600, -200], [-400, -200], [-400, 100], [-500, 150], [-400, 200], [-400, 600], [-600, 600]]"
        VenueFixtures.expectInvalid(try VenueFixtures.edited([(of: VenueFixtures.land0Ring, with: open)]), "land 0 is not closed")
    }

    @Test(arguments: [
        // A bow tie: edges 0 and 2 cross.
        ("[[-600, -200], [-400, 600], [-400, -200], [-600, 600], [-600, -200]]", "self-intersecting"),
        // A figure of eight that touches itself at one corner.
        ("[[-600, -200], [-500, 0], [-400, -200], [-400, 200], [-500, 0], [-600, 200], [-600, -200]]", "self-intersecting"),
        // A corner on another edge.
        ("[[-600, -200], [-400, -200], [-400, 600], [-600, 600], [-600, 400], [-400, 300], [-600, 200], [-600, -200]]", "self-intersecting"),
        // A spike that doubles back along its own edge.
        ("[[-600, -200], [-400, -200], [-400, 600], [-400, 300], [-600, 600], [-600, -200]]", "doubles back"),
        // A repeated corner.
        ("[[-600, -200], [-400, -200], [-400, -200], [-400, 600], [-600, -200]]", "repeats corner"),
        // Two corners, closed.
        ("[[-600, -200], [-400, -200], [-600, -200]]", "not closed"),
        // All on a line.
        ("[[-600, -200], [-500, -200], [-400, -200], [-600, -200]]", "doubles back"),
        // Not points.
        ("[[-600, -200], [-400], [-400, 600], [-600, -200]]", "finite [x, y]"),
    ])
    func badPolygonIsRejected(ring: String, reason: String) throws {
        VenueFixtures.expectInvalid(try VenueFixtures.edited([(of: VenueFixtures.land0Ring, with: ring)]), reason)
    }

    @Test func mismatchedGeographicGridIsRejected() throws {
        // A row one value short.
        let shortRow = try VenueFixtures.edited([(of: "[3, 1.5, 0, -1.5, -3]", with: "[3, 1.5, 0, -1.5]")])
        VenueFixtures.expectInvalid(shortRow, "directionDeltaDegrees row 1 has 4 values, expected 5")
        // Declared dimensions that don't match the values.
        let wrongRows = try VenueFixtures.edited([(of: #""columns": 3,"#, with: #""columns": 4,"#)])
        VenueFixtures.expectInvalid(wrongRows, "directionDeltaDegrees row 0 has 3 values, expected 4")
        let missingRow = try VenueFixtures.edited([(of: "[0.9, 0.95, 1],\n", with: "")])
        VenueFixtures.expectInvalid(missingRow, "speedFactor has 3 rows, expected 4")
        let tooSmall = try VenueFixtures.edited([
            (of: #""rows": 4,"#, with: #""rows": 1,"#),
            (of: "[\n          [-6, 0, 6],\n          [-4, 0, 4],\n          [-2, 0, 2],\n", with: "[\n"),
            (of: "[\n          [0.7, 0.75, 0.8],\n          [0.8, 0.85, 0.9],\n          [0.9, 0.95, 1],\n", with: "[\n"),
        ])
        VenueFixtures.expectInvalid(tooSmall, "at least 2 columns and 2 rows")
    }

    @Test func mismatchedCurrentGridIsRejected() throws {
        let shortRow = try VenueFixtures.edited([(of: "[0, 3, 7, 4, 0]", with: "[0, 3, 7, 4]")])
        VenueFixtures.expectInvalid(shortRow, "current grid depthMetres row 3 has 4 values, expected 5")
        let wrongRows = try VenueFixtures.edited([(of: #""rows": 6,"#, with: #""rows": 5,"#)])
        VenueFixtures.expectInvalid(wrongRows, "current grid depthMetres has 6 rows, expected 5")
        let flood = try VenueFixtures.edited([(of: "[0, 350, 0, 10, 0]", with: "[0, 350, 0, 10]")])
        VenueFixtures.expectInvalid(flood, "floodDirectionDegrees row 5 has 4 values, expected 5")
    }

    @Test(arguments: [
        (#""cellSizeMetres": 250,"#, #""cellSizeMetres": 0,"#, "cellSizeMetres must be positive"),
        (#""orientationDegrees": 30,"#, #""orientationDegrees": 360,"#, "orientationDegrees must be in [0, 360)"),
        (#""meanDirectionDegrees": 270,"#, #""meanDirectionDegrees": -90,"#, "meanDirectionDegrees must be in [0, 360)"),
        ("[0.7, 0.75, 0.8]", "[0, 0.75, 0.8]", "speedFactor must be positive"),
        ("[-6, 0, 6]", "[-180, 0, 6]", "directionDeltaDegrees must be in (-180, 180)"),
        (#""originMetres": [-300, -300]"#, #""originMetres": [-300]"#, "originMetres must be a finite [x, y] point"),
        (#""startLineCentreMetres": [0, 50]"#, #""startLineCentreMetres": [-500, 0]"#, "startLineCentreMetres is on land"),
        (#""id": "gusty-offshore", "version": 2"#, #""id": "classic-oscillating", "version": 2"#, "one pairing per conditions"),
        (#""id": "gusty-offshore", "version": 2"#, #""id": "Gusty Offshore", "version": 2"#, "conditionsRef needs a valid id"),
        (#""id": "gusty-offshore", "version": 2"#, #""id": "gusty-offshore", "version": 0"#, "conditionsRef needs a valid id"),
        (#""asset": "test-clubhouse""#, #""asset": """#, "landmark 1 has an empty asset name"),
        (#""displayName": "Test Water""#, #""displayName": """#, "displayName is empty"),
    ])
    func badVenueValuesAreRejected(of: String, with: String, reason: String) throws {
        VenueFixtures.expectInvalid(try VenueFixtures.edited([(of: of, with: with)]), reason)
    }

    @Test(arguments: [
        (#""peakKnots": 1.5,"#, #""peakKnots": 2.5,"#, "peakKnots must be 0.5–2 kn"),
        (#""peakKnots": 1.5,"#, #""peakKnots": 0.4,"#, "peakKnots must be 0.5–2 kn"),
        (#""tideClockRate": 19,"#, "", "a tidal venue needs tideClockRate"),
        (#""tideClockRate": 19,"#, #""tideClockRate": 1,"#, "tideClockRate must be above 1"),
        (#""tidal": true,"#, #""tidal": false,"#, "tideClockRate is only for tidal venues"),
        (#""fromDegrees": 330"#, #""fromDegrees": 400"#, "fromDegrees must be in [0, 360)"),
        ("[0, 2, 8, 3, 0]", "[0, 2, 8, -3, 0]", "depthMetres must not be negative"),
        ("[0, 350, 0, 10, 0]", "[0, 350, 0, 360, 0]", "floodDirectionDegrees must be in [0, 360)"),
        (#""strengthExponent": 0.6667"#, #""strengthExponent": 0"#, "strengthExponent must be positive"),
        (#""shallowsLeadDegrees": 20"#, #""shallowsLeadDegrees": 90"#, "shallowsLeadDegrees must be in [0, 90)"),
        (#""peakKnots": 0.45"#, #""peakKnots": 1.6"#, "at most the venue's peakKnots"),
        (#""outerRadiusMetres": 150"#, #""outerRadiusMetres": 40"#, "larger than coreRadiusMetres"),
        (#""coreRadiusMetres": 40"#, #""coreRadiusMetres": -1"#, "coreRadiusMetres must be positive"),
        (#""hasCurrent": true,"#, #""hasCurrent": false,"#, "a venue with no current has no other current fields"),
        (#""peakKnots": 1.5,"#, "", "hasCurrent needs peakKnots"),
    ])
    func badCurrentIsRejected(of: String, with: String, reason: String) throws {
        VenueFixtures.expectInvalid(try VenueFixtures.edited([(of: of, with: with)]), reason)
    }

    @Test func allDryCurrentGridIsRejected() throws {
        var replacements: [(of: String, with: String)] = []
        for row in ["[0, 2, 8, 3, 0]", "[0, 3, 8, 3, 0]", "[0, 3, 8, 4, 0]", "[0, 3, 7, 4, 0]", "[0, 2, 6, 3, 0]", "[0, 1, 5, 2, 0]"] {
            replacements.append((of: row, with: "[0, 0, 0, 0, 0]"))
        }
        VenueFixtures.expectInvalid(try VenueFixtures.edited(replacements), "needs some water deeper than 0 m")
    }

    @Test(arguments: [
        // A typo at the top level, in a pairing's grid, in the current and in an eddy.
        (#""displayName": "Test Water","#, #""displayName": "Test Water", "displayname": "Typo","#, "/displayname"),
        (#""cellSizeMetres": 300,"#, #""cellSizeMetres": 300, "cellSize": 300,"#, "/pairings/1/geographicGrid/cellSize"),
        (#""eddies": ["#, #""eddys": [], "eddies": ["#, "/current/eddys"),
        (#""floodRotation": "clockwise""#, #""floodRotation": "clockwise", "ebbRotation": "clockwise""#, "/current/eddies/0/ebbRotation"),
        (#""conditionsRef": { "id": "classic-oscillating", "version": 1 }"#,
         #""conditionsRef": { "id": "classic-oscillating", "version": 1, "hash": "" }"#, "/pairings/0/conditionsRef/hash"),
        // Null is not the same as leaving a field out.
        (#""notes": ["#, #""notes": null, "oldNotes": ["#, "/notes"),
    ])
    func unknownFieldIsMalformed(of: String, with: String, pointer: String) throws {
        let data = try VenueFixtures.edited([(of: of, with: with)])
        #expect(throws: DataFileError.malformed(
            kind: "venue", reason: "unknown or null field \(pointer): a venue file has only its schema's fields")) {
            try VenueFile(data: data)
        }
    }

    @Test(arguments: [
        // Top level, and nested in the current, in an eddy and in a pairing's conditionsRef.
        (#""displayName": "Test Water","#, #""displayName": "Test Water", "displayName": "Other","#, "/displayName"),
        (#""tidal": true,"#, #""tidal": true, "tidal": false,"#, "/current/tidal"),
        (#""floodRotation": "clockwise""#, #""floodRotation": "anticlockwise", "floodRotation": "clockwise""#,
         "/current/eddies/0/floodRotation"),
        (#""id": "gusty-offshore", "version": 2"#, #""id": "gusty-offshore", "version": 2, "version": 3"#,
         "/pairings/1/conditionsRef/version"),
        // A typo copy first and a clean copy last: each parser would read a different one.
        (#""eddies": ["#, #""eddies": [{ "typo": 1 }], "eddies": ["#, "/current/eddies"),
        // The same key spelled with an escape.
        (#""displayName": "Test Water","#, #""displayName": "Test Water", "display\u004eame": "Other","#, "/displayName"),
    ])
    func duplicateFieldIsMalformed(of: String, with: String, pointer: String) throws {
        let data = try VenueFixtures.edited([(of: of, with: with)])
        #expect(throws: DataFileError.malformed(kind: "venue", reason: "duplicate field \(pointer)")) {
            try VenueFile(data: data)
        }
    }

    @Test func duplicateKeyScanFollowsPointersAndIgnoresStrings() {
        func first(_ json: String) -> String? { JSONDuplicateKeys.first(in: Data(json.utf8)) }
        #expect(first(#"{"a": 1, "b": {"c": [1, 2]}, "s": "{\"a\": 1, \"a\": 2}", "t": "\\"}"#) == nil)
        #expect(first(#"{"a": [{"x": 1}, {"x": 1, "y": {"z": 1, "z": 2}}]}"#) == "/a/1/y/z")
        #expect(first(#"{"a/b": {"~": 1, "~": 2}}"#) == "/a~1b/~0")
        #expect(first(#"[{"k": 1}, {"k": 2}]"#) == nil)
        #expect(first(#"{"k": "x", "v": "k", "k": 2}"#) == "/k")
    }

    @Test func boatClassesStillIgnoreUnknownFields() throws {
        let data = try Fixtures.edited([(of: #""name": "Dinghy","#, with: #""name": "Dinghy", "nmae": "typo","#)])
        #expect(try BoatClassFile(data: data).content.name == "Dinghy")
    }

    @Test func unknownTrendDirectionIsMalformed() throws {
        let data = try VenueFixtures.edited([(of: #""trendDirection": "veer""#, with: #""trendDirection": "left""#)])
        #expect {
            try VenueFile(data: data)
        } throws: { error in
            if case .malformed(kind: "venue", reason: _) = error as? DataFileError { return true }
            return false
        }
    }

    @Test func noPairingsIsRejected() throws {
        let decoded = try JSONDecoder().decode(VenueSchema1.self, from: VenueFixtures.bytes())
        var empty = decoded
        empty.pairings = []
        empty.placeholders = nil
        VenueFixtures.expectInvalid(try JSONEncoder().encode(empty), "at least one pairing")
    }
}
