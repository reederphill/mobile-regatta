import RegattaCore

// A bot's conduct under the rules once racing (#101, #19: "bots hold their rights as a human would: they hold course
// as the right-of-way boat, defend a lane, and luff within rule 16's room"; "they never hunt other boats to force
// fouls, and never protest"). What she sees of the rules is her seat's (`SeatView`): who keeps clear of whom under
// rules 10–13, or rule 21 for another boat taking a penalty or returning (`OtherBoat.rightOfWay`, `Race.rightsOfWay(of:)`),
// and the mark-room notices told her (`OwnBoat.markRoom`). Never the umpire's
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
//   has right of way. A turn her autohelm makes following a shift isn't hers. The one exception (#537): a boat that
//   must keep clear and clearly isn't (stopped, or sailing straight on into her, `notKeepingClear`), with contact inside
//   the escape horizon, she turns away from, the least turn, never towards any boat (`avoidingContact`,
//   `BotBrain+AvoidContact.swift`), and she tacks or gybes only once clear of her (`tapMeetsBoatNotKeepingClear`).
// - She taps a tack or gybe only clear of every boat (`tapIsClear`), racing and before her start (#280): a boat
//   tacking keeps clear (rule 13), and one that acquires right of way by it gives room (rule 15).
//   "Give a turning boat her circle" (#517): a boat taking a penalty is to that look a circle of water where she is,
//   which the tack's track and the sailing after it stay out of (`penaltyCircleRadius`), and a boat sailed on at her
//   velocity as every other: both.
// - Misjudging (#103, #19: "they foul only by misjudging"): meeting a boat she must keep clear of under a rule in
//   `BotWeaknesses.misjudgeScope`, she may misjudge the encounter, by her skill's `ruleMisjudgeRate`, drawn once an
//   encounter (`judgeEncounters`), racing and before her start (#280): she believes she holds her rights and sails on,
//   as she would were she the right-of-way boat, so fails to keep clear. A misjudgement only ever leaves out her
//   give-way manoeuvre: it never turns her towards a boat, and her hold-course under 16.1 is as ever. None from
//   National's band up.
// - Rule 17 (#346): held to her proper course, she sails within it by construction (`BotBrain+ProperCourse.swift`).
// - Ghosts have no rights or obligations: she ignores them. She never steers at a boat to force a foul, and never
//   protests: a `BotDecision` has no protest tap.
// - The bot suite's hunter (#355, `BotProfile.hunter`, `BotBrain+Hunter.swift`) does steer at a boat that must keep
//   clear of her, within rule 16.1's rate, in place of holding her course: a measuring profile, never a bot players race.
//
// Before her start (#99, #280) she keeps clear as `keepClear` has her (`BotBrain+Start.swift`): on port by the water
// (`startKeepClear`), on starboard as the rule has her, the windward boat luffing as far as just outside the no-go zone
// (`startLuff`) and easing to drop astern when that isn't enough; she taps only clear of every boat, misjudges as she
// does racing, and keeps clear of every boat 30° into a penalty turn (rule 21.2, `penaltyInput`). She doesn't hold her
// course as the right-of-way boat there: she steers her approach to the line (#280 measured holding course before the
// gun at on time 0.55 against the start gate's 0.60), but for turning away from a boat clearly not keeping clear of her,
// as racing (#537: a boat stopped below the line is the commonest).
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
    /// "Give a turning boat her circle" (#517): the radius of the water a boat taking a penalty is to her before a tack or
    /// gybe (`penaltyCircleRadius`), in diameters of a penalty turn. One: `OtherBoat` shows no rudder, so she can't see
    /// which way that boat turns, and a disc that far round her holds the circle on either side. Placeholder.
    static let penaltyCircleDiameters = 1.0
    /// Seconds she sails on at her speed on the new tack, after the tack or gybe itself (`tapLookahead`), that must stay
    /// out of that water too (`circleApproach`); the cautious bot's as every bot's. Placeholder.
    static let penaltyCircleAfter = 3.0
    /// "Turn away, not through" (#528): seconds of `penaltyStartMargin` she may spend past her penalty turn's latest
    /// start (`latestStartSeconds`) holding a way out of a boat crossing her turn's sweep (`PenaltyEscape`), before she
    /// turns on regardless. The rest of the margin is left for the turn itself: a missed-penalty disqualification costs
    /// more than a foul. Placeholder.
    static let penaltyLateDodgeSeconds = 3.0
    /// "Penalty turns in clear water" (#528): radians either side of her heading she looks for a heading on her own
    /// tack that clears her turn's sweep (`penaltyEscapeHeading`). Placeholder.
    static let penaltyEscapeSpread = deg2rad(60)
    /// Seconds ahead, at most, from where she scores a heading's sweep (`penaltyEscapeHeading`): where the heading puts
    /// her by then, no further than her time allows. Placeholder.
    static let penaltyEscapeHorizon = 6.0
    /// "Away from the pack, not to the edge" (#528 fix 5, the owner's ruling): hull lengths of water to the race area's
    /// edge within which, of two ways out that clear her alike, she takes the one with more (`penaltyEscapeEdgeWater`).
    /// Further in, the edge breaks no tie. Placeholder.
    static let penaltyEscapeEdgeLengths = 6.0
    /// Seconds of her latest start (`latestStartSeconds`) under which, called with her sweep blocked racing, she has
    /// nothing to move to clear water with: she starts at once, the best way, and dodges as she turns. Placeholder.
    static let penaltyMoveMinSeconds = 6.0
    /// "Start earlier, not later" (#528, the owner's figure): seconds of her latest start from which, sailing to
    /// clear water, she starts the turn with a thin margin (`penaltyThinStartMargin`) rather than blind at 0 s.
    /// Placeholder.
    static let penaltyThinStartSeconds = 10.0
    /// Seconds past her keep-clear lookahead the best way's first conflict must be for a thin-margin start
    /// (`penaltyThinStartSeconds`; owner 2026-10-15: tied to the lookahead, so it scales with her skill as the lookahead
    /// does): inside the lookahead she would dodge the moment she started. Placeholder.
    static let penaltyThinStartMargin = 1.5
    /// Seconds past her keep-clear lookahead her turn's first conflict must be before she lets a held way out go
    /// (`PenaltyEscape`) and turns on: she dodges inside the lookahead, so letting go at it would flick her back. At
    /// 1.5 s the held dodge spent her time: the live all-National cell's own-turn calls were 84, at 0.5 s 78.
    /// Placeholder.
    static let penaltyEscapeRelease = 0.5
    /// Radians between the headings she tries for the least turn that keeps her clear (`clearingHeading`).
    static let clearingStep = deg2rad(5)

    // MARK: - Misjudging

    /// Draws her judgement of each boat she meets racing, or before her start (#280), that she must keep clear of under
    /// a rule in `BotWeaknesses.misjudgeScope` (#103): once an encounter, the first decision she owes that boat
    /// keep-clear within `keepClearRange`, kept until that boat is beyond it again, so she doesn't swing between
    /// judgements through one encounter. From her own stream (`rng`), and only if she can misjudge at all, so a bot
    /// that misjudges nothing draws nothing. OCS she keeps clear of every boat as a returning one (rule 21.1), finished
    /// she sails no more: she judges nothing then.
    mutating func judgeEncounters(_ b: SeatView.OwnBoat, _ view: SeatView) {
        guard b.status == .racing || b.status == .prestart, weaknesses.ruleMisjudgeRate > 0 else {
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
    /// (`OtherBoat.rightOfWay`; never rule 21, which names `other` when it names either), else `.givingMarkRoom` when a mark-room notice has her owe `other` room (rule 18,
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
        let clear = view.boatClass.hull.length * keepClearLengths * Self.keepClearMargin
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
        // The cautious bot holds her course so before her start too (#104).
        guard b.status == .racing || (caution != nil && b.status == .prestart), input.rudder != 0,
              turnsTowardsKeepClearBoat(b, view, turn: input.rudder > 0 ? 1 : -1) else { return input }
        return BoatInput(rudder: 0 as Int8, ease: input.ease)
    }

    /// "Steady helm standing on" (#455, the owner's Q6 of 2026-10-20): whether she stands on, racing, as she holds her
    /// course (`holdingCourse`), the right-of-way boat with a boat that must
    /// keep clear of her (rules 10–13, or 21: `OtherBoat.rightOfWay`), not a ghost, near enough to come inside
    /// `roomLengths` of her within `roomLookahead` (`turns(towards:)`'s reach); or clear astern of one, whose overlap,
    /// made to leeward, gives her right of way on the tick it begins, mid-correction. Her hand then turns her no faster
    /// than `Hunter.rateShare` of rule 16.1's course-change rate (`BotDecision.standsOn`, `BotHelm.steady`), and so do a
    /// mark, the edge and an overtaking lane turning her towards a boat keeping clear of her (`sail`): following a shift
    /// she comes round a little late rather than snapping to her groove, as a helm standing on does, and never surprises
    /// the boat keeping clear of her. A turn her brain puts the rudder over for to keep clear herself, tack, gybe or take
    /// a penalty is not steadied; her hand holding the angle her brain leaves her is, whatever that turn was. Not before
    /// her start, where the cautious bot holds her course too: steadied there, she drew calls in the pre-start crowd
    /// (`CautiousBotSuiteTests`, seeds 1 and 14). Not a slowdown or a give-way: she sails her angle, only steadier.
    /// Internal.
    func standsOn(_ b: SeatView.OwnBoat, _ view: SeatView) -> Bool {
        guard b.status == .racing else { return false }
        let clear = view.boatClass.hull.length * roomLengths
        return view.others.contains { other in
            guard !other.isGhost, let right = other.rightOfWay,
                  right.keepClear == other.seat || right.rule == .clearAstern else { return false }
            return (other.position - b.position).length < clear + (b.speed + other.speed) * roomLookahead
        }
    }

    /// Whether turning her `turn` way (+1 to starboard) brings a boat that must keep clear of her (rules 10–13, or 21
    /// for a boat taking a penalty or returning: `OtherBoat.rightOfWay`) closer to her than holding her course would, at a moment within `roomLookahead` seconds
    /// when that boat is inside `roomDistance` hull lengths of her: any of `roomTurns` that way, both boats sailing on
    /// in straight lines in the same water, weighed every `roomStep` seconds.
    func turnsTowardsKeepClearBoat(_ b: SeatView.OwnBoat, _ view: SeatView, turn: Double) -> Bool {
        view.others.contains { other in
            !other.isGhost && other.rightOfWay?.keepClear == other.seat && turns(towards: other, b, view, turn: turn)
        }
    }

    /// Whether turning her `turn` way (+1 to starboard) by any of `turns` radians, at her speed, brings `other`, sailing
    /// on at its velocity, closer to her than holding her course would, at a moment within `lookahead` seconds
    /// (`roomLookahead` if nil) when it is inside `roomLengths` hull lengths of her, weighed every `roomStep` seconds:
    /// `turnsTowardsKeepClearBoat`'s reckoning for one boat, and the look before a tack by hand's
    /// (`handTurnsAtKeepClearBoat`, #455).
    func turns(towards other: SeatView.OtherBoat, _ b: SeatView.OwnBoat, _ view: SeatView, turn: Double,
               turns: [Double] = Self.roomTurns, lookahead: Double? = nil) -> Bool {
        let clear = view.boatClass.hull.length * roomLengths
        let lookahead = lookahead ?? roomLookahead
        let offset = other.position - b.position
        guard offset.length < clear + (b.speed + other.speed) * lookahead else { return false }
        let headings = turns.map { Vec2.heading(b.heading + turn * $0) * b.speed }
        let holding = b.velocity
        for t in stride(from: Self.roomStep, through: lookahead, by: Self.roomStep) {
            let held = (offset + (other.velocity - holding) * t).length
            for velocity in headings {
                let turned = (offset + (other.velocity - velocity) * t).length
                if turned < clear && turned < held { return true }
            }
        }
        return false
    }

    // MARK: - Tacking clear

    /// Whether a tack or gybe now leaves her clear of every boat, racing or before her start (rules 13 and 15, #280):
    /// sailing her wind angle on the other tack at `tapSpeedShare` of her speed for `tapLookahead` seconds
    /// (`tapOntoPortLookahead` for a boat on starboard when she goes onto port), no boat within `tapRange` comes inside
    /// `tapClearance` hull lengths of her. Held off a tap before her start, she sails her own tack's groove meanwhile
    /// (`sail`). OCS, her return is #99's: she runs back on her own tack, short of a gybe.
    ///
    /// "Tacks away from a boat alongside" (#263): a boat already inside the clearance, overlapped with her, is clear of
    /// a tack that only opens the gap between them. Two boats sailing side by side off the start would otherwise each
    /// wait on the other to tack, and sail on together into the race area's edge; the one whose tack takes her away
    /// tacks.
    ///
    /// "Give a turning boat her circle" (#517): a boat taking a penalty (rule 21.2) isn't only a boat sailed on at her
    /// velocity. She is slow and circling, and can't get out of the way of a tack into her turn; the rules gave the
    /// tacker right of way through it and called the turning boat (the owner's incident of 2026-10-13). She is a circle
    /// of water where she is now (`penaltyCircleRadius`), which the tack's track and the sailing after it stay out of
    /// (`circleApproach`), and a boat sailed on at her velocity as well, weighed as every other boat is with the
    /// lookahead any boat has: between her tack and her gybe she is reaching, not circling in place. A tap near her
    /// passes both. Her circle is looked for as far off as `tapRange` and its radius and the clearance: off the wind the
    /// track reaches a circle whose boat is beyond `tapRange` (4.5 s of her speed: a skiff running at 7 m/s sails 32 m,
    /// to a circle 8 m round a boat 46 m off).
    /// Held off it, she sails on as for any tap refused (`sail`), and tacks once her track clears the circle, read anew
    /// where that boat is at every decision: no slowing, no easing, no keeping station ("no orderly bots"). Not a
    /// returning boat (rule 21.1), who sails a course: she is weighed as every other boat. Internal: nothing shows it.
    ///
    /// The cautious bot looks for it as well sailing the tap through in her mind (`tapTrack`), every boat going on turning
    /// as she saw it turn (`tapApproach`).
    func tapIsClear(_ b: SeatView.OwnBoat, _ view: SeatView) -> Bool {
        guard b.status == .racing || b.status == .prestart else { return true }
        let heading = 2 * b.windDirection - b.heading
        let speed = b.speed * Self.tapSpeedShare
        let clear = view.boatClass.hull.length * tapClearanceLengths
        let ontoPort = b.tack == .starboard
        // Her track through the tap, sailed in her mind only once a boat is near enough to matter (the cautious bot's).
        var track: [Vec2]?
        return view.others.allSatisfy { other in
            let gap = (other.position - b.position).length
            guard !other.isGhost else { return true }
            // Her circle, from as far off as her track reaches it; then the boat she is, as every other.
            if let radius = penaltyCircleRadius(of: other, b, view), gap <= Self.tapRange + radius + clear {
                guard circleApproach(to: other, b, heading: heading) >= min(radius + clear, gap) else { return false }
            }
            guard gap <= Self.tapRange else { return true }
            let lookahead = (ontoPort && other.tack == .starboard ? Self.tapOntoPortLookahead : Self.tapLookahead) * tapLookaheadScale
            let approach = Self.closestApproach(of: other, to: b, heading: heading, speed: speed, lookahead: lookahead)
            guard approach >= min(clear, gap) else { return false }
            // A live bot racing on the shared scorer (#531, racing only: Q6) looks along the tack she will sail too,
            // `other` rolled as the scorer rolls her against a tack (`tackReaction`: rule 13, nobody gives way to her).
            // Not a gybe: refused near a mark of a run, the closest course to it (`refusedTurnAim`) turned her at a
            // boat that tacked a tick later (`rightOfWayBotNeverRuddersTowardAKeepClearBoat`, skill 0.7, seed 20).
            if caution == nil {
                guard usesKeepClearScorer(b), abs(sailingAngle(b)) < .pi / 2 else { return true }
                let sailed = track ?? tapTrack(b, view, seconds: Self.tapOntoPortLookahead * tapLookaheadScale)
                track = sailed
                let steps = min(sailed.count, Int((lookahead / Self.keepClearPredictionStep).rounded()))
                let theirs = predictedTrack(of: other, tackReaction(of: other, b, view), view, steps: steps)
                let closest = zip(sailed, theirs).map { ($1 - $0).length }.min() ?? gap
                return closest >= min(clear, gap)
            }
            let sailed = track ?? tapTrack(b, view, seconds: Self.tapOntoPortLookahead * tapLookaheadScale)
            track = sailed
            return tapApproach(of: other, track: sailed, lookahead: lookahead, view) >= min(clear, gap)
        }
    }

    /// "Give a turning boat her circle" (#517): the radius, metres, of the water `other` is to her before a tack or gybe
    /// (`tapIsClear`), or nil unless `other` is taking a penalty and keeps clear of her for it (rule 21.2,
    /// `OtherBoat.rightOfWay`; not a returning boat, rule 21.1). `penaltyCircleDiameters` diameters of a penalty turn:
    /// its circle at the rate `penaltyRudder` turns a boat of the class at `HandTackTable.penaltyTurn.speed` of
    /// close-hauled speed in the wind she has (`turnSweep`'s reckoning of her own turn, its `reach` without the
    /// clearance), centred on that boat, who never leaves her circle.
    func penaltyCircleRadius(of other: SeatView.OtherBoat, _ b: SeatView.OwnBoat, _ view: SeatView) -> Double? {
        guard let right = other.rightOfWay, right.keepClear == other.seat, right.rule == .takingAPenalty else { return nil }
        let speed = closeHauledSpeed(b, view) * HandTackTable.penaltyTurn.speed
        let rate = Self.penaltyRudder(view) * view.boatClass.steering.turnRate(speed: speed)
        guard rate > 0 else { return nil }
        return Self.penaltyCircleDiameters * 2 * speed / rate
    }

    /// The closest her track through a tack or gybe onto `heading`, and the sailing after it, comes to where `other` is
    /// now, metres between centres: the tap's line (`tapSpeedShare` of her speed for `tapLookahead` seconds, the
    /// cautious bot's further), then on at her speed for `penaltyCircleAfter` seconds. `other` doesn't move: a boat
    /// taking a penalty, turning her circle (`tapIsClear`, which weighs her sailed on at her velocity besides).
    func circleApproach(to other: SeatView.OtherBoat, _ b: SeatView.OwnBoat, heading: Double) -> Double {
        let sailed = b.speed * (Self.tapSpeedShare * Self.tapLookahead * tapLookaheadScale + Self.penaltyCircleAfter)
        return Self.closestApproach(offset: other.position - b.position, relativeVelocity: -Vec2.heading(heading),
                                    lookahead: sailed)
    }
}

extension RacingRule {
    /// Rule 21: a boat returning to start or taking a penalty keeps clear (`Race.rightsOfWay(of:)`, #337).
    var isRule21: Bool { self == .returningToStart || self == .takingAPenalty }
}
