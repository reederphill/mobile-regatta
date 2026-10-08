import RegattaCore

/// A bot's hidden, seeded style (#19, #102): where on the line she starts, which side of the course she favours,
/// how much risk she takes at the start, how willing she is to tack and how she engages the boats around her, and
/// the skill she sails at. No named personalities: every field is its own draw. The style is drawn from the bot's own
/// seed (`BotDriver.seed`), never from the race's streams, so changing a style never moves placement or wind; the
/// skill is an input (a tier's band, or a rating), never drawn here. Tuning it needs no simulation version bump:
/// the race log holds the inputs a bot applied, and replays never run brains (ADR 0002).
public struct BotStyle: Hashable, Sendable {
    /// 0…1: what her weaknesses are (`BotWeaknesses(skill:)`). A tier's band (`BotTier`) or a rating sets it.
    public var skill: Double
    /// Her line end: where on the line to start, 0 = pin, 1 = committee boat.
    public var startSpot: Double
    /// Where on the line to finish, 0 = pin, 1 = committee boat.
    public var finishSpot: Double
    /// Her start risk: seconds she adds to her time at the line, as far as her start timing error shows it
    /// (`BotWeaknesses.startTiming`, `BotBrain.startArrival`): negative makes her earlier, though she never means to
    /// be over at the gun.
    public var timingSlack: Double
    /// Hard over to this side (−1 port, 1 starboard) for penalty turns in open water; near a mark she turns
    /// away from it (#89).
    public var penaltyDirection: Double
    /// The side of the course she favours, −1 the left (looking upwind) … 1 the right: she sails her beats' and
    /// runs' corridor (`Tactics.corridor`) shifted that way by up to half its width.
    public var favouredSide: Double
    /// How willing she is to tack, 0…1: the willing tack on smaller shifts, sooner after the last tack.
    public var tackWillingness: Double
    /// How she engages the boats around her, 0 sailing her own race … 1 combative (#223): the one value every fleet
    /// tactic reads (#234, `Tactics.engagement`): whether she covers, holds her lane, lee-bows or tacks on a boat's wind,
    /// and how far off a boat she covers. Independent of her skill, which sets how well she plays them.
    public var engagement: Double
    /// −1…1: which way, and how far, she misreads the start line's bias (`BotWeaknesses.lineBiasMisread`).
    public var lineBiasDraw: Double

    public init(skill: Double, startSpot: Double, finishSpot: Double, timingSlack: Double, penaltyDirection: Double,
                favouredSide: Double = 0, tackWillingness: Double = 0.5, engagement: Double = 0.5, lineBiasDraw: Double = 0) {
        self.skill = skill
        self.startSpot = startSpot
        self.finishSpot = finishSpot
        self.timingSlack = timingSlack
        self.penaltyDirection = penaltyDirection
        self.favouredSide = favouredSide
        self.tackWillingness = tackWillingness
        self.engagement = engagement
        self.lineBiasDraw = lineBiasDraw
    }

    /// A style drawn from `rng` (the bot's own seed), sailing at `skill`.
    public init(skill: Double, rng: inout SplitMix64) {
        self.skill = skill
        // The draws before #102 keep their places, so a seed's line end, finish spot, start risk and penalty turn
        // are what they were: the skill the prototype drew here (now the tier's draw, `BotTier.skillDraw`) and its
        // hold depth are consumed, not used.
        _ = rng.unit()
        startSpot = rng.range(0.1, 0.9)
        finishSpot = rng.range(0.6, 0.85)
        _ = rng.range(18, 35)
        timingSlack = rng.range(-2.5, 5)
        penaltyDirection = rng.bool() ? 1 : -1
        favouredSide = rng.range(-1, 1)
        tackWillingness = rng.unit()
        engagement = rng.unit()
        lineBiasDraw = rng.range(-1, 1)
    }
}

/// One bot decision: exactly what a human could send (#19), a held input and at most one tap.
public struct BotDecision: Hashable, Sendable {
    public var input: BoatInput
    public var tap: BoatTap?
    /// What the suite's hunter's hunting made of `input` (#355, `BotBrain.hunting`); nil for every other bot, and for
    /// her when she sailed as a live bot does.
    var hunt: BotBrain.HuntStep? = nil
    /// The fleet tactic her tap plays (#234, #337: counted by the suite by engagement band); nil for any other tap.
    var play: BotBrain.FleetPlay.Kind? = nil
    /// Whether `input` is a combative bot's luff at a windward boat before her start (#337, `startLuffing`).
    var startLuff = false

    public init(input: BoatInput, tap: BoatTap? = nil) {
        self.input = input
        self.tap = tap
    }
}

/// Helms a computer-controlled boat on the autohelm (ADR 0007, #231): pre-start timing, beating and running
/// between laylines, playing shifts, mark roundings, penalty turns (keeping clear of every boat as she turns
/// them, rule 21.2), her conduct under the rules (#101, `BotBrain+Conduct.swift`: keeping clear when it is the
/// give-way boat, holding her course when it is the right-of-way boat), and keeping off the race area's edge (#82).
///
/// It sails the way a player does. Each decision it picks an `Aim`, a wind angle on a tack (the groove,
/// the groove with a pinch or foot, or a course to a mark as the wind angle it needs), steers to it and
/// centres the rudder, and the autohelm holds it: no heading tracking between decisions. It takes the
/// rudder back only when the aim changes, or the angle held has drifted past the aim's tolerance. Tacks
/// and gybes are the tap's, never the rudder's. Keeping clear and staying off a mark or the race area's
/// edge are steered with the rudder while they last; then she centres on her aim again.
///
/// It sees the race only through its seat's `SeatView` (#98): what a player in that seat sees now, never
/// the race itself, a key or another boat's input (#19). It answers with a `BotDecision`, an int8 rudder
/// plus the tack/gybe tap, exactly what a player can send. What it plays beyond the groove (`Tactics`) is a
/// live bot's, set by its skill, or a bot-suite profile's (`BotProfile`); the bot phase (#99–#104, #234)
/// grows it, gaining behaviour but never information: `BotSourceTests` keeps the race out of every
/// `BotBrain*.swift` file.
struct BotBrain: Sendable {
    let style: BotStyle
    /// What she plays beyond sailing the groove to the marks. Set once, at her making; a `var` only so the scripted
    /// encounter tests can sail a live bot without #366's National ramp (`BotConductTests.Pilot`).
    var tactics: Tactics
    var plannedTack: Tack = .starboard
    /// The tactician's spot on the start line as she reads its bias (#105, `Tactics.startsAtFavouredEnd`, `readLineBias`),
    /// 0 the pin … 1 the committee boat; nil until she has read it, or for any other bot.
    var favouredEndSpot: Double?
    var lastTackTime = -1_000.0
    /// The fleet tactic (#234) that last turned her plan to the other tack (`upwindTack`), and when: her tap then is
    /// that play's (`BotDecision.play`, for the suite's count, #337).
    var lastFleetPlay: FleetPlay.Kind?
    var lastFleetPlayTime = -Double.infinity
    /// When she last tapped: she lets a tap finish before another.
    var lastTapTime = -1_000.0
    /// The rudder she holds hard over through her penalty turns, one way, from when she starts them until
    /// she owes none (`penaltyInput`); nil while she isn't turning one.
    var penaltyTurn: Double?
    /// She gave a penalty turn up to keep clear (rule 21.2, `penaltyInput`) and turns it the other way, since she
    /// last owed none.
    var penaltyGivenUp = false
    /// Radians into her current penalty turn when she last looked (`OwedPenalty.progress`): a drop means she has
    /// just served one and the next is starting (`penaltyInput`).
    var penaltyProgress = 0.0
    /// When she began leaving her current penalty turn to the autohelm, its rudder still over the other way
    /// (`turningOn`); nil while she isn't.
    var penaltyHeldSince: Double?
    /// What she has made of her own wind and speed so far (`observe`).
    var senses = Senses()
    /// What her skill costs her (#102): a live bot's, from her skill; a bot-suite profile's, none.
    let weaknesses: BotWeaknesses
    /// Her own draws as she sails (#102): her misjudged laylines and groove choices. From her own seed, on a stream
    /// of its own, never the race's.
    var rng: SplitMix64
    /// Her layline misjudgement for the leg she's on (`BotWeaknesses.laylineMisjudge`): the leg, and radians past
    /// the layline she tacks or gybes onto it (negative: short of it).
    var laylineError: (leg: Int, error: Double)?
    /// Her groove choice (`BotWeaknesses.angleMissRate`): radians off the groove she sails, past its snap (0: in
    /// it), until the race clock reaches `until`.
    var grooveMiss = (offset: 0.0, until: -Double.infinity)
    /// Her judgement of each boat she has met, racing or before her start (#280), and must keep clear of under a rule in
    /// `BotWeaknesses.misjudgeScope` (#103, `judgeEncounters`), by its seat:
    /// true if she misjudges that encounter and believes she holds her rights. Kept while that boat is within
    /// `keepClearRange` of her.
    var misjudged: [Int: Bool] = [:]
    /// How she will roll the tack she has tapped (#263, `planRoll`), and when she tapped it; nil with no roll to send.
    var rollPlan: (plan: RollPlan, tapped: Double)?
    /// What she has made of the boats around her (#234, `observeFleet`): each one's tack, when she saw it tack, and
    /// her timing error on it.
    var fleet = FleetSense()
    /// Her draws for the fleet tactics (#234): her timing errors. A stream of her seed of its own, so they never move
    /// the draws `rng` makes.
    var tacticsRng: SplitMix64
    /// What makes her cautious, if she is the cautious bot (#104, `BotBrain+Cautious.swift`); nil for every other bot.
    let caution: Caution?
    /// She is taking the seat over and hasn't decided yet (#104): her first decision rebuilds her plan from what the
    /// seat sees (`adopt`).
    var takingOver = false
    /// A penalty turn she took over part-turned with the rudder centred, whose way she is reading (`readPenaltyTurn`).
    var penaltyRead: PenaltyRead?
    /// The boats around her as she saw them at her last decision, by seat (`guarded`): the cautious bot's only.
    var seen: [Seen?] = []
    /// Whether she holds her aim within her proper course while told she is restricted under rule 17
    /// (`properCourseLimited`, #346). A test seam: always true in play; only tests that compare her steering with the
    /// limit left out set it false.
    var limitsProperCourse = true

