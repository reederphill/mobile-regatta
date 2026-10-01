import Foundation
import Testing
@testable import RegattaCore

/// Finite pressure lanes' fixtures (ADR 0008): the version-7 (schema 6) conditions at dev-venue@7, which pairs them.
enum FiniteLaneFixtures {
    static let w = WindFixtures.windows

    /// The version-7 files' SHA-256, pinned like every released file (ADR 0004).
    static let version7Hashes: [(id: String, hash: String)] = [
        ("classic-oscillating", "5cf03773ab3e3dcc8f7cda42041784a3bd3bf51339fe37dafd0e0b4ad7ef70de"),
        ("gusty-offshore", "319366c97c015c3723692565cfcd414886737e23a0906e518df04dae4e33b24c"),
        ("light-and-patchy", "3df853bede49332395d521de57bc7564851a1de2c47985431b30f6e297809eb0"),
        ("sea-breeze", "54e788f185b30afa503b48d0221e67a2e623d396ef2630034c571e0157294a05"),
    ]

    /// The version-8 files' SHA-256 (the owner's lane tuning).
    static let version8Hashes: [(id: String, hash: String)] = [
        ("classic-oscillating", "7f25a953b048a0cf10c24e787869414de412c0c68abe65a0018bec5376b0e838"),
        ("gusty-offshore", "bd948397188603b2cb73579195b8cd44be22b56e2403c19405ab46f3077a0804"),
        ("light-and-patchy", "fca3e5028df123babc36983da39544c775b7f442b4fc597a5867acce8b4e0faf"),
        ("sea-breeze", "a1035f21fe51804f7c0f1846dcfc705f6a4a5fbb25b6082819759c262eba5d38"),
    ]

    /// `id`@`version`'s setup with a race area at dev-venue@`version`.
    static func setup(_ id: String, version: Int = 7, raceSeed: UInt64 = 1) throws -> WindSetup {
        try GeographyFixtures.setup(id, version: version, raceSeed: raceSeed)
    }

    /// `field`'s pressure factor at points `steps` apart along a line up the course, `across` metres right of its
    /// centre line, at `tick`: where the venue's geography is the same at every point of the line, so any change
    /// along it is the pressure field's.
    static func alongCourse(_ field: WindField, tick: Int, across: Double, steps: Int = 12) throws -> [Double] {
        let area = try #require(field.setup.raceArea)
        let pressure = try field.pressure(atTick: tick)
        return (0..<steps).map { i in
            let along = (Double(i) / Double(steps - 1) * 2 - 1) * area.halfLength * 0.9
            return pressure(PressureFixtures.point(area, across: across, along: along)).factor
        }
    }
}

/// Finite pressure lanes (ADR 0008): schema 6 makes each lane an ellipse that drifts down the wind, some of them weak,
/// so the pressure changes up the course as well as across it.
@Suite struct FiniteLaneTests {
    static let w = FiniteLaneFixtures.w

