import RegattaCore

// The suite's hunter (#355, `BotProfile.hunter`): the tactician, sailing to the edge of the rules as an aggressive
// player does, never knowingly over them. A measuring profile only: the bots players race hold their course as the
// right-of-way boat and never hunt (#19, #228, `holdingCourse`); only the hunter steers at a boat that must keep clear.
// What she sees is her seat's, like any bot's: who keeps clear of whom (`OtherBoat.rightOfWay`), the mark-room and
// proper-course notices. Never the umpire's escape simulation: whether the other boat can still escape is not hers to
// know, so she keeps under the one part of rule 16.1's test she can see, its course-change rate.
//
// - Racing, as the right-of-way boat with a boat that must keep clear of her within `Hunter.rangeLengths` and not clear
//   astern of her (`quarry`), she turns towards that boat with a held rudder of `Hunter.rudder`, never faster than
//   `Hunter.rateShare` of the rules' course-change rate (`Hunter.courseChangeRate`, fleet-rules@5's `changesCourse`):
//   - as the leeward boat (rule 11) she luffs her, up to just outside the no-go zone, and while restricted under rule 17
//     no higher than her proper course's edge plus `properCourseMargin` (the aim's limit, `properCourseLimited`, isn't
//     enough: her luff is steered after it);
//   - otherwise (rule 10 as the starboard boat, 12, 13) she turns the way that brings the boat closer, bearing down on a
//     port boat's track: never away from it, so she never gives up her lane.
//   She stops turning `Hunter.maxTurn` off the heading she would sail, or where the turn would bring the boat inside
//   `Hunter.noCloserLengths` (she squeezes, she doesn't ram), and holds there with the autohelm; a turn the plan asks
//   for away from the boat she holds off too, up to `Hunter.maxTurn` and a little, then makes it at the same rate; and
//   with a boat that must keep clear of her in range but none to hunt (clear astern of her), she turns no faster. Nor
//   does she let the autohelm turn her faster there (`gently`): a turn it makes is hers under 16.1 (#228).
// - With mark-room at a mark (rule 18, `OwnBoat.markRoom`), in its zone, she takes all of it: she rounds as a live bot
//   does, which gives none of it up (`BotProfileTests.hunterTakesAllHerMarkRoom`), and hunts no one there.
// - She tacks or gybes only with no boat that must keep clear of her in range on the side the tap turns her to
//   (`tapTurnsAtKeepClearBoat`): the tap turns faster than rule 16.1's test.
// - She keeps clear first: `evasion` (a boat she must keep clear of, marks, the edge) is steered before this is
//   reached, and she never hunts a boat she owes mark-room, a ghost, or with a penalty to take; before her start she
//   sails as a live bot does (pre-start fighting is #337's: a combative live bot's luff, `startLuffing`).
extension BotBrain {
    /// The hunter's tunables (#355): how hard she turns at a boat, how far ahead and how near she looks.
    enum Hunter {
        /// Her held rudder turning at a boat: about 7°/s at the skiff's top turn rate, the gentle turn of #342's playtest.
        static let rudder = 0.2
        /// The rules' 16.1 course-change rate (fleet-rules@5 `incidents.escape.changesCourse`), radians a second: a turn
        /// no faster on any tick can never be rule 16.1 on her. A mirror; `BotProfileTests` pins it to the rules file.
        static let courseChangeRate = deg2rad(12)
        /// The share of `courseChangeRate` she turns at most, whatever her speed: a held rudder's rate grows as she
        /// gathers way.
        static let rateShare = 0.8
        /// Hull lengths, centre to centre, inside which she hunts a boat that must keep clear of her.
        static let rangeLengths = 4.0
        /// Hull lengths, centre to centre: she turns no further at a boat once the turn would bring it this close.
        static let noCloserLengths = 1.0
        /// Radians off the heading she would sail that she turns at most: a squeeze, not a spin.
        static let maxTurn = deg2rad(25)
        /// Seconds ahead she weighs a boat's closest approach, both sailing on in straight lines.
        static let lookahead = 3.0
        /// Radians she tries her heading either way when she weighs which way brings a boat closer.
        static let probe = deg2rad(5)
        /// Radians outside the no-go zone she luffs to at most, as `steer` does.
        static let noGoMargin = deg2rad(5)
        /// Radians off her sailing angle the autohelm may aim before she steers to its aim herself (`gently`).
        static let autohelmSlack = deg2rad(1.5)
        /// Radians past `maxTurn` she holds against a turn her plan asks for away from the boat.
        static let holdSlack = deg2rad(5)
    }

