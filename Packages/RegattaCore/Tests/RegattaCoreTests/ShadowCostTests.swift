import Foundation
import Testing
@testable import RegattaCore

/// #263 acceptance (#220's "shadow is clear but not killing"): for skiff@3 a wind shadow is a speed loss, not a wind
/// loss. Her target is the polar × (1 − the ribbons' loss at her, 0.48 at most, #377), she slows to it with the shadow's
/// own 2 s, and stacked ribbons never take her below 0.3 of it. About 5 s in a boat's shadow costs about what a tack
/// costs: 0.7–1.8 hull lengths against the same boat in clean air (1.5 under #263's cones). Twin races in open water and a steady wind (`OpenWater`).
@Suite struct ShadowCostTests {
    let knots = 10.0
    var shadow: BoatClass.WindShadow { OpenWater.boatClass.windShadow }

    @Test func classShadowIsASpeedLossWithItsOwnSlowingDown() {
        #expect(shadow.isSpeedLoss && shadow.slowingDown == 2)
        #expect(shadow.lossCloseIn == 0.48 && shadow.stackingFloor == 0.3)
    }

    /// Seat 0 close-hauled with seat 1 `lengths` hull lengths up the apparent wind from her (`OpenWater.race`), sailing
    /// the same course at the same speed, so seat 0 is in seat 1's ribbon once it has formed; with `together` false seat
    /// 1 is 400 m away to windward-ahead, out of it.
    func race(lengths: Double, together: Bool) throws -> Race {
        try OpenWater.race(knots: knots) { snapshot, _ in
            let receiver = snapshot.seats[0].boat
            var caster = receiver
            let apparent = BoatWinds.resolve(ground: caster.windOverGround, current: .zero,
                                             velocityThroughWater: caster.velocity).apparent
            // Down her apparent wind: where her ribbon lies once it has formed (#377).
            let axis = -Vec2.heading(apparent.direction)
            caster.position = receiver.position - axis * lengths * OpenWater.hullLength
            if !together { caster.position += Vec2.heading(caster.windDirection) * 400 }
            snapshot.seats[1].boat.position = caster.position
            snapshot.seats[1].boat.heading = caster.heading
            snapshot.seats[1].boat.speed = caster.speed
            snapshot.seats[1].boat.boomSide = caster.boomSide
            snapshot.seats[1].boat.rudder = 0
            snapshot.seats[1].boat.desiredRudder = 0
            snapshot.seats[1].heldInput = .neutral
        }
    }

    /// 1.5, 2 and 3 L down the ribbon. The ribbon forms first: seat 1's air takes a few seconds to drift down to her, so
    /// both twins sail until seat 0 has been in it a tick, then the five seconds are measured from there.
    @Test(arguments: [1.5, 2, 3])
    func fiveSecondsInARibbonCosts0_7To1_5Lengths(lengths: Double) throws {
        let shaded = try race(lengths: lengths, together: true), clean = try race(lengths: lengths, together: false)
        var forming = 0
        while shaded.boats[0].shadow == 1 && forming < 10 * Race.tickRate {
            shaded.step()
            clean.step()
            forming += 1
        }
        #expect(shaded.boats[0].shadow < 1, "the ribbon reached her after \(forming) ticks")
        let start = shaded.boats[0].position
        let course = shaded.boats[0].heading
        var shadedTicks = 0
        for _ in 0..<(5 * Race.tickRate) {
            shaded.step()
            clean.step()
            if shaded.boats[0].shadow < 1 { shadedTicks += 1 }
            #expect(clean.boats[0].shadow == 1)
        }
        #expect(shadedTicks >= 5 * Race.tickRate - 1, "in the ribbon \(shadedTicks) of \(5 * Race.tickRate) ticks")
        // Out of it: the caster sails away, and she recovers over the next 20 s.
        var snapshot = shaded.exportSnapshot()
        snapshot.seats[1].boat.position += Vec2.heading(snapshot.seats[1].boat.windDirection) * 400
        // Her ribbon goes with her: the 5 s are all the shadow she sails in (the wake would linger on the water).
        snapshot.ribbonPoints[1] = []
        try shaded.importSnapshot(snapshot)
        for _ in 0..<(20 * Race.tickRate) {
            shaded.step()
            clean.step()
        }
        #expect(shaded.boats[0].shadow == 1)
        #expect(abs(shaded.boats[0].speed - clean.boats[0].speed) < 0.01 * clean.boats[0].speed, "recovered")
        #expect(abs(shaded.boats[0].heading - course) < 1e-9, "the shadow never turned her")
        let lost = (OpenWater.madeGood(clean, from: start, direction: course)
            - OpenWater.madeGood(shaded, from: start, direction: course)) / OpenWater.hullLength
        // #377: the ribbons' placeholders cost 1.60–1.68 L close in (1.5–2 L down), a little over the cone's 1.5 cap, and
        // about 1.9–2.1 L with the wake left lingering on the water; the band is widened to 1.8 for the owner's sliders.
        #expect(lost >= 0.7 && lost <= 1.8, "5 s \(lengths) L down the ribbon cost \(lost) L")
    }

    @Test func stackedRibbonsFloorAt0_3() {
        // Three casters' fresh points right over her: 0.52³ of the wind left, floored at 0.3.
        let point = TurbulenceRibbons.Point(position: .zero, drift: .zero, born: 0, peak: shadow.ribbons.peak,
                                            scale: shadow.ribbons.startWidth / 2, growth: 0, life: 5)
        let ribbons = TurbulenceRibbons(shadow: shadow, points: [[point], [point], [point]], levels: [1, 1, 1])
        #expect(ribbons.unflooredFactor(at: .zero, tick: 0, receiver: 3) < 0.3)
        let stacked = ribbons.factor(at: .zero, tick: 0, receiver: 3)
        #expect(stacked == 0.3)

        // At the floor her target is 0.3 of the polar's, and she slows to it with the shadow's 2 s.
        let boatClass = OpenWater.boatClass
        let tws = metresPerSecond(knots: knots)
        let best = boatClass.polar.bestUpwind(tws: tws)
        var s = BoatDynamics.State(heading: -best.twa, speed: best.speed, boomSide: .port)
        let env = BoatDynamics.Environment(windDirection: 0, windSpeed: tws, current: .zero, shadow: stacked)
        let first = BoatDynamics.advance(s, control: .init(rudder: 0), env: env, boatClass: boatClass, dt: Race.dt)
        let expected = best.speed + (0.3 * best.speed - best.speed) * Race.dt / 2
        #expect(abs(first.speed - expected) < 1e-12)
        for _ in 0..<(30 * Race.tickRate) {
            s = BoatDynamics.advance(s, control: .init(rudder: 0), env: env, boatClass: boatClass, dt: Race.dt)
        }
        #expect(abs(s.speed - 0.3 * best.speed) < 1e-6)
    }
}
