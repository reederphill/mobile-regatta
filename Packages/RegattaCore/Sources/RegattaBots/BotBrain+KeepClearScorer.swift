import RegattaCore

// Racing keep-clear on the shared scorer (#531). Racing, when a collision she must keep clear of is coming (today's
// `isAboutToHit` test over `keepClearLookahead`), she no longer gives way to the first boat that trips it by the least
// 5° step off `desired` (`racingKeepClear`, `clearingHeading`). She weighs every boat near her at once
// (`scoreRacingKeepClear`): a set of candidate courses (holding her heading, the headings she can be pointing at in 1, 2
// and 3 s either way at her measured turn rate, `desired`, and the tack when she can tap it by hand), each sailed in her
// mind as she would sail it (`reachable`'s turn and speed loss, #529), against where each other boat will be. Each boat
// is rolled forward on what it is doing and what it owes her (`Reaction`): a boat she must keep clear of holds her
// course as she was sailing it, turning and slowing as she has been over the last second (`measuredMotion`, from the
// per-seat memory `glimpsed`); a boat that owes her gives way in her rule's direction after a reaction delay, at the
// measured turn rate of a bot's give-way turn; a boat clearly not keeping clear (#537's `notKeepingClear`) can't, and a
// stopped one comes to rest; a boat taking a penalty is her circle (#517). A person's boat (`humanSeats`) is never rolled
// giving way: she is sailed on as she has been, or can't when stopped (owner, 2026-10-16). A course is out inside
// `keepClearDistance` × `keepClearMargin` of a boat she must keep clear of or owes mark-room, and inside the collision
// distance of any other; among those left, the one losing her least progress wins, a thin margin costed (`thinMargin`),
// holding her heading costed like every other (#529: never ranked first). She commits to a side, not a heading
// (`KeepClearLatch`): once she turns off one way she looks on that way only, re-picking the heading each decision, until
// the threat is gone or no heading that way clears. A tack chosen here is a committed tack (`KeepClearTack`): abandoned
// only for a boat it would hit on the new tack, never for the threat it was chosen to escape.
//
// Racing only, every live bot but the cautious bot (`caution == nil`, #531 Q5) and the suite's hunter racing; before her
// start `keepClear` is unchanged. Internal: nothing shows it.
extension BotBrain {
    /// Another boat as she saw it at one of her decisions (`glimpsed`): the per-seat memory every live bot keeps (#537,
    /// #531), rebuilt from the seat view in seat order at each decision (`glimpse`), never iterated as a dictionary
    /// (ADR 0002).
    struct Glimpse: Equatable, Sendable {
        var time: Double
        var position: Vec2
        var heading: Double
        var speed: Double
    }

    /// Seconds of sightings the memory keeps (`glimpsed`): her measured motion is read over them (#531: "her measured
    /// acceleration over the last second"). Placeholder.
    static let memorySeconds = 1.0

    /// What `other` has been doing over the memory's last second (`glimpsed`): her turn rate, radians a second (positive
    /// to starboard), clamped to `guardTurnRate`, and her acceleration, metres a second squared, clamped to
    /// `guardSlowing` / `guardSpeeding`. Nothing at a first sighting (a takeover's memory is empty: straight lines).
    func measuredMotion(of other: SeatView.OtherBoat, _ view: SeatView) -> (turnRate: Double, acceleration: Double) {
        guard other.seat < glimpsed.count, let first = glimpsed[other.seat].first, view.time > first.time + 1e-9
        else { return (0, 0) }
        let seconds = view.time - first.time
        return ((wrapAngle(other.heading - first.heading) / seconds).clamped(to: -Self.guardTurnRate...Self.guardTurnRate),
                ((other.speed - first.speed) / seconds).clamped(to: -Self.guardSlowing...Self.guardSpeeding))
    }

    /// How the keep-clear scorer rolls another boat forward (#531 Q3, owner 2026-10-16).
    enum Reaction: Equatable, Sendable {
        /// On her measured motion (`measuredMotion`): a boat she must keep clear of holds her course ("won't" give
        /// way), a person's boat whatever she owes, a boat turning through a tack, a third party.
        case measured
        /// She owes her and gives way: after `giveWayDelay`, turning `turn` way (+1 to starboard) at
        /// `keepClearTurnRate`, losing `keepClearTurnSpeedLoss` a second, by no more than `limit` radians.
        case givesWay(turn: Double, limit: Double)
        /// She can't keep clear (#537's `notKeepingClear`): sailed on as she is, a stopped boat slowing to rest.
        case cannot(stopped: Bool)
        /// Taking a penalty: her circle (`penaltyCircleRadius`), water that doesn't move.
        case circle(radius: Double)
    }

