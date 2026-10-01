/// The disturbed air one boat casts (#10): her wind shadow, a cone downwind of her along her apparent
/// wind, and her backwind, a small zone to windward of her. Both are sized by her class
/// (`BoatClass.WindShadow`, ADR 0004). They slow the boats inside them and never turn the wind.
///
/// The cone's loss tapers from its full value on the axis at the boat to nothing at the far end and at the edges.
/// Its near edge is a line across her centre, square to the wind, or for a class that casts it from her bow and
/// stern (`BoatClass.WindShadow.coneFromHull`) the line from her bow to her stern, whichever way she points.
/// The backwind has two shapes. A class with a backwind inner length (#298) casts a right trapezoid on her windward
/// quarter, astern of her stern, following her heading and her windward side (`Boat.tack`, which flips at the boom
/// crossing, #71): its loss fades from full at the stern edge to nothing at the far edge, and one of those edges
/// slants (`BoatClass.WindShadow.backwindSpan(out:)`). A class with a backwind running angle casts none while she is
/// running, her true wind angle at or past it. A class without an inner length casts #79's band straight up her
/// apparent wind, tapering at the edges. A ghost casts neither (`Race.shadowCone(ofSeat:)`).
public struct ShadowCone: Sendable, Equatable {
    /// The caster's position (her hull's centre): the cone's apex and the backwind zone's origin.
    public let apex: Vec2
    /// Unit vector downwind along the caster's apparent wind: the cone's axis. #79's backwind band runs the
    /// other way, `-axis`.
    public let axis: Vec2
    /// Unit vector along the caster's heading: the trapezoid's forward (#298).
    public let forward: Vec2
    /// Unit vector square to her heading towards her windward side, the side the wind comes over (#298).
    public let windward: Vec2
    /// The class's sizes and losses, metres and fractions.
    public let shadow: BoatClass.WindShadow
    /// The caster's true wind angle, radians, 0 to π, or nil when not known: the backwind is off while she is running
    /// (`BoatClass.WindShadow.backwindRunningAngle`), and a cone with no angle casts it on every point of sail.
    public let trueWindAngle: Double?
    /// The caster's speed through the water, m/s, or nil when not known: her backwind trapezoid scales with it
    /// (`BoatClass.WindShadow.backwindScale(speed:)`), and a cone with no speed draws it at its full size.
    public let speed: Double?
    /// The cone's near edge's two ends, in its own frame (x across the axis towards `axis.rightPerp`, y down it from the
    /// apex), metres: `coneWidthAtBoat` across her centre, or her bow and her stern. The far end's corners are
    /// `coneWidthAtEnd` across at `coneLength`.
    public let nearA: Vec2
    public let nearB: Vec2
    public var nearEdge: [Vec2] { [nearA, nearB] }

    /// The shadow `caster` casts, from her position, apparent wind, heading and windward side.
    public init(caster: Boat, shadow: BoatClass.WindShadow) {
        self.init(apex: caster.position, apparentWindDirection: caster.apparentWind.direction,
                  heading: caster.heading, windwardSide: caster.tack, shadow: shadow, trueWindAngle: caster.twa,
                  speed: caster.speedThroughWater)
    }

    public init(apex: Vec2, apparentWindDirection: Double, heading: Double, windwardSide: Tack, shadow: BoatClass.WindShadow,
                trueWindAngle: Double? = nil, speed: Double? = nil) {
        self.trueWindAngle = trueWindAngle
        self.speed = speed
        let axis = -Vec2.heading(apparentWindDirection), forward = Vec2.heading(heading)
        self.apex = apex
        self.axis = axis
        self.forward = forward
        self.windward = windwardSide == .starboard ? forward.rightPerp : -forward.rightPerp
        self.shadow = shadow
        if shadow.coneFromHull {
            // Her bow and stern on the centreline, read in the cone's frame.
            let across = axis.rightPerp
            nearA = Vec2(forward.dot(across) * shadow.bowY, forward.dot(axis) * shadow.bowY)
            nearB = Vec2(forward.dot(across) * shadow.sternCorner.y, forward.dot(axis) * shadow.sternCorner.y)
        } else {
            nearA = Vec2(-shadow.coneWidthAtBoat / 2, 0)
            nearB = Vec2(shadow.coneWidthAtBoat / 2, 0)
        }
    }

    /// Length of the cone along `axis`, metres.
    public var length: Double { shadow.coneLength }

    /// Half-width of the cone `distance` metres down its axis: from half its width at the boat to half
    /// its width at its end, straight between.
    public func halfWidth(at distance: Double) -> Double {
        let t = (distance / shadow.coneLength).clamped(to: 0...1)
        return (shadow.coneWidthAtBoat + (shadow.coneWidthAtEnd - shadow.coneWidthAtBoat) * t) / 2
    }

    /// The wind multiplier this boat's shadow and backwind leave at `p`: 1 outside both.
    public func factor(at p: Vec2) -> Double {
        let offset = p - apex
        let along = offset.dot(axis)
        let lateral = abs(offset.cross(axis))
        guard shadow.backwindInnerLength != nil else {
            // #79's band, exactly as it was: the classes before #298 sail as they did.
            if along > 0 { return coneFactor(along: along, lateral: lateral) }
            let upwind = -along
            let width = shadow.backwindWidth / 2
            guard upwind > 0, upwind < shadow.backwindLength, lateral < width else { return 1 }
            return 1 - shadow.backwindLoss * (1 - upwind / shadow.backwindLength) * (1 - lateral / width)
        }
        let cone = shadow.coneFromHull ? hullConeFactor(along: along, across: offset.dot(axis.rightPerp))
                                       : (along > 0 ? coneFactor(along: along, lateral: lateral) : 1)
        return cone * trapezoidFactor(at: offset)
    }