    /// The stream of her seed her own draws come from.
    static let brainStream: UInt64 = 0x6272_6169_6e64_7277 // "braindrw"
    /// The stream of her seed her fleet tactics' draws come from (#234).
    static let tacticsStream: UInt64 = 0x7461_6374_6963_7321 // "tactics!"

    init(style: BotStyle, profile: BotProfile? = nil, seed: UInt64 = 0, weaknesses: BotWeaknesses? = nil,
         caution: Caution? = nil) {
        self.style = style
        self.caution = caution
        self.weaknesses = weaknesses ?? profile?.weaknesses(skill: style.skill) ?? BotWeaknesses(skill: style.skill)
        tactics = Tactics(profile: profile, skill: style.skill, style: style, weaknesses: self.weaknesses)
        // #337: the cautious bot plays no fleet tactic (her engagement is 0) and fights for no spot: today's values.
        if caution != nil {
            tactics.tacticEngagement = nil
            tactics.startEngagement = nil
        }
        rng = SplitMix64(seed: seed, stream: Self.brainStream)
        tacticsRng = SplitMix64(seed: seed, stream: Self.tacticsStream)
    }

    private var skill: Double { style.skill }
    private var finishSpot: Double { style.finishSpot }

    /// The decision for `view`'s seat now: what she sails, with her roll tap if this is its moment (`rollsNow`).
    ///
    /// "Sheets in through the eye": turning through the no-go zone she never eases, whatever she was holding
    /// with before (#231, #263): the sails can't draw there, and eased she comes out of the tack slower still.
    mutating func decide(_ view: SeatView) -> BotDecision {
        var decision = sail(view)
        if decision.tap == nil, rollsNow(view.own, view) { decision.tap = .tackGybe }
        // The cautious bot looks before she leaps (#104), and notes the boats around her for her next look.
        if caution != nil {
            if decision.tap == nil, let input = guarded(view, decision.input) { decision.input = input }
            see(view)
        }
        if decision.input.ease, view.own.twa < BoatDynamics.noGoAngle(view.boatClass.polar) {
            decision.input = decision.input.eased(false)
        }
        return decision
    }

    /// What she sails now: her held input, and her tack or gybe tap.
    private mutating func sail(_ view: SeatView) -> BotDecision {
        let boat = view.own
        observe(boat, view)
        if takingOver {
            takingOver = false
            adopt(view)
        }
        guard boat.isOnCourse else { return BotDecision(input: .neutral) }
        judgeEncounters(boat, view)
        if let input = penaltyInput(boat, view) { return BotDecision(input: input) }
        var aim = plan(boat, view)
        // Tacked before her start, she bears away to close-hauled before she holds any closer to the wind: until
        // she's there, rule 13 has her keep clear of every boat (#99).
        let closeHauled = Self.closeHauled(boat.polarWindSpeed, view) + deg2rad(2)
        let starting = boat.status == .prestart || boat.status == .ocs
        if starting, senses.tacking, aim.tack == boat.tack, aim.groove == nil, aim.angle < closeHauled {
            aim = Aim(angle: closeHauled, tack: aim.tack, ease: aim.ease)
        }
        // The cautious bot does so racing too: held below close-hauled, in a groove she misses or a pinch, she would
        // stay tacking under rule 13 for as long, keeping clear of every boat (#104).
        if caution != nil, senses.tacking, aim.tack == boat.tack, aim.angle < closeHauled {
            aim = Aim(angle: closeHauled, tack: aim.tack, ease: aim.ease)
        }
        // Held to her proper course under rule 17, she sails no higher than it allows (#346).
        if limitsProperCourse { aim = Self.properCourseLimited(aim, boat) }
        // The autohelm is sailing the tap through the tack or gybe: hands off. Any rudder would cancel it
        // (#13) and leave her head to wind; it's over in a couple of seconds.
        if boat.autohelm?.isTapping == true { return BotDecision(input: .neutral) }
        let desired = aim.tack == boat.tack ? aim.heading(wind: boat.windDirection) : boat.heading
        if let evasion = evasion(boat, view, desired: desired) {
            let ease = aim.ease && aim.tack == boat.tack || evasion.dropsAstern
                || easesKeepingClear(boat, view, heading: evasion.heading)
            let input = steer(boat, toHeading: evasion.heading, view, closest: evasion.closest)
            return BotDecision(input: clearingQuarter(boat, view, input.eased(ease)))
        }
        if aim.tack != boat.tack {
            if canTap(boat, view) {
                lastTapTime = view.time
                planRoll(boat, view)
                var decision = BotDecision(input: .neutral, tap: .tackGybe)
                if lastFleetPlayTime == view.time { decision.play = lastFleetPlay }
                return decision
            }
            // Not yet (too slow to tack, or a mark too close to turn by): the same aim on her own tack. Before
            // her start (#99) she sails her own tack's groove sheeted in instead: the speed to tack, rather than
            // a gybe to leeward the race area below the line may not have room for; but running by an end of the
            // line, she runs on clear of its mark to gybe.
            // Off the wind, held off the gybe onto the other tack by boats near (with room for it to leeward), where
            // her groove would put her on the line well before the gun (`grooveIsOverEarly`), she holds her angle, or
            // bears away to the plan's if it is broader, with the plan's Ease, until the gybe is clear, rather than luff
            // to her groove (anywhere else she luffs to it as before): from a broad reach on port that drove her at the
            // line beside the committee boat with 19 s to go, over early, and running back swept her into it; luffing
            // again, across the starboard boats (#388, seed 1 of `aBotTakingOverBeforeTheGunStarts`).
            var own = aim
            own.tack = boat.tack
            if boat.status == .prestart || boat.status == .ocs {
                let running = sailingAngle(boat) >= .pi / 2
                let groove = Aim.groove(.upwind, tack: boat.tack, angle: grooveAngle(.upwind, boat, view))
                own = running && !isClearOfMarks(boat, view, lengths: Self.tapMarkClearance)
                    ? Aim(angle: max(sailingAngle(boat), Self.returnAngle), tack: boat.tack)
                    : running && (!tapIsClear(boat, view) || tapTurnsAtKeepClearBoat(boat, view))
                        && hasGybeRoom(boat, view) && grooveIsOverEarly(boat, view, groove)
                    ? Aim(angle: max(sailingAngle(boat), min(aim.angle, Self.returnAngle)), tack: boat.tack, ease: aim.ease)
                    : groove
            }
            return holding(boat, view, helm(boat, to: own, view), desired: own.heading(wind: boat.windDirection))
        }
        return holding(boat, view, helm(boat, to: aim, view).eased(aim.ease), desired: desired)
    }

