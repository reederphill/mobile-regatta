import RegattaCore

// "Penalty turns in clear water" (#528, the owner's ruling of 2026-10-15): under fleet-rules@6 on a class she turns by
// hand, a boat owing a turn with boats across its sweep moves to clear water rather than waiting in the pack, starts it
// with a thin margin rather than blind at its latest start, and once she picks a way out of a boat crossing it while she
// turns, holds that way until her sweep is clear. What she commits to is the direction of the way out (`EscapeSide`, the
// owner's ruling on round 2), not a heading: a heading near moving boats is one something is still closing on, so she
// picks it again along that direction whenever it stops keeping her room. The heading she steers either time is one
// function's (`penaltyEscapeHeading`). #542 PR 2 puts it on #531's shared scorer's prediction (`scoredEscape`): her own
// track turning to each heading (`herTrack`) against every boat rolled on what it is doing (`predictedTrack`), never
// on one giving way to her (a boat owing a turn clears every boat round her, the owner's rule of 2026-10-15), with
// holding, a hard bear-away and, dodging, easing to slow among the candidates. #528's order stands: a candidate that
// clears loses only to one that also clears.

extension BotBrain {
    /// A way out of a boat crossing her penalty turn's sweep she has chosen and holds until clear (#528): the heading
    /// she steers and the direction she committed to.
    struct PenaltyEscape: Sendable, Equatable {
        var heading: Double
        /// The way out she has committed to, once she steers off her heading (`EscapeSide`).
        var side: EscapeSide?
        /// The heading she first chose away from the boats (#528 fix 3): she picks again round it, never round the
        /// heading she has come to, so a long hold cannot ratchet her round.
        var toward: Double
        /// Whether she eases to slow on it (#542 PR 2, the dodge's ease; `EscapeCourse`).
        var ease = false
    }

    /// A way out she may sail (`penaltyEscapeCourse`): the heading, and whether she eases to slow on it (#542 PR 2:
    /// only the dodge, `penaltyDodge`, weighs easing; it is never a keep-clear candidate, owner #529).
    struct EscapeCourse: Sendable, Equatable {
        var heading: Double
        var ease = false
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
    /// heading that leaves her furthest from the nearest boat. Non-mutating. On the shared scorer's prediction
    /// (`scoresPenaltyEscape`, #542 PR 2) unless the seam is off: `penaltyEscapeCourse` without the ease.
    func penaltyEscapeHeading(_ b: SeatView.OwnBoat, _ view: SeatView, ways: [Double], angle: (Double) -> Double,
                              horizon: Double, side: EscapeSide? = nil, around: Double? = nil,
                              openWater: Bool = false) -> Double? {
        penaltyEscapeCourse(b, view, ways: ways, angle: angle, horizon: horizon, side: side, around: around,
                            openWater: openWater)?.heading
    }

    /// The way out she sails for her penalty turn (`penaltyEscapeHeading`), with `eases` (the dodge only) easing to
    /// slow on each heading weighed besides. With the seam `scoresPenaltyEscape` off, #528's straight-line pick
    /// (`straightEscapeHeading`), never easing.
    func penaltyEscapeCourse(_ b: SeatView.OwnBoat, _ view: SeatView, ways: [Double], angle: (Double) -> Double,
                             horizon: Double, side: EscapeSide? = nil, around: Double? = nil,
                             openWater: Bool = false, eases: Bool = false) -> EscapeCourse? {
        guard scoresPenaltyEscape else {
            return straightEscapeHeading(b, view, ways: ways, angle: angle, horizon: horizon, side: side,
                                         around: around, openWater: openWater).map { EscapeCourse(heading: $0) }
        }
        return scoredEscape(b, view, ways: ways, angle: angle, horizon: horizon, side: side, around: around,
                            openWater: openWater, eases: eases)
    }