    /// The version-7 files are version 6 with the lanes' extent, a weaker side and a different mix of lanes (schema 6),
    /// pinned; schema 5 refuses the new columns, schema 6 needs them; dev-venue@7 is dev-venue@6 on them.
    @Test(arguments: FiniteLaneFixtures.version7Hashes.map(\.id))
    func version7FilesAreVersion6PlusFiniteLanes(id: String) throws {
        let v7 = try ConditionsFile.bundled(id: id, version: 7)
        #expect(v7.schemaVersion == 6 && v7.version == 7)
        let before = try ConditionsFixtures.leaves(id, version: 6), after = try ConditionsFixtures.leaves(id, version: 7)
        let header = ["/version", "/schemaVersion", "/placeholders", "/notes"]
        let changed = Set(before.keys).union(after.keys)
            .filter { before[$0] != after[$0] }
            .filter { pointer in !header.contains { pointer == $0 || pointer.hasPrefix($0 + "/") } }
        #expect(changed == [
            "/pressureField/side/strength", "/pressureField/lanes/count", "/pressureField/lanes/strength/min",
            "/pressureField/lanes/strength/max", "/pressureField/lanes/widthMetres/min", "/pressureField/lanes/widthMetres/max",
            "/pressureField/lanes/spotShare", "/pressureField/lanes/lengthMetres/min", "/pressureField/lanes/lengthMetres/max",
            "/pressureField/lanes/alongDriftFraction/min", "/pressureField/lanes/alongDriftFraction/max",
            "/pressureField/lanes/weakShare",
        ])
        let extent = try #require(v7.content.pressureField?.lanes.extent)
        #expect(extent.length == 300...800 && extent.drift == 0.1...0.25 && (0...1).contains(extent.weakShare))
        #expect(try ConditionsFile.bundled(id: id, version: 6).content.pressureField?.lanes.extent == nil)

        let text = String(decoding: try #require(try ConditionsFile.bundledData(id: id, version: 7)), as: UTF8.self)
        func refused(_ of: String, _ with: String) {
            #expect(text.contains(of), "\(of)")
            #expect(throws: DataFileError.self, "\(with)") { try ConditionsFile(data: Data(text.replacingOccurrences(of: of, with: with).utf8)) }
        }
        refused(#""schemaVersion": 6,"#, #""schemaVersion": 5,"#)
        refused(",\n      \"lengthMetres\": { \"min\": 300, \"max\": 800 }", "")
        refused(",\n      \"alongDriftFraction\": { \"min\": 0.1, \"max\": 0.25 }", "")
        refused(#""lengthMetres": { "min": 300, "max": 800 }"#, #""lengthMetres": { "min": 900, "max": 800 }"#)
        refused(#""alongDriftFraction": { "min": 0.1, "max": 0.25 }"#, #""alongDriftFraction": { "min": 0.1, "max": 1.5 }"#)
        let weak = try #require(text.range(of: #"(?<="weakShare": )[0-9.]+"#, options: .regularExpression))
        refused(String(text[weak]), "1.5")
        let count = try #require(text.range(of: #"(?<="count": )[0-9.]+"#, options: .regularExpression))
        refused(String(text[count]), "25")

        let venue = try GeographyFixtures.devVenue(7), was = try GeographyFixtures.devVenue(6)
        let pairing = try #require(venue.pairing(for: v7.ref.key))
        let old = try GeographyFixtures.devPairing(id, version: 6)
        #expect(pairing.geographicGrid == old.geographicGrid && pairing.sideTendency == old.sideTendency)
        #expect(pairing.meanDirection == old.meanDirection && pairing.startLineCentre == old.startLineCentre)
        #expect(venue.landmarks == was.landmarks && venue.land == was.land && venue.current == was.current)
    }

    /// The version-8 files are version 7 with the owner's lane tuning (2026-10-01), the same in all four: 16 lanes,
    /// strength 0.10–0.20, width 60–200 m, life 30–180 s. Pinned; the venues that paired version 7 pair them in their
    /// next version, otherwise unchanged.
    @Test(arguments: FiniteLaneFixtures.version7Hashes.map(\.id))
    func version8FilesAreVersion7WithTheOwnersLaneTuning(id: String) throws {
        let v8 = try ConditionsFile.bundled(id: id, version: 8)
        #expect(v8.schemaVersion == 6 && v8.version == 8)
        #expect(v8.ref.hash.hex == FiniteLaneFixtures.version8Hashes.first { $0.id == id }?.hash)
        let before = try ConditionsFixtures.leaves(id, version: 7), after = try ConditionsFixtures.leaves(id, version: 8)
        let header = ["/version", "/schemaVersion", "/placeholders", "/notes"]
        let changed = Set(before.keys).union(after.keys)
            .filter { before[$0] != after[$0] }
            .filter { pointer in !header.contains { pointer == $0 || pointer.hasPrefix($0 + "/") } }
        let tuned: Set<String> = ["/pressureField/lanes/count", "/pressureField/lanes/strength/min", "/pressureField/lanes/strength/max",
                                  "/pressureField/lanes/widthMetres/min", "/pressureField/lanes/widthMetres/max",
                                  "/pressureField/lanes/lifetimeSeconds/min", "/pressureField/lanes/lifetimeSeconds/max"]
        #expect(changed.isSubset(of: tuned), "\(changed.subtracting(tuned))")
        let lanes = try #require(v8.content.pressureField?.lanes)
        #expect(lanes.count == 16 && lanes.strength == 0.1...0.2 && lanes.width == 60...200 && lanes.lifetime == 30...180)

        for (venue, was) in [("dev-venue", 7), ("hollin-bay", 1), ("saltings-reach", 1), ("fellmere", 1)] {
            let old = try VenueFile.bundled(id: venue, version: was).content
            let new = try VenueFile.bundled(id: venue, version: was + 1).content
            guard let pairing = old.pairing(for: DataFileKey(id: id, version: 7)) else {
                #expect(new.pairing(for: v8.ref.key) == nil, "\(venue) pairs \(id) in neither version")
                continue
            }
            let next = try #require(new.pairing(for: v8.ref.key), "\(venue)@\(was + 1) pairs \(id)@8")
            #expect(next.geographicGrid == pairing.geographicGrid && next.sideTendency == pairing.sideTendency)
            #expect(next.meanDirection == pairing.meanDirection && next.startLineCentre == pairing.startLineCentre)
            #expect(new.landmarks == old.landmarks && new.land == old.land && new.current == old.current)
        }
    }

    @Test func conditionsFilesArePinned() throws {
        for (id, hash) in FiniteLaneFixtures.version7Hashes {
            #expect(try ConditionsFile.bundled(id: id, version: 7).ref.hash.hex == hash, "\(id)")
        }
    }

    /// A finite lane's footprint is the ellipse `d² + e² < 1`: nothing beyond its length, `(1 − d² − e²)²` inside,
    /// the same either side of its middle up the course; a weak lane does the opposite of a strong one; and without a
    /// length a lane is the unending band it was, whatever the point's place along the course.
    @Test func laneEffectIsAnEllipse() {
        let lane = PressureLane(centre: 40, drift: 0, halfWidth: 100, intensity: 0.2, alongCentre: -50, halfLength: 300)
        let middle = lane.effect(at: 40, along: -50)
        #expect(abs(middle.speed - 0.2) < 1e-12 && middle.fan == 0)
        // Half way to its end up the course: (1 − 0.25)².
        #expect(abs(lane.effect(at: 40, along: -50 + 150).speed - 0.2 * 0.75 * 0.75) < 1e-12)
        #expect(lane.effect(at: 40, along: -50 + 150).speed == lane.effect(at: 40, along: -50 - 150).speed)
        #expect(lane.effect(at: 40, along: -50 + 300) == (0, 0) && lane.effect(at: 40, along: -50 - 301) == (0, 0))
        #expect(lane.effect(at: 140, along: -50) == (0, 0))
        // On the diagonal where d² + e² = 1, it is over.
        #expect(lane.effect(at: 40 + 80, along: -50 + 180) == (0, 0))
        #expect(lane.effect(at: 40 + 60, along: -50 + 120).speed > 0)
        // Veering on its right-hand edge, backing on its left, as an unending lane does.
        #expect(lane.effect(at: 40 + 50, along: -50).fan > 0 && lane.effect(at: 40 - 50, along: -50).fan < 0)

        let weak = PressureLane(centre: 40, drift: 0, halfWidth: 100, intensity: -0.2, alongCentre: -50, halfLength: 300)
        let (strong, loss) = (lane.effect(at: 70, along: 10), weak.effect(at: 70, along: 10))
        #expect(loss.speed == -strong.speed && loss.fan == -strong.fan)

        let band = PressureLane(centre: 40, drift: 0, halfWidth: 100, intensity: 0.2)
        for along in [-5_000.0, 0, 70, 9_000] {
            #expect(band.effect(at: 90, along: along) == band.effect(at: 90))
        }
    }

    /// A key draws a finite lane's length, place, drift and sign from a stream of its own, so every other draw is what
    /// the same key gives a file without an extent; and each lane's extent lies in the file's ranges.
    @Test(arguments: FiniteLaneFixtures.version7Hashes.map(\.id))
    func extentIsDrawnFromItsOwnStream(id: String) throws {
        let setup = try FiniteLaneFixtures.setup(id, raceSeed: 7)
        let (field, _) = try WindFixtures.field(setup, windSeed: 7, through: 34)
        let plan = try #require(field.pressurePlan)
        let extent = try #require(plan.extent)
        let bare = Conditions.PressureField(
            side: plan.field.side,
            lanes: .init(count: plan.field.lanes.count, strength: plan.field.lanes.strength, width: plan.field.lanes.width,
                         lifetime: plan.field.lanes.lifetime, drift: plan.field.lanes.drift, bend: plan.field.lanes.bend,
                         spotShare: plan.field.lanes.spotShare, extent: nil),
            puffChoices: plan.field.puffChoices)
        let unending = PressurePlan(setup: setup, area: try #require(setup.raceArea), field: bare)
        var lanes = 0, weak = 0
        for window in 0...34 {
            let key = try #require(field.keys[window])
            let drawn = plan.draws(of: key, windows: Self.w), plain = unending.draws(of: key, windows: Self.w)
            #expect(drawn.side == plain.side && drawn.tendency == plain.tendency)
            #expect(drawn.lanes.count == plain.lanes.count)
            for (a, b) in zip(drawn.lanes, plain.lanes) {
                #expect(b.halfLength == nil && a.halfLength != nil)
                #expect((a.window, a.index, a.spawnTick, a.lifetimeTicks) == (b.window, b.index, b.spawnTick, b.lifetimeTicks))
                #expect((a.halfWidth, a.start, a.startDrift) == (b.halfWidth, b.start, b.startDrift))
                #expect(abs(a.strength) == b.strength)
                let half = try #require(a.halfLength)
                #expect(half >= extent.length.lowerBound / 2 && half <= extent.length.upperBound / 2)
                // It drifts down the wind (negative up the course) at its share of the base wind speed.
                let speed = -a.alongVelocity / plan.baseStrength
                #expect(speed >= extent.drift.lowerBound - 1e-12 && speed <= extent.drift.upperBound + 1e-12)
                // Its mid-life place lies within the race area and half the longest length beyond it, or at a spot.
                let mid = a.alongCentre(atTick: a.spawnTick + a.lifetimeTicks / 2)
                let spots = try #require(plan.laneSpots)
                let nearSpot = spots.alongs.contains { abs(mid - $0) <= spots.spread + 1 }
                #expect(abs(mid) <= plan.halfLength + extent.length.upperBound / 2 + 1e-6 || nearSpot)
                #expect(a.alongCentre(atTick: a.spawnTick + 30) < a.alongCentre(atTick: a.spawnTick))
                if a.strength < 0 { weak += 1 }
                lanes += 1
            }
        }
        #expect(lanes > 50, "\(lanes) lanes")
        // About the file's share of the lanes away from the venue's spots weaken the wind.
        let share = Double(weak) / Double(lanes)
        let expected = extent.weakShare * (1 - plan.field.lanes.spotShare)
        #expect(abs(share - expected) < 0.15, "\(share) weak against \(expected)")
    }

    /// A finite lane at one of the venue's spots lies at its node up the course as well as across, and is never weak:
    /// with every lane at a spot, each is strong and forms within half a cell of a preferring node both ways.
    @Test func spotLanesAreStrongAndAtTheirNode() throws {
        let setup = try FiniteLaneFixtures.setup("light-and-patchy", raceSeed: 3)
        let (field, _) = try WindFixtures.field(setup, windSeed: 3, through: 34)
        let base = try #require(field.pressurePlan)
        let lanes = base.field.lanes
        let allAtSpots = Conditions.PressureField(
            side: base.field.side,
            lanes: .init(count: lanes.count, strength: lanes.strength, width: lanes.width, lifetime: lanes.lifetime,
                         drift: lanes.drift, bend: lanes.bend, spotShare: 1, extent: lanes.extent),
            puffChoices: base.field.puffChoices)
        let plan = PressurePlan(setup: setup, area: try #require(setup.raceArea), field: allAtSpots)
        let spots = try #require(plan.laneSpots)
        var checked = 0
        for window in 0...34 {
            for lane in plan.draws(of: try #require(field.keys[window]), windows: Self.w).lanes {
                #expect(lane.strength > 0)
                let mid = lane.alongCentre(atTick: lane.spawnTick + lane.lifetimeTicks / 2)
                let near = zip(spots.positions, spots.alongs).contains { across, along in
                    abs(lane.start - across) <= spots.spread + 1e-6 && abs(mid - along) <= spots.spread + 1
                }
                #expect(near, "lane at \(lane.start) across, \(mid) along")
                checked += 1
            }
        }
        #expect(checked > 50)
    }

    /// The pressure changes up the course: along a line parallel to the wind, a version-7 field varies by more than 3 %
    /// in over half the samples and several times as much as the version-6 field, whose unending bands only bend with
    /// the venue's shore, and whose geography is level down the middle of the course.
    @Test func pressureChangesUpTheCourse() throws {
        var varies = 0, samples = 0
        var oldRanges = 0.0, newRanges = 0.0
        for id in WindFixtures.ids {
            for raceSeed in UInt64(1)...3 {
                let old = try FiniteLaneFixtures.setup(id, version: 6, raceSeed: raceSeed)
                let new = try FiniteLaneFixtures.setup(id, version: 7, raceSeed: raceSeed)
                let (oldField, _) = try WindFixtures.field(old, windSeed: raceSeed, through: 34)
                let (newField, _) = try WindFixtures.field(new, windSeed: raceSeed, through: 34)
                for tick in stride(from: Self.w.start(of: 4), to: Self.w.start(of: 30), by: 5 * WindWindows.ticksPerWindow / 2) {
                    // Down the middle of the course, where dev-venue's geography is level from end to end.
                    let flat = try FiniteLaneFixtures.alongCourse(oldField, tick: tick, across: 0)
                    let moving = try FiniteLaneFixtures.alongCourse(newField, tick: tick, across: 0)
                    oldRanges += flat.max()! - flat.min()!
                    newRanges += moving.max()! - moving.min()!
                    if moving.max()! - moving.min()! > 0.03 { varies += 1 }
                    samples += 1
                }
            }
        }
        #expect(Double(varies) / Double(samples) > 0.5, "\(varies) of \(samples) lines vary by more than 3 % up the course")
        #expect(newRanges > 3 * oldRanges, "mean range up the course \(newRanges / Double(samples)) against \(oldRanges / Double(samples))")
    }

    /// Sampling is still a pure function of the keys: a field built from the keys in any order is the same field,
    /// and the water's sampler gives `sample`'s answer at every point, bit for bit, with finite lanes.
    @Test func keyedAndSampledAsBefore() throws {
        let setup = try FiniteLaneFixtures.setup("gusty-offshore", raceSeed: 11)
        let (field, _) = try WindFixtures.field(setup, windSeed: 11, through: 40)
        var shuffled = field.keys.keys
        var rng = SplitMix64(seed: 2024)
        rng.shuffle(&shuffled)
        var added = WindField(setup: setup, windows: Self.w)
        for key in shuffled { added.add(key) }
        #expect(added == field)

        let area = try #require(setup.raceArea)
        for tick in stride(from: Self.w.start(of: 3), to: Self.w.start(of: 38), by: 211) {
            let sampler = try field.sampler(atTick: tick)
            let pressure = try field.pressure(atTick: tick)
            for i in 0..<24 {
                let p = PressureFixtures.point(area, across: Double(i % 6 - 3) * area.halfWidth / 3,
                                               along: Double(i / 6 - 2) * area.halfLength / 2)
                let a = try field.sample(p, tick: tick), b = sampler.sample(p)
                #expect(a.speed.bitPattern == b.speed.bitPattern && a.direction.bitPattern == b.direction.bitPattern)
                #expect(sampler.pressure(at: p) == pressure(p))
            }
        }
    }
}
