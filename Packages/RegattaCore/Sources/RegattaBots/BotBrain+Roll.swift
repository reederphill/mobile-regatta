import RegattaCore

/// Her roll tacks (#222, #263): the second tack/gybe tap through a tack, which the class times on the boom crossing
/// (`BoatClass.RollTackTuning`). She sends it exactly as a player does. Whether it hits is her skill's
/// (`BotWeaknesses.rollHitRate`, #102), drawn from her own stream as she taps the tack; below `rollSkillFloor` she
/// never rolls. Internal heuristics, never shown to a player:
///
/// - "Roll on the crossing": a hit is timed on the boom coming across, at her first decision after it.
/// - "Rolled too soon": a miss early, at her first decision after the tack's tap, long before the boom crosses.
/// - "Rolled too late": a miss late, once the boom has been across `lateRollDelay`, and only while she is still well
///   short of close-hauled (`lateRollMargin`), so it can never land after her tack and start another one. Past that
///   she lets the roll go.
extension BotBrain {
    /// How she will time the roll of the tack she has just tapped.
    enum RollPlan: Sendable, Equatable {
        case onTheCrossing
        case tooSoon
        case tooLate
    }

    /// Seconds after the boom crosses that she rolls too late: well outside any class's window.
    static let lateRollDelay = 0.4
    /// She rolls too late only this far short of close-hauled (`closeHauled`), radians, or not at all.
    static let lateRollMargin = deg2rad(10)
    /// Seconds after tapping a tack that a roll she hasn't sent is dropped: the tack is long over.
    static let rollPlanLifetime = 6.0

    /// Draws how she rolls the tack she taps now from `b`, or none: a class without a roll tack, a gybe, or a skill
    /// below the floor.
    mutating func planRoll(_ b: SeatView.OwnBoat, _ view: SeatView) {
        rollPlan = nil
        guard view.boatClass.rollTack != nil, style.skill >= BotWeaknesses.rollSkillFloor,
              abs(sailingAngle(b)) < .pi / 2 else { return }
        let plan: RollPlan = rng.unit() < weaknesses.rollHitRate ? .onTheCrossing : (rng.bool() ? .tooSoon : .tooLate)
        rollPlan = (plan, view.time)
    }

    /// Whether she sends her roll tap with this decision (`planRoll`); once sent, or past its chance, the plan is gone.
    mutating func rollsNow(_ b: SeatView.OwnBoat, _ view: SeatView) -> Bool {
        guard let (plan, tapped) = rollPlan else { return false }
        guard b.isOnCourse, b.penalty == nil, view.time - tapped <= Self.rollPlanLifetime else {
            rollPlan = nil
            return false
        }
        let crossed = senses.tackCrossedAt.map { $0 > tapped } ?? false
        let rolls: Bool
        switch plan {
        case .tooSoon:
            // Her first decision after the tap, while the autohelm is still sailing her up to head to wind.
            guard !crossed, b.autohelm?.isTapping == true else {
                rollPlan = nil
                return false
            }
            rolls = true
        case .onTheCrossing:
            guard crossed else { return false }
            rolls = senses.tacking && senses.tackCrossedAt == view.time
        case .tooLate:
            guard crossed, let at = senses.tackCrossedAt else { return false }
            guard view.time - at >= Self.lateRollDelay else { return false }
            rolls = senses.tacking && b.twa < Self.closeHauled(b.polarWindSpeed, view) - Self.lateRollMargin
        }
        rollPlan = nil
        return rolls
    }
}
