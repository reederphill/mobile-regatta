import RegattaCore

/// The gap planner (#584 stage 4): in the last seconds before the gun a live bot picks the hole in the line that scores
/// best against the fleet as she sees it, and makes it her spot (`plannedSpot`, ahead of every other read of her spot in
/// `spotOnLine`); the start plan she sails (`starboardHoldAim`) times her run in to it as it does to any spot. The one
/// place a bot plans against other boats: the start's version of #583's planner.
///
/// **Information, not foresight** (ADR 0001): everything here is read from her `SeatView`. The other boats are projected to
/// the gun on the course and speed they hold now (as the keep-clear lookahead reads them), never on their inputs: in the
/// last 15–20 s the fleet is slow and committed, so a held course is a fair guess.
///
/// - Candidate holes (`holeSpots`): spots along the line, in from its ends.
/// - Each hole's score, metres up the course: the room to leeward of it at the gun (to the projected boat nearest it on
///   the pin side, or to a hull length clear of the pin, capped at `roomCap` hull lengths); less
///   what she would be late there (her run in, sailed forward on her class's dynamics, `secondsToLine`, against the time
///   to the gun), in metres at the polar's best; less the metres the hole gives up to the favoured end, as she reads the
///   line's bias (`lineBiasSine`); less `airCost` for each projected boat just to windward of it at the gun (within
///   `airLengths` on the committee side), whose backwind she would start in.
/// - Vetoed: a hole a projected boat sits on (within `occupiedLengths`), or whose run in comes within `keepClearDistance`
///   hull lengths of a projected boat on the way: she can only barge into it.
/// - Kept: she moves to a new hole only when it beats hers by `switchMargin` hull lengths' worth, so she doesn't dither
///   between holes as the projection moves.
///
/// Skill is depth (`StartPlanDepth`): a live bot from the National band plans from `nationalFromSeconds` before the gun
/// over every hole; from the Regional band, from `regionalFromSeconds` over every other hole; below, she keeps her
/// strategy's own spot. The horizon is the fleet oracle's (#584 stage 2, hold-one-out): it waits about 17 m below the line
/// at T−10 and runs in for the last 12 s or so, so a National bot chooses her hole some 8 s before that run in begins.
extension BotBrain {
    /// How deep a live bot plans her start (#584 stage 4).
    struct StartPlanDepth: Sendable, Equatable {
        /// Seconds before the gun from which she plans.
        var fromSeconds: Double
        /// Every `stride`th hole of `holeSpots`.
        var stride: Int
    }

    static let nationalFromSeconds = 20.0
    static let regionalFromSeconds = 10.0
    /// The candidate holes: spots along the line, 0 the pin … 1 the committee boat, a tenth of it in from either end: a hole
    /// at a mark is one she rounds the mark into, and back out of if she is over.
    static let holeSpots: [Double] = (2...18).map { Double($0) * 0.05 }
    /// She plans again only this often, seconds, and holds her hole between.
    static let startReplanSeconds = 1.0
    /// Hull lengths of room to leeward past which more is worth no more.
    static let roomCap = 3.0
    /// A projected boat within this many hull lengths along the line, on the committee side, puts her in its air.
    static let airLengths = 2.5
    /// Metres a boat in her air costs: about what a few seconds of backwind take off her first minute.
    static let airCost = 6.0
    /// A projected boat within this many hull lengths of the hole at the gun sits on it.
    static let occupiedLengths = 1.0
    /// Hull lengths' worth of score a new hole must beat hers by.
    static let switchMargin = 1.0

    /// Her depth at `skill`, a live bot's; nil below the Regional band, and for the suite's profiles and the cautious bot.
    static func startPlanDepth(skill: Double) -> StartPlanDepth? {
        guard ProbeKnobs.plannerOn else { return nil }
        if skill >= BotTier.national.skillBand.lowerBound { return StartPlanDepth(fromSeconds: nationalFromSeconds, stride: 1) }
        if skill >= BotTier.regional.skillBand.lowerBound { return StartPlanDepth(fromSeconds: regionalFromSeconds, stride: 2) }
        return nil
    }

