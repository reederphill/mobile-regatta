import Foundation
import Testing
@testable import RegattaCore

/// The pressure field's fixtures (#286): the version-4 (schema 3) conditions, with the race area a `Race` gives them.
enum PressureFixtures {
    static let w = WindFixtures.windows

    /// `id`@4's setup with a race area, on `pairing` or else a flat one.
    static func setup(_ id: String = "classic-oscillating", raceSeed: UInt64 = 1, pairing: Venue.Pairing? = nil) throws -> WindSetup {
        PuffFixtures.withRaceArea(try WindFixtures.setup(id, version: 4, raceSeed: raceSeed, pairing: pairing))
    }

    /// `id`@4's pairing at dev-venue@4: its gentle shore bends.
    static func devPairing(_ id: String) throws -> Venue.Pairing {
        let venue = try VenueFile.bundled(id: "dev-venue", version: 4).content
        return try #require(venue.pairing(for: DataFileKey(id: id, version: 4)))
    }

    /// A 2 km square grid, wind from the north, whose bend grows from nothing at its downwind (south) edge to
    /// `maxDegrees` veered at its upwind edge: streamlines through it curve.
    static func bentGrid(maxDegrees: Double = 12) -> Venue.GeographicGrid {
        let grid = Venue.Grid(origin: Vec2(-1000, -1000), cellSize: 100, orientation: 0, columns: 21, rows: 21)
        var deltas = [Double](repeating: 0, count: grid.nodeCount)
        for row in 0..<grid.rows {
            for column in 0..<grid.columns {
                deltas[grid.index(column: column, row: row)] = deg2rad(maxDegrees * Double(row) / Double(grid.rows - 1))
            }
        }
        return Venue.GeographicGrid(grid: grid, directionDeltas: deltas, speedFactors: Array(repeating: 1, count: grid.nodeCount))
    }

    static func bentPairing(_ id: String = "classic-oscillating") throws -> Venue.Pairing {
        let file = try ConditionsFile.bundled(id: id, version: 4)
        return Venue.Pairing(conditions: file.ref.key, meanDirection: 0, trendDirection: .either, startLineCentre: .zero,
                             geographicGrid: bentGrid())
    }

    /// A point `across` metres right of the race area's centre line (looking downwind) and `along` metres up it.
    static func point(_ area: RaceArea, across: Double, along: Double) -> Vec2 {
        let up = Vec2.heading(area.axis)
        return area.centre + (-up).rightPerp * across + up * along
    }

    /// The version-4 files' SHA-256, pinned like every released file (ADR 0004).
    static let version4Hashes: [(id: String, hash: String)] = [
        ("classic-oscillating", "2bd88b641fad3d95bc432d8c41c6bb84b224105ba8fdca84004537ef3f6091f2"),
        ("gusty-offshore", "7bda012b065f69b6b50642f314d3e3731766f12213961e1c9c94a1a1b2a32b8a"),
        ("light-and-patchy", "ff832751b6b31285723de36207b14e251b1403f615541e6c5ecc3d8cbde59865"),
        ("sea-breeze", "a56b2b264ab777c72edf799a57108fe93a5ec5b6d8e1c4f06237f941dba6c7c9"),
    ]
}

/// The pressure field (#286, ADR 0008): the pressure side and pressure lanes, keyed per window.
@Suite struct PressureFieldTests {
    static let w = PressureFixtures.w