    /// Seconds ahead a boat's measured turn is rolled on (`predictedTrack`), straight after: a turn seen is one she is
    /// finishing. Placeholder: the `reachable` headings' middle second (#529); rolled on for the whole horizon, a
    /// leeward boat's autohelm following a shift was a circle into the windward boat, which luffed hard and fell
    /// astern (`botNotRestrictedSteersAsToday`).
    static let measuredTurnSeconds = 2.0
    /// Seconds a boat that owes her takes to begin giving way (#531 Q3). Placeholder.
    static let giveWayDelay = 0.5
    /// The most a boat that owes her is rolled turning away, radians, when no lesser turn clears her (#531). Placeholder.
    static let giveWayMaxTurn = deg2rad(60)
    /// Metres a second squared a stopped boat comes to rest at (#531: "a stopped boat decelerating to rest").
    /// Placeholder.
    static let stoppedDeceleration = 0.5
    /// Hull lengths, centre to centre, inside which a course meets a boat she needn't keep clear of: the collision
    /// distance (#529's `keepClearCollisionLengths`, 1.15). Placeholder.
    static let collisionLengths = 1.15
    /// Over her out distance by less than this factor, a course passes on a thin margin (`thinMarginCost`), from
    /// `keepClearMargin`. Placeholder.
    static let thinMargin = keepClearMargin
    /// Hull lengths of progress a thin margin costs a course (#531: "the tack wins on a thin margin"). Placeholder.
    static let thinMarginCost = ProbeKnobs.thinMarginCost
    /// Seconds ahead she rolls the boats at most. Placeholder.
    static let scorerHorizon = 10.0

    /// Degrees a second she turns towards a keep-clear heading (#529's trace, the owner's "about 30°/s"): her measured
    /// turn, and every bot's give-way turn, not the class's full-rudder table. Placeholder.
    static let keepClearTurnRate = deg2rad(30)
    /// The share of her speed she loses each second she turns (#529's trace; the owner's "12%/s while turning").
    /// Placeholder.
    static let keepClearTurnSpeedLoss = 0.12
    /// Seconds of her turn the reachable headings are taken at (#529, the owner's ruling).
    static let keepClearReachSeconds: [Double] = [1, 2, 3]
    /// The time step the scorer rolls the boats on, seconds.
    static let keepClearPredictionStep = 0.1
    /// Seconds over which her speed settles to a new heading's polar speed (`herTrack`). Placeholder.
    static let keepClearSpeedSettle = 2.0

    /// The side she has committed to keeping clear (#531, design point 8: "commit to a direction, not a heading"):
    /// +1 bearing away, −1 luffing, in her sailing angle off `desired`.
    struct KeepClearLatch: Equatable, Sendable {
        var side: Double
        /// The boat ahead on her tack she is passing (`overtakeFlag`), held to her lane until clear ahead of it; nil
        /// keeping clear of a crossing.
        var lane: Int? = nil
    }

    /// Hull lengths within which she looks for a boat ahead on her tack she is closing on (`overtakeFlag`, #531: the
    /// distance horizon, "≥ 7.5 L"). Placeholder.
    static let overtakeRangeLengths = 7.5
    /// Hull lengths of her own travel within which closing on a boat ahead flags it (`overtakeFlag`, #531: "within ~6
    /// lengths of her own travel, whatever the closing speed"). Placeholder.
    static let overtakeTravelLengths = 6.0
    /// Hull lengths abeam of a boat ahead her lane passes it at (#531: "a lane two lengths to windward or to leeward").
    static let laneLengths = 2.0
    /// Seconds her speed margin must get her past a boat ahead in for her lane to be to windward (#531: "when her speed
    /// margin gets her through before the shadow is hers"); slower, she passes to leeward. Placeholder.
    static let windwardPassSeconds = 15.0
    /// A pass under way, worth this much header to her tactics on a beat (`upwindTack`, #531 Q4): a tack to clear air
    /// is at least considered, at every tier. Placeholder: `dirtyAirWeight`'s.
    static let overtakeWeight = deg2rad(2)

