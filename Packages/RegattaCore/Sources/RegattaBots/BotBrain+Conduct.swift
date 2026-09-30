import RegattaCore

// A bot's conduct under the rules once racing (#101, #19: "bots hold their rights as a human would: they hold course
// as the right-of-way boat, defend a lane, and luff within rule 16's room"; "they never hunt other boats to force
// fouls, and never protest"). What she sees of the rules is her seat's (`SeatView`): who keeps clear of whom under
// rules 10–13 (`OtherBoat.rightOfWay`) and the mark-room notices told her (`OwnBoat.markRoom`). Never the umpire's
// escape simulation or its calls to come: room is her own reckoning, a straight-line closest approach.
//
// - Give way (rules 10–13, and 18 when she owes mark-room): she steers clear with the rudder (`racingKeepClear`): a
//   port boat ducks, a windward boat luffs, a boat clear astern or owing mark-room turns away, each by the least turn
//   that passes clear; a tacking boat finishes her tack (rule 13). Rule 21 is `penaltyInput`'s (#100) and, returning
//   when OCS, `returnAim`'s (#99).
// - Hold course (#228): as the right-of-way boat she keeps the rudder centred and the autohelm holding, rather than
//   rudder a turn towards a boat that must keep clear of her inside the time it takes her to keep clear
//   (`holdingCourse`, rule 16.1); turning off a mark that way, she holds her course instead while it clears the mark
//   (`evasiveHeading`). She never gives her lane up to such a boat either: nothing here has her give way when she
//   has right of way. A turn her autohelm makes following a shift isn't hers.
// - She taps a tack or gybe only clear of every boat (`tapIsClear`): a boat tacking keeps clear (rule 13), and one
//   that acquires right of way by it gives room (rule 15).
// - Misjudging (#103, #19: "they foul only by misjudging"): meeting a boat she must keep clear of under a rule in
//   `BotWeaknesses.misjudgeScope`, she may misjudge the encounter, by her skill's `ruleMisjudgeRate`, drawn once an
//   encounter (`judgeEncounters`): she believes she holds her rights and sails on, as she would were she the
//   right-of-way boat, so fails to keep clear. A misjudgement only ever leaves out her give-way manoeuvre: it never
//   turns her towards a boat, and her hold-course under 16.1 is as ever. None from National's band up.
// - Ghosts have no rights or obligations: she ignores them. She never steers at a boat to force a foul, and never
//   protests: a `BotDecision` has no protest tap.
//
// Before her start her conduct is #99's (`keepClear`, `BotBrain+Start.swift`), unchanged.
extension BotBrain {
    /// Hull lengths, centre to centre, inside which a turn of hers towards a boat that must keep clear of her takes
    /// that boat's room (`holdingCourse`).
    static let roomDistance = 2.0
    /// Turns she tries her rudder's way when she weighs holding her course (`turnsTowardsKeepClearBoat`), radians: a
    /// touch, and what the rudder turns her through in the escape simulation's horizon.
    static let roomTurns = [deg2rad(5), deg2rad(10), deg2rad(20)]
    /// Seconds ahead she weighs room to keep clear over (`holdingCourse`): the escape simulation's horizon (the
    /// rules' 2 s, `RulesConfig.Escape.horizon`) and further, the more skilled she is.
    var roomLookahead: Double { 2 + style.skill }
    /// Seconds between the moments she weighs the other boat at over `roomLookahead`.
    static let roomStep = 0.1

