import Foundation
import RegattaCore

/// A live bot's named start strategies (#276): from T−45 she chooses how she will start, remembers it, and sails its
/// plan to the gun. Internal: nothing is shown to a player, no notice, cue or UI, and nothing she does telegraphs the
/// choice beyond the boat's own course ("Bots sail like real sailors").
///
/// - `starboardHold`: today's plan (`starboardHoldAim`, `BotBrain+Start.swift`), unchanged: the fallback, always
///   feasible, and every bot-suite profile's and the cautious bot's only plan. So far the only strategy: the chooser
///   is the frame the alternatives (PR 3 on) join, each with its trigger and its reasons.
///
/// Whatever her plan, she reads the favoured end late (`readEndLate`, "read the end late", owner G4): the bias early in
/// the sequence points at the wrong end more often than not (the #276 brief, §4).
enum StartStrategy: String, Hashable, Sendable, CaseIterable {
    case starboardHold
}

/// The start strategy she chose and when, by the race clock (`BotBrain.startStrategy`).
struct StartChoice: Hashable, Sendable {
    var plan: StartStrategy
    var time: Double
}

extension BotBrain {
    /// Seconds before the gun from which she chooses her start strategy.
    static let chooseFromSeconds = 45.0
    /// Seconds before the gun from which she reads the favoured end (`readEndLate`).
    static let lateEndReadSeconds = 15.0
    /// The angle off the wind, with Ease, whose rate along the line is how far her late end read may move her spot
    /// pinward in the time left (`lateEndReach`): sliding along the line.
    static let endReadPinAngle = deg2rad(80)

    /// Before her start (`plan`): a live bot's chosen strategy's aim (`chooseStartStrategy`, at each of her decisions),
    /// after her late read of the favoured end; every other bot's today's plan.
    mutating func startAim(_ b: SeatView.OwnBoat, _ view: SeatView) -> Aim {
        guard isLive else { return starboardHoldAim(b, view) }
        readEndLate(b, view)
        planStart(b, view)
        switch startStrategy?.plan {
        case .starboardHold, nil:
            return starboardHoldAim(b, view)
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

    // MARK: - The chooser

    /// A live bot's every decision (`sail`): one choice at her first decision from `chooseFromSeconds` before the gun, or
    /// at a takeover's first decision if later, remembered (`startStrategy`) and chosen again only once her plan's
    /// trigger fails (`isFeasible`), never back to the plan it left: with nothing remembered she would flip between plans
    /// as #532's plan chatter did. Before the gun only.
    mutating func chooseStartStrategy(_ b: SeatView.OwnBoat, _ view: SeatView) {
        guard b.status == .prestart, view.time < 0, -view.time <= Self.chooseFromSeconds else { return }
        guard let choice = startStrategy else {
            startStrategy = StartChoice(plan: bestStartStrategy(b, view, leaving: nil), time: view.time)
            return
        }
        guard !isFeasible(choice.plan, b, view) else { return }
        startStrategy = StartChoice(plan: bestStartStrategy(b, view, leaving: choice.plan), time: view.time)
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

    /// Whether her plan's trigger holds: `starboardHold` always.
    func isFeasible(_ plan: StartStrategy, _ b: SeatView.OwnBoat, _ view: SeatView) -> Bool {
        switch plan {
        case .starboardHold: return true
        }
    }

    /// Her reasons for a plan over the others, scored (the weights arrive with the first alternative, PR 3):
    /// `starboardHold` is the baseline, 0.
    func startStrategyScore(_ plan: StartStrategy, _ b: SeatView.OwnBoat, _ view: SeatView) -> Double {
        switch plan {
        case .starboardHold: return 0
        }
    }
}