    /// The same keys give the same field, whatever order they came in; a window's key changes the field only from
    /// that window on; and sampling needs every key back to `firstWindowNeeded`, and says which it lacks.
    @Test func keyedPerWindow() throws {
        let setup = try PressureFixtures.setup(raceSeed: 3)
        let plan = try #require(WindField(setup: setup, windows: Self.w).pressurePlan)
        let (field, _) = try WindFixtures.field(setup, windSeed: 3, through: 40)
        var shuffled = field.keys.keys
        var rng = SplitMix64(seed: 286)
        rng.shuffle(&shuffled)
        var added = WindField(setup: setup, windows: Self.w)
        for key in shuffled { added.add(key) }
        #expect(added == field && WindField(setup: setup, windows: Self.w, keys: WindKeyChain(shuffled)) == field)

        let area = try #require(setup.raceArea)
        let points = (0..<12).map { i in
            PressureFixtures.point(area, across: Double(i - 6) * area.halfWidth / 5, along: Double(i % 4 - 2) * 100)
        }
        let (other, _) = try WindFixtures.field(setup, windSeed: 99, through: 40)
        for k in [12, 20, 28] {
            // Key k from another wind seed.
            var keys = field.keys
            keys.insert(try #require(other.keys[k]))
            let changed = WindField(setup: setup, windows: Self.w, keys: keys)
            var laterDiffers = false
            for tick in stride(from: Self.w.start(of: 1), to: Self.w.start(of: 40), by: 97) {
                let a = try field.pressureState(atTick: tick, plan), b = try changed.pressureState(atTick: tick, plan)
                if Self.w.window(containing: tick) < k {
                    #expect(a == b, "tick \(tick), before window \(k)")
                    for p in points {
                        let x = try field.sample(p, tick: tick), y = try changed.sample(p, tick: tick)
                        #expect(x.speed.bitPattern == y.speed.bitPattern && x.direction.bitPattern == y.direction.bitPattern)
                    }
                } else if a != b {
                    laterDiffers = true
                }
            }
            #expect(laterDiffers, "key \(k) changes the pressure field from its window on")
        }

        // Keys back to firstWindowNeeded, no further; the pressure side looks back further than any puff lives.
        let (long, _) = try WindFixtures.field(setup, windSeed: 3, through: 70)
        let k = 70, tick = Self.w.start(of: k) + 5
        let first = long.firstWindowNeeded(atTick: tick)
        #expect(first == k - plan.lookback && plan.lookback > PuffPlan(setup: setup, area: area).lookback)
        for window in [first, (first + k) / 2, k] {
            var keys = long.keys
            keys.remove(window: window)
            let dropped = WindField(setup: setup, windows: Self.w, keys: keys)
            #expect(throws: WindFieldError.missingKey(window)) { try dropped.sample(area.centre, tick: tick) }
            #expect(throws: WindFieldError.missingKey(window)) { try dropped.sampler(atTick: tick) }
            #expect(throws: WindFieldError.missingKey(window)) { try dropped.requireKeys(atTick: tick) }
        }
        var keys = long.keys
        keys.remove(window: first - 1)
        let older = WindField(setup: setup, windows: Self.w, keys: keys)
        #expect(try older.sample(area.centre, tick: tick) == long.sample(area.centre, tick: tick))
    }

    /// Each layer's curve is continuous across window boundaries, value and slope: the pressure side's knot ends
    /// one window and starts the next, and so does each lane's position and drift; and the field sampled either
    /// side of a boundary moves no more than within a window.
    @Test func smoothAcrossKnots() throws {
        var checkedLanes = 0
        for seed in UInt64(1)...6 {
            let setup = try PressureFixtures.setup(raceSeed: seed, pairing: try PressureFixtures.devPairing("classic-oscillating"))
            let (field, _) = try WindFixtures.field(setup, windSeed: seed, through: 41)
            let plan = try #require(field.pressurePlan)
            let area = try #require(setup.raceArea)
            for k in 2...40 {
                let end = WindField.hermite(field.sideKnot(k - 2, plan), field.sideKnot(k - 1, plan), 1)
                let start = WindField.hermite(field.sideKnot(k - 1, plan), field.sideKnot(k, plan), 0)
                #expect(abs(end.value - start.value) < 1e-12 && abs(end.slope - start.slope) < 1e-12, "side at knot \(k - 1)")

                let boundary = Self.w.start(of: k)
                for window in max(0, k - plan.laneLookback)...k {
                    for spawn in field.pressureDraws(ofWindow: window).lanes where spawn.isAlive(atTick: boundary) {
                        let end = WindField.hermite(field.laneKnot(spawn, k - 2, plan), field.laneKnot(spawn, k - 1, plan), 1)
                        let start = WindField.hermite(field.laneKnot(spawn, k - 1, plan), field.laneKnot(spawn, k, plan), 0)
                        #expect(abs(end.value - start.value) < 1e-9 && abs(end.slope - start.slope) < 1e-12, "lane at knot \(k - 1)")
                        checkedLanes += 1
                    }
                }

                // The field itself, a tick either side of the boundary, at a spread of points.
                let before = try field.pressureState(atTick: boundary - 1, plan), at = try field.pressureState(atTick: boundary, plan)
                #expect(at.side == field.sideKnot(k - 1, plan).value, "a window starts on its first knot")
                for i in 0..<9 {
                    let r = plan.coordinate(at: PressureFixtures.point(area, across: Double(i - 4) * area.halfWidth / 3, along: 0))
                    let a = plan.effect(at: r, side: before.side, lanes: before.lanes)
                    let b = plan.effect(at: r, side: at.side, lanes: at.lanes)
                    #expect(abs(a.factor - b.factor) < 2e-3 && abs(a.turn - b.turn) < deg2rad(0.1))
                }
            }
        }
        #expect(checkedLanes > 100, "\(checkedLanes) lanes across a knot")
    }

    /// #288: `pressureState` blends the knots `WindField` caches as keys arrive, bit for bit what working them out
    /// afresh at the tick gives (`sideTarget`, `sideKnot`, `laneKnots`): in the version-4 and -5 files, flat and at
    /// their dev venues (dev-venue@5 with a side tendency and lane spots), with keys added in order or shuffled.
    @Test func cachedKnotsGiveTheSameStateBitForBit() throws {
        var lanes = 0
        for id in WindFixtures.ids {
            let setups = [
                try PressureFixtures.setup(id, raceSeed: 5),
                try PressureFixtures.setup(id, raceSeed: 5, pairing: try PressureFixtures.devPairing(id)),
                try GeographyFixtures.setup(id, raceSeed: 5),
            ]
            for setup in setups {
                let (field, _) = try WindFixtures.field(setup, windSeed: 288, through: 45)
                let plan = try #require(field.pressurePlan)
                var shuffled = field.keys.keys
                var rng = SplitMix64(seed: 288)
                rng.shuffle(&shuffled)
                var added = WindField(setup: setup, windows: Self.w)
                for key in shuffled { added.add(key) }
                #expect(added == field)
                for tick in stride(from: Self.w.start(of: 1), to: Self.w.start(of: 46), by: 37) {
                    let k = Self.w.window(containing: tick)
                    let fraction = Double(tick - Self.w.start(of: k)) / Double(WindWindows.ticksPerWindow)
                    let side = WindField.hermite(field.sideKnot(k - 1, plan), field.sideKnot(k, plan), fraction).value
                    var expected: [PressureLane] = []
                    for window in max(0, k - plan.laneLookback)...k {
                        for spawn in field.pressureDraws(ofWindow: window).lanes where spawn.isAlive(atTick: tick) {
                            let knots = field.laneKnots(spawn, k, plan)
                            let position = WindField.hermite(knots.from, knots.to, fraction)
                            expected.append(PressureLane(centre: position.value, drift: position.slope, halfWidth: spawn.halfWidth,
                                                         intensity: spawn.intensity(atTick: tick)))
                        }
                    }
                    let state = try field.pressureState(atTick: tick, plan)
                    #expect(state.side.bitPattern == side.bitPattern, "\(id) side at tick \(tick)")
                    #expect(state.lanes.count == expected.count)
                    for (a, b) in zip(state.lanes, expected) {
                        #expect(a.centre.bitPattern == b.centre.bitPattern && a.drift.bitPattern == b.drift.bitPattern
                                && a.intensity.bitPattern == b.intensity.bitPattern, "\(id) lane at tick \(tick)")
                    }
                    lanes += expected.count
                }
            }
        }
        #expect(lanes > 1000, "\(lanes) lanes checked")
    }

