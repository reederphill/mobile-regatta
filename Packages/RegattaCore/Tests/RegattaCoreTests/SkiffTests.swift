import Testing
@testable import RegattaCore

/// #248 acceptance: the skiff, the schema-3 class races sail by default (skiff@3 since #263: #89's quicker turn with
/// #263's momentum, rudder drag and roll tack). Its polar is #244's seed table (docs/research/49er-skiff-polars-and-handling.md §8); it planes,
/// hoists and drops an automatic spinnaker, and pays heavily by the lee. The dynamics tests sail in a
/// constant wind from the north with no current, steered as `Race` steers (the autohelm and its tap), like
/// `BoomTests`.
@Suite struct SkiffTests {
    let skiff: BoatClass
    let dt = Race.dt
    /// The wind blows from the north.
    let windFrom = 0.0

    init() throws {
        skiff = try SkiffFixtures.boatClass()
    }

    func tws(_ knots: Double) -> Double { metresPerSecond(knots: knots) }

    func env(knots: Double) -> BoatDynamics.Environment {
        .constant(windDirection: windFrom, windSpeed: tws(knots))
    }

    /// Starboard tack (boom to port) at `twa` radians, at `speed`, planing and with the spinnaker as given.
    func starboard(twa: Double, speed: Double, isPlaning: Bool = false, spinnaker: Spinnaker = .down) -> BoatDynamics.State {
        .init(heading: wrapAngle(windFrom - twa), speed: speed, boomSide: .port, isPlaning: isPlaning, spinnaker: spinnaker)
    }

    func twa(_ s: BoatDynamics.State) -> Double { abs(wrapAngle(windFrom - s.heading)) }

    func sailingAngle(_ s: BoatDynamics.State) -> Double {
        s.boomSide.sailingAngle(relativeWind: wrapAngle(windFrom - s.heading))
    }

    func step(_ s: BoatDynamics.State, rudder: Double = 0, knots: Double) -> BoatDynamics.State {
        BoatDynamics.advance(s, control: .init(rudder: rudder), env: env(knots: knots), boatClass: skiff, dt: dt)
    }

    /// `seconds` of holding her heading (rudder centred, a steady wind: her true wind angle holds).
    func hold(_ s: BoatDynamics.State, knots: Double, seconds: Double, each: (BoatDynamics.State) -> Void = { _ in }) -> BoatDynamics.State {
        var s = s
        for _ in 0..<Int((seconds / dt).rounded()) {
            s = step(s, knots: knots)
            each(s)
        }
        return s
    }

    /// Her heading turned to `twa` radians on the same tack, everything else as it was.
    func headed(_ s: BoatDynamics.State, twa: Double) -> BoatDynamics.State {
        var s = s
        s.heading = wrapAngle(windFrom - s.boomSide.windSign * twa)
        return s
    }

    /// One tack/gybe tap from `state` for `seconds`, steered as `Race` steers it: the autohelm sails the
    /// tap until the boom crosses, then holds the groove on the new tack. Every tick's state, the first
    /// before the tap.
    func tap(_ state: BoatDynamics.State, knots: Double, seconds: Double = 25) -> [BoatDynamics.State] {
        var s = state
        var helm = Autohelm.tackOrGybe(sailingAngle: sailingAngle(s))
        var states = [s]
        for _ in 0..<Int((seconds / dt).rounded()) {
            let side = s.boomSide
            let rudder = helm.rudder(sailingAngle: sailingAngle(s), boomSide: side, tws: tws(knots), boatClass: skiff)
            s = step(s, rudder: rudder, knots: knots)
            if s.boomSide != side { helm.isTapping = false }
            states.append(s)
        }
        return states
    }

    /// Metres lost over `run` against holding the entry heading and speed for as long, made good along `direction`.
    func metresLost(_ run: [BoatDynamics.State], along direction: Vec2) -> Double {
        let start = run[0]
        let seconds = Double(run.count - 1) * dt
        let straight = Vec2.heading(start.heading).dot(direction) * start.speed * seconds
        return straight - (run.last!.position - start.position).dot(direction)
    }

