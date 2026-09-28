import Foundation
import Testing
@testable import RegattaCore

/// Puffs and lulls formed from the pressure field's fixtures (#288): the version-6 (schema 5) conditions at
/// dev-venue@6, which pairs them.
enum PuffSpawnFixtures {
    static let w = WindFixtures.windows

    /// The version-6 files' SHA-256, pinned like every released file (ADR 0004).
    static let version6Hashes: [(id: String, hash: String)] = [
        ("classic-oscillating", "27bd4b26dab712ea998057e14fd06e45d7592a6e78491b195a4afc31297a7a45"),
        ("gusty-offshore", "59d74548087b6b10156c63bd6db3a06b79f7b2824c108ec3b9a1c89d7fb80ccc"),
        ("light-and-patchy", "65be03cb7306730498306b5abe3f3a3be6f7dc9d999948233cb74e6648a0213e"),
        ("sea-breeze", "a22f2bd49f0e82dcde0fcb09f4dd5abc290287a1f001eb3ea2b3ff9b62a1650a"),
    ]
    /// The race's windows: the start (window 2 with the default sequence) through window 33, past the time limit.
    static let race = 2..<34

    /// `id`@`version`'s setup with a race area at dev-venue@`version`: version 6's, or 5's to compare with.
    static func setup(_ id: String, version: Int = 6, raceSeed: UInt64) throws -> WindSetup {
        try GeographyFixtures.setup(id, version: version, raceSeed: raceSeed)
    }

    /// The pressure at `p` at `tick`, as a speed factor on the course average: the geographic grid's speed factor
    /// times the pressure field's, before any puff.
    static func pressure(_ field: WindField, at p: Vec2, tick: Int) throws -> Double {
        let plan = try #require(field.pressurePlan)
        let state = try field.pressureState(atTick: tick, plan)
        let factor = plan.effect(at: plan.coordinate(at: p), side: state.side, lanes: state.lanes).factor
        return field.setup.pairing.geographicGrid.sample(p).speedFactor * factor
    }

    /// Ticks through the race, `step` apart.
    static func ticks(step: Int) -> StrideTo<Int> {
        stride(from: w.start(of: race.lowerBound), to: w.start(of: race.upperBound), by: step)
    }

    /// Points `spacing` metres apart over `puff`'s disk where it changes the wind by more than
    /// `PuffPlan.coverageThreshold`: its footprint at that moment.
    static func footprint(_ puff: Puff, spacing: Double, across: Vec2) -> [Vec2] {
        var points: [Vec2] = []
        var x = -puff.radius
        while x <= puff.radius {
            var y = -puff.radius
            while y <= puff.radius {
                let p = puff.center + Vec2(x, y)
                if abs(puff.effect(at: p, across: across).speed) > PuffPlan.coverageThreshold { points.append(p) }
                y += spacing
            }
            x += spacing
        }
        return points
    }
}

/// Supplemental puffs and lulls (#288, ADR 0008): each forms at the best of `pressureField.puffChoices` places its
/// key draws, puffs where the pressure field is strong and lulls where it is weak, at about a third of the old
/// coverage; they keep their fan (#221).
@Suite struct PuffSpawnTests {
    static let w = PuffSpawnFixtures.w
    static let seeds: [UInt64] = [1, 2, 3, 4, 5, 6]

    /// Over a race in every version-6 file, the pressure at puffs' centres is higher than at lulls' centres, by
    /// more than `threshold` of the course average, where the version-5 files' puffs, formed anywhere, sit at no
    /// better pressure than their lulls.
    @Test(arguments: WindFixtures.ids)
    func puffsInPressureLullsOut(id: String) throws {
        let threshold = 0.04
        func gap(version: Int) throws -> Double {
            var puffs = 0.0, lulls = 0.0, puffCount = 0, lullCount = 0
            for seed in Self.seeds {
                let setup = try PuffSpawnFixtures.setup(id, version: version, raceSeed: seed)
                let (field, _) = try WindFixtures.field(setup, windSeed: seed, through: PuffSpawnFixtures.race.upperBound)
                for tick in PuffSpawnFixtures.ticks(step: WindWindows.ticksPerWindow / 2) {
                    for puff in field.activePuffs(atTick: tick) where puff.intensity != 0 {
                        let pressure = try PuffSpawnFixtures.pressure(field, at: puff.center, tick: tick)
                        if puff.strength > 0 { puffs += pressure; puffCount += 1 } else { lulls += pressure; lullCount += 1 }
                    }
                }
            }
            #expect(puffCount > 50 && lullCount > 20, "\(id)@\(version): \(puffCount) puffs, \(lullCount) lulls")
            return puffs / Double(max(1, puffCount)) - lulls / Double(max(1, lullCount))
        }
        let formed = try gap(version: 6), anywhere = try gap(version: 5)
        #expect(formed > threshold, "\(id): puffs' pressure above lulls' by \(formed)")
        #expect(abs(anywhere) < threshold / 2, "\(id)@5: \(anywhere)")
    }