    /// The seconds she weighs `other` over (until they are closest, at most `scorerHorizon`), a boat ahead of her on her
    /// tack, she sailing `desired` while it sails on, when the closing brings her inside `keepClearDistance` hull
    /// lengths of it within `overtakeTravelLengths` of her own travel, whatever the closing speed (#531: the distance
    /// horizon); else nil. Out to
    /// `overtakeRangeLengths`; the 4.5 s test (`isAboutToHit`) stays for crossings.
    func overtakeFlag(_ other: SeatView.OtherBoat, _ b: SeatView.OwnBoat, _ view: SeatView, desired: Double) -> Double? {
        let length = view.boatClass.hull.length
        let offset = other.position - b.position
        let forward = Vec2.heading(desired)
        // Clear ahead of her (a hull length and more up her course, centre to centre): an overlapped boat is a lane's
        // business once she holds one (`isPassing`), and rules 11 and 17's otherwise, not an overtake's.
        // A boat she is clear astern of (rule 12), so never one tacking or gybing (rule 13), whose tack has flipped
        // mid-turn: she is turning, not a slower boat ahead.
        guard !other.isGhost, other.tack == b.tack,
              other.rightOfWay == RightOfWay(keepClear: view.seat, rule: .clearAstern),
              offset.length < length * Self.overtakeRangeLengths, offset.dot(forward) > length else { return nil }
        // The moment she comes inside `keepClearDistance` of it, both sailing on: |offset + relative·t| = that distance.
        let relative = other.velocity - forward * b.speed
        let vv = relative.lengthSquared
        let inside = length * Self.keepClearDistance
        guard vv > 1e-6 else { return nil }
        let od = offset.dot(relative)
        let excess = offset.lengthSquared - inside * inside
        let discriminant = od * od - vv * excess
        guard discriminant >= 0 else { return nil }
        let t = excess <= 0 ? 0 : (-od - discriminant.squareRoot()) / vv
        guard t >= 0, b.speed * t <= length * Self.overtakeTravelLengths else { return nil }
        // Her horizon runs on to where they would be closest, at most `scorerHorizon`.
        return max(t, min(-od / vv, Self.scorerHorizon))
    }

    /// Whether she is still passing `other`, the boat of her lane (`KeepClearLatch.lane`): on her tack, near, and not
    /// yet clear ahead of it (her stern ahead of its bow).
    func isPassing(_ other: SeatView.OtherBoat, _ b: SeatView.OwnBoat, _ view: SeatView) -> Bool {
        let length = view.boatClass.hull.length
        let offset = other.position - b.position
        return !other.isGhost && other.tack == b.tack && offset.length < length * Self.overtakeRangeLengths
            && offset.dot(b.forward) > -length
    }

    /// Her lane past `other` (#531): the side, +1 to leeward (bearing away), −1 to windward, and the heading that puts
    /// her `laneLengths` abeam of it by the time she is alongside. To windward when her speed margin passes it within
    /// `windwardPassSeconds`, else to leeward with the bear-away's speed. `side` given, that side's heading.
    func lane(past other: SeatView.OtherBoat, _ b: SeatView.OwnBoat, _ view: SeatView, desired: Double,
              side: Double? = nil) -> (side: Double, heading: Double) {
        let length = view.boatClass.hull.length
        let tackSide: Double = b.tack == .port ? 1 : -1
        let offset = other.position - b.position
        let forward = Vec2.heading(desired)
        let along = max(offset.dot(forward), 0)
        let margin = b.speed - other.speed
        let side = side ?? (margin > 0.05 && (along + length * Self.laneLengths) / margin <= Self.windwardPassSeconds
            ? -1 : 1)
        // Her lateral way on that side: bearing away on port turns her to starboard.
        let lateral = forward.rightPerp * (side * tackSide)
        let apart = -offset.dot(lateral)
        let needed = max(length * Self.laneLengths - apart, 0)
        let angle = Vec2(needed, max(along, length)).bearing
        return (side, b.windDirection + tackSide * (wrapAngle(desired - b.windDirection) * tackSide + side * angle))
    }


    /// A tack the scorer chose (#531): committed until it is over, abandoned only for a boat it would hit on the new
    /// tack, never for `escaping`, the boat it was chosen to escape (owner, 2026-10-16).
    struct KeepClearTack: Equatable, Sendable {
        var escaping: Int
        var toTack: Tack
        var since: Double
    }

