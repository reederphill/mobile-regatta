import Testing
@testable import RegattaCore

/// #70 acceptance: the boat moves by her class file alone, in a constant wind with no current.
@Suite struct BoatDynamicsTests {
    let dinghy: BoatClass
    let dt = Race.dt
    /// The wind blows from the north.
    let windFrom = 0.0

    init() throws {
        dinghy = try Fixtures.boatClass()
    }

    func env(knots: Double) -> BoatDynamics.Environment {
        .constant(windDirection: windFrom, windSpeed: metresPerSecond(knots: knots))
    }

    /// Heading with the wind `twa` over the starboard side.
    func heading(twa: Double) -> Double { wrapAngle(windFrom - twa) }

    func closeHauled(knots: Double) -> PolarTable.Optimum {
        dinghy.polar.bestUpwind(tws: metresPerSecond(knots: knots))
    }

    func run(_ state: BoatDynamics.State, _ control: BoatDynamics.Control, knots: Double, seconds: Double,
             boatClass: BoatClass? = nil) -> BoatDynamics.State {
        var s = state
        for _ in 0..<Int((seconds / dt).rounded()) {
            s = BoatDynamics.advance(s, control: control, env: env(knots: knots), boatClass: boatClass ?? dinghy, dt: dt)
        }
        return s
    }

    @Test func fromRestOnABeamReachReachesAboutTwoThirdsOfTargetInFourSeconds() {
        let twa = deg2rad(90)
        let target = dinghy.polar.speed(twa: twa, tws: metresPerSecond(knots: 10))
        let s = run(.init(heading: heading(twa: twa), speed: 0), .init(rudder: 0), knots: 10, seconds: 4)
        let fraction = s.speed / target
        #expect(fraction >= 0.60 && fraction <= 0.66, "speed/target \(fraction)")
    }

    /// Turn rate over one tick with the rudder already hard over to bear away, in degrees per second.
    func fullRudderTurnRate(twa: Double, speed: Double) -> Double {
        let start = BoatDynamics.State(heading: heading(twa: twa), speed: speed, rudder: -1)
        let next = BoatDynamics.advance(start, control: .init(rudder: -1), env: env(knots: 10), boatClass: dinghy, dt: dt)
        return -rad2deg(wrapAngle(next.heading - start.heading)) / dt
    }

    @Test func fullRudderTurnsAboutThirtyDegreesASecondCloseHauledAndTenStopped() {
        let beat = closeHauled(knots: 10)
        // Bearing away from close-hauled: the turn is all rudder.
        let sailing = fullRudderTurnRate(twa: beat.twa, speed: beat.speed)
        #expect(sailing >= 27 && sailing <= 33, "close-hauled \(sailing)°/s")
        let stopped = fullRudderTurnRate(twa: deg2rad(90), speed: 0)
        #expect(stopped >= 9 && stopped <= 11, "stopped \(stopped)°/s")
    }

    @Test func luffedHeadToWindShootsTwoHullLengthsBeforeStopping() {
        let beat = closeHauled(knots: 10)
        var s = BoatDynamics.State(heading: windFrom, speed: beat.speed)
        let start = s.position
        var seconds = 0.0
        while s.speed >= metresPerSecond(knots: 0.3) {
            s = BoatDynamics.advance(s, control: .init(rudder: 0), env: env(knots: 10), boatClass: dinghy, dt: dt)
            seconds += dt
            if seconds >= 60 { break }
        }
        #expect(seconds < 60)
        let hullLengths = (s.position - start).length / dinghy.hull.length
        #expect(hullLengths >= 1.5 && hullLengths <= 2.5, "shot \(hullLengths) hull lengths in \(seconds) s")
    }

    @Test func stoppedHeadToWindFallsOffPastThirtyFiveDegreesWithinTenSeconds() {
        var s = BoatDynamics.State(heading: windFrom, speed: 0)
        var fellOffAt: Double?
        for tick in 1...Int(10 / dt) {
            s = BoatDynamics.advance(s, control: .init(rudder: 0), env: env(knots: 10), boatClass: dinghy, dt: dt)
            if abs(wrapAngle(windFrom - s.heading)) >= deg2rad(35) {
                fellOffAt = Double(tick) * dt
                break
            }
        }
        #expect(fellOffAt != nil, "still at \(rad2deg(abs(wrapAngle(windFrom - s.heading))))° after 10 s")
    }

