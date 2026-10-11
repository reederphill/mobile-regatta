import Foundation
import Testing
@testable import RegattaCore

/// skiff@9 (#462): skiff@8 with the planing rule's stay-on speed share and apparent wind.
enum SkiffNine {
    static let file = try! BoatClassFile.bundled(id: "skiff", version: 9)
    static var boatClass: BoatClass { file.content }
}

/// #462: the planing rule (`PlaningTuning.isPlaning(was:twa:speed:tws:rudder:polar:)`), each of its tests on and off.
@Suite struct PlaningRuleTests {
    static let knot = metresPerSecond(knots: 1)
    let polar = SkiffNine.boatClass.polar
    let rule = SkiffNine.boatClass.planing!

    /// The rule before #462, copied: what a class without the new values must still answer, bit for bit.
    static func ruleBefore(_ p: BoatClass.PlaningTuning, was: Bool, twa: Double, speed: Double, tws: Double) -> Bool {
        if was { return twa >= p.offBelowTWA && speed >= p.offSpeed }
        guard twa >= p.fromTWA && speed >= p.onSpeed else { return false }
        return BoatClass.PlaningTuning.apparentWindCosine(twa: twa, speed: speed, tws: tws) >= RegattaCore.cos(p.onMaxAWA)
    }

    func planes(_ rule: BoatClass.PlaningTuning? = nil, was: Bool, twa: Double, knots: Double, tws: Double, rudder: Double = 0) -> Bool {
        (rule ?? self.rule).isPlaning(was: was, twa: deg2rad(twa), speed: knots * Self.knot, tws: tws * Self.knot, rudder: rudder,
                                      polar: polar)
    }

    func apparentKnots(twa: Double, knots: Double, tws: Double) -> Double {
        BoatClass.PlaningTuning.apparentWindSpeed(twa: deg2rad(twa), speed: knots * Self.knot, tws: tws * Self.knot) / Self.knot
    }

    func apparentIsAft(twa: Double, knots: Double, tws: Double) -> Bool {
        BoatClass.PlaningTuning.apparentWindCosine(twa: deg2rad(twa), speed: knots * Self.knot, tws: tws * Self.knot) < 0
    }

