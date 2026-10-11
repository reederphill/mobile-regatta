import RegattaCore

// Her tacks and gybes by hand (#459), on a class whose tack/gybe tap sails nothing (`AutohelmTuning.sailsTap` false,
// skiff@8): she holds the rudder over through the wind herself, as a player does, and how well is her handling
// (`BotBrain.turnHandling`, #443), not a roll skill. A class whose tap sails the turn keeps the tap and the roll
// (`BotBrain+Roll.swift`), untouched. Internal heuristics, never shown to a player:
//
// - "A moderate rudder, eased out": a good helm turns a tack at a little over half rudder and eases it over the last
//   degrees onto the new groove; the poorer she is the more she puts on, to a slam hard over, which costs her half a
//   length (`HandTackTable.tackFraction`, `tackEase`).
// - "Gybe gently": a good helm gybes with little rudder, a slow wide turn; a poor one cranks it, which costs her the
//   most (`HandTackTable.gybeFraction`).
// - "Bear off to build speed": in light air, slow but fast enough to tack, a good helm bears away a few degrees for
//   a few seconds first (`HandTackTable.bearOff`).
// - "Flubbed it": now and then, the more often the worse her handling, she under-steers the turn or sails past her
//   new groove (`HandTackTable.botchRate`). A flubbed turn costs her lengths, never a stall: too little rudder
//   stalls her in light air, so she under-steers only in a breeze.
// - "Let go in irons": stalled short of head to wind she centres the rudder, truly, until the boat falls off and
//   has steerage again (`centresStalled`): the class's irons recovery works only on a centred rudder (#458).

/// The hand turn's placeholder values (#459), one table for the owner to tune (#461), as `HandSteeringTable` is the
/// hand steering's. Anchors, skiff@8 at 10 kn from full speed on the owner's ruling of 2026-10-09 (#458's harness,
/// `HandTurnProfileTests`): a tack at 60 % rudder eased out loses about 0.96 hull lengths (0.95 held; 50 % the same),
/// 75 % 1.07, a slam 1.48, 35 % 1.23; a gybe 0.33 at 30 % rudder and 1.17 hard over; a tack at 60 % over-steered 20°
/// to 30° about 1.14 to 1.52 and a slam as far past 1.92 to 2.31, a cranked gybe 1.63 to 1.96.
public enum HandTackTable {
    /// A tack's rudder, as a share of full: `good` at `goodHandling` or better, rising in a line to `poor` at
    /// `poorHandling` or worse. 60 %, not the 50 % that measures a hair better at 10 kn: in light air from the slowest
    /// she tacks at, 50 % is on the edge of a stall (5 kn from 70 % of her speed: 20 s stuck; 55 %, 4 s). Club's centre
    /// (0.55) turns at about 77 %, about 1.1 lengths.
    public static let tackFraction = (good: 0.6, poor: 1.0)
    public static let tackHandling = (good: 0.8, poor: 0.2)
    /// Radians before her new groove from which a good helm eases the tack's rudder (none at `tackHandling.poor`). At
    /// 60 % it costs her 0.01 lengths; the more rudder she has on the more it saves (0.09 of a slam's).
    public static let tackEase = deg2rad(20)
    /// A gybe's rudder, as `tackFraction`: little for a good helm, hard over for a poor one.
    public static let gybeFraction = (good: 0.3, poor: 1.0)
    public static let gybeHandling = (good: 0.7, poor: 0.3)
    /// The eased rudder ends at this share of the turn's, this close to the groove (the #458 harness's `smooth`).
    public static let easedShare = 0.25
    public static let easeEnd = deg2rad(5)
    /// Seconds of turning short of her groove at which she lets the turn go: her rudder's slew (the harness's `held`).
    public static let leadSeconds = 0.2

    /// The share of her turns she flubs at handling 0, falling with the square of her handling: none at 1.
    public static let botchRate = 0.5
    /// The share of her flubbed tacks she under-steers; the rest, and every flubbed gybe, she over-steers.
    public static let underSteerShare = 0.25
    /// A flubbed tack under-steered: this rudder, in more than `underSteerWind` (m/s) and only by a helm whose own
    /// rudder is `underSteerFrom` or less (a slam under-steered would tack better). 35 % rudder costs 0.28 lengths more
    /// than the best at 10 kn and 0.5 at 14; in light air it stalls her (6 kn from the slowest she tacks at: 19 s
    /// stuck at 36 %), so there, and for a helm with more rudder on, the flub is an over-steer.
    public static let underSteer = 0.35
    public static let underSteerWind = metresPerSecond(knots: 8)
    public static let underSteerFrom = 0.85
    /// A flubbed turn over-steered: radians past her new groove, drawn in this range.
    public static let overSteer = deg2rad(20)...deg2rad(30)

