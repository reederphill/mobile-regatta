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

    /// The rule as first built for skiff@9 (68ad024), copied: what a class with the two values and no taper must still
    /// answer, and skiff@9 itself wherever the taper's share of the wind is no less than the fixed speed.
    static func ruleWithoutTaper(_ p: BoatClass.PlaningTuning, was: Bool, twa: Double, speed: Double, tws: Double, rudder: Double,
                                 polar: PolarTable) -> Bool {
        let apparent = BoatClass.PlaningTuning.apparentWindSpeed(twa: twa, speed: speed, tws: tws)
        let cosine = BoatClass.PlaningTuning.apparentWindCosine(twa: twa, speed: speed, tws: tws)
        guard was else {
            guard twa >= p.fromTWA && speed >= p.onSpeed else { return false }
            if let wind = p.apparentWind, apparent < wind.onSpeed { return false }
            return cosine >= RegattaCore.cos(p.onMaxAWA)
        }
        guard twa >= p.offBelowTWA && speed >= p.offSpeed else { return false }
        if let share = p.stayOnSpeedShare, cosine < RegattaCore.cos(p.onMaxAWA), speed < share * polar.speed(twa: twa, tws: tws) { return false }
        if let wind = p.apparentWind, apparent < wind.offSpeed, abs(rudder) <= wind.rudderWithin { return false }
        return true
    }

    /// The light-air taper (the owner, 2026-10-11): the floor is the lesser of 4.0 kn and 0.6 of the wind, getting on
    /// the lesser of 4.5 kn and 0.675 of it. 3.6 / 4.05 kn at 6 kn, 3.0 / 3.375 at 5; the fixed speeds, to the bit,
    /// from 6.67 kn up. Continuous: no step where the two meet.
    @Test func apparentWindFloorTapersInVeryLightWind() throws {
        let wind = try #require(rule.apparentWind)
        #expect(wind.offWindShare == 0.6 && wind.onWindShare == 0.675)
        func off(_ knots: Double) -> Double { wind.offSpeed(tws: knots * Self.knot) / Self.knot }
        func on(_ knots: Double) -> Double { wind.onSpeed(tws: knots * Self.knot) / Self.knot }
        #expect(abs(off(6) - 3.6) < 1e-9 && abs(on(6) - 4.05) < 1e-9)
        #expect(abs(off(5) - 3.0) < 1e-9 && abs(on(5) - 3.375) < 1e-9)
        for knots in [6.67, 7, 8, 10, 14, 18, 25] {
            #expect(wind.offSpeed(tws: knots * Self.knot) == wind.offSpeed && wind.onSpeed(tws: knots * Self.knot) == wind.onSpeed, "\(knots) kn")
        }
        #expect(abs(off(6.666) - 4) < 0.001 && abs(on(6.666) - 4.5) < 0.001, "no step where they meet")
        var fixed = wind
        fixed.offWindShare = nil
        fixed.onWindShare = nil
        #expect(fixed.offSpeed(tws: 1) == wind.offSpeed && fixed.onSpeed(tws: 1) == wind.onSpeed, "no shares, no taper")
        // In 6 kn at 155° and 8.2 kn she has 3.75 kn of apparent wind: on the plane she stays (the fixed 4.0 kn took her
        // off); at 160°, 3.3 kn, she drops off. Off the plane at 150°, 4.25 kn, she gets on (the fixed 4.5 kn kept her
        // off); at 155° she does not.
        var untapered = rule
        untapered.apparentWind = fixed
        #expect(abs(apparentKnots(twa: 155, knots: 8.2, tws: 6) - 3.75) < 0.05)
        #expect(planes(was: true, twa: 155, knots: 8.2, tws: 6) && !planes(untapered, was: true, twa: 155, knots: 8.2, tws: 6))
        #expect(apparentKnots(twa: 160, knots: 8.2, tws: 6) < 3.6 && !planes(was: true, twa: 160, knots: 8.2, tws: 6))
        #expect(abs(apparentKnots(twa: 150, knots: 8.2, tws: 6) - 4.25) < 0.05)
        #expect(planes(was: false, twa: 150, knots: 8.2, tws: 6) && !planes(untapered, was: false, twa: 150, knots: 8.2, tws: 6))
        #expect(!planes(was: false, twa: 155, knots: 8.2, tws: 6))
    }

    /// Without the shares it is the rule as first built, and with them too from 6.67 kn of wind up: 200,000 random
    /// inputs each. Below that the taper only ever keeps her on, or lets her on: never the other way.
    @Test func taperChangesNothingFromSixPointSevenKnots() throws {
        var untapered = rule
        untapered.apparentWind?.offWindShare = nil
        untapered.apparentWind?.onWindShare = nil
        var random = SplitMix64(seed: 4620)
        var differ = (untapered: 0, breeze: 0, light: 0, lightOff: 0)
        for _ in 0..<200_000 {
            let was = random.bool()
            let twa = random.range(0, .pi), speed = random.range(0, 12), rudder = random.range(-1, 1)
            let breeze = random.range(6.67 * Self.knot, 14), light = random.range(0, 6.67 * Self.knot)
            for tws in [breeze, light] {
                if untapered.isPlaning(was: was, twa: twa, speed: speed, tws: tws, rudder: rudder, polar: polar)
                    != Self.ruleWithoutTaper(untapered, was: was, twa: twa, speed: speed, tws: tws, rudder: rudder, polar: polar) {
                    differ.untapered += 1
                }
            }
            if rule.isPlaning(was: was, twa: twa, speed: speed, tws: breeze, rudder: rudder, polar: polar)
                != Self.ruleWithoutTaper(rule, was: was, twa: twa, speed: speed, tws: breeze, rudder: rudder, polar: polar) {
                differ.breeze += 1
            }
            let tapered = rule.isPlaning(was: was, twa: twa, speed: speed, tws: light, rudder: rudder, polar: polar)
            let before = Self.ruleWithoutTaper(rule, was: was, twa: twa, speed: speed, tws: light, rudder: rudder, polar: polar)
            if tapered != before { differ.light += 1 }
            if before && !tapered { differ.lightOff += 1 }
        }
        #expect(differ.untapered == 0 && differ.breeze == 0 && differ.lightOff == 0, "\(differ)")
        #expect(differ.light > 0, "the taper does something under 6.67 kn")
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
        #expect(planing.apparentWind == .init(offSpeed: metresPerSecond(knots: 4), onSpeed: metresPerSecond(knots: 4.5), rudderWithin: 0.2,
                                              offWindShare: 0.6, onWindShare: 0.675))
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

    /// Races sail it by default (simulation revision 40); skiff@8 stays bundled for the races naming it.
    @Test func skiffNineIsTheDefault() throws {
        #expect(RaceFiles.defaults.boatClass.ref == SkiffNine.file.ref)
        #expect(BoatClassFile.bundledKeys().contains(SkiffEight.file.ref.key))
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
        #expect(windOnly.planing?.apparentWind?.offWindShare == nil && windOnly.planing?.apparentWind?.onWindShare == nil)
        // The taper's shares of the wind: positive, on no less than off, and both or neither.
        let taper = #""offWindShare": 0.6,"#
        #expect(try load((of: taper, with: #""offWindShare": 0.5,"#)).planing?.apparentWind?.offWindShare == 0.5)
        for (of, with) in [(taper, #""offWindShare": 0,"#), (taper, #""offWindShare": 0.7,"#), (taper, ""),
                           (#""onWindShare": 0.675"#, #""onWindShare": 0.5"#)] {
            #expect(throws: DataFileError.self, "\(with)") { try load((of: of, with: with)) }
        }
        let untapered = try load((of: #""rudderWithin": 0.2,\#n      "offWindShare": 0.6,\#n      "onWindShare": 0.675"#,
                                  with: #""rudderWithin": 0.2"#))
        #expect(untapered.planing?.apparentWind == .init(offSpeed: metresPerSecond(knots: 4), onSpeed: metresPerSecond(knots: 4.5), rudderWithin: 0.2))
        // A schema-3 class does not read them.
        let schemaThree = try load((of: #""offSpeedKnots": 6,"#, with: #""offSpeedKnots": 6, "stayOnSpeedShare": 0.6,"#), version: 6)
        #expect(schemaThree.planing?.stayOnSpeedShare == nil)
        // A tuned copy (the debug sliders) rewrites each.
        let tuned = try TunedCopy.make(BoatClass.self, base: try SkiffFixtures.bytes(version: 9),
                                       values: ["/planing/stayOnSpeedShare": 0.75, "/planing/apparentWind/offKnots": 3.5,
                                                "/planing/apparentWind/onKnots": 5, "/planing/apparentWind/rudderWithin": 0.4,
                                                "/planing/apparentWind/offWindShare": 0.5, "/planing/apparentWind/onWindShare": 0.8],
                                       tune: 2)
        let planing = try #require(tuned.file.content.planing)
        #expect(planing.stayOnSpeedShare == 0.75)
        #expect(planing.apparentWind == .init(offSpeed: metresPerSecond(knots: 3.5), onSpeed: metresPerSecond(knots: 5), rudderWithin: 0.4,
                                              offWindShare: 0.5, onWindShare: 0.8))
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

/// #462, the light-air taper (the owner's ruling of 2026-10-11): at 6 kn a boat that is planing keeps it as she does on
/// skiff@8 where the fixed floor took it; from 7 kn up the tables are the fixed floor's.
@Suite struct PlaningTaperTests {
    typealias Wind = PlaningHarness.Wind
    let boat = SkiffNine.boatClass
    /// skiff@9 with the fixed floor at every wind: as first built.
    static let untapered: BoatClass = {
        var boat = SkiffNine.boatClass
        boat.planing?.apparentWind?.offWindShare = nil
        boat.planing?.apparentWind?.onWindShare = nil
        return boat
    }()

    static func same(_ a: PlaningHarness.Result, _ b: PlaningHarness.Result) -> Bool {
        a.end == b.end && a.loss30 == b.loss30 && a.loss45 == b.loss45 && a.offSeconds == b.offSeconds
            && a.transitions == b.transitions && a.firstOff == b.firstOff && a.lastOff == b.lastOff && a.onAtEnd == b.onAtEnd
    }

    /// At 6 kn a planing boat's gybe at 50 % rudder is skiff@8's: on the plane throughout in the steady wind, and off
    /// it in the same winds of the seven (the fixed floor: off in the steady wind and 5 of 7).
    @Test func halfRudderGybeInSixKnotsIsSkiffEights() {
        let nine = Wind.all(6).map { PlaningHarness.gybe(0.5, boat, $0) }
        let eight = Wind.all(6).map { PlaningHarness.gybe(0.5, SkiffEight.boatClass, $0) }
        let fixed = Wind.all(6).map { PlaningHarness.gybe(0.5, Self.untapered, $0) }
        print("PLANINGTAPER 6 kn 50 % gybe fell: skiff@9 \(nine.map(\.fell)) skiff@8 \(eight.map(\.fell)) fixed floor \(fixed.map(\.fell))")
        #expect(nine[0].offSeconds == 0 && nine[0].onAtEnd, "steady")
        #expect(nine.map(\.fell) == eight.map(\.fell))
        #expect(nine.filter(\.fell).count < fixed.filter(\.fell).count)
        let mean = (nine.map(\.loss45).reduce(0, +) / 7, eight.map(\.loss45).reduce(0, +) / 7)
        #expect(abs(mean.0 - mean.1) <= 0.02, "\(mean)")
        // 30 and 35 % and the under-steer stay on, as before the taper.
        for fraction in [0.3, 0.35, 0.25] {
            for wind in Wind.all(6) { #expect(PlaningHarness.gybe(fraction, boat, wind).offSeconds == 0, "\(fraction), wind \(wind.seed ?? 0)") }
        }
    }

    /// At 6 kn 5° deeper than the groove stays on the plane, steady and following the groove through the six gusty
    /// winds (the fixed floor: off in 5 of the 6); 10° deeper still falls, and the groove still holds.
    @Test func fiveDegreesDeepStaysOnInSixKnotsAndTenFalls() {
        for wind in Wind.all(6) {
            #expect(PlaningHarness.run(boat, wind, delta: 5).offSeconds == 0, "5° deep, wind \(wind.seed ?? 0)")
            #expect(PlaningHarness.run(boat, wind).offSeconds == 0, "groove, wind \(wind.seed ?? 0)")
        }
        #expect(Wind.gusty(6).filter { PlaningHarness.run(Self.untapered, $0, delta: 5).offSeconds > 0 }.count >= 4)
        let deep = PlaningHarness.run(boat, Wind(knots: 6), delta: 10)
        #expect(!deep.onAtEnd && (deep.firstOff ?? .infinity) < 10, "10° deep: first off at \(deep.firstOff ?? .infinity) s")
        #expect(Wind.gusty(6).filter { PlaningHarness.run(boat, $0, delta: 10).offSeconds > 0 }.count >= 5)
    }

    /// From 7 kn up every table row is the fixed floor's, to the bit: each gybe helm and each run offset (following the
    /// groove and on one compass course), in the steady wind and the six gusty ones, and each scripted lull that leaves
    /// her 6.67 kn of wind or more. A lull that takes the wind under that (20 % from 7 and 8 kn, 35 % from 7, 8 and
    /// 10 kn) is the taper's wind while it lasts: the same boats fall and stay off, 0.6 to 6 s later, none sooner.
    @Test(arguments: [7.0, 8, 10, 14, 18])
    func tablesFromSevenKnotsAreUnchanged(knots: Double) {
        var differ: [String] = []
        for wind in Wind.all(knots) {
            let name = "wind \(wind.seed ?? 0)"
            for fraction in [0.3, 0.35, 0.5, 0.75, 0.85, 0.9, 0.95, 1, 0.25] {
                if !Self.same(PlaningHarness.gybe(fraction, boat, wind), PlaningHarness.gybe(fraction, Self.untapered, wind)) { differ.append("gybe \(fraction) \(name)") }
                if fraction >= 0.85, !Self.same(PlaningHarness.gybe(fraction, headsUp: true, boat, wind),
                                                PlaningHarness.gybe(fraction, headsUp: true, Self.untapered, wind)) { differ.append("gybe \(fraction) heading up \(name)") }
            }
            for (fraction, over) in [(1.0, 20.0), (1, 30), (0.5, 20), (0.5, 30)] {
                if !Self.same(PlaningHarness.gybe(fraction, over: over, boat, wind), PlaningHarness.gybe(fraction, over: over, Self.untapered, wind)) { differ.append("gybe \(fraction) +\(over) \(name)") }
            }
            for linger in [2.0, 4] {
                if !Self.same(PlaningHarness.gybe(0.5, linger: linger, boat, wind), PlaningHarness.gybe(0.5, linger: linger, Self.untapered, wind)) { differ.append("linger \(linger) \(name)") }
            }
            for delta in [-10.0, -5, 0, 5, 10, 15] {
                for mode in [PlaningHarness.RunHelm.Mode.track, .compass] {
                    if !Self.same(PlaningHarness.run(boat, wind, delta: delta, mode: mode), PlaningHarness.run(Self.untapered, wind, delta: delta, mode: mode)) { differ.append("run \(delta) \(mode) \(name)") }
                }
            }
        }
        for lull in [0.2, 0.35] {
            for delta in [0.0, 5, 10] {
                let wind = Wind(knots: knots, lullDepth: lull)
                let a = PlaningHarness.run(boat, wind, delta: delta, mode: .compass, seconds: 45)
                let b = PlaningHarness.run(Self.untapered, wind, delta: delta, mode: .compass, seconds: 45)
                guard knots * (1 - lull) < 6.67 else {
                    if !Self.same(a, b) { differ.append("lull \(lull) +\(delta)") }
                    continue
                }
                #expect(a.onAtEnd == b.onAtEnd && (a.offSeconds > 0) == (b.offSeconds > 0), "\(knots) kn, lull \(lull) +\(delta)")
                #expect((a.firstOff ?? .infinity) >= (b.firstOff ?? .infinity) && a.offSeconds <= b.offSeconds,
                        "\(knots) kn, lull \(lull) +\(delta): first off \(a.firstOff ?? -1) s (fixed floor \(b.firstOff ?? -1) s)")
            }
        }
        print("PLANINGTAPER \(knots) kn: \(differ.count) rows differ \(differ)")
        #expect(differ.isEmpty, "\(knots) kn: \(differ)")
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
