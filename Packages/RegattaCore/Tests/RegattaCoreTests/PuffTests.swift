import Foundation
import Testing
@testable import RegattaCore

/// Keyed puffs and lulls (#76): each window's key spawns them from its `puffSeed` in the race area.
enum PuffFixtures {
    /// `id`'s setup with the race area a `Race` gives it until course derivation (#80): the placeholder
    /// around the standard course, laid square to the setup's mean direction.
    static func setup(_ id: String, raceSeed: UInt64 = 1) throws -> WindSetup {
        let drawn = try WindFixtures.setup(id, raceSeed: raceSeed)
        let course = Course.standard(axis: drawn.meanDirection, hullLength: Race.defaultBoatClass.hull.length)
        return drawn.with(raceArea: .placeholder(around: course))
    }

    /// Points `spacing` metres apart over `area`, cell centres.
    static func grid(_ area: RaceArea, spacing: Double) -> [Vec2] {
        let up = Vec2.heading(area.axis), right = up.rightPerp
        var points: [Vec2] = []
        var x = -area.halfWidth + spacing / 2
        while x < area.halfWidth {
            var y = -area.halfLength + spacing / 2
            while y < area.halfLength {
                points.append(area.centre + right * x + up * y)
                y += spacing
            }
            x += spacing
        }
        return points
    }

    /// The fraction of `points` where the wind speed at `tick` is more than 5 % off the course average.
    static func coverage(_ field: WindField, _ points: [Vec2], tick: Int) throws -> Double {
        let course = try field.courseAverageSpeed(atTick: tick)
        var covered = 0
        for p in points {
            if abs(try field.sample(p, tick: tick).speed / course - 1) > 0.05 { covered += 1 }
        }
        return Double(covered) / Double(points.count)
    }
}

@Suite struct PuffTests {
    static let w = WindFixtures.windows