    /// What the racing scorer decided (`scoreRacingKeepClear`).
    struct RacingKeepClear: Equatable, Sendable {
        /// The heading she steers for, or nil to sail her plan (`desired` won, or a committed tack is under way).
        var heading: Double?
        /// The tack won: she tacks now (`sail`).
        var tacks = false
        /// The side she is committed to (`KeepClearLatch`), if any.
        var latch: KeepClearLatch?
        /// The boat that tripped the trigger first, in seat order.
        var threat: Int?
    }

    /// Whether `seat` is a person's boat (`humanSeats`, set by `SeatControllers.drive`): a player could tell.
    func isHuman(_ seat: Int) -> Bool { seat < humanSeats.count && humanSeats[seat] }

    /// Whether `other` is going under `stoppedShare` of the polar speed at her wind angle (#537's "can't" test).
    func isStopped(_ other: SeatView.OtherBoat, _ b: SeatView.OwnBoat, _ view: SeatView) -> Bool {
        let polar = view.boatClass.polar
        let twa = abs(wrapAngle(b.windDirection - other.heading))
        let reference = polar.speed(twa: max(twa, BoatDynamics.noGoAngle(polar) + deg2rad(5)), tws: b.polarWindSpeed)
        return other.speed < Self.stoppedShare * reference
    }

    /// How the scorer rolls `other` forward (`Reaction`, #531 Q3): her circle if she is taking a penalty; can't when she
    /// clearly isn't keeping clear (`notKeepingClear`), or is a person's boat stopped; a person's boat otherwise on her
    /// measured motion only; giving way when she owes her under rules 10–12 (10 bears away, 11 luffs, 12 turns from her
    /// side) by the least turn, in `clearingStep`s, that passes her straight course `keepClearDistance` off; else on
    /// her measured motion.
    func reaction(of other: SeatView.OtherBoat, _ b: SeatView.OwnBoat, _ view: SeatView) -> Reaction {
        if let radius = penaltyCircleRadius(of: other, b, view) { return .circle(radius: radius) }
        guard let right = other.rightOfWay, right.keepClear == other.seat else { return .measured }
        if let not = notKeepingClear(other, b, view) { return .cannot(stopped: not == .cannot) }
        if isHuman(other.seat) { return isStopped(other, b, view) ? .cannot(stopped: true) : .measured }
        let side: Double = other.tack == .port ? 1 : -1
        let turn: Double
        switch right.rule {
        case .portStarboard: turn = side
        case .windwardLeeward: turn = -side
        case .clearAstern:
            turn = (b.position - other.position).dot(other.forward.rightPerp) > 0 ? -1 : 1
        default:
            return .measured
        }
        let clear = view.boatClass.hull.length * Self.keepClearDistance
        let offset = b.position - other.position
        var limit = Self.giveWayMaxTurn
        var angle = Self.clearingStep
        while angle < Self.giveWayMaxTurn {
            let velocity = Vec2.heading(other.heading + turn * angle) * other.speed
            if Self.closestApproach(offset: offset, relativeVelocity: b.velocity - velocity,
                                    lookahead: keepClearLookahead) >= clear {
                limit = angle
                break
            }
            angle += Self.clearingStep
        }
        return .givesWay(turn: turn, limit: limit)
    }

    /// How the scorer rolls `other` forward against her tack (`reaction`): tacking she keeps clear of every boat (rule
    /// 13), so no boat gives way to her; a boat that owes her now is sailed on as she has been.
    func tackReaction(of other: SeatView.OtherBoat, _ b: SeatView.OwnBoat, _ view: SeatView) -> Reaction {
        let reaction = reaction(of: other, b, view)
        if case .givesWay = reaction { return .measured }
        return reaction
    }

