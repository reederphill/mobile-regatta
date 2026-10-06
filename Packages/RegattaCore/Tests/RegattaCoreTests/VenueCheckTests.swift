import Foundation
import Testing
@testable import RegattaCore

/// The three real venues (#83) and edited copies of their bytes.
enum RealVenues {
    static let ids = ["hollin-bay", "saltings-reach", "fellmere"]

    static func file(_ id: String) throws -> VenueFile { try VenueFile.bundled(id: id, version: 1) }

    /// Venue `id`@1 as `fixture-venue@1`, its file edited by `edit`. Decoded into the schema's own types rather than
    /// `JSONSerialization` casts, which bridge numbers differently on Linux (#316).
    static func edited(_ id: String, _ edit: (inout VenueSchema2) throws -> Void) throws -> Venue {
        let bytes = try #require(try VenueFile.bundledData(id: id, version: 1))
        var file = try JSONDecoder().decode(VenueSchema2.self, from: bytes)
        file.id = "fixture-venue"
        file.version = 1
        try edit(&file)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try VenueFile(data: encoder.encode(file)).content
    }

    /// A closed ring of a `side`-metre square centred on `centre`.
    static func square(_ centre: Vec2, side: Double) -> VenueSchema1.Land {
        let h = side / 2
        let corners = [Vec2(-h, -h), Vec2(h, -h), Vec2(h, h), Vec2(-h, h), Vec2(-h, -h)].map { centre + $0 }
        return VenueSchema1.Land(outlineMetres: corners.map { [$0.x, $0.y] })
    }
}

@Suite struct VenueCheckTests {
    // MARK: Acceptance

    /// #83: every real venue × conditions pairing (all 6) passes the offline check: the longest beat's race area at
    /// every rotation clear of land, land clear of the line and marks, the grids covering the area, and the estuary's
    /// deepest water and shallows inside it.
    @Test func everyPairingPassesTheCheck() throws {
        var pairings = 0
        for id in RealVenues.ids {
            let venue = try RealVenues.file(id).content
            pairings += venue.pairings.count
            let findings = VenueCheck.check(venue)
            #expect(findings.isEmpty, "\(id): \(findings.map(\.description))")
        }
        #expect(pairings == 6)
    }

    /// #83: land inside the race area fails the check.
    @Test func landInsideRaceAreaFails() throws {
        let venue = try RealVenues.edited("hollin-bay") { json in
            // Halfway up the classic-oscillating beat (from 240°), square on the course.
            json.land.append(RealVenues.square(Vec2.heading(deg2rad(240)) * 180, side: 40))
        }
        let findings = VenueCheck.check(venue)
        let classic = findings.filter { $0.pairing.id == "classic-oscillating" }
        #expect(classic.contains { $0.reason == "land 1 reaches into the race area" })
        #expect(classic.count >= VenueCheck.rotations.count, "found at every rotation")
    }