    /// Over a race in every version-6 file, the share of lulls' footprint (where each changes the wind by more than
    /// 5 %) that live puffs' footprint covers too is under `threshold`, and well under version 5's, whose puffs and
    /// lulls form anywhere (at three times the coverage): they end up apart without a rule keeping them so.
    @Test(arguments: WindFixtures.ids)
    func lullsMostlyClearOfPuffs(id: String) throws {
        let threshold = 0.05
        func share(version: Int) throws -> Double {
            var covered = 0, total = 0
            for seed in Self.seeds {
                let setup = try PuffSpawnFixtures.setup(id, version: version, raceSeed: seed)
                let (field, _) = try WindFixtures.field(setup, windSeed: seed, through: PuffSpawnFixtures.race.upperBound)
                let across = try #require(field.puffPlan).acrossDownwind
                for tick in PuffSpawnFixtures.ticks(step: WindWindows.ticksPerWindow) {
                    let live = field.activePuffs(atTick: tick)
                    let puffs = live.filter { $0.strength > 0 }
                    for lull in live where lull.strength < 0 {
                        for p in PuffSpawnFixtures.footprint(lull, spacing: 10, across: across) {
                            total += 1
                            if puffs.contains(where: { $0.effect(at: p, across: across).speed > PuffPlan.coverageThreshold }) {
                                covered += 1
                            }
                        }
                    }
                }
            }
            #expect(total > 1000, "\(id)@\(version): \(total) points under lulls")
            return Double(covered) / Double(max(1, total))
        }
        let formed = try share(version: 6), anywhere = try share(version: 5)
        #expect(formed < threshold, "\(id): \(formed) of lulls' footprint under puffs")
        #expect(formed < anywhere / 3, "\(id): \(formed) vs \(anywhere) at version 5")
    }

