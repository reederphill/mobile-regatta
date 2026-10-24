import Foundation

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