    /// "Bear off to build speed": at this handling or better, in this much wind or less (m/s), under this share of
    /// her close-hauled speed, she bears away `angle` for `seconds` before a tack. In more wind it only costs her.
    public static let bearOff = (handling: 0.7, wind: metresPerSecond(knots: 8), speed: 0.85, angle: deg2rad(10),
                                 seconds: 3.0)

    /// Seconds after which a tack, or a gybe, she is still turning is over whatever she has made of it.
    public static let longest = (tack: 12.0, gybe: 15.0)

    /// "Let go in irons": within `margin` of the no-go zone, under `slow` of her close-hauled speed and turning at
    /// under `turnRate` for `seconds`, she centres the rudder until she has `steerage` of that speed or is out of it.
    public static let stall = (margin: deg2rad(3), slow: 0.3, turnRate: deg2rad(2), seconds: 0.5, steerage: 0.5)
    /// A penalty turn's rudder, as a share of full, whatever her handling: hard over, the rudder's drag stops her head
    /// to wind in every turn (8 to 10 s stuck, the turn through the wind at a crawl), as a slammed tack from slow.
    public static let penaltyFraction = 0.7
    /// Radians per second: a penalty turn's rudder turning her through the wind slower than this, she puts it hard
    /// over, from `penaltyLuffMargin` radians outside close-hauled.
    public static let penaltyCrawl = deg2rad(8)
    public static let penaltyLuffMargin = deg2rad(10)
    /// "Speed before the tack": luffing up through a penalty turn inside `from` radians off the wind, under `speed` of
    /// her close-hauled speed, she turns on with `rudder` only, until `penaltyLuffMargin` outside close-hauled.
    public static let penaltyBuild = (from: deg2rad(110), speed: 0.75, rudder: 0.35)
    /// A penalty turn's time by hand (`BotBrain.penaltyTurnSeconds`): the turn's rudder leaves her about `speed` of her
    /// close-hauled speed, the tack at the end of it takes about `crawl` seconds more, and she wants `margin` seconds
    /// to spare before she puts a turn off or gives one up. On the wind (inside `luffFirstAngle`) with `luffFirstSpeed`
    /// of her close-hauled speed she luffs first.
    public static let penaltyTurn = (speed: 0.4, crawl: 9.0, margin: 3.0, luffFirstAngle: deg2rad(90), luffFirstSpeed: 0.6)
    /// "Start first, then turn" (`BotBrain.startsBeforeHerTurn`, #471): at least `turnIn` seconds for the rules' 30°
    /// once she is over the line (the rudder's slew, the 30° at the turn's rudder, a second to spare; more when slow),
    /// reckoned at `speed` of her close-hauled speed while her crossing is further off than that; `spare` seconds over
    /// the turn itself before the complete deadline; from `late` seconds after the gun her run to the line is reckoned
    /// on the heading she sails, not close-hauled on her tack. Measured on the quick loops (80 all-Club and 160
    /// all-National 10-boat races) with the crowd's put-off gone: boats more than 10 s late for a turn before the
    /// start 335 a thousand without it and 265 with it (Club), 186 and 153 (National).
    public static let penaltyStartFirst = (turnIn: 2.0, spare: 4.0, late: 2.0, speed: 0.6)
    /// "Bear away, then turn" (`BotBrain.clearingRoom`, #471): with a boat within `lengths` hull lengths she bears away
    /// `angle`, under the rules' 30°, and sails that heading sheeted in for `seconds` at most before she turns, unless
    /// it brings her `closing` metres nearer a boat inside her keep-clear distance. The
    /// owner's ruling for how it looks; on the quick loops it moved no number (calls on a boat turning, Club: 256
    /// without it, 249 with it; over 8 s, 260).
    public static let penaltyClear = (angle: deg2rad(25), seconds: 3.5, lengths: 3.0, closing: 0.5)
    /// Seconds at most she waits, centred, for steerage to turn a penalty on.
    public static let stallWait = 8.0