    /// The boat she hunts now, and the rule it keeps clear of her under: the nearest boat that must keep clear of her
    /// under rules 10–13 (`OtherBoat.rightOfWay`) within `Hunter.rangeLengths`, not clear astern of her, not a ghost, and
    /// not one she owes mark-room. Never a boat that keeps clear of her under rule 21 (taking a penalty or returning,
    /// `Race.rightsOfWay(of:)`): she holds her course for it as any bot does, and hunts no boat out of its penalty
    /// (#337 review). Nil when there is none.
    func quarry(_ b: SeatView.OwnBoat, _ view: SeatView) -> (boat: SeatView.OtherBoat, rule: RacingRule)? {
        let length = view.boatClass.hull.length
        var nearest: (boat: SeatView.OtherBoat, rule: RacingRule, gap: Double)?
        for other in view.others where !other.isGhost {
            guard let right = other.rightOfWay, right.keepClear == other.seat, !right.rule.isRule21,
                  keepClearRule(b, view, other) == nil else { continue }
            let offset = other.position - b.position
            let gap = offset.length
            guard gap <= length * Hunter.rangeLengths, offset.dot(b.forward) > -length, gap < nearest?.gap ?? .infinity
            else { continue }
            nearest = (other, right.rule, gap)
        }
        return nearest.map { ($0.boat, $0.rule) }
    }

    /// What the hunter's hunting made of her plan's helm (#355), for the suite to count (`BotDriver.isHuntingTurn`).
    enum HuntStep: Hashable, Sendable {
        /// She turned at the boat she hunts (`quarry`): a luff, or a turn that brings it closer.
        case turn
        /// She held at the edge of her turn, or turned as her plan asks no faster than she hunts.
        case hold
        /// With a boat that must keep clear of her in range and none to hunt, she turned no faster than she hunts.
        case gentle
    }

    /// The hunter's held input (#355) in place of `holdingCourse`'s, and what hunting made of it: `input` (her plan's
    /// helm) as she hunts the boat she hunts (`quarry`), or as a live bot holds her course (step nil) when there is
    /// none. `desired` is the heading her plan sails.
    func hunting(_ b: SeatView.OwnBoat, _ view: SeatView, _ input: BoatInput, desired: Double) -> (BoatInput, HuntStep?) {
        guard b.status == .racing, b.penalty == nil else { return (holdingCourse(b, view, input), nil) }
        let held = holdingCourse(b, view, input)
        // Mark-room (rule 18), in its zone: she rounds as a live bot does, which already takes all of it
        // (`BotProfileTests.hunterTakesAllHerMarkRoom`); hunting there, or turning no faster than she hunts, would give
        // some of it away.
        if b.zone?.isIn == true, b.markRoom.contains(where: { $0.entitled == view.seat }) { return (held, nil) }
        let most = huntRudder(b, view)
        guard let (quarry, rule) = quarry(b, view) else {
            // No boat to hunt: she holds her course as a live bot does, and with a boat that must keep clear of her
            // still in range (clear astern of her, say) she turns no faster than she hunts.
            guard hasKeepClearBoatInRange(b, view) else { return (held, nil) }
            return (gently(b, view, BoatInput(rudder: held.rudderValue.clamped(to: -most...most), ease: held.ease), most: most),
                    .gentle)
        }
        let (hunted, turned) = huntingInput(b, view, input, desired: desired, quarry: quarry, rule: rule, most: most)
        return (gently(b, view, hunted, most: most), turned ? .turn : .hold)
    }

    /// #337 (owner 2026-10-08): before her start, a combative live bot (`Tactics.startLuffUntil`) as the leeward
    /// right-of-way boat (rule 11) luffs a windward boat that must keep clear of her (`quarry`), as the hunter does
    /// racing: rule 16.1's rate and the hunter's limits (`huntingInput`, `gently`), never without the right of way, never
    /// a boat she owes room, and never onto a heading that would carry her over the line within `luffLineSeconds` (`crossesEarly`). She
    /// eases it off `startLuffUntil` seconds before the gun to start, and breaks it off sooner once she no longer has the
    /// time to spare for her approach to her spot (`hasTimeToSpare`), for good (`brokeOffStartLuff`: bearing away to
    /// her plan wins time back, and she would luff and break off in turn). Nil when she doesn't: she holds her course
    /// (`holdingCourse`) as every other bot does.
    func startLuffing(_ b: SeatView.OwnBoat, _ view: SeatView, _ input: BoatInput, desired: Double) -> BoatInput? {
        guard let until = tactics.startLuffUntil, b.status == .prestart, b.penalty == nil, view.time < 0,
              -view.time > until, !brokeOffStartLuff, hasTimeToSpare(b, view), let (quarry, rule) = quarry(b, view), rule == .windwardLeeward,
              !crossesEarly(b, view, heading: b.heading + luff(b) * Hunter.probe, within: Self.luffLineSeconds) else { return nil }
        let most = huntRudder(b, view)
        let (luffed, _) = huntingInput(b, view, input, desired: desired, quarry: quarry, rule: rule, most: most)
        return gently(b, view, luffed, most: most)
    }

