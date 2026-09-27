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
        guard canReach(rightOfWay, keepClear, hull: hull) else { return false }
        return hits(swept(rightOfWay, hull: hull), keepClear, hull: hull)
    }

    /// The right-of-way boat's hull at every check of the sweep, heading offset by heading offset: what `hits`
    /// tries the keep-clear boat against, worked out once for a boat it is asked of against many (the escape
    /// simulation's candidates, #92).
    struct Swept {
        /// By heading offset (`headingOffsets`), then by check: none if `seconds` is shorter than `stepTicks`.
        let hulls: [[[Vec2]]]
        /// Each hull's centre, likewise.
        let centres: [[Vec2]]
        /// Seconds from now of each check.
        let times: [Double]
    }

    /// `rightOfWay`'s `Swept` hulls.
    func swept(_ rightOfWay: Boat, hull: BoatClass.Hull) -> Swept {
        let ticks = RulesConfig.ticks(seconds)
        guard ticks >= stepTicks else { return Swept(hulls: [], centres: [], times: []) }
        let outline = hull.outline
        let times = stride(from: stepTicks, through: ticks, by: stepTicks).map { Double($0) * Race.dt }
        var hulls: [[[Vec2]]] = [], centres: [[Vec2]] = []
        for offset in headingOffsets {
            var swept = rightOfWay
            swept.heading = rightOfWay.heading + offset
            let velocity = swept.velocityOverGround
            let at = times.map { rightOfWay.position + velocity * $0 }
            centres.append(at)
            hulls.append(at.map { position in
                swept.position = position
                return swept.hull(outline: outline)
            })
        }
        return Swept(hulls: hulls, centres: centres, times: times)
    }

    /// `hits` against the right-of-way boat's `swept` hulls, for a pair `canReach` has let through.
    func hits(_ swept: Swept, _ keepClear: Boat, hull: BoatClass.Hull) -> Bool {
        guard !swept.times.isEmpty else { return false }
        let outline = hull.outline
        let clearance = clearance.metres(hullLength: hull.length)
        // Hulls whose centres are further apart than this can neither touch nor come within the clearance.
        let reach = 2 * outline.reduce(0) { max($0, $1.length) } + clearance
        // The keep-clear boat's hull at each check, the same whichever heading the other is tried on: built the
        // first time a swept hull comes within reach of it.
        let keepClearCentres = swept.times.map { keepClear.position + keepClear.velocityOverGround * $0 }
        var keepClearHulls = [[Vec2]?](repeating: nil, count: keepClearCentres.count)
        for (h, heading) in swept.hulls.enumerated() {
            for (k, sweptHull) in heading.enumerated() where (swept.centres[h][k] - keepClearCentres[k]).length <= reach {
                if keepClearHulls[k] == nil {
                    var ahead = keepClear
                    ahead.position = keepClearCentres[k]
                    keepClearHulls[k] = ahead.hull(outline: outline)
                }
                let keepClearHull = keepClearHulls[k]!
                if Collision.penetration(sweptHull, keepClearHull) != nil { return true }
                if clearance > 0, Collision.distance(convex: sweptHull, simplePolygon: keepClearHull) < clearance {
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