    /// Seconds a tack onto starboard takes her before her start, by hand, before she can sail at her spot
    /// (`BotBrain.tackSeconds`): the turn, and the way it costs her won back.
    public static let startTackSeconds = 9.0

    /// The least rudder of a gybe before her start, a share of full: a gentle gybe (`gybeFraction.good`) is 12 s and
    /// 30 m of water downwind of the line.
    public static let startGybeFraction = 0.7

    /// Turning up to her hold or her run in before her start (`BotBrain.turnUpSeconds`): from more than `from` radians
    /// broader, at `rudder` of the full rudder's rate at `speed` of her close-hauled speed or her own, and `slew`
    /// seconds for the rudder.
    public static let startTurnUp = (from: deg2rad(20), speed: 0.4, rudder: 0.8, slew: 0.5)
    /// Reaching along the line for the speed to tack (`BotBrain.startReachAim`): `towards` radians closer to the wind
    /// than parallel to the line, no broader than `broadest` (a tack from there, not a gybe), where her groove would
    /// have her over the line `within` seconds. Measured on the start suite's 160 races: any time before the gun, OCS
    /// 0.03 and 800 pre-start fouls, but the suite's hunters then draw no more calls than live bots in their seats
    /// (`BotHunterSuiteTests`: 19 against 22); within 12 s 0.03 and 970 (18 against 14); within 8 s 0.04 and 1018 (25
    /// against 15); within 5 s 0.05 and 1046; never, 0.05 and 1264.
    public static let startReach = (towards: deg2rad(12), broadest: deg2rad(85), within: 8.0)
    /// Seconds to the gun inside which a turn by hand before her start, once begun, ends only for a mark or the edge
    /// (`BotBrain.handTurning`). Measured on the start suite's 160 races: always, on time 0.46 and 1038 pre-start
    /// fouls; inside 25 s, 0.46 and 812; inside 12 s, 0.41 and 598; never, 0.41 and 560.
    public static let startTurnsThroughSeconds = 25.0

    /// `values.good` at `handling.good` or better, in a line to `values.poor` at `handling.poor` or worse.
    static func ramp(_ h: Double, _ values: (good: Double, poor: Double), _ handling: (good: Double, poor: Double)) -> Double {
        let t = ((handling.good - h) / (handling.good - handling.poor)).clamped(to: 0...1)
        return values.good + (values.poor - values.good) * t
    }

    /// A tack's rudder at `handling`.
    public static func tackFraction(handling: Double) -> Double { ramp(handling, tackFraction, tackHandling) }
    /// Radians before her groove a tack's rudder eases from at `handling`.
    public static func tackEase(handling: Double) -> Double { ramp(handling, (tackEase, 0), tackHandling) }
    /// A gybe's rudder at `handling`.
    public static func gybeFraction(handling: Double) -> Double { ramp(handling, gybeFraction, gybeHandling) }
    /// The share of her turns she flubs at `handling`.
    public static func botchRate(handling: Double) -> Double {
        let deficit = 1 - handling.clamped(to: 0...1)
        return botchRate * deficit * deficit
    }
}

extension BotBrain {
    /// A tack or gybe she is steering by hand.
    struct HandTurn: Sendable, Equatable {
        /// Through the wind, or away from it through dead downwind.
        var isTack: Bool
        /// The tack she is turning onto.
        var toTack: Tack
        /// The way she turns: +1 to starboard.
        var sign: Double
        /// The rudder she holds, a share of full.
        var fraction: Double
        /// Radians before her new groove from which she eases the rudder; 0 holds it to the end.
        var ease: Double
        /// Radians past her new groove she turns (a flubbed, over-steered turn); 0 for none.
        var overSteer: Double
        /// The race clock when she put the rudder over.
        var started: Double
        /// Still bearing off to build speed first, until then (`HandTackTable.bearOff`); nil once she is turning.
        var bearOffUntil: Double?

        var isTurning: Bool { bearOffUntil == nil }
    }

    /// Clearing room before a penalty turn by hand (`clearingRoom`, #471).
    struct PenaltyClearing: Sendable, Equatable {
        /// Since when, and the heading she holds; nil before she begins.
        var since: Double?
        var heading = 0.0
        /// Done for the turns she owes now: she turns.
        var isDone = false
    }

    /// What she knows of a stall (`centresStalled`).
    struct Stall: Sendable, Equatable {
        /// Her heading and the race clock at her last decision.
        var heading: Double?
        var time = 0.0
        /// Since when she has been slow, in irons and barely turning.
        var slowSince: Double?
        /// Since when she has held the rudder centred for it; nil while she steers.
        var centredSince: Double?
    }