    /// Seconds to spare she keeps over her approach to her spot (`secondsToSpot`) before she breaks a luff off
    /// (`hasTimeToSpare`). A placeholder: 2 s and 5 s gave the same pin third (0.701, #337 round 2); 2 s luffs more.
    static let luffSpareSeconds = 2.0

    /// Whether she still has time to luff before her start (#337, owner 2026-10-08: "luff with time to spare"): her
    /// approach to her own spot (`secondsToSpot`) plus `luffSpareSeconds` inside the time to the gun. Once it isn't, she
    /// breaks off and bears away to her plan (#337 round 1: luffing a windward boat for tens of seconds, combative
    /// pin-style bots from committee slots never got to the pin and lost the pin third).
    func hasTimeToSpare(_ b: SeatView.OwnBoat, _ view: SeatView) -> Bool {
        secondsToSpot(b, view, hold: Self.holdAngle(view)) + Self.luffSpareSeconds < -view.time
    }

    /// `input`, or with the autohelm due to turn her, her own rudder of `most` towards where it would turn her instead:
    /// the autohelm turns faster than she hunts, and a turn it makes is hers under rule 16.1 (#228). Due to turn her: a
    /// centred rudder with the autohelm's aim more than `Hunter.autohelmSlack` off her sailing angle, or a rudder she
    /// centres now (the autohelm engaging, `Autohelm.engage`) where it would snap to a groove that far off.
    func gently(_ b: SeatView.OwnBoat, _ view: SeatView, _ input: BoatInput, most: Double) -> BoatInput {
        guard abs(input.rudderValue) <= Autohelm.deadBand, b.autohelm?.isTapping != true else { return input }
        let angle = sailingAngle(b)
        let aim = b.autohelm?.aim ?? Autohelm.engage(sailingAngle: angle, tws: b.polarWindSpeed, boatClass: view.boatClass)
            .autohelm.aim(tws: b.polarWindSpeed, boatClass: view.boatClass)
        let error = wrapAngle(aim - angle)
        guard abs(error) > Hunter.autohelmSlack else { return input }
        let windSign: Double = b.boomSide == .port ? 1 : -1
        return BoatInput(rudder: (-windSign * error > 0 ? 1 : -1) * most, ease: input.ease)
    }

    /// The hunter's held input with `quarry` to hunt under `rule` (`hunting`), and whether she turned at it.
    private func huntingInput(_ b: SeatView.OwnBoat, _ view: SeatView, _ input: BoatInput, desired: Double,
                              quarry: SeatView.OtherBoat, rule: RacingRule, most: Double) -> (BoatInput, Bool) {
        let off = wrapAngle(b.heading - desired)
        if let toward = turn(towards: quarry, rule: rule, b, view), canTurn(toward, at: quarry, b, view, off: off) {
            return (BoatInput(rudder: toward * most, ease: input.ease), true)
        }
        let rudder = input.rudderValue
        guard abs(rudder) > Autohelm.deadBand else { return (input, false) }
        let towards = isTowards(rudder > 0 ? 1 : -1, quarry, rule: rule, b, view)
        // Holding at her edge: no further towards the boat, and no turn away from it while she is within her turn.
        if towards || abs(off) <= Hunter.maxTurn + Hunter.holdSlack { return (BoatInput(rudder: 0 as Int8, ease: input.ease), false) }
        return (BoatInput(rudder: rudder.clamped(to: -most...most), ease: input.ease), false)
    }

