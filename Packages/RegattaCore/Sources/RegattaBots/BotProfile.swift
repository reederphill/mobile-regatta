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
}