    /// Over a leg (4 min), the difference in mean speed between the race area's two sides exceeds 5 % of the course
    /// speed most of the time; and the pressure side changes within a 20-minute race in some seeds, not all.
    @Test func pressureSidePersistsAndChanges() throws {
        let seeds = (0..<60).map { UInt64($0) &* 0x9E37_79B9_7F4A_7C15 ^ 0x286 }
        var legs = 0, pressuredLegs = 0
        var flipsBySeed: [Int] = []
        for seed in seeds {
            let setup = try PressureFixtures.setup(raceSeed: seed)
            let (field, _) = try WindFixtures.field(setup, windSeed: seed, through: 42)
            let plan = try #require(field.pressurePlan)
            let area = try #require(setup.raceArea)
            // Race windows 2…41: 20 minutes, five legs of eight windows.
            for leg in 0..<5 {
                var left = 0.0, right = 0.0, course = 0.0
                for window in (2 + 8 * leg)..<(10 + 8 * leg) {
                    for tick in stride(from: Self.w.start(of: window), to: Self.w.start(of: window + 1), by: 10 * Race.tickRate) {
                        for along in [-0.6, 0, 0.6] {
                            left += try field.sample(PressureFixtures.point(area, across: -0.7 * area.halfWidth,
                                                                            along: along * area.halfLength), tick: tick).speed
                            right += try field.sample(PressureFixtures.point(area, across: 0.7 * area.halfWidth,
                                                                             along: along * area.halfLength), tick: tick).speed
                            course += try field.courseAverageSpeed(atTick: tick)
                        }
                    }
                }
                legs += 1
                if abs(right - left) / course > 0.05 { pressuredLegs += 1 }
            }
            // Which side the knots favour, where they clearly favour one.
            var flips = 0, last = 0.0
            for k in 2...41 {
                let value = field.sideKnot(k, plan).value
                guard abs(value) > 0.25 * plan.field.side.strength else { continue }
                if last != 0, (value > 0) != (last > 0) { flips += 1 }
                last = value
            }
            flipsBySeed.append(flips)
        }
        let share = Double(pressuredLegs) / Double(legs)
        let flipped = flipsBySeed.filter { $0 > 0 }.count
        print("pressure side: \(pressuredLegs)/\(legs) legs over 5 %; \(flipped)/\(seeds.count) races flip; flips \(flipsBySeed)")
        #expect(share > 0.7, "\(pressuredLegs) of \(legs) legs with a pressure side")
        #expect(flipped > 0 && flipped < seeds.count, "\(flipped) of \(seeds.count) races flip")
    }

