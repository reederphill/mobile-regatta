import Foundation
import RegattaCore

/// A live bot's named start strategies (#276): from T−45 she chooses how she will start, from the situation and her
/// style, remembers it, and sails its plan to the gun. Internal: nothing is shown to a player, no notice, cue or UI, and
/// nothing she does telegraphs the choice beyond the boat's own course ("Bots sail like real sailors").
///
/// - `starboardHold`: today's plan (`starboardHoldAim`, `BotBrain+Start.swift`), unchanged: the fallback, always
///   feasible, and every bot-suite profile's and the cautious bot's only plan.
/// - `boatEnd`: "starboard boat-end" (owner G1′): her end is the committee end and its front row has room; she holds
///   below and to the right of the committee boat until about T−7, then hovers up to the line with Ease, the one wait
///   allowed under her tacking speed, and goes at the gun.
/// - `outAndInReaching`: "the reaching out-and-in" (owner G2′): on port, she reaches out away from the line, tacks at
///   her turn time and reaches back in to her spot at full speed.
/// - `vanderbilt`: "the Vanderbilt start" (owner G2′): on port, she broad-reaches out away from the line, gybes at her
///   turn time, hauls up and comes back to her spot close-hauled at full speed.
///
/// Whatever her plan, she reads the favoured end late (`readEndLate`, "read the end late", owner G4): the bias early in
/// the sequence points at the wrong end more often than not (the #276 brief, §4). Crowding, holes and lanes read every
/// boat in her view by position and motion only (#531): nothing assumes a person's boat gives way. She never slows,
/// queues or keeps her distance to avoid a foul ("no orderly bots").
enum StartStrategy: String, Hashable, Sendable, CaseIterable {
    case starboardHold
    case boatEnd
    case outAndInReaching
    case vanderbilt

    /// The two out-and-ins.
    var isOutAndIn: Bool { self == .outAndInReaching || self == .vanderbilt }
}

/// Why a remembered start strategy is dropped and chosen again (`chooseStartStrategy`): her plan's trigger fails.
enum StartStrategyAbort: Hashable, Sendable {
    /// `starboardHold`, her first choice: from `lateEndReadSeconds`, her late read puts her end at the committee boat
    /// and the boat end is in reach (`isFeasible(.boatEnd)`).
    case endReadLate
    /// `starboardHold`, her first choice: on port, an out-and-in's round trip now fits the race area below her and the
    /// time left (`isFeasible`), and it scores above today's plan. At T−45 most of the fleet is still on port on its way
    /// to its set-up point, deep, where the round trip doesn't fit yet; on the way it comes to.
    case roundTripFits
    /// `boatEnd`: her end, read late, is no longer the committee end (`boatEndLeave`), before she has left for the
    /// boat: once there, she starts there.
    case endNotHers
    /// `boatEnd`: before her hover, the committee end's front row holds more than `boatEndCrowd` boats.
    case crowded
    /// An out-and-in, before her turn: turning now she would still reach the line `outAndInLateSeconds` late.
    case roundTripShort
    /// An out-and-in, before her turn: she is on starboard, off her out leg (a boat she kept clear of, or a tack begun
    /// before she chose it).
    case offHerOutLeg
}

/// The start strategy she chose and when, by the race clock (`BotBrain.startStrategy`), and the abort that last
/// re-chose it, if any.
struct StartChoice: Hashable, Sendable {
    var plan: StartStrategy
    var time: Double
    var abort: StartStrategyAbort?
}

/// How far into her plan she is (`BotBrain.startPlan`), set as she sails it and cleared at each choice.
struct StartPlanProgress: Hashable, Sendable {
    /// An out-and-in: she has begun her turn for the in leg.
    var turning = false
    /// An out-and-in: she is on her in leg, on starboard since her turn.
    var turned = false
    /// `boatEnd`: she has left for her hold point below the committee boat.
    var leftForTheBoat = false
}

extension BotBrain {
    // MARK: - The chooser's weights ("the reasons as weights": placeholders for #389)

    /// "Slow at the gun": score a second lost against a full-speed arrival (`secondsLostAtTheGun`).
    static let slowAtTheGun = -0.45
    /// "Easy to barge": score a front-row boat within `bargeLengths` along of where she waits.
    static let easyToBarge = -0.3
    /// "Can't tack waiting": score for a plan whose wait is under her tacking speed (`canTap`'s floor).
    static let cantTackWaiting = -0.5
    /// "Every extra length of route is lateness" (#532): score a hull length her plan's spot lies along the line from
    /// her own.
    static let routeLength = -0.2
    /// "Start at the favoured end": score a hull length of the line's bias at her plan's spot, read through her misread
    /// (`BotWeaknesses.lineBiasMisread`) ...
    static let lineBias = 0.15
    /// ... of which she trusts this share before `lateEndReadSeconds`: the bias at T−30 is anti-correlated with the gun's.
    static let earlyBiasTrust = 0.2
    /// "Crowd at her end": score a front-row boat in her plan's spot's third of the line.
    static let crowdAtHerEnd = -0.25
    /// "Where she is": score a second of her way to her plan's set-up (`secondsToSetUp`), beside each plan's trigger.
    static let whereSheIs = -0.02
    /// "The wind": score a second of timing margin her plan needs in her wind (`timingMargin`).
    static let wind = -0.2
    /// Her style's say: her preference draw for a plan (`BotStyle.boatEndDraw` …) times this.
    static let stylePreference = 0.5

    // MARK: - When she chooses and reads

