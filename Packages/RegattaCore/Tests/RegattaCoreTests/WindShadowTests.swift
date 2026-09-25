import Foundation
import Testing
@testable import RegattaCore

/// #79 acceptance: the shadow cone follows the caster's apparent wind, backwind reaches to windward of
/// her, and both slow a boat without turning her wind (#10).
@Suite struct WindShadowTests {
    let dinghy: BoatClass
    var shadow: BoatClass.WindShadow { dinghy.windShadow }
    var hullLength: Double { dinghy.hull.length }
    let noCurrent = CurrentField(current: nil, tideStateAtGun: 0)

    init() throws {
        dinghy = try Fixtures.boatClass()
    }

    /// Angle between two unit vectors, radians.
    func angle(_ a: Vec2, _ b: Vec2) -> Double { acos(a.dot(b).clamped(to: -1...1)) }

    /// Close-hauled on starboard at her polar speed in her sailing wind.
    func closeHauled(_ boat: inout Boat) {
        let best = dinghy.polar.bestUpwind(tws: boat.windSpeed)
        boat.heading = wrapAngle(boat.windDirection - best.twa)
        boat.speed = best.speed
        boat.boomSide = .port
        boat.rudder = 0
        boat.desiredRudder = 0
    }

    @Test func reachingCastersConeFollowsHerApparentWind() throws {
        let tws = metresPerSecond(knots: 10)
        var caster = Boat(id: 0, isPlayer: true, colorIndex: 0, position: .zero, heading: -.pi / 2,
                          speed: dinghy.polar.speed(twa: .pi / 2, tws: tws))
        let winds = BoatWinds.resolve(ground: Wind(direction: 0, speed: tws), current: .zero, velocityThroughWater: caster.velocity)
        caster.sailingWind = winds.sailing
        caster.apparentWind = winds.apparent
        #expect(abs(caster.twa - .pi / 2) < 1e-12)
        let cone = ShadowCone(caster: caster, shadow: shadow)
        let trueDownwind = -Vec2.heading(caster.windDirection)
        #expect(rad2deg(angle(cone.axis, trueDownwind)) > 10, "axis \(rad2deg(angle(cone.axis, trueDownwind)))° off true downwind")
        #expect((cone.axis - -Vec2.heading(caster.apparentWind.direction)).length < 1e-12)
        // Bent forward: the cone streams aft of the beam on her leeward side.
        #expect(cone.axis.dot(caster.forward) < 0 && cone.axis.dot(trueDownwind) > 0)

        // A race's cone query is the same geometry, at each boat, along her apparent wind.
        let race = try placedRace(current: noCurrent) { snapshot, _ in
            var boat = snapshot.seats[0].boat
            boat.heading = wrapAngle(boat.windDirection - .pi / 2)
            boat.speed = dinghy.polar.speed(twa: .pi / 2, tws: boat.windSpeed)
            snapshot.seats[0].boat = boat
        }
        race.step()
        let raced = try #require(race.shadowCone(ofSeat: 0))
        #expect(raced == ShadowCone(caster: race.boats[0], shadow: race.boatClass.windShadow))
        #expect(raced.apex == race.boats[0].position)
        #expect(rad2deg(angle(raced.axis, -Vec2.heading(race.boats[0].windOverGround.direction))) > 10)
        #expect(race.shadowCone(ofSeat: 2) == nil)
    }

    @Test func lossOneLengthBehindIsAtMostAQuarter() {
        let cone = ShadowCone(apex: .zero, apparentWindDirection: 0, shadow: shadow)
        let behind = cone.axis * hullLength
        #expect(cone.factor(at: behind) >= 0.75 && cone.factor(at: behind) < 1)
        // The loss is greatest on the axis, smaller off it, and gone at the cone's edge.
        let side = cone.axis.rightPerp
        #expect(cone.factor(at: behind + side * 0.5) > cone.factor(at: behind))
        #expect(cone.factor(at: behind + side * (cone.halfWidth(at: hullLength) + 0.01)) == 1)
    }

    @Test func noLossBeyondTheClassConeLength() {
        let cone = ShadowCone(apex: .zero, apparentWindDirection: deg2rad(30), shadow: shadow)
        #expect(cone.length == shadow.coneLength && cone.length == 8 * hullLength)
        #expect(cone.factor(at: cone.axis * (cone.length - 0.5)) < 1)
        #expect(cone.factor(at: cone.axis * (cone.length + 0.01)) == 1)
        #expect(cone.factor(at: cone.axis * (cone.length * 2)) == 1)
    }

    @Test func twoStackedConesNeverGoBelowTheFloor() {
        let near = ShadowCone(apex: .zero, apparentWindDirection: 0, shadow: shadow)
        let nearer = ShadowCone(apex: near.axis * 0.5, apparentWindDirection: 0, shadow: shadow)
        let p = near.axis * 1
        // Together they would take more than 40 %; the class floor holds it at 60 %.
        #expect(near.factor(at: p) * nearer.factor(at: p) < shadow.stackingFloor)
        let stacked = ShadowCone.factor(at: p, of: [near, nearer], floor: shadow.stackingFloor)
        #expect(stacked >= 0.6 && stacked == shadow.stackingFloor)
        #expect(ShadowCone.factor(at: p, of: [near], floor: shadow.stackingFloor) == near.factor(at: p))
    }