    // MARK: - The polar

    /// Upwind ~45° from 6 to 20 kn; the downwind groove deepens from 135° at 4 kn to ~155° at 14–16 kn
    /// (#244 §8's best-VMG table).
    @Test func bestUpwindAndDownwindMatchTheSeed() {
        // 45° exactly at 8–16 kn; the refined optimum sits a little wider at 6 kn (47°) and 20 kn (48°, as §8 finds).
        for knots in [6.0, 8, 10, 12, 14, 16, 20] {
            let upwind = rad2deg(skiff.polar.bestUpwind(tws: tws(knots)).twa)
            #expect(abs(upwind - 45) <= ((8...16).contains(knots) ? 0.01 : 3.5), "best upwind \(upwind)° at \(knots) kn")
        }
        // The groove is flat at 12–16 kn (§4.2): its refined optimum is 153° at 12 kn and 157° at 16 kn.
        for (knots, groove, tolerance) in [(4.0, 135.0, 0.01), (6, 140, 0.01), (8, 145, 0.01), (10, 150, 0.01), (12, 155, 2.5),
                                           (14, 155, 0.01), (16, 155, 2.5)] {
            let downwind = rad2deg(skiff.polar.bestDownwind(tws: tws(knots)).twa)
            #expect(abs(downwind - groove) <= tolerance, "best downwind \(downwind)° at \(knots) kn")
        }
        // The seed's VMG (§8): 5.59 kn upwind and 10.22 kn downwind at 10 kn.
        #expect(abs(skiff.polar.bestUpwind(tws: tws(10)).vmg / metresPerSecond(knots: 1) - 5.59) < 0.02)
        #expect(abs(skiff.polar.bestDownwind(tws: tws(10)).vmg / metresPerSecond(knots: 1) - 10.22) < 0.02)
        // The class the ticket names: two-person 4.9 m, the 1.8 m hull beam (the racks are drawn, not sailed).
        #expect(skiff.name == "Skiff" && skiff.hull.length == 4.9 && skiff.hull.beam == 1.8)
    }

    // MARK: - Planing

