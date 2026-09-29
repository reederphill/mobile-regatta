import Foundation
import Testing
@testable import RegattaCore

/// Venue geography's fixtures (#287): dev-venue@5 (venue schema 2) on the version-5 (schema 4) conditions.
enum GeographyFixtures {
    static let w = WindFixtures.windows

    /// The version-5 conditions files' SHA-256, pinned like every released file (ADR 0004).
    static let version5Hashes: [(id: String, hash: String)] = [
        ("classic-oscillating", "bb0f06e96d1a5a1249f59db219c5b832b85d1e48c92eb8d93eafe9e0741ba0b9"),
        ("gusty-offshore", "1571a4b84d37acfd9eab76942945347f8a1cae2a6fcea920f24e757cca863256"),
        ("light-and-patchy", "9a76c066f919108956001c34e16959ad579b5314443a999ec70b258245a5214f"),
        ("sea-breeze", "8aeb6262f528062ab823b2572cabea61ec973e77658f3fb03e9c4e995a15ba53"),
    ]

    static func devVenue(_ version: Int = 5) throws -> Venue {
        try VenueFile.bundled(id: VenueFixtures.devID, version: version).content
    }

    /// `id`'s pairing at dev-venue@`version`, which pairs the conditions at the same version.
    static func devPairing(_ id: String = "classic-oscillating", version: Int = 5) throws -> Venue.Pairing {
        try #require(try devVenue(version).pairing(for: DataFileKey(id: id, version: version)))
    }

    /// `id`@`version`'s setup with a race area, on `pairing` (by default dev-venue@`version`'s).
    static func setup(_ id: String = "classic-oscillating", version: Int = 5, raceSeed: UInt64 = 1,
                      pairing: Venue.Pairing? = nil) throws -> WindSetup {
        PuffFixtures.withRaceArea(try WindFixtures.setup(id, version: version, raceSeed: raceSeed,
                                                         pairing: pairing ?? devPairing(id, version: version)))
    }

    /// `pairing` with its geography's grids replaced: the same bend (so the same across-the-wind coordinate).
    static func pairing(_ pairing: Venue.Pairing, speedFactors: [Double]? = nil, lanePreferences: [Double]? = nil,
                        sideTendency: Double? = nil) -> Venue.Pairing {
        let g = pairing.geographicGrid
        return Venue.Pairing(
            conditions: pairing.conditions, meanDirection: pairing.meanDirection, trendDirection: pairing.trendDirection,
            startLineCentre: pairing.startLineCentre,
            geographicGrid: Venue.GeographicGrid(grid: g.grid, directionDeltas: g.directionDeltas,
                                                 speedFactors: speedFactors ?? g.speedFactors,
                                                 lanePreferences: lanePreferences ?? g.lanePreferences),
            sideTendency: sideTendency ?? pairing.sideTendency)
    }

    /// The pressure side's slope averaged over the race's windows (the start through window 33, past the time
    /// limit), for wind seed `seed`: which side has more pressure over the race.
    static func meanSide(_ setup: WindSetup, seed: UInt64) throws -> Double {
        let (field, _) = try WindFixtures.field(setup, windSeed: seed, through: 34)
        let plan = try #require(field.pressurePlan)
        var total = 0.0, count = 0
        for tick in stride(from: w.start(of: 2), to: w.start(of: 34), by: WindWindows.ticksPerWindow / 3) {
            total += try field.pressureState(atTick: tick, plan).side
            count += 1
        }
        return total / Double(count)
    }
}

/// Venue geography (#287, ADR 0008): a signed speed change, lane spots and a side tendency per pairing, in venue
/// schema 2, steering #286's pressure field.
@Suite struct VenueGeographyTests {
    static let w = GeographyFixtures.w

