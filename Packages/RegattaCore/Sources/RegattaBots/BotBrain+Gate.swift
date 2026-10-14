import Foundation
import RegattaCore

// The leg to the leeward gate before she is through it (#518, from #510's prototype, variants P and R). On main she
// sailed for a point below the gate's centre down the corridor to it and took the nearer mark only once across the
// line: a traverse of 25 to 35 m along the line to a mark, a gybe round it as often as not, and a boat that fell below
// the line outside a mark came back at it from below.
// Here she picks her mark from `gatePickRange` above the line, by what rounding each costs her in metres (the way to
// her point inside it and her gybes, the one round the mark dearest), and sails for her point inside it: straight for
// it on the gybe that rounds it in one luff, and never a gybe inside `gateStraightRange` of it. Below the line and not
// through it, she sails back above it round the nearer end.
// After the crossing nothing changes: `waypoint`'s point below the nearer mark, as before.
// Far and deep of her point (two gybes, away and back) the other mark is the cheaper by a gybe wherever the way to
// it is no reach: with the default gate's points 31 m apart she then changes for it and gybes once, and gybes away
// and back only for a pick she holds within `gateRepickMetres` (`BotGateTests.farAndDeepSheGybesAwayNotByTheLee`).
//
// #525 H1: the pick prices a crowded or shadowed mark (`gateTrafficMetres`), and on the rounding gybe in dirty air with
// room to come back she gybes out of it once a leg; the traffic is blended over `gateTrafficSeconds` so the pick does
// not follow the pack. H3 is the tap's (`tapClearanceOwing`).
//
// Every constant here was set by hand in #510 on 80 races (8 bots, 2 laps); none was swept beyond a step or two inside
// the noise, but the pick's range (40 against 80 m) and the inset, which moved the overshoots clearly.

extension BotBrain {
    /// Metres above the gate's line from which she has picked her mark. Its own range, not `tacticalRange`: picked at
    /// 40 m she overshot her mark more often than at 80 (#510, set by hand on 80 races).
    static let gatePickRange = 80.0
    /// Metres from her point inside the mark within which she sails straight for it and gybes no more (#510, set by
    /// hand on 80 races).
    static let gateStraightRange = 30.0
    /// What a gybe is worth in metres when she picks (#510, set by hand on 80 races).
    static let gateGybeMetres = 20.0
    /// What the gybe round the mark itself is worth in metres when she picks: the rounding on the gybe that does not
    /// round it in one luff (#510, set by hand on 80 races; the one number for how readily she takes that rounding
    /// over the reach across to the far mark).
    static let gateMarkGybeMetres = 35.0
    /// Metres the other mark must cost her less before she changes her pick (#510, set by hand on 80 races).
    static let gateRepickMetres = 10.0
    /// Radians deeper than her groove she still sails straight for her point from beyond `gateStraightRange`; deeper
    /// than that she gybes away and comes back on its layline rather than run by the lee (#510, set by hand on 80 races).
    static let gateDeepest = deg2rad(12)
    /// Metres more than the mark's radius, her beam and `markClearance` her point lies inside the mark, along the
    /// line (#510, set by hand on 80 races: 5 against 2.5 m moved the overshoots).
    static let gateInset = 5.0
    /// Metres below the gate's line her point lies (#510, set by hand on 80 races).
    static let gateDepth = 2.0
    /// Radians from dead downwind within which a course to her point counts as on her own gybe, whichever side of
    /// dead downwind it lies (#510, set by hand on 80 races).
    static let gateLee = deg2rad(10)
    /// Radians short of her downwind groove from which a course to her point is a run, not a reach: `navigate`'s own
    /// margin (#510, set by hand on 80 races).
    static let gateDeeperMargin = deg2rad(2)
    /// The deepest angle she sails straight for her point at, radians: short of dead downwind by what keeps her boom
    /// on her side (#510, set by hand on 80 races).
    static let gateMaxAngle = Double.pi - deg2rad(3)
    /// Metres below the gate's line, not through it, from which she sails back above it (#510 R, set by hand on 80
    /// races).
    static let gateRecoverBelow = 1.0
    /// Metres above the gate's line at which she is back above it and sails for her mark again (#510 R, set by hand on
    /// 80 races).
    static let gateRecoverAbove = 10.0
    /// Metres outside the nearer mark, along the line, the point she sails back above the line for lies (#510 R, set
    /// by hand on 80 races).
    static let gateRecoverOutside = 8.0
    /// Metres above the line that point lies (#510 R, set by hand on 80 races).
    static let gateRecoverUp = 20.0

