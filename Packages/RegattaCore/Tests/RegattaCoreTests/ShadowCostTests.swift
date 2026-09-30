import Foundation
import Testing
@testable import RegattaCore

/// #263 acceptance (#220's "shadow is clear but not killing"): for skiff@3 a wind shadow is a speed loss, not a wind
/// loss. Her target is the polar × (1 − 0.48 × the cone's depth at her), she slows to it with the shadow's own 2 s,
/// and stacked cones never take her below 0.3 of it. About 5 s in a boat's shadow costs what a tack costs: 0.7–1.5
/// hull lengths against the same boat in clean air. Twin races in open water and a steady wind (`OpenWater`).
@Suite struct ShadowCostTests {
    let knots = 10.0
    var shadow: BoatClass.WindShadow { OpenWater.boatClass.windShadow }

    @Test func classShadowIsASpeedLossWithItsOwnSlowingDown() {
        #expect(shadow.isSpeedLoss && shadow.slowingDown == 2)
        #expect(shadow.lossCloseIn == 0.48 && shadow.stackingFloor == 0.3)
    }

    /// Seat 0 close-hauled with seat 1 `lengths` hull lengths up her own cone from her (`OpenWater.race`), sailing the
    /// same course at the same speed; with `together` false seat 1 is 400 m away to windward-ahead, out of it.
    func race(lengths: Double, together: Bool) throws -> Race {
        try OpenWater.race(knots: knots) { snapshot, _ in
            let receiver = snapshot.seats[0].boat
            var caster = receiver
            let apparent = BoatWinds.resolve(ground: caster.windOverGround, current: .zero,
                                             velocityThroughWater: caster.velocity).apparent
            caster.position = receiver.position + Vec2.heading(apparent.direction) * lengths * OpenWater.hullLength
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

    @Test(arguments: [1.0, 2, 3])
    func fiveSecondsInAConeCosts0_7To1_5Lengths(lengths: Double) throws {
        let shaded = try race(lengths: lengths, together: true), clean = try race(lengths: lengths, together: false)
        let start = shaded.boats[0].position
        let course = shaded.boats[0].heading
        var shadedTicks = 0
        for _ in 0..<(5 * Race.tickRate) {
            shaded.step()
            clean.step()
            if shaded.boats[0].shadow < 1 { shadedTicks += 1 }
            #expect(clean.boats[0].shadow == 1)
        }
        #expect(shadedTicks >= 5 * Race.tickRate - 1, "in the cone \(shadedTicks) of \(5 * Race.tickRate) ticks")
        // Out of it: the caster sails away, and she recovers over the next 20 s.
        var snapshot = shaded.exportSnapshot()
        snapshot.seats[1].boat.position += Vec2.heading(snapshot.seats[1].boat.windDirection) * 400
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
        #expect(lost >= 0.7 && lost <= 1.5, "5 s \(lengths) L down the cone cost \(lost) L")
    }

    @Test func stackedConesFloorAt0_3() {
        let length = OpenWater.hullLength
        let near = ShadowCone(apex: .zero, apparentWindDirection: 0, heading: 0, windwardSide: .starboard, shadow: shadow)
        let nearer = ShadowCone(apex: near.axis * (0.5 * length), apparentWindDirection: 0, heading: 0, windwardSide: .starboard, shadow: shadow)
        let nearest = ShadowCone(apex: near.axis * (0.75 * length), apparentWindDirection: 0, heading: 0, windwardSide: .starboard, shadow: shadow)
        let p = near.axis * length
        #expect(near.factor(at: p) * nearer.factor(at: p) * nearest.factor(at: p) < 0.3)
        let stacked = ShadowCone.factor(at: p, of: [near, nearer, nearest], floor: shadow.stackingFloor)
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