    /// Her decision as the right-of-way boat, `input` her plan's helm: holding her course (`holdingCourse`, #228), or for
    /// the suite's hunter hunting (`hunting`, #355), then clearing her quarter. `desired` is the heading her plan sails.
    private func holding(_ b: SeatView.OwnBoat, _ view: SeatView, _ input: BoatInput, desired: Double) -> BotDecision {
        guard tactics.hunts else {
            // #337: a combative live bot luffs a windward boat before her start (`startLuffing`).
            let luffed = startLuffing(b, view, input, desired: desired)
            var decision = BotDecision(input: clearingQuarter(b, view, luffed ?? holdingCourse(b, view, input)))
            decision.startLuff = luffed != nil && decision.input == luffed
            return decision
        }
        let (held, step) = hunting(b, view, input, desired: desired)
        var decision = BotDecision(input: clearingQuarter(b, view, held))
        // What hunting did, unless clearing her quarter steered her otherwise.
        decision.hunt = decision.input == held ? step : nil
        return decision
    }

    // MARK: - Penalty turns

    /// Hull lengths of water between her and every mark she wants before starting a penalty turn: the turn
    /// sweeps a circle up to about three lengths across at speed, and she turns it away from the nearest
    /// mark. No allowance for current: a bot navigates the course by the wind alone, laylines included (#100).
    static let penaltyMarkClearance = 3.0
    /// Seconds before her current turn's start deadline by which she starts it wherever she is: time to
    /// turn the rules' 30° from a standstill, with room to spare.
    static let penaltyStartMargin = 6.0
    /// Seconds before her current turn's complete deadline after which she no longer gives it up to keep clear
    /// (#100, `canGiveUpTurn`): time for a whole 360 in a light breeze, with room to spare. A disqualification costs
    /// her the race where a foul costs her another turn.
    static let penaltyCompleteMargin = 15.0

    /// Her held input for her penalty turns (#9, #89), or nil while she has none to turn yet. She starts her
    /// current turn as soon as it is hers (`SeatView.OwnBoat.penalty`) in clear water. Two things hold her off, each
    /// only until `penaltyStartMargin` before the start deadline, when she starts wherever she is (`canPutOffTurn`):
    /// a mark closer than `penaltyMarkClearance` (she sails on, round it and away, and starts once clear), and
    /// another boat within `penaltyBoatClearance`: the crowd below the line before her start (#99), and racing, for a
    /// bot of `penaltyPutOffSkill` or more, the pack, except on the last leg, where she can't finish owing a turn, and where the put-off would end at a mark
    /// (`putOffEndsAtAMark`) (#351: turning at once in the pack, a
    /// penalised boat swept through it and was called 21.2 by boats that had nothing to do with her first foul). She
    /// turns away from the nearest mark, so the circle she sweeps opens away from it: a boat spinning beside a mark
    /// she had touched touched it again (and owed another turn) on every turn (#79); with none near, at
    /// `penaltyPutOffSkill` or more, away from the nearest boat still in her water.
    ///
    /// Once started she holds the rudder hard over that way until she owes none: through head to wind,
    /// where letting go would hand her to the autohelm and a turn the other way would give the turn up, and
    /// on into the next owed turn, which turning on serves. She never crosses the finish line owing one: she
    /// is turning it before she gets there.
    ///
    /// 30° into a turn (`OwedPenalty.isStarted`) she keeps clear of every boat (rule 21.2, #100; before her start too,
    /// #280: holding it hard over into the crowd there, one boat went from one turn owed to four in 2 s), whatever
    /// rules 10–13 would give her (`penaltyKeepClear`). With a boat about to hit her, turning on turns her away from
    /// it or sweeps her towards it. Away, she turns on. Towards, she gives the turn up and turns it again the other
    /// way at once, hard over away from the boat: once while she owes turns, in the turn's first half (past it,
    /// turning on clears her out of the way sooner than a whole turn the other way), while she has time to turn it
    /// all again (`canGiveUpTurn`), and not towards a mark near her. Otherwise she turns on whoever is near: she never
    /// eases or centres the rudder mid-turn to wait, since the autohelm taking her swings her heading back against
    /// the turn, and the tick she takes the helm again to turn on gives the turn up, perhaps too late to start it
    /// again. Before her start she starts one only in clear water, and putting it off there keeps clear of every boat
    /// until `penaltyPutOffKeepClearSeconds` before the gun.
    private mutating func penaltyInput(_ b: SeatView.OwnBoat, _ view: SeatView) -> BoatInput? {
        guard let owed = b.penalty else {
            penaltyTurn = nil
            penaltyGivenUp = false
            penaltyProgress = 0
            penaltyRead = nil
            penaltyHeldSince = nil
            return nil
        }
        if let reading = readPenaltyTurn(b, view, owed) { return reading }
        // Between one turn and the next she owes, with a mark close aboard: she stops turning and sails clear of it
        // before the next, as she would before her first (`startPenaltyTurn`). Turning on there sweeps the same
        // circle, and a circle that touched the mark touches it again, owing another turn each time round (#102).
        let servedOne = owed.progress < penaltyProgress - .pi
        penaltyProgress = owed.progress
        if servedOne, penaltyTurn != nil, let mark = nearestMark(b, view),
           mark.clearance < view.boatClass.hull.length * Self.penaltyMarkClearance, canPutOffTurn(owed, view) {
            penaltyTurn = nil
            penaltyGivenUp = false
        }
        let keepClear = owed.isStarted ? penaltyKeepClear(b, view) : nil
        guard let turn = penaltyTurn ?? startPenaltyTurn(b, view, owed) else {
            // Not turning it yet, but 30° into it all the same (a rounding counts towards it): she keeps clear. Before
            // her start, putting it off in the crowd while the gun is further off than `penaltyPutOffKeepClearSeconds`,
            // she keeps clear of every boat already (#280): any turn she sails there counts towards it, and 30° in, a
            // boat close aboard would have her foul again. Either way, before her start not over the line early.
            let puttingOff = b.status == .prestart && -view.time > Self.penaltyPutOffKeepClearSeconds
            guard let clear = keepClear ?? (puttingOff ? penaltyKeepClear(b, view) : nil),
                  !crossesEarly(b, view, heading: clear.heading) else { return nil }
            return steer(b, toHeading: clear.heading, view)
        }
        let markAway = nearestMark(b, view).map { Self.away(from: $0.offset, b) }
        guard let keepClear, keepClear.away != turn, (markAway ?? keepClear.away) == keepClear.away, !penaltyGivenUp,
              owed.progress < .pi, canGiveUpTurn(owed, view) else {
            return turningOn(b, turn, owed, view)
        }
        penaltyTurn = keepClear.away
        penaltyGivenUp = true
        penaltyHeldSince = nil
        return BoatInput(rudder: keepClear.away)
    }

    /// One tick of the race, seconds, from the rules' tick count for a second (the brain holds no race, #98).
    static let tickStep = 1 / Double(RulesConfig.ticks(1))

    /// Seconds at most she leaves a penalty turn to the autohelm, its rudder over the other way, before she turns it
    /// on her way regardless (`turningOn`): a few ticks' slew brings any rudder to centre, so a rudder still over after
    /// this has settled there, and waiting on would run the turn out of time (a missed-penalty disqualification).
    static let penaltyHoldSeconds = 0.5

    /// Her input turning her current penalty turn on `turn`'s way: the rudder hard over that way, unless the autohelm
    /// has her (she let go, or took the boat over from a player who had, #219) with its rudder still over the other
    /// way. The tick she takes the helm her rudder only slews part way back (the class's `rudderSlew`), so her heading
    /// goes on turning back that tick, driven by her: the race gives the turn up (`penaltyReset`, #350). She leaves the
    /// boat to the autohelm, which can never undo a turn, until one tick's slew brings the rudder to centre or her way;
    /// but never for more than `penaltyHoldSeconds` (`penaltyHeldSince`), and not past `penaltyStartMargin` before the
    /// start deadline of a turn not yet started.
    mutating func turningOn(_ b: SeatView.OwnBoat, _ turn: Double, _ owed: OwedPenalty, _ view: SeatView) -> BoatInput {
        guard let helm = b.autohelm, !helm.isTapping, owed.progress > 0,
              turn * b.rudder < -view.boatClass.steering.rudderSlew * Self.tickStep,
              owed.isStarted || canPutOffTurn(owed, view) else {
            penaltyHeldSince = nil
            return BoatInput(rudder: turn)
        }
        let since = penaltyHeldSince ?? view.time
        penaltyHeldSince = since
        return view.time - since < Self.penaltyHoldSeconds ? .neutral : BoatInput(rudder: turn)
    }

