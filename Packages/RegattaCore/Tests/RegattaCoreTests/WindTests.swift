import Foundation
import Testing
@testable import RegattaCore

/// The keyed wind (#75, ADR 0001): key chain, Hermite knots and `WindField`.
enum WindFixtures {
    static let ids = ["light-and-patchy", "classic-oscillating", "sea-breeze", "gusty-offshore"]
    /// The default 60 s sequence: origin −2700, the race starts in window 1.
    static let windows = WindWindows(startSequenceTicks: 60 * Race.tickRate)
    static let seeds: [UInt64] = (0..<200).map { UInt64($0) &* 0x9E37_79B9_7F4A_7C15 ^ 0xD1CE }

    static func setup(_ id: String, raceSeed: UInt64 = 1, pairing: VenuePairing = .stub) throws -> WindSetup {
        WindSetup(conditions: try ConditionsFile.bundled(id: id, version: 2), pairing: pairing, raceSeed: RaceSeed(raceSeed))
    }

    static func generator(_ setup: WindSetup, windSeed: UInt64) throws -> WindKeyGenerator {
        try WindKeyGenerator(windSeed: WindSeed(windSeed), setup: setup, windows: windows)
    }

    /// A field holding keys 0…`window`, and the generator that made them.
    static func field(_ setup: WindSetup, windSeed: UInt64, through window: Int) throws -> (WindField, WindKeyGenerator) {
        var generator = try generator(setup, windSeed: windSeed)
        let field = WindField(setup: setup, windows: windows, keys: WindKeyChain(generator.keys(through: window)))
        return (field, generator)
    }

    /// A field holding keys 0…`window`, and the parts each key's knots are the sum of, by window.
    static func parts(_ setup: WindSetup, windSeed: UInt64, through window: Int) throws -> (WindField, [WindKeyGenerator.Parts]) {
        var generator = try generator(setup, windSeed: windSeed)
        var parts: [WindKeyGenerator.Parts] = []
        while generator.nextWindow <= window { parts.append(generator.nextParts()) }
        return (WindField(setup: setup, windows: windows, keys: WindKeyChain(parts.map(\.key))), parts)
    }
}

@Suite struct WindKeyDerivationTests {
    /// Computed independently with Python: `hmac.new(seed.to_bytes(8, "big"), k.to_bytes(8, "big"), hashlib.sha256)`.
    static let knownAnswers: [(seed: UInt64, window: Int, hex: String)] = [
        (0x0123_4567_89AB_CDEF, 0, "6eb9720035d2e8e3df59515a267fa44560d41f1e3a2a71e183719e5c7b9f39a7"),
        (0x0123_4567_89AB_CDEF, 7, "d0bb0edb1d0cd85b431c9813ac5b5a874bd0f2d348c45547261fd5a3014b6093"),
        (0xD1CE_0000_0059_0002, 1, "413a6086c85a45d0b9e19cbb3f76d84ffb9c091a7326e9876e2eaef5af493852"),
        (0xFFFF_FFFF_FFFF_FFFF, 1000, "dfbeb2f1b8ccc390762169ed9c70e82a4cef5ad1a0ec3001d84c90bd98266500"),
    ]

    @Test func keyMaterialMatchesHMACSHA256KnownAnswers() throws {
        for vector in Self.knownAnswers {
            let expected = try #require(ContentHash(hex: vector.hex)).bytes
            #expect(WindKeyGenerator.material(windSeed: WindSeed(vector.seed), window: vector.window) == expected)
        }
    }

    /// The puff seed is the first 8 bytes of the key's material, big-endian.
    @Test func puffSeedIsTheMaterialsFirstEightBytes() throws {
        let setup = try WindFixtures.setup("classic-oscillating")
        var generator = try WindFixtures.generator(setup, windSeed: 0x0123_4567_89AB_CDEF)
        let keys = generator.keys(through: 7)
        #expect(keys[0].puffSeed == 0x6EB9_7200_35D2_E8E3)
        #expect(keys[7].puffSeed == 0xD0BB_0EDB_1D0C_D85B)
    }