    /// Seconds before the gun from which she chooses her start strategy.
    static let chooseFromSeconds = 45.0
    /// Seconds before the gun from which she reads the favoured end (`readEndLate`), and trusts the bias in full.
    static let lateEndReadSeconds = 15.0
    /// The angle off the wind, with Ease, whose rate along the line is how far her late end read may move her spot
    /// pinward in the time left (`lateEndReach`): sliding along the line.
    static let endReadPinAngle = deg2rad(80)

    // MARK: - Shared reads

    /// Hull lengths below the line a boat is in the front row.
    static let frontRowLengths = 3.0
    /// Hull lengths along the line either side of where she waits that a front-row boat may barge her.
    static let bargeLengths = 3.0
    /// True wind, knots, of the gusty conditions' strength range, where her timing allows `gustyMargin` more seconds.
    static let gustyKnots = 14.0...20.0
    static let gustyMargin = 2.0
    /// Seconds lost against a full-speed twin, going from a hover eased at the hold 1.5 L below the line, by true wind
    /// in knots (the #276 brief's physics table, skiff@9): a plan that waits eased (`secondsLostAtTheGun`).
    static let hoverSecondsLost: [(knots: Double, seconds: Double)] = [(6, 2.50), (10, 2.07), (14, 1.93), (20, 2.03)]

    /// Before her start (`plan`): a live bot's chosen strategy's aim (`chooseStartStrategy`, at each of her decisions),
    /// after her late read of the favoured end; every other bot's today's plan.
    mutating func startAim(_ b: SeatView.OwnBoat, _ view: SeatView) -> Aim {
        guard isLive else { return starboardHoldAim(b, view) }
        readEndLate(b, view)
        if let plan = startStrategy?.plan, plan.isOutAndIn, ProcessInfo.processInfo.environment["T276_DBG"] != nil,
           (view.time * 10).rounded().truncatingRemainder(dividingBy: 10) == 0 {
            let line = view.course.startLine
            let L = view.boatClass.hull.length
            let along = (b.position - line.pin.position).dot(Self.lineDirection(line)) / line.length
            print(String(format: "DBGR seat %d t %5.1f %@ ang %6.1f ease %d depth %5.2f along %5.2f spd %4.2f turning %d turned %d spot %.2f near %d",
                         view.seat, view.time, b.tack == .port ? "P" : "S", rad2deg(sailingAngle(b)), b.ease ? 1 : 0, -line.side(b.position) / L,
                         along, b.speed / closeHauledSpeed(b, view), startPlan.turning ? 1 : 0, startPlan.turned ? 1 : 0, spotOnLine,
                         view.others.filter { ($0.position - b.position).length < 3 * L }.count))
        }
        switch startStrategy?.plan {
        case .starboardHold, nil:
            return starboardHoldAim(b, view)
        case .boatEnd:
            return boatEndAim(b, view)
        case .outAndInReaching, .vanderbilt:
            return outAndInAim(startStrategy?.plan ?? .outAndInReaching, b, view)
        }
    }

    // MARK: - The late end read

    /// "Read the end late" (#276, G4): from `lateEndReadSeconds` before the gun she reads the line's bias as the tactician
    /// does (`readLineBias`) and moves her spot from her style's (`styleSpotOnLine`) towards the favoured end,
    /// `favouredEndShift` of the line a degree, within what she still reaches (`lateEndReach`); a reach she has had
    /// stands as the time runs down. Every live bot but the tactician, who reads it throughout (`favouredEndSpot`).
    mutating func readEndLate(_ b: SeatView.OwnBoat, _ view: SeatView) {
        guard !tactics.startsAtFavouredEnd, b.status == .prestart, view.time < 0,
              -view.time <= Self.lateEndReadSeconds else { return }
        let base = styleSpotOnLine
        let asked = Self.favouredEndShift * rad2deg(lineBiasSine(b, view))
        let had = (lateEndSpot ?? base) - base
        let reach = lateEndReach(b, view, base: base, pinward: asked < 0)
        let shift = asked < 0 ? max(asked, -max(reach, had < 0 ? -had : 0)) : min(asked, max(reach, had > 0 ? had : 0))
        lateEndSpot = min(max(base + shift, Self.favouredEndInset), 1 - Self.favouredEndInset)
        lateEndAsk = (base, asked)
    }

    /// How far along the line, as a share of it, her spot may move from `base` late: pinward, what she reaches with Ease
    /// at `endReadPinAngle` in the time left (on starboard she slides that way as she waits); towards the committee boat,
    /// no further than where her hold course meets the line, as she can't fetch further up it without going round.
    func lateEndReach(_ b: SeatView.OwnBoat, _ view: SeatView, base: Double, pinward: Bool) -> Double {
        let line = view.course.startLine
        if pinward {
            let eased = BoatDynamics.polarTarget(relativeWind: Self.endReadPinAngle, boomSide: .port, tws: b.polarWindSpeed,
                                                 isPlaning: false, spinnaker: .down, boatClass: view.boatClass)
                * b.speedShadow * view.easeSpeedFraction
            return eased * Vec2.heading(Self.endReadPinAngle).x * -view.time / max(line.length, 1)
        }
        let course = Vec2.heading(b.windDirection - Self.holdAngle(view))
        let rate = line.courseSideRate(course)
        let depth = -line.side(b.position)
        guard rate > 0.05, depth > 0 else { return 0 }
        let along = (line.committee.position - line.pin.position).normalized
        let landing = (b.position + course * (depth / rate) - line.pin.position).dot(along) / max(line.length, 1)
        return max(0, landing - base)
    }