    /// A new-schema file's signed speed change reaches the ground wind, both faster and slower than the course
    /// average: the wind at a point is its twin's with no speed change (the same keys, bend and pressure field)
    /// times `1 + speedChange` there, above 1 off the west headland and below it under the east shore.
    @Test func signedSpeedChange() throws {
        let file = try VenueFile.bundled(id: VenueFixtures.devID, version: 5)
        #expect(file.schemaVersion == 2)
        let pairing = try GeographyFixtures.devPairing()
        let geo = pairing.geographicGrid
        // Node (7, 5) is (-300, 0), off the headland; node (18, 5) is (800, 0), under the east shore.
        #expect(abs(geo.speedChange(column: 7, row: 5) - 0.11) < 1e-12)
        #expect(abs(geo.speedChange(column: 18, row: 5) + 0.19) < 1e-12)

        let setup = try GeographyFixtures.setup(pairing: pairing)
        let flat = try GeographyFixtures.setup(pairing: GeographyFixtures.pairing(
            pairing, speedFactors: Array(repeating: 1, count: geo.grid.nodeCount)))
        let (field, _) = try WindFixtures.field(setup, windSeed: 7, through: 30)
        let twin = WindField(setup: flat, windows: Self.w, keys: field.keys)
        var faster = 0, slower = 0
        for tick in stride(from: Self.w.start(of: 3), to: Self.w.start(of: 30), by: 311) {
            let average = try field.courseAverageSpeed(atTick: tick)
            let sampler = try field.sampler(atTick: tick)
            for x in stride(from: -700.0, through: 700, by: 50) {
                for y in stride(from: -400.0, through: 900, by: 130) {
                    let p = Vec2(x, y)
                    let change = geo.sample(p).speedFactor - 1
                    let wind = try field.sample(p, tick: tick), plain = try twin.sample(p, tick: tick)
                    #expect(abs(wind.speed - plain.speed * (1 + change)) < 1e-9 * plain.speed, "\(p) at \(tick)")
                    #expect(wind.direction == plain.direction)
                    #expect(sampler.sample(p) == wind)
                    // Against the course average, away from the pressure field and the puffs: the speed change alone.
                    let alone = average * (1 + change)
                    if change > 0.05 { faster += 1; #expect(alone > average) }
                    if change < -0.05 { slower += 1; #expect(alone < average) }
                }
            }
        }
        #expect(faster > 0 && slower > 0)
    }

    /// Over many races, lanes form at the venue's preferred spots much more often than elsewhere (per metre across
    /// the course), and sometimes elsewhere; at the same venue without spots they form evenly across it.
    @Test func lanesPreferTheirSpots() throws {
        let pairing = try GeographyFixtures.devPairing()
        let noSpots = GeographyFixtures.pairing(
            pairing, lanePreferences: Array(repeating: 0, count: pairing.geographicGrid.grid.nodeCount))
        func shares(_ pairing: Venue.Pairing) throws -> (atSpot: Double, expected: Double, lanes: Int) {
            var atSpot = 0, lanes = 0, expected = 0.0
            let seeds = UInt64(1)...80
            for seed in seeds {
                let setup = try GeographyFixtures.setup(raceSeed: seed, pairing: pairing)
                let plan = try #require(WindField(setup: setup, windows: Self.w).pressurePlan)
                // The spot: the band off the headland, x −400…−200 m on the start line's latitude.
                let spot = [-400.0, -200].map { plan.coordinate(at: Vec2($0, 0)) }
                // Within the lanes' reach across the course, which a light-air race area's narrow width may cut.
                let reach = plan.halfWidth + plan.laneMargin
                let band = max(-reach, min(spot[0], spot[1]))...min(reach, max(spot[0], spot[1]))
                var generator = try WindFixtures.generator(setup, windSeed: seed)
                for key in generator.keys(through: 33) {
                    for lane in plan.draws(of: key, windows: Self.w).lanes {
                        lanes += 1
                        if band.contains(lane.start) { atSpot += 1 }
                    }
                }
                expected += (band.upperBound - band.lowerBound) / (2 * reach)
            }
            return (Double(atSpot) / Double(lanes), expected / Double(seeds.count), lanes)
        }
        let spots = try shares(pairing), even = try shares(noSpots)
        #expect(spots.lanes > 1000 && even.lanes == spots.lanes)
        // Much more often than elsewhere, per metre across: lanes are over three times as dense at the spot as
        // anywhere else; and sometimes elsewhere.
        let density = (spots.atSpot / spots.expected) / ((1 - spots.atSpot) / (1 - spots.expected))
        #expect(density > 3, "\(spots): \(density)")
        #expect(spots.atSpot > 0.4 && spots.atSpot < 0.85, "\(spots)")
        // Without spots, about the band's share.
        #expect(abs(even.atSpot - even.expected) < 0.05, "\(even)")
    }

    /// Over many races, the pressure side follows the venue's tendency more often than not, and in some races
    /// doesn't: the race's multiplier on it, from window 0's key, is sometimes reversed, and the keys still move the
    /// side. A mirror-image tendency leans the other way, and with none the side is even.
    @Test func sideTendencyIsVariable() throws {
        let pairing = try GeographyFixtures.devPairing()
        #expect(pairing.sideTendency > 0)
        let strong = GeographyFixtures.pairing(pairing, sideTendency: 0.15)
        let conditions = try ConditionsFile.bundled(id: "classic-oscillating", version: 5).content
        let scale = try #require(conditions.pressureField).side.tendencyScale
        func follows(_ pairing: Venue.Pairing) throws -> (share: Double, reversed: Int) {
            var follows = 0, reversed = 0
            let seeds = UInt64(1)...200
            for seed in seeds {
                let setup = try GeographyFixtures.setup(raceSeed: seed, pairing: pairing)
                let side = try GeographyFixtures.meanSide(setup, seed: seed)
                if pairing.sideTendency == 0 ? side > 0 : (side > 0) == (pairing.sideTendency > 0) { follows += 1 }
                if pairing.sideTendency != 0 {
                    let plan = try #require(WindField(setup: setup, windows: Self.w).pressurePlan)
                    var generator = try WindFixtures.generator(setup, windSeed: seed)
                    let first = generator.keys(through: 0)[0]
                    let multiplier = plan.draws(of: first, windows: Self.w).tendency / pairing.sideTendency
                    #expect(scale.contains(multiplier))
                    if multiplier < 0 { reversed += 1 }
                }
            }
            return (Double(follows) / Double(seeds.count), reversed)
        }
        let dev = try follows(pairing), strongly = try follows(strong)
        let mirror = try follows(GeographyFixtures.pairing(pairing, sideTendency: -pairing.sideTendency))
        let none = try follows(GeographyFixtures.pairing(pairing, sideTendency: 0))
        // More often than not, and not always.
        #expect(dev.share > 0.55 && dev.share < 0.95, "\(dev)")
        #expect(strongly.share > dev.share && strongly.share < 0.95, "\(strongly)")
        #expect(mirror.share > 0.55, "\(mirror)")
        #expect(abs(none.share - 0.5) < 0.1, "\(none)")
        // Some races reverse it: about a quarter, from −0.5…1.5.
        #expect(dev.reversed > 20 && dev.reversed < 80, "\(dev)")

        // The tendency is window 0's draw, so the wind needs window 0's key throughout.
        let setup = try GeographyFixtures.setup(raceSeed: 3, pairing: pairing)
        let (field, _) = try WindFixtures.field(setup, windSeed: 3, through: 70)
        let tick = Self.w.start(of: 70) + 5
        #expect(field.firstWindowNeeded(atTick: tick) == 0)
        var keys = field.keys
        keys.remove(window: 0)
        let dropped = WindField(setup: setup, windows: Self.w, keys: keys)
        #expect(throws: WindFieldError.missingKey(0)) { try dropped.sample(.zero, tick: tick) }
    }

    /// Older schema files decode their shadow as the same (negative) change: the speed factor as written, with no
    /// lane spots or tendency, so the pressure field draws nothing more and they sail unchanged (the golden rows).
    @Test func oldShadowReadsAsLoss() throws {
        let data = try #require(try VenueFile.bundledData(id: VenueFixtures.devID, version: 4))
        let file = try VenueFile(data: data)
        #expect(file.schemaVersion == 1)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let filePairings = try #require(json["pairings"] as? [[String: Any]])
        for (pairing, written) in zip(file.content.pairings, filePairings) {
            let geo = pairing.geographicGrid
            let grid = try #require(written["geographicGrid"] as? [String: Any])
            let factors = try #require(grid["speedFactor"] as? [[Double]])
            var losses = 0
            for row in 0..<geo.grid.rows {
                for column in 0..<geo.grid.columns {
                    let factor = factors[row][column]
                    // The factor as written, bit for bit: never re-derived through the change.
                    #expect(geo.speedFactor(column: column, row: row).bitPattern == factor.bitPattern)
                    #expect(geo.speedChange(column: column, row: row) == factor - 1)
                    if factor < 1 {
                        #expect(geo.speedChange(column: column, row: row) < 0)
                        losses += 1
                    }
                    #expect(geo.lanePreference(column: column, row: row) == 0)
                }
            }
            #expect(losses > 0)
            #expect(abs(geo.speedChange(column: 0, row: 0) + 0.12) < 1e-12)
            #expect(!geo.hasLaneSpots && pairing.sideTendency == 0)
        }
        // test-venue@1's factors above 1 read as gains.
        let test = try VenueFixtures.testVenue().pairings[0].geographicGrid
        #expect(abs(test.speedChange(column: 2, row: 3) - 0.1) < 1e-12)

        // Their pressure field is #286's: no spots, no tendency, lanes uniform across the course, no key 0 needed.
        let setup = try PressureFixtures.setup(raceSeed: 5, pairing: try PressureFixtures.devPairing("classic-oscillating"))
        let (field, _) = try WindFixtures.field(setup, windSeed: 5, through: 70)
        let plan = try #require(field.pressurePlan)
        #expect(plan.laneSpots == nil && !plan.readsFirstKey && plan.sideTendency == 0)
        let tick = Self.w.start(of: 70) + 5
        #expect(field.firstWindowNeeded(atTick: tick) == 70 - plan.lookback)
        for key in field.keys.keys {
            let draws = plan.draws(of: key, windows: Self.w)
            #expect(draws.tendency == 0)
            // Each lane's start is #286's uniform draw: the fifth of its six on the lane stream after the count.
            var rng = SplitMix64(seed: key.puffSeed, stream: PressurePlan.laneStream)
            _ = rng.unit()
            for lane in draws.lanes {
                let values = (0..<6).map { _ in rng.unit() }
                #expect(lane.start == (2 * values[4] - 1) * (plan.halfWidth + plan.laneMargin))
            }
            for j in [key.window, key.window + 3] {
                var window = j, expected = 0.0
                while window >= max(0, j - plan.sideLookback + 1) {
                    if let side = field.pressureDraws(ofWindow: window).side { expected = side; break }
                    window -= 1
                }
                #expect(field.sideTarget(j, plan).bitPattern == expected.bitPattern)
            }
        }
    }

    /// The new dev-venue shows its pattern: a cross-course difference in speed larger than the old placeholder
    /// grid's, more pressure off the west headland and less under the east shore, its lane spot off the headland,
    /// within the lanes' reach, and a mild left-side tendency (the west, looking upwind into its northerly).
    @Test func devVenueHasAPattern() throws {
        let old = try GeographyFixtures.devVenue(4), new = try GeographyFixtures.devVenue(5)
        #expect(new.pairings.count == old.pairings.count)
        /// Speed factors along the start line's latitude across the water, x −700…700 m: their spread, and the west
        /// third's mean less the east third's.
        func acrossCourse(_ pairing: Venue.Pairing) -> (spread: Double, westLessEast: Double) {
            let factors = stride(from: -700.0, through: 700, by: 50).map { pairing.geographicGrid.sample(Vec2($0, 0)).speedFactor }
            let third = factors.count / 3
            let mean = { (s: ArraySlice<Double>) in s.reduce(0, +) / Double(s.count) }
            return (factors.max()! - factors.min()!, mean(factors.prefix(third)) - mean(factors.suffix(third)))
        }
        for (before, after) in zip(old.pairings, new.pairings) {
            let was = acrossCourse(before), now = acrossCourse(after)
            #expect(now.spread > was.spread + 0.1, "\(after.conditions): \(now) vs \(was)")
            #expect(now.westLessEast > abs(was.westLessEast) + 0.1, "\(after.conditions)")
            #expect(after.geographicGrid.directionDeltas == before.geographicGrid.directionDeltas)

            // The lane spot is off the headland (its tip at (−700, 200)): the most preferred nodes lie 300–500 m
            // east of it, abreast of it or downwind (south), and nothing prefers lanes east of mid-course.
            let geo = after.geographicGrid
            let best = geo.lanePreferences.max()!
            #expect(best == 1)
            for row in 0..<geo.grid.rows {
                for column in 0..<geo.grid.columns {
                    let p = geo.grid.position(column: column, row: row), preference = geo.lanePreference(column: column, row: row)
                    if preference == best { #expect(p.x >= -400 && p.x <= -200 && p.y <= 300, "\(p)") }
                    if p.x >= 0 { #expect(preference == 0) }
                }
            }
            #expect(after.sideTendency > 0 && after.sideTendency <= 0.1)

            let setup = try GeographyFixtures.setup(after.conditions.id, pairing: after)
            let plan = try #require(WindField(setup: setup, windows: Self.w).pressurePlan)
            let spots = try #require(plan.laneSpots)
            let headland = plan.coordinate(at: Vec2(-300, 0))
            #expect(abs(headland) < plan.halfWidth + plan.laneMargin)
            // The right-hand side looking downwind is the west: the side a positive tendency favours.
            #expect(headland > 0)
            let centre = (0..<200).map { spots.position((Double($0) + 0.5) / 200, 0.5) }.reduce(0, +) / 200
            #expect(abs(centre - headland) < 100, "\(centre) vs \(headland)")
        }
    }

    /// dev-venue@5 is version 4 in everything but its geography and pairs the version-5 files; the version-5
    /// conditions are version 4 plus the two geography columns (schema 4), pinned, which schema 3 refuses.
    @Test(arguments: GeographyFixtures.version5Hashes.map(\.id))
    func version5FilesAreVersion4PlusTheGeographyColumns(id: String) throws {
        let v5 = try ConditionsFile.bundled(id: id, version: 5)
        #expect(v5.schemaVersion == 4 && v5.version == 5)
        #expect(v5.ref.hash.hex == GeographyFixtures.version5Hashes.first { $0.id == id }?.hash)
        let before = try ConditionsFixtures.leaves(id, version: 4), after = try ConditionsFixtures.leaves(id, version: 5)
        let header = ["/version", "/schemaVersion", "/placeholders", "/notes"]
        let changed = Set(before.keys).union(after.keys)
            .filter { before[$0] != after[$0] }
            .filter { pointer in !header.contains { pointer == $0 || pointer.hasPrefix($0 + "/") } }
        #expect(changed == ["/pressureField/side/tendencyScale/min", "/pressureField/side/tendencyScale/max",
                            "/pressureField/lanes/spotShare"])
        let field = try #require(v5.content.pressureField)
        #expect(field.side.tendencyScale == -0.5...1.5 && field.lanes.spotShare == 0.7)
        let v4 = try #require(try ConditionsFile.bundled(id: id, version: 4).content.pressureField)
        #expect(v4.side.tendencyScale == Conditions.PressureField.Side.defaultTendencyScale)
        #expect(v4.lanes.spotShare == Conditions.PressureField.Lanes.defaultSpotShare)

        let text = String(decoding: try #require(try ConditionsFile.bundledData(id: id, version: 5)), as: UTF8.self)
        let schema3 = text.replacingOccurrences(of: #""schemaVersion": 4,"#, with: #""schemaVersion": 3,"#)
        #expect { try ConditionsFile(data: Data(schema3.utf8)) } throws: { error in
            if case .invalidContent(kind: "conditions", id: id, reason: _) = error as? DataFileError { return true }
            return false
        }
        let noShare = text.replacingOccurrences(of: ",\n      \"spotShare\": 0.7", with: "")
            .replacingOccurrences(of: ",\n    \"/pressureField/lanes/spotShare\"", with: "")
        #expect { try ConditionsFile(data: Data(noShare.utf8)) } throws: { error in
            if case .malformed(kind: "conditions", reason: _) = error as? DataFileError { return true }
            return false
        }
        let tooMany = text.replacingOccurrences(of: #""spotShare": 0.7"#, with: #""spotShare": 1.5"#)
        #expect(throws: DataFileError.self) { try ConditionsFile(data: Data(tooMany.utf8)) }

        let venue = try GeographyFixtures.devVenue()
        let pairing = try #require(venue.pairing(for: v5.ref.key))
        let was = try GeographyFixtures.devPairing(id, version: 4)
        #expect(pairing.meanDirection == was.meanDirection && pairing.trendDirection == was.trendDirection)
        #expect(pairing.startLineCentre == was.startLineCentre && pairing.geographicGrid.grid == was.geographicGrid.grid)
        let old = try GeographyFixtures.devVenue(4)
        #expect(venue.displayName == old.displayName && venue.landmarks == old.landmarks && venue.land == old.land)
        #expect(venue.current == old.current)
    }

    /// Schema 2 is validated: a speed change of −1 or less, a lane preference outside 0…1, a side tendency beyond
    /// ±0.5, a missing tendency, a schema-1 `speedFactor` or an unknown field is refused.
    @Test func schema2IsValidated() throws {
        let text = String(decoding: try #require(try VenueFile.bundledData(id: VenueFixtures.devID, version: 5)), as: UTF8.self)
        func refused(_ of: String, _ with: String) {
            #expect(text.contains(of), "\(of)")
            let data = Data(text.replacingOccurrences(of: of, with: with).utf8)
            #expect(throws: DataFileError.self, "\(with)") { try VenueFile(data: data) }
        }
        refused(#""sideTendency": 0.06"#, #""sideTendency": 0.6"#)
        refused("\"speedChange\": [\n          [-0.13", "\"speedChange\": [\n          [-1")
        refused("\"lanePreference\": [\n          [0,", "\"lanePreference\": [\n          [1.2,")
        refused(#""speedChange": ["#, #""speedFactor": ["#)
        refused(#""sideTendency": 0.06,"#, "")
        let extra = text.replacingOccurrences(of: #""cellSizeMetres": 100,"#, with: #""cellSizeMetres": 100, "extra": 1,"#)
        #expect(throws: DataFileError.malformed(
            kind: "venue", reason: "unknown or null field /pairings/0/geographicGrid/extra: a venue file has only its schema's fields")) {
            try VenueFile(data: Data(extra.utf8))
        }
    }
}