    /// "Avoid the crowded mark" (#525 H1): metres from the line to a mark's point inside which a boat below her, on the
    /// way, is in her road (`gateTrafficMetres`). Set by hand (the prototype's value; not swept).
    static let gateTrafficNear = 25.0
    /// Metres a boat on that line adds to a mark's cost, fading linearly to nothing at `gateTrafficNear` off it: about a
    /// gybe and a half (`gateGybeMetres`, `gateMarkGybeMetres`), enough to flip a close pick and not a far one. Set by
    /// hand (the prototype's value; not swept).
    static let gateTrafficBoatMetres = 30.0
    /// What the speed she loses in the wake and shadow along that line is worth, as metres per metre of line lost (four
    /// samples of the ribbons at the time she would be there). Set by hand (the prototype's value; not swept).
    static let gateTrafficShadowWeight = 1.5
    /// Seconds of the time constant with which the traffic and wake on each mark's line is blended into her pick: boats
    /// are read where they are now and sail on through the gate in a few seconds, and the pick must not follow every
    /// one of them (unsmoothed, 70 of 128 roundings in a trace of 16 races changed their pick, against 8 on main; at 8 s 20, at 12 s 17, at
    /// 15 s 13). Set by hand.
    static let gateTrafficSeconds = 12.0
    /// Metres from her point, at least, at which she gybes out of dirty air on the rounding gybe (#525 H1): room to come
    /// back on its layline before `gateStraightRange`. Set by hand (the prototype's value; not swept).
    static let gateShadowGybeMetres = 45.0

    /// Seconds after a gate's leg ends that the beat's first tack is held (#523), so a boat that never gets
    /// close-hauled (a refused luff) is not held to it for good.
    static let gateExitSeconds = 25.0
    /// Radians off her upwind groove at which she counts as close-hauled on the rounding tack and the window ends.
    static let gateExitHauled = deg2rad(4)

    /// The gate of the leg she is racing: its marks, left and right looking downwind, and the centre of its line.
    struct Gate {
        var left: CourseLayout.Mark
        var right: CourseLayout.Mark
        var centre: Vec2

        func mark(left isLeft: Bool) -> CourseLayout.Mark { isLeft ? left : right }
    }

    /// The gate of the leg she is racing, or nil when her leg rounds no gate.
    static func gate(of b: SeatView.OwnBoat, _ view: SeatView) -> Gate? {
        let c = view.course
        guard b.status == .racing, c.legs.indices.contains(b.legIndex), case .round(let index) = c.legs[b.legIndex],
              case .gate(let left, let right) = c.elements[index] else { return nil }
        return Gate(left: left, right: right, centre: c.targetPosition(for: c.legs[b.legIndex]))
    }

    /// Her point through the gate inside `mark`: along the line towards its centre by the mark's radius, her beam,
    /// `markClearance` and `gateInset`, `gateDepth` below the line.
    static func gateEntry(_ mark: CourseLayout.Mark, centre: Vec2, _ view: SeatView) -> Vec2 {
        let inside = mark.radius + view.boatClass.hull.beam + markClearance + gateInset
        return mark.position + (centre - mark.position).normalized * inside - view.course.upwind * gateDepth
    }

    /// The gybe that rounds `mark` in one luff: the one that heads her outwards across the line, port for the left
    /// mark in a wind down the course.
    static func roundingTack(_ mark: CourseLayout.Mark, centre: Vec2, _ b: SeatView.OwnBoat, _ view: SeatView) -> Tack {
        Aim(heading: ((mark.position - centre).normalized - view.course.upwind * 0.3).bearing, b, tolerance: 0).tack
    }