    /// Metres within which she weighs a boat before a tack or gybe (`tapIsClear`).
    static let tapRange = 40.0
    /// Seconds ahead she looks through a tack or gybe for a boat she would sail into: the tack itself, while she keeps
    /// clear of every boat (rule 13) and can't steer to. Once through it she keeps clear as ever.
    static let tapLookahead = 3.0
    /// Seconds ahead she looks, tacking or gybing onto port, for a boat on starboard: through the tack and on, slowed by
    /// it, while she keeps clear of that boat (rule 10), too slow to duck her.
    static let tapOntoPortLookahead = 6.0
    /// Her speed through a tack or gybe, as a share of her speed now: a tack slows her.
    static let tapSpeedShare = 0.5
    /// Hull lengths, centre to centre, a boat must pass off her through a tack or gybe.
    static let tapClearance = 1.3
    /// Radians between the headings she tries for the least turn that keeps her clear (`clearingHeading`).
    static let clearingStep = deg2rad(5)

    // MARK: - Misjudging

    /// Draws her judgement of each boat she meets racing that she must keep clear of under a rule in
    /// `BotWeaknesses.misjudgeScope` (#103): once an encounter, the first decision she owes that boat keep-clear
    /// within `keepClearRange`, kept until that boat is beyond it again, so she doesn't swing between judgements
    /// through one encounter. From her own stream (`rng`), and only if she can misjudge at all, so a bot that
    /// misjudges nothing draws nothing. Before her start, or not racing, she judges nothing (#99, #280).
    mutating func judgeEncounters(_ b: SeatView.OwnBoat, _ view: SeatView) {
        guard b.status == .racing, weaknesses.ruleMisjudgeRate > 0 else {
            if !misjudged.isEmpty { misjudged = [:] }
            return
        }
        // Rebuilt from the boats in range, in seat-view order, never by iterating the dictionary (ADR 0002).
        let inRange = view.others.filter {
            !$0.isGhost && ($0.position - b.position).length < Self.keepClearRange
        }
        var judged: [Int: Bool] = [:]
        for other in inRange {
            if let judgement = misjudged[other.seat] {
                judged[other.seat] = judgement
            } else if let rule = keepClearRule(b, view, other), BotWeaknesses.misjudgeScope.contains(rule) {
                judged[other.seat] = rng.unit() < weaknesses.ruleMisjudgeRate
            }
        }
        misjudged = judged
    }

    /// Whether she misjudges her encounter with `other`, keeping clear of her under `rule` (`judgeEncounters`).
    func misjudges(_ other: SeatView.OtherBoat, _ rule: RacingRule) -> Bool {
        misjudged[other.seat] == true && BotWeaknesses.misjudgeScope.contains(rule)
    }

    // MARK: - Giving way

    /// The rule she keeps clear of `other` under, racing: the one rules 10–13 name her keep-clear boat under
    /// (`OtherBoat.rightOfWay`), else `.givingMarkRoom` when a mark-room notice has her owe `other` room (rule 18,
    /// `OwnBoat.markRoom`), or nil when she owes `other` nothing.
    func keepClearRule(_ b: SeatView.OwnBoat, _ view: SeatView, _ other: SeatView.OtherBoat) -> RacingRule? {
        if let right = other.rightOfWay, right.keepClear == view.seat { return right.rule }
        if b.markRoom.contains(where: { $0.owing == view.seat && $0.entitled == other.seat }) { return .givingMarkRoom }
        return nil
    }

    /// She is this close to rule 13's end (`closeHauled`), radians, within the turn she makes before her next decision.
    static let tackEndMargin = deg2rad(4)

    /// "Finishing the tack": the heading that ends her rule 13, close-hauled on her new tack and a little more. Within
    /// `tackEndMargin` of close-hauled she steers for it and no further: the tick her tack ends she may hold rights,
    /// and a rudder still hard over past it, from a decision made while she was tacking, would turn her towards the
    /// boat that now keeps clear of her (#101, #263).
    func finishingTack(_ b: SeatView.OwnBoat, _ view: SeatView) -> Double {
        let side: Double = b.tack == .port ? 1 : -1
        let closeHauled = Self.closeHauled(b.polarWindSpeed, view)
        let beyond = closeHauled - b.twa < Self.tackEndMargin ? 0 : deg2rad(10)
        return b.windDirection + side * (closeHauled + beyond)
    }

