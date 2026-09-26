import RegattaCore

/// A bot's hidden, seeded style (#19): where it starts, how early it risks being, how it serves
/// penalties, and a skill value. Drawn from the bot's own seed (`BotDriver.seed`), never from the
/// race's streams, so changing a style never moves placement or wind. Tuning it needs no simulation
/// version bump: the race log holds the inputs a bot applied, and replays never run brains (ADR 0002).
public struct BotStyle: Hashable, Sendable {
    /// 0…1. Today it gates shift-playing and sets the keep-clear look-ahead; #102 grows it into the tiers.
    public var skill: Double
    /// Where on the line to start, 0 = pin, 1 = committee boat.
    public var startSpot: Double
    /// Where on the line to finish, 0 = pin, 1 = committee boat.
    public var finishSpot: Double
    /// Metres below the start spot to hold before the approach.
    public var holdDepth: Double
    /// Seconds added to the approach; negative values make the bot early (and risk OCS).
    public var timingSlack: Double
    /// Hard over to this side (−1 port, 1 starboard) for penalty turns.
    public var penaltyDirection: Double

    public init(skill: Double, startSpot: Double, finishSpot: Double, holdDepth: Double,
                timingSlack: Double, penaltyDirection: Double) {
        self.skill = skill
        self.startSpot = startSpot
        self.finishSpot = finishSpot
        self.holdDepth = holdDepth
        self.timingSlack = timingSlack
        self.penaltyDirection = penaltyDirection
    }

    /// The prototype brain's draws, in its order.
    public init(rng: inout SplitMix64) {
        skill = rng.range(0.35, 1)
        startSpot = rng.range(0.1, 0.9)
        finishSpot = rng.range(0.6, 0.85)
        holdDepth = rng.range(18, 35)
        timingSlack = rng.range(-2.5, 5) * (1.3 - skill)
        penaltyDirection = rng.bool() ? 1 : -1
    }
}

/// One bot decision: exactly what a human could send (#19), a held input and at most one tap.
public struct BotDecision: Hashable, Sendable {
    public var input: BoatInput
    public var tap: BoatTap?

    public init(input: BoatInput, tap: BoatTap? = nil) {
        self.input = input
        self.tap = tap
    }
}

/// Helms a computer-controlled boat: pre-start timing, beating and running between
/// laylines, playing shifts, mark roundings, penalty turns, and keeping clear when
/// it is the give-way boat.
///
/// The prototype brain behind a temporary adapter (#60): it reads only the public race, as a
/// player's device could, and answers with a `BotDecision`, an int8 rudder plus the tack/gybe tap.
/// The bot phase (#98–#104) rebuilds it: ease, tiers, player-visible information only.
struct BotBrain: Sendable {
    let style: BotStyle
    var plannedTack: Tack = .starboard
    var lastTackTime = -1_000.0
    /// Hard over on penalty turns until none are owed (see `decide`).
    var servingPenalty = false

    init(style: BotStyle) {
        self.style = style
    }

    private var skill: Double { style.skill }
    private var startSpot: Double { style.startSpot }
    private var finishSpot: Double { style.finishSpot }
    private var holdDepth: Double { style.holdDepth }
    private var timingSlack: Double { style.timingSlack }

    mutating func decide(for i: Int, in race: Race) -> BotDecision {
        let boat = race.boats[i]
        guard boat.isOnCourse else { return BotDecision(input: .neutral) }
        // Penalty turns start only clear of boats and of marks by three lengths, then go on whoever comes
        // near, unless they carry her within a length of a mark: she sails on and starts again clear. The
        // sim counts every turn since the boat came to owe one, a rounding included, so going by
        // `isTakingPenalty` spun a boat that had just touched a mark hard over against it, touching it
        // again (and owing another turn) on every turn.
        servingPenalty = servingPenalty && boat.penaltyTurnsOwed > 0 && isClearOfMarks(boat, race, lengths: 1)
        if boat.penaltyTurnsOwed > 0 && (servingPenalty || (isClearOfTraffic(boat, race) && isClearOfMarks(boat, race, lengths: 3))) {
            servingPenalty = true
            return BotDecision(input: BoatInput(rudder: style.penaltyDirection))
        }
        let desired = desiredHeading(boat, race)
        var heading = keepClear(boat, race, desired: desired)
        let keepingClear = heading != desired
        heading = avoidMarks(boat, race, desired: heading)

        // The tap's autopilot is tacking or gybing the boat: hands off, since any rudder cancels it,
        // unless the boat has to keep clear of someone.
        if boat.autopilot != nil && !keepingClear { return BotDecision(input: .neutral) }
        if !keepingClear && wantsTackOrGybe(boat, to: heading, race) {
            return BotDecision(input: .neutral, tap: .tackGybe)
        }
        return BotDecision(input: BoatInput(rudder: (wrapAngle(heading - boat.heading) / deg2rad(20)).clamped(to: -1...1)))
    }

