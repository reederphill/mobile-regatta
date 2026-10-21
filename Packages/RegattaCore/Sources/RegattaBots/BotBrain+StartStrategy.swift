import Foundation
import RegattaCore

/// A live bot's named start strategies (#276): from T−45 she chooses how she will start, from the situation and her
/// style, remembers it, and sails its plan to the gun. Internal: nothing is shown to a player, no notice, cue or UI, and
/// nothing she does telegraphs the choice beyond the boat's own course ("Bots sail like real sailors").
///
/// - `starboardHold`: today's plan (`starboardHoldAim`, `BotBrain+Start.swift`), unchanged: the fallback, always
///   feasible, and every bot-suite profile's and the cautious bot's only plan.
/// - `boatEnd`: "starboard boat-end": her end is the committee end and its front row has room; she sets up below the
///   committee boat by T−20 and from then hovers with Ease at her hold angle down to the line on today's reckoning.
///
/// Whatever her plan, she reads the favoured end late (`readEndLate`, "read the end late"): the bias early in the
/// sequence points at the wrong end more often than not (the #276 brief, §4). Crowding, holes and lanes read every boat
/// in her view by position and motion only (#531): nothing assumes a person's boat gives way. She never slows, queues or
/// keeps her distance to avoid a foul ("no orderly bots").
enum StartStrategy: String, Hashable, Sendable, CaseIterable {
    case starboardHold
    case boatEnd
}

/// Why a remembered start strategy is dropped and chosen again (`chooseStartStrategy`): her plan's trigger fails.
enum StartStrategyAbort: Hashable, Sendable {
    /// `boatEnd`: her spot, read late, is no longer at the committee end (`boatEndLeave`).
    case endNotHers
    /// `boatEnd`: before her hover, the committee end's front row holds more than `boatEndCrowd` boats.
    case crowded
}

/// The start strategy she chose and when, by the race clock (`BotBrain.startStrategy`), and the abort that last
/// re-chose it, if any.
struct StartChoice: Hashable, Sendable {
    var plan: StartStrategy
    var time: Double
    var abort: StartStrategyAbort?
    /// `boatEnd`: she has left for her set-up point below the committee boat (`boatEndAim`).
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
    /// "Every extra length of route is lateness" (#532): score a hull length of route beyond her direct line to her spot.
    static let routeLength = -0.2
    /// "Start at the favoured end": score a hull length of the line's bias at her plan's spot, read through her misread
    /// (`BotWeaknesses.lineBiasMisread`) ...
    static let lineBias = 0.15
    /// ... of which she trusts this share before `lateEndReadSeconds`: the bias at T−30 is anti-correlated with the gun's.
    static let earlyBiasTrust = 0.2
    /// "Crowd at her end": score a front-row boat in her plan's spot's third of the line.
    static let crowdAtHerEnd = -0.25
    /// "Where she is": score a second of her approach to her plan's spot (`secondsToSpot`), beside each plan's trigger.
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

    // MARK: - boatEnd

    /// Her spot at least this far towards the committee boat (0 the pin … 1) makes the committee end hers ...
    static let boatEndEnd = 0.65
    /// ... and read late below this, it no longer is (`StartStrategyAbort.endNotHers`): short of `boatEndEnd`, so a
    /// degree or two of bias doesn't flip her plan.
    static let boatEndLeave = 0.55
    /// More front-row boats than this within `boatEndCrowdLengths` of the committee boat and the end has no room.
    static let boatEndCrowd = 2
    static let boatEndCrowdLengths = 3.0
    /// Hull lengths in from the committee boat her boat-end spot lies along the line, at least.
    static let boatEndSpotLengths = 1.5
    /// Hull lengths of the committee boat along the line within which she hovers (G1).
    static let boatEndHoverLengths = 3.0
    /// Seconds before the gun from which she hovers at the boat (owner, G1).
    static let boatEndHoverSeconds = 20.0
    /// Hull lengths in from the committee boat of her set-up point (`boatEndPlan`), seconds of her hover she leaves for
    /// her run in, and seconds more than her sail there she leaves for it.
    static let boatEndSetupInLengths = 0.5
    static let boatEndGoSeconds = 4.0
    static let boatEndSetupMargin = 5.0
    /// Seconds lost against a full-speed twin, going from a hover eased at the hold 1.5 L below the line, by true wind
    /// in knots (the #276 brief's physics table, skiff@9): `secondsLostAtTheGun` interpolates.
    static let hoverSecondsLost: [(knots: Double, seconds: Double)] = [(6, 2.50), (10, 2.07), (14, 1.93), (20, 2.03)]

    // MARK: - Shared reads

