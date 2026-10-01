import Testing
@testable import RegattaCore

/// skiff@5's cone starts from her bow and stern (`BoatClass.WindShadow.coneFromHull`): its near edge is the line between
/// them, whichever way she points across the wind, not a line square to the wind across her centre. Everything else about
/// it is the square cone's, and a class without the flag is unchanged.
@Suite struct ConeFromHullTests {
    let shadow: BoatClass.WindShadow
    var length: Double { shadow.coneLength / 9 }

    init() throws {
        shadow = try BoatClassFile.bundled(id: SkiffFixtures.classID, version: 5).content.windShadow
    }

    /// A caster at the origin heading `heading`, the apparent wind blowing from straight ahead of the world's +y.
    func cone(heading: Double) -> ShadowCone {
        ShadowCone(apex: .zero, apparentWindDirection: .pi, heading: heading, windwardSide: .starboard, shadow: shadow)
    }

    @Test func bowAndSternAreTheNearEdge() {
        // Wind from the north (direction 0 blows from north: apparent direction π is the way it blows to, south): the
        // cone runs south. Heading east, across the wind: her hull lies square to the axis, so the edge is square.
        let beam = cone(heading: .pi / 2)
        #expect(abs(beam.nearA.y) < 1e-9 && abs(beam.nearB.y) < 1e-9)
        #expect(abs(abs(beam.nearA.x - beam.nearB.x) - length) < 1e-9, "a hull length across")
        // Heading north, close-hauled-ish 30° off: the edge runs from her bow to her stern, slanted to the axis.
        let slanted = cone(heading: deg2rad(30))
        let edge = slanted.nearA - slanted.nearB
        #expect(abs(edge.length - length) < 1e-9, "bow to stern is her hull length")
        let acrossShare: Double = length * sin(deg2rad(30)), alongShare: Double = length * cos(deg2rad(30))
        #expect(abs(abs(edge.x) - acrossShare) < 1e-9)
        #expect(abs(abs(edge.y) - alongShare) < 1e-9)
        // The ends are her bow and stern on the water.
        let bow = slanted.apex + slanted.axis.rightPerp * slanted.nearA.x + slanted.axis * slanted.nearA.y
        #expect((bow - slanted.forward * shadow.bowY).length < 1e-9)
        let stern = slanted.apex + slanted.axis.rightPerp * slanted.nearB.x + slanted.axis * slanted.nearB.y
        #expect((stern - slanted.forward * shadow.sternCorner.y).length < 1e-9)
    }

    /// Beam to the wind it is the square cone: the hull is the class's cone width at the boat across.
    @Test func beamOnItIsTheSquareCone() {
        let beam = cone(heading: .pi / 2)
        #expect(abs(shadow.coneWidthAtBoat - length) < 1e-9)
        var square = shadow
        square.coneFromHull = false
        let old = ShadowCone(apex: .zero, apparentWindDirection: .pi, heading: .pi / 2, windwardSide: .starboard, shadow: square)
        for along in stride(from: 0.5, to: shadow.coneLength, by: 3.1) {
            for across in stride(from: -9.0, through: 9, by: 1.3) {
                let p = beam.axis * along + beam.axis.rightPerp * across
                let a = beam.factor(at: p), b = old.factor(at: p)
                // The backwind's trapezoid sits to windward and astern, off the cone's side here; compare the cone alone.
                if beam.backwindFactor(at: p) == 1 { #expect(abs(a - b) < 1e-9, "\(along) \(across)") }
            }
        }
    }

    /// Slanted, it reaches from the bow's side to the stern's, and fades with distance and to its sides.
    @Test func slantedItFollowsTheHullAndFades() {
        let c = cone(heading: deg2rad(30))
        let dir = c.axis
        let across = dir.rightPerp
        func inside(_ along: Double, _ x: Double) -> Bool { c.factor(at: dir * along + across * x) < 1 }
        // Upwind of the centre, beside the bow end of the hull (the hull's upwind end), it is cast too.
        let (up, down) = c.nearA.y < c.nearB.y ? (c.nearA, c.nearB) : (c.nearB, c.nearA)
        #expect(up.y < 0 && down.y > 0)
        #expect(inside(up.y + 0.05, up.x), "just downwind of her upwind end")
        #expect(!inside(up.y - 0.05, up.x), "just upwind of it, outside")
        #expect(inside(down.y + 0.05, down.x), "just downwind of her downwind end")
        // Nothing upwind of the near edge on the other side either.
        #expect(!inside(down.y - 0.4, down.x + (down.x - up.x).magnitude), "outside beyond her downwind end's side")
        // Along the middle the loss falls with distance down the axis, and is nothing at the far end.
        let mid = (up.x + down.x) / 2
        #expect(c.factor(at: dir * 2 + across * mid) < c.factor(at: dir * 20 + across * mid))
        #expect(c.factor(at: dir * (shadow.coneLength - 0.01) + across * mid) > 0.999)
        #expect(c.factor(at: dir * (shadow.coneLength + 0.01) + across * mid) == 1)
        // Across it falls to nothing at the sides.
        let span = c.span(at: 15)!
        #expect(c.factor(at: dir * 15 + across * ((span.lo + span.hi) / 2)) < c.factor(at: dir * 15 + across * (span.hi - 0.05)))
        #expect(c.factor(at: dir * 15 + across * (span.hi + 0.05)) == 1)
        #expect(span.hi - span.lo > c.span(at: 4)!.hi - c.span(at: 4)!.lo, "it widens")
    }

    /// Head to wind her hull lies along the axis: the near edge has no width, and the cone is still one cone.
    @Test func headToWindItStillWidens() {
        let c = cone(heading: .pi) // the way the wind blows to, so her bow points down the axis
        #expect(abs(c.nearA.x) < 1e-9 && abs(c.nearB.x) < 1e-9)
        let near = c.span(at: 1)!, far = c.span(at: 30)!
        #expect(near.hi - near.lo < far.hi - far.lo && far.hi - far.lo > 0)
        #expect(c.factor(at: c.axis * 3) < 1)
    }

    /// A class without the flag keeps its square cone, bit for bit: skiff@4's.
    @Test func skiffFourKeepsItsSquareCone() throws {
        let v4 = try BoatClassFile.bundled(id: SkiffFixtures.classID, version: 4).content.windShadow
        #expect(!v4.coneFromHull)
        let c = ShadowCone(apex: .zero, apparentWindDirection: .pi, heading: deg2rad(30), windwardSide: .starboard, shadow: v4)
        #expect(c.nearA == Vec2(-v4.coneWidthAtBoat / 2, 0) && c.nearB == Vec2(v4.coneWidthAtBoat / 2, 0))
        for along in stride(from: 0.2, to: v4.coneLength, by: 2.3) {
            let p = c.axis * along + c.axis.rightPerp * 0.4
            let lateral = 0.4, width = c.halfWidth(at: along)
            let cone = lateral < width ? 1 - v4.lossCloseIn * (1 - along / v4.coneLength) * (1 - lateral / width) : 1
            #expect(c.factor(at: p) / c.backwindFactor(at: p) == cone || abs(c.factor(at: p) / c.backwindFactor(at: p) - cone) < 1e-12)
        }
    }
}