    /// Her give-way manoeuvre racing (#101), keeping clear of `other` under `rule` with a collision coming on
    /// `desired`: steered with the rudder (`evasiveHeading`).
    /// - Rule 13: she finishes her tack, bearing away to close-hauled on her new tack and a little more, which ends it.
    ///   Luffing to keep clear held her inside rule 13's end (the skiff's ~40°), still tacking, until the contact
    ///   (#231).
    /// - Rule 10: the port boat ducks, bearing away behind the starboard boat.
    /// - Rule 11: the windward boat luffs, away from the leeward one.
    /// - Rule 12, and mark-room she owes (18.2): she turns away from the other boat's side.
    /// Each by the least turn that passes clear (`clearingHeading`), the other way if none that way does.
    func racingKeepClear(_ b: SeatView.OwnBoat, _ view: SeatView, from other: SeatView.OtherBoat, rule: RacingRule,
                         desired: Double, lookahead: Double) -> Double {
        // Her tack's side of the wind: a heading is the wind's direction plus `side` times her sailing angle.
        let side: Double = b.tack == .port ? 1 : -1
        let bearAway: Double
        switch rule {
        case .whileTacking:
            return finishingTack(b, view)
        case .portStarboard:
            bearAway = 1
        case .windwardLeeward:
            bearAway = -1
        default:
            // To port (−) from a boat to starboard, else to starboard: in sailing angle, her tack's way.
            let turn: Double = (other.position - b.position).dot(b.forward.rightPerp) > 0 ? -1 : 1
            bearAway = turn * side
        }
        // The windward boat looks to luff first even turned down towards the leeward one already: bearing away
        // from alongside her, she speeds up as she turns and doesn't drop astern in time (#263's momentum).
        return clearingHeading(b, view, desired: desired, lookahead: lookahead, first: bearAway,
                               keepsFirst: rule == .windwardLeeward)
    }

    /// The heading on her own tack nearest `desired` that passes every boat near her at least `keepClearDistance`
    /// times `keepClearMargin` hull lengths off over `lookahead` seconds (`closestApproach`), looking `first` way (+1
    /// bearing away, −1 luffing), or unless `keepsFirst` the way she has already turned off `desired`, and then the
    /// other; failing that, the one that passes furthest off. Only sailing angles `steer` sails: out of the no-go zone,
    /// never by the lee.
    func clearingHeading(_ b: SeatView.OwnBoat, _ view: SeatView, desired: Double, lookahead: Double,
                         first: Double, keepsFirst: Bool = false) -> Double {
        let near = view.others.filter { !$0.isGhost && ($0.position - b.position).length < Self.keepClearRange }
        let side: Double = b.tack == .port ? 1 : -1
        let closest = BoatDynamics.noGoAngle(view.boatClass.polar) + deg2rad(5)
        let angles = closest...Double.pi
        let clear = view.boatClass.hull.length * Self.keepClearDistance * Self.keepClearMargin
        let start = abs(wrapAngle(desired - b.windDirection)).clamped(to: angles)
        // Already turned off `desired` one way, she looks on that way first, so she doesn't swing from side to side.
        let turned = abs(wrapAngle(b.heading - b.windDirection)) - start
        let onHerTack = wrapAngle(b.heading - b.windDirection) * side >= 0
        let first: Double = !keepsFirst && abs(turned) > Self.clearingStep && onHerTack ? (turned > 0 ? 1 : -1) : first
        func distance(_ heading: Double) -> Double {
            near.map { Self.closestApproach(of: $0, to: b, heading: heading, lookahead: lookahead) }.min() ?? .infinity
        }
        var furthest: (heading: Double, distance: Double)?
        for way in [first, -first] {
            var angle = start + way * Self.clearingStep
            while angles.contains(angle) {
                let heading = b.windDirection + side * angle
                let passes = distance(heading)
                if passes >= clear { return heading }
                if passes > furthest?.distance ?? -1 { furthest = (heading, passes) }
                angle += way * Self.clearingStep
            }
        }
        return furthest?.heading ?? b.windDirection + side * start
    }