    /// A leeward boat close-hauled with another just to windward and ahead of her, in her backwind; and
    /// the same windward boat with the leeward one sailed away.
    func backwindRaces() throws -> (together: Race, alone: Race) {
        func race(together: Bool) throws -> Race {
            try placedRace(current: noCurrent) { snapshot, _ in
                var leeward = snapshot.seats[0].boat
                closeHauled(&leeward)
                let apparent = BoatWinds.resolve(ground: leeward.windOverGround, current: .zero,
                                                 velocityThroughWater: leeward.velocity).apparent
                var windward = Boat(id: 1, isPlayer: true, colorIndex: 1,
                                position: leeward.position + Vec2.heading(apparent.direction) * 0.6 * shadow.backwindLength,
                                heading: leeward.heading, speed: leeward.speed, boomSide: .port)
                windward.sailingWind = leeward.sailingWind
                if !together { leeward.position += Vec2(400, 0) }
                snapshot.seats[0].boat = leeward
                snapshot.seats[1].boat = windward
            }
        }
        return (try race(together: true), try race(together: false))
    }

    @Test func boatJustToWindwardAheadOfALeewardBoatLosesSpeedInHerBackwind() throws {
        let (together, alone) = try backwindRaces()
        let (leeward, windward) = (together.boats[0], together.boats[1])
        // To windward of the leeward boat and ahead of her.
        let side = (windward.position - leeward.position).dot(leeward.forward.rightPerp)
        #expect(side * leeward.relativeWind > 0, "to windward")
        #expect((windward.position - leeward.position).dot(leeward.forward) > 0, "ahead")

        together.step()
        alone.step()
        let cone = try #require(together.shadowCone(ofSeat: 0))
        #expect(cone.factor(at: together.boats[1].position) < 1)
        #expect(together.boats[1].shadow < 1 && alone.boats[1].shadow == 1)
        for _ in 0..<(3 * Race.tickRate) {
            together.step()
            alone.step()
        }
        #expect(together.boats[1].speed < alone.boats[1].speed,
                "backwinded \(together.boats[1].speed) m/s, clear \(alone.boats[1].speed) m/s")
        #expect(!together.drainEvents().contains { if case .ruleCall = $0.kind { true } else { false } }, "the boats never touched")
    }

    @Test func boatInShadowKeepsTheWindDirection() throws {
        // A reaching caster with a reaching boat two lengths down her cone; the same boat alone.
        func race(together: Bool) throws -> Race {
            try placedRace(current: noCurrent) { snapshot, _ in
                var caster = snapshot.seats[0].boat
                caster.heading = wrapAngle(caster.windDirection - .pi / 2)
                caster.speed = dinghy.polar.speed(twa: .pi / 2, tws: caster.windSpeed)
                caster.rudder = 0
                caster.desiredRudder = 0
                let apparent = BoatWinds.resolve(ground: caster.windOverGround, current: .zero,
                                                 velocityThroughWater: caster.velocity).apparent
                let receiver = Boat(id: 1, isPlayer: true, colorIndex: 1,
                                position: caster.position - Vec2.heading(apparent.direction) * 2 * hullLength,
                                heading: caster.heading, speed: caster.speed, boomSide: caster.boomSide)
                if !together { caster.position += Vec2(0, 400) }
                snapshot.seats[0].boat = caster
                snapshot.seats[1].boat = receiver
            }
        }
        let together = try race(together: true), alone = try race(together: false)
        for tick in 0..<(2 * Race.tickRate) {
            together.step()
            alone.step()
            let (shaded, clear) = (together.boats[1], alone.boats[1])
            if tick == 0 {
                #expect(shaded.shadow < 1 && clear.shadow == 1)
                #expect(shaded.sailingWind == clear.sailingWind)
                #expect(shaded.windOverGround == clear.windOverGround)
            }
            // Shadow slows her; it never turns the wind she steers by.
            #expect(shaded.heading == clear.heading)
        }
        #expect(together.boats[1].speed < alone.boats[1].speed)
    }

    @Test func backwindAndShadowFloorComeFromTheClassFile() throws {
        let file = try BoatClassFile.bundled(id: Fixtures.classID, version: Fixtures.version)
        #expect(file.header.placeholders.contains("/windShadow/backwind"))
        #expect(file.header.placeholders.contains("/windShadow/stackingFloor"))
        #expect(shadow.backwindLength == 1.5 * hullLength && shadow.backwindWidth == 1.0 * hullLength)
        #expect(shadow.backwindLoss == 0.1 && shadow.stackingFloor == 0.6)

        let retuned = try BoatClassFile(data: Fixtures.edited([
            (of: #""stackingFloor": 0.6"#, with: #""stackingFloor": 0.5"#),
            (of: #""lengthHullLengths": 1.5"#, with: #""lengthHullLengths": 2.0"#),
            (of: #""loss": 0.1"#, with: #""loss": 0.2"#),
        ])).content.windShadow
        let upwind = Vec2.heading(0) * 1.75 * hullLength
        #expect(ShadowCone(apex: .zero, apparentWindDirection: 0, shadow: shadow).factor(at: upwind) == 1)
        let wider = ShadowCone(apex: .zero, apparentWindDirection: 0, shadow: retuned)
        #expect(wider.factor(at: upwind) < 1)
        #expect(abs(wider.factor(at: Vec2.heading(0) * 0.001) - 0.8) < 1e-3)
        let near = ShadowCone(apex: .zero, apparentWindDirection: 0, shadow: retuned)
        let nearer = ShadowCone(apex: near.axis * 0.5, apparentWindDirection: 0, shadow: retuned)
        let p = near.axis * 1
        #expect(ShadowCone.factor(at: p, of: [near, nearer], floor: retuned.stackingFloor) == near.factor(at: p) * nearer.factor(at: p))

        // A race casts with its class's values.
        let race = try placedRace(current: noCurrent) { _, _ in }
        #expect(race.shadowCone(ofSeat: 0)?.shadow == race.boatClass.windShadow)
    }
}
