/// A scripted way of racing that the bot suite can give a seat (#231), in place of a live bot's, to measure
/// the skill the autohelm leaves to the helm (ADR 0007: "leaving the groove at the right moment (pinch,
/// foot, tack) is where skill shows"). A profile reads the seat's `SeatView` like any bot and sends what a
/// player can (#19); it changes only what she chooses to do, never what she sees. Fleet tactics for the
/// bots players race are #234's, which may reuse these.
public enum BotProfile: String, Codable, CaseIterable, Hashable, Sendable {
    /// The groove and nothing else: she sails the grooves and the laylines, tacks on headers past a
    /// threshold, taps each tack and gybe on time, and ignores the fleet but for keeping clear.
    case baseline
    /// The baseline, plus leaving the groove when it pays: she heads up in a lull and off the plane to
    /// plane again, sails towards the puffs drawn on the water, tacks out of dirty air, covers the boat close
    /// behind her, and tacks on smaller headers, leading them by how fast the wind is turning.
    case tactician
    /// The baseline, but tacking on every header past 3° (#221, #238): a blip, the wobble that never outlasts
    /// its 30 s window, as readily as a real shift. Tacking on a blip is a mistake: the tactician should beat her.
    case blipTacker
    /// The tactician, sailing to the edge of the rules (#355): a measuring profile for the suite only, never one of the
    /// bots players race (`BotDriver(seat:raceSeed:)` gives none), which hold course and never hunt (#19). As the
    /// right-of-way boat racing she turns towards a boat that must keep clear of her, at a rate under the umpire's
    /// rule 16.1 course-change test, to make her keep clear and take her wind: as the leeward boat she luffs (rule 11),
    /// within her proper course when she came from astern (rule 17); as the starboard boat she holds or bears down on
    /// the port boat, never giving up her lane (rule 10); with mark-room she takes all of it. She tacks or gybes
    /// only with no boat that must keep clear of her close on the side she turns to. She still keeps clear first
    /// when it is hers to, and hunts only racing (pre-start fighting is #337's). Her tunables: `BotBrain.Hunter`
    /// (`BotBrain+Hunter.swift`).
    case hunter
    /// Execution without tactics (#222, #105): the baseline's tactics, but rolling every tack and hitting every roll,
    /// with no angle noise (`BotWeaknesses.none`). A measuring profile for the suite only: the "execution never beats
    /// tactics" check races her against `tacticianClubExecution`.
    case executor
    /// The tactician at Club-level execution (#222, #105): her tactics, but half her rolls miss
    /// (`clubExecutionRollHitRate`; rolls only, the orchestrator's ruling on #105). A measuring profile for the suite only.
    case tacticianClubExecution
    /// The baseline steering by hand at Club level (#435): her tactics and no weaknesses, but Club's shift lag, wander
    /// and overshoot (`BotWeaknesses.clubHandSteering`), felt only in a class whose autohelm doesn't hold a centred
    /// rudder. A measuring profile for the suite only: the handling mix races her against the baseline.
    case clubSteering
    /// The tactician steering by hand at Club level (#435), as `clubSteering` is the baseline. A measuring profile for
    /// the suite only: the handling mix races her against the tactician.
    case tacticianClubSteering
}

extension BotProfile {
    /// The share of `tacticianClubExecution`'s rolls that hit (#105: "half its rolls miss").
    static let clubExecutionRollHitRate = 0.5

    /// What she sails with at `skill`: no weaknesses (`BotWeaknesses.none`, #102), but for `tacticianClubExecution`,
    /// whose rolls hit only `clubExecutionRollHitRate` of the time, and the Club-steering profiles, which steer by hand
    /// as Club does (#435).
    func weaknesses(skill: Double) -> BotWeaknesses {
        var weaknesses = BotWeaknesses.none(skill: skill)
        if self == .tacticianClubExecution { weaknesses.rollHitRate = Self.clubExecutionRollHitRate }
        if self == .clubSteering || self == .tacticianClubSteering {
            weaknesses = weaknesses.steering(like: .clubHandSteering)
        }
        return weaknesses
    }
}