    /// A live bot's every decision before her start: from her depth's `fromSeconds` before the gun, once a
    /// `startReplanSeconds`, she plans her hole (`plannedSpot`). Before the gun only: after it she is late, and runs in
    /// where she is.
    mutating func planStart(_ b: SeatView.OwnBoat, _ view: SeatView) {
        guard let depth = startPlanning, b.status == .prestart, view.time < 0, -view.time <= depth.fromSeconds else { return }
        if let last = lastStartPlanTime, view.time - last < Self.startReplanSeconds { return }
        lastStartPlanTime = view.time
        startPlans += 1
        let spots = Swift.stride(from: 0, to: Self.holeSpots.count, by: depth.stride).map { Self.holeSpots[$0] }
        let length = view.boatClass.hull.length
        let current = plannedSpot ?? spotOnLine
        var best: (spot: Double, score: Double)?
        var currentScore: Double?
        for spot in spots + [current] {
            guard let score = holeScore(spot, b, view) else { continue }
            if spot == current { currentScore = score }
            if best.map({ score > $0.score }) ?? true { best = (spot, score) }
        }
        guard let best else { return }
        // Hers holds unless the best beats it by the margin (or hers is vetoed).
        if let currentScore, best.score - currentScore < Self.switchMargin * length { return }
        plannedSpot = best.spot
    }

    /// Where `boat` is at the gun on the course and speed she holds now, kept below the line (she won't be over it).
    func projectedAtGun(_ boat: SeatView.OtherBoat, _ view: SeatView, after seconds: Double) -> Vec2 {
        let line = view.course.startLine
        var p = boat.position + Vec2.heading(boat.heading) * (boat.speed * seconds)
        let side = line.side(p)
        if side > 0 {
            // Pulled back to the line along the axis: a boat reaching the line holds there rather than going over.
            p -= view.course.upwind * side
        }
        return p
    }

    /// Hole `spot`'s score, metres up the course (the type's doc), or nil if vetoed.
    func holeScore(_ spot: Double, _ b: SeatView.OwnBoat, _ view: SeatView) -> Double? {
        let c = view.course
        let line = c.startLine
        let length = view.boatClass.hull.length
        let along = line.committee.position - line.pin.position
        let point = line.pin.position + along * spot
        let toGun = -view.time
        let others = view.others.filter { !$0.isGhost }
        let projected = others.map { projectedAtGun($0, view, after: toGun) }
        // Occupied at the gun: a hole with a boat on it is no hole.
        if projected.contains(where: { ($0 - point).length < Self.occupiedLengths * length }) { return nil }
        // Her run in: the bearing to the hole, no closer to the wind than her hold angle, timed by her dynamics.
        let bearing = (point - b.position).bearing
        let hold = Self.holdAngle(view)
        let angle = wrapAngle(b.windDirection - bearing)
        let heading = angle >= hold ? bearing : wrapAngle(b.windDirection - hold)
        var run = secondsToLine(b, view, heading: heading, ease: false, within: max(toGun, 1) + 20)
        if angle < hold {
            // Up to windward of her hold course: she goes round to it, along the line at her positioning speed and two
            // tacks.
            let reach = view.boatClass.polar.speed(twa: .pi / 2, tws: b.polarWindSpeed) * b.speedShadow * Self.positioningSpeed
            let landing = line.courseSideRate(Vec2.heading(heading)) > 0.05
                ? b.position + Vec2.heading(heading) * (-line.side(b.position) / line.courseSideRate(Vec2.heading(heading)))
                : b.position
            run = min(run, 60) + abs((point - landing).dot(along.normalized)) / max(reach, 0.3) + Self.tackSeconds(view) * 2
        }
        guard run.isFinite else { return nil }
        // The way in: no closer than keep-clear distance to a projected boat at the same moment.
        let steps = 8
        for k in 1...steps {
            let t = min(run, toGun) * Double(k) / Double(steps)
            let mine = b.position + (point - b.position) * (t / max(run, 1e-6))
            for other in others {
                let theirs = other.position + Vec2.heading(other.heading) * (other.speed * t)
                if (theirs - mine).length < Self.keepClearDistance * length { return nil }
            }
        }
        let vmg = max(view.boatClass.polar.bestUpwind(tws: b.polarWindSpeed).vmg, 0.3)
        // Room to leeward at the gun: along the line, pinward, to the nearest projected boat near the line, or to the pin
        // itself, a hull length clear of it: the mark bounds the room at the end nobody else is.
        let near = projected.filter { -line.side($0) < 4 * length }
        let pinward = near.map { (point - $0).dot(along.normalized) }.filter { $0 > 0 }
        let toPin = max(0, spot * line.length - length)
        let room = min(pinward.min() ?? .infinity, toPin, Self.roomCap * length)
        let windward = near.map { ($0 - point).dot(along.normalized) }.filter { $0 > 0 && $0 < Self.airLengths * length }.count
        let late = max(0, run - toGun)
        let biasMetres = lineBiasSine(b, view) * line.length
        // The favoured end's lead over the hole: the committee end's if the bias is positive, else the pin's.
        let biasLoss = biasMetres >= 0 ? biasMetres * (1 - spot) : -biasMetres * spot
        return room - late * vmg - biasLoss - Self.airCost * Double(windward)
    }
}