    // MARK: - Holding course

    /// `input`, or with the rudder centred for the autohelm to hold her course (#228), racing, when its rudder would
    /// turn her, the right-of-way boat, towards a boat that must keep clear of her (`turnsTowardsKeepClearBoat`): she
    /// changes course only as rule 16.1 lets her, giving that boat room to keep clear. Her ease stays as it was. What
    /// her autohelm does with a centred rudder, following a shift or snapping to the groove, isn't her course change.
    func holdingCourse(_ b: SeatView.OwnBoat, _ view: SeatView, _ input: BoatInput) -> BoatInput {
        guard b.status == .racing, input.rudder != 0,
              turnsTowardsKeepClearBoat(b, view, turn: input.rudder > 0 ? 1 : -1) else { return input }
        return BoatInput(rudder: 0 as Int8, ease: input.ease)
    }

    /// Whether turning her `turn` way (+1 to starboard) brings a boat that must keep clear of her (rules 10–13,
    /// `OtherBoat.rightOfWay`) closer to her than holding her course would, at a moment within `roomLookahead` seconds
    /// when that boat is inside `roomDistance` hull lengths of her: any of `roomTurns` that way, both boats sailing on
    /// in straight lines in the same water, weighed every `roomStep` seconds.
    func turnsTowardsKeepClearBoat(_ b: SeatView.OwnBoat, _ view: SeatView, turn: Double) -> Bool {
        let clear = view.boatClass.hull.length * Self.roomDistance
        let lookahead = roomLookahead
        let moments = Array(stride(from: Self.roomStep, through: lookahead, by: Self.roomStep))
        let headings = Self.roomTurns.map { Vec2.heading(b.heading + turn * $0) * b.speed }
        let holding = b.velocity
        for other in view.others where !other.isGhost && other.rightOfWay?.keepClear == other.seat {
            let offset = other.position - b.position
            guard offset.length < clear + (b.speed + other.speed) * lookahead else { continue }
            for t in moments {
                let held = (offset + (other.velocity - holding) * t).length
                for velocity in headings {
                    let turned = (offset + (other.velocity - velocity) * t).length
                    if turned < clear && turned < held { return true }
                }
            }
        }
        return false
    }

    // MARK: - Tacking clear

    /// Whether a tack or gybe now leaves her clear of every boat, racing (rules 13 and 15): sailing her wind angle on
    /// the other tack at `tapSpeedShare` of her speed for `tapLookahead` seconds (`tapOntoPortLookahead` for a boat on
    /// starboard when she goes onto port), no boat within `tapRange` comes inside `tapClearance` hull lengths of her.
    /// Before her start her taps are #99's.
    ///
    /// "Tacks away from a boat alongside" (#263): a boat already inside the clearance, overlapped with her, is clear of
    /// a tack that only opens the gap between them. Two boats sailing side by side off the start would otherwise each
    /// wait on the other to tack, and sail on together into the race area's edge; the one whose tack takes her away
    /// tacks.
    func tapIsClear(_ b: SeatView.OwnBoat, _ view: SeatView) -> Bool {
        guard b.status == .racing else { return true }
        let heading = 2 * b.windDirection - b.heading
        let speed = b.speed * Self.tapSpeedShare
        let clear = view.boatClass.hull.length * Self.tapClearance
        let ontoPort = b.tack == .starboard
        return view.others.allSatisfy { other in
            let gap = (other.position - b.position).length
            guard !other.isGhost, gap <= Self.tapRange else { return true }
            let lookahead = ontoPort && other.tack == .starboard ? Self.tapOntoPortLookahead : Self.tapLookahead
            let approach = Self.closestApproach(of: other, to: b, heading: heading, speed: speed, lookahead: lookahead)
            return approach >= min(clear, gap)
        }
    }
}
