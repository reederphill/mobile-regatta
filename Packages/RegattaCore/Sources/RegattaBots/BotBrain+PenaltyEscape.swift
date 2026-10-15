import RegattaCore

// "Penalty turns in clear water" (#528, the owner's ruling of 2026-10-15): under fleet-rules@6 on a class she turns by
// hand, a boat owing a turn with boats across its sweep moves to clear water rather than waiting in the pack, starts it
// with a thin margin rather than blind at its latest start, and once she picks a way out of a boat crossing it while she
// turns, holds that way until her sweep is clear. What she commits to is the direction of the way out (`EscapeSide`, the
// owner's ruling on round 2), not a heading: a heading near moving boats is one something is still closing on, so she
// picks it again along that direction whenever it stops keeping her room. The heading she steers either time is one
// function's (`penaltyEscapeHeading`), which #529's shared scorer replaces.

extension BotBrain {
    /// A way out of a boat crossing her penalty turn's sweep she has chosen and holds until clear (#528): the heading
    /// she steers, since when, and the direction she committed to.
    struct PenaltyEscape: Sendable, Equatable {
        var heading: Double
        var since: Double
        /// The way out she has committed to, once she steers off her heading (`EscapeSide`).
        var side: EscapeSide?
        /// The heading she first chose away from the boats (#528 fix 3): she picks again round it, never round the
        /// heading she has come to, so a long hold cannot ratchet her round.
        var toward: Double
    }

    /// The direction of a way out she has committed to (#528, the owner's ruling of 2026-10-15, "commit the direction,
    /// not the heading"): the side of `from`, her heading when she first steered off it, she escapes to (+1 to
    /// starboard of it). Whenever she picks her heading again it is on that side (or `from` itself), so she cannot swing
    /// back through the boats she is leaving.
    struct EscapeSide: Sendable, Equatable {
        var from: Double
        var side: Double

        /// The side she commits to steering `heading` from her heading `current`, or `latched` once she has one; nil
        /// while she holds her heading.
        static func latch(_ latched: EscapeSide?, current: Double, heading: Double) -> EscapeSide? {
            if let latched { return latched }
            let change = wrapAngle(heading - current)
            return abs(change) < BotBrain.clearingStep / 2 ? nil : EscapeSide(from: current, side: change > 0 ? 1 : -1)
        }

        func allows(_ heading: Double) -> Bool { side * wrapAngle(heading - from) > -BotBrain.clearingStep / 2 }
    }

    /// The heading she sails to clear water for her penalty turn (#528), or nil with none she may sail: on her own tack,
    /// every `clearingStep` within `penaltyEscapeSpread` of her heading (or of `around`, the way out she first chose:
    /// picking again round the heading she has come to ratcheted her ~145° round over a long pre-start hold), off any mark (`avoidMarks`) or the race area's
    /// edge (`avoidEdges`; marks bind, they are never weighed), before the gun not over the line early (`crossesEarly`),
    /// and on the side of a way out she has committed to (`side`, `EscapeSide`). First, the water it keeps her
    /// from every boat (`penaltyEscapeRoom`: before her first crossing rules 10 to 13 still bind her, after it rule
    /// 21.2), as far as `roomLengths`; then the later first conflict of her turn's sweep (`turnSweep`, each of `ways`,
    /// `angle` of it) from where the heading puts her after `horizon` seconds at her speed, a clear sweep best. In a pack
    /// (a boat inside her room already, every heading tied on it) in `openWater`, the room the heading leaves her from
    /// every boat where it puts her breaks the tie: she moves out. Then the water it leaves her to the race area's edge
    /// (`penaltyEscapeEdgeWater`, #528 fix 5): of two ways out that clear her alike she takes the one away from the
    /// edge, before she holds (as a tie between the two sides alone, after holding, it never broke one: the sweep's
    /// seconds always differ). At a mark she waits: a tie goes to the least change of heading (she holds), then the
    /// heading that leaves her furthest from the nearest boat. Non-mutating; #529's shared scorer replaces its body.
    func penaltyEscapeHeading(_ b: SeatView.OwnBoat, _ view: SeatView, ways: [Double], angle: (Double) -> Double,
                              horizon: Double, side: EscapeSide? = nil, around: Double? = nil,
                              openWater: Bool = false) -> Double? {
        let tack = wrapAngle(b.windDirection - b.heading) >= 0
        let others = view.others.filter { !$0.isGhost }
        let nearest = others.min { ($0.position - b.position).length < ($1.position - b.position).length }
        let steps = Int((Self.penaltyEscapeSpread / Self.clearingStep).rounded())
        let room = view.boatClass.hull.length * roomLengths
        var best: (heading: Double, clear: Double, score: Double, after: Double, edge: Double, change: Double,
                    apart: Double)?
        let centre = around ?? b.heading
        for step in -steps...steps {
            let heading = wrapAngle(centre + Double(step) * Self.clearingStep)
            let relative = wrapAngle(b.windDirection - heading)
            guard (relative >= 0) == tack, abs(relative) >= BoatDynamics.noGoAngle(view.boatClass.polar) + deg2rad(5),
                  abs(relative) <= .pi - deg2rad(10),
                  avoidMarks(b, view, desired: heading) == nil, avoidEdges(b, view, desired: heading) == nil,
                  side?.allows(heading) ?? true,
                  !crossesEarly(b, view, heading: heading) else { continue }
            let there = (position: b.position + Vec2.heading(heading) * (b.speed * horizon), heading: heading,
                         seconds: horizon)
            guard penaltyTurnFits(b, view, at: there.position) else { continue }
            let clear = min(room, penaltyEscapeRoom(b, view, heading: heading, horizon: horizon))
            let score = clear < room ? 0 : ways.map {
                turnSweep(b, view, direction: $0, angle: angle($0), from: there)?.seconds ?? .infinity
            }.max() ?? 0
            let change = (abs(wrapAngle(heading - b.heading)) / Self.clearingStep).rounded()
            let apart = nearest.map { ($0.position + $0.velocity * horizon - there.position).length } ?? .infinity
            // In a pack in open water, the room she has where the heading puts her breaks the tie before holding
            // does: at a mark she waits.
            let after = openWater && clear < room
                ? min(room, others.map { ($0.position + $0.velocity * horizon - there.position).length }.min() ?? .infinity)
                : 0
            let edge = penaltyEscapeEdgeWater(view, at: there.position)
            if let current = best {
                if (clear, score, after, edge) < (current.clear, current.score, current.after, current.edge) { continue }
                if (clear, score, after, edge) == (current.clear, current.score, current.after, current.edge) {
                    if change > current.change { continue }
                    if change == current.change, apart <= current.apart { continue }
                }
            }
            best = (heading, clear, score, after, edge, change, apart)
        }
        return best?.heading
    }