    /// The way she turns her current penalty turn, starting it now, or nil while she holds it off (`penaltyInput`).
    private mutating func startPenaltyTurn(_ b: SeatView.OwnBoat, _ view: SeatView, _ owed: OwedPenalty) -> Double? {
        let mark = nearestMark(b, view)
        let crowd = nearestCrowding(b, view)
        let readsThePack = skill >= Self.penaltyPutOffSkill
        let crowded = crowd != nil
            && (b.status != .racing || (readsThePack && !isOnLastLeg(b, view) && !putOffEndsAtAMark(b, view, owed)))
        if crowded || mark.map({ $0.clearance < view.boatClass.hull.length * Self.penaltyMarkClearance }) == true,
           canPutOffTurn(owed, view) {
            return nil
        }
        // Away from the nearest mark, if one is near, else from the nearest boat in her water (#351): turning to
        // starboard (+) circles to her right.
        let turn = mark.map { Self.away(from: $0.offset, b) }
            ?? crowd.flatMap { readsThePack ? Self.away(from: $0.position - b.position, b) : nil } ?? style.penaltyDirection
        penaltyTurn = turn
        return turn
    }

    /// Whether she may still put her current turn off, waiting to start it: until `penaltyStartMargin` before its
    /// start deadline.
    private func canPutOffTurn(_ owed: OwedPenalty, _ view: SeatView) -> Bool {
        owed.startDeadlineTick - view.tick > RulesConfig.ticks(Self.penaltyStartMargin)
    }

    /// Whether she may give her current turn up to keep clear (rule 21.2) and turn it all again: until
    /// `penaltyStartMargin` before its start deadline (`canPutOffTurn`) and `penaltyCompleteMargin` before its
    /// complete deadline.
    func canGiveUpTurn(_ owed: OwedPenalty, _ view: SeatView) -> Bool {
        canPutOffTurn(owed, view)
            && owed.completeDeadlineTick - view.tick > RulesConfig.ticks(Self.penaltyCompleteMargin)
    }

    /// The heading that keeps her clear of a boat about to hit her as she turns a penalty (rule 21.2, #100), and
    /// the way she turns for it, away from the boat (+1 to starboard), or nil with none in her way: any boat,
    /// whatever rules 10–13 would give her, on the course she is sailing now. She turns away from it as
    /// `ruleKeepClear` does, off any mark or the race area's edge that heading would sail her into
    /// (`evasiveHeading`'s refinements).
    private func penaltyKeepClear(_ b: SeatView.OwnBoat, _ view: SeatView) -> (heading: Double, away: Double)? {
        let lookahead = keepClearLookahead
        guard let other = view.others.first(where: {
            !$0.isGhost && isAboutToHit($0, b, view, desired: b.heading, lookahead: lookahead)
        }) else { return nil }
        let away = Self.away(from: other.position - b.position, b)
        let clear = sailable(b.heading + away * deg2rad(35), wind: b.windDirection)
        let heading = avoidMarks(b, view, desired: clear) ?? clear
        return (avoidEdges(b, view, desired: heading) ?? heading, away)
    }

    /// The way she turns away from something `offset` from her: to port (−1) from something to starboard, else to
    /// starboard (+1).
    private static func away(from offset: Vec2, _ b: SeatView.OwnBoat) -> Double {
        offset.dot(b.forward.rightPerp) > 0 ? -1 : 1
    }

    /// Seconds before the gun from which a boat putting her penalty turn off before her start no longer keeps clear
    /// of every boat meanwhile (`penaltyInput`, #280): later she is lining up for the line. #280 measured keeping
    /// clear to the gun at on time 0.645 against 0.665 on the start population, and 0.53 against 0.61 on the acceptance
    /// run, against the start gate's 0.60.
    static let penaltyPutOffKeepClearSeconds = 30.0

    /// Hull lengths of water around her she waits for before a penalty turn: before her start (#99), the crowd
    /// below the line holds, waits and crosses on every course; racing (not on the last leg, #351), the pack; and a
    /// boat turning a penalty keeps clear of all of it (rule 21.2).
    static let penaltyBoatClearance = 2.5

    /// The least skill (National's band) at which she reads the pack around her penalty turn (#351): racing she puts it
    /// off in company (`penaltyInput`), and in company she turns away from the nearest boat. Below it she turns as soon
    /// as it is hers, her own way, as before #351: put off by Club and Regional bots, the mixed fleet's finish share
    /// fell (0.903 to 0.894 over 12 seeds) and the Club fleet around the cautious bot caught her as the offender in 3
    /// of `CautiousBotSuiteTests`' 100 races.
    static let penaltyPutOffSkill = 0.8

    /// The nearest other boat within `penaltyBoatClearance` hull lengths of her, or nil in clear water.
    private func nearestCrowding(_ b: SeatView.OwnBoat, _ view: SeatView) -> SeatView.OtherBoat? {
        let room = view.boatClass.hull.length * Self.penaltyBoatClearance
        return view.others
            .filter { !$0.isGhost && ($0.position - b.position).length < room }
            .min { ($0.position - b.position).length < ($1.position - b.position).length }
    }

    /// Whether the mark she is sailing to is in the water she would sail racing while she puts her turn off for the
    /// pack: within `penaltyMarkClearance` hull lengths and a turn's circle more, plus what she sails at her speed
    /// until she can no longer put it off (`canPutOffTurn`). There she starts at once in company, as before #351: put
    /// off, the turn came due beside the mark she had sailed on to, and a touch there was another turn (the mixed
    /// fleet's marks per boat rose from 0.07 to 0.13).
    private func putOffEndsAtAMark(_ b: SeatView.OwnBoat, _ view: SeatView, _ owed: OwedPenalty) -> Bool {
        guard view.course.legs.indices.contains(b.legIndex), case .round(let index) = view.course.legs[b.legIndex]
        else { return false }
        let seconds = max(0, Double(owed.startDeadlineTick - view.tick) / Double(RulesConfig.ticks(1)) - Self.penaltyStartMargin)
        let reach = view.boatClass.hull.length * (Self.penaltyMarkClearance + 3) + b.speed * seconds
        return view.course.elements[index].marks.contains { ($0.position - b.position).length - $0.radius < reach }
    }

    /// Whether she is on the course's last leg, to the finish: there she starts a turn at once, crowd or not, since
    /// she can't finish owing one (#351).
    private func isOnLastLeg(_ b: SeatView.OwnBoat, _ view: SeatView) -> Bool {
        if case .finish = view.course.legs[b.legIndex] { return true }
        return false
    }

    /// The mark nearest her, within `penaltyMarkClearance` hull lengths and a turn's circle more: the way to
    /// it from her, and the water between her and it.
    private func nearestMark(_ b: SeatView.OwnBoat, _ view: SeatView) -> (offset: Vec2, clearance: Double)? {
        let reach = view.boatClass.hull.length * (Self.penaltyMarkClearance + 3)
        var nearest: (offset: Vec2, clearance: Double)?
        for obstacle in view.course.obstacles {
            let offset = obstacle.position - b.position
            let clearance = offset.length - obstacle.radius
            if clearance < reach && clearance < (nearest?.clearance ?? .infinity) { nearest = (offset, clearance) }
        }
        return nearest
    }

    // MARK: - Helming

    /// Error under which a bot centres the rudder on an aim that isn't a groove, and the autohelm
    /// captures the angle she sails.
    static let letGoError = deg2rad(1.5)
    /// A groove aim is let go within this share of the class's snap width to it: close enough that the
    /// autohelm snaps to it whatever her reckoning of the groove wind is off by.
    static let grooveLetGo = 0.6
    /// Error at which she steers with full rudder; less in proportion.
    static let fullRudderError = deg2rad(15)
    /// The least rudder she steers with: past the autohelm's `deadBand`, so the rudder is held.
    static let leastRudder = 0.08
    /// The least rudder a bot holds inside the no-go zone: just off centre (`Autohelm.deadBand`), so the
    /// autohelm stays off and doesn't bear her away to the groove.
    static let noGoRudder = 0.06
    /// Seconds after a tap before she taps again: long enough for the autohelm to sail it.
    static let tapInterval = 3.0
    /// She tacks (a tap with the wind forward of the beam) only at this share of her close-hauled speed or
    /// more: slower, the tap leaves her head to wind. A gybe keeps her sails full, so it needs none.
    static let tackingSpeed = 0.75