    /// The across-the-wind coordinate is constant along the streamlines of the wind the grid bends, so lanes laid
    /// on it curve with the geography; with a flat grid it is the plain distance across the mean wind, so they lie
    /// along it; and lanes move sideways no faster than the conditions' drift.
    @Test func lanesCurveWithTheGeography() throws {
        // Flat: straight across the race's mean wind, whatever it is.
        let flat = VenueFixtures.pairing(for: try ConditionsFile.bundled(id: "classic-oscillating", version: 4))
        #expect(flat.acrossWind.offsets.allSatisfy { $0 == 0 })
        for mean in [0.0, 0.1, -0.17] {
            let across = Venue.AcrossWind.across(mean), downwind = -Vec2.heading(mean)
            for p in [Vec2(0, 0), Vec2(300, -200), Vec2(-5000, 4000)] {
                #expect(flat.acrossWind.coordinate(at: p, meanDirection: mean) == p.dot(across))
                #expect(abs(flat.acrossWind.coordinate(at: p + downwind * 800, meanDirection: mean) - p.dot(across)) < 1e-9)
            }
        }

        // Bent: follow a streamline down through the grid with fine steps, independently of the trace at load. The
        // plain distance across moves far; the coordinate hardly.
        let pairing = try PressureFixtures.bentPairing()
        let geography = pairing.geographicGrid
        for startX in [-400.0, 0, 350] {
            var p = Vec2(startX, 950)
            let coordinate = pairing.acrossWind.coordinate(at: p, meanDirection: 0)
            let across = Venue.AcrossWind.across(0)
            let plainStart = p.dot(across)
            var worst = 0.0
            while p.y > -950 {
                p = p - Vec2.heading(geography.sample(p).directionDelta)
                worst = max(worst, abs(pairing.acrossWind.coordinate(at: p, meanDirection: 0) - coordinate))
            }
            #expect(abs(p.dot(across) - plainStart) > 150, "the streamline bends")
            #expect(worst < 3, "coordinate moves \(worst) m along a streamline from x \(startX)")
        }

        // A live lane's middle runs down that streamline: at every point of it, the lane is at its peak.
        let setup = try PressureFixtures.setup(raceSeed: 5, pairing: pairing)
        let (field, _) = try WindFixtures.field(setup, windSeed: 5, through: 30)
        let plan = try #require(field.pressurePlan)
        let area = try #require(setup.raceArea)
        var lanesSeen = 0
        for tick in stride(from: Self.w.start(of: 12), to: Self.w.start(of: 30), by: 30 * Race.tickRate) {
            for lane in try field.pressureState(atTick: tick, plan).lanes where abs(lane.centre) < area.halfWidth {
                // Find where the lane's middle crosses the upwind end of the race area, then follow the race's wind.
                let along = area.halfLength
                var lo = -2 * area.halfWidth, hi = 2 * area.halfWidth
                for _ in 0..<60 {
                    let mid = (lo + hi) / 2
                    if plan.coordinate(at: PressureFixtures.point(area, across: mid, along: along)) < lane.centre { lo = mid } else { hi = mid }
                }
                var p = PressureFixtures.point(area, across: lo, along: along)
                let end = PressureFixtures.point(area, across: lo, along: -along)
                var worst = 0.0
                while (p - end).dot(Vec2.heading(area.axis)) > 0 {
                    p = p - Vec2.heading(setup.meanDirection + pairing.geographicGrid.sample(p).directionDelta)
                    worst = max(worst, abs(plan.coordinate(at: p) - lane.centre) / lane.halfWidth)
                }
                #expect(worst < 0.1, "the lane's middle strays \(worst) half-widths off the streamline")
                lanesSeen += 1
            }
        }
        #expect(lanesSeen > 5)

        // Sideways, never faster than the drift column, knot or between.
        for seed in UInt64(1)...5 {
            let setup = try PressureFixtures.setup(raceSeed: seed)
            let (field, _) = try WindFixtures.field(setup, windSeed: seed, through: 30)
            let plan = try #require(field.pressurePlan)
            let limit = plan.field.lanes.drift
            #expect(limit > 0 && limit <= 1, "slow enough to sail into: \(limit) m/s")
            for tick in stride(from: Self.w.start(of: 2), to: Self.w.start(of: 30), by: 37) {
                let now = try field.pressureState(atTick: tick, plan), next = try field.pressureState(atTick: tick + 1, plan)
                for lane in now.lanes {
                    #expect(abs(lane.drift) <= limit * (1 + 1e-12))
                    if let moved = next.lanes.first(where: { $0.halfWidth == lane.halfWidth }) {
                        #expect(abs(moved.centre - lane.centre) <= limit / Double(Race.tickRate) + 1e-9)
                    }
                }
            }
        }
    }