    @Test func holdingTheEaseSlowsAReachToTheClassEaseFraction() {
        let twa = deg2rad(90)
        let target = dinghy.polar.speed(twa: twa, tws: metresPerSecond(knots: 10))
        let s = run(.init(heading: heading(twa: twa), speed: target), .init(rudder: 0, ease: true), knots: 10, seconds: 30)
        let expected = dinghy.ease.speedFraction * target
        #expect(abs(s.speed - expected) <= 0.05 * expected, "eased \(s.speed) m/s, expected \(expected)")
        // Letting the sheets in again speeds her back up.
        let drawing = run(s, .init(rudder: 0), knots: 10, seconds: 40)
        #expect(abs(drawing.speed - target) < 0.01 * target)
    }

    @Test func aClassCopysContactFactorSetsPostContactSpeed() {
        var gentle = dinghy
        gentle.contact.boat = 0.9
        gentle.contact.mark = 0.8
        let speed = 3.0
        #expect(BoatDynamics.speed(after: .boat, speed: speed, boatClass: dinghy) == speed * dinghy.contact.boat)
        #expect(BoatDynamics.speed(after: .boat, speed: speed, boatClass: gentle) == speed * 0.9)
        #expect(BoatDynamics.speed(after: .mark, speed: speed, boatClass: dinghy) == speed * dinghy.contact.mark)
        #expect(BoatDynamics.speed(after: .mark, speed: speed, boatClass: gentle) == speed * 0.8)
        #expect(dinghy.contact.boat != 0.9 && dinghy.contact.mark != 0.8)
    }

    @Test(arguments: [6.0, 10, 14, 20])
    func steadyCloseHauledSailsThePolar(knots: Double) {
        let beat = closeHauled(knots: knots)
        // Half a degree free of the fall-off edge.
        let twa = beat.twa + deg2rad(0.5)
        let polar = dinghy.polar.speed(twa: twa, tws: metresPerSecond(knots: knots))
        let s = run(.init(heading: heading(twa: twa), speed: 0), .init(rudder: 0), knots: knots, seconds: 60)
        #expect(abs(s.speed - polar) <= 0.02 * polar, "\(knots) kn: \(s.speed) m/s vs polar \(polar)")
        #expect(abs(wrapAngle(s.heading - heading(twa: twa))) < 1e-9, "a boat sailing close-hauled holds her course")
    }

    @Test func rudderSlewsAtTheClassRate() {
        let s = BoatDynamics.advance(.init(heading: heading(twa: deg2rad(90)), speed: 3), control: .init(rudder: 1),
                                     env: env(knots: 10), boatClass: dinghy, dt: dt)
        #expect(abs(s.rudder - dinghy.steering.rudderSlew * dt) < 1e-12)
    }

    @Test func rudderDragSlowsATurningBoat() {
        let twa = deg2rad(90)
        let target = dinghy.polar.speed(twa: twa, tws: metresPerSecond(knots: 10))
        let straight = BoatDynamics.advance(.init(heading: heading(twa: twa), speed: target), control: .init(rudder: 0),
                                            env: env(knots: 10), boatClass: dinghy, dt: dt)
        let turning = BoatDynamics.advance(.init(heading: heading(twa: twa), speed: target, rudder: 1), control: .init(rudder: 1),
                                           env: env(knots: 10), boatClass: dinghy, dt: dt)
        #expect(turning.speed < straight.speed)
    }

    @Test func currentMovesTheBoatWithoutChangingSpeedThroughTheWater() {
        let start = BoatDynamics.State(heading: heading(twa: deg2rad(90)), speed: 3)
        let still = BoatDynamics.advance(start, control: .init(rudder: 0), env: env(knots: 10), boatClass: dinghy, dt: 1)
        var flowing = env(knots: 10)
        flowing.current = Vec2(0, 1)
        let carried = BoatDynamics.advance(start, control: .init(rudder: 0), env: flowing, boatClass: dinghy, dt: 1)
        #expect(carried.speed == still.speed)
        #expect(((carried.position - still.position) - Vec2(0, 1)).length < 1e-12)
    }
}
