/// The disturbed air one boat casts (#10): her wind shadow, a cone downwind of her along her apparent
/// wind, and her backwind, a small zone the other way, to windward of her. Both are sized by her class
/// (`BoatClass.WindShadow`, ADR 0004). They slow the boats inside them and never turn the wind.
///
/// Inside either, the loss tapers from its full value on the axis at the boat to nothing at the far
/// end and at the edges. A ghost casts neither (`Race.shadowCone(ofSeat:)`).
public struct ShadowCone: Sendable, Equatable {
    /// The caster's position: the cone's apex and the backwind zone's base.
    public let apex: Vec2
    /// Unit vector downwind along the caster's apparent wind: the cone's axis. The backwind zone runs
    /// the other way, `-axis`.
    public let axis: Vec2
    /// The class's sizes and losses, metres and fractions.
    public let shadow: BoatClass.WindShadow

    /// The shadow `caster` casts, from her position and apparent wind.
    public init(caster: Boat, shadow: BoatClass.WindShadow) {
        self.init(apex: caster.position, apparentWindDirection: caster.apparentWind.direction, shadow: shadow)
    }

    public init(apex: Vec2, apparentWindDirection: Double, shadow: BoatClass.WindShadow) {
        self.apex = apex
        self.axis = -Vec2.heading(apparentWindDirection)
        self.shadow = shadow
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
        if along > 0 {
            guard along < shadow.coneLength else { return 1 }
            let width = halfWidth(at: along)
            guard lateral < width else { return 1 }
            return 1 - shadow.lossCloseIn * (1 - along / shadow.coneLength) * (1 - lateral / width)
        }
        let upwind = -along
        let width = shadow.backwindWidth / 2
        guard upwind > 0, upwind < shadow.backwindLength, lateral < width else { return 1 }
        return 1 - shadow.backwindLoss * (1 - upwind / shadow.backwindLength) * (1 - lateral / width)
    }

    /// The wind multiplier `cones` leave at `p` together: each one's factor multiplied, never below
    /// the class's stacking floor (`floor`).
    public static func factor(at p: Vec2, of cones: [ShadowCone], floor: Double) -> Double {
        var factor = 1.0
        for cone in cones { factor *= cone.factor(at: p) }
        return max(factor, floor)
    }
}