    /// What rounding one of the gate's marks is to her from where she is.
    struct GateOption {
        /// What it costs her, metres: the way to her point inside it, and her gybes.
        var cost: Double
        /// Her point inside it (`gateEntry`).
        var entry: Vec2
        /// Metres to that point.
        var distance: Double
        /// Whether the course to it is on her own gybe, or within `gateLee` of dead downwind.
        var onOwn: Bool
        /// The angle off the wind of the course to it, radians.
        var offWind: Double
        /// The gybe that rounds it in one luff (`roundingTack`).
        var needs: Tack
        /// Whether it lies beyond `gateStraightRange` and more than `gateDeepest` deeper than her groove, and she has
        /// not yet sailed straight for it (`gateCommitted`).
        var farDeep: Bool
        /// Of `cost`, the metres of traffic and wake on the way to it (`gateTrafficMetres`).
        var traffic: Double = 0
    }

    /// What rounding the gate's left or right mark is to her now. On the gybe that rounds it in one luff the cost is
    /// the way there, deeper than her groove the gybing cone's length, and two gybes if the point is on the other
    /// side or far and deep; on the other gybe a gybe to get there, or the gybe round the mark itself.
    func gateOption(left: Bool, _ gate: Gate, _ b: SeatView.OwnBoat, _ view: SeatView) -> GateOption {
        let mark = gate.mark(left: left)
        let down = grooveAngle(.downwind, b, view)
        let entry = Self.gateEntry(mark, centre: gate.centre, view)
        let to = entry - b.position
        let aim = Aim(heading: to.bearing, b, tolerance: 0)
        let onOwn = aim.tack == b.tack || aim.angle >= .pi - Self.gateLee
        let needs = Self.roundingTack(mark, centre: gate.centre, b, view)
        // Deeper than her groove she gybes down to it: the gybing cone's length.
        // RegattaCore's cosine (`Vec2.heading`), as the rest of her brain takes it.
        let cone = to.length * Vec2.heading(.pi - aim.angle).y / Vec2.heading(.pi - down).y
        let length = aim.angle > down ? cone : to.length
        // Once she has sailed straight for a mark's point she is no longer far and deep of it: she holds on.
        let committed = gateCommitted.map { $0.leg == b.legIndex && $0.left == left } ?? false
        let farDeep = !committed && to.length >= Self.gateStraightRange && aim.angle > down + Self.gateDeepest
        var cost: Double
        if b.tack == needs {
            // Far out and much deeper than her groove she gybes away and back for it rather than run by the lee.
            cost = !onOwn || farDeep ? length + 2 * Self.gateGybeMetres : length
        } else if !onOwn {
            cost = length + Self.gateGybeMetres
        } else if aim.angle > down, to.length >= Self.gateStraightRange {
            cost = cone + Self.gateGybeMetres
        } else {
            cost = length + Self.gateMarkGybeMetres
        }
        let traffic = gateTrafficMetres(to: entry, gate, b, view)
        cost += traffic
        return GateOption(cost: cost, entry: entry, distance: to.length, onOwn: onOwn, offWind: aim.angle, needs: needs,
                          farDeep: farDeep, traffic: traffic)
    }

    /// "Avoid the crowded mark" (#525 H1): the metres the boats below her and their wake cost her on the way to `point`.
    /// Each boat below her on the way, within `gateTrafficNear` of the line to it and not yet through the gate, blocks it
    /// (`gateTrafficBoatMetres`, less the further off the line), as boats are where they are now; and the speed she loses
    /// in the wake the ribbons leave along it at the time she gets there (`view.wake`), `gateTrafficShadowWeight` times.
    /// Ghosts add nothing. Nothing in range: 0.
    func gateTrafficMetres(to point: Vec2, _ gate: Gate, _ b: SeatView.OwnBoat, _ view: SeatView) -> Double {
        let line = point - b.position
        let length = line.length
        guard length > 1, view.others.contains(where: { !$0.isGhost }) else { return 0 }
        let up = view.course.upwind
        let dir = line / length
        var metres = 0.0
        for other in view.others where !other.isGhost {
            let rel = other.position - b.position
            let along = rel.dot(dir)
            // Below her, on the way to the point, and not already through the gate.
            guard along > 0, along < length + 5, rel.dot(up) < 0, up.dot(other.position - gate.centre) > -3 else { continue }
            let off = abs(rel.cross(dir))
            if off < Self.gateTrafficNear { metres += Self.gateTrafficBoatMetres * (1 - off / Self.gateTrafficNear) }
        }
        let speed = max(b.speed, 1)
        var lost = 0.0
        for k in 1...4 {
            let f = Double(k) / 4
            let tick = TurbulenceRibbons.tick(after: length * f / speed, from: view.tick)
            lost += (1 - view.wake.factor(at: b.position + line * f, tick: tick, receiver: view.seat)) * length / 4
        }
        return metres + Self.gateTrafficShadowWeight * lost
    }