    /// The water `point` has to the race area's edge (#528 fix 5, the owner's ruling: "away from the pack" is toward
    /// where the boats aren't, at the line and the leeward gate the race area's edge), in whole hull lengths up to
    /// `penaltyEscapeEdgeLengths`: further in, every heading is alike. The start line before the gun is not weighed:
    /// with it the Club cell's missed-penalty DSQs went 16 to 28 (main 19); `crossesEarly` already keeps her off it.
    func penaltyEscapeEdgeWater(_ view: SeatView, at point: Vec2) -> Double {
        let water = view.course.raceArea.inset(point)
        return min(Self.penaltyEscapeEdgeLengths, max(0, (water / view.boatClass.hull.length).rounded(.down)))
    }

    /// The closest any boat comes to her, metres between centres, while she sails `heading` at her speed for her
    /// keep-clear lookahead or `horizon` seconds, the longer, every boat sailing on in a straight line
    /// (`closestApproach`).
    func penaltyEscapeRoom(_ b: SeatView.OwnBoat, _ view: SeatView, heading: Double, horizon: Double) -> Double {
        let lookahead = max(keepClearLookahead, horizon)
        return view.others.lazy.filter { !$0.isGhost }
            .map { Self.closestApproach(of: $0, to: b, heading: heading, lookahead: lookahead) }.min() ?? .infinity
    }

    /// Whether `heading` is still one she may hold for her penalty turn (#528): no boat comes within `roomLengths` of
    /// her on it (`penaltyEscapeRoom`), it sails her into no mark or edge, and her turn still fits in the race area
    /// where it puts her after `horizon` (`penaltyTurnFits`).
    func penaltyEscapeHolds(_ b: SeatView.OwnBoat, _ view: SeatView, heading: Double, horizon: Double) -> Bool {
        penaltyEscapeRoom(b, view, heading: heading, horizon: horizon) >= view.boatClass.hull.length * roomLengths
            && avoidMarks(b, view, desired: heading) == nil && avoidEdges(b, view, desired: heading) == nil
            && !crossesEarly(b, view, heading: heading)
            && penaltyTurnFits(b, view, at: b.position + Vec2.heading(heading) * (b.speed * horizon))
    }

    /// Whether her penalty turn, either way, fits in the race area from `point` (#528 fix 2): every point of a disc a
    /// turn's diameter round it (her turning speed over her rate at the penalty rudder, as `penaltyCircleRadius` reads
    /// another boat's) is in the race area, sampled every 45°. A way out to clear water that leaves her turn sweeping
    /// the race area's edge is no way out: before the gun the area reaches only a line's length below the line, and
    /// a way out from the crowd there sailed her to its edge (BotEdgeTests).
    func penaltyTurnFits(_ b: SeatView.OwnBoat, _ view: SeatView, at point: Vec2) -> Bool {
        let speed = closeHauledSpeed(b, view) * HandTackTable.penaltyTurn.speed
        let rate = Self.penaltyRudder(view) * view.boatClass.steering.turnRate(speed: speed)
        guard rate > 0 else { return true }
        let diameter = 2 * speed / rate + view.boatClass.hull.length / 2
        return (0..<8).allSatisfy { view.course.isInRaceArea(point + Vec2.heading(Double($0) * .pi / 4) * diameter) }
    }
}
