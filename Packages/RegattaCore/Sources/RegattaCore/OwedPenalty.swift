/// A boat's owed penalty turns as the HUD shows them (G4, #89; #114 draws it): how many she owes, and the
/// current turn's two deadlines and progress. Read off her penalty state (`Boat.penaltyTurnsOwed`,
/// `penaltyProgress`, `penaltyClockTick`, and under a `tackAndGybe` penalty `penaltyDirection` and
/// `penaltyFirstCrossing`, #487) and the rules' penalty, so a client computes it from the world it predicts as the
/// server does (`Race.owedPenalty(ofSeat:)`).
public struct OwedPenalty: Sendable, Equatable {
    /// Penalty turns she owes, the current one included.
    public let turnsOwed: Int
    /// The tick by which the current turn must be started (turned `startedTurn`), or she is disqualified. Under a
    /// `tackAndGybe` penalty (#487), which has no start deadline, it is the complete deadline, `completeDeadlineTick`.
    public let startDeadlineTick: Int
    /// The tick by which the current turn must be completed, or she is disqualified. While its clock is pending
    /// (`isClockPending`), now plus the whole limit: the time she will have once clear of the mark.
    public let completeDeadlineTick: Int
    /// Radians turned in the current turn, whichever way she turns it: a full turn (2π) serves it. Always 0 under a
    /// `tackAndGybe` penalty.
    public let progress: Double
    /// Whether the current turn is started: turned at least the rules' `startedTurn` (30°), or under a
    /// `tackAndGybe` penalty made a counting crossing (#487).
    public let isStarted: Bool
    /// Under a `tackAndGybe` penalty (#487, fleet-rules@6): whether the current turn's clock waits for her to be clear
    /// of the mark she is rounding (`Boat.penaltyClockTick` nil while owed): its deadlines then show the whole limit
    /// from now. Always false under a `fullCircle` penalty.
    public internal(set) var isClockPending = false
    /// Under a `tackAndGybe` penalty (#487): whether the current turn has its tack, and its gybe. A prediction's
    /// second crossing, held for the server's word (`Boat.penaltyCrossingHeld`), shows both. Always false under
    /// a `fullCircle` penalty.
    public let hasTacked: Bool
    public let hasGybed: Bool
    /// Under a `tackAndGybe` penalty (#487): the way the current turn goes, +1 to starboard, −1 to port, 0 before
    /// its way is set (`Boat.penaltyDirection`). Always 0 under a `fullCircle` penalty.
    public let direction: Int
    /// Under a `tackAndGybe` penalty: whether `direction` is the first served turn's of this sequence, which every
    /// later turn goes (RRS 44.2, `Boat.penaltyDirectionLocked`): a crossing back then only undoes the turn's first,
    /// never turns it round (#488's bots read it). Always false under a `fullCircle` penalty.
    public let isDirectionLocked: Bool

    public init(turnsOwed: Int, startDeadlineTick: Int, completeDeadlineTick: Int, progress: Double, isStarted: Bool,
                hasTacked: Bool = false, hasGybed: Bool = false, direction: Int = 0, isDirectionLocked: Bool = false) {
        self.turnsOwed = turnsOwed
        self.startDeadlineTick = startDeadlineTick
        self.completeDeadlineTick = completeDeadlineTick
        self.progress = progress
        self.isStarted = isStarted
        self.hasTacked = hasTacked
        self.hasGybed = hasGybed
        self.direction = direction
        self.isDirectionLocked = isDirectionLocked
    }

    /// `boat`'s owed penalty under `penalty` at tick `now`, or nil while she owes none. A prediction's progress past a
    /// full turn (#96: the server serves it) shows just short of one until the server's word comes; under a
    /// `tackAndGybe` penalty its held second crossing shows as made, and a pending clock (#487) the whole limit from
    /// `now`.
    public init?(_ boat: Boat, penalty: RulesConfig.Penalty, now: Int) {
        guard boat.penaltyTurnsOwed > 0 else { return nil }
        let pending = boat.penaltyClockTick == nil
        guard let clock = boat.penaltyClockTick ?? (penalty.turn == .tackAndGybe ? now : nil) else { return nil }
        let complete = clock + RulesConfig.ticks(penalty.complete)
        switch penalty.turn {
        case .fullCircle:
            let progress = min(abs(boat.penaltyProgress), Race.heldPenaltyProgress)
            self.init(turnsOwed: boat.penaltyTurnsOwed, startDeadlineTick: clock + RulesConfig.ticks(penalty.start),
                      completeDeadlineTick: complete, progress: progress, isStarted: progress >= penalty.startedTurn)
        case .tackAndGybe:
            let first = boat.penaltyFirstCrossing, held = boat.penaltyCrossingHeld
            self.init(turnsOwed: boat.penaltyTurnsOwed, startDeadlineTick: complete, completeDeadlineTick: complete,
                      progress: 0, isStarted: first != nil || held,
                      hasTacked: held || first == .tack, hasGybed: held || first == .gybe, direction: boat.penaltyDirection,
                      isDirectionLocked: boat.penaltyDirectionLocked)
        }
        isClockPending = pending
    }
}