    /// The traffic metres she prices on each mark's pick (#525 H1): `left` and `right` now, blended into the last leg's
    /// with a time constant of `gateTrafficSeconds`; the first on a leg is as it is.
    mutating func smoothedGateTraffic(_ left: Double, _ right: Double, _ b: SeatView.OwnBoat, _ view: SeatView)
        -> (left: Double, right: Double) {
        var smoothed = (leg: b.legIndex, left: left, right: right, time: view.time)
        if let last = gateTraffic, last.leg == b.legIndex, view.time > last.time {
            let share = 1 - exp(-(view.time - last.time) / Self.gateTrafficSeconds)
            smoothed.left = last.left + (left - last.left) * share
            smoothed.right = last.right + (right - last.right) * share
        }
        gateTraffic = smoothed
        return (smoothed.left, smoothed.right)
    }

    /// What each of her gate's marks costs her now (`gateOption`), or nil when her leg rounds no gate.
    func gateCosts(_ b: SeatView.OwnBoat, _ view: SeatView) -> (left: Double, right: Double)? {
        guard let gate = Self.gate(of: b, view) else { return nil }
        return (gateOption(left: true, gate, b, view).cost, gateOption(left: false, gate, b, view).cost)
    }

    /// Whether she picks the left mark at costs `left` and `right`: the cheaper, the left on a tie; having picked
    /// (`held`, whether it was the left) she keeps it unless the other costs more than `gateRepickMetres` less.
    static func picksLeftGateMark(held: Bool?, left: Double, right: Double) -> Bool {
        guard let held else { return left <= right }
        let mine = held ? left : right, other = held ? right : left
        return other + gateRepickMetres >= mine ? held : !held
    }

