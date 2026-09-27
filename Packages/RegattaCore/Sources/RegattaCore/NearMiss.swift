extension RulesConfig.NearMissSweep {
    /// Whether `rightOfWay` would hit `keepClear` had she held her course, within the sweep: the near miss
    /// that triggers a ruling without contact (#9, part (b) of *keep clear*: "sweeping an overlapped
    /// right-of-way boat's hull ±10° over 0.5 s would hit"). The umpire asks it only of overlapped pairs
    /// (`Race`); `hull` is their class's.
    ///
    /// The geometry is a builder value (`docs/rules-file.md`): both boats sail on in straight lines at
    /// their velocities over the ground, checked every `stepTicks` ticks from the first through `seconds`.
    /// The right-of-way boat is tried on each of `headingOffsets` from her heading, at her speed through
    /// the water; the keep-clear boat keeps her own heading and velocity. A hit is the hulls overlapping,
    /// or closer than `clearance`, at any check. Neither boat turns or changes speed along the way: no
    /// dynamics, so it's cheap enough to ask every tick.
    public func hits(_ rightOfWay: Boat, _ keepClear: Boat, hull: BoatClass.Hull) -> Bool {
        let ticks = RulesConfig.ticks(seconds)
        guard ticks >= stepTicks, canReach(rightOfWay, keepClear, hull: hull) else { return false }
        let outline = hull.outline
        let clearance = clearance.metres(hullLength: hull.length)
        let times = stride(from: stepTicks, through: ticks, by: stepTicks).map { Double($0) * Race.dt }
        // The keep-clear boat's hull at each check: the same whichever heading the other is tried on.
        let keepClearHulls = times.map { t in
            var ahead = keepClear
            ahead.position += keepClear.velocityOverGround * t
            return ahead.hull(outline: outline)
        }
        for offset in headingOffsets {
            var swept = rightOfWay
            swept.heading = rightOfWay.heading + offset
            let velocity = swept.velocityOverGround
            for (k, t) in times.enumerated() {
                swept.position = rightOfWay.position + velocity * t
                let sweptHull = swept.hull(outline: outline)
                if Collision.penetration(sweptHull, keepClearHulls[k]) != nil { return true }
                if clearance > 0, Collision.distance(convex: sweptHull, simplePolygon: keepClearHulls[k]) < clearance {
                    return true
                }
            }
        }
        return false
    }

    /// Whether the sweep could hit, either way round: false only when it can't. A cheap test to ask first.
    ///
    /// Each hull lies within `radius` of its centre, however it's turned, so a hit needs the centres within
    /// two radii and the clearance. They close no faster than their velocities over the ground differ, plus
    /// what the sweep's turn adds: turning a boat moving at speed s through angle θ changes her velocity by
    /// 2 s sin(θ/2). Boats sailing side by side are near miss candidates only when close.
    public func canReach(_ a: Boat, _ b: Boat, hull: BoatClass.Hull) -> Bool {
        let radius = hull.outline.reduce(0) { max($0, $1.length) }
        let turned = 2 * max(abs(a.speed), abs(b.speed)) * sin(heading / 2)
        let closing = (a.velocityOverGround - b.velocityOverGround).length + turned
        let horizon = Double(RulesConfig.ticks(seconds)) * Race.dt
        return (a.position - b.position).length
            <= 2 * radius + clearance.metres(hullLength: hull.length) + closing * horizon
    }
}