    /// Whether `heading` is the mirror of a close-hauled or running course on the other tack, which
    /// the tack/gybe tap sails to as a player's would.
    private func wantsTackOrGybe(_ b: Boat, to heading: Double, _ race: Race) -> Bool {
        let target = wrapAngle(b.windDirection - heading)
        guard BoomSide.leeward(ofRelativeWind: target) != b.boomSide, abs(wrapAngle(heading - b.heading)) > deg2rad(50) else { return false }
        let polar = race.boatClass.polar
        let upwind = polar.bestUpwind(tws: b.windSpeed).twa + deg2rad(15)
        let downwind = polar.bestDownwind(tws: b.windSpeed).twa - deg2rad(15)
        return (b.twa < upwind && abs(target) < upwind) || (b.twa > downwind && abs(target) > downwind)
    }

    private mutating func desiredHeading(_ b: Boat, _ race: Race) -> Double {
        let c = race.course
        switch b.status {
        case .prestart where race.time < 0:
            return prestartHeading(b, race)
        case .prestart:
            return lateStartHeading(b, race)
        case .ocs:
            return navigate(b, to: startPoint(c) - c.upwind * 15, race)
        case .racing:
            return navigate(b, to: waypoint(b, c), race)
        case .finished, .dsq, .dnf:
            return b.heading
        }
    }

    /// After the gun, not yet started. A boat starts only by crossing the line itself from the
    /// pre-start side, so one on the course side (she went past an end of the line) sails back below
    /// it as an OCS boat does, and one below it but beyond an end first sails in behind the line;
    /// otherwise she would loiter past the line, or keep hitting the end mark, and never start.
    private mutating func lateStartHeading(_ b: Boat, _ race: Race) -> Double {
        let c = race.course
        let line = c.startLine
        if line.side(b.position) > 0 { return navigate(b, to: startPoint(c) - c.upwind * 15, race) }
        let along = (b.position - line.pin.position).dot((line.committee.position - line.pin.position).normalized)
        let clearOfEnds = race.boatClass.hull.length
        if along < clearOfEnds || along > line.length - clearOfEnds {
            return navigate(b, to: startPoint(c) - c.upwind * 5, race)
        }
        return navigate(b, to: startPoint(c) + c.upwind * 20, race)
    }

    private func startPoint(_ c: CourseLayout) -> Vec2 {
        let line = c.startLine
        return line.pin.position + (line.committee.position - line.pin.position) * startSpot
    }

    private mutating func prestartHeading(_ b: Boat, _ race: Race) -> Double {
        let c = race.course
        let spot = startPoint(c)
        let timeLeft = -race.time
        let distance = (spot - b.position).length
        let beatSpeed = race.boatClass.polar.bestUpwind(tws: b.windSpeed).speed
        let timeNeeded = distance / max(beatSpeed, 0.5) * 1.25 + 5 + timingSlack

        if timeLeft > timeNeeded + 4 {
            let hold = spot - c.upwind * holdDepth
            if (hold - b.position).length > 12 { return navigate(b, to: hold, race) }
            return b.windDirection - deg2rad(28) // luff and wait
        }
        // Too close to the line with time to kill: reach away along it rather than
        // luffing, because a luffing boat still coasts several lengths.
        let depth = -c.startLine.side(b.position)
        if depth < b.speed * 4 + 3 && depth / max(b.speed, 1) < timeLeft - 2 {
            return b.windDirection - deg2rad(110)
        }
        let eta = distance / max(b.speed, 1)
        if eta < timeLeft - 3 { return b.windDirection - deg2rad(28) }
        return navigate(b, to: spot - c.upwind * 2, race)
    }

    /// The point to sail at for the current leg: round each mark to port, approaching it along the
    /// course (upwind to W, across from W to O); through the gate, then round the nearer of its marks.
    private func waypoint(_ b: Boat, _ c: CourseLayout) -> Vec2 {
        let leg = c.legs[b.legIndex]
        switch leg {
        case .round(let index):
            switch c.elements[index] {
            case .mark(let mark, _):
                let m = mark.position
                let approach = index == CourseLayout.windwardIndex
                    ? c.upwind : (m - c.elements[CourseLayout.windwardIndex].marks[0].position).normalized
                let side = approach.rightPerp
                if b.roundingStage == 0 {
                    return detour(from: b.position, to: m + side * 6 + approach * 4, around: m,
                                  via: m + side * 7 - approach * 7)
                }
                return m + approach * 9 - side * 10
            case .gate(let left, let right):
                let centre = c.targetPosition(for: leg)
                if b.roundingStage == 0 { return centre - c.upwind * 6 }
                let near = (left.position - b.position).length <= (right.position - b.position).length ? left : right
                return near.position - c.upwind * 9 + (near.position - centre).normalized * 10
            }
        case .finish:
            let line = c.finishLine
            return line.pin.position + (line.committee.position - line.pin.position) * finishSpot - c.upwind * 12
        }
    }

    /// `waypoint`, unless the straight line to it runs over `mark` — then `via` first.
    private func detour(from p: Vec2, to waypoint: Vec2, around mark: Vec2, via: Vec2) -> Vec2 {
        let closest = Collision.closestPoint(on: Segment(p, waypoint), to: mark)
        return (closest - mark).length < 4 ? via : waypoint
    }

