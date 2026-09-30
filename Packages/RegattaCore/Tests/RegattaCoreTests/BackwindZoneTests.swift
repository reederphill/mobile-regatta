import Foundation
import Testing
@testable import RegattaCore

/// #298 acceptance: the backwind is a right trapezoid on the caster's windward quarter, astern of her stern. In her
/// frame (x out to windward, y forward, origin at the hull's centre, L the hull length), on ilca-dinghy@4: P1 her
/// windward stern corner (0.63 m, −L/2), P2 = P1 + (1 L, 0), P3 = P2 + (0, −2 L), P4 = P1 + (0, −1.5 L). It follows her
/// heading and her windward side, which flips at the boom crossing (#71).
@Suite struct BackwindZoneTests {
    let boatClass: BoatClass
    var shadow: BoatClass.WindShadow { boatClass.windShadow }
    var length: Double { boatClass.hull.length }

    init() throws {
        boatClass = try BoatClassFile.bundled(id: Fixtures.classID, version: 4).content
    }

    /// A caster at `apex` heading `heading` with the wind over `windward`, the apparent wind on her windward beam (so
    /// her cone streams to leeward, clear of the zone).
    func zone(apex: Vec2 = .zero, heading: Double = 0, windward: Tack = .starboard) -> ShadowCone {
        let wind = heading + (windward == .starboard ? .pi / 2 : -.pi / 2)
        return ShadowCone(apex: apex, apparentWindDirection: wind, heading: heading, windwardSide: windward, shadow: shadow)
    }

    /// The point at `(x, y)` in the caster's frame (x to windward, y forward), with the caster at `apex` on `heading`.
    func point(_ x: Double, _ y: Double, apex: Vec2 = .zero, heading: Double = 0, windward: Tack = .starboard) -> Vec2 {
        let forward = Vec2.heading(heading)
        let out = windward == .starboard ? forward.rightPerp : -forward.rightPerp
        return apex + out * x + forward * y
    }

