import Foundation
import Testing
@testable import RegattaCore

/// The backwind's follow-up to #298, on skiff@5: the trapezoid is turned half a turn from skiff@4's, so its stern edge
/// slants and its far edge is flat, and she casts none while running. In her frame (x out to windward, y forward,
/// origin at the hull's centre, L the 4.9 m hull): P1 her windward stern corner (0.85, −L/2), P2 = P1 + (1 L, −0.5 L),
/// P3 = P2 + (0, −1.5 L), P4 = (P1.x, P1.y − 2 L). Files without the new values keep #298's shape bit for bit.
@Suite struct BackwindSternSlantTests {
    let boatClass: BoatClass
    var shadow: BoatClass.WindShadow { boatClass.windShadow }
    var length: Double { boatClass.hull.length }

    init() throws {
        boatClass = try BoatClassFile.bundled(id: SkiffFixtures.classID, version: 5).content
    }

    /// A caster heading 0 with the wind over her starboard side and the apparent wind on her beam (her cone streams
    /// to leeward, clear of the zone), `trueWindAngle` as given.
    func zone(trueWindAngle: Double? = nil) -> ShadowCone {
        ShadowCone(apex: .zero, apparentWindDirection: .pi / 2, heading: 0, windwardSide: .starboard, shadow: shadow,
                   trueWindAngle: trueWindAngle)
    }

    @Test func sternEdgeSlantsAndFarEdgeIsFlat() {
        let e = 0.01
        let p1 = shadow.sternCorner
        #expect(p1 == Vec2(0.85, -length / 2))
        let p2 = p1 + Vec2(length, -0.5 * length), p3 = p2 + Vec2(0, -1.5 * length), p4 = p1 + Vec2(0, -2 * length)
        let cone = zone()
        func factor(_ p: Vec2) -> Double { cone.backwindFactor(at: p) }

        // Full loss along the slanted stern edge, from its hull-side end to its outboard one.
        #expect(abs(factor(p1 + Vec2(e, -e)) - (1 - shadow.backwindLoss)) < 1e-3, "hull-side end of the stern edge")
        #expect(abs(factor(p2 + Vec2(-e, -2 * e)) - (1 - shadow.backwindLoss)) < 5e-3, "outboard end of the stern edge")
        // The stern edge slants: out at the outboard side the zone starts half a hull length astern of her stern.
        #expect(factor(Vec2(p2.x - e, p1.y - e)) == 1, "outboard, just astern of her stern, is outside")
        #expect(factor(Vec2(p1.x + e, p1.y - e)) < 1, "hull side, just astern of her stern, is inside")
        // The far edge is flat: inside just short of 2 L astern on both sides, outside just past it.
        #expect(factor(p4 + Vec2(e, 2 * e)) < 1 && factor(p3 + Vec2(-e, 2 * e)) < 1)
        #expect(factor(p4 + Vec2(e, -e)) == 1 && factor(p3 + Vec2(-e, -e)) == 1, "past 2 L astern")
        // Nothing ahead of the stern, beyond 1 L out, or to leeward.
        #expect(factor(p1 + Vec2(0.5 * length, e)) == 1, "ahead of the stern")
        #expect(factor(p2 + Vec2(e, -e)) == 1, "beyond 1 L out")
        #expect(factor(Vec2(-p1.x - 0.5 * length, p1.y - length)) == 1, "on the leeward side")
        // The loss fades from the stern edge to the far edge.
        #expect(factor(p1 + Vec2(0.5 * length, -0.6 * length)) < factor(p1 + Vec2(0.5 * length, -1.6 * length)))
        let hullSide = shadow.backwindSpan(out: 0)!, outboard = shadow.backwindSpan(out: length)!
        #expect(hullSide.start == 0 && abs(hullSide.end - 2 * length) < 1e-9)
        #expect(abs(outboard.start - 0.5 * length) < 1e-9 && abs(outboard.end - 2 * length) < 1e-9)
    }

    /// Past 115° of true wind angle she is running and casts none; inside it, and with no angle known, she does.
    @Test func runningCastsNoBackwind() throws {
        let inside = shadow.sternCorner + Vec2(0.5 * length, -0.8 * length)
        for degrees in [30.0, 90, 114.9] {
            let cone = zone(trueWindAngle: deg2rad(degrees))
            #expect(!cone.isRunning && cone.isInBackwind(inside), "\(degrees)°")
        }
        for degrees in [115.0, 135, 180] {
            let cone = zone(trueWindAngle: deg2rad(degrees))
            #expect(cone.isRunning && !cone.isInBackwind(inside) && cone.backwindFactor(at: inside) == 1, "\(degrees)°")
            #expect(cone.factor(at: inside) == 1, "her cone streams the other way")
        }
        #expect(!zone().isRunning && zone().isInBackwind(inside), "no angle known: on every point of sail")

        // The caster's own angle: `ShadowCone(caster:)` reads it off her wind and heading.
        var boat = Boat(id: 0, isPlayer: false, colorIndex: 0, position: .zero, heading: 0, speed: 3, boomSide: .port)
        boat.sailingWind = Wind(direction: .pi, speed: 6) // wind blowing from astern: she is running
        boat.apparentWind = Wind(direction: .pi / 2, speed: 6)
        #expect(boat.twa > deg2rad(170) && ShadowCone(caster: boat, shadow: shadow).isRunning)
        boat.sailingWind = Wind(direction: deg2rad(-45), speed: 6) // close-hauled
        #expect(!ShadowCone(caster: boat, shadow: shadow).isRunning)
    }

    /// Without the new values (skiff@4) the trapezoid is #298's, its far edge slanting, and never off.
    @Test func skiffFourKeepsItsShapeAndIsNeverOff() throws {
        let v4 = try BoatClassFile.bundled(id: SkiffFixtures.classID, version: 4).content.windShadow
        #expect(!v4.backwindSternSlant && v4.backwindRunningAngle == nil)
        let inner = v4.backwindInnerLength!
        for out in stride(from: 0.0, through: v4.backwindWidth, by: v4.backwindWidth / 8) {
            let span = v4.backwindSpan(out: out)!
            #expect(span.start == 0 && span.end == inner + (v4.backwindLength - inner) * out / v4.backwindWidth)
        }
        let cone = ShadowCone(apex: .zero, apparentWindDirection: .pi / 2, heading: 0, windwardSide: .starboard,
                              shadow: v4, trueWindAngle: deg2rad(170))
        #expect(!cone.isRunning && cone.isInBackwind(v4.sternCorner + Vec2(0.5 * v4.backwindWidth, -0.5 * inner)))
    }
}