    /// Hull lengths a mark must be clear of her for a tap: the tack or gybe sails itself, hands off.
    static let tapMarkClearance = 2.0
    /// Race area a gybe needs downwind of her (#82): it bears her away through dead downwind before the
    /// boom crosses and she heads up again, carrying her this many hull lengths, and this many seconds at
    /// her speed, to leeward.
    static let gybeRoom = (hullLengths: 2.0, seconds: 4.0)

    /// How long before the gun her own tack's groove must carry her to the start line for her to hold off the wind
    /// instead (`grooveIsOverEarly`): nearer the gun, luffed to it, she is only on the line a little early.
    static let grooveEarlySeconds = 10.0

    /// Whether, before the gun, her own tack's groove would carry her hull to the start line more than
    /// `grooveEarlySeconds` before it (`secondsToLine`).
    func grooveIsOverEarly(_ b: SeatView.OwnBoat, _ view: SeatView, _ groove: Aim) -> Bool {
        guard view.time < 0 else { return false }
        let toGun = -view.time
        return secondsToLine(b, view, heading: groove.heading(wind: b.windDirection), ease: false, within: toGun)
            < toGun - Self.grooveEarlySeconds
    }

    /// Whether the race area has room to leeward of her for a gybe (`gybeRoom`).
    func hasGybeRoom(_ b: SeatView.OwnBoat, _ view: SeatView) -> Bool {
        let room = view.boatClass.hull.length * Self.gybeRoom.hullLengths + b.speed * Self.gybeRoom.seconds
        let leeward = -Vec2.heading(b.windDirection) * room
        return view.course.isInRaceArea(b.position + leeward)
    }

    /// Whether she can tap now: a tap done, no mark close enough for the turn to swing her onto, and for a
    /// tack, the speed to carry her through it; for a gybe, room to leeward inside the race area. Racing, she also
    /// taps only clear of every boat (`tapIsClear`, #101).
    func canTap(_ b: SeatView.OwnBoat, _ view: SeatView) -> Bool {
        guard view.time - lastTapTime >= Self.tapInterval,
              isClearOfMarks(b, view, lengths: Self.tapMarkClearance), tapIsClear(b, view),
              !tapTurnsAtKeepClearBoat(b, view) else { return false }
        guard abs(sailingAngle(b)) < .pi / 2 else { return hasGybeRoom(b, view) }
        let closeHauled = view.boatClass.polar.bestUpwind(tws: b.polarWindSpeed).speed * b.speedShadow
        return b.speed >= closeHauled * Self.tackingSpeed
    }

    /// The held input that sails `aim` on her tack under the autohelm (ADR 0007). Once the autohelm holds
    /// it (`holds`), the rudder stays centred until the aim moves. Otherwise she steers in proportion to the
    /// error and centres close to it, so the autohelm captures the angle (and snaps a groove aim to the
    /// groove); an autohelm holding something else is let go of first with a touch of rudder. An aim
    /// inside the no-go zone keeps a touch of rudder instead, towards the wind when there is no error to
    /// steer: letting go there would hand her to the autohelm, which bears away to the groove (#219). No aim
    /// today is one: she holds before her start with Ease, outside the no-go zone (#99).
    private func helm(_ b: SeatView.OwnBoat, to aim: Aim, _ view: SeatView) -> BoatInput {
        let boatClass = view.boatClass
        let error = wrapAngle(aim.angle - sailingAngle(b))
        if aim.angle < BoatDynamics.noGoAngle(boatClass.polar) {
            let windSign: Double = b.boomSide == .port ? 1 : -1
            let proportional = (-windSign * error / Self.fullRudderError).clamped(to: -1...1)
            guard abs(proportional) < Self.noGoRudder else { return BoatInput(rudder: proportional) }
            // Towards the wind (her sailing angle falling) when there is no error to steer.
            let side = error != 0 ? -windSign * error : windSign
            return BoatInput(rudder: side < 0 ? -Self.noGoRudder : Self.noGoRudder)
        }
        if let held = b.autohelm, Self.holds(held, aim, boatClass) { return .neutral }
        let tuning = boatClass.steering.autohelm
        let letGo = aim.groove.map { ($0 == .upwind ? tuning.upwindSnap : tuning.downwindSnap) * Self.grooveLetGo } ?? Self.letGoError
        guard abs(error) > letGo else {
            return b.autohelm == nil ? .neutral : rudder(b, error)
        }
        return rudder(b, error)
    }

    /// Whether the autohelm's `held` target sails `aim`: its groove, or an angle within the aim's tolerance.
    /// A groove held within its snap width of the aim is as close as the autohelm lets her hold.
    static func holds(_ held: Autohelm.Reading, _ aim: Aim, _ boatClass: BoatClass) -> Bool {
        if let groove = aim.groove { return held.target.groove == groove }
        let off = abs(wrapAngle(held.aim - aim.angle))
        guard let groove = held.target.groove else { return off <= aim.tolerance }
        let tuning = boatClass.steering.autohelm
        return off <= max(aim.tolerance, groove == .upwind ? tuning.upwindSnap : tuning.downwindSnap)
    }

    /// Rudder that turns her sailing angle by `error` (radians): in proportion, at least `leastRudder`.
    /// Turning to starboard (+) brings a wind over the starboard side towards the bow: her sailing angle
    /// falls on starboard tack and rises on port.
    private func rudder(_ b: SeatView.OwnBoat, _ error: Double) -> BoatInput {
        let windSign: Double = b.boomSide == .port ? 1 : -1
        let proportional = (-windSign * error / Self.fullRudderError).clamped(to: -1...1)
        let least = proportional < 0 ? -Self.leastRudder : Self.leastRudder
        return BoatInput(rudder: abs(proportional) < Self.leastRudder ? least : proportional)
    }

    /// Steers with the rudder for `heading`, keeping clear or off a mark: on her own tack, never through
    /// head to wind or past the by-the-lee limit (tacks and gybes are the tap's), nor closer to the wind than
    /// `closest`, by default 5° outside the no-go zone (a windward boat's luff before her start goes closer, #280,
    /// `startLuff`). Centred once she's on it.
    private func steer(_ b: SeatView.OwnBoat, toHeading heading: Double, _ view: SeatView,
                       closest: Double? = nil) -> BoatInput {
        let polar = view.boatClass.polar
        var target = b.boomSide.sailingAngle(relativeWind: wrapAngle(b.windDirection - heading))
        let closest = closest ?? BoatDynamics.noGoAngle(polar) + deg2rad(5)
        if target > -.pi / 2 && target < closest { target = closest }
        let byTheLee = max(0, polar.byTheLeeLimit(tws: b.windSpeed) - deg2rad(5))
        if target <= -.pi / 2 && .pi + target > byTheLee { target = byTheLee - .pi }
        let error = wrapAngle(target - sailingAngle(b))
        return abs(error) < Self.letGoError ? .neutral : rudder(b, error)
    }

    /// Her sailing angle (`BoomSide.sailingAngle`): her wind angle against her boom, as the autohelm reads it.
    func sailingAngle(_ b: SeatView.OwnBoat) -> Double {
        b.boomSide.sailingAngle(relativeWind: b.relativeWind)
    }

    // MARK: - Planning

    /// Where she wants to sail now.
    private mutating func plan(_ b: SeatView.OwnBoat, _ view: SeatView) -> Aim {
        let c = view.course
        switch b.status {
        case .prestart:
            return hangBackAim(b, view) ?? startAim(b, view)
        case .ocs:
            return returnAim(b, view)
        case .racing:
            if case .finish = c.legs[b.legIndex] { return finishAim(b, view) }
            return navigate(b, to: waypoint(b, view), view)
        case .finished, .dsq:
            return Aim(heading: b.heading, b, tolerance: .pi)
        }
    }

