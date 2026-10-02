import Testing
@testable import RegattaCore

/// skiff@5's cone starts from her bow and stern (`BoatClass.WindShadow.coneFromHull`): its near edge is the line between
/// them, whichever way she points across the wind, not a line square to the wind across her centre. Everything else about
/// it is the square cone's, and a class without the flag is unchanged.
@Suite struct ConeFromHullTests {
    let shadow: BoatClass.WindShadow
    var length: Double { 4.9 }

    /// skiff@5's cone with its axis along the apparent wind (no swing astern), for the cone's own shape; `ConeSwingTests`
    /// are about the swing.
    init() throws {
        var file = try BoatClassFile.bundled(id: SkiffFixtures.classID, version: 5).content.windShadow
        file.coneSwing = 0
        shadow = file
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

/// skiff@5 swings its cone's axis half the way from downwind to straight astern (`BoatClass.WindShadow.coneSwing`), so the
/// shadow opens behind her rather than off to leeward across a reach; a class with no swing keeps its axis down the wind.
@Suite struct ConeSwingTests {
    let file: BoatClass.WindShadow

    init() throws {
        file = try BoatClassFile.bundled(id: SkiffFixtures.classID, version: 5).content.windShadow
    }

    func cone(heading: Double, windFrom: Double, swing: Double) -> ShadowCone {
        var shadow = file
        shadow.coneSwing = swing
        return ShadowCone(apex: .zero, apparentWindDirection: windFrom, heading: heading, windwardSide: .starboard, shadow: shadow)
    }

    @Test func axisIsPartWayFromDownwindToAstern() {
        #expect(file.coneSwing == 0.5 && file.coneLength == 10 * 4.9 && file.coneWidthAtEnd == 6 * 4.9)
        // Heading east, the wind from the north: downwind is south, astern is west; half way is south-west.
        let (east, north) = (Double.pi / 2, 0.0)
        let none = cone(heading: east, windFrom: north, swing: 0), half = cone(heading: east, windFrom: north, swing: 0.5)
        #expect((none.axis - Vec2(0, -1)).length < 1e-12, "no swing: straight downwind")
        #expect((half.axis - Vec2(-0.5.squareRoot(), -0.5.squareRoot())).length < 1e-12, "half way: south-west")
        #expect((cone(heading: east, windFrom: north, swing: 1).axis - Vec2(-1, 0)).length < 1e-12, "all the way: astern")
        #expect(half.apparentWindDirection == north && abs(half.axis.length - 1) < 1e-12)
        // The short way round the circle: downwind 200°, astern 160° (heading 340°): half way is 180°.
        let across = cone(heading: deg2rad(340), windFrom: deg2rad(20), swing: 0.5)
        #expect((across.axis - Vec2.heading(.pi)).length < 1e-12)
    }

    @Test func theShadowFallsAlongTheSwungAxis() {
        let (east, north) = (Double.pi / 2, 0.0)
        let swung = cone(heading: east, windFrom: north, swing: 0.5), plain = cone(heading: east, windFrom: north, swing: 0)
        let far = 20.0
        // 20 m down the swung axis is in the swung cone and not in the plain one (south-west of it, 45 degrees off its
        // axis), and the other way round for a point on the plain axis.
        #expect(swung.factor(at: swung.axis * far) < 1 && plain.factor(at: swung.axis * far) == 1)
        #expect(plain.factor(at: plain.axis * far) < 1 && swung.factor(at: plain.axis * far) == 1)
        // The swung cone is wider at its end than the old class's was (6 hull lengths against 4.2).
        #expect(swung.span(at: 40).map { $0.hi - $0.lo }! > 4.2 * 4.9 * 0.9)
    }

    @Test func aClassWithNoSwingKeepsItsAxis() throws {
        let v4 = try BoatClassFile.bundled(id: SkiffFixtures.classID, version: 4).content.windShadow
        #expect(v4.coneSwing == 0)
        let c = ShadowCone(apex: .zero, apparentWindDirection: deg2rad(30), heading: deg2rad(100), windwardSide: .port, shadow: v4)
        #expect(c.axis == -Vec2.heading(deg2rad(30)))
    }
}