    /// A lane veers the wind on its right-hand edge (looking downwind) and backs it on its left; the pressure side
    /// veers where it makes the wind stronger and backs where weaker, in proportion; and conditions before schema 3
    /// have no pressure field, so they sample as they always have.
    @Test func bendFollowsPressure() throws {
        let setup = try PressureFixtures.setup(raceSeed: 2)
        let plan = try #require(WindField(setup: setup, windows: Self.w).pressurePlan)
        let lane = PressureLane(centre: 40, drift: 0, halfWidth: 150, intensity: 0.12)
        for offset in [20.0, 67, 120] {
            let right = plan.effect(at: 40 + offset, side: 0, lanes: [lane])
            let left = plan.effect(at: 40 - offset, side: 0, lanes: [lane])
            #expect(right.turn > 0 && left.turn < 0 && abs(right.turn + left.turn) < 1e-15)
            #expect(right.factor > 1 && right.factor == left.factor)
        }
        let middle = plan.effect(at: 40, side: 0, lanes: [lane])
        #expect(middle.turn == 0 && middle.factor == 1.12)
        // Its edge bend peaks at the lanes' bend for the strongest lane.
        let strongest = PressureLane(centre: 0, drift: 0, halfWidth: 150, intensity: plan.strongestLane)
        let peak = plan.effect(at: 150 / 5.0.squareRoot(), side: 0, lanes: [strongest])
        #expect(abs(peak.turn - plan.field.lanes.bend) < 1e-12)

        for side in [0.08, -0.1] {
            var last: Double?
            for r in stride(from: -plan.halfWidth, through: plan.halfWidth, by: plan.halfWidth / 4) {
                let effect = plan.effect(at: r, side: side, lanes: [])
                let pressure = effect.factor - 1
                #expect((effect.turn > 0) == (pressure > 0) && (effect.turn < 0) == (pressure < 0))
                if pressure != 0 {
                    let ratio = effect.turn / pressure
                    if let last { #expect(abs(ratio - last) < 1e-9) }
                    last = ratio
                }
            }
        }

        // Before schema 3 there is no pressure field, and the wind needs no keys further back for it.
        let field = WindField(setup: setup, windows: Self.w)
        for version in 1...3 {
            let old = PuffFixtures.withRaceArea(try WindFixtures.setup("classic-oscillating", version: version, raceSeed: 2))
            #expect(old.conditions.pressureField == nil && WindField(setup: old, windows: Self.w).pressurePlan == nil)
        }
        let tick = Self.w.start(of: 20)
        #expect(field.firstWindowNeeded(atTick: tick) < WindField(setup: PuffFixtures.withRaceArea(
            try WindFixtures.setup("classic-oscillating", version: 3, raceSeed: 2)), windows: Self.w).firstWindowNeeded(atTick: tick))
    }

    /// Version 4 of each conditions file is version 3 plus the pressure field (schema 3), pinned; schema 3 needs
    /// the pressure field and earlier schemas refuse it.
    @Test(arguments: PressureFixtures.version4Hashes.map(\.id))
    func version4FilesAreVersion3PlusThePressureField(id: String) throws {
        let v4 = try ConditionsFile.bundled(id: id, version: 4)
        #expect(v4.schemaVersion == 3 && v4.version == 4)
        #expect(v4.ref.hash.hex == PressureFixtures.version4Hashes.first { $0.id == id }?.hash)
        let before = try ConditionsFixtures.leaves(id, version: 3), after = try ConditionsFixtures.leaves(id, version: 4)
        let header = ["/version", "/schemaVersion", "/placeholders", "/notes"]
        let changed = Set(before.keys).union(after.keys)
            .filter { before[$0] != after[$0] }
            .filter { pointer in !header.contains { pointer == $0 || pointer.hasPrefix($0 + "/") } }
        #expect(changed.allSatisfy { $0.hasPrefix("/pressureField/") } && !changed.isEmpty)
        #expect(v4.header.placeholders.contains("/pressureField"))
        let field = try #require(v4.content.pressureField)
        #expect(field.side.strength > 0 && field.lanes.count >= 2 && field.lanes.count <= 4)
        #expect(field.lanes.width.lowerBound >= 100 && field.lanes.width.upperBound <= 500)
        #expect(field.lanes.lifetime == 120...240)

        let text = String(decoding: try #require(try ConditionsFile.bundledData(id: id, version: 4)), as: UTF8.self)
        let start = try #require(text.range(of: ",\n  \"pressureField\""))
        let withoutField = text[..<start.lowerBound].replacingOccurrences(of: ",\n    \"/pressureField\"", with: "") + "\n}\n"
        #expect { try ConditionsFile(data: Data(withoutField.utf8)) } throws: { error in
            if case .malformed(kind: "conditions", reason: _) = error as? DataFileError { return true }
            return false
        }
        let schema2 = text.replacingOccurrences(of: #""schemaVersion": 3,"#, with: #""schemaVersion": 2,"#)
        #expect { try ConditionsFile(data: Data(schema2.utf8)) } throws: { error in
            if case .invalidContent(kind: "conditions", id: id, reason: _) = error as? DataFileError { return true }
            return false
        }
        let weak = text.replacingOccurrences(of: #""side": { "strength": 0.15"#, with: #""side": { "strength": 0.9"#)
        #expect { try ConditionsFile(data: Data(weak.utf8)) } throws: { error in
            if case .invalidContent(kind: "conditions", id: id, reason: _) = error as? DataFileError { return true }
            return false
        }
    }
}