    /// Where `other` is every `keepClearPredictionStep` for `steps` steps, the first a step from now, rolled on
    /// `reaction`.
    func predictedTrack(of other: SeatView.OtherBoat, _ reaction: Reaction, _ view: SeatView, steps: Int) -> [Vec2] {
        let dt = Self.keepClearPredictionStep
        if case .circle = reaction { return Array(repeating: other.position, count: steps) }
        let motion = measuredMotion(of: other, view)
        var position = other.position, heading = other.heading, speed = other.speed
        var turned = 0.0
        var track: [Vec2] = []
        track.reserveCapacity(steps)
        // Her measured turn, rolled on for `measuredTurnSeconds` at most: a turn seen is one she is finishing, not a
        // circle she sails on (a boat whose autohelm follows a shift turns for a second or two).
        func yaw(_ t: Double) -> Double { t < Self.measuredTurnSeconds ? motion.turnRate * dt : 0 }
        // Her measured acceleration over the whole horizon, never below rest and never speeding past the polar's speed
        // at her heading (or her own, already faster). Not cut off after `measuredTurnSeconds` like the yaw: her speed
        // held from there (fix round 2) cost National seeds 5-8 1226 -> 1201 finishers, the loss in 16-boat fleets'
        // last-leg DNFs, irons and mark contacts (#531 fix round 3).
        let polar = view.boatClass.polar
        let floor = BoatDynamics.noGoAngle(polar) + deg2rad(5)
        let tws = view.own.polarWindSpeed, wind = view.own.windDirection
        func accelerated(_ t: Double, _ acceleration: Double) -> Double {
            let next = max(0, speed + acceleration * dt)
            guard acceleration > 0 else { return next }
            let ceiling = polar.speed(twa: max(abs(wrapAngle(wind - heading)), floor), tws: tws)
            return min(next, max(speed, ceiling))
        }
        for step in 0..<steps {
            let t = Double(step) * dt
            switch reaction {
            case .measured, .cannot(stopped: false):
                heading += yaw(t)
                speed = accelerated(t, motion.acceleration)
            case .cannot(stopped: true):
                heading += yaw(t)
                // Slowing to rest whatever she was seen doing, at her measured loss if faster.
                speed = max(0, speed + min(motion.acceleration, -Self.stoppedDeceleration) * dt)
            case let .givesWay(turn, limit):
                if t < Self.giveWayDelay {
                    heading += yaw(t)
                    speed = accelerated(t, motion.acceleration)
                } else if turned < limit {
                    let d = min(Self.keepClearTurnRate * dt, limit - turned)
                    heading += turn * d
                    turned += d
                    speed *= 1 - Self.keepClearTurnSpeedLoss * dt
                }
            case .circle:
                break
            }
            position = position + Vec2.heading(heading) * (speed * dt)
            track.append(position)
        }
        return track
    }

    /// Her own track steering for `heading` (#529's `reachable`): turning to it at `keepClearTurnRate`, losing
    /// `keepClearTurnSpeedLoss` of her speed each second she turns, and settling to the polar's speed for the new
    /// heading over `keepClearSpeedSettle`; and the progress it makes along `axis`, metres. Her polar speeds are read
    /// no closer to the wind than `closest` (racing's 5° outside the no-go zone unless given: before the gun
    /// `startLuffFloor`, #542 Q8's `committedAvoidance`). With `ease` (#542 PR 2, the penalty way out's ease, dodge
    /// only) she settles to the ease's fraction of that speed (`SeatView.easeSpeedFraction`: the class's, or before the gun
    /// the opening's trim, #477) over its `ease.timeConstant`.
    func herTrack(_ b: SeatView.OwnBoat, _ view: SeatView, heading target: Double, steps: Int,
                  axis: Vec2, closest: Double? = nil, ease: Bool = false) -> (track: [Vec2], progress: Double) {
        let dt = Self.keepClearPredictionStep
        let polar = view.boatClass.polar
        let floor = closest ?? BoatDynamics.noGoAngle(polar) + deg2rad(5)
        let now = polar.speed(twa: max(b.twa, floor), tws: b.polarWindSpeed)
        let then = polar.speed(twa: max(abs(wrapAngle(target - b.windDirection)), floor), tws: b.polarWindSpeed)
        var settled = b.speed * (now > 1e-6 ? (then / now).clamped(to: 0.5...1.5) : 1)
        var settle = Self.keepClearSpeedSettle
        if ease {
            settled *= view.easeSpeedFraction
            settle = view.boatClass.ease.timeConstant
        }
        var position = b.position, heading = b.heading, speed = b.speed
        var track: [Vec2] = []
        track.reserveCapacity(steps)
        for _ in 0..<steps {
            let remaining = wrapAngle(target - heading)
            let turn = min(abs(remaining), Self.keepClearTurnRate * dt)
            if turn > 1e-9 {
                heading += remaining > 0 ? turn : -turn
                speed *= 1 - Self.keepClearTurnSpeedLoss * dt
            } else {
                speed += (settled - speed) * min(dt / settle, 1)
            }
            position = position + Vec2.heading(heading) * (speed * dt)
            track.append(position)
        }
        return (track, (position - b.position).dot(axis))
    }

