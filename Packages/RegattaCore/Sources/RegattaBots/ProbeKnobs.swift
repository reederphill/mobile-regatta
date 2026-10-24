import Foundation
import RegattaCore

/// A measurement probe (#591 stage 4's cheap test, owner note 2026-10-24), never shipped: the keep-clear constants read
/// from the environment, their shipped values when unset, so one build sails every setting. #591 stage 4 makes the ones
/// that matter `BotTunables` properly.
enum ProbeKnobs {
    static func double(_ name: String) -> Double? {
        ProcessInfo.processInfo.environment[name].flatMap(Double.init)
    }

    static let keepClearDistance = double("KC_DISTANCE") ?? 1.3
    static let keepClearMargin = double("KC_MARGIN") ?? 1.2
    static let thinMarginCost = double("KC_THIN_COST") ?? 1.0
    static let lookaheadSlope = double("KC_SLOPE") ?? 2
    static let plannerOn = (double("KC_PLANNER") ?? 1) != 0
}

extension ProbeKnobs {
    /// #591 step 3: the keep-clear judges read the other boat on her measured motion (`predictedTrack`, `.measured`)
    /// rather than a straight line.
    static let curved = (double("KC_CURVED") ?? 0) != 0
}

extension BotBrain {
    /// Probe (#591 step 3): where `other` goes over `lookahead` seconds on her measured motion (turn rate rolled on for
    /// `measuredTurnSeconds`, acceleration toward the polar), every `keepClearPredictionStep`; nil when the probe
    /// sails straight lines (`ProbeKnobs.curved` off).
    func projectedTrack(of other: SeatView.OtherBoat, lookahead: Double, _ view: SeatView) -> [Vec2]? {
        guard ProbeKnobs.curved else { return nil }
        let steps = max(1, Int((lookahead / Self.keepClearPredictionStep).rounded(.up)))
        return predictedTrack(of: other, .measured, view, steps: steps)
    }

    /// `closestApproach` against `track` (`projectedTrack`) if there is one: her straight course at `speed` against
    /// each step of the other's, closest between the steps; else the straight line.
    static func approach(of other: SeatView.OtherBoat, track: [Vec2]?, to b: SeatView.OwnBoat, heading: Double,
                         speed: Double? = nil, lookahead: Double) -> Double {
        guard let track else { return closestApproach(of: other, to: b, heading: heading, speed: speed, lookahead: lookahead) }
        let dt = keepClearPredictionStep
        let mine = Vec2.heading(heading) * (speed ?? b.speed)
        var theirs = other.position, ours = b.position
        var closest = (theirs - ours).length
        for (k, next) in track.enumerated() {
            let t = Double(k) * dt
            guard t < lookahead else { break }
            let step = min(dt, lookahead - t)
            let relative = (next - theirs) * (1 / dt) - mine
            closest = min(closest, closestApproach(offset: theirs - ours, relativeVelocity: relative, lookahead: step))
            theirs = next
            ours = ours + mine * dt
        }
        return closest
    }

    /// `approach` on `other`'s projected track, made here.
    func approach(of other: SeatView.OtherBoat, to b: SeatView.OwnBoat, heading: Double, speed: Double? = nil,
                  lookahead: Double, _ view: SeatView) -> Double {
        Self.approach(of: other, track: projectedTrack(of: other, lookahead: lookahead, view), to: b, heading: heading,
                      speed: speed, lookahead: lookahead)
    }
}
