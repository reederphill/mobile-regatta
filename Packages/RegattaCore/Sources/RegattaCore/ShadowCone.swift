/// The disturbed air bound to one boat (#10, #377): her backwind, a small zone to windward of her, sized by her class
/// (`BoatClass.WindShadow`, ADR 0004). Her wind shadow is no longer a zone here: since #377 it is the ribbon wake she
/// leaves on the water (`TurbulenceRibbons`), and the cone is gone.
///
/// The backwind has two shapes. A class with a backwind inner length (#298) casts a right trapezoid on her windward
/// quarter, astern of her stern, following her heading and her windward side (`Boat.tack`, which flips at the boom
/// crossing, #71): it fades from full at the stern edge to nothing at the far edge, and one of those edges slants
/// (`BoatClass.WindShadow.backwindSpan(out:)`). A class with a backwind running angle casts none while she is running,
/// her true wind angle at or past it. A class without an inner length casts #79's band straight up her apparent wind,
/// tapering at the edges. A ghost casts neither (`Race.shadowCone(ofSeat:)`).
///
/// A class with a `header` (#377) sails an envelope (`backwindEnvelope(at:)`): the upwash beside her sail, from her
/// mast back past her stern (to a length astern of it on skiff@6) on her windward side, a fan widening aft (on skiff@6
/// a wedge from a point at her mast), for a class with one
/// (`BoatClass.WindShadow.backwindUpwash`, the owner's renders review), else the trapezoid. A boat in it has her
/// wind turned towards her bow (`Race`), plus the header's lull, if any; the envelope is scaled by how hard her sail is
/// working (`backwindSail`), held on the side it was cast on while it fades (`backwindSide`), and faded out below the
/// class's floor speed. A class without one loses wind (or speed) in it, as #298 built it. Never a cone: the type keeps
/// its name for the readers that hold one.
public struct ShadowCone: Sendable, Equatable {
    /// The caster's position (her hull's centre): the backwind zone's origin.
    public let apex: Vec2
    /// The caster's apparent wind direction, radians, the way it blows from.
    public let apparentWindDirection: Double
    /// Unit vector down the caster's apparent wind: #79's backwind band runs the other way, `-axis`.
    public let axis: Vec2
    /// Unit vector along the caster's heading: the trapezoid's forward (#298).
    public let forward: Vec2
    /// Unit vector square to her heading towards her windward side, the side the wind comes over (#298).
    public let windward: Vec2
    /// The class's sizes and losses, metres and fractions.
    public let shadow: BoatClass.WindShadow
    /// The caster's true wind angle, radians, 0 to π, or nil when not known: the backwind is off while she is running
    /// (`BoatClass.WindShadow.backwindRunningAngle`), and a zone with no angle is cast on every point of sail.
    public let trueWindAngle: Double?
    /// The caster's speed through the water, m/s, or nil when not known: her backwind trapezoid scales with it
    /// (`BoatClass.WindShadow.backwindScale(speed:)`) and fades out below the class's floor
    /// (`backwindFloorFactor(speed:)`); a zone with no speed is drawn at its full size.
    public let speed: Double?
    /// How hard her sail is working, 0...1, for a class with a header (#377): her backwind level (`BackwindSails`), which
    /// scales her envelope (`backwindEnvelope(at:)`). 1 unless the race sets it; #298's loss never reads it.
    public var backwindSail = 1.0
    /// The side her envelope is cast on, for a class with a header (#377, `BackwindSails.sides`): her windward side, but
    /// held on the old one while it fades out past her boom crossing. nil: `windward`, her side now.
    public var backwindSide: Tack?

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
        let forward = Vec2.heading(heading)
        self.apparentWindDirection = apparentWindDirection
        self.apex = apex
        self.axis = -Vec2.heading(apparentWindDirection)
        self.forward = forward
        self.windward = windwardSide == .starboard ? forward.rightPerp : -forward.rightPerp
        self.shadow = shadow
    }

    /// The wind (or speed) multiplier this boat's backwind leaves at `p`: 1 outside it. #79's band; #298's trapezoid's
    /// loss; for a class with a header, its lull × the envelope (1 at the defaults' lull of 0: the header carries it).
    public func factor(at p: Vec2) -> Double {
        let offset = p - apex
        guard shadow.backwindInnerLength != nil else {
            // #79's band, exactly as it was: the classes before #298 sail as they did.
            let upwind = -offset.dot(axis), lateral = abs(offset.cross(axis))
            let width = shadow.backwindWidth / 2
            guard upwind > 0, upwind < shadow.backwindLength, lateral < width else { return 1 }
            return 1 - shadow.backwindLoss * (1 - upwind / shadow.backwindLength) * (1 - lateral / width)
        }
        return backwindFactor(at: p)
    }

    /// The multiplier this boat's backwind trapezoid leaves at `p` (#298): 1 outside it, and 1 everywhere for a class
    /// with #79's band, or while she is running (`isRunning`). For a class with a header (#377), its lull × the envelope.
    public func backwindFactor(at p: Vec2) -> Double {
        guard shadow.backwindInnerLength != nil else { return 1 }
        if let header = shadow.header { return 1 - header.lull * backwindEnvelope(at: p) }
        return trapezoidFactor(at: p - apex)
    }

    /// Whether she is running, so casts no backwind: her true wind angle at or past her class's running angle.
    public var isRunning: Bool {
        guard let limit = shadow.backwindRunningAngle, let twa = trueWindAngle else { return false }
        return twa >= limit
    }

    /// How much of her backwind she casts, 1 down to 0: all of it forward of her class's running fade, falling
    /// straight to none at the running angle (`BoatClass.WindShadow.backwindRunningFade`), so bearing away across a
    /// reach fades it out and coming up fades it back in. 1 for a class with no running angle, and when her angle
    /// isn't known.
    public var backwindPresence: Double {
        guard let limit = shadow.backwindRunningAngle, let twa = trueWindAngle else { return 1 }
        guard twa < limit else { return 0 }
        let band = shadow.backwindRunningFade
        guard band > 0, twa > limit - band else { return 1 }
        return (limit - twa) / band
    }

    /// Whether `p` is inside this boat's backwind trapezoid (#298): where it slows (#298's loss) or heads (a class with a
    /// header, #377) a boat; false for a class with #79's band.
    public func isInBackwind(_ p: Vec2) -> Bool {
        shadow.header != nil ? backwindEnvelope(at: p) > 0 : backwindFactor(at: p) < 1
    }

    /// The backwind trapezoid's multiplier at `offset` from the caster (#298). In her frame (out to windward, forward),
    /// from P1, her windward stern corner (`BoatClass.WindShadow.sternCorner`): it reaches `backwindWidth` out along
    /// the stern line, and astern between the start and end of its span there (`BoatClass.WindShadow.backwindSpan(out:)`),
    /// one of whose edges slants. The loss is full at its start (the stern edge) and fades straight to nothing at its
    /// end (the far edge), all of it scaled by `backwindPresence`: less across a reach, nothing while she is running.
    private func trapezoidFactor(at offset: Vec2) -> Double {
        let presence = backwindPresence
        guard presence > 0 else { return 1 }
        let out = offset.dot(windward) - shadow.sternCorner.x
        // Her speed scales the trapezoid's length astern: a boat stopped casts none (`backwindScale(speed:)`).
        let scale = shadow.backwindScale(speed: speed)
        guard scale > 0 else { return 1 }
        let astern = (shadow.sternCorner.y - offset.dot(forward)) / scale
        guard out > 0, out < shadow.backwindWidth, astern > 0, let span = shadow.backwindSpan(out: out) else { return 1 }
        guard astern > span.start, astern < span.end else { return 1 }
        // Below the class's floor speed she casts none (#377; no floor, 1, as #298 built it).
        let floor = shadow.backwindFloorFactor(speed: speed)
        guard floor > 0 else { return 1 }
        return 1 - shadow.backwindLoss * presence * floor * (1 - (astern - span.start) / (span.end - span.start))
    }

    /// Unit vector square to her heading towards the side her envelope is cast on (`backwindSide`, else `windward`).
    private var backwindWindward: Vec2 {
        guard let backwindSide else { return windward }
        return backwindSide == .starboard ? forward.rightPerp : -forward.rightPerp
    }

    /// How much of her backwind zone reaches `p`, 0...1 (#377), on `backwindSide`, times `backwindPresence` (running),
    /// the class's floor (`backwindFloorFactor`) and `backwindSail` (her sail working); 0 outside it, and everywhere for
    /// a class with #79's band. The zone is the upwash beside her sail for a class with one
    /// (`BoatClass.WindShadow.upwashShare(out:along:)`: from her mast back past her stern to its aft end, a fan, full at her
    /// side and nothing at its width out (`upwashWidth(along:)`), bound to her, not scaled by her speed); else her trapezoid, 1 at its stern edge, falling straight
    /// to 0 at its far edge.
    public func backwindEnvelope(at p: Vec2) -> Double {
        guard shadow.backwindInnerLength != nil, backwindSail > 0 else { return 0 }
        // Out to windward first: most boats aren't, and the rest is dearer (the result is the same in any order).
        let offset = p - apex
        let out = offset.dot(backwindWindward) - shadow.sternCorner.x
        if shadow.upwashExtent != nil {
            let share = shadow.upwashShare(out: out, along: offset.dot(forward))
            guard share > 0 else { return 0 }
            return backwindSail * backwindPresence * shadow.backwindFloorFactor(speed: speed) * share
        }
        guard out > 0, out < shadow.backwindWidth else { return 0 }
        let presence = backwindPresence * shadow.backwindFloorFactor(speed: speed)
        guard presence > 0 else { return 0 }
        let scale = shadow.backwindScale(speed: speed)
        guard scale > 0 else { return 0 }
        let astern = (shadow.sternCorner.y - offset.dot(forward)) / scale
        guard out > 0, out < shadow.backwindWidth, astern > 0, let span = shadow.backwindSpan(out: out) else { return 0 }
        guard astern > span.start, astern < span.end else { return 0 }
        return backwindSail * presence * (1 - (astern - span.start) / (span.end - span.start))
    }
}