    /// The stream of her seed her flubbed turns are drawn from: ASCII "handturn". Only a class without the tap draws.
    static let handTurnStream: UInt64 = 0x6861_6E64_7475_726E

    /// How well she turns by hand, 0…1, for a brain sailing `weaknesses`: the handling her hand steering shows (her
    /// handling draw, #443; a profile's or stand-in's Club hand steering is Club's centre; none is 1), but Club's
    /// centre for `tacticianClubExecution` (Club-level execution, #105) and the floor of Club's band for the cautious bot.
    static func turnHandling(profile: BotProfile?, weaknesses: BotWeaknesses, caution: Caution?) -> Double {
        if caution != nil { return BotTier.club.handlingBand.lowerBound }
        if profile == .tacticianClubExecution { return BotTier.club.handling(at: 0.5) }
        guard HandSteeringTable.shiftLagScale > 0 else { return 1 }
        return (1 - weaknesses.shiftLag / HandSteeringTable.shiftLagScale).clamped(to: 0...1)
    }

    /// The rudder she turns a penalty turn with, a share of full: all of it on a class whose tap sails her turns.
    static func penaltyRudder(_ view: SeatView) -> Double { turnsByHand(view) ? HandTackTable.penaltyFraction : 1 }

    /// The rudder she turns her penalty turn on with now, a share of full, turning `turn`'s way (+1 to starboard):
    /// `penaltyRudder(view)`, but hard over inside close-hauled, luffing or head to wind, once that rudder would turn
    /// her through the wind at under `HandTackTable.penaltyCrawl`: slow there, the fall-off takes most of a part
    /// rudder's turn, and a tick of turning back gives the whole turn up (`Race.turnPenalty`; on a class without the
    /// autohelm every tick is hers).
    func penaltyRudder(_ b: SeatView.OwnBoat, _ turn: Double, _ owed: OwedPenalty, _ view: SeatView) -> Double {
        let rudder = Self.penaltyRudder(view)
        guard Self.turnsByHand(view) else { return rudder }
        let steering = view.boatClass.steering
        let closeHauled = view.boatClass.polar.bestUpwind(tws: b.polarWindSpeed).twa
        // Turning to starboard (+) luffs her with the wind over her starboard side (`relativeWind` > 0).
        let luffing = turn * b.relativeWind > 0
        // "Speed before the tack": luffing up from a reach, slow, she takes rudder off to gather way.
        let build = HandTackTable.penaltyBuild
        // Not when the turn is whole before she is head to wind: there is no tack to gather way for.
        if luffing, 2 * .pi - owed.progress > b.twa, b.twa >= closeHauled + HandTackTable.penaltyLuffMargin, b.twa < build.from,
           b.speed < closeHauledSpeed(b, view) * build.speed {
            return build.rudder
        }
        guard b.twa < closeHauled + HandTackTable.penaltyLuffMargin, luffing || b.twa < closeHauled else { return rudder }
        let rate = steering.turnRate(speed: b.speed)
        let fallOff = luffing ? steering.headToWindFallOffRate * max(0, 1 - rate / steering.topTurnRate) : 0
        return rudder * rate - fallOff < HandTackTable.penaltyCrawl ? 1 : rudder
    }

    /// Seconds a whole penalty turn takes her by hand from here, roughly: all the way round at the rate
    /// `penaltyRudder` turns her at the speed it leaves her (`HandTackTable.penaltyTurn.speed` of close-hauled, whatever
    /// she has now: the rudder's drag takes it), and `crawl` seconds more through the wind.
    func penaltyTurnSeconds(_ b: SeatView.OwnBoat, _ view: SeatView) -> Double {
        let table = HandTackTable.penaltyTurn
        let speed = closeHauledSpeed(b, view) * table.speed
        return 2 * .pi / (Self.penaltyRudder(view) * view.boatClass.steering.turnRate(speed: speed)) + table.crawl
    }

