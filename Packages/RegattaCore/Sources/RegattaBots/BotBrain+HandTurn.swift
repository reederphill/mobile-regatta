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
    /// Seconds at most she waits, centred, for steerage to turn a penalty on.
    public static let stallWait = 8.0

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

    /// Whether her class leaves tacks and gybes to her hand: its tap sails nothing.
    static func turnsByHand(_ view: SeatView) -> Bool { !view.boatClass.steering.autohelm.sailsTap }

    /// Her close-hauled speed in the wind she has, m/s: what `canTap` measures a tack's speed against.
    private func closeHauledSpeed(_ b: SeatView.OwnBoat, _ view: SeatView) -> Double {
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
        if let evasion = evasion(b, view, desired: heading) {
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
    /// steerage or is out of the no-go zone; owing a penalty turn, whose rudder would take her straight back into the
    /// wind, only with steerage (or after `stallWait`). A centred rudder turns no penalty back (`Race.turnPenalty`).
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