    private mutating func navigate(_ b: Boat, to target: Vec2, _ race: Race) -> Double {
        let toTarget = target - b.position
        let distance = toTarget.length
        let bearing = toTarget.bearing
        let w = b.windDirection
        let offWind = abs(wrapAngle(bearing - w))
        let up = race.boatClass.polar.bestUpwind(tws: b.windSpeed).twa
        let down = race.boatClass.polar.bestDownwind(tws: b.windSpeed).twa
        let lateral = (b.position - target).dot(Vec2.heading(w).rightPerp)
        let corridor = max(20, distance * 0.35)

        if offWind < up + deg2rad(2) {
            var tack = plannedTack
            if lateral < -corridor {
                tack = .port
            } else if lateral > corridor {
                tack = .starboard
            } else if race.time - lastTackTime > 15 && skill > 0.5 {
                // Tack on headers.
                let shift = wrapAngle(w - race.course.axis)
                if tack == .starboard && shift < -deg2rad(4) { tack = .port }
                if tack == .port && shift > deg2rad(4) { tack = .starboard }
            }
            setTack(tack, race)
            return tack == .starboard ? w - up : w + up
        }

        if offWind > down - deg2rad(2) {
            var gybe = plannedTack
            if lateral < -corridor { gybe = .port } else if lateral > corridor { gybe = .starboard }
            setTack(gybe, race)
            return gybe == .starboard ? w - down : w + down
        }

        plannedTack = b.tack
        return bearing
    }

    private mutating func setTack(_ tack: Tack, _ race: Race) {
        guard tack != plannedTack else { return }
        plannedTack = tack
        lastTackTime = race.time
    }

    /// Alters course if a collision is coming and this boat is the one that must keep clear.
    private func keepClear(_ b: Boat, _ race: Race, desired: Double) -> Double {
        let lookahead = 2.5 + 2 * skill
        let myVelocity = Vec2.heading(desired) * b.speed
        for other in race.boats where other.id != b.id && !other.isGhost {
            let offset = other.position - b.position
            guard offset.length < 30 else { continue }
            let relativeVelocity = other.velocity - myVelocity
            let vv = relativeVelocity.lengthSquared
            let t = vv > 1e-6 ? (-offset.dot(relativeVelocity) / vv).clamped(to: 0...lookahead) : 0
            guard (offset + relativeVelocity * t).length < race.boatClass.hull.length * 1.3 else { continue }

            guard let right = race.rightOfWay(b.id, other.id), right.keepClear == b.id else { continue }

            // Headings are set relative to the wind so evasive action never parks the boat in irons.
            let side: Double = b.tack == .port ? 1 : -1
            switch right.rule {
            case .portStarboard:
                return b.windDirection + side * deg2rad(85) // duck
            case .windwardLeeward, .whileTacking:
                return b.windDirection + side * deg2rad(38) // luff
            default:
                let otherIsToStarboard = offset.dot(b.forward.rightPerp) > 0
                return sailable(b.heading + (otherIsToStarboard ? -1 : 1) * deg2rad(35), wind: b.windDirection)
            }
        }
        return desired
    }

    /// Bears away from any mark the boat is about to sail into.
    private func avoidMarks(_ b: Boat, _ race: Race, desired: Double) -> Double {
        let ahead = Vec2.heading(desired)
        for obstacle in race.course.obstacles {
            let offset = obstacle.position - b.position
            guard offset.length < 20 else { continue }
            let along = offset.dot(ahead)
            guard along > 0, along < max(b.speed, 1) * 3 + 3 else { continue }
            guard abs(offset.cross(ahead)) < obstacle.radius + race.boatClass.hull.beam + 1 else { continue }
            let markIsToStarboard = offset.dot(ahead.rightPerp) > 0
            return sailable(desired + (markIsToStarboard ? -1 : 1) * deg2rad(30), wind: b.windDirection)
        }
        return desired
    }

    /// Nudges a heading out of the no-go zone, keeping it on the same side of the wind.
    private func sailable(_ heading: Double, wind: Double) -> Double {
        let relative = wrapAngle(wind - heading)
        let minimum = deg2rad(38)
        guard abs(relative) < minimum else { return heading }
        return wind - (relative >= 0 ? minimum : -minimum)
    }

    private func isClearOfTraffic(_ b: Boat, _ race: Race) -> Bool {
        race.boats.allSatisfy { $0.id == b.id || !$0.isOnCourse || ($0.position - b.position).length > 7 }
    }

    /// Whether every mark is more than `lengths` hull lengths clear of the boat. Penalty turns sweep a
    /// circle about two lengths across; three lengths of room to start them keeps that circle off the
    /// mark. No allowance for current: #100 owns navigating in it.
    private func isClearOfMarks(_ b: Boat, _ race: Race, lengths: Double) -> Bool {
        let room = race.boatClass.hull.length * lengths
        return race.course.obstacles.allSatisfy { ($0.position - b.position).length > $0.radius + room }
    }
}