    /// #528's pick (`penaltyEscapeHeading`), every boat sailing on in a straight line (`penaltyEscapeRoom`) and her
    /// heading's water reckoned at her speed: main's before #542 PR 2, kept behind `scoresPenaltyEscape`.
    func straightEscapeHeading(_ b: SeatView.OwnBoat, _ view: SeatView, ways: [Double], angle: (Double) -> Double,
                               horizon: Double, side: EscapeSide?, around: Double?, openWater: Bool) -> Double? {
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

    /// The boats her way out is weighed against (`scoredEscape`, `penaltyEscapeHolds`), rolled on the shared scorer's
    /// prediction (#542 PR 2, #531's `predictedTrack`): every non-ghost boat that could come within `roomLengths` of
    /// her inside `steps`, on what it is doing (its circle if taking a penalty; can't when not keeping clear of her;
    /// else its measured motion), never giving way to her: a boat owing a turn clears every boat round her (the
    /// owner's rule of 2026-10-15), so `.givesWay` is rolled as measured, the human-seat rule (`reaction`) unchanged.
    /// `extra` is how much further off than `roomLengths` she must pass it: a circle's radius.
    struct EscapeBoat {
        var other: SeatView.OtherBoat
        var track: [Vec2]
        var extra: Double
    }

    func escapeBoats(_ b: SeatView.OwnBoat, _ view: SeatView, steps: Int) -> [EscapeBoat] {
        let room = view.boatClass.hull.length * roomLengths
        let seconds = Double(steps) * Self.keepClearPredictionStep
        let reach = b.speed * 1.5 * seconds + room
        return view.others.compactMap { other in
            guard !other.isGhost,
                  (other.position - b.position).length - other.speed * seconds < reach + room else { return nil }
            var reaction = reaction(of: other, b, view)
            if case .givesWay = reaction { reaction = .measured }
            var extra = 0.0
            if case let .circle(radius) = reaction { extra = radius }
            return EscapeBoat(other: other, track: predictedTrack(of: other, reaction, view, steps: steps), extra: extra)
        }
    }

    /// The closest any of `boats` comes to `track` (hers, a step apart from now), metres between centres less each
    /// boat's `extra`, now included: the room she has now bounds it, as it does a straight line's. #528's tie in a
    /// pack rests on every heading that closes on no boat leaving her the room she has, so a track that never comes
    /// more than `escapeRoomTolerance` inside it leaves her that room: holding alongside a boat at her speed, rolling
    /// the two forward drifts them a rounding error together, which #531's attempt lost the tie on (her heading held
    /// a hair short, 5° off a hair long; `inAPackAtAMarkSheWaits` broke on 5 of 20 seeds).
    static func escapeRoom(_ track: [Vec2], from position: Vec2, _ boats: [EscapeBoat]) -> Double {
        var least = Double.infinity
        for boat in boats {
            let now = (boat.other.position - position).length
            var closest = now
            for i in 0..<min(track.count, boat.track.count) {
                closest = min(closest, (boat.track[i] - track[i]).length)
            }
            if closest > now - escapeRoomTolerance { closest = now }
            least = min(least, closest - boat.extra)
        }
        return least
    }

    /// Metres a track may come inside the room she has now and still leave her it (`escapeRoom`): a rounding error's
    /// worth, far under anything a hull feels.
    static let escapeRoomTolerance = 0.001

    /// `penaltyEscapeHeading` on the shared scorer's prediction (#542 PR 2). Candidates, on her own tack's sailable
    /// angles: every `clearingStep` within `penaltyEscapeSpread` of `around` (or her heading), her heading held, the
    /// hard bear-away (`keepClearDeepest` off the wind), and with `eases` each of them eased to slow. Filters as #528's
    /// (marks, edges, her committed side, before the gun not over the line early, her turn fitting where it puts her).
    /// Each is sailed in her mind (`herTrack`, turning to it and settling to its speed, eased or not) against every
    /// boat (`escapeBoats`) for her keep-clear lookahead or `horizon`, the longer. #528's lexicographic order stands
    /// on that prediction: the room it keeps her (to `roomLengths`), then her sweep from where it puts her, the pack's
    /// room in open water, the race area's edge; a candidate that clears loses only to one that also clears. An eased
    /// one is weighed only if it clears. Then sheeted before eased (she keeps her speed where easing buys nothing), the least change of heading (at a mark
    /// she waits), and the furthest from the nearest boat.
    func scoredEscape(_ b: SeatView.OwnBoat, _ view: SeatView, ways: [Double], angle: (Double) -> Double,
                      horizon: Double, side: EscapeSide?, around: Double?, openWater: Bool,
                      eases: Bool) -> EscapeCourse? {
        let tack = wrapAngle(b.windDirection - b.heading) >= 0
        let sign: Double = tack ? 1 : -1
        let dt = Self.keepClearPredictionStep
        let lookahead = min(max(keepClearLookahead, horizon), Self.scorerHorizon)
        let steps = max(1, Int((lookahead / dt).rounded(.up)))
        let at = max(1, min(steps, Int((horizon / dt).rounded())))
        let boats = escapeBoats(b, view, steps: steps)
        let nearest = boats.min { ($0.other.position - b.position).length < ($1.other.position - b.position).length }
        let room = view.boatClass.hull.length * roomLengths
        let spread = Int((Self.penaltyEscapeSpread / Self.clearingStep).rounded())
        let centre = around ?? b.heading
        var headings: [Double] = []
        func add(_ heading: Double) {
            let heading = wrapAngle(heading)
            if !headings.contains(where: { abs(wrapAngle($0 - heading)) < deg2rad(1) }) { headings.append(heading) }
        }
        for step in -spread...spread { add(centre + Double(step) * Self.clearingStep) }
        add(b.heading)
        add(b.windDirection - sign * Self.keepClearDeepest)
        let closest = BoatDynamics.noGoAngle(view.boatClass.polar) + deg2rad(5)
        typealias Key = (clear: Double, score: Double, after: Double, edge: Double)
        var best: (course: EscapeCourse, key: Key, change: Double, apart: Double)?
        for heading in headings {
            let relative = wrapAngle(b.windDirection - heading)
            guard (relative >= 0) == tack, abs(relative) >= closest, abs(relative) <= Self.keepClearDeepest + 1e-9,
                  avoidMarks(b, view, desired: heading) == nil, avoidEdges(b, view, desired: heading) == nil,
                  side?.allows(heading) ?? true,
                  !crossesEarly(b, view, heading: heading) else { continue }
            let change = (abs(wrapAngle(heading - b.heading)) / Self.clearingStep).rounded()
            for ease in eases ? [false, true] : [false] {
                let track = herTrack(b, view, heading: heading, steps: steps, axis: b.forward, ease: ease).track
                let point = track[at - 1]
                guard penaltyTurnFits(b, view, at: point) else { continue }
                let there = (position: point, heading: heading, seconds: Double(at) * dt)
                let clear = min(room, Self.escapeRoom(track, from: b.position, boats))
                // Eased, only a course that clears: slowing short of room is waiting in the pack, the wait #528 and
                // #534 removed (an eased hold's turn fits where a sheeted one's doesn't, and she sat in the pack).
                if ease, clear < room { continue }
                let score = clear < room ? 0 : ways.map {
                    turnSweep(b, view, direction: $0, angle: angle($0), from: there)?.seconds ?? .infinity
                }.max() ?? 0
                func then(_ boat: EscapeBoat) -> Vec2 { boat.track[min(at, boat.track.count) - 1] }
                let apart = nearest.map { (then($0) - point).length } ?? .infinity
                let after = openWater && clear < room
                    ? min(room, boats.map { (then($0) - point).length - $0.extra }.min() ?? .infinity)
                    : 0
                let edge = penaltyEscapeEdgeWater(view, at: point)
                let key: Key = (clear, score, after, edge)
                if let current = best {
                    if key < current.key { continue }
                    if key == current.key {
                        if ease && !current.course.ease { continue }
                        if ease == current.course.ease {
                            if change > current.change { continue }
                            if change == current.change, apart <= current.apart { continue }
                        }
                    }
                }
                best = (EscapeCourse(heading: heading, ease: ease), key, change, apart)
            }
        }
        return best?.course
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
    /// On the shared scorer's prediction (`scoresPenaltyEscape`, #542 PR 2) the room and where it puts her are
    /// `scoredEscape`'s, eased if she eases on it.
    func penaltyEscapeHolds(_ b: SeatView.OwnBoat, _ view: SeatView, heading: Double, horizon: Double,
                            ease: Bool = false) -> Bool {
        guard avoidMarks(b, view, desired: heading) == nil, avoidEdges(b, view, desired: heading) == nil,
              !crossesEarly(b, view, heading: heading) else { return false }
        let room = view.boatClass.hull.length * roomLengths
        guard scoresPenaltyEscape else {
            return penaltyEscapeRoom(b, view, heading: heading, horizon: horizon) >= room
                && penaltyTurnFits(b, view, at: b.position + Vec2.heading(heading) * (b.speed * horizon))
        }
        let dt = Self.keepClearPredictionStep
        let lookahead = min(max(keepClearLookahead, horizon), Self.scorerHorizon)
        let steps = max(1, Int((lookahead / dt).rounded(.up)))
        let at = max(1, min(steps, Int((horizon / dt).rounded())))
        let track = herTrack(b, view, heading: heading, steps: steps, axis: b.forward, ease: ease).track
        return Self.escapeRoom(track, from: b.position, escapeBoats(b, view, steps: steps)) >= room
            && penaltyTurnFits(b, view, at: track[at - 1])
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