    /// 8 kn, 145°: on the plane she holds it; knocked off it (a lull), the same heading doesn't get her
    /// back on; heading up to ~125° does, and bearing away again she keeps it (#244 §4.4).
    @Test func planingHysteresisDownwind() {
        let groove = deg2rad(145)
        let onPlane = skiff.polar.speed(twa: groove, tws: tws(8))
        var s = starboard(twa: groove, speed: onPlane, isPlaning: true, spinnaker: .up)
        s = hold(s, knots: 8, seconds: 30) { #expect($0.isPlaning) }
        #expect(abs(s.speed - onPlane) < 1e-6, "on the plane at \(s.speed / metresPerSecond(knots: 1)) kn")

        // A lull to 3 kn for 12 s knocks her off the plane (skiff@3 bleeds speed off over 10 s, #263).
        s = hold(s, knots: 3, seconds: 12)
        #expect(!s.isPlaning)

        // Back in 8 kn at the same heading she stays off it, at the off-plane speed.
        s = hold(s, knots: 8, seconds: 60) { #expect(!$0.isPlaning) }
        let offPlane = skiff.planing!.offPlaneSpeed(twa: groove, tws: tws(8), polar: skiff.polar)
        #expect(abs(s.speed - offPlane) < 1e-3, "off the plane at \(s.speed / metresPerSecond(knots: 1)) kn")
        #expect(offPlane < 0.8 * onPlane)

        // Heading up to 125° gets her back on it within a few seconds...
        s = headed(s, twa: deg2rad(125))
        var planedAfter: Double?
        var t = 0.0
        s = hold(s, knots: 8, seconds: 15) { state in
            t += dt
            if planedAfter == nil && state.isPlaning { planedAfter = t }
        }
        let planed = try? #require(planedAfter)
        #expect((planed ?? .infinity) <= 8, "planed \(String(describing: planed)) s after heading up")
        // ...and bearing away again to 145° she keeps it and gets back to the on-plane speed.
        s = hold(headed(s, twa: groove), knots: 8, seconds: 60) { #expect($0.isPlaning) }
        #expect(abs(s.speed - onPlane) < 1e-3)
    }

    /// The planing state machine's thresholds, one at a time.
    @Test func planingThresholdsHaveHysteresis() throws {
        let planing = try #require(skiff.planing)
        let knots = metresPerSecond(knots: 1)
        func planes(was: Bool, twa: Double, speed: Double, tws: Double = 8) -> Bool {
            planing.isPlaning(was: was, twa: deg2rad(twa), speed: speed * knots, tws: tws * knots)
        }
        // On the plane, she stays on it down to 6 kn of boat speed, whatever the apparent wind.
        #expect(planes(was: true, twa: 145, speed: 6.1))
        #expect(!planes(was: true, twa: 145, speed: 5.9))
        #expect(planes(was: true, twa: 175, speed: 7, tws: 20)) // apparent wind well aft
        // Off it, she needs 8 kn and the apparent wind forward of the beam.
        #expect(!planes(was: false, twa: 145, speed: 7.9))
        #expect(planes(was: false, twa: 125, speed: 8.1))
        #expect(!planes(was: false, twa: 145, speed: 8.2, tws: 12)) // 8.2 kn at 145° in 12 kn: apparent wind ~103°
        #expect(planes(was: false, twa: 130, speed: 9.5, tws: 12))
        // Downwind and reaching only: on from 65°, off forward of 55°.
        #expect(!planes(was: false, twa: 60, speed: 10))
        #expect(planes(was: false, twa: 66, speed: 10))
        #expect(planes(was: true, twa: 56, speed: 10))
        #expect(!planes(was: true, twa: 54, speed: 10))
        // Forward of 65° she sails the polar as is, planing or not.
        for twa in [45.0, 60] {
            let a = BoatDynamics.polarTarget(relativeWind: deg2rad(twa), boomSide: .port, tws: 8 * knots, isPlaning: false,
                                             spinnaker: .down, boatClass: skiff)
            #expect(a == skiff.polar.speed(twa: deg2rad(twa), tws: 8 * knots))
        }
    }

    // MARK: - The spinnaker

    /// Up past 115°, down forward of 105°, nothing in between: no flicker. A hoist and a drop each take
    /// ~4 s, at two-sail speed.
    @Test func spinnakerHoistsAndDropsWithHysteresis() throws {
        let kite = try #require(skiff.spinnaker)
        #expect(kite.transitionTime == 4)
        // Two sails on a reach at 110°: the spinnaker stays down.
        var s = starboard(twa: deg2rad(110), speed: skiff.polar.speed(twa: deg2rad(110), tws: tws(10)) * 0.65, isPlaning: true)
        s = hold(s, knots: 10, seconds: 20) { #expect($0.spinnaker == .down) }

        // Bearing away to 125° hoists it: two-sail speed for 4 s, then up.
        s = headed(s, twa: deg2rad(125))
        let twoSail = BoatDynamics.polarTarget(relativeWind: deg2rad(125), boomSide: .port, tws: tws(10), isPlaning: true,
                                               spinnaker: .hoisting(remaining: 2), boatClass: skiff)
        #expect(abs(twoSail - 0.65 * skiff.polar.speed(twa: deg2rad(125), tws: tws(10))) < 1e-9)
        var hoisting = 0
        s = hold(s, knots: 10, seconds: 10) { state in
            if case .hoisting = state.spinnaker {
                hoisting += 1
                #expect(state.speed <= twoSail + 1e-9, "faster than two-sail speed while hoisting")
            }
        }
        #expect(abs(Double(hoisting) * dt - 4) <= dt, "hoisting took \(Double(hoisting) * dt) s")
        #expect(s.spinnaker == .up)
        #expect(s.speed > twoSail * 1.2, "up and drawing: \(s.speed / metresPerSecond(knots: 1)) kn")

        // Wobbling between 106° and 114° leaves it up...
        func wobble(_ state: BoatDynamics.State, seconds: Double) -> [Spinnaker] {
            var state = state
            var seen: [Spinnaker] = []
            for n in 0..<Int((seconds / dt).rounded()) {
                let angle = 110 + 4 * RegattaCore.sin(Double(n) * dt * 2 * .pi / 5) // a 5 s wobble, ±4°
                state = step(headed(state, twa: deg2rad(angle)), knots: 10)
                seen.append(state.spinnaker)
            }
            return seen
        }
        #expect(Set(wobble(s, seconds: 60).map { "\($0)" }) == ["up"])

        // ...heading up to 100° drops it in 4 s...
        s = headed(s, twa: deg2rad(100))
        var dropping = 0
        s = hold(s, knots: 10, seconds: 10) { state in
            if case .dropping = state.spinnaker { dropping += 1 }
        }
        #expect(abs(Double(dropping) * dt - 4) <= dt, "dropping took \(Double(dropping) * dt) s")
        #expect(s.spinnaker == .down)
        // ...and the same wobble leaves it down.
        #expect(Set(wobble(s, seconds: 60).map { "\($0)" }) == ["down"])
    }

    /// The spinnaker's state machine on its own: the transition runs on the clock, and turning back past
    /// the other angle mid-way reverses it, taking as long to undo as it had run.
    @Test func spinnakerTransitionsReverseMidWay() throws {
        let kite = try #require(skiff.spinnaker)
        let deep = deg2rad(130), reach = deg2rad(100), between = deg2rad(110)
        #expect(Spinnaker.down.next(twa: between, dt: dt, tuning: kite) == .down)
        #expect(Spinnaker.up.next(twa: between, dt: dt, tuning: kite) == .up)
        #expect(Spinnaker.down.next(twa: deep, dt: dt, tuning: kite) == .hoisting(remaining: 4))
        #expect(Spinnaker.up.next(twa: reach, dt: dt, tuning: kite) == .dropping(remaining: 4))
        #expect(Spinnaker.hoisting(remaining: 1).next(twa: between, dt: 0.5, tuning: kite) == .hoisting(remaining: 0.5))
        #expect(Spinnaker.hoisting(remaining: 0.5).next(twa: between, dt: 0.5, tuning: kite) == .up)
        #expect(Spinnaker.dropping(remaining: 0.5).next(twa: between, dt: 0.5, tuning: kite) == .down)
        // A second into a hoist, heading up past 105° takes a second to bring it down again.
        #expect(Spinnaker.hoisting(remaining: 3).next(twa: reach, dt: dt, tuning: kite) == .dropping(remaining: 1))
        #expect(Spinnaker.dropping(remaining: 3).next(twa: deep, dt: dt, tuning: kite) == .hoisting(remaining: 1))
        #expect(Spinnaker.hoisting(remaining: 4).next(twa: reach, dt: dt, tuning: kite) == .down)
    }

    // MARK: - By the lee

    /// −10% per 5° by the lee, and the spinnaker collapses past 10°: two-sail speed on top.
    @Test func byTheLeeCostsTenPercentPerFiveDegreesAndCollapsesTheSpinnaker() {
        let knots = tws(12)
        func target(byTheLee degrees: Double, spinnaker: Spinnaker = .up) -> Double {
            // Boom to port, the wind over the port quarter: `degrees` past dead downwind.
            BoatDynamics.polarTarget(relativeWind: -(Double.pi - deg2rad(degrees)), boomSide: .port, tws: knots, isPlaning: true,
                                     spinnaker: spinnaker, boatClass: skiff)
        }
        for degrees in [5.0, 10] {
            let mirrored = skiff.polar.speed(twa: .pi - deg2rad(degrees), tws: knots)
            #expect(abs(target(byTheLee: degrees) - mirrored * (1 - 0.02 * degrees)) < 1e-9, "\(degrees)° by the lee")
        }
        let mirrored = skiff.polar.speed(twa: .pi - deg2rad(15), tws: knots)
        #expect(abs(target(byTheLee: 15) - mirrored * 0.7 * 0.65) < 1e-9, "15° by the lee: collapsed")
        var boat = Boat(id: 0, isPlayer: true, colorIndex: 0, position: .zero, heading: wrapAngle(windFrom + .pi - deg2rad(15)),
                        speed: 5, boomSide: .port)
        boat.windDirection = windFrom
        boat.spinnaker = .up
        #expect(boat.isSpinnakerCollapsed(in: skiff))
        boat.heading = wrapAngle(windFrom + .pi - deg2rad(8))
        #expect(!boat.isSpinnakerCollapsed(in: skiff))
    }

    // MARK: - Manoeuvres

    /// #263: a tack tapped from close-hauled with the autohelm holding costs 0.7–1.3 hull lengths made good upwind
    /// over 25 s against sailing on, at 6, 10 and 14 kn (skiff@3: rudder drag 0.25, momentum 1.5 s / 10 s). She is
    /// close-hauled on the new tack within 3.5 s of the tap and never below 40 % of her entry speed, so the stall
    /// skiff@2 had (30 % of entry, 1.57 L at 10 kn) can't come back.
    @Test(arguments: [6.0, 10, 14])
    func tackCosts0_7To1_3LengthsAt6_10And14Knots(knots: Double) {
        let beat = skiff.polar.bestUpwind(tws: tws(knots))
        let run = tap(starboard(twa: beat.twa, speed: beat.speed), knots: knots)
        #expect(zip(run, run.dropFirst()).filter { $0.boomSide != $1.boomSide }.count == 1)
        #expect(run.last!.boomSide == .starboard)
        #expect(abs(rad2deg(sailingAngle(run.last!) - beat.twa)) < 0.5, "settled close-hauled on the new tack")
        let lengths = metresLost(run, along: .heading(windFrom)) / skiff.hull.length
        #expect(lengths >= 0.7 && lengths <= 1.3, "\(knots) kn tack lost \(lengths) L")
        // Close-hauled as `Race` has it (rule 13's end): within 5° of the groove on the new tack.
        let closeHauled = run.firstIndex { $0.boomSide == .starboard && sailingAngle($0) >= beat.twa - deg2rad(5) }
        let seconds = closeHauled.map { Double($0) * dt } ?? .infinity
        #expect(seconds <= 3.5, "\(knots) kn tack close-hauled after \(seconds) s")
        let slowest = run.map(\.speed).min()! / beat.speed
        #expect(slowest >= 0.4, "\(knots) kn tack slowed to \(slowest) of her entry speed")
    }

    /// A gybe from the groove to the groove, on the plane with the spinnaker up, costs about 3.5 m and
    /// she is back to full speed about 7 s after the tap, having kept the plane and the spinnaker. Skiff@3's
    /// momentum (speeding up 1.5 s) and rudder drag 0.25 (#263) made it cheaper than #244 §6.2's 8 m / 12 s;
    /// the range is the measured cost (3.5 / 3.7 m, 7.0 / 6.7 s at 10 / 12 kn) with a margin.
    @Test(arguments: [10.0, 12])
    func gybeCostsAbout3_5MetresAndRecoversIn7Seconds(knots: Double) {
        let groove = Autohelm.grooveAngle(.downwind, tws: tws(knots), boatClass: skiff)
        let entry = skiff.polar.speed(twa: groove, tws: tws(knots))
        let run = tap(starboard(twa: groove, speed: entry, isPlaning: true, spinnaker: .up), knots: knots)
        #expect(zip(run, run.dropFirst()).filter { $0.boomSide != $1.boomSide }.count == 1)
        #expect(run.last!.boomSide == .starboard)
        #expect(run.allSatisfy { $0.isPlaning && $0.spinnaker == .up }, "kept the plane and the spinnaker")
        let lost = metresLost(run, along: -Vec2.heading(windFrom))
        #expect(lost >= 2.5 && lost <= 5, "\(knots) kn gybe lost \(lost) m")
        // Back to within 1% of her entry speed, for good.
        let slow = run.lastIndex { $0.speed < 0.99 * entry } ?? 0
        let recovered = Double(slow + 1) * dt
        #expect(recovered >= 5.5 && recovered <= 8.5, "\(knots) kn gybe back to full speed after \(recovered) s")
    }
}