    /// The multiplier this boat's backwind trapezoid alone leaves at `p` (#298), without her cone: 1 outside it, and
    /// 1 everywhere for a class with #79's band, or while she is running (`isRunning`).
    public func backwindFactor(at p: Vec2) -> Double {
        guard shadow.backwindInnerLength != nil else { return 1 }
        return trapezoidFactor(at: p - apex)
    }

    /// Whether she is running, so casts no backwind: her true wind angle at or past her class's running angle.
    public var isRunning: Bool {
        guard let limit = shadow.backwindRunningAngle, let twa = trueWindAngle else { return false }
        return twa >= limit
    }

    /// Whether `p` is inside this boat's backwind trapezoid (#298); false for a class with #79's band.
    public func isInBackwind(_ p: Vec2) -> Bool { backwindFactor(at: p) < 1 }

    /// The cone's multiplier `along` metres down its axis and `lateral` off it (`along` > 0).
    private func coneFactor(along: Double, lateral: Double) -> Double {
        guard along < shadow.coneLength else { return 1 }
        let width = halfWidth(at: along)
        guard lateral < width else { return 1 }
        return 1 - shadow.lossCloseIn * (1 - along / shadow.coneLength) * (1 - lateral / width)
    }

    /// The cone's multiplier `along` metres down its axis and `across` it (towards `axis.rightPerp`), for a cone from
    /// her bow and stern. Its shape is the hull of `nearEdge` and the far end's corners, so at each distance down the
    /// axis it spans from one side to the other (`span(at:)`): the loss is full at her centre's distance and upwind of it
    /// and fades straight to nothing at the far end, and across the span fades from its middle to nothing at its sides,
    /// as the square cone's does.
    private func hullConeFactor(along: Double, across: Double) -> Double {
        guard let span = span(at: along) else { return 1 }
        let half = (span.hi - span.lo) / 2, off = abs(across - (span.lo + span.hi) / 2)
        guard off < half else { return 1 }
        let fade = 1 - along.clamped(to: 0...shadow.coneLength) / shadow.coneLength
        return 1 - shadow.lossCloseIn * fade * (1 - off / half)
    }

    /// Where the cone reaches across the axis `along` metres down it: nil outside it, else the least and the greatest
    /// `across`. The hull of four points meets a line across the axis between the points' crossings with the segments
    /// that join them, so those are all that's needed.
    public func span(at along: Double) -> (lo: Double, hi: Double)? {
        guard along < shadow.coneLength else { return nil }
        let far = shadow.coneWidthAtEnd / 2
        var lo = Double.infinity, hi = -Double.infinity
        func cross(_ p: Vec2, _ q: Vec2) {
            guard p.y != q.y, along >= min(p.y, q.y), along <= max(p.y, q.y) else { return }
            let x = p.x + (q.x - p.x) * (along - p.y) / (q.y - p.y)
            lo = min(lo, x)
            hi = max(hi, x)
        }
        let (a, b) = (nearA, nearB)
        cross(a, b)
        for corner in [Vec2(-far, shadow.coneLength), Vec2(far, shadow.coneLength)] {
            cross(a, corner)
            cross(b, corner)
        }
        return hi > lo ? (lo, hi) : nil
    }

    /// The backwind trapezoid's multiplier at `offset` from the caster (#298). In her frame (out to windward, forward),
    /// from P1, her windward stern corner (`BoatClass.WindShadow.sternCorner`): it reaches `backwindWidth` out along
    /// the stern line, and astern between the start and end of its span there (`BoatClass.WindShadow.backwindSpan(out:)`),
    /// one of whose edges slants. The loss is full at its start (the stern edge) and fades straight to nothing at its
    /// end (the far edge). Nothing while she is running.
    private func trapezoidFactor(at offset: Vec2) -> Double {
        guard !isRunning else { return 1 }
        let out = offset.dot(windward) - shadow.sternCorner.x
        // Her speed scales the trapezoid's length astern: a boat stopped casts none (`backwindScale(speed:)`).
        let scale = shadow.backwindScale(speed: speed)
        guard scale > 0 else { return 1 }
        let astern = (shadow.sternCorner.y - offset.dot(forward)) / scale
        guard out > 0, out < shadow.backwindWidth, astern > 0, let span = shadow.backwindSpan(out: out) else { return 1 }
        guard astern > span.start, astern < span.end else { return 1 }
        return 1 - shadow.backwindLoss * (1 - (astern - span.start) / (span.end - span.start))
    }

    /// The wind multiplier `cones` leave at `p` together: each one's factor multiplied, never below
    /// the class's stacking floor (`floor`).
    public static func factor(at p: Vec2, of cones: [ShadowCone], floor: Double) -> Double {
        var factor = 1.0
        for cone in cones { factor *= cone.factor(at: p) }
        return max(factor, floor)
    }
}
