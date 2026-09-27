/// A boat's owed penalty turns as the HUD shows them (G4, #89; #114 draws it): how many she owes, and the
/// current turn's two deadlines and progress. Read off her penalty state (`Boat.penaltyTurnsOwed`,
/// `penaltyProgress`, `penaltyClockTick`) and the rules' penalty, so a client computes it from the world it
/// predicts as the server does (`Race.owedPenalty(ofSeat:)`).
public struct OwedPenalty: Sendable, Equatable {
    /// Penalty turns she owes, the current one included.
    public let turnsOwed: Int
    /// The tick by which the current turn must be started (turned `startedTurn`), or she is disqualified.
    public let startDeadlineTick: Int
    /// The tick by which the current turn must be completed, or she is disqualified.
    public let completeDeadlineTick: Int
    /// Radians turned in the current turn, whichever way she turns it: a full turn (2π) serves it.
    public let progress: Double
    /// Whether the current turn is started: turned at least the rules' `startedTurn` (30°).
    public let isStarted: Bool

    public init(turnsOwed: Int, startDeadlineTick: Int, completeDeadlineTick: Int, progress: Double, isStarted: Bool) {
        self.turnsOwed = turnsOwed
        self.startDeadlineTick = startDeadlineTick
        self.completeDeadlineTick = completeDeadlineTick
        self.progress = progress
        self.isStarted = isStarted
    }

    /// `boat`'s owed penalty under `penalty`, or nil while she owes none.
    public init?(_ boat: Boat, penalty: RulesConfig.Penalty) {
        guard boat.penaltyTurnsOwed > 0, let clock = boat.penaltyClockTick else { return nil }
        let progress = abs(boat.penaltyProgress)
        self.init(turnsOwed: boat.penaltyTurnsOwed, startDeadlineTick: clock + RulesConfig.ticks(penalty.start),
                  completeDeadlineTick: clock + RulesConfig.ticks(penalty.complete), progress: progress,
                  isStarted: progress >= penalty.startedTurn)
    }
}