    /// #76 acceptance 1: over 100 windows, the race area's mean coverage (grid points more than 5 % off
    /// the course-average speed) is 0.25–0.40, in the race's own conditions and race area.
    @Test func meanCoverageOverAHundredWindowsIsAQuarterToTwoFifths() throws {
        let setup = try PuffFixtures.setup("classic-oscillating", raceSeed: 2)
        #expect(setup.conditionsRef == Race.defaultConditions.ref)
        let (field, _) = try WindFixtures.field(setup, windSeed: 76, through: 104)
        let points = PuffFixtures.grid(try #require(setup.raceArea), spacing: 20)
        var total = 0.0
        // From window 5, once windows before the first have had a full lifetime to fill the water.
        for window in 5..<105 {
            total += try PuffFixtures.coverage(field, points, tick: Self.w.start(of: window) + 450)
        }
        let mean = total / 100
        #expect((0.25...0.40).contains(mean), "mean coverage \(mean)")
    }

    /// The spawn count is calibrated from each conditions' coverage, so every bundled conditions file
    /// comes out near its own.
    @Test func everyConditionsCoverageComesOutNearItsOwn() throws {
        for id in WindFixtures.ids {
            let setup = try PuffFixtures.setup(id, raceSeed: 9)
            let (field, _) = try WindFixtures.field(setup, windSeed: 9, through: 45)
            let points = PuffFixtures.grid(try #require(setup.raceArea), spacing: 30)
            var total = 0.0
            for window in 5..<45 { total += try PuffFixtures.coverage(field, points, tick: Self.w.start(of: window) + 300) }
            let mean = total / 40
            #expect(abs(mean - setup.conditions.puffs.coverage) < 0.06, "\(id): coverage \(mean)")
        }
    }

    /// #76 acceptance 2: a puff fans out as it lands. Looking downwind, the wind veers on its right and
    /// backs on its left, by at most the conditions' fan (8° in gusty offshore, the most of any) and so
    /// never more than 8°; a lull draws in, the other way. Checked on puffs no other puff reaches.
    @Test func puffEdgesRightAndLeftOfCentreTurnTheWindOppositeWaysWithinEightDegrees() throws {
        let setup = try PuffFixtures.setup("gusty-offshore", raceSeed: 3)
        let fan = setup.conditions.puffs.fan
        #expect(abs(fan - deg2rad(8)) < 1e-12)
        let (field, _) = try WindFixtures.field(setup, windSeed: 3, through: 40)
        let right = (-Vec2.heading(setup.meanDirection)).rightPerp
        var checked = (puffs: 0, lulls: 0)
        for tick in stride(from: Self.w.start(of: 5), to: Self.w.start(of: 40), by: 97) {
            let base = setup.meanDirection + (try field.shift(atTick: tick))
            let live = field.activePuffs(atTick: tick)
            for puff in live where puff.intensity / puff.strength > 0.5 {
                let edges = [puff.center + right * (puff.radius / 2), puff.center - right * (puff.radius / 2)]
                let alone = live.allSatisfy { other in
                    (other.center == puff.center && other.radius == puff.radius)
                        || edges.allSatisfy { (other.center - $0).length >= other.radius }
                }
                guard alone else { continue }
                let turns = try edges.map { wrapAngle(try field.sample($0, tick: tick).direction - base) }
                if puff.strength > 0 {
                    #expect(turns[0] > 0 && turns[1] < 0, "puff: right \(turns[0]), left \(turns[1])")
                    checked.puffs += 1
                } else {
                    #expect(turns[0] < 0 && turns[1] > 0, "lull: right \(turns[0]), left \(turns[1])")
                    checked.lulls += 1
                }
                #expect(abs(turns[0] + turns[1]) < 1e-9, "symmetric about the centre")
                #expect(turns.allSatisfy { abs($0) <= fan + 1e-12 })
            }
        }
        #expect(checked.puffs >= 20 && checked.lulls >= 5, "checked \(checked)")

        // Anywhere, overlaps included, the turn stays within the fan, and puffs do reach a good part of it.
        var rng = SplitMix64(seed: 76)
        var largest = 0.0
        let area = try #require(setup.raceArea)
        for _ in 0..<20_000 {
            let tick = rng.int(in: Self.w.start(of: 5)..<Self.w.start(of: 40))
            let p = area.centre + Vec2(rng.range(-area.halfWidth, area.halfWidth), rng.range(-area.halfLength, area.halfLength))
            let turn = wrapAngle(try field.sample(p, tick: tick).direction - setup.meanDirection - (try field.shift(atTick: tick)))
            #expect(abs(turn) <= fan + 1e-12)
            largest = max(largest, abs(turn))
        }
        #expect(largest > fan / 2, "largest turn \(rad2deg(largest))°")
    }

    /// #76 acceptance 3: a puff's centre drifts straight downwind (along the mean direction) at 0.3–0.5 ×
    /// the race's base wind speed.
    @Test func puffCentresDriftDownwindAtAThirdToAHalfOfBaseSpeed() throws {
        let setup = try PuffFixtures.setup("classic-oscillating", raceSeed: 5)
        let (field, _) = try WindFixtures.field(setup, windSeed: 5, through: 20)
        let downwind = -Vec2.heading(setup.meanDirection)
        func expectDownwindDrift(from a: Puff, to b: Puff) {
            let moved = b.center - a.center
            let rate = moved.dot(downwind) / (b.age - a.age) / setup.baseStrength
            #expect(rate >= 0.3 - 1e-9 && rate <= 0.5 + 1e-9, "drift \(rate) × base speed")
            #expect(abs(moved.cross(downwind)) < 1e-9, "straight downwind")
        }
        var count = 0
        for window in 1...20 {
            for spawn in field.spawns(ofWindow: window) {
                expectDownwindDrift(from: spawn.puff(atTick: spawn.spawnTick), to: spawn.puff(atTick: spawn.endTick))
                count += 1
            }
        }
        #expect(count > 100)

        // The same through `activePuffs`, which the renderer and bots read: the puffs alive a second apart.
        let tick = Self.w.start(of: 12) + 100
        let now = field.activePuffs(atTick: tick), later = field.activePuffs(atTick: tick + Race.tickRate)
        var matched = 0
        for a in now {
            guard let b = later.first(where: { $0.radius == a.radius && $0.strength == a.strength }) else { continue }
            expectDownwindDrift(from: a, to: b)
            #expect(b.velocity == a.velocity && abs(a.velocity.length / setup.baseStrength - 0.4) <= 0.1 + 1e-9)
            matched += 1
        }
        #expect(matched > 20)
    }

    /// #76 acceptance 4: a puff fades in from nothing and out to nothing: intensity 0 at its spawn tick and
    /// at the end of its life, and so no effect on the wind there, and at full strength mid-life.
    @Test func intensityIsZeroAtTheSpawnTickAndTheEndOfLife() throws {
        let setup = try PuffFixtures.setup("light-and-patchy", raceSeed: 6)
        let (field, _) = try WindFixtures.field(setup, windSeed: 6, through: 20)
        let right = (-Vec2.heading(setup.meanDirection)).rightPerp
        var count = 0
        for window in 1...20 {
            for spawn in field.spawns(ofWindow: window) {
                for tick in [spawn.spawnTick, spawn.endTick] {
                    let puff = spawn.puff(atTick: tick)
                    #expect(puff.intensity == 0)
                    let effect = puff.effect(at: puff.center + right * (puff.radius / 3), across: right)
                    #expect(effect.speed == 0 && effect.fan == 0)
                    // `activePuffs` includes it, at 0.
                    #expect(field.activePuffs(atTick: tick).contains { $0.center == puff.center && $0.intensity == 0 })
                }
                #expect(!field.activePuffs(atTick: spawn.spawnTick - 1).contains { $0.radius == spawn.radius && $0.strength == spawn.strength })
                #expect(!field.activePuffs(atTick: spawn.endTick + 1).contains { $0.radius == spawn.radius && $0.strength == spawn.strength })
                let next = spawn.puff(atTick: spawn.spawnTick + 1).intensity, last = spawn.puff(atTick: spawn.endTick - 1).intensity
                #expect(next != 0 && next.sign == spawn.strength.sign && abs(next - last) < 1e-12)
                let peak = spawn.puff(atTick: spawn.spawnTick + spawn.lifetimeTicks / 2).intensity
                #expect(abs(peak) >= abs(spawn.strength) * 0.999)
                count += 1
            }
        }
        #expect(count > 100)
    }

    /// #76 acceptance 5: no puff from window k affects any tick before window k starts (tick 900k on the
    /// window grid, `origin + 900k` on the race clock): every one spawns inside its window, and a
    /// different puff seed in key k, or no key k at all, leaves every earlier sample bit for bit the same.
    @Test func noPuffFromWindowKAffectsAnyTickBeforeWindowK() throws {
        let setup = try PuffFixtures.setup("gusty-offshore", raceSeed: 8)
        let (field, _) = try WindFixtures.field(setup, windSeed: 8, through: 30)
        let points = PuffFixtures.grid(try #require(setup.raceArea), spacing: 45)
        for k in [2, 5, 9, 17, 30] {
            let start = Self.w.start(of: k)
            #expect(field.spawns(ofWindow: k).allSatisfy { $0.spawnTick >= start && $0.spawnTick < Self.w.start(of: k + 1) })
            let key = try #require(field.keys[k])
            var reseeded = field
            reseeded.add(WindKey(window: k, shift: key.shift, strength: key.strength, wobble: key.wobble, puffSeed: ~key.puffSeed))
            #expect(reseeded.spawns(ofWindow: k) != field.spawns(ofWindow: k))
            var withoutK = field.keys
            withoutK.remove(window: k)
            for later in (k + 1)..<31 { withoutK.remove(window: later) }
            let truncated = WindField(setup: setup, windows: Self.w, keys: withoutK)
            for tick in Array(stride(from: max(Self.w.start(of: 1), start - 3 * WindWindows.ticksPerWindow), to: start, by: 37)) + [start - 1] {
                for p in points {
                    let a = try field.sample(p, tick: tick)
                    for b in [try reseeded.sample(p, tick: tick), try truncated.sample(p, tick: tick)] {
                        #expect(a.speed.bitPattern == b.speed.bitPattern && a.direction.bitPattern == b.direction.bitPattern)
                    }
                }
            }
            // It does act once its window starts.
            var differs = false
            for tick in stride(from: start, to: Self.w.start(of: k + 1), by: 60) where !differs {
                differs = try points.contains { try field.sample($0, tick: tick) != reseeded.sample($0, tick: tick) }
            }
            #expect(differs)
        }
    }

    /// #76 acceptance 6: puffs are a pure function of the keys, so any sampling order gives the same answers,
    /// and so does adding the keys in any order.
    @Test func shuffledSamplingEqualsOrderedSamplingWithPuffs() throws {
        let setup = try PuffFixtures.setup("classic-oscillating", raceSeed: 12)
        let (field, _) = try WindFixtures.field(setup, windSeed: 12, through: 60)
        let area = try #require(setup.raceArea)
        var rng = SplitMix64(seed: 76)
        let samples = (0..<3000).map { _ in
            (p: area.centre + Vec2(rng.range(-area.halfWidth, area.halfWidth), rng.range(-area.halfLength, area.halfLength)),
             tick: rng.int(in: Self.w.start(of: 1)..<Self.w.start(of: 61)))
        }
        let ordered = try samples.map { try field.sample($0.p, tick: $0.tick) }
        var puffed = 0
        for (sample, wind) in zip(samples, ordered) {
            if wind.speed != (try field.courseAverageSpeed(atTick: sample.tick)) { puffed += 1 }
        }
        #expect(puffed > 500, "puffs present in \(puffed) of 3000 samples")
        var order = Array(samples.indices)
        rng.shuffle(&order)
        var shuffledKeys = field.keys.keys
        rng.shuffle(&shuffledKeys)
        let rebuilt = WindField(setup: setup, windows: Self.w, keys: WindKeyChain(shuffledKeys))
        #expect(rebuilt == field)
        var added = WindField(setup: setup, windows: Self.w)
        for key in shuffledKeys { added.add(key) }
        #expect(added == field)
        for i in order {
            for other in [field, rebuilt, added] {
                let again = try other.sample(samples[i].p, tick: samples[i].tick)
                #expect(again.direction.bitPattern == ordered[i].direction.bitPattern)
                #expect(again.speed.bitPattern == ordered[i].speed.bitPattern)
            }
        }
    }

    /// A puff alive at a tick may come from a window up to ⌈longest life / 30 s⌉ back, so the wind there
    /// needs every key from that window on, and says which one it lacks rather than guess (ADR 0001).
    @Test func samplingNeedsTheKeysOfEveryPuffThatMayStillBeAlive() throws {
        let setup = try PuffFixtures.setup("classic-oscillating", raceSeed: 4)
        let (field, _) = try WindFixtures.field(setup, windSeed: 4, through: 20)
        let k = 12, tick = Self.w.start(of: k)
        let p = try #require(setup.raceArea).centre
        // Longest life 90 s: three windows back.
        #expect(field.firstWindowNeeded(atTick: tick) == k - 3)
        #expect(field.firstWindowNeeded(atTick: Self.w.start(of: 2)) == 0)
        #expect(WindField(setup: try WindFixtures.setup("classic-oscillating"), windows: Self.w).firstWindowNeeded(atTick: tick) == k - 1)
        func dropping(_ window: Int) -> WindField {
            var keys = field.keys
            keys.remove(window: window)
            return WindField(setup: setup, windows: Self.w, keys: keys)
        }
        for window in (k - 3)...k {
            #expect(throws: WindFieldError.missingKey(window)) { try dropping(window).sample(p, tick: tick) }
            #expect(throws: WindFieldError.missingKey(window)) { try dropping(window).requireKeys(atTick: tick) }
        }
        _ = try dropping(k - 4).sample(p, tick: tick)
        try dropping(k - 4).requireKeys(atTick: tick)
        // The fleet-wide channels still need only keys k − 1 and k.
        _ = try dropping(k - 3).courseAverageSpeed(atTick: tick)
        // Some puff from window k − 3 is alive in window k: the lookback is needed.
        #expect(field.spawns(ofWindow: k - 3).contains { $0.endTick >= tick })
    }

    /// A race attaches the placeholder race area until course derivation (#80), so its wind has puffs.
    @Test func aRaceHasPuffsInItsPlaceholderRaceArea() throws {
        let race = Race(setup: try RaceSetup(raceSeed: RaceSeed(76), seats: [.human, .bot]), windSeed: WindSeed(76))
        let course = Course.standard(laps: race.setup.laps, axis: race.windSetup.meanDirection,
                                     hullLength: race.boatClass.hull.length)
        #expect(race.windSetup.raceArea == .placeholder(around: course))
        for _ in 0..<(4 * WindWindows.ticksPerWindow) { race.step() }
        #expect(race.wind.activePuffs(atTick: race.tick).count > 20)
        let area = try #require(race.windSetup.raceArea)
        #expect(area.halfLength >= 300 && area.halfWidth >= 250)
        #expect(race.course.marks.allSatisfy { m in
            let offset = m.position - area.centre
            return abs(offset.dot(course.upwind)) < area.halfLength && abs(offset.dot(course.right)) < area.halfWidth
        })
    }
}