    @Test func sameSeedGivesIdenticalChainBytesAndDifferentSeedsDiffer() throws {
        for id in WindFixtures.ids {
            let setup = try WindFixtures.setup(id)
            let a = try WindFixtures.field(setup, windSeed: 42, through: 63).0.keys
            let b = try WindFixtures.field(setup, windSeed: 42, through: 63).0.keys
            let c = try WindFixtures.field(setup, windSeed: 43, through: 63).0.keys
            #expect(a.bytes == b.bytes)
            #expect(a.bytes.count == 64 * WindKey.byteCount)
            #expect(a.bytes != c.bytes)
            for k in 0..<64 {
                #expect(a[k]?.shift != c[k]?.shift && a[k]?.puffSeed != c[k]?.puffSeed)
            }
        }
    }

    /// Key k depends only on the keys up to k: making more keys never changes an earlier one.
    @Test func keysArePrefixStable() throws {
        let setup = try WindFixtures.setup("sea-breeze", raceSeed: 5)
        var long = try WindFixtures.generator(setup, windSeed: 9)
        var short = try WindFixtures.generator(setup, windSeed: 9)
        let longKeys = long.keys(through: 100)
        let shortKeys = short.keys(through: 10)
        #expect(Array(longKeys.prefix(11)) == shortKeys)
        #expect(short.nextWindow == 11)
        #expect(short.keys(through: 5).isEmpty)
        #expect(short.next() == longKeys[11])
    }

    @Test func keyBytesRoundTrip() throws {
        let setup = try WindFixtures.setup("sea-breeze", raceSeed: 3)
        let (field, _) = try WindFixtures.field(setup, windSeed: 77, through: 40)
        for key in field.keys.keys {
            #expect(key.bytes.count == WindKey.byteCount)
            #expect(WindKey(bytes: key.bytes) == key)
        }
        let key = try #require(field.keys[3])
        #expect(Array(key.bytes.prefix(8)) == [0, 0, 0, 0, 0, 0, 0, 3])
        #expect(WindKey(bytes: Array(key.bytes.dropLast())) == nil)
        #expect(WindKey(bytes: [0xFF] + key.bytes.dropFirst()) == nil, "negative window")
        var nan = key.bytes
        nan.replaceSubrange(8..<16, with: [0x7F, 0xF8, 0, 0, 0, 0, 0, 0])
        #expect(WindKey(bytes: nan) == nil)
    }

    @Test func generatorRefusesSchema1Conditions() throws {
        let file = try ConditionsFile.bundled(id: "classic-oscillating", version: 1)
        let setup = WindSetup(conditions: file, pairing: .stub, raceSeed: RaceSeed(1))
        #expect(throws: WindKeyGeneratorError.conditionsPredateKeyedWind(file.ref)) {
            try WindKeyGenerator(windSeed: WindSeed(1), setup: setup, windows: WindFixtures.windows)
        }
    }
}

@Suite struct WindWindowsTests {
    @Test func defaultSequenceStartsInWindowOneWithKnotsOnWholeWindowsFromTheGun() {
        let w = WindFixtures.windows
        #expect(w.origin == -2700)
        #expect(w.window(containing: -1800) == 1)
        #expect(w.start(of: 1) == -1800)
        #expect(w.knotTick(of: 0) == -1800)
        #expect(w.window(containing: 0) == 3 && w.start(of: 3) == 0, "the gun is a knot")
        #expect(w.window(containing: 899) == 3 && w.window(containing: 900) == 4)
        #expect(w.window(containing: -2700) == 0)
        #expect(w.window(containing: -2701) == -1)
        #expect(w.window(containing: -3600) == -1 && w.window(containing: -3601) == -2)
    }