    /// The sine of the line's bias as she reads it (`readLineBias`): positive when the committee end lies up the wind.
    func lineBiasSine(_ b: SeatView.OwnBoat, _ view: SeatView) -> Double {
        let line = view.course.startLine
        return (line.committee.position - line.pin.position).normalized.dot(Vec2.heading(senses.direction ?? b.windDirection))
    }

    /// Her end as she reads it late (`readEndLate`): her style's spot moved by the whole shift the bias asked, before her
    /// reach caps it; before the read, her spot (`spotOnLine`).
    var endAsRead: Double {
        guard favouredEndSpot == nil, let ask = lateEndAsk else { return spotOnLine }
        return ask.styleSpot + ask.shift
    }

    // MARK: - The chooser

    /// A live bot's every decision (`sail`): one choice at her first decision from `chooseFromSeconds` before the gun, or
    /// at a takeover's first decision if later, remembered (`startStrategy`) and chosen again only on a named abort
    /// (`abort`), never back to the plan it left: with nothing remembered she would flip between plans as #532's plan
    /// chatter did. Before the gun only.
    mutating func chooseStartStrategy(_ b: SeatView.OwnBoat, _ view: SeatView) {
        guard b.status == .prestart, view.time < 0, -view.time <= Self.chooseFromSeconds else { return }
        guard let choice = startStrategy else {
            startStrategy = StartChoice(plan: bestStartStrategy(b, view, leaving: nil), time: view.time)
            startPlan = StartPlanProgress()
            return
        }
        guard let abort = abort(choice, b, view) else { return }
        startStrategy = StartChoice(plan: bestStartStrategy(b, view, leaving: choice.plan), time: view.time, abort: abort)
        startPlan = StartPlanProgress()
        startStrategySwitches += 1
    }

    /// The feasible plan with the highest score (`startStrategyScore`); a tie, or nothing better, `starboardHold`.
    /// Leaving a plan, never back to it: leaving `starboardHold`, the best of the others feasible, and `starboardHold`
    /// again only if none is.
    func bestStartStrategy(_ b: SeatView.OwnBoat, _ view: SeatView, leaving: StartStrategy?) -> StartStrategy {
        var best: (plan: StartStrategy, score: Double)? = leaving == .starboardHold
            ? nil : (.starboardHold, startStrategyScore(.starboardHold, b, view))
        for plan in StartStrategy.allCases where plan != .starboardHold && plan != leaving && isFeasible(plan, b, view) {
            let score = startStrategyScore(plan, b, view)
            if score > best?.score ?? -.infinity { best = (plan, score) }
        }
        return best?.plan ?? .starboardHold
    }

    /// Her plan's trigger (`whereSheIs`'s gates): `starboardHold` always; `boatEnd` while her end is the committee end,
    /// its front row has room and she reaches her hold point below the committee boat in time; an out-and-in while she is
    /// on port with clear water and room for its round trip in the time left (`outAndInPlan`).
    func isFeasible(_ plan: StartStrategy, _ b: SeatView.OwnBoat, _ view: SeatView) -> Bool {
        switch plan {
        case .starboardHold: return true
        case .boatEnd:
            return endAsRead >= Self.boatEndEnd && committeeEndCrowd(b, view) <= Self.boatEndCrowd
                && secondsToSail(b, to: boatEndHoldPoint(view)) <= -view.time - Self.boatEndHoverSeconds + Self.boatEndLateSeconds
        case .outAndInReaching, .vanderbilt:
            if plan == .outAndInReaching {
                let line = view.course.startLine
                let along = (b.position - line.pin.position).dot(Self.lineDirection(line)) / max(line.length, 1)
                guard abs(along - spotOnLine) * line.length <= Self.reachingSpotLengths * view.boatClass.hull.length else { return false }
            }
            guard handTurn == nil, startArrival(view) <= Self.outAndInLongest, let trip = outAndInPlan(plan, b, view),
                  trip.outSeconds >= Self.outAndInShortestOut, !trip.capped else { return false }
            return outLegIsClear(b, view, outSeconds: trip.outSeconds, plan: plan)
        }
    }

    /// The named abort that drops her remembered plan, if its trigger has failed (`StartStrategyAbort`).
    func abort(_ choice: StartChoice, _ b: SeatView.OwnBoat, _ view: SeatView) -> StartStrategyAbort? {
        switch choice.plan {
        case .starboardHold:
            guard choice.abort == nil else { return nil }
            if -view.time <= Self.lateEndReadSeconds, -view.time > Self.boatEndHoverSeconds, let ask = lateEndAsk, ask.shift > 0,
               isFeasible(.boatEnd, b, view) {
                return .endReadLate
            }
            guard b.tack == .port else { return nil }
            let hold = startStrategyScore(.starboardHold, b, view)
            let fits = StartStrategy.allCases.contains { plan in
                plan.isOutAndIn && isFeasible(plan, b, view) && startStrategyScore(plan, b, view) > hold
            }
            return fits ? .roundTripFits : nil
        case .boatEnd:
            if !startPlan.leftForTheBoat, endAsRead < Self.boatEndLeave { return .endNotHers }
            if -view.time > Self.boatEndHoverSeconds, committeeEndCrowd(b, view) > Self.boatEndCrowd { return .crowded }
            return nil
        case .outAndInReaching, .vanderbilt:
            if !startPlan.turning, b.tack == .starboard, handTurn == nil { return .offHerOutLeg }
            guard !startPlan.turning, !startPlan.turned, b.tack == .port,
                  let trip = outAndInPlan(choice.plan, b, view), trip.lateBy > Self.outAndInLateSeconds else { return nil }
            return .roundTripShort
        }
    }