    /// The headings on her own tack she weighs keeping clear (#529's reachable headings): `desired`, her heading held,
    /// and where she can be pointing in `keepClearReachSeconds` either way at `keepClearTurnRate`, each kept to her
    /// tack's sailable angles (out of the no-go zone, never by the lee) and none within a degree of another. A turn
    /// bearing her away past dead downwind stops there (#455): wrapped round the wind, it read as a luff to close-hauled,
    /// and running fast down on a slow boat clear ahead she swung from bearing away to luffing and back every second,
    /// keeping clear of neither side (`scriptedEncountersZeroFoulsAtSkill1`, clear astern running, seed 17).
    func keepClearHeadings(_ b: SeatView.OwnBoat, _ view: SeatView, desired: Double, extra: [Double] = []) -> [Double] {
        let side: Double = b.tack == .port ? 1 : -1
        let closest = BoatDynamics.noGoAngle(view.boatClass.polar) + deg2rad(5)
        func onHerTack(_ heading: Double) -> Double {
            // Her sailing angle on her tack: by the lee is past π, not round the wind on the other side.
            var angle = wrapAngle(heading - b.windDirection) * side
            if angle < -.pi / 2 { angle += 2 * .pi }
            return b.windDirection + side * angle.clamped(to: closest...Double.pi)
        }
        var headings: [Double] = []
        func add(_ heading: Double) {
            let heading = onHerTack(heading)
            if !headings.contains(where: { abs(wrapAngle($0 - heading)) < deg2rad(1) }) { headings.append(heading) }
        }
        add(desired)
        add(b.heading)
        for seconds in Self.keepClearReachSeconds {
            for turn in [-1.0, 1.0] { add(b.heading + turn * Self.keepClearTurnRate * seconds) }
        }
        extra.forEach(add)
        return headings
    }

    /// Her sailing angle on her tack off `desired` steering `heading`: positive bearing away.
    func offDesired(_ b: SeatView.OwnBoat, heading: Double, desired: Double) -> Double {
        let side: Double = b.tack == .port ? 1 : -1
        return wrapAngle(heading - desired) * side
    }

    /// The racing keep-clear scorer (#531), or nil when no collision she must keep clear of is coming: the trigger is
    /// today's (`isAboutToHit` on `desired` over `lookahead`, a boat she must keep clear of or owes mark-room, not
    /// misjudged). Rule 13 as before: tacking, she finishes her tack (`finishingTack`). A committed tack under way
    /// (`keepClearTack`) is left alone unless it would hit a boat other than the one it escapes on the new tack.
    /// Otherwise every candidate (`keepClearHeadings`, and the tack when `tackable`) is sailed in her mind against
    /// every non-ghost boat within `keepClearRange` (`predictedTrack` on its `reaction`) for the trigger's horizon;
    /// a candidate is out inside a boat's out distance (`keepClearDistance` × `keepClearMargin` hull lengths of one
    /// she must keep clear of, every boat for the tack under rule 13; `collisionLengths` of any other; a circle's
    /// radius more), and the one left that loses her least progress, a thin margin costed `thinMarginCost`, wins; none
    /// left, the one passing furthest off for its distances. Committed to a side (`keepClearLatch`), she weighs only
    /// that side while any heading there clears.
    /// The overtake (`overtakeFlag`, the lane) only while `overtakes`: her plan sails her tack (`sail`), no turn by hand
    /// is under way, and she isn't near her mark: a lane is never held against her plan's tack, through a tack or into
    /// a mark.
    func scoreRacingKeepClear(_ b: SeatView.OwnBoat, _ view: SeatView, desired: Double, lookahead: Double,
                              tackable: Bool = false, overtakes: Bool = true) -> RacingKeepClear? {
        scoredRacingKeepClear(b, view, desired: desired, lookahead: lookahead, tackable: tackable,
                              overtakes: overtakes).decision
    }

    /// A candidate's score (`scoredRacingKeepClear`): the heading, nil for the tack; the progress it loses her in hull
    /// lengths, a thin margin costed; and the least of its clearances over the out distances (1 or more clears).
    struct KeepClearScore: Equatable, Sendable {
        var heading: Double?
        var cost: Double
        var margin: Double
    }