    /// Whether, on a class she turns by hand, a turn started later (put off, or given up to turn again) can still be
    /// whole by its complete deadline: `penaltyTurnSeconds` and `HandTackTable.penaltyTurn.margin` to spare. Always on
    /// a class whose tap sails her turns: its turn fits the rules' deadlines from anywhere.
    func hasTimeToTurnLater(_ owed: OwedPenalty, _ b: SeatView.OwnBoat, _ view: SeatView) -> Bool {
        guard Self.turnsByHand(view) else { return true }
        let left = Double(owed.completeDeadlineTick - view.tick) * Self.tickStep
        return left > penaltyTurnSeconds(b, view) + HandTackTable.penaltyTurn.margin
    }

    /// "Start first, then turn" (#471, the owner's ruling of 2026-10-10): called before her start, owing the one turn,
    /// with the gun so close that she can cross the line and still be the rules' 30° into her turn by its start
    /// deadline, she sails her start and turns at once after it. Exactly: the seconds until she crosses (the gun, or
    /// her run to the line from her speed now if that is later: close-hauled on her tack, and from
    /// `HandTackTable.penaltyStartFirst.late` seconds after the gun on the heading she sails) and the seconds the 30°
    /// take her there (`turnIn`) fit before the start deadline, and the same crossing, a whole turn (`penaltyTurnSeconds`
    /// less its crawl: she crosses with way on) and `spare` fit before the complete deadline. Under the rules' 20 s and
    /// 40 s that is a crossing no later than 18 s after the call in a breeze: a boat on the line at the gun, called in
    /// the last 18 s; one 5 s late to the line, in the last 13. In light or dirty air the turn's own time binds first
    /// (a turn of 28 s with its spare: a crossing 12 s after the call). Reckoned again at every decision: when her
    /// start slips past it, or she is called again, she turns where she is.
    func startsBeforeHerTurn(_ owed: OwedPenalty, _ b: SeatView.OwnBoat, _ view: SeatView) -> Bool {
        guard Self.turnsByHand(view), b.status == .prestart, owed.turnsOwed == 1 else { return false }
        let table = HandTackTable.penaltyStartFirst
        let toStart = Double(owed.startDeadlineTick - view.tick) * Self.tickStep
        let toComplete = Double(owed.completeDeadlineTick - view.tick) * Self.tickStep
        let angle = view.boatClass.polar.bestUpwind(tws: b.polarWindSpeed).twa
        let heading = view.time > table.late ? b.heading : b.windDirection + (b.tack == .starboard ? -angle : angle)
        let cross = max(-view.time, secondsToLine(b, view, heading: heading, ease: false, within: toStart))
        let speed = cross > table.turnIn ? max(b.speed, table.speed * closeHauledSpeed(b, view)) : b.speed
        let rate = Self.penaltyRudder(view) * view.boatClass.steering.turnRate(speed: speed)
        let turnIn = max(table.turnIn, 1 + Self.penaltyStartedAngle / rate)
        return cross + turnIn <= toStart
            && cross + penaltyTurnSeconds(b, view) - HandTackTable.penaltyTurn.crawl + table.spare <= toComplete
    }

    /// "Tack while she has the speed": the way (+1 to starboard) she starts a penalty turn by hand on the wind (inside
    /// `HandTackTable.penaltyTurn.luffFirstAngle`), or nil off it. With way on she luffs: bearing away first she comes
    /// to the tack last, slowed by the whole turn's rudder, and crawls through the wind. Slow, she bears away: a luff
    /// from there is that crawl at once, and the reach and the gybe give her what speed there is for the tack.
    func penaltyLuffFirst(_ b: SeatView.OwnBoat, _ view: SeatView) -> Double? {
        let table = HandTackTable.penaltyTurn
        guard Self.turnsByHand(view), b.twa < table.luffFirstAngle else { return nil }
        return penaltyBearAwayFirst(b, view).map { -$0 }
    }

    /// The way (+1 to starboard) that bears her away, for a penalty turn she starts by hand on the wind (inside
    /// `HandTackTable.penaltyTurn.luffFirstAngle`) under `luffFirstSpeed` of her close-hauled speed, or nil: this
    /// before the way a boat near her would have her turn, and the way she turns a turn she has not started (the
    /// rules' 30°) once she is luffing that slow.
    func penaltyBearAwayFirst(_ b: SeatView.OwnBoat, _ view: SeatView) -> Double? {
        let table = HandTackTable.penaltyTurn
        guard b.twa < table.luffFirstAngle, isSlowForPenaltyTurn(b, view) else { return nil }
        return b.relativeWind > 0 ? -1 : 1
    }