    /// `score(s) = Σ weight × feature(s) + style`: the reasons for and against each plan, each a named weight.
    func startStrategyScore(_ plan: StartStrategy, _ b: SeatView.OwnBoat, _ view: SeatView) -> Double {
        let line = view.course.startLine
        let length = view.boatClass.hull.length
        let spot = planSpot(plan, b, view)
        let point = line.pin.position + (line.committee.position - line.pin.position) * spot
        let trust = -view.time <= Self.lateEndReadSeconds ? 1 : Self.earlyBiasTrust
        let misread = weaknesses.lineBiasMisread * style.lineBiasDraw
        let biasLengths = (spot - 0.5) * line.length * sin(asin(lineBiasSine(b, view).clamped(to: -1...1)) + misread) / length
        var score = Self.slowAtTheGun * secondsLostAtTheGun(plan, b)
        score += Self.cantTackWaiting * (plan.isOutAndIn ? 0 : 1)
        if !plan.isOutAndIn {
            score += Self.easyToBarge
                * Double(frontRow(b, view) { abs(($0 - point).dot(Self.lineDirection(line))) <= Self.bargeLengths * length })
        }
        score += Self.routeLength * abs(spot - spotOnLine) * line.length / length
        score += Self.lineBias * trust * biasLengths
        score += Self.crowdAtHerEnd * Double(frontRow(b, view) { Self.third(of: line, $0) == Self.third(spot) })
        score += Self.whereSheIs * secondsToSetUp(plan, b, view)
        score += Self.wind * timingMargin(plan, b)
        score += Self.stylePreference * preference(plan)
        return score
    }

    /// Her plan's spot on the line, 0 the pin … 1 the committee boat: her own, but at the boat end.
    func planSpot(_ plan: StartStrategy, _ b: SeatView.OwnBoat, _ view: SeatView) -> Double {
        plan == .boatEnd ? boatEndSpot(view) : spotOnLine
    }

    /// Seconds lost at the gun against a full-speed arrival, in her wind (the #276 brief's physics): a plan that waits
    /// eased goes from there (`hoverSecondsLost`); the reaching out-and-in arrives at full speed; the Vanderbilt
    /// `vanderbiltSecondsLost`, hauling up from the gybe.
    func secondsLostAtTheGun(_ plan: StartStrategy, _ b: SeatView.OwnBoat) -> Double {
        switch plan {
        case .starboardHold, .boatEnd: return Self.interpolated(Self.hoverSecondsLost, knots: knots(metresPerSecond: b.polarWindSpeed))
        case .outAndInReaching: return 0
        case .vanderbilt: return Self.vanderbiltSecondsLost
        }
    }

    /// Seconds of her way to her plan's set-up: the boat end's hold point; the others start from where she is.
    func secondsToSetUp(_ plan: StartStrategy, _ b: SeatView.OwnBoat, _ view: SeatView) -> Double {
        plan == .boatEnd ? min(secondsToSail(b, to: boatEndHoldPoint(view)), Self.timingHorizon) : 0
    }

    /// Seconds of timing margin her plan needs in her wind: `gustyMargin` in the gusty range for every plan but today's,
    /// where a puff carries her early to the line or a lull leaves her short.
    func timingMargin(_ plan: StartStrategy, _ b: SeatView.OwnBoat) -> Double {
        guard plan != .starboardHold else { return 0 }
        return Self.gustyKnots.contains(knots(metresPerSecond: b.polarWindSpeed)) ? Self.gustyMargin : 0
    }

    /// Her style's preference for a plan over the plain hold.
    func preference(_ plan: StartStrategy) -> Double {
        switch plan {
        case .starboardHold: return 0
        case .boatEnd: return style.boatEndDraw
        case .outAndInReaching: return style.outAndInReachingDraw
        case .vanderbilt: return style.vanderbiltDraw
        }
    }

    /// Front-row boats (no more than `frontRowLengths` below the line, not over it) whose position passes `where`: every
    /// boat in her view by position, people's boats as bots' (#531).
    func frontRow(_ b: SeatView.OwnBoat, _ view: SeatView, where test: (Vec2) -> Bool) -> Int {
        let line = view.course.startLine
        let deepest = view.boatClass.hull.length * Self.frontRowLengths
        return view.others.filter { other in
            let depth = -line.side(other.position)
            return !other.isGhost && depth >= 0 && depth <= deepest && test(other.position)
        }.count
    }

    /// Front-row boats within `boatEndCrowdLengths` of the committee boat.
    func committeeEndCrowd(_ b: SeatView.OwnBoat, _ view: SeatView) -> Int {
        let committee = view.course.startLine.committee.position
        let range = view.boatClass.hull.length * Self.boatEndCrowdLengths
        return frontRow(b, view) { ($0 - committee).length <= range }
    }

    static func lineDirection(_ line: CourseLayout.Line) -> Vec2 { (line.committee.position - line.pin.position).normalized }

    /// The third of the line a point lies off (0 the pin's … 2 the committee boat's), and a spot's.
    static func third(of line: CourseLayout.Line, _ p: Vec2) -> Int {
        third((p - line.pin.position).dot(lineDirection(line)) / max(line.length, 1))
    }

    static func third(_ spot: Double) -> Int { min(max(Int(spot * 3), 0), 2) }

