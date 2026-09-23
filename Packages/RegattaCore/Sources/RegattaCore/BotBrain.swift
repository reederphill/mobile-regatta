import Foundation

/// Helms a computer-controlled boat: pre-start timing, beating and running between
/// laylines, playing shifts, mark roundings, penalty turns, and keeping clear when
/// it is the give-way boat.
struct BotBrain {
    let skill: Double
    /// Where on the line to start, 0 = pin, 1 = committee boat.
    let startSpot: Double
    let finishSpot: Double
    let holdDepth: Double
    /// Seconds added to the approach; negative values make the bot early (and risk OCS).
    let timingSlack: Double
    let penaltyDirection: Double
    var plannedTack: Tack = .starboard
    var lastTackTime = -1_000.0

    init(rng: inout SplitMix64) {
        skill = rng.range(0.35, 1)
        startSpot = rng.range(0.1, 0.9)
        finishSpot = rng.range(0.6, 0.85)
        holdDepth = rng.range(18, 35)
        timingSlack = rng.range(-2.5, 5) * (1.3 - skill)
        penaltyDirection = rng.bool() ? 1 : -1
    }

    mutating func rudder(for i: Int, in race: Race) -> Double {
        let boat = race.boats[i]
        guard boat.isOnCourse else { return 0 }
        if boat.penaltyTurnsOwed > 0 && (boat.isTakingPenalty || isClearOfTraffic(boat, race)) {
            return penaltyDirection
        }
        var heading = desiredHeading(boat, race)
        heading = keepClear(boat, race, desired: heading)
        heading = avoidMarks(boat, race, desired: heading)
        return (wrapAngle(heading - boat.heading) / deg2rad(20)).clamped(to: -1...1)
    }

    private mutating func desiredHeading(_ b: Boat, _ race: Race) -> Double {
        let c = race.course
        switch b.status {
        case .prestart where race.time < 0:
            return prestartHeading(b, race)
        case .prestart:
            return navigate(b, to: startPoint(c) + c.upwind * 20, race)
        case .ocs:
            return navigate(b, to: startPoint(c) - c.upwind * 15, race)
        case .racing:
            return navigate(b, to: waypoint(b, c), race)
        case .finished, .dsq, .dnf:
            return b.heading
        }
    }

    private func startPoint(_ c: Course) -> Vec2 {
        c.pin + (c.committee - c.pin) * startSpot
    }

    private mutating func prestartHeading(_ b: Boat, _ race: Race) -> Double {
        let c = race.course
        let spot = startPoint(c)
        let timeLeft = -race.time
        let distance = (spot - b.position).length
        let beatSpeed = race.polar.targetSpeed(twa: race.polar.upwindTWA, windSpeed: b.windSpeed)
        let timeNeeded = distance / max(beatSpeed, 0.5) * 1.25 + 5 + timingSlack

        if timeLeft > timeNeeded + 4 {
            let hold = spot - c.upwind * holdDepth
            if (hold - b.position).length > 12 { return navigate(b, to: hold, race) }
            return b.windDirection - deg2rad(28) // luff and wait
        }
        // Too close to the line with time to kill: reach away along it rather than
        // luffing, because a luffing boat still coasts several lengths.
        let depth = -c.lineSide(b.position)
        if depth < b.speed * 4 + 3 && depth / max(b.speed, 1) < timeLeft - 2 {
            return b.windDirection - deg2rad(110)
        }
        let eta = distance / max(b.speed, 1)
        if eta < timeLeft - 3 { return b.windDirection - deg2rad(28) }
        return navigate(b, to: spot - c.upwind * 2, race)
    }

    /// The point to sail at for the current leg, offset so the mark is left to port.
    private func waypoint(_ b: Boat, _ c: Course) -> Vec2 {
        switch c.legs[b.legIndex] {
        case .round(let index):
            let mark = c.marks[index]
            let u = c.upwind, r = c.right
            let m = mark.position
            switch (mark.kind, b.roundingStage) {
            case (.windward, 0):
                return detour(from: b.position, to: m + r * 6 + u * 4, around: m, via: m + r * 7 - u * 7)
            case (.windward, _):
                return m + u * 9 - r * 10
            case (.leeward, 0):
                return detour(from: b.position, to: m - r * 6 - u * 4, around: m, via: m - r * 7 + u * 7)
            case (.leeward, _):
                return m - u * 9 + r * 10
            }
        case .finish:
            return c.pin + (c.committee - c.pin) * finishSpot - c.upwind * 12
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
        let up = race.polar.upwindTWA
        let down = race.polar.downwindTWA
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
        for other in race.boats where other.id != b.id && other.isOnCourse {
            let offset = other.position - b.position
            guard offset.length < 30 else { continue }
            let relativeVelocity = other.velocity - myVelocity
            let vv = relativeVelocity.lengthSquared
            let t = vv > 1e-6 ? (-offset.dot(relativeVelocity) / vv).clamped(to: 0...lookahead) : 0
            guard (offset + relativeVelocity * t).length < Boat.length * 1.3 else { continue }

            let call = Rules.judge(b, other, course: race.course)
            guard call.offender == b.id else { continue }

            // Headings are set relative to the wind so evasive action never parks the boat in irons.
            let side: Double = b.tack == .port ? 1 : -1
            switch call.rule {
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
            guard abs(offset.cross(ahead)) < obstacle.radius + Boat.beam + 1 else { continue }
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
}