    /// The puffs' coverage (grid points where the puffs and lulls alone change the wind by more than 5 %) over a
    /// race area comes out within `tolerance` of each version-6 file's `coverage`, a third or so of version 5's,
    /// though they gather where the field puts them.
    @Test(arguments: WindFixtures.ids)
    func coverageHolds(id: String) throws {
        let tolerance = 0.03
        var total = 0.0, count = 0
        var coverage = 0.0
        for seed in Self.seeds {
            let setup = try PuffSpawnFixtures.setup(id, raceSeed: seed)
            coverage = setup.conditions.puffs.coverage
            let (field, _) = try WindFixtures.field(setup, windSeed: seed, through: 45)
            let plan = try #require(field.puffPlan)
            let points = PuffFixtures.grid(try #require(setup.raceArea), spacing: 30)
            for window in 5..<45 {
                let tick = Self.w.start(of: window) + 150
                var covered = 0
                for p in points where abs(try field.puffEffect(at: p, tick: tick, plan).factor - 1) > PuffPlan.coverageThreshold {
                    covered += 1
                }
                total += Double(covered) / Double(points.count)
                count += 1
            }
        }
        let mean = total / Double(count)
        let old = try ConditionsFile.bundled(id: id, version: 5).content.puffs.coverage
        #expect(abs(mean - coverage) < tolerance, "\(id): coverage \(mean) vs \(coverage)")
        #expect(abs(coverage - old / 3) < 0.01, "\(id): \(coverage) vs version 5's \(old)")
    }

    /// Where a puff forms reads the field, so keys before its own: the same keys still give the same spawns whatever
    /// order they came in, a key changes no spawn of a window before its own, and the version-5 files (one choice)
    /// form their puffs where they always did, drawing nothing more.
    @Test func keyedWhateverTheOrder() throws {
        let setup = try PuffSpawnFixtures.setup("gusty-offshore", raceSeed: 7)
        #expect(setup.conditions.pressureField?.puffChoices == 3)
        let (field, _) = try WindFixtures.field(setup, windSeed: 7, through: 40)
        var shuffled = field.keys.keys
        var rng = SplitMix64(seed: 288)
        rng.shuffle(&shuffled)
        var added = WindField(setup: setup, windows: Self.w)
        for key in shuffled { added.add(key) }
        #expect(added == field)
        #expect(WindField(setup: setup, windows: Self.w, keys: WindKeyChain(shuffled)) == field)

        let (other, _) = try WindFixtures.field(setup, windSeed: 99, through: 40)
        let k = 20
        var keys = field.keys
        keys.insert(try #require(other.keys[k]))
        let changed = WindField(setup: setup, windows: Self.w, keys: keys)
        for window in 0..<k { #expect(changed.spawns(ofWindow: window) == field.spawns(ofWindow: window), "window \(window)") }
        #expect((k...40).contains { changed.spawns(ofWindow: $0) != field.spawns(ofWindow: $0) })

        // One choice: the plan's own spawns, as before #288.
        let old = try PuffSpawnFixtures.setup("gusty-offshore", version: 5, raceSeed: 7)
        #expect(old.conditions.pressureField?.puffChoices == 1)
        let (oldField, _) = try WindFixtures.field(old, windSeed: 7, through: 20)
        let plan = try #require(oldField.puffPlan)
        for window in 0...20 {
            #expect(oldField.spawns(ofWindow: window) == plan.spawns(of: try #require(oldField.keys[window]), windows: Self.w))
        }
    }

    /// The version-6 files are version 5 with `pressureField.puffChoices` and a third of the coverage (schema 5),
    /// pinned; schema 4 refuses the new column, schema 5 needs it, 1…8; dev-venue@6 is dev-venue@5 on them.
    @Test(arguments: PuffSpawnFixtures.version6Hashes.map(\.id))
    func version6FilesAreVersion5PlusPuffPlacement(id: String) throws {
        let v6 = try ConditionsFile.bundled(id: id, version: 6)
        #expect(v6.schemaVersion == 5 && v6.version == 6)
        #expect(v6.ref.hash.hex == PuffSpawnFixtures.version6Hashes.first { $0.id == id }?.hash)
        let before = try ConditionsFixtures.leaves(id, version: 5), after = try ConditionsFixtures.leaves(id, version: 6)
        let header = ["/version", "/schemaVersion", "/placeholders", "/notes"]
        let changed = Set(before.keys).union(after.keys)
            .filter { before[$0] != after[$0] }
            .filter { pointer in !header.contains { pointer == $0 || pointer.hasPrefix($0 + "/") } }
        #expect(changed == ["/puffs/coverage", "/pressureField/puffChoices"])
        #expect(v6.content.pressureField?.puffChoices == 3)
        #expect(try ConditionsFile.bundled(id: id, version: 5).content.pressureField?.puffChoices
                    == Conditions.PressureField.defaultPuffChoices)

        let text = String(decoding: try #require(try ConditionsFile.bundledData(id: id, version: 6)), as: UTF8.self)
        func refused(_ of: String, _ with: String) {
            #expect(text.contains(of), "\(of)")
            #expect(throws: DataFileError.self, "\(with)") { try ConditionsFile(data: Data(text.replacingOccurrences(of: of, with: with).utf8)) }
        }
        refused(#""schemaVersion": 5,"#, #""schemaVersion": 4,"#)
        refused(",\n    \"puffChoices\": 3", "")
        refused(#""puffChoices": 3"#, #""puffChoices": 0"#)
        refused(#""puffChoices": 3"#, #""puffChoices": 9"#)

        let venue = try GeographyFixtures.devVenue(6), was = try GeographyFixtures.devVenue(5)
        let pairing = try #require(venue.pairing(for: v6.ref.key))
        let old = try GeographyFixtures.devPairing(id, version: 5)
        #expect(pairing.geographicGrid == old.geographicGrid && pairing.sideTendency == old.sideTendency)
        #expect(pairing.meanDirection == old.meanDirection && pairing.startLineCentre == old.startLineCentre)
        #expect(venue.landmarks == was.landmarks && venue.land == was.land && venue.current == was.current)
    }
}