    /// A table by true wind in knots, interpolated, held at its ends.
    static func interpolated(_ table: [(knots: Double, seconds: Double)], knots: Double) -> Double {
        guard let upper = table.firstIndex(where: { $0.knots >= knots }) else { return table.last?.seconds ?? 0 }
        guard upper > 0 else { return table[0].seconds }
        let (low, high) = (table[upper - 1], table[upper])
        return low.seconds + (high.seconds - low.seconds) * (knots - low.knots) / (high.knots - low.knots)
    }

    // MARK: - boatEnd

    /// Her end as she reads it at least this far towards the committee boat (0 the pin … 1) makes the committee end hers ...
    static let boatEndEnd = 0.7
    /// ... and read late below this, it no longer is (`StartStrategyAbort.endNotHers`): short of `boatEndEnd`, so a
    /// degree or two of bias doesn't flip her plan.
    static let boatEndLeave = 0.55
    /// More front-row boats than this within `boatEndCrowdLengths` of the committee boat and the end has no room.
    static let boatEndCrowd = 2
    static let boatEndCrowdLengths = 3.0
    /// Seconds before the gun from which she hovers up to the line (owner G1′, "until about T−7") ...
    static let boatEndHoverSeconds = 7.0
    /// ... and seconds after that by which she may still reach her hold point and choose the boat end.
    static let boatEndLateSeconds = 3.0
    /// Her hold point (`boatEndHoldPoint`): hull lengths right of the committee boat along the line's extension, and
    /// below the line: the eased hover climbs about 0.3 L a second, so from there it reaches the line at the gun.
    static let boatEndHoldRightLengths = 0.5
    static let boatEndHoldDepthLengths = 2.5
    /// Within this many hull lengths of her hold point she is at it.
    static let boatEndAtHoldLengths = 1.5
    /// Hull lengths in from the committee boat her boat-end spot lies along the line.
    static let boatEndSpotLengths = 1.2
    /// Seconds more than her sail to her hold point she leaves for it, or as soon as she is this many hull lengths from
    /// it: today's plan would sail her on past it to its set-up point.
    static let boatEndSetupMargin = 5.0
    static let boatEndNearLengths = 4.0
    /// Early at the boat end she bears away to this, with Ease, on starboard, and lets the time run: a broad reach, not
    /// a run, so the swing back up to her hold never carries her through a gybe by hand.
    static let boatEndBearAwayAngle = deg2rad(130)

    /// Her boat-end spot on the line (0 the pin … 1): `boatEndSpotLengths` in from the committee boat.
    func boatEndSpot(_ view: SeatView) -> Double {
        let line = view.course.startLine
        return max(0.5, 1 - view.boatClass.hull.length * Self.boatEndSpotLengths / max(line.length, 1))
    }

    /// Where she holds before her hover: below and to the right of the committee boat (owner G1′).
    func boatEndHoldPoint(_ view: SeatView) -> Vec2 {
        let c = view.course
        let line = c.startLine
        let length = view.boatClass.hull.length
        return line.committee.position + Self.lineDirection(line) * (length * Self.boatEndHoldRightLengths)
            - c.upwind * (length * Self.boatEndHoldDepthLengths)
    }

    /// "Starboard boat-end" (#276, owner G1′): she sails today's plan until it is time to leave for her hold point below
    /// and to the right of the committee boat (`boatEndHoldPoint`), sails there and waits there, slow, until about T−7
    /// (`boatEndHoverSeconds`); then hovers up to the line with Ease and goes at the gun (`boatEndHover`).
    mutating func boatEndAim(_ b: SeatView.OwnBoat, _ view: SeatView) -> Aim {
        guard view.time < 0, b.status == .prestart else { return starboardHoldAim(b, view) }
        let length = view.boatClass.hull.length
        let holdPoint = boatEndHoldPoint(view)
        let toHover = -view.time - Self.boatEndHoverSeconds
        if toHover <= 0 {
            return b.tack == .starboard && isAtTheBoat(b, view) ? boatEndHover(b, view) : starboardHoldAim(b, view)
        }
        if !startPlan.leftForTheBoat {
            guard secondsToSail(b, to: holdPoint) + Self.boatEndSetupMargin >= toHover
                    || (holdPoint - b.position).length <= length * Self.boatEndNearLengths else { return starboardHoldAim(b, view) }
            startPlan.leftForTheBoat = true
        }
        let hold = Self.holdAngle(view)
        guard (holdPoint - b.position).length <= length * Self.boatEndAtHoldLengths else {
            return navigate(b, to: holdPoint, view)
        }
        // At her hold point early she waits there on starboard, slow, with Ease: up at her hold angle while below it,
        // off the wind (`boatEndBearAwayAngle`) once above it. The hover goes from about here.
        let line = view.course.startLine
        let above = -line.side(b.position) < -line.side(holdPoint)
        if b.tack == .starboard, !above, boatEndHoldingIsLate(b, view) { return boatEndHover(b, view) }
        return Aim(angle: above ? Self.boatEndBearAwayAngle : hold, tack: .starboard, tolerance: Self.approachTolerance, ease: true)
    }

    /// Whether, at her hold point, hovering up with Ease from here already takes the time left (`boatEndHover`'s
    /// reckoning): then she hovers now.
    func boatEndHoldingIsLate(_ b: SeatView.OwnBoat, _ view: SeatView) -> Bool {
        let hold = Self.holdAngle(view)
        let arrival = startArrival(view)
        return secondsToLine(b, view, angle: hold, ease: true, within: arrival) + turnUpSeconds(b, view, to: hold) >= arrival
    }