    @Test(arguments: [1, 90, 899, 900, 901, 1799, 1800, 1801, 2700, 5000])
    func raceAlwaysStartsInWindowOne(startSequenceTicks: Int) {
        let w = WindWindows(startSequenceTicks: startSequenceTicks)
        #expect(w.window(containing: -startSequenceTicks) == 1)
        #expect(w.origin % WindWindows.ticksPerWindow == 0)
        #expect(w.start(of: 1) <= -startSequenceTicks)
    }
}

@Suite struct WindFieldTests {
    /// #75 acceptance: the shift is C1-continuous at every knot, and the knot is exactly the key's.
    @Test(arguments: WindFixtures.ids)
    func shiftIsC1ContinuousAtEveryKnot(id: String) throws {
        for seed in WindFixtures.seeds.prefix(10) {
            let setup = try WindFixtures.setup(id, raceSeed: seed)
            let (field, _) = try WindFixtures.field(setup, windSeed: seed, through: 200)
            for k in 0..<200 {
                let left = try field.channels(window: k, fraction: 1)
                let right = try field.channels(window: k + 1, fraction: 0)
                #expect(abs(left.shift - right.shift) < 1e-9)
                #expect(abs(left.shiftSlope - right.shiftSlope) < 1e-9)
                #expect(abs(left.strength - right.strength) < 1e-9)
                #expect(abs(left.strengthSlope - right.strengthSlope) < 1e-9)
                let knot = try #require(field.keys[k])
                // The value exactly; the slope to rounding (it passes through × and ÷ the window length).
                #expect(right.shift == knot.shift.value && abs(right.shiftSlope - knot.shift.slope) < 1e-15)
                #expect(right.strength == knot.strength.value && abs(right.strengthSlope - knot.strength.slope) < 1e-15)
            }
        }
    }