    /// Whether, on a class she turns by hand, she is too slow to turn a penalty turn up through the wind, or to give
    /// one up and turn it again the other way (`canGiveUpTurn`): under `HandTackTable.penaltyTurn.luffFirstSpeed` of
    /// her close-hauled speed in clear air. From a standstill head to wind the rudder turns her 3° a second.
    func isSlowForPenaltyTurn(_ b: SeatView.OwnBoat, _ view: SeatView) -> Bool {
        Self.turnsByHand(view)
            && b.speed < view.boatClass.polar.bestUpwind(tws: b.polarWindSpeed).speed * HandTackTable.penaltyTurn.luffFirstSpeed
    }

    /// Whether she turns a penalty turn on through a stall rather than let go (`centresStalled`): on a class without
    /// the autohelm a let-go head to wind falls her back the way she came, and that gives the turn up.
    func turnsPenaltyThroughStall(_ b: SeatView.OwnBoat) -> Bool { b.penalty != nil && penaltyTurn != nil }

    /// Whether her class leaves tacks and gybes to her hand: its tap sails nothing.
    static func turnsByHand(_ view: SeatView) -> Bool { !view.boatClass.steering.autohelm.sailsTap }

    /// Her close-hauled speed in the wind she has, m/s: what `canTap` measures a tack's speed against.
    func closeHauledSpeed(_ b: SeatView.OwnBoat, _ view: SeatView) -> Double {
        view.boatClass.polar.bestUpwind(tws: b.polarWindSpeed).speed * b.speedShadow
    }

    /// Starts the tack or gybe onto `aim`'s tack by hand, from `b` (`canTap` held): her rudder and how she eases it
    /// from her handling, a flub drawn from her own stream, and in light air a bear-off first.
    mutating func startHandTurn(_ b: SeatView.OwnBoat, _ aim: Aim, _ view: SeatView, fleetPlay: Bool) {
        let h = turnHandling
        let isTack = abs(sailingAngle(b)) < .pi / 2
        // Turning to starboard (+) luffs her with the wind over her starboard side.
        let luff: Double = b.boomSide == .port ? 1 : -1
        var turn = HandTurn(isTack: isTack, toTack: aim.tack, sign: isTack ? luff : -luff,
                            fraction: isTack ? HandTackTable.tackFraction(handling: h) : HandTackTable.gybeFraction(handling: h),
                            ease: isTack ? HandTackTable.tackEase(handling: h) : 0, overSteer: 0, started: view.time)
        // Before her start a gybe is for getting round, not for the lengths it saves: more rudder (#461).
        if !isTack, b.status != .racing { turn.fraction = max(turn.fraction, HandTackTable.startGybeFraction) }
        if handTurnRng.unit() < HandTackTable.botchRate(handling: h) {
            let under = handTurnRng.unit() < HandTackTable.underSteerShare
            let past = handTurnRng.range(HandTackTable.overSteer.lowerBound, HandTackTable.overSteer.upperBound)
            turn.ease = 0
            if isTack, under, b.polarWindSpeed > HandTackTable.underSteerWind, turn.fraction <= HandTackTable.underSteerFrom {
                turn.fraction = HandTackTable.underSteer
            } else {
                // A gybe is cheaper gentle, so a flubbed one is never under-steered: she cranks it past her groove.
                if !isTack { turn.fraction = HandTackTable.gybeFraction.poor }
                turn.overSteer = past
            }
        }
        let bear = HandTackTable.bearOff
        if isTack, !fleetPlay, b.status == .racing, h >= bear.handling, b.polarWindSpeed <= bear.wind,
           b.speed < closeHauledSpeed(b, view) * bear.speed {
            turn.bearOffUntil = view.time + bear.seconds
        }
        handTurn = turn
    }