    /// The hover at the boat end (owner G1′: from about T−7, close to the committee boat, the one wait allowed under her
    /// tacking speed): on today's reckoning (`secondsToLine`, which counts her acceleration from the hover's speed) she
    /// sheets in and goes close-hauled once that brings her to the line only as the gun goes; while holding with Ease at
    /// her hold angle would, she holds there; and while even that would be early, she bears away with Ease
    /// (`boatEndBearAwayAngle`) and lets the time run, off the wind rather than along the line, so she stays at the boat end.
    func boatEndHover(_ b: SeatView.OwnBoat, _ view: SeatView) -> Aim {
        let hold = Self.holdAngle(view)
        let arrival = startArrival(view)
        let go = Aim(angle: max(grooveAngle(.upwind, b, view), hold), tack: .starboard, tolerance: Self.approachTolerance)
        let run = secondsToLine(b, view, angle: go.angle, ease: false, within: arrival) + turnUpSeconds(b, view, to: go.angle)
        let needed = run + max(0, run - Self.clearRunSeconds) * Self.trafficAllowance
        if needed >= arrival - (b.ease ? 0 : Self.goHysteresis) { return go }
        let holdAim = Aim(angle: hold, tack: .starboard, tolerance: Self.approachTolerance, ease: true)
        if secondsToLine(b, view, angle: hold, ease: true, within: arrival) + turnUpSeconds(b, view, to: hold) >= arrival {
            return holdAim
        }
        return Aim(angle: Self.boatEndBearAwayAngle, tack: .starboard, tolerance: Self.approachTolerance, ease: true)
    }

    /// Whether she is at the boat end for her hover: below the line no deeper than her hold point and a length, and
    /// along the line from her hold point's side of the committee boat to `bargeLengths` in from it.
    func isAtTheBoat(_ b: SeatView.OwnBoat, _ view: SeatView) -> Bool {
        let line = view.course.startLine
        let length = view.boatClass.hull.length
        let below = -line.side(b.position)
        let inFromBoat = line.length - (b.position - line.pin.position).dot(Self.lineDirection(line))
        return below > 0 && below <= length * (Self.boatEndHoldDepthLengths + 1)
            && inFromBoat >= -length * (Self.boatEndHoldRightLengths + Self.boatEndAtHoldLengths)
            && inFromBoat <= length * Self.bargeLengths
    }

    // MARK: - The out-and-ins

    /// Her sailing angle on port out away from the line: the reaching out-and-in's beam reach, the Vanderbilt's broad
    /// reach (owner G2′).
    static let reachingOutAngle = deg2rad(120)
    static let vanderbiltOutAngle = deg2rad(130)
    /// The Vanderbilt's aim on starboard through her gybe: the broad reach she gybes onto before she hauls up.
    static let vanderbiltGybeAngle = deg2rad(140)
    /// The reaching out-and-in luffs on port to below this sailing angle before she tacks, a tack, never a gybe, with
    /// her reach's way on: at `tackingSpeed` and `reachingTackSpeedMargin` more she tacks; slower, she builds it on a
    /// close reach (`reachingBuildAngle`) first.
    static let reachingTackFrom = deg2rad(88)
    static let reachingTackSpeedMargin = 1.1
    static let reachingBuildAngle = deg2rad(75)
    /// The Vanderbilt bears away on port to this before her gybe, and her gybe's room is reckoned at its speed.
    static let vanderbiltGybeFrom = deg2rad(165)
    /// Hull lengths along the line from her spot she may be to choose the reaching out-and-in: out and back, it keeps
    /// her spot.
    static let reachingSpotLengths = 5.0
    /// Seconds her turn costs her against sailing straight in from where she turns, by true wind in knots: the reaching
    /// out-and-in's luff and tack, the Vanderbilt's gybe and haul-up from the broad reach to close-hauled (skiff@9 by
    /// hand, `eachStrategyReachesTheLineAtTheGun`).
    static let reachingTurnSeconds: [(knots: Double, seconds: Double)] = [(6, 9.5), (10, 8.5), (14, 8.0), (20, 8.0)]
    static let vanderbiltTurnSeconds: [(knots: Double, seconds: Double)] = [(6, 8.0), (10, 7.0), (14, 6.5), (20, 6.5)]
    /// Seconds the Vanderbilt loses at the gun against a full-speed arrival: she hauls up from the gybe and beats in.
    static let vanderbiltSecondsLost = 0.3
    /// The latest arrival, seconds, for which she chooses an out-and-in, and the shortest out leg it may have.
    static let outAndInLongest = 50.0
    static let outAndInShortestOut = 3.0
    /// Turning now, this many seconds late and her round trip no longer fits (`StartStrategyAbort.roundTripShort`).
    static let outAndInLateSeconds = 3.0
    /// Hull lengths her out leg keeps clear of every starboard boat, now and halfway out by its motion (#531), to choose
    /// an out-and-in; and of the race area's sides at her turn.
    static let outLegClearLengths = 3.0
    static let outLegRoomLengths = 3.0
    /// The Vanderbilt gybes at her turn: there the race area leaves her room to leeward for it (`gybeRoom`, as
    /// `hasGybeRoom` asks of it) and this many hull lengths more.
    static let gybeRoomMarginLengths = 0.5
    /// Hull lengths in from the pin her beat in must land on the line, at least.
    static let outAndInPinClearLengths = 2.0
    /// The broadest her spot may bear on starboard, sailing in.
    static let runInBroadest = deg2rad(100)
    /// Running in early, she foots: this much broader than her spot bears, sheeted in, while that is on time ...
    static let footAngle = deg2rad(40)
    static let footStep = deg2rad(5)
    /// ... and seconds early from which she does.
    static let footEarlySeconds = 0.0