    /// #75 acceptance: window k needs keys k − 1 and k, and nothing is extrapolated without them.
    @Test func samplingNeedsKeysUpToItsWindowAndNeverExtrapolates() throws {
        let setup = try WindFixtures.setup("gusty-offshore")
        let w = WindFixtures.windows
        let k = 12
        let (field, _) = try WindFixtures.field(setup, windSeed: 5, through: k)
        let p = Vec2(10, 200)
        for tick in stride(from: w.start(of: k), to: w.start(of: k + 1), by: 7) {
            _ = try field.sample(p, tick: tick)
        }
        #expect(throws: WindFieldError.missingKey(k + 1)) { try field.sample(p, tick: w.start(of: k + 1)) }

        func dropping(_ window: Int) -> WindField {
            var keys = field.keys
            keys.remove(window: window)
            return WindField(setup: setup, windows: w, keys: keys)
        }
        let withoutK = dropping(k)
        #expect(throws: WindFieldError.missingKey(k)) { try withoutK.sample(p, tick: w.start(of: k)) }
        #expect(throws: WindFieldError.missingKey(k)) { try withoutK.sample(p, tick: w.start(of: k + 1) - 1) }
        _ = try withoutK.sample(p, tick: w.start(of: k) - 1) // window k − 1 still has its keys

        let withoutPrevious = dropping(k - 1)
        #expect(throws: WindFieldError.missingKey(k - 1)) { try withoutPrevious.sample(p, tick: w.start(of: k)) }
        #expect(throws: WindFieldError.missingKey(k - 1)) { try withoutPrevious.sample(p, tick: w.start(of: k) - 1) }

        // Window 0 starts from the fixed first knot, so it needs only key 0.
        let onlyFirst = WindField(setup: setup, windows: w, keys: WindKeyChain([try #require(field.keys[0])]))
        _ = try onlyFirst.sample(p, tick: w.origin)
        #expect(try onlyFirst.shift(atTick: w.origin) == 0)
        #expect(throws: WindFieldError.beforeOrigin(tick: w.origin - 1)) { try onlyFirst.sample(p, tick: w.origin - 1) }
        #expect(throws: WindFieldError.missingKey(0)) { try WindField(setup: setup, windows: w).sample(p, tick: w.origin) }
    }

    /// #75 acceptance: sampling is pure, so any order gives the same answers, and so does adding keys in any order.
    @Test func shuffledOrderSamplingEqualsOrderedSampling() throws {
        let setup = try WindFixtures.setup("sea-breeze", raceSeed: 11)
        let (field, _) = try WindFixtures.field(setup, windSeed: 11, through: 60)
        let w = WindFixtures.windows
        var rng = SplitMix64(seed: 75)
        let samples = (0..<3000).map { _ in
            (p: Vec2(rng.range(-500, 500), rng.range(-300, 900)), tick: rng.int(in: w.start(of: 1)..<w.start(of: 61)))
        }
        let ordered = try samples.map { try field.sample($0.p, tick: $0.tick) }
        var order = Array(samples.indices)
        rng.shuffle(&order)
        var shuffledKeys = field.keys.keys
        rng.shuffle(&shuffledKeys)
        let rebuilt = WindField(setup: setup, windows: w, keys: WindKeyChain(shuffledKeys))
        #expect(rebuilt == field)
        for i in order {
            let again = try rebuilt.sample(samples[i].p, tick: samples[i].tick)
            #expect(again.direction.bitPattern == ordered[i].direction.bitPattern)
            #expect(again.speed.bitPattern == ordered[i].speed.bitPattern)
        }
    }

    /// The base shift is fleet-wide: the same everywhere at a tick (ADR 0001).
    @Test func baseWindIsTheSameEverywhereAtATick() throws {
        let setup = try WindFixtures.setup("classic-oscillating", raceSeed: 2)
        let (field, _) = try WindFixtures.field(setup, windSeed: 2, through: 10)
        for tick in stride(from: -1800, to: 5000, by: 131) {
            let a = try field.sample(Vec2(-400, -200), tick: tick)
            let b = try field.sample(Vec2(350, 600), tick: tick)
            #expect(a == b)
            #expect(abs(wrapAngle(a.direction - setup.meanDirection - (try field.shift(atTick: tick)))) < 1e-12)
        }
        #expect(field.activePuffs(atTick: 0).isEmpty, "no puffs until #76")
    }

    /// The wobble moves the shift within a window: at the middle it adds exactly the hump.
    @Test func wobbleActsMidWindowAndVanishesAtKnots() throws {
        let setup = try WindFixtures.setup("gusty-offshore", raceSeed: 4)
        let (field, _) = try WindFixtures.field(setup, windSeed: 4, through: 50)
        var moved = 0
        for k in 1...50 {
            let from = try #require(field.keys[k - 1]), key = try #require(field.keys[k])
            let mid = try field.channels(window: k, fraction: 0.5)
            let smooth = WindField.hermite(from.shift, key.shift, 0.5)
            #expect(abs(mid.shift - smooth.value - key.wobble.hump) < 1e-12)
            #expect(abs(key.wobble.hump) <= setup.conditions.keyedWind!.wobble / 2)
            #expect(abs(key.wobble.wiggle) <= setup.conditions.keyedWind!.wobble / 2)
            if abs(key.wobble.hump) > 1e-4 { moved += 1 }
            let atKnot = WindField.wobble(key.wobble, 0)
            #expect(atKnot.value == 0 && atKnot.slope == 0)
        }
        #expect(moved > 40)
    }

    /// #75 acceptance, per conditions over 2000 windows: the oscillating shift peaks within 1.2 × the
    /// amplitude, and its mean period is within the conditions' range ± 15 %.
    @Test(arguments: WindFixtures.ids)
    func oscillationKeepsItsAmplitudeAndPeriodOver2000Windows(id: String) throws {
        let windowCount = 2000
        for seed in WindFixtures.seeds.prefix(3) {
            let setup = try WindFixtures.setup(id, raceSeed: seed)
            let (field, parts) = try WindFixtures.parts(setup, windSeed: seed, through: windowCount)
            let c = setup.conditions
            var peak = 0.0
            for k in 1...windowCount {
                let start = field.windows.start(of: k)
                for tick in stride(from: start, to: field.windows.start(of: k + 1), by: 3) {
                    // Take away the trend's own curve between its knots: the rest is the oscillation and wobble.
                    let s = Double(tick - start) / Double(WindWindows.ticksPerWindow)
                    let trend = WindField.hermite(parts[k - 1].trend, parts[k].trend, s).value
                    peak = max(peak, abs(try field.shift(atTick: tick) - trend))
                }
            }
            #expect(peak <= c.shift.amplitude * 1.2, "\(id): peak \(rad2deg(peak))°")
            #expect(peak >= c.shift.amplitude * 0.9, "\(id): the oscillation reaches its amplitude")

            // Sign changes of the oscillation at the knots: at most one per window, since half a period is over 30 s.
            var crossings = 0
            for k in 1...windowCount where (parts[k - 1].oscillation.value < 0) != (parts[k].oscillation.value < 0) {
                crossings += 1
            }
            let meanPeriod = 2 * Double(windowCount) * WindWindows.seconds / Double(crossings)
            #expect(meanPeriod >= c.shift.period.lowerBound * 0.85 && meanPeriod <= c.shift.period.upperBound * 1.15,
                    "\(id): mean period \(meanPeriod) s")
        }
    }

    /// #75 acceptance: sea breeze drifts 5–15° toward its trend over the 16 minutes from the gun; the
    /// other conditions average out within 2°.
    @Test func seaBreezeDriftsTowardItsTrendAndTheOthersAverageOut() throws {
        let span = 960 * Race.tickRate
        var lefts = 0, rights = 0
        var paces: [Double] = []
        for seed in WindFixtures.seeds {
            let pairing = VenuePairing(meanDirection: 0, trend: .either)
            let setup = try WindFixtures.setup("sea-breeze", raceSeed: seed, pairing: pairing)
            let direction = try #require(setup.trend)
            if direction == .left { lefts += 1 } else { rights += 1 }
            let (field, parts) = try WindFixtures.parts(setup, windSeed: seed ^ 0xABCD, through: 120)
            let w = field.windows

            // The trend part alone: none up to the gun, then exactly the drawn size over the span,
            // never turning back, even between knots.
            let atGun = parts[w.window(containing: 0) - 1], atSpanEnd = parts[w.window(containing: span) - 1]
            #expect(w.knotTick(of: atGun.key.window) == 0 && w.knotTick(of: atSpanEnd.key.window) == span)
            #expect(parts.prefix(atGun.key.window + 1).allSatisfy { $0.trend == WindKnot(value: 0, slope: 0) })
            let net = direction.sign * atSpanEnd.trend.value
            #expect(net >= deg2rad(5) - 1e-12 && net <= deg2rad(15) + 1e-12)
            for k in 1..<parts.count {
                var previous = direction.sign * parts[k - 1].trend.value
                for step in 1...30 {
                    let now = direction.sign * WindField.hermite(parts[k - 1].trend, parts[k].trend, Double(step) / 30).value
                    #expect(now >= previous - 1e-12 && now <= net + 1e-12)
                    previous = now
                }
            }
            // The pace is keyed per window: the slope in whole windows of the ramp varies.
            let rampSlopes = parts.map { abs($0.trend.slope) }.filter { $0 > 0 }
            if let fastest = rampSlopes.max(), let slowest = rampSlopes.min() { paces.append(fastest / slowest) }

            // As sailed: after the span the wind sits 5–15° toward the trend on average.
            var sum = 0.0, count = 0
            for tick in stride(from: span, to: span + 1200 * Race.tickRate, by: 10) {
                sum += try field.shift(atTick: tick)
                count += 1
            }
            let settled = direction.sign * sum / Double(count)
            #expect(settled >= deg2rad(4.5) && settled <= deg2rad(15.5), "settled at \(rad2deg(settled))°")
        }
        #expect(lefts > 50 && rights > 50)
        #expect(paces.filter { $0 > 1.5 }.count > paces.count / 2, "the trend's pace changes from window to window")

        for id in ["light-and-patchy", "classic-oscillating", "gusty-offshore"] {
            for seed in WindFixtures.seeds {
                let setup = try WindFixtures.setup(id, raceSeed: seed)
                let (field, _) = try WindFixtures.field(setup, windSeed: seed, through: 40)
                var sum = 0.0, count = 0
                for tick in stride(from: 0, to: span, by: 10) {
                    sum += try field.shift(atTick: tick)
                    count += 1
                }
                #expect(abs(sum / Double(count)) < deg2rad(2), "\(id) mean \(rad2deg(sum / Double(count)))°")
            }
        }
    }

    /// The sea breeze's build never takes the wind above the forecast's top strength (#10: the forecast
    /// is never wrong), and conditions with no build keep the base strength.
    @Test func strengthStaysInTheForecastRange() throws {
        var capped = 0
        for seed in WindFixtures.seeds {
            let setup = try WindFixtures.setup("sea-breeze", raceSeed: seed)
            let (field, parts) = try WindFixtures.parts(setup, windSeed: seed, through: 80)
            let range = setup.conditions.strength
            let headroom = range.upperBound / setup.baseStrength - 1
            for tick in stride(from: -1800, to: 1200 * Race.tickRate, by: 29) {
                let speed = try field.sample(.zero, tick: tick).speed
                #expect(speed <= range.upperBound)
                #expect(speed >= setup.baseStrength * (1 - 1e-12), "the build only rises")
            }
            let rise = parts[field.windows.window(containing: 960 * Race.tickRate) - 1].build.value
            #expect(rise >= 0 && rise <= 0.15 && rise <= headroom + 1e-12)
            #expect(parts.allSatisfy { $0.build.value <= rise })
            if rise >= headroom - 1e-12 { capped += 1 }
        }
        #expect(capped > 0, "some bases near the top have their build capped")

        let setup = try WindFixtures.setup("classic-oscillating", raceSeed: 8)
        let (field, _) = try WindFixtures.field(setup, windSeed: 8, through: 20)
        for tick in stride(from: -1800, to: 15000, by: 97) {
            #expect(try field.sample(.zero, tick: tick).speed == setup.baseStrength)
        }
    }

}

@Suite struct RaceWindTests {
    /// The race makes each key as its window starts: it holds keys through the current window, never
    /// the next one, and never misses one (practice and replay hold the wind seed).
    @Test func raceHoldsKeysExactlyThroughTheCurrentWindow() {
        let race = testRace(opponents: 1, prestartSeconds: 60, seed: 3, brains: [])
        #expect(race.wind.keys.endWindow == 2)
        for _ in 0..<(4 * WindWindows.ticksPerWindow + 17) {
            race.step()
            #expect(race.wind.keys.endWindow == race.wind.windows.window(containing: race.tick) + 1)
        }
    }

    @Test func raceWindIsTheKeyedFieldOfItsWindSeed() throws {
        let race = testRace(opponents: 3, prestartSeconds: 60, seed: 12)
        for _ in 0..<2000 { race.step() }
        var generator = try WindKeyGenerator(windSeed: race.windSeed, setup: race.windSetup, windows: race.wind.windows)
        #expect(race.wind.keys == WindKeyChain(generator.keys(through: race.wind.keys.endWindow - 1)))
        for boat in race.boats {
            let wind = try race.wind.sample(boat.position, tick: race.tick)
            #expect(boat.windDirection == wind.direction && boat.windSpeed == wind.speed)
            #expect(race.groundWind(at: boat.position) == wind)
        }
        #expect(race.windSetup.conditionsRef == Race.defaultConditions.ref)
        #expect(race.course.axis == race.windSetup.meanDirection, "the course is square to the mean direction")
    }

    /// A long race keeps making keys: well past the 16-minute time limit, the wind never runs out.
    @Test func raceWindNeverRunsOut() {
        let race = testRace(opponents: 1, prestartSeconds: 60, seed: 21, brains: [])
        for _ in 0..<(40 * 60 * Race.tickRate) where !race.isOver { race.step() }
        #expect(race.wind.keys.endWindow == race.wind.windows.window(containing: race.tick) + 1)
    }
}