    /// Every class before skiff@9, and skiff@9 with the two values taken out, answers as the rule before #462 did on
    /// 100,000 random inputs each, whatever the rudder.
    @Test func withoutTheNewValuesItIsTheRuleBefore() throws {
        var rules = try (1...8).map { try #require(try BoatClassFile.bundled(id: "skiff", version: $0).content.planing) }
        var stripped = rule
        stripped.stayOnSpeedShare = nil
        stripped.apparentWind = nil
        rules.append(stripped)
        var random = SplitMix64(seed: 462)
        for (index, rule) in rules.enumerated() {
            #expect(rule.stayOnSpeedShare == nil && rule.apparentWind == nil)
            var differ = 0
            for _ in 0..<100_000 {
                let was = random.bool()
                let twa = random.range(0, .pi), speed = random.range(0, 12), tws = random.range(0, 14)
                let rudder = random.range(-1, 1)
                if rule.isPlaning(was: was, twa: twa, speed: speed, tws: tws, rudder: rudder, polar: polar)
                    != Self.ruleBefore(rule, was: was, twa: twa, speed: speed, tws: tws) { differ += 1 }
            }
            #expect(differ == 0, "rule \(index + 1)")
        }
    }

    /// The speed share: on the plane at 150° in 10 kn (the polar's 11.8 kn) she drops off at 8 kn, 0.68 of it, with the
    /// apparent wind aft of the beam; at 8.5 kn, 0.72, she stays. A class without the share stays on at both.
    @Test func speedShareDropsHerBelowItsShareOfThePolar() {
        #expect(apparentIsAft(twa: 150, knots: 8, tws: 10) && apparentKnots(twa: 150, knots: 8, tws: 10) > 4.5)
        // Full rudder throughout: the apparent wind's own test is out of it.
        #expect(!planes(was: true, twa: 150, knots: 8, tws: 10, rudder: 1))
        #expect(planes(was: true, twa: 150, knots: 8.5, tws: 10, rudder: 1))
        var without = rule
        without.stayOnSpeedShare = nil
        #expect(planes(without, was: true, twa: 150, knots: 8, tws: 10, rudder: 1))
    }

    /// The share is asked only with the apparent wind aft of `onMaxAWA`: at 110° in 10 kn (the polar's 12.4 kn) 8.5 kn
    /// is 0.69 of it, but the apparent wind is forward of the beam, where she would get on the plane anyway, so she
    /// stays on it (no flicker on the way back up to speed).
    @Test func speedShareIsNotAskedWithTheApparentWindForward() {
        #expect(!apparentIsAft(twa: 110, knots: 8.5, tws: 10))
        #expect(8.5 * Self.knot < 0.7 * polar.speed(twa: deg2rad(110), tws: 10 * Self.knot))
        #expect(planes(was: true, twa: 110, knots: 8.5, tws: 10))
        #expect(planes(was: false, twa: 110, knots: 8.5, tws: 10))
        // Aft of a narrower limit the same boat drops off.
        var narrow = rule
        narrow.onMaxAWA = deg2rad(30)
        #expect(!planes(narrow, was: true, twa: 110, knots: 8.5, tws: 10))
    }

    /// The apparent wind: at 170° in 10 kn at 9 kn she has under 2 kn of it. With the rudder centred, or within 0.2
    /// of centre, she drops off; with it further over (a gybe sailed through) she stays on. A class without the value
    /// stays on.
    @Test func apparentWindDropsHerOnlyWithTheRudderNearCentre() {
        #expect(apparentKnots(twa: 170, knots: 9, tws: 10) < 2)
        #expect(9 * Self.knot >= polar.speed(twa: deg2rad(170), tws: 10 * Self.knot), "the speed share is out of it")
        for rudder in [0, 0.1, -0.2, 0.2] { #expect(!planes(was: true, twa: 170, knots: 9, tws: 10, rudder: rudder), "\(rudder)") }
        for rudder in [0.25, -0.35, 0.5, 1] { #expect(planes(was: true, twa: 170, knots: 9, tws: 10, rudder: rudder), "\(rudder)") }
        var without = rule
        without.apparentWind = nil
        #expect(planes(without, was: true, twa: 170, knots: 9, tws: 10))
        var always = rule
        always.apparentWind?.rudderWithin = 1
        #expect(!planes(always, was: true, twa: 170, knots: 9, tws: 10, rudder: 1))
    }

    /// Hysteresis: between 4.0 and 4.5 kn of apparent wind a planing boat stays on and one off the plane stays off;
    /// under 4.0 she drops off, from 4.5 she gets on. `was` is the only state.
    @Test func apparentWindHasHysteresis() {
        // 155° in 8 kn at 9.19 kn: 3.9 kn of apparent wind. 150° at 8.21 kn: 4.2 kn; at 9.2 kn: 4.6 kn. All forward of the beam.
        #expect(abs(apparentKnots(twa: 155, knots: 9.19, tws: 8) - 3.9) < 0.05)
        #expect(abs(apparentKnots(twa: 150, knots: 8.21, tws: 8) - 4.2) < 0.05)
        #expect(abs(apparentKnots(twa: 150, knots: 9.2, tws: 8) - 4.6) < 0.05)
        #expect(!planes(was: true, twa: 155, knots: 9.19, tws: 8))
        #expect(!planes(was: false, twa: 155, knots: 9.19, tws: 8))
        #expect(planes(was: true, twa: 150, knots: 8.21, tws: 8))
        #expect(!planes(was: false, twa: 150, knots: 8.21, tws: 8))
        #expect(planes(was: true, twa: 150, knots: 9.2, tws: 8))
        #expect(planes(was: false, twa: 150, knots: 9.2, tws: 8))
        // The rudder does not gate getting on.
        #expect(!planes(was: false, twa: 150, knots: 8.21, tws: 8, rudder: 1))
        // Without the value, the rule before: on at all three.
        var without = rule
        without.apparentWind = nil
        #expect(planes(without, was: false, twa: 155, knots: 9.19, tws: 8) && planes(without, was: false, twa: 150, knots: 8.21, tws: 8))
    }

    /// One rule at every wind strength (the owner, 2026-10-11: no wind gate): in 6 kn and in 25 kn the same tests
    /// take the same boat off.
    @Test func sameRuleInLightAirAndInAGale() {
        // 6 kn of wind, 160° at 6.5 kn: 2.2 kn of apparent wind.
        #expect(apparentKnots(twa: 160, knots: 6.5, tws: 6) < 4)
        #expect(!planes(was: true, twa: 160, knots: 6.5, tws: 6))
        #expect(Self.ruleBefore(rule, was: true, twa: deg2rad(160), speed: 6.5 * Self.knot, tws: 6 * Self.knot))
        // 25 kn, 165° at 11 kn: 0.63 of the polar's 17.6 kn, the apparent wind aft.
        #expect(apparentIsAft(twa: 165, knots: 11, tws: 25))
        #expect(!planes(was: true, twa: 165, knots: 11, tws: 25, rudder: 1))
        #expect(planes(was: true, twa: 165, knots: 13, tws: 25, rudder: 1))
    }

    /// The rule before #462 still holds on skiff@9: forward of 55° or under 6 kn she is off, whatever else.
    @Test func speedAndAngleStillTakeHerOff() {
        #expect(!planes(was: true, twa: 50, knots: 9, tws: 10))
        #expect(!planes(was: true, twa: 120, knots: 5.9, tws: 6))
        #expect(!planes(was: false, twa: 120, knots: 7.9, tws: 10))
        #expect(planes(was: false, twa: 120, knots: 8, tws: 10))
    }
}

/// #462: skiff@9, and the files before it unchanged.
@Suite struct SkiffNineTests {
    @Test func skiffNineIsSkiffEightWithThePlaningValues() throws {
        let file = SkiffNine.file
        #expect(file.schemaVersion == 4 && file.id == "skiff" && file.version == 9)
        let planing = try #require(file.content.planing)
        #expect(planing.stayOnSpeedShare == 0.7)
        #expect(planing.apparentWind == .init(offSpeed: metresPerSecond(knots: 4), onSpeed: metresPerSecond(knots: 4.5), rudderWithin: 0.2))
        // On 8 kn, off 6 kn, the apparent wind no further aft than the beam: as shipped.
        #expect(planing.onSpeed == metresPerSecond(knots: 8) && planing.offSpeed == metresPerSecond(knots: 6))
        #expect(planing.onMaxAWA == deg2rad(90))
        #expect(file.header.placeholders == SkiffEight.file.header.placeholders + ["/planing/stayOnSpeedShare", "/planing/apparentWind"])
        // Everything else is skiff@8's.
        var content = file.content
        content.planing?.stayOnSpeedShare = nil
        content.planing?.apparentWind = nil
        #expect(content == SkiffEight.boatClass)
    }

    /// The default switch is a later change: races still sail skiff@8.
    @Test func skiffEightIsStillTheDefault() throws {
        #expect(RaceFiles.defaults.boatClass.ref == SkiffEight.file.ref)
    }

    @Test func olderClassesLoadUnchanged() throws {
        let files = try (1...8).map { try BoatClassFile.bundled(id: "skiff", version: $0) }
            + (3...5).map { try BoatClassFile.bundled(id: "ilca-dinghy", version: $0) } // 1 and 2 are schema 1: not sailed
        for file in files {
            #expect(file.content.planing?.stayOnSpeedShare == nil && file.content.planing?.apparentWind == nil,
                    "\(file.id)@\(file.version)")
            #expect(!file.header.placeholders.contains { $0.hasPrefix("/planing/") }, "\(file.id)@\(file.version)")
        }
    }

    @Test func newValuesDecodeAndValidate() throws {
        func load(_ replacement: (of: String, with: String), version: Int = 9) throws -> BoatClass {
            try BoatClassFile(data: SkiffFixtures.edited([replacement], version: version), tune: 1).content
        }
        let share = #""stayOnSpeedShare": 0.7"#
        #expect(try load((of: share, with: #""stayOnSpeedShare": 0.55"#)).planing?.stayOnSpeedShare == 0.55)
        #expect(try load((of: share, with: #""stayOnSpeedShare": 0"#)).planing?.stayOnSpeedShare == 0)
        for bad in ["-0.1", "1.01"] {
            #expect(throws: DataFileError.self, "\(bad)") { try load((of: share, with: #""stayOnSpeedShare": \#(bad)"#)) }
        }
        for (of, with) in [(#""offKnots": 4,"#, #""offKnots": 0,"#), (#""offKnots": 4,"#, #""offKnots": 4.6,"#),
                           (#""onKnots": 4.5,"#, #""onKnots": 3.9,"#), (#""rudderWithin": 0.2"#, #""rudderWithin": 1.5"#),
                           (#""rudderWithin": 0.2"#, #""rudderWithin": -0.1"#)] {
            #expect(throws: DataFileError.self, "\(with)") { try load((of: of, with: with)) }
        }
        // Either value alone, and a schema-4 class with neither (skiff@8 is one).
        let shareOnly = try load((of: #""offSpeedKnots": 6,"#, with: #""offSpeedKnots": 6, "stayOnSpeedShare": 0.6,"#), version: 8)
        #expect(shareOnly.planing?.stayOnSpeedShare == 0.6 && shareOnly.planing?.apparentWind == nil)
        let windOnly = try load((of: #""offSpeedKnots": 6,"#,
                                 with: #""offSpeedKnots": 6, "apparentWind": {"offKnots": 3, "onKnots": 3, "rudderWithin": 1},"#),
                                version: 8)
        #expect(windOnly.planing?.stayOnSpeedShare == nil)
        #expect(windOnly.planing?.apparentWind == .init(offSpeed: metresPerSecond(knots: 3), onSpeed: metresPerSecond(knots: 3), rudderWithin: 1))
        // A schema-3 class does not read them.
        let schemaThree = try load((of: #""offSpeedKnots": 6,"#, with: #""offSpeedKnots": 6, "stayOnSpeedShare": 0.6,"#), version: 6)
        #expect(schemaThree.planing?.stayOnSpeedShare == nil)
        // A tuned copy (the debug sliders) rewrites each.
        let tuned = try TunedCopy.make(BoatClass.self, base: try SkiffFixtures.bytes(version: 9),
                                       values: ["/planing/stayOnSpeedShare": 0.75, "/planing/apparentWind/offKnots": 3.5,
                                                "/planing/apparentWind/onKnots": 5, "/planing/apparentWind/rudderWithin": 0.4],
                                       tune: 2)
        let planing = try #require(tuned.file.content.planing)
        #expect(planing.stayOnSpeedShare == 0.75)
        #expect(planing.apparentWind == .init(offSpeed: metresPerSecond(knots: 3.5), onSpeed: metresPerSecond(knots: 5), rudderWithin: 0.4))
    }
}

/// #462 acceptance (the owner's rulings of 2026-10-10 and 2026-10-11, the sweep's row R1), on skiff@9 from the plane
/// with the spinnaker up (`PlaningHarness`): a steady and six gusty winds of each strength.
@Suite struct PlaningTests {
    typealias Wind = PlaningHarness.Wind
    let boat = SkiffNine.boatClass
    static let breeze: [Double] = [8, 10, 14, 18]

    /// Ruling 1: a gybe at 30, 35 or 50 % rudder, and one under-steered at 25 %, never leaves the plane, not for a
    /// tick, in any of the seven winds at 8, 10, 14 and 18 kn; nor at 7 kn, where she only just planes.
    @Test(arguments: [7.0] + PlaningTests.breeze)
    func cleanGybeStaysOnThePlane(knots: Double) {
        for fraction in [0.3, 0.35, 0.5, 0.25] {
            for wind in Wind.all(knots) {
                let gybe = PlaningHarness.gybe(fraction, boat, wind)
                #expect(gybe.offSeconds == 0 && gybe.onAtEnd && gybe.arrived != nil,
                        "\(fraction) rudder, \(knots) kn, wind \(wind.seed ?? 0): off \(gybe.offSeconds) s")
            }
        }
    }

    /// Ruling 4: a clean gybe costs exactly what it costs on skiff@8, in every wind. The mean loss against sailing
    /// on, 45 s after a 35 % gybe: 0.40 / 0.50 / 0.61 / 0.67 hull lengths at 8 / 10 / 14 / 18 kn.
    @Test(arguments: zip(PlaningTests.breeze, [0.40, 0.50, 0.61, 0.67]))
    func cleanGybeCostsWhatItDoesOnSkiffEight(knots: Double, pinned: Double) {
        for fraction in [0.3, 0.35, 0.5] {
            for wind in Wind.all(knots) {
                let nine = PlaningHarness.gybe(fraction, boat, wind), eight = PlaningHarness.gybe(fraction, SkiffEight.boatClass, wind)
                #expect(nine.end == eight.end && nine.loss30 == eight.loss30 && nine.loss45 == eight.loss45,
                        "\(fraction) rudder, \(knots) kn, wind \(wind.seed ?? 0)")
            }
        }
        let mean = Wind.all(knots).map { PlaningHarness.gybe(0.35, boat, $0).loss45 }.reduce(0, +) / 7
        #expect(abs(mean - pinned) <= 0.02, "35 % gybe at \(knots) kn: \(mean) L (re-pin)")
    }

    /// Ruling 1: a slam, and a slam cranked 20° or 30° past the new groove (the bots' flub), drops her off the plane in
    /// every wind at 8, 10, 14 and 18 kn; holding dead downwind 4 s on the way round does in the steady wind and at
    /// least five of the seven. Sitting on the new groove she is still off 45 s on.
    @Test(arguments: PlaningTests.breeze)
    func slowGybeFallsOffThePlane(knots: Double) {
        for over in [0.0, 20, 30] {
            for wind in Wind.all(knots) {
                let slam = PlaningHarness.gybe(1, over: over, boat, wind)
                #expect(slam.fell && !slam.onAtEnd, "slam +\(over)°, \(knots) kn, wind \(wind.seed ?? 0)")
            }
        }
        let linger = Wind.all(knots).map { PlaningHarness.gybe(0.5, linger: 4, boat, $0) }
        #expect(linger[0].fell && !linger[0].onAtEnd, "4 s linger, \(knots) kn, steady")
        #expect(linger.filter(\.fell).count >= 5, "4 s linger, \(knots) kn: fell in \(linger.filter(\.fell).count) of 7")
        // Before #462 none of these left the plane from 10 kn up.
        if knots >= 10 { #expect(PlaningHarness.gybe(1, SkiffEight.boatClass, Wind(knots: knots)).offSeconds == 0) }
    }

    /// Ruling 2 as measured: heading up at once after a slam she is planing again, in every wind, within 9.8 / 4.1 /
    /// 1.5 / 1.4 s at 8 / 10 / 14 / 18 kn (bounded with margin, and never the 20 s cap), off once and on once.
    @Test(arguments: zip(PlaningTests.breeze, [12.0, 6, 3, 3]))
    func slowGybeRecoversByHeadingUp(knots: Double, within: Double) {
        for wind in Wind.all(knots) {
            let slam = PlaningHarness.gybe(1, headsUp: true, boat, wind)
            let replane = slam.replane ?? .infinity
            #expect(slam.onAtEnd && replane <= within && replane < 20, "\(knots) kn, wind \(wind.seed ?? 0): \(replane) s")
            #expect(slam.transitions == 2, "\(knots) kn, wind \(wind.seed ?? 0): \(slam.transitions) transitions")
        }
        // A 4 s linger, heading up: back on too.
        let linger = PlaningHarness.gybe(0.5, linger: 4, headsUp: true, boat, Wind(knots: knots))
        #expect(linger.onAtEnd && (linger.replane ?? .infinity) < 20, "4 s linger, \(knots) kn: \(linger.replane ?? .infinity) s")
    }

    /// Ruling 2: sit deep and she stays off. Off the plane on the groove, at any wind from 6 to 25 kn, she never gets
    /// back on by herself.
    @Test func sittingOnTheGrooveSheStaysOff() {
        for knots in stride(from: 6.0, through: 25, by: 1) {
            let sitting = PlaningHarness.run(boat, Wind(knots: knots), seconds: 60, start: .offPlane)
            #expect(!sitting.onAtEnd && sitting.transitions == 0, "\(knots) kn")
        }
    }

    /// Ruling 3: 5° deeper than the groove she stays on the plane, in the steady wind and following the groove through
    /// the six gusty ones.
    @Test(arguments: PlaningTests.breeze)
    func fiveDegreesDeepStaysOnThePlane(knots: Double) {
        for wind in Wind.all(knots) {
            let run = PlaningHarness.run(boat, wind, delta: 5)
            #expect(run.offSeconds == 0, "\(knots) kn, wind \(wind.seed ?? 0): off \(run.offSeconds) s")
        }
    }

    /// Ruling 3: 10° deeper she drops off and stays off, in the steady wind and at least five of the six gusty ones.
    @Test(arguments: PlaningTests.breeze)
    func tenDegreesDeepFallsOffThePlane(knots: Double) {
        let steady = PlaningHarness.run(boat, Wind(knots: knots), delta: 10)
        #expect(!steady.onAtEnd && (steady.firstOff ?? .infinity) < 10, "\(knots) kn: first off at \(steady.firstOff ?? .infinity) s")
        let gusty = Wind.gusty(knots).filter { PlaningHarness.run(boat, $0, delta: 10).offSeconds > 0 }.count
        #expect(gusty >= 5, "\(knots) kn: fell in \(gusty) of 6 gusty winds")
        #expect(PlaningHarness.run(SkiffEight.boatClass, Wind(knots: knots), delta: 10).offSeconds == 0, "skiff@8, \(knots) kn")
    }

    /// Ruling 5: a 35 % lull takes a boat 5° deep off the plane (holding her course); on the groove she rides it out,
    /// and a 20 % lull leaves the boat 5° deep on.
    @Test(arguments: [10.0, 14, 18])
    func lullTakesADeepBoatOffThePlane(knots: Double) {
        func run(lull: Double, delta: Double) -> PlaningHarness.Result {
            PlaningHarness.run(boat, Wind(knots: knots, lullDepth: lull), delta: delta, mode: .compass, seconds: 45)
        }
        #expect(run(lull: 0.35, delta: 5).offSeconds > 0, "\(knots) kn: 35 % lull, 5° deep")
        #expect(run(lull: 0.35, delta: 0).offSeconds == 0, "\(knots) kn: 35 % lull, on the groove")
        #expect(run(lull: 0.2, delta: 5).offSeconds == 0, "\(knots) kn: 20 % lull, 5° deep")
        #expect(run(lull: 0.2, delta: 10).offSeconds > 0, "\(knots) kn: 20 % lull, 10° deep")
    }

    /// The blocker: on her groove she never leaves the plane, at a steady 6 to 25 kn (every knot) and following the
    /// groove of the wind she has through the six gusty winds, as the bots do. Not once on or off.
    @Test func grooveNeverFallsOffAtAnyWind() {
        for knots in stride(from: 6.0, through: 25, by: 1) {
            let steady = PlaningHarness.run(boat, Wind(knots: knots), seconds: 60)
            #expect(steady.transitions == 0 && steady.offSeconds == 0 && steady.onAtEnd, "steady \(knots) kn")
        }
        for knots in [6.0, 7, 8, 10, 12, 14, 16, 18, 20, 22, 25] {
            for wind in Wind.gusty(knots) {
                let run = PlaningHarness.run(boat, wind)
                #expect(run.transitions == 0 && run.offSeconds == 0, "gusty \(knots) kn, wind \(wind.seed ?? 0)")
            }
        }
    }
}

/// #462: nothing upwind moves. skiff@9 against skiff@8 with `==`: the tack table, the 2 kn tack floor, irons recovery,
/// the bear-off gaps and the penalty circles (`HandTackTests`, `FallOffRetuneTests`, `IronsRecoveryTests`).
@Suite struct TackTableUnchangedTests {
    let nine = SkiffNine.boatClass
    let eight = SkiffEight.boatClass

    @Test(arguments: [6.0, 10, 14])
    func tackTableIsSkiffEights(knots: Double) {
        for entry in [1.0, 0.7] {
            for cell in HandTack.Cell.all(knots: knots, entry: entry) {
                for helm in HandTack.Helm.allCases {
                    let a = HandTack.run(helm, cell, boatClass: nine), b = HandTack.run(helm, cell, boatClass: eight)
                    #expect(a.loss20 == b.loss20 && a.loss25 == b.loss25 && a.stuck == b.stuck, "\(helm) \(cell)")
                }
            }
        }
    }

    @Test func bestTackSlamAndGapsAreSkiffEights() {
        #expect(HandTack.best(boatClass: nine) == HandTack.best(boatClass: eight))
        #expect(HandTack.loss(.slam, boatClass: nine) == HandTack.loss(.slam, boatClass: eight))
        #expect(HandTack.gentleGap(boatClass: nine) == HandTack.gentleGap(boatClass: eight))
        #expect(HandTack.bearOffGap(knots: 6, boatClass: nine) == HandTack.bearOffGap(knots: 6, boatClass: eight), "light-air gap")
        #expect(HandTack.bearOffGap(knots: 14, boatClass: nine) == HandTack.bearOffGap(knots: 14, boatClass: eight))
    }

    @Test func ironsRecoveryIsSkiffEights() {
        #expect(HandTack.stuck(boatClass: nine) == HandTack.stuck(boatClass: eight))
        #expect(HandTack.stuck([.release25Probe, .release60Probe], boatClass: nine)
                == HandTack.stuck([.release25Probe, .release60Probe], boatClass: eight))
    }

    /// `FallOffRetuneTests`' cases: from 1 and 2 kn at the edge of the no-go, every rudder it holds.
    @Test func twoKnotTackFloorIsSkiffEights() {
        for knots in [4.0, 6, 10] {
            for cell in HandTack.Cell.all(knots: knots) {
                for fraction in [0.3, 0.4, 0.5, 0.6, 0.75, 1] {
                    for speed in [1.0, 2] {
                        let a = HandTack.carry(fraction: fraction, cell: cell, speed: metresPerSecond(knots: speed), boatClass: nine)
                        let b = HandTack.carry(fraction: fraction, cell: cell, speed: metresPerSecond(knots: speed), boatClass: eight)
                        #expect(a.out == b.out && a.clean == b.clean, "\(fraction) rudder from \(speed) kn, \(cell)")
                    }
                }
            }
        }
    }

    /// `FallOffRetuneTests`' circles: tack first at 70 % rudder (a penalty turn) and hard over, from the groove, 2 kn
    /// and a standstill.
    @Test func penaltyCirclesAreSkiffEights() {
        for knots in [4.0, 6, 10] {
            for cell in HandTack.Cell.all(knots: knots) {
                for fraction in [0.7, 1] {
                    for speed in [nil, metresPerSecond(knots: 2), 0] as [Double?] {
                        #expect(HandTack.circle(fraction: fraction, cell: cell, speed: speed, boatClass: nine)
                                == HandTack.circle(fraction: fraction, cell: cell, speed: speed, boatClass: eight),
                                "\(fraction) rudder from \(speed.map { "\($0) m/s" } ?? "the groove"), \(cell)")
                    }
                }
            }
        }
    }
}