    /// An out-and-in's round trip from where she is (`outAndInPlan`): seconds to sail on out before she turns, whether the
    /// race area's room cut her out leg short (`capped`), and seconds late she reaches the line turning now (`lateBy`).
    struct OutAndInTrip {
        var outSeconds: Double
        var capped: Bool
        var lateBy: Double
    }

    /// Her round trip, on port: out at her plan's angle (`reachingOutAngle`, `vanderbiltOutAngle`) at her polar's speed,
    /// a second at a time, to the first turn point from which her turn (`turnSeconds`) and her run in to her spot, at the
    /// angle it bears there sheeted in (no closer to the wind than close-hauled), take the time left; no further than the
    /// race area leaves her room below and beside her (`maxHoldDepth`, `outLegRoomLengths`). Nil where her spot bears
    /// behind her on starboard: she is not on its approach.
    func outAndInPlan(_ plan: StartStrategy, _ b: SeatView.OwnBoat, _ view: SeatView) -> OutAndInTrip? {
        guard b.tack == .port, b.status == .prestart, view.time < 0 else { return nil }
        let c = view.course
        let length = view.boatClass.hull.length
        let polar = view.boatClass.polar
        let tws = b.polarWindSpeed
        let arrival = startArrival(view)
        let angle = plan == .vanderbilt ? Self.vanderbiltOutAngle : Self.reachingOutAngle
        let out = Vec2.heading(b.windDirection + angle) * polar.speed(twa: angle, tws: tws) * b.speedShadow
        let cost = turnSeconds(plan, b)
        let groove = grooveAngle(.upwind, b, view)
        let spot = startPoint(c)
        let vmg = max(polar.bestUpwind(tws: tws).vmg * b.speedShadow, 0.3)
        let line = c.startLine
        let closeHauled = Vec2.heading(b.windDirection - groove)
        func runIn(from p: Vec2) -> Double? {
            let toSpot = spot - p
            let bearing = wrapAngle(b.windDirection - toSpot.bearing)
            guard bearing <= Self.runInBroadest else { return nil }
            guard bearing <= groove else { return toSpot.length / max(polar.speed(twa: bearing, tws: tws) * b.speedShadow, 0.3) }
            // Her spot closer to the wind than close-hauled: she beats in to the line, landing to leeward of it, clear
            // of the pin end.
            let depth = max(-line.side(p), 0)
            let rate = line.courseSideRate(closeHauled)
            guard rate > 0.05 else { return nil }
            let landing = (p + closeHauled * (depth / rate) - line.pin.position).dot(Self.lineDirection(line))
            guard landing > length * Self.outAndInPinClearLengths else { return nil }
            return depth / vmg
        }
        // Turning now: from where she is her run in may not land clear of the pin yet; out on port it opens.
        if let now = runIn(from: b.position), now + cost >= arrival {
            return OutAndInTrip(outSeconds: 0, capped: false, lateBy: now + cost - arrival)
        }
        var t = 1.0
        while t < arrival {
            let p = b.position + out * t
            let depth = -c.startLine.side(p)
            let leeward = plan == .vanderbilt ? length * (Self.gybeRoom.hullLengths + Self.gybeRoomMarginLengths)
                + polar.speed(twa: Self.vanderbiltGybeFrom, tws: tws) * b.speedShadow * Self.gybeRoom.seconds : 0
            if depth > maxHoldDepth(view, at: p) || c.raceArea.inset(p) < length * Self.outLegRoomLengths
                || !c.isInRaceArea(p - Vec2.heading(b.windDirection) * leeward) {
                return OutAndInTrip(outSeconds: t - 1, capped: true, lateBy: 0)
            }
            if let back = runIn(from: p), t + cost + back >= arrival { return OutAndInTrip(outSeconds: t, capped: false, lateBy: 0) }
            t += 1
        }
        return OutAndInTrip(outSeconds: t, capped: true, lateBy: 0)
    }

    /// Seconds her plan's turn costs her in her wind (`reachingTurnSeconds`, `vanderbiltTurnSeconds`).
    func turnSeconds(_ plan: StartStrategy, _ b: SeatView.OwnBoat) -> Double {
        Self.interpolated(plan == .vanderbilt ? Self.vanderbiltTurnSeconds : Self.reachingTurnSeconds,
                          knots: knots(metresPerSecond: b.polarWindSpeed))
    }

    /// Whether her out leg is clear water: no starboard boat within `outLegClearLengths` of it, where it is now and where
    /// its motion puts it halfway out (#531: by motion only).
    func outLegIsClear(_ b: SeatView.OwnBoat, _ view: SeatView, outSeconds: Double, plan: StartStrategy) -> Bool {
        let angle = plan == .vanderbilt ? Self.vanderbiltOutAngle : Self.reachingOutAngle
        let speed = view.boatClass.polar.speed(twa: angle, tws: b.polarWindSpeed) * b.speedShadow
        let end = b.position + Vec2.heading(b.windDirection + angle) * speed * outSeconds
        let clear = view.boatClass.hull.length * Self.outLegClearLengths
        func distance(_ p: Vec2) -> Double {
            let leg = end - b.position
            let t = leg.lengthSquared > 1e-6 ? ((p - b.position).dot(leg) / leg.lengthSquared).clamped(to: 0...1) : 0
            return (b.position + leg * t - p).length
        }
        return !view.others.contains { other in
            !other.isGhost && other.tack == .starboard
                && min(distance(other.position), distance(other.position + other.velocity * (outSeconds / 2))) < clear
        }
    }