    /// Her aim on the leg to the gate before she is through it, or nil when it is `navigate`'s to the gate's centre
    /// (more than `gatePickRange` above the line), or not that leg at all.
    ///
    /// More than `gateRecoverBelow` below the line she sails for a point `gateRecoverOutside` outside the nearer mark
    /// and `gateRecoverUp` above it until she is `gateRecoverAbove` above the line. Otherwise she picks her mark
    /// (`gateOption`, `picksLeftGateMark`) and sails for her point inside it: on the gybe that rounds it, straight for
    /// it when it lies deeper than a reach, gybing away first when it is on the other side or far and deep; on the
    /// other gybe by `navigate` to its layline, and straight on to gybe round the mark only from inside
    /// `gateStraightRange`. Straight for it she plans no gybe.
    mutating func gateAim(_ b: SeatView.OwnBoat, _ view: SeatView) -> Aim? {
        guard let gate = Self.gate(of: b, view), b.roundingStage == 0 else {
            gateRecovering = false
            return nil
        }
        let up = view.course.upwind
        let above = up.dot(b.position - gate.centre)
        if above < -Self.gateRecoverBelow {
            gateRecovering = true
        } else if above > Self.gateRecoverAbove {
            gateRecovering = false
        }
        if gateRecovering {
            // The nearer end now, not one she holds to.
            let near = gate.mark(left: (gate.left.position - b.position).length <= (gate.right.position - b.position).length)
            let outwards = (near.position - gate.centre).normalized
            return navigate(b, to: near.position + outwards * Self.gateRecoverOutside + up * Self.gateRecoverUp, view)
        }
        guard above < Self.gatePickRange, above > -Self.gateRecoverBelow else { return nil }
        // From the pick on she is near her mark of her leg, as inside `PlaningTable.markRange`: no gybe deferred for
        // speed and a refused turn holds the closest course to her point (#523; `navigate` below notes it by its
        // distance to her point, and from 80 m the pick wanted the other gybe while neither rule held).
        defer { isNearHerMark = true }

        let l = gateOption(left: true, gate, b, view), r = gateOption(left: false, gate, b, view)
        let held = gatePick.flatMap { $0.leg == b.legIndex ? $0.left : nil }
        // The traffic she prices is the boats' of the last `gateTrafficSeconds`, not of this tick: a boat that sails on
        // through the gate leaves a crowded mark dear a while, so her pick does not flip back and forth with the pack.
        let traffic = smoothedGateTraffic(l.traffic, r.traffic, b, view)
        let picksLeft = Self.picksLeftGateMark(held: held, left: l.cost - l.traffic + traffic.left,
                                               right: r.cost - r.traffic + traffic.right)
        gatePick = (b.legIndex, picksLeft)
        let mine = picksLeft ? l : r
        let down = grooveAngle(.downwind, b, view)
        let deeper = mine.offWind > down - Self.gateDeeperMargin
        if b.tack == mine.needs {
            // On the gybe she rounds it on: straight for her point, not down her groove past it. With it on the other
            // side, or far and deep, she gybes now and `navigate` brings her back on its layline; a reach is its too.
            if !mine.onOwn || mine.farDeep {
                plannedTack = b.tack.other
                return navigate(b, to: mine.entry, view)
            }
            guard deeper else { return navigate(b, to: mine.entry, view) }
            // "Gybe out of dirty air, once" (#525 H1): in a shadow with room to come back, the other gybe, once a leg.
            if b.shadow < Self.dirtyAir, mine.distance >= Self.gateShadowGybeMetres, gateShadowGybeLeg != b.legIndex {
                gateShadowGybeLeg = b.legIndex
                plannedTack = b.tack.other
                return navigate(b, to: mine.entry, view)
            }
            // She has sailed straight for this point: far and deep never reprices it.
            gateCommitted = (b.legIndex, picksLeft)
        } else {
            // On the other gybe: to its layline and the gybe while there is room; close in, straight on and round it.
            guard mine.distance < Self.gateStraightRange, deeper, mine.onOwn else { return navigate(b, to: mine.entry, view) }
        }
        // Straight for it on her own gybe, by the lee no further than a few degrees; what `navigate` notes of it.
        plannedTack = b.tack
        isNearHerMark = true
        isAtHerGate = mine.distance < PlaningTable.gateRange
        let angle = min(mine.offWind, Self.gateMaxAngle)
        return downwindAim(b, view, aim: Aim(angle: angle, tack: b.tack, tolerance: Self.reachTolerance), nearMark: true)
    }
}

extension BotBrain {
    /// Opens and closes the window in which the beat off a gate starts on the rounding tack (`gateExit`, #523): it
    /// opens on the first tick of the leg after a gate's, on the tack that rounds the gate's nearer mark in one luff
    /// (`roundingTack`: port off the left mark, starboard off the right), and ends when she is close-hauled on it,
    /// `gateExitSeconds` on, or when she is no longer on that leg.
    mutating func updateGateExit(_ b: SeatView.OwnBoat, _ view: SeatView) {
        let c = view.course
        if let exit = gateExit {
            let up = grooveAngle(.upwind, b, view)
            let hauled = b.tack == exit.tack && abs(sailingAngle(b)) <= up + Self.gateExitHauled
            if exit.leg != b.legIndex || view.time >= exit.until || hauled || b.status != .racing { gateExit = nil }
            return
        }
        // The first tick of the leg after her pick's gate: where she is is the leg's end of that gate.
        guard b.status == .racing, let pick = gatePick, pick.leg == b.legIndex - 1, c.legs.indices.contains(b.legIndex),
              case .round(let next) = c.legs[b.legIndex], c.elements.indices.contains(next),
              case .round(let index) = c.legs[pick.leg], case .gate(let left, let right) = c.elements[index] else { return }
        if case .gate = c.elements[next] { return }
        let centre = c.targetPosition(for: c.legs[pick.leg])
        let leftIsNearer = (left.position - b.position).length <= (right.position - b.position).length
        let mark = leftIsNearer ? left : right
        gatePick = nil
        let tack = Self.roundingTack(mark, centre: centre, b, view)
        gateExit = (b.legIndex, tack, view.time + Self.gateExitSeconds)
    }
}