    /// Hull lengths below the line a boat is in the front row.
    static let frontRowLengths = 3.0
    /// Hull lengths along the line either side of where she waits that a front-row boat may barge her.
    static let bargeLengths = 3.0
    /// True wind, knots, of the gusty conditions' strength range, where her timing allows `gustyMargin` more seconds.
    static let gustyKnots = 14.0...20.0
    static let gustyMargin = 2.0

    /// Before her start (`plan`): a live bot's chosen strategy's aim; every other bot's today's plan.
    mutating func startAim(_ b: SeatView.OwnBoat, _ view: SeatView) -> Aim {
        guard isLive else { return starboardHoldAim(b, view) }
        readLineBias(b, view)
        readEndLate(b, view)
        chooseStartStrategy(b, view)
        switch startStrategy?.plan {
        case .boatEnd:
            return boatEndAim(b, view)
        case .starboardHold, nil:
            strategySpot = nil
            return starboardHoldAim(b, view)
        }
    }

    // MARK: - The late end read

    /// "Read the end late" (#276, G4): from `lateEndReadSeconds` before the gun she reads the line's bias as the tactician
    /// does (`readLineBias`) and moves her spot towards the favoured end, `favouredEndShift` of the line a degree, within
    /// what her plan still reaches (`lateEndReach`); a reach she has had stands as the time runs down. Her misread moves
    /// the spot she starts from. Every live bot but the tactician, who reads it throughout (`favouredEndSpot`).
    mutating func readEndLate(_ b: SeatView.OwnBoat, _ view: SeatView) {
        guard favouredEndSpot == nil, b.status == .prestart, view.time < 0, -view.time <= Self.lateEndReadSeconds else { return }
        let base = styleSpotOnLine
        let asked = Self.favouredEndShift * rad2deg(lineBiasSine(b, view))
        let had = (lateEndSpot ?? base) - base
        let reach = lateEndReach(b, view, base: base, pinward: asked < 0)
        let shift = asked < 0 ? max(asked, -max(reach, had < 0 ? -had : 0)) : min(asked, max(reach, had > 0 ? had : 0))
        lateEndSpot = min(max(base + shift, Self.favouredEndInset), 1 - Self.favouredEndInset)
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
            return eased * sin(Self.endReadPinAngle) * -view.time / max(line.length, 1)
        }
        let course = Vec2.heading(b.windDirection - Self.holdAngle(view))
        let rate = line.courseSideRate(course)
        let depth = -line.side(b.position)
        guard rate > 0.05, depth > 0 else { return 0 }
        let landing = (b.position + course * (depth / rate) - line.pin.position).dot(Self.lineDirection(line)) / max(line.length, 1)
        return max(0, landing - base)
    }

    /// The sine of the line's bias as she reads it (`readLineBias`): positive when the committee end lies up the wind.
    func lineBiasSine(_ b: SeatView.OwnBoat, _ view: SeatView) -> Double {
        let line = view.course.startLine
        return (line.committee.position - line.pin.position).normalized.dot(Vec2.heading(senses.direction ?? b.windDirection))
    }

    // MARK: - The chooser

    /// One choice from `chooseFromSeconds` before the gun, or at a takeover's first decision if later, remembered
    /// (`startStrategy`) and chosen again only on a named abort (`abort`), never back to the plan it left: with nothing
    /// remembered she would flip between plans as #532's plan chatter did. Before the gun only.
    mutating func chooseStartStrategy(_ b: SeatView.OwnBoat, _ view: SeatView) {
        guard b.status == .prestart, view.time < 0, -view.time <= Self.chooseFromSeconds else { return }
        guard let choice = startStrategy else {
            startStrategy = StartChoice(plan: bestStartStrategy(b, view, leaving: nil), time: view.time)
            return
        }
        guard let abort = abort(choice.plan, b, view) else { return }
        startStrategy = StartChoice(plan: bestStartStrategy(b, view, leaving: choice.plan), time: view.time, abort: abort)
        startStrategySwitches += 1
    }

    /// The feasible plan with the highest score (`startStrategyScore`); a tie, or nothing better, `starboardHold`.
    func bestStartStrategy(_ b: SeatView.OwnBoat, _ view: SeatView, leaving: StartStrategy?) -> StartStrategy {
        var best = (plan: StartStrategy.starboardHold, score: startStrategyScore(.starboardHold, b, view))
        for plan in StartStrategy.allCases where plan != .starboardHold && plan != leaving && isFeasible(plan, b, view) {
            let score = startStrategyScore(plan, b, view)
            if score > best.score { best = (plan, score) }
        }
        return best.plan
    }

    /// Her plan's trigger (`whereSheIs`'s gates): `starboardHold` always; `boatEnd` while her end is the committee end
    /// and its front row has room.
    func isFeasible(_ plan: StartStrategy, _ b: SeatView.OwnBoat, _ view: SeatView) -> Bool {
        switch plan {
        case .starboardHold: return true
        case .boatEnd: return spotOnLine >= Self.boatEndEnd && committeeEndCrowd(b, view) <= Self.boatEndCrowd
        }
    }

    /// The named abort that drops her remembered `plan`, if its trigger has failed: `boatEnd` once her end, read late,
    /// is no longer the committee end, or before her hover once its front row is crowded.
    func abort(_ plan: StartStrategy, _ b: SeatView.OwnBoat, _ view: SeatView) -> StartStrategyAbort? {
        switch plan {
        case .starboardHold: return nil
        case .boatEnd:
            if spotOnLine < Self.boatEndLeave { return .endNotHers }
            if -view.time > Self.boatEndHoverSeconds, committeeEndCrowd(b, view) > Self.boatEndCrowd { return .crowded }
            return nil
        }
    }

    /// `score(s) = Σ weight × feature(s) + style`: the reasons for and against each plan, each a named weight.
    func startStrategyScore(_ plan: StartStrategy, _ b: SeatView.OwnBoat, _ view: SeatView) -> Double {
        let line = view.course.startLine
        let length = view.boatClass.hull.length
        let spot = planSpot(plan, b, view)
        let point = line.pin.position + (line.committee.position - line.pin.position) * spot
        let own = line.pin.position + (line.committee.position - line.pin.position) * spotOnLine
        let trust = -view.time <= Self.lateEndReadSeconds ? 1 : Self.earlyBiasTrust
        let misread = weaknesses.lineBiasMisread * style.lineBiasDraw
        let biasLengths = (spot - 0.5) * line.length * sin(asin(lineBiasSine(b, view).clamped(to: -1...1)) + misread) / length
        let extraRoute = max(0, (point - b.position).length - (own - b.position).length) / length
        var probe = self
        probe.strategySpot = spot
        var score = Self.slowAtTheGun * secondsLostAtTheGun(plan, b)
        score += Self.cantTackWaiting * (waitsUnderTappingSpeed(plan) ? 1 : 0)
        score += Self.easyToBarge * Double(frontRow(b, view) { abs(($0 - point).dot(Self.lineDirection(line))) <= Self.bargeLengths * length })
        score += Self.routeLength * extraRoute
        score += Self.lineBias * trust * biasLengths
        score += Self.crowdAtHerEnd * Double(frontRow(b, view) { Self.third(of: line, $0) == Self.third(spot) })
        score += Self.whereSheIs * min(probe.secondsToSpot(b, view, hold: Self.holdAngle(view)), Self.timingHorizon)
        score += Self.wind * timingMargin(plan, b)
        score += Self.stylePreference * preference(plan)
        return score
    }

    /// Her plan's spot on the line, 0 the pin … 1 the committee boat.
    func planSpot(_ plan: StartStrategy, _ b: SeatView.OwnBoat, _ view: SeatView) -> Double {
        switch plan {
        case .starboardHold: return spotOnLine
        case .boatEnd: return boatEndPlan(b, view).spot
        }
    }

    /// Seconds lost at the gun against a full-speed arrival, in her wind: both plans wait eased at the hold and go from
    /// there (the #276 brief's physics, `hoverSecondsLost`).
    func secondsLostAtTheGun(_ plan: StartStrategy, _ b: SeatView.OwnBoat) -> Double {
        let knots = b.polarWindSpeed / 0.514444
        let table = Self.hoverSecondsLost
        guard let upper = table.firstIndex(where: { $0.knots >= knots }) else { return table.last?.seconds ?? 0 }
        guard upper > 0 else { return table[0].seconds }
        let (low, high) = (table[upper - 1], table[upper])
        return low.seconds + (high.seconds - low.seconds) * (knots - low.knots) / (high.knots - low.knots)
    }

    /// Whether her plan waits slower than she can tack from (`canTap`'s floor): both of today's plans wait eased.
    func waitsUnderTappingSpeed(_ plan: StartStrategy) -> Bool {
        switch plan {
        case .starboardHold, .boatEnd: return true
        }
    }

    /// Seconds of timing margin her plan needs in her wind: the hover at the boat end `gustyMargin` in the gusty range,
    /// where a puff carries her up to the line.
    func timingMargin(_ plan: StartStrategy, _ b: SeatView.OwnBoat) -> Double {
        switch plan {
        case .starboardHold: return 0
        case .boatEnd: return Self.gustyKnots.contains(b.polarWindSpeed / 0.514444) ? Self.gustyMargin : 0
        }
    }

    /// Her style's preference for a plan over the plain hold.
    func preference(_ plan: StartStrategy) -> Double {
        switch plan {
        case .starboardHold: return 0
        case .boatEnd: return style.boatEndDraw
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

    // MARK: - boatEnd

    /// Her set-up point for the boat end and her spot there: `boatEndSetupInLengths` in from the committee boat, just
    /// below and to leeward of it, not beyond it, as deep as holding with Ease from there takes her hover
    /// (`boatEndHoverSeconds`, less `boatEndGoSeconds` for her run in), within the race area's room (`maxHoldDepth`); her
    /// spot `boatEndSpotLengths` in from the boat.
    func boatEndPlan(_ b: SeatView.OwnBoat, _ view: SeatView) -> (setup: Vec2, depth: Double, spot: Double) {
        let c = view.course
        let line = c.startLine
        let length = view.boatClass.hull.length
        let hold = Self.holdAngle(view)
        let eased = BoatDynamics.polarTarget(relativeWind: hold, boomSide: .port, tws: b.polarWindSpeed, isPlaning: false,
                                             spinnaker: .down, boatClass: view.boatClass) * b.speedShadow * view.easeSpeedFraction
        let climb = eased * max(Vec2.heading(b.windDirection - hold).dot(c.upwind), 0.3)
        let depth = min(max(climb * (Self.boatEndHoverSeconds - Self.boatEndGoSeconds), length * 2),
                        max(maxHoldDepth(view, at: line.committee.position), length * 2))
        let setup = line.committee.position - Self.lineDirection(line) * (length * Self.boatEndSetupInLengths) - c.upwind * depth
        return (setup, depth, max(0.5, 1 - length * Self.boatEndSpotLengths / max(line.length, 1)))
    }

    /// "Starboard boat-end" (#276): before her hover she sails for her set-up point below the committee boat
    /// (`boatEndPlan`) in time to be there as it starts (`boatEndHoverSeconds`), and keeps to it once on her way; until
    /// then she waits on today's plan (`starboardHoldAim`, to her boat-end spot). At the boat she hovers (`boatEndHover`).
    /// Anywhere else she sails today's plan to her boat-end spot.
    mutating func boatEndAim(_ b: SeatView.OwnBoat, _ view: SeatView) -> Aim {
        let plan = boatEndPlan(b, view)
        strategySpot = plan.spot
        guard view.time < 0, b.status == .prestart else { return starboardHoldAim(b, view) }
        if b.tack == .starboard, -view.time <= Self.boatEndHoverSeconds, isAtTheBoat(b, view, depth: plan.depth) {
            return boatEndHover(b, view)
        }
        let toHover = -view.time - Self.boatEndHoverSeconds
        guard toHover > 0 else { return starboardHoldAim(b, view) }
        if startStrategy?.leftForTheBoat != true {
            guard secondsToSail(b, to: plan.setup) + Self.boatEndSetupMargin >= toHover else { return starboardHoldAim(b, view) }
            startStrategy?.leftForTheBoat = true
        }
        // There early, she holds there with Ease, as today's plan holds.
        if b.tack == .starboard, (plan.setup - b.position).length <= view.boatClass.hull.length {
            return Aim(angle: Self.holdAngle(view), tack: .starboard, tolerance: Self.approachTolerance, ease: true)
        }
        return navigate(b, to: plan.setup, view)
    }

    /// The hover at the boat end (G1: from `boatEndHoverSeconds` before the gun, close to the committee boat, the one wait
    /// allowed under her tacking speed): on today's reckoning (`secondsToLine`, which counts her acceleration from the
    /// hover's speed) she sheets in and goes close-hauled once that brings her to the line only as the gun goes; while
    /// holding with Ease at her hold angle would, she holds there; and while even that would be early, she bears away
    /// with Ease (`deepWaitAngle`) and lets the time run, down the wind rather than along the line, so she stays at the
    /// boat end.
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
        return Aim(angle: Self.deepWaitAngle, tack: .starboard, tolerance: Self.approachTolerance, ease: true)
    }

    /// Whether she is at the boat end for her hover: below the line no deeper than her set-up point and a length, not
    /// beyond the committee boat, and within `boatEndHoverLengths` of it along the line.
    func isAtTheBoat(_ b: SeatView.OwnBoat, _ view: SeatView, depth: Double) -> Bool {
        let line = view.course.startLine
        let length = view.boatClass.hull.length
        let below = -line.side(b.position)
        let inFromBoat = line.length - (b.position - line.pin.position).dot(Self.lineDirection(line))
        return below > 0 && below <= depth + length && inFromBoat >= 0 && inFromBoat <= length * Self.boatEndHoverLengths
    }
}