    /// #316: a landmark (#115 draws them) out on the water, in the race area, fails the check: landmarks stand on or
    /// beside the shore, outside the race area.
    @Test func landmarkOnWaterOrInRaceAreaFails() throws {
        let venue = try RealVenues.edited("hollin-bay") { json in
            // The clubhouse moved onto the classic-oscillating start line's centre, out on the water.
            json.landmarks[0].positionMetres = json.pairings[0].startLineCentreMetres
        }
        let findings = VenueCheck.check(venue)
        let asset = venue.landmarks[0].asset
        for pairing in venue.pairings {
            let mine = findings.filter { $0.pairing == pairing.conditions }
            #expect(mine.filter { $0.reason == "landmark 0 (\(asset)) is in the race area" }.count == VenueCheck.rotations.count,
                    "found at every rotation: \(mine)")
            #expect(mine.contains { $0.reason.hasPrefix("landmark 0 (\(asset)) is ") && $0.reason.hasSuffix(" m from land") })
        }
        #expect(!findings.contains { $0.reason.hasPrefix("landmark 1") || $0.reason.hasPrefix("landmark 2") })
    }

    // MARK: More fixtures

    @Test func landNearAMarkFails() throws {
        let setup = try RealVenues.edited("hollin-bay") { _ in }
        let pairing = setup.pairings[0]
        let conditions = try ConditionsFile.bundled(id: pairing.conditions.id, version: pairing.conditions.version)
        let layout = VenueCheck.layouts(venue: setup, pairing: pairing, conditions: conditions,
                                        boatClass: RaceFiles.defaults.boatClass.content,
                                        rules: RaceFiles.defaults.rulesConfiguration.content)[0].layout
        let windward = layout.elements[CourseLayout.windwardIndex].marks[0].position
        let venue = try RealVenues.edited("hollin-bay") { json in
            json.land.append(RealVenues.square(windward + layout.right * 25, side: 10))
        }
        let problems = VenueCheck.problems(venue: venue, pairing: venue.pairings[0], layout: layout)
        #expect(problems.contains { $0.hasPrefix("land 1 is ") && $0.hasSuffix(" m from the windward mark") }, "\(problems)")
    }

    @Test func deepestWaterOutsideRaceAreaFails() throws {
        let venue = try RealVenues.edited("saltings-reach") { json in
            var grid = try #require(json.current.grid)
            // The last row, 800 m up the reach, in the channel: beyond every race area.
            grid.depthMetres[grid.depthMetres.count - 1][5] = 9
            json.current.grid = grid
        }
        let findings = VenueCheck.check(venue)
        #expect(findings.contains { $0.reason == "the deepest water lies outside the race area" })
    }

    @Test func gridNotCoveringRaceAreaFails() throws {
        let venue = try RealVenues.edited("fellmere") { json in
            json.pairings[0].geographicGrid.cellSizeMetres = 50
        }
        let findings = VenueCheck.check(venue)
        #expect(findings.contains { $0.pairing.id == "light-and-patchy" && $0.reason == "the geographic grid doesn't cover the race area" })
    }

    @Test func rotationsSpanTheSeededSpread() {
        let rotations = VenueCheck.rotations
        #expect(abs(rotations.first! + WindSetup.meanDirectionSpread) < 1e-12)
        #expect(abs(rotations.last! - WindSetup.meanDirectionSpread) < 1e-12)
        #expect(rotations.count == 9)
    }
}

@Suite struct VenueSailabilityTests {
    // MARK: Acceptance

    /// #83 (#11, #14): every real venue × conditions pairing (all 6) is sailable in a 25 % lull at peak current:
    /// somewhere across the beat a close-hauled boat makes at least 1 kn up the course over the ground, and nowhere is
    /// she swept backwards.
    @Test func everyPairingIsSailable() throws {
        var results: [VenueSailability.Result] = []
        for id in RealVenues.ids {
            results += VenueSailability.check(try RealVenues.file(id).content)
        }
        #expect(results.count == 6)
        for result in results {
            #expect(result.passes, "\(result)")
        }
    }

    // MARK: More fixtures

    /// 2 kn of foul tide straight down the course, against a weak lull, sweeps a boat backwards.
    @Test func footOfTideAgainstWeakLullFails() throws {
        let venue = try RealVenues.edited("saltings-reach") { json in
            // The pairing laid down the reach, in light and patchy with the pressure taken off everywhere.
            json.pairings[0].conditionsRef = DataFileKey(id: "light-and-patchy", version: 7)
            let grid = json.pairings[0].geographicGrid
            json.pairings[0].geographicGrid.speedChange = Array(repeating: Array(repeating: -0.3, count: grid.columns),
                                                                count: grid.rows)
        }
        let result = VenueSailability.check(venue)[0]
        #expect(!result.passes)
        #expect(result.worstProgressKnots < 0)
    }

    /// #316: a pairing whose wind is too light to make 1 kn up the beat anywhere fails criterion (1) on its own: no
    /// current, so nowhere is a boat swept backwards.
    @Test func tooLightToMakeWayFailsOnItsOwn() throws {
        let venue = try RealVenues.edited("hollin-bay") { json in
            // Nineteen twentieths of the pressure taken off everywhere, in both pairings.
            for k in json.pairings.indices {
                let grid = json.pairings[k].geographicGrid
                json.pairings[k].geographicGrid.speedChange = Array(repeating: Array(repeating: -0.95, count: grid.columns),
                                                                    count: grid.rows)
            }
        }
        #expect(venue.current == nil)
        for result in VenueSailability.check(venue) {
            #expect(!result.passes, "\(result)")
            #expect(result.bestProgressKnots < VenueSailability.minimumProgressKnots, "\(result)")
            #expect(result.worstProgressKnots >= 0, "\(result)")
        }
    }

    @Test func tideStatesSweepTheWholeCycleOnce() throws {
        let states = VenueSailability.tideStates(try RealVenues.file("saltings-reach").content)
        #expect(states.count == 72)
        #expect(states.first == 0 && abs(states.last! - deg2rad(355)) < 1e-9)
        #expect(VenueSailability.tideStates(try RealVenues.file("fellmere").content) == [0])
    }
}
