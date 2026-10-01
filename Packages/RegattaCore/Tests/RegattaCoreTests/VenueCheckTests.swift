import Foundation
import Testing
@testable import RegattaCore

/// The three real venues (#83) and edited copies of their bytes.
enum RealVenues {
    static let ids = ["hollin-bay", "saltings-reach", "fellmere"]

    static func file(_ id: String) throws -> VenueFile { try VenueFile.bundled(id: id, version: 1) }

    /// Venue `id`@1 as `fixture-venue@1`, its JSON edited by `edit`.
    static func edited(_ id: String, _ edit: (inout [String: Any]) throws -> Void) throws -> Venue {
        let bytes = try #require(try VenueFile.bundledData(id: id, version: 1))
        var json = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        json["id"] = "fixture-venue"
        json["version"] = 1
        try edit(&json)
        return try VenueFile(data: JSONSerialization.data(withJSONObject: json, options: .sortedKeys)).content
    }

    /// A closed ring of a `side`-metre square centred on `centre`.
    static func square(_ centre: Vec2, side: Double) -> [String: Any] {
        let h = side / 2
        let corners = [Vec2(-h, -h), Vec2(h, -h), Vec2(h, h), Vec2(-h, h), Vec2(-h, -h)].map { centre + $0 }
        return ["outlineMetres": corners.map { [$0.x, $0.y] }]
    }

    /// Adds `ring` to the venue's land.
    static func addLand(_ ring: [String: Any], to json: inout [String: Any]) throws {
        var land = try #require(json["land"] as? [[String: Any]])
        land.append(ring)
        json["land"] = land
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
            try RealVenues.addLand(RealVenues.square(Vec2.heading(deg2rad(240)) * 180, side: 40), to: &json)
        }
        let findings = VenueCheck.check(venue)
        let classic = findings.filter { $0.pairing.id == "classic-oscillating" }
        #expect(classic.contains { $0.reason == "land 1 reaches into the race area" })
        #expect(classic.count >= VenueCheck.rotations.count, "found at every rotation")
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
            try RealVenues.addLand(RealVenues.square(windward + layout.right * 25, side: 10), to: &json)
        }
        let problems = VenueCheck.problems(venue: venue, pairing: venue.pairings[0], layout: layout)
        #expect(problems.contains { $0.hasPrefix("land 1 is ") && $0.hasSuffix(" m from the windward mark") }, "\(problems)")
    }

    @Test func deepestWaterOutsideRaceAreaFails() throws {
        let venue = try RealVenues.edited("saltings-reach") { json in
            var current = try #require(json["current"] as? [String: Any])
            var grid = try #require(current["grid"] as? [String: Any])
            var depths = try #require(grid["depthMetres"] as? [[Double]])
            // The last row, 800 m up the reach, in the channel: beyond every race area.
            depths[depths.count - 1][5] = 9
            grid["depthMetres"] = depths
            current["grid"] = grid
            json["current"] = current
        }
        let findings = VenueCheck.check(venue)
        #expect(findings.contains { $0.reason == "the deepest water lies outside the race area" })
    }

    @Test func gridNotCoveringRaceAreaFails() throws {
        let venue = try RealVenues.edited("fellmere") { json in
            var pairings = try #require(json["pairings"] as? [[String: Any]])
            var grid = try #require(pairings[0]["geographicGrid"] as? [String: Any])
            grid["cellSizeMetres"] = 50
            pairings[0]["geographicGrid"] = grid
            json["pairings"] = pairings
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
            var pairings = try #require(json["pairings"] as? [[String: Any]])
            // The pairing laid down the reach, in light and patchy with the pressure taken off everywhere.
            pairings[0]["conditionsRef"] = ["id": "light-and-patchy", "version": 7]
            var grid = try #require(pairings[0]["geographicGrid"] as? [String: Any])
            let rows = try #require(grid["rows"] as? Int), columns = try #require(grid["columns"] as? Int)
            grid["speedChange"] = Array(repeating: Array(repeating: -0.3, count: columns), count: rows)
            pairings[0]["geographicGrid"] = grid
            json["pairings"] = pairings
        }
        let result = VenueSailability.check(venue)[0]
        #expect(!result.passes)
        #expect(result.worstProgressKnots < 0)
    }

    @Test func tideStatesSweepTheWholeCycleOnce() throws {
        let states = VenueSailability.tideStates(try RealVenues.file("saltings-reach").content)
        #expect(states.count == 24)
        #expect(states.first == 0 && abs(states.last! - deg2rad(345)) < 1e-9)
        #expect(VenueSailability.tideStates(try RealVenues.file("fellmere").content) == [0])
    }
}