    /// Whether a tack or gybe now would turn the suite's hunter, racing, at a boat that must keep clear of her within
    /// `Hunter.rangeLengths`: on the side the tap turns her to (up through the wind on a beat, away from it on a run). The
    /// tap turns her at the autohelm's rate, faster than rule 16.1's course-change test, so she holds it off (`canTap`)
    /// until no such boat is there. Never for a live bot, nor for her before her start.
    func tapTurnsAtKeepClearBoat(_ b: SeatView.OwnBoat, _ view: SeatView) -> Bool {
        guard tactics.hunts, b.status == .racing else { return false }
        return turnsTowardsKeepClearBoat(b, view, turn: abs(sailingAngle(b)) < .pi / 2 ? luff(b) : -luff(b))
    }

    /// Whether a boat that must keep clear of her is within `Hunter.rangeLengths` of her, wherever it is.
    func hasKeepClearBoatInRange(_ b: SeatView.OwnBoat, _ view: SeatView) -> Bool {
        let range = view.boatClass.hull.length * Hunter.rangeLengths
        return view.others.contains { other in
            !other.isGhost && other.rightOfWay?.keepClear == other.seat && (other.position - b.position).length <= range
        }
    }

    /// The most rudder she holds turning at a boat: `Hunter.rudder`, or less where her speed would turn her faster than
    /// `Hunter.rateShare` of `Hunter.courseChangeRate` with it.
    func huntRudder(_ b: SeatView.OwnBoat, _ view: SeatView) -> Double {
        let rate = view.boatClass.steering.turnRate(speed: b.speed)
        return min(Hunter.rudder, Hunter.rateShare * Hunter.courseChangeRate / max(rate, 1e-9))
    }

    /// The way (+1 to starboard) she turns at `quarry`: a luff as the leeward boat (rule 11), otherwise the way that
    /// brings it closer than holding her course would; nil when neither does.
    func turn(towards quarry: SeatView.OtherBoat, rule: RacingRule, _ b: SeatView.OwnBoat, _ view: SeatView) -> Double? {
        if rule == .windwardLeeward { return luff(b) }
        let held = Self.closestApproach(of: quarry, to: b, heading: b.heading, lookahead: Hunter.lookahead)
        let ways = [1.0, -1.0].map { way in
            (way, Self.closestApproach(of: quarry, to: b, heading: b.heading + way * Hunter.probe, lookahead: Hunter.lookahead))
        }
        guard let best = ways.min(by: { $0.1 < $1.1 }), best.1 < held - 1e-3 else { return nil }
        return best.0
    }

    /// Whether turning her `way` (+1 to starboard) is towards `quarry`: the luff against a windward boat (rule 11), or a
    /// turn that brings the boat closer than holding her course.
    func isTowards(_ way: Double, _ quarry: SeatView.OtherBoat, rule: RacingRule, _ b: SeatView.OwnBoat,
                   _ view: SeatView) -> Bool {
        if rule == .windwardLeeward { return way == luff(b) }
        let held = Self.closestApproach(of: quarry, to: b, heading: b.heading, lookahead: Hunter.lookahead)
        return Self.closestApproach(of: quarry, to: b, heading: b.heading + way * Hunter.probe, lookahead: Hunter.lookahead) < held
    }

    /// The rudder's way that luffs her: to starboard on starboard tack, her sailing angle falling.
    func luff(_ b: SeatView.OwnBoat) -> Double { b.tack == .starboard ? 1 : -1 }

    /// Whether she may turn on `way` at `quarry`: within `Hunter.maxTurn` of the heading she would sail (`off` from it
    /// now), the boat no nearer than `Hunter.noCloserLengths` for it, outside the no-go zone by `Hunter.noGoMargin` and
    /// short of by the lee, and no higher than her proper course allows while she is restricted under rule 17.
    func canTurn(_ way: Double, at quarry: SeatView.OtherBoat, _ b: SeatView.OwnBoat, _ view: SeatView, off: Double) -> Bool {
        guard way * off < Hunter.maxTurn else { return false }
        let heading = b.heading + way * Hunter.probe
        let polar = view.boatClass.polar
        let angle = b.boomSide.sailingAngle(relativeWind: wrapAngle(b.windDirection - heading))
        if angle > -.pi / 2 && angle < BoatDynamics.noGoAngle(polar) + Hunter.noGoMargin { return false }
        if angle <= -.pi / 2 && .pi + angle > max(0, polar.byTheLeeLimit(tws: b.windSpeed) - Hunter.noGoMargin) { return false }
        if let notice = b.properCourse, angle >= 0, angle < notice.edgeSailingAngle + Self.properCourseMargin { return false }
        let near = Self.closestApproach(of: quarry, to: b, heading: heading, lookahead: Hunter.lookahead)
        return near >= view.boatClass.hull.length * Hunter.noCloserLengths
    }
}