    /// Her decision turning `turn` on towards `aim`, or nil once it is over (`handTurn` cleared): she is on her new
    /// groove's doorstep, the plan no longer wants that tack, or it has run out of time; then she steers as ever.
    /// Keeping clear, a mark and the race area's edge still win: looked for on the heading she is turning to, and
    /// steering for one ends the turn.
    mutating func handTurning(_ turn: HandTurn, _ aim: Aim, _ b: SeatView.OwnBoat, _ view: SeatView) -> BotDecision? {
        let longest = turn.isTack ? HandTackTable.longest.tack : HandTackTable.longest.gybe
        guard aim.tack == turn.toTack, view.time - turn.started <= longest else {
            handTurn = nil
            return nil
        }
        if let until = turn.bearOffUntil {
            guard b.tack != turn.toTack else {
                handTurn = nil
                return nil
            }
            if view.time < until {
                let own = Aim(angle: grooveAngle(.upwind, b, view) + HandTackTable.bearOff.angle, tack: b.tack)
                let desired = own.heading(wind: b.windDirection)
                guard evasion(b, view, desired: desired) == nil else {
                    handTurn = nil
                    return nil
                }
                return holding(b, view, helm(b, to: own, view), desired: desired)
            }
            guard isClearToTurn(b, view) else {
                handTurn = nil
                return nil
            }
            handTurn?.bearOffUntil = nil
            handTurn?.started = view.time
        }
        let heading = aim.heading(wind: b.windDirection)
        // Close to the gun before her start only a mark or the edge ends the turn (#461): the boats she keeps clear of
        // on this tack are not the ones she will on the other, the turn began clear of them all (`isClearToTurn`), and
        // ended head to wind she is in every boat's way with no time to turn again.
        let turnsThrough = b.status != .racing && view.time < 0 && -view.time < HandTackTable.startTurnsThroughSeconds
        if let evasion = turnsThrough ? obstacleEvasion(b, view, desired: heading) : evasion(b, view, desired: heading) {
            handTurn = nil
            lastTapTime = view.time
            let input = steer(b, toHeading: evasion.heading, view, closest: evasion.closest)
            return BotDecision(input: clearingQuarter(b, view, input.eased(evasion.dropsAstern)))
        }
        var remaining = turn.sign * wrapAngle(heading + turn.sign * turn.overSteer - b.heading)
        // Short of the boom's crossing she has the whole way round to go, however far that is.
        if b.tack != turn.toTack, remaining < 0 { remaining += 2 * .pi }
        var rudder = turn.fraction
        var end = turn.fraction * view.boatClass.steering.turnRate(speed: b.speed) * HandTackTable.leadSeconds
        if turn.ease > HandTackTable.easeEnd {
            end = max(end * HandTackTable.easedShare, HandTackTable.easeEnd)
            if remaining < turn.ease {
                let t = ((turn.ease - remaining) / (turn.ease - HandTackTable.easeEnd)).clamped(to: 0...1)
                rudder *= 1 + (HandTackTable.easedShare - 1) * t
            }
        }
        // Never before her boom is across: a gybe's crosses by the lee, a few degrees short of her new groove, and let
        // go there she would be sailed back onto the gybe she came from.
        guard remaining > end || b.tack != turn.toTack else {
            handTurn = nil
            return nil
        }
        return BotDecision(input: clearingQuarter(b, view, BoatInput(rudder: turn.sign * rudder)))
    }

    /// "Let go in irons": whether she holds the rudder truly centred now, stalled short of head to wind
    /// (`HandTackTable.stall`). The class's irons recovery (#458) falls her off only on a centred rudder; a held one,
    /// hers through a turn or her hand's holding an angle (`BotHelm`), keeps her there. She steers again once she has
    /// steerage or is out of the no-go zone; owing a penalty turn she has not begun, only with steerage (or after
    /// `stallWait`). A penalty turn she is turning she never lets go (`turnsPenaltyThroughStall`, #461).
    mutating func centresStalled(_ b: SeatView.OwnBoat, _ view: SeatView) -> Bool {
        let stalled = HandTackTable.stall
        let last = stall
        stall.heading = b.heading
        stall.time = view.time
        let groove = closeHauledSpeed(b, view)
        let inIrons = b.twa < BoatDynamics.noGoAngle(view.boatClass.polar) + stalled.margin
        if let since = last.centredSince {
            let hasSteerage = b.speed >= groove * stalled.steerage
            let out = b.penalty == nil ? !inIrons : view.time - since >= HandTackTable.stallWait
            guard !hasSteerage, !out else {
                stall.centredSince = nil
                stall.slowSince = nil
                return false
            }
            return true
        }
        let dt = view.time - last.time
        let turning = last.heading.map { dt > 0 ? abs(wrapAngle(b.heading - $0)) / dt : .infinity } ?? .infinity
        guard inIrons, b.speed < groove * stalled.slow, turning < stalled.turnRate else {
            stall.slowSince = nil
            return false
        }
        let since = last.slowSince ?? view.time
        stall.slowSince = since
        guard view.time - since >= stalled.seconds else { return false }
        stall.centredSince = view.time
        return true
    }
}