    /// "The reaching out-and-in" and "the Vanderbilt start" (#276, owner G2′): on port she sails out at her plan's angle,
    /// sheeted in, until her turn time (`outAndInPlan`); the reaching one luffs and tacks, the Vanderbilt gybes onto a
    /// starboard broad reach; on starboard she runs in (`outAndInRunIn`). Back on port after her turn (a boat she kept
    /// clear of), today's plan takes her in.
    mutating func outAndInAim(_ plan: StartStrategy, _ b: SeatView.OwnBoat, _ view: SeatView) -> Aim {
        guard view.time < 0, b.status == .prestart else { return starboardHoldAim(b, view) }
        if b.tack == .starboard, startPlan.turning { startPlan.turned = true }
        if startPlan.turned { return b.tack == .starboard ? outAndInRunIn(b, view) : starboardHoldAim(b, view) }
        if b.tack == .starboard, !startPlan.turning { return starboardHoldAim(b, view) }
        if !startPlan.turning {
            let window = Double(BotDriver.decisionInterval) / Double(Race.tickRate)
            if let trip = outAndInPlan(plan, b, view), trip.outSeconds > window / 2 {
                let angle = plan == .vanderbilt ? Self.vanderbiltOutAngle : Self.reachingOutAngle
                return Aim(angle: angle, tack: .port, tolerance: Self.approachTolerance)
            }
            startPlan.turning = true
        }
        if plan == .vanderbilt {
            if abs(sailingAngle(b)) < Self.vanderbiltGybeFrom - Self.approachTolerance {
                return Aim(angle: Self.vanderbiltGybeFrom, tack: .port, tolerance: Self.approachTolerance)
            }
            return Aim(angle: Self.vanderbiltGybeAngle, tack: .starboard, tolerance: Self.approachTolerance)
        }
        let groove = grooveAngle(.upwind, b, view)
        if b.speed < closeHauledSpeed(b, view) * Self.tackingSpeed * Self.reachingTackSpeedMargin {
            return Aim(angle: Self.reachingBuildAngle, tack: .port, tolerance: Self.approachTolerance)
        }
        if abs(sailingAngle(b)) > Self.reachingTackFrom { return Aim(angle: Self.reachingTackFrom - Self.approachTolerance, tack: .port, tolerance: Self.approachTolerance) }
        return Aim(angle: groove, tack: .starboard, tolerance: Self.approachTolerance)
    }

    /// Her run in on starboard after an out-and-in's turn: sheeted in at her spot (no closer to the wind than
    /// close-hauled, so to leeward of it if it bears closer; clear of the pin end) once that brings her to the line only as the gun goes; early, she foots, as
    /// much as `footAngle` broader, sheeted in, keeping her speed rather than easing; later, she goes. Further early than
    /// footing takes up, her spot behind her or the pin end to windward, today's plan holds or sails round
    /// (`starboardHoldAim`).
    mutating func outAndInRunIn(_ b: SeatView.OwnBoat, _ view: SeatView) -> Aim {
        let line = view.course.startLine
        guard Self.hullDepth(b.position, heading: b.heading, line, view.boatClass) > 0 else { return starboardHoldAim(b, view) }
        let hold = Self.holdAngle(view)
        let arrival = startArrival(view)
        let spot = startPoint(view.course)
        let bearing = wrapAngle(b.windDirection - (spot - b.position).bearing)
        let pinEnd = line.pin.position + Self.lineDirection(line) * view.boatClass.hull.length
        let toPin = wrapAngle(b.windDirection - (pinEnd - b.position).bearing)
        guard bearing <= .pi / 2 + Self.waitOffLine, toPin >= hold else { return starboardHoldAim(b, view) }
        let angle = max(min(max(bearing, grooveAngle(.upwind, b, view)), toPin), hold)
        func run(_ angle: Double) -> Double {
            secondsToLine(b, view, angle: angle, ease: false, within: arrival) + turnUpSeconds(b, view, to: angle)
        }
        if run(angle) >= arrival - Self.footEarlySeconds {
            return Aim(angle: angle, tack: .starboard, tolerance: Self.approachTolerance)
        }
        // Early: she foots, sheeted in, keeping her speed, the least that brings her on time; then she eases at her spot.
        let broadest = max(min(angle + Self.footAngle, toPin, .pi / 2), angle)
        var foot = angle + Self.footStep
        while foot <= broadest {
            if run(foot) >= arrival - Self.footEarlySeconds { return Aim(angle: foot, tack: .starboard, tolerance: Self.approachTolerance) }
            foot += Self.footStep
        }
        if secondsToLine(b, view, angle: angle, ease: true, within: arrival) + turnUpSeconds(b, view, to: angle)
            >= arrival - Self.footEarlySeconds {
            return Aim(angle: angle, tack: .starboard, tolerance: Self.approachTolerance, ease: true)
        }
        // Earlier still, she waits as today's plan does, with Ease at her hold angle, while that is not early.
        if secondsToLine(b, view, angle: hold, ease: true, within: arrival) + turnUpSeconds(b, view, to: hold) >= arrival {
            return Aim(angle: hold, tack: .starboard, tolerance: Self.approachTolerance, ease: true)
        }
        return starboardHoldAim(b, view)
    }
}