    @Test func zoneIsARightTrapezoidFromTheWindwardSternCorner() {
        let e = 0.01
        let p1 = Vec2(0.63, -length / 2)
        #expect(shadow.sternCorner == p1 && abs(p1.x / length - 0.15) < 1e-12)
        let p2 = p1 + Vec2(length, 0), p3 = p2 + Vec2(0, -2 * length), p4 = p1 + Vec2(0, -1.5 * length)
        // Off a caster somewhere on the course, heading 30°, so the frame is hers and not the world's.
        let (apex, heading) = (Vec2(120, -40), deg2rad(30))
        let cone = zone(apex: apex, heading: heading)
        // The trapezoid alone (her cone streams the other way, to leeward); `factor(at:)` is the same on this side.
        func factor(_ p: Vec2) -> Double { cone.backwindFactor(at: point(p.x, p.y, apex: apex, heading: heading)) }
        let windwardQuarter = point(p1.x + 0.5 * length, p1.y - 0.5 * length, apex: apex, heading: heading)
        #expect(cone.factor(at: windwardQuarter) == cone.backwindFactor(at: windwardQuarter))

        // Inside: just past P1, and just inside the far edge.
        #expect(factor(p1 + Vec2(e, -e)) < 1 && abs(factor(p1 + Vec2(e, -e)) - (1 - shadow.backwindLoss)) < 1e-3,
                "full loss at the stern edge")
        #expect(factor(p2 + Vec2(-e, -e)) < 1)
        let farMiddle = (p3 + p4) / 2
        #expect(factor(farMiddle + Vec2(0, 2 * e)) < 1 && factor(farMiddle + Vec2(0, 2 * e)) > 1 - 0.01 * shadow.backwindLoss,
                "nearly nothing just inside the far edge")
        #expect(factor(p3 + Vec2(-e, 2 * e)) < 1 && factor(p4 + Vec2(e, 2 * e)) < 1)
        // The loss fades from the stern edge to the far edge.
        #expect(factor(p1 + Vec2(0.5 * length, -0.5 * length)) < factor(p1 + Vec2(0.5 * length, -1.2 * length)))

        // Outside: ahead of the stern, past 2 L, beyond the slanted edge, beyond 1 L out, and on the leeward side.
        #expect(factor(p1 + Vec2(0.5 * length, e)) == 1, "ahead of the stern")
        #expect(factor(Vec2(0, 0)) == 1 && factor(Vec2(p1.x + 0.5 * length, length)) == 1, "alongside and ahead")
        #expect(factor(p3 + Vec2(-e, -e)) == 1, "past 2 L astern")
        #expect(factor(p4 + Vec2(e, -e)) == 1, "past the inner edge's 1.5 L")
        #expect(factor(farMiddle + Vec2(0, -2 * e)) == 1, "beyond the slanted edge")
        #expect(factor(p2 + Vec2(e, -e)) == 1, "beyond 1 L out")
        #expect(factor(Vec2(-p1.x - 0.5 * length, p1.y - 0.5 * length)) == 1, "on the leeward side")
        #expect(factor(Vec2(p1.x - e, p1.y - 0.5 * length)) == 1, "inside the windward corner's line")
    }

    @Test func zoneSwitchesSidesAtTheBoomCrossing() throws {
        // A boat head to wind, turning from starboard tack to port: the zone is on her starboard quarter until
        // the boom crosses, then on her port quarter.
        var boat = Boat(id: 0, isPlayer: true, colorIndex: 0, position: .zero, heading: 0, speed: 2, boomSide: .port)
        #expect(boat.tack == .starboard)
        let quarter = (x: shadow.sternCorner.x + 0.5 * length, y: shadow.sternCorner.y - 0.5 * length)
        let starboardQuarter = Vec2(quarter.x, quarter.y), portQuarter = Vec2(-quarter.x, quarter.y)
        let before = ShadowCone(caster: boat, shadow: shadow)
        #expect(before.isInBackwind(starboardQuarter) && !before.isInBackwind(portQuarter))
        boat.boomSide = .starboard
        #expect(boat.tack == .port)
        let after = ShadowCone(caster: boat, shadow: shadow)
        #expect(after.isInBackwind(portQuarter) && !after.isInBackwind(starboardQuarter))
        #expect(after.factor(at: portQuarter) == before.factor(at: starboardQuarter), "mirrored")

        // In a race: a boat tacking carries her zone across at the boom crossing, and only there.
        let file = try BoatClassFile.bundled(id: Fixtures.classID, version: 4)
        let race = try placedRace(current: CurrentField(current: nil, tideStateAtGun: 0), boatClass: file.ref) { snapshot, _ in
            var b = snapshot.seats[0].boat
            let best = boatClass.polar.bestUpwind(tws: b.windSpeed)
            b.heading = wrapAngle(b.windDirection - best.twa)
            b.speed = best.speed
            b.boomSide = .port
            b.rudder = 0
            b.desiredRudder = 0
            snapshot.seats[0].boat = b
            snapshot.seats[0].heldInput = .neutral
        }
        race.step()
        race.tap(.tackGybe, seat: 0, atTick: race.tick + 1)
        var crossed = false
        for _ in 0..<(10 * Race.tickRate) {
            let side = race.boats[0].tack
            race.step()
            let b = race.boats[0]
            let cone = try #require(race.shadowCone(ofSeat: 0))
            let forward = b.forward
            let windwardQuarter = b.position + (b.tack == .starboard ? forward.rightPerp : -forward.rightPerp) * quarter.x
                + forward * quarter.y
            let leewardQuarter = b.position - (b.tack == .starboard ? forward.rightPerp : -forward.rightPerp) * quarter.x
                + forward * quarter.y
            #expect(cone.isInBackwind(windwardQuarter) && !cone.isInBackwind(leewardQuarter))
            if b.tack != side {
                #expect(!crossed, "the side flips once")
                #expect(side == .starboard && b.tack == .port)
                crossed = true
            }
        }
        #expect(crossed, "the boom crossed")
    }
}