    /// The point to sail at for the current leg: round each mark to port, approaching it along the
    /// course (upwind to W on the starboard layline, across from W to O); through the gate, then round the
    /// nearer of its marks.
    private func waypoint(_ b: SeatView.OwnBoat, _ view: SeatView) -> Vec2 {
        let c = view.course
        let leg = c.legs[b.legIndex]
        switch leg {
        case .round(let index):
            switch c.elements[index] {
            case .mark(let mark, _):
                let m = mark.position
                let approach = index == CourseLayout.windwardIndex
                    ? c.upwind : (m - c.elements[CourseLayout.windwardIndex].marks[0].position).normalized
                let side = approach.rightPerp
                if b.roundingStage == 0 && index == CourseLayout.windwardIndex {
                    let room = mark.radius + view.boatClass.hull.beam + Self.markClearance + Self.layMargin
                    return Self.windwardApproach(from: b.position, tack: b.tack, mark: m, room: room,
                                                 fetch: m + side * 6 + approach * 4, wind: b.windDirection,
                                                 groove: grooveAngle(.upwind, b, view), upwind: c.upwind,
                                                 overstand: Self.overstand + (laylineError.map { $0.leg == b.legIndex ? $0.error : 0 } ?? 0))
                }
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

    /// Metres from her spot on the finish line inside which she sails straight for it, so she crosses the
    /// line between its ends rather than gybing across an end.
    static let finishApproach = 40.0

    /// The finish: down to her spot on the line and through it. One that crossed beyond an end, below the
    /// line but not finished, sails back up to the course side to cross it again.
    private mutating func finishAim(_ b: SeatView.OwnBoat, _ view: SeatView) -> Aim {
        let c = view.course
        let line = c.finishLine
        let spot = line.pin.position + (line.committee.position - line.pin.position) * finishSpot
        if line.side(b.position) <= 0 { return navigate(b, to: spot + c.upwind * 15, view) }
        let through = spot - c.upwind * 12
        guard (spot - b.position).length < Self.finishApproach else { return navigate(b, to: through, view) }
        plannedTack = b.tack
        return Aim(heading: (through - b.position).bearing, b, tolerance: Self.reachTolerance)
    }

    /// Metres down the starboard layline from the windward mark's fetch point to where a boat that can't
    /// fetch it yet sails first: far enough right of the mark that the port track there clears it.
    static let laylineLead = 15.0
    /// Metres her track keeps off a mark beyond its radius and her beam (`avoidMarks`).
    static let markClearance = 1.0
    /// Metres more than that by which a starboard boat's close-hauled course must clear the windward mark
    /// for her to hold on and round it: room for a small header on the way in.
    static let layMargin = 0.5
    /// Metres right of and below the windward mark a boat above it, unrounded and right of it, sails back to
    /// (`windwardApproach`).
    static let belowRight = (side: 8.0, down: 6.0)
    /// Metres left of and below it one left of it sails to first, round its foot.
    static let belowLeft = (side: 7.0, down: 7.0)

    /// The point to beat to for the windward mark at `mark`, rounded to port: `fetch`, beside and above it,
    /// on the starboard layline. A boat that can't fetch it yet, and is below the layline's lead point, sails
    /// to that point first, down the layline and right of the mark: a port track to the fetch point itself
    /// would run over the mark, and a starboard one below the layline would pass under it. A boat on
    /// starboard whose close-hauled course clears the mark itself by `room` metres or more holds on to the
    /// fetch point and rounds: close in, the lead point is abeam of her, and sailing for it would be a tack,
    /// a reach and a tack back (#231). `tack` is her tack, `wind` the wind's direction, `groove` her upwind
    /// groove angle to it, `upwind` the course's upwind direction.
    ///
    /// A boat above the mark that hasn't rounded it (#377's fixer: one that bore away past it on its wrong side, in a
    /// crowd at the mark) can't round from there: the rounding counts only crossing the line out to the mark's right
    /// going upwind (`CourseLayout.roundingStages(of:)`), and the fetch point is above that line, so she circled it
    /// for the rest of the race. She sails back below the mark first: to `belowRight` from its right, to `belowLeft`
    /// round its foot from its left; below it, the approach is the beat's.
    static func windwardApproach(from position: Vec2, tack: Tack, mark: Vec2, room: Double, fetch: Vec2,
                                 wind w: Double, groove up: Double, upwind: Vec2, overstand: Double = overstand) -> Vec2 {
        let fromMark = position - mark
        if fromMark.dot(upwind) > 0 {
            return fromMark.dot(upwind.rightPerp) >= 0 ? mark + upwind.rightPerp * belowRight.side - upwind * belowRight.down
                : mark - upwind.rightPerp * belowLeft.side - upwind * belowLeft.down
        }
        if wrapAngle((fetch - position).bearing - w) <= -(up - overstand) { return fetch }
        let closeHauled = Vec2.heading(w - up)
        let toMark = mark - position
        // The mark to port of her starboard course (negative to starboard), metres.
        let clears = -toMark.dot(closeHauled.rightPerp)
        if tack == .starboard && toMark.dot(closeHauled) > 0 && clears >= room { return fetch }
        let lead = fetch - closeHauled * laylineLead
        return (lead - position).dot(upwind) > 0 ? lead : fetch
    }

    /// `waypoint`, unless the straight line to it runs over `mark` — then `via` first.
    private func detour(from p: Vec2, to waypoint: Vec2, around mark: Vec2, via: Vec2) -> Vec2 {
        let closest = Collision.closestPoint(on: Segment(p, waypoint), to: mark)
        return (closest - mark).length < 4 ? via : waypoint
    }

    /// The aim that sails her to `target`: the upwind groove on a tack inside the corridor to it, the
    /// downwind groove on a gybe likewise, or straight there as a wind angle when it's a reach (the
    /// laylines and the reach both expressed as the angle to the wind, ADR 0007). Her tactics choose the
    /// tack inside the corridor, and may pinch or foot off the groove.
    mutating func navigate(_ b: SeatView.OwnBoat, to mark: Vec2, _ view: SeatView) -> Aim {
        // Upstream of it by the set she allows for (#102): none at Club, the forecast's at National.
        let target = mark - currentAllowance(b, view, to: mark) * secondsToSail(b, to: mark)
        let overstand = laylineOverstand(b)
        let toTarget = target - b.position
        let distance = toTarget.length
        let bearing = toTarget.bearing
        let w = b.windDirection
        let offWind = abs(wrapAngle(bearing - w))
        let up = grooveAngle(.upwind, b, view)
        let down = grooveAngle(.downwind, b, view)
        let corridor = max(20, distance * tactics.corridor)
        // Her favoured side shifts the corridor on the leg, not at its end: it fades out over her last
        // `tacticalRange` or so, so the corridor closes on her mark and never has her tack onto a board that
        // sails her below its layline, into it.
        let bias = tactics.corridorBias * min(max(distance / Self.tacticalRange - 1, 0), 1)
        let lateral = (b.position - target).dot(Vec2.heading(w).rightPerp) - bias * corridor

        if offWind < up + deg2rad(2) {
            // Where the target bears from her: to the right of the wind positive.
            let relative = wrapAngle(bearing - w)
            var tack = plannedTack
            if lateral < -corridor {
                tack = .port
            } else if lateral > corridor {
                tack = .starboard
            } else if tack == .starboard && relative >= up + overstand {
                tack = .port // on the port layline
            } else if tack == .port && relative <= -(up + overstand) {
                tack = .starboard // on the starboard layline
            } else if distance > Self.tacticalRange {
                // A fleet tactic's tack (#234) onto a board past its layline would only be tacked back.
                tack = upwindTack(b, view, planned: tack) { other in
                    other == .starboard ? relative >= up + overstand : relative <= -(up + overstand)
                }
            }
            setTack(tack, view)
            let aim = upwindAim(b, view, tack: tack, relative: relative, distance: distance)
            return distance > Self.tacticalRange ? missingGroove(aim, b, view) : aim
        }

        if offWind > down - deg2rad(2) {
            // Where the target bears from dead downwind: to the right looking downwind positive, as the
            // port gybe's heading lies and against the starboard gybe's.
            let fromDeadDownwind = wrapAngle(bearing - w - .pi)
            var gybe = plannedTack
            if lateral < -corridor {
                gybe = .port
            } else if lateral > corridor {
                gybe = .starboard
            } else if gybe == .starboard && fromDeadDownwind <= -(.pi - down + overstand) {
                gybe = .port // on the port layline
            } else if gybe == .port && fromDeadDownwind >= .pi - down + overstand {
                gybe = .starboard // on the starboard layline
            } else if distance > Self.tacticalRange {
                gybe = downwindGybe(b, view, planned: gybe)
            }
            setTack(gybe, view)
            let aim = Aim.groove(.downwind, tack: gybe, angle: down)
            return downwindAim(b, view, aim: distance > Self.tacticalRange ? missingGroove(aim, b, view) : aim)
        }

        plannedTack = b.tack
        return downwindAim(b, view, aim: Aim(heading: bearing, b, tolerance: Self.reachTolerance))
    }

    /// How far the angle held on a reach may drift off the one her mark needs before she steers again.
    static let reachTolerance = deg2rad(5)
    /// How far past a layline she sails before tacking onto it: the tack's own loss.
    static let overstand = deg2rad(1)
    /// Metres from her mark inside which she tacks only on a layline or the corridor's edge: a header or
    /// a puff this close would tack her below the layline, into the mark.
    static let tacticalRange = 60.0

    mutating func setTack(_ tack: Tack, _ view: SeatView) {
        guard tack != plannedTack else { return }
        plannedTack = tack
        lastTackTime = view.time
    }

    /// The heading she steers for instead of `desired` while she must, or nil: keeping clear of a boat,
    /// and staying off a mark while she does or by itself, since a mark doesn't move out of her way. Nor
    /// does the race area's edge (#82): whichever of these she steers for, she turns off the edge only if
    /// that heading would sail her into it. Turning off a mark in the way of her desired heading, she holds her
    /// course instead when that turn would take her, the right-of-way boat, towards a boat that must keep clear of
    /// her (#101, `turnsTowardsKeepClearBoat`) and her course clears the mark.
    func evasiveHeading(_ b: SeatView.OwnBoat, _ view: SeatView, desired: Double) -> Double? {
        evasion(b, view, desired: desired)?.heading
    }

    /// A heading she steers for instead of her desired one (`evasion`), and how: as close to the wind as `steer` goes
    /// unless `closest` says closer (a windward boat's luff before her start, `startLuff`, #280), and eased to drop
    /// astern if `dropsAstern`.
    struct Evasion: Sendable {
        var heading: Double
        var closest: Double? = nil
        var dropsAstern = false
    }

    /// `evasiveHeading`, with how she steers it (`Evasion`): only her keep-clear heading, when neither a mark nor the
    /// edge turns her off it, carries more than the heading.
    func evasion(_ b: SeatView.OwnBoat, _ view: SeatView, desired: Double) -> Evasion? {
        let keepingClear = keepClear(b, view, desired: desired)
        var evasive = keepingClear.map { kept in avoidMarks(b, view, desired: kept.heading).map { Evasion(heading: $0) } ?? kept }
            ?? avoidMarks(b, view, desired: desired).map { Evasion(heading: $0) }
        if keepingClear == nil, b.status == .racing, let off = evasive?.heading,
           turnsTowardsKeepClearBoat(b, view, turn: wrapAngle(off - b.heading) > 0 ? 1 : -1),
           avoidMarks(b, view, desired: b.heading) == nil {
            evasive = Evasion(heading: b.heading)
        }
        return avoidEdges(b, view, desired: evasive?.heading ?? desired).map { Evasion(heading: $0) } ?? evasive
    }

    /// A heading that keeps her clear if a collision is coming and she is the one that must keep clear, or racing,
    /// must give the other mark-room (#101). Before her start (#99) she keeps clear on port by the water
    /// (`startKeepClear`), and on starboard as `ruleKeepClear` has her unless that would take her over the line early:
    /// a luff (`startLuff`, #280) only if it would within `luffLineSeconds`, since she bears away again once clear.
    private func keepClear(_ b: SeatView.OwnBoat, _ view: SeatView, desired: Double) -> Evasion? {
        let lookahead = keepClearLookahead
        guard b.status == .prestart || b.status == .ocs else {
            return ruleKeepClear(b, view, desired: desired, lookahead: lookahead)
        }
        if b.tack == .port || b.status == .ocs || keepsClearOfEveryBoat {
            return startKeepClear(b, view, desired: desired, lookahead: lookahead).map { Evasion(heading: $0) }
        }
        guard let kept = ruleKeepClear(b, view, desired: desired, lookahead: lookahead) else { return nil }
        let within = isStartLuff(b, view, kept.heading) ? Self.luffLineSeconds : nil
        guard crossesEarly(b, view, heading: kept.heading, within: within) else { return kept }
        return startKeepClear(b, view, desired: desired, lookahead: lookahead).map { Evasion(heading: $0) } ?? kept
    }

    /// Seconds ahead she looks for a collision she must keep clear of: further, the more skilled she is
    /// (`BotWeaknesses.keepClearLookahead`, #103).
    /// The cautious bot looks `Caution.keepClearLookahead` ahead instead (#104).
    var keepClearLookahead: Double { caution == nil ? weaknesses.keepClearLookahead : Caution.keepClearLookahead }

    /// The heading the rule she must keep clear under has her steer, if a collision is coming: ducking, luffing,
    /// finishing a tack, or turning away. Racing, her give-way manoeuvre for each relation is `racingKeepClear`'s
    /// (#101), and she gives the boat she owes mark-room to (`SeatView.OwnBoat.markRoom`) room as she would keep
    /// clear of her, whatever rules 10–13 give her.
    private func ruleKeepClear(_ b: SeatView.OwnBoat, _ view: SeatView, desired: Double, lookahead: Double) -> Evasion? {
        for other in view.others where !other.isGhost {
            if b.status == .racing {
                guard let rule = keepClearRule(b, view, other), !misjudges(other, rule),
                      isAboutToHit(other, b, view, desired: desired, lookahead: lookahead) else { continue }
                return Evasion(heading: racingKeepClear(b, view, from: other, rule: rule, desired: desired, lookahead: lookahead))
            }
            guard isAboutToHit(other, b, view, desired: desired, lookahead: lookahead) else { continue }
            guard let right = other.rightOfWay, right.keepClear == view.seat, !misjudges(other, right.rule) else { continue }
            let offset = other.position - b.position

            // Headings are set relative to the wind so evasive action never parks the boat in irons.
            let side: Double = b.tack == .port ? 1 : -1
            // Not racing, she is before her start (#99), where boats hold, wait and reach below the line on every
            // course, not only close-hauled: she ducks further than she is sailing already, finishes a tack to
            // close-hauled rather than stay tacking (rule 13), and luffs from as close as she's holding (`startLuff`,
            // #280). Misjudging the encounter (#103, `judgeEncounters`), she sails on.
            switch right.rule {
            case .portStarboard:
                return Evasion(heading: b.windDirection + side * min(max(deg2rad(85), b.twa + deg2rad(30)), deg2rad(150)))
            case .whileTacking:
                return Evasion(heading: finishingTack(b, view))
            case .windwardLeeward:
                return startLuff(b, view, desired: desired, lookahead: lookahead)
            default:
                // Turning away towards the wind, she luffs as a windward boat does (#280): `sailable` would only turn
                // her down again, from her hold, towards the boat.
                let otherIsToStarboard = offset.dot(b.forward.rightPerp) > 0
                let turn: Double = otherIsToStarboard ? -1 : 1
                if turn * side < 0 { return startLuff(b, view, desired: desired, lookahead: lookahead) }
                return Evasion(heading: sailable(b.heading + turn * deg2rad(35), wind: b.windDirection))
            }
        }
        return nil
    }

    /// Whether she is about to hit `other`, sailing `desired` at her speed for up to `lookahead` seconds: they come
    /// within `keepClearDistance` hull lengths, centre to centre.
    private func isAboutToHit(_ other: SeatView.OtherBoat, _ b: SeatView.OwnBoat, _ view: SeatView, desired: Double,
                              lookahead: Double) -> Bool {
        guard (other.position - b.position).length < 30 else { return false }
        return Self.closestApproach(of: other, to: b, heading: desired, lookahead: lookahead)
            < view.boatClass.hull.length * keepClearLengths
    }

    /// The closest `other` comes to her over the next `lookahead` seconds, metres between centres, sailing `heading`
    /// at her speed through the water while `other` sails on at hers: both in straight lines, in the same water.
    static func closestApproach(of other: SeatView.OtherBoat, to b: SeatView.OwnBoat, heading: Double, speed: Double? = nil,
                                lookahead: Double) -> Double {
        let offset = other.position - b.position
        let relativeVelocity = other.velocity - Vec2.heading(heading) * (speed ?? b.speed)
        let vv = relativeVelocity.lengthSquared
        let t = vv > 1e-6 ? (-offset.dot(relativeVelocity) / vv).clamped(to: 0...lookahead) : 0
        return (offset + relativeVelocity * t).length
    }

    /// A heading that bears her away from a mark she is about to sail into, if there is one.
    private func avoidMarks(_ b: SeatView.OwnBoat, _ view: SeatView, desired: Double) -> Double? {
        let ahead = Vec2.heading(desired)
        for obstacle in view.course.obstacles {
            let offset = obstacle.position - b.position
            guard offset.length < 20 else { continue }
            let along = offset.dot(ahead)
            guard along > 0, along < max(b.speed, 1) * 3 + 3 else { continue }
            guard abs(offset.cross(ahead)) < obstacle.radius + view.boatClass.hull.beam + Self.markClearance else { continue }
            let markIsToStarboard = offset.dot(ahead.rightPerp) > 0
            let turned = desired + (markIsToStarboard ? -1 : 1) * deg2rad(30)
            let away = sailable(turned, wind: b.windDirection)
            // Close-hauled with the mark to leeward, away from it is into the wind: she shoots it, luffing into the
            // no-go zone on her way (#102's fix loop), rather than holding her groove into it.
            guard abs(wrapAngle(away - turned)) > 1e-9,
                  abs(offset.cross(.heading(away))) < obstacle.radius + view.boatClass.hull.beam + Self.markClearance
            else { return away }
            let side: Double = wrapAngle(b.windDirection - desired) >= 0 ? 1 : -1
            return b.windDirection - side * Self.shootAngle
        }
        return nil
    }

    /// `input`, unless its rudder would swing her stern into a mark on her quarter (#102's fix loop): a boat pivots
    /// about her middle, so turning away from a mark alongside her aft swings her quarter onto it, and each touch
    /// costs her a turn; slowed by it, she touched it again every time she turned off it. While it is there she turns,
    /// gently, the other way, her bow away from it, until it is past her stern. Only once she has started: before
    /// the gun the line's ends are the marks she works about, and turning off her plan there can carry her over
    /// the line (#99's takeover).
    func clearingQuarter(_ b: SeatView.OwnBoat, _ view: SeatView, _ input: BoatInput) -> BoatInput {
        guard b.status != .prestart, b.status != .ocs else { return input }
        let rudder = input.rudderValue
        guard abs(rudder) > Autohelm.deadBand else { return input }
        let hull = view.boatClass.hull
        for obstacle in view.course.obstacles {
            let offset = obstacle.position - b.position
            let along = offset.dot(b.forward)
            guard along < 0, along > -(hull.length / 2 + obstacle.radius + Self.markClearance) else { continue }
            let lateral = offset.dot(b.forward.rightPerp)
            guard abs(lateral) < obstacle.radius + hull.beam / 2 + Self.markClearance else { continue }
            // Rudder to starboard (+) swings her stern to port (−), and the other way about.
            guard (rudder > 0) == (lateral < 0) else { continue }
            return BoatInput(rudder: (lateral > 0 ? 1 : -1) * Self.leastRudder, ease: input.ease)
        }
        return input
    }

    /// Radians off the wind she luffs to, shooting a mark close to leeward of her groove (`avoidMarks`): inside the
    /// no-go zone, on her own tack, carrying her way past it.
    static let shootAngle = deg2rad(15)

    /// Seconds of sailing ahead she looks for the race area's edge.
    static let edgeLookahead = 3.0

    /// A heading that turns her off the race area's edge (#82: its boundary and the land in it) when she
    /// is about to sail into it: the nearest to `desired`, towards the wind first, whose point a few
    /// seconds' sailing and a hull length ahead is in the race area. The edge costs her speed, never a
    /// penalty, but a boat pinned against it bow on turns away only at her class's slowest rate.
    private func avoidEdges(_ b: SeatView.OwnBoat, _ view: SeatView, desired: Double) -> Double? {
        let ahead = max(b.speed, 1) * Self.edgeLookahead + view.boatClass.hull.length
        func isClear(_ heading: Double) -> Bool { view.course.isInRaceArea(b.position + Vec2.heading(heading) * ahead) }
        guard !isClear(desired) else { return nil }
        let towardsWind: Double = wrapAngle(b.windDirection - desired) >= 0 ? 1 : -1
        // Only a heading on her own tack: `steer` never takes her through head to wind or past dead downwind,
        // so one beyond would leave her pinned where she is, bow on to the edge (#99, a takeover run into it).
        let ownSide: Double = b.tack == .starboard ? 1 : -1
        for step in 1...18 {
            for side in [towardsWind, -towardsWind] {
                let heading = desired + side * Double(step) * deg2rad(10)
                guard wrapAngle(b.windDirection - heading) * ownSide > 0 else { continue }
                if isClear(heading) { return sailable(heading, wind: b.windDirection) }
            }
        }
        return nil
    }

    /// Nudges a heading out of the no-go zone, keeping it on the same side of the wind.
    private func sailable(_ heading: Double, wind: Double) -> Double {
        let relative = wrapAngle(wind - heading)
        let minimum = deg2rad(38)
        guard abs(relative) < minimum else { return heading }
        return wind - (relative >= 0 ? minimum : -minimum)
    }

    /// Whether every mark is more than `lengths` hull lengths clear of the boat.
    private func isClearOfMarks(_ b: SeatView.OwnBoat, _ view: SeatView, lengths: Double) -> Bool {
        let room = view.boatClass.hull.length * lengths
        return view.course.obstacles.allSatisfy { ($0.position - b.position).length > $0.radius + room }
    }
}

/// Where a bot wants to sail (#231): a sailing angle on a tack, which the autohelm holds once she has
/// steered to it and centred the rudder. Everything is an angle to the wind (ADR 0007): the groove, a
/// pinch or foot off it, and a course to a mark as the angle it needs now. Before her start she may sail
/// it with Ease (#99), sheets let out to slow her.
struct Aim: Equatable {
    var tack: Tack
    /// Her sailing angle on `tack` (`BoomSide.sailingAngle`), radians, 0...π.
    var angle: Double
    /// The groove she wants: the autohelm snaps to it and follows it; nil for an angle it holds.
    var groove: Autohelm.Groove?
    /// How far the angle the autohelm holds may be off `angle` before she steers again.
    var tolerance: Double
    /// Sheets let out (`BoatInput.ease`): she sails the angle at the class's eased fraction of her speed.
    var ease = false

    init(angle: Double, tack: Tack, tolerance: Double = deg2rad(1.5), ease: Bool = false) {
        self.tack = tack
        self.angle = angle
        self.tolerance = tolerance
        self.ease = ease
    }

    /// The groove on `tack`, at `angle` (her reckoning of it).
    static func groove(_ groove: Autohelm.Groove, tack: Tack, angle: Double) -> Aim {
        var aim = Aim(angle: angle, tack: tack)
        aim.groove = groove
        return aim
    }

    /// Sailing `heading` in the wind at `b` now. Within a few degrees of dead downwind she stays on her tack.
    init(heading: Double, _ b: SeatView.OwnBoat, tolerance: Double) {
        let relative = wrapAngle(b.windDirection - heading)
        // Turning to starboard (+) brings a wind over the starboard side (+) towards the bow.
        let tack: Tack = abs(relative) > .pi - deg2rad(3) ? b.tack : (relative >= 0 ? .starboard : .port)
        self.init(angle: abs(relative), tack: tack, tolerance: tolerance)
    }

    /// Her compass heading on this aim in a wind blowing from `wind`.
    func heading(wind: Double) -> Double {
        tack == .starboard ? wind - angle : wind + angle
    }

    /// The same aim `offset` radians further off the wind (positive: foot, or deeper; negative: pinch,
    /// or hotter), held as an angle.
    func offset(by offset: Double, tolerance: Double = deg2rad(1.5)) -> Aim {
        Aim(angle: (angle + offset).clamped(to: 0...(.pi)), tack: tack, tolerance: tolerance)
    }
}

extension BoatInput {
    /// The same rudder with the sheets let out, or not.
    func eased(_ ease: Bool) -> BoatInput {
        ease == self.ease ? self : BoatInput(rudder: rudder, ease: ease)
    }
}
