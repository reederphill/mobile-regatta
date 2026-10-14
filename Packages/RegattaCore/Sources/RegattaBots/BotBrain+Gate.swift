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
// #525 fix round 2: to her mark on the gybe that does not round it, she gybes onto the rounding gybe above the line
// (`gateSetUp`), not round the mark below it, where in a pack the gybe is refused and she carried deep; and straight for
// a point by the lee she runs, not the mirror angle that sailed her outside it.
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
    /// Metres up the rounding gybe's groove from her point at which she gybes onto it when she comes to her mark on the
    /// other gybe (#525 fix round 2, `gateSetUp`): above the line, so she rounds in one luff and does not gybe at the
    /// mark in the pack. Set by hand.
    static let gateSetUpMetres = 20.0
    /// Metres below her, at least, that point must lie for her to sail for it; higher than that she reaches across to
    /// the groove at `gateSetUpReach` (#525 fix round 2). Set by hand.
    static let gateSetUpDrop = 3.0
    /// Her angle off the wind on that reach, radians: a little below a beam reach, so she keeps her height above the
    /// line (#525 fix round 2). Set by hand.
    static let gateSetUpReach = deg2rad(100)
    /// Metres above her point below which she no longer gybes above the mark but at it, the old way (#525 fix round
    /// 2). Set by hand.
    static let gateSetUpLow = 5.0
    /// The least rudder of her set-up gybe (`gateSetUp`), a share of full: "throw her round to make the mark" (#525 fix
    /// round 4). Her own gybe is gentler (`HandTackTable.gybeFraction`, and on a planing class `PlaningTable.safeGybe`);
    /// from a reach above her point that gentle gybe ran 4 s and 19 m, and she crossed the line mid-turn. Set by hand.
    static let gateSetUpGybeFraction = 0.7
    /// The share of her set-up gybe's seconds she reads ahead on her course for her point's side (#525 fix round 4):
    /// the gybe bears her away as it goes, so she covers less of her reach than its whole time at her speed. Set by
    /// hand.
    static let gateSetUpLead = 0.5
    /// Radians by the lee, at most, of a point she runs for on the rounding gybe rather than gybe away: off her set-up
    /// gybe, or within `gateSetUpRunRange` of it (#525 fix round 4). Set by hand.
    static let gateSetUpLee = deg2rad(25)
    /// Metres from her point within which she runs for it by the lee on the rounding gybe (`gateSetUpLee`, #525 fix
    /// round 4). Set by hand.
    static let gateSetUpRunRange = 50.0

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

    /// "Gybe above the mark, not at it" (#525 fix round 2), on the gybe that does not round `mine` in one luff: she
    /// gybes onto the rounding gybe once her point bears on its side, so she comes to the line on the gybe that rounds
    /// it, not across it and round the mark by a gybe below it (in a pack that gybe is refused and she carries deep).
    /// Within `gateStraightRange` her point's side is read from where the gybe will leave her, the plan holds once
    /// made, and she gybes straight onto a run for her point, hard (`gateSetUpGybeFraction`, #525 fix round 4).
    /// Till then she sails for the point `gateSetUpMetres` up the rounding gybe's groove from her point, or, lower
    /// than that, reaches across to that groove at `gateSetUpReach`. Nil within `gateSetUpLow` of her point's height:
    /// the old way, straight on and the gybe round the mark.
    mutating func gateSetUp(_ mine: GateOption, _ b: SeatView.OwnBoat, _ view: SeatView, down: Double) -> Aim? {
        let wind = b.windDirection
        let up = view.course.upwind
        // "Gybe early enough to finish above the line" (#525 fix round 4): her point's side is read from where she will
        // be once the gybe is done, not from where she is; a prediction already past her point's height is late, and
        // she reads it from here. Far out (`gateStraightRange`) the gybe is to her point's layline, as ever.
        let close = mine.distance < Self.gateStraightRange
        let ahead = b.position + b.velocityOverGround * (gateSetUpGybeSeconds(b, view, down: down) * Self.gateSetUpLead)
        let from = close && up.dot(ahead - mine.entry) > 0 ? ahead : b.position
        // Where her point bears, as the wind's side: positive with it over her starboard side, as `Aim(heading:)`.
        let toEntry = wrapAngle(wind - (mine.entry - from).bearing)
        let entrySide: Tack = toEntry >= 0 ? .starboard : .port
        // Far out, no deeper on it than she sails straight for her point (`farDeep`), or she gybes back.
        let limit = close ? Self.gateMaxAngle : down + Self.gateDeepest
        // Once planned it holds (#525 fix round 4): as she bears away into the gybe her prediction swings, and a plan
        // dropped mid-turn ends the turn.
        let held = close && gateSetUpGybe.map { $0.leg == b.legIndex && $0.tack == mine.needs } ?? false
        if held || (entrySide == mine.needs && abs(toEntry) <= limit) {
            plannedTack = mine.needs
            if close { gateSetUpGybe = (b.legIndex, mine.needs) }
            // The gybe straight onto the course for her point, by the lee no further than `gateMaxAngle`: not
            // `navigate`'s aim, which with her point still on her side is on the gybe she is on, nor a heated-up angle,
            // which from above her point heads her at her mark.
            let now = wrapAngle(wind - (mine.entry - b.position).bearing)
            let onNeeds = (now >= 0 ? Tack.starboard : .port) == mine.needs
            guard close || !onNeeds else { return navigate(b, to: mine.entry, view) }
            let angle = onNeeds ? min(abs(now), Self.gateMaxAngle) : Self.gateMaxAngle
            return Aim(angle: angle, tack: mine.needs, tolerance: Self.reachTolerance)
        }
        let groove = Vec2.heading(Aim(angle: down, tack: mine.needs).heading(wind: wind))
        let setUp = mine.entry - groove * Self.gateSetUpMetres
        if up.dot(b.position - setUp) >= Self.gateSetUpDrop {
            let aim = Aim(heading: (setUp - b.position).bearing, b, tolerance: Self.reachTolerance)
            guard aim.tack == b.tack else { return nil }
            plannedTack = b.tack
            return downwindAim(b, view, aim: Aim(angle: min(aim.angle, Self.gateMaxAngle), tack: b.tack,
                                                 tolerance: Self.reachTolerance), nearMark: true)
        }
        // Lower down, across to its groove on a reach that keeps her height, while there is room above the line.
        guard up.dot(b.position - mine.entry) >= Self.gateSetUpLow else { return nil }
        plannedTack = b.tack
        return downwindAim(b, view, aim: Aim(angle: Self.gateSetUpReach, tack: b.tack, tolerance: Self.reachTolerance),
                           nearMark: true)
    }

    /// Seconds her set-up gybe takes her by hand from here, roughly: from her angle off the wind through dead downwind
    /// to her groove on the other gybe, at `gateSetUpGybeFraction`'s rudder (or her own, if more) at her speed.
    func gateSetUpGybeSeconds(_ b: SeatView.OwnBoat, _ view: SeatView, down: Double) -> Double {
        guard Self.turnsByHand(view) else { return 0 }
        let fraction = max(HandTackTable.gybeFraction(handling: turnHandling), Self.gateSetUpGybeFraction)
        let turn = max(0, .pi - b.twa) + max(0, .pi - down)
        return turn / (fraction * view.boatClass.steering.turnRate(speed: b.speed))
    }

    /// Her aim on the leg to the gate before she is through it, or nil when it is `navigate`'s to the gate's centre
    /// (more than `gatePickRange` above the line), or not that leg at all.
    ///
    /// More than `gateRecoverBelow` below the line she sails for a point `gateRecoverOutside` outside the nearer mark
    /// and `gateRecoverUp` above it until she is `gateRecoverAbove` above the line. Otherwise she picks her mark
    /// (`gateOption`, `picksLeftGateMark`) and sails for her point inside it: on the gybe that rounds it, straight for
    /// it when it lies deeper than a reach, gybing away first when it is on the other side or far and deep; on the
    /// other gybe across above it and onto the rounding gybe above the line (`gateSetUp`), else by `navigate` to its
    /// layline, and straight on to gybe round the mark only from inside `gateStraightRange` and low down. Straight for
    /// it she plans no gybe.
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
            // "Run by the lee to the mark" (#525 fix round 4): off her set-up gybe, or within `gateSetUpRunRange` (a
            // current setting her outside it), a point by the lee no further than `gateSetUpLee` she runs for, rather
            // than gybe away and round the mark by a gybe below the line.
            let setUp = gateSetUpGybe.map { $0.leg == b.legIndex && $0.tack == b.tack } ?? false
            let runs = !mine.onOwn && (setUp || mine.distance < Self.gateSetUpRunRange)
                && mine.offWind >= .pi - Self.gateSetUpLee
            if !runs, !mine.onOwn || mine.farDeep {
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
            if let aim = gateSetUp(mine, b, view, down: down) { return aim }
            // On the other gybe: to its layline and the gybe while there is room; close in, straight on and round it.
            guard mine.distance < Self.gateStraightRange, deeper, mine.onOwn else { return navigate(b, to: mine.entry, view) }
        }
        // Straight for it on her own gybe, by the lee no further than a few degrees; what `navigate` notes of it.
        plannedTack = b.tack
        isNearHerMark = true
        isAtHerGate = mine.distance < PlaningTable.gateRange
        // Her point by the lee: as close to dead downwind as she sails, not as far the other side (#525 fix round 2).
        let byTheLee = Aim(heading: (mine.entry - b.position).bearing, b, tolerance: 0).tack != b.tack
        let angle = byTheLee ? Self.gateMaxAngle : min(mine.offWind, Self.gateMaxAngle)
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