    /// `scoreRacingKeepClear`, with every candidate's score (for tests).
    func scoredRacingKeepClear(_ b: SeatView.OwnBoat, _ view: SeatView, desired: Double, lookahead: Double,
                               tackable: Bool = false,
                               overtakes: Bool = true) -> (decision: RacingKeepClear?, scores: [KeepClearScore]) {
        let overtakes = overtakes && handTurn == nil && !isNearHerMark
        let hull = view.boatClass.hull
        var threat: SeatView.OtherBoat?
        var horizon = lookahead
        // The boat of a lane she holds, until clear ahead of it; else the first boat ahead she is closing on.
        var passing = !overtakes ? nil : keepClearLatch?.lane.flatMap { seat in view.others.first { $0.seat == seat } }
            .flatMap { isPassing($0, b, view) ? $0 : nil }
        // The boats ahead she is closing on, in seat order: rolled out with the rest though beyond `keepClearRange`,
        // the flag's own range (`overtakeRangeLengths`) reaching further (a stopped boat at ~7.3 L).
        var flagged: [Int] = passing.map { [$0.seat] } ?? []
        for other in view.others where !other.isGhost {
            if passing?.seat == other.seat {
                horizon = max(horizon, overtakeFlag(other, b, view, desired: desired) ?? 0)
                if threat == nil { threat = other }
                continue
            }
            if let rule = keepClearRule(b, view, other), !misjudges(other, rule),
               isAboutToHit(other, b, view, desired: desired, lookahead: lookahead) {
                if rule == .whileTacking, keepClearTack == nil {
                    return (RacingKeepClear(heading: finishingTack(b, view)), [])
                }
                if threat == nil { threat = other }
            } else if overtakes, let t = overtakeFlag(other, b, view, desired: desired) {
                horizon = max(horizon, t)
                flagged.append(other.seat)
                if threat == nil { threat = other }
                if passing == nil { passing = other }
            }
        }
        // A committed tack under way: only a boat it would hit on the new tack ends it.
        if let committed = keepClearTack, handTurn != nil || senses.tacking {
            // Close-hauled on the new tack: where the turn takes her.
            let side: Double = committed.toTack == .port ? 1 : -1
            let heading = b.windDirection + side * Self.closeHauled(b.polarWindSpeed, view)
            let collision = hull.length * Self.collisionLengths
            let hits = view.others.first { other in
                !other.isGhost && other.seat != committed.escaping
                    && (other.position - b.position).length < Self.keepClearRange
                    && approach(of: other, to: b, heading: heading, speed: b.speed * Self.tapSpeedShare,
                                lookahead: lookahead, view) < collision
            }
            guard hits != nil else { return (RacingKeepClear(heading: nil, threat: committed.escaping), []) }
        }
        guard let threat else { return (nil, []) }
        let length = hull.length
        let dt = Self.keepClearPredictionStep
        horizon = min(max(horizon, dt), Self.scorerHorizon)
        let steps = Int((horizon / dt).rounded(.up))
        let upwind = abs(sailingAngle(b)) < .pi / 2
        let axis = upwind ? Vec2.heading(b.windDirection) : Vec2.heading(desired)
        // Every boat near her, rolled on what it is doing and what it owes her, and how far off a course must pass it.
        let boats: [(track: [Vec2], tackTrack: [Vec2], out: Double, owed: Bool)] = view.others.compactMap { other in
            guard !other.isGhost,
                  (other.position - b.position).length < Self.keepClearRange || flagged.contains(other.seat)
            else { return nil }
            let rule = keepClearRule(b, view, other)
            // A misjudged encounter leaves her give-way out (`judgeEncounters`), but never the boat ahead she is passing:
            // noticing a slower boat ahead is avoidance, whatever her skill (owner, #531 Q4: "never whether she looks").
            let isPassed = other.seat == passing?.seat
            if let rule, misjudges(other, rule), !isPassed { return nil }
            let reaction = reaction(of: other, b, view)
            // The boat she is passing, she passes as she must keep clear of it, whatever their overlap gives her.
            let owed = rule != nil || isPassed
            let out: Double
            if case let .circle(radius) = reaction {
                out = radius + length * Self.collisionLengths
            } else {
                out = length * (owed ? keepClearLengths * Self.keepClearMargin : Self.collisionLengths)
            }
            let track = predictedTrack(of: other, reaction, view, steps: steps)
            // Against her tack no boat gives way to her (rule 13, `tackReaction`).
            var tackTrack = track
            if tackable, case .givesWay = reaction { tackTrack = predictedTrack(of: other, .measured, view, steps: steps) }
            return (track, tackTrack, out, owed)
        }
        // Rule 13 on the tack: she keeps clear of every boat.
        let tackOut = length * keepClearLengths * Self.keepClearMargin
        typealias Scored = KeepClearScore
        func score(_ track: [Vec2], progress: Double, tack: Bool) -> Scored {
            var margin = Double.infinity
            for boat in boats {
                let out = tack ? max(boat.out, tackOut) : boat.out
                let theirs = tack ? boat.tackTrack : boat.track
                var closest = Double.infinity
                for i in 0..<min(track.count, theirs.count) {
                    closest = min(closest, (theirs[i] - track[i]).length)
                }
                margin = min(margin, closest / out)
            }
            let thin = margin >= 1 && margin < Self.thinMargin ? Self.thinMarginCost : 0
            return Scored(heading: nil, cost: -progress / length + thin, margin: margin)
        }
        // Her lane past the boat ahead: the side latched at the first flag, the heading re-picked each decision.
        var laneSide: Double?
        if let passing, let latch = keepClearLatch, latch.lane == passing.seat { laneSide = latch.side }
        var lane: (side: Double, heading: Double)?
        if let passing { lane = self.lane(past: passing, b, view, desired: desired, side: laneSide) }
        let extra: [Double] = lane.map { [$0.heading] } ?? []
        // Right of way unchanged (#101, #228): she gives way here, and a turn towards a boat that must keep clear of her
        // is left to `holdingCourse` as before, never a filter on her candidates: cutting a side whenever such a boat was
        // near took her escape from the boat she owes (racing fouls 312 → 466 per 8 seeds, live National).
        let headings = keepClearHeadings(b, view, desired: desired, extra: extra)
        var scored: [Scored] = headings.map { (heading: Double) -> Scored in
            let sailed = herTrack(b, view, heading: heading, steps: steps, axis: axis)
            var s = score(sailed.track, progress: sailed.progress, tack: false)
            s.heading = heading
            return s
        }
        if tackable, upwind {
            let track = tapTrack(b, view, seconds: horizon)
            let progress = ((track.last ?? b.position) - b.position).dot(axis)
            scored.append(score(Array(track.prefix(steps)), progress: progress, tack: true))
        }
        func pick(_ list: [Scored]) -> Scored? {
            list.filter { $0.margin >= 1 }.min { $0.cost < $1.cost }
        }
        // Committed to a side, she looks that way (and on her plan's heading) while a heading there clears.
        let committed = lane.map { KeepClearLatch(side: $0.side, lane: passing?.seat) } ?? keepClearLatch
        let latched = committed.flatMap { latch in
            pick(scored.filter { s in
                guard let heading = s.heading else { return false }
                let off = offDesired(b, heading: heading, desired: desired)
                return abs(off) <= Self.clearingStep || off * latch.side > 0
            })
        }
        guard let best = latched ?? pick(scored) ?? scored.max(by: { $0.margin < $1.margin }) else { return (nil, scored) }
        guard let heading = best.heading else {
            return (RacingKeepClear(heading: nil, tacks: true, threat: threat.seat), scored)
        }
        let off = offDesired(b, heading: heading, desired: desired)
        let latch = lane.map { KeepClearLatch(side: $0.side, lane: passing?.seat) }
            ?? (abs(off) > Self.clearingStep ? KeepClearLatch(side: off > 0 ? 1 : -1) : keepClearLatch)
        let steered = abs(wrapAngle(heading - desired)) < deg2rad(1) ? nil : heading
        return (RacingKeepClear(heading: steered, latch: latch, threat: threat.seat), scored)
    }

    /// Whether the racing scorer (#531) keeps her clear: racing, a live bot that isn't the cautious one (#531 Q5) nor
    /// the suite's hunter (whose racing conduct is #355's), with the test seam `scoresKeepClear` on.
    func usesKeepClearScorer(_ b: SeatView.OwnBoat) -> Bool {
        scoresKeepClear && b.status == .racing && caution == nil && !tactics.hunts
    }
}
