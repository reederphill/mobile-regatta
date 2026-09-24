import RegattaCore

/// A bot's seed: `hash(raceSeed, seat, "bot")`, FNV-1a over the race seed, the seat and the tag.
/// Every bot draws from its own seed, never from the race's streams, so bots never move placement,
/// wind or each other (#60). Public like the race seed it comes from: nothing secret may use it.
public func botSeed(raceSeed: RaceSeed, seat: Int) -> UInt64 {
    var h = FNV1a()
    h.combine(raceSeed.value)
    h.combine(seat)
    h.combine("bot")
    return h.value
}

/// Sails one seat for a bot through the race's input API, exactly as a player's device would (#19):
/// a held input and the tack/gybe tap, through `Race.apply` and `Race.tap`. The race logs what it
/// applied, so a replay never runs the driver (ADR 0002).
///
/// Decides at 10 Hz: on ticks where `(tick + phase) % 3 == 0`, with the phase spreading the fleet's
/// decisions over the three ticks. A decision is applied on the next tick and held until the next one.
public struct BotDriver: Sendable {
    /// Ticks between decisions: 10 Hz at `Race.tickRate`.
    public static let decisionInterval = 3

    public let seat: Int
    /// `botSeed(raceSeed:seat:)`; the style and sailing name are drawn from it.
    public let seed: UInt64
    public var style: BotStyle { brain.style }
    /// Which of the three ticks this seat decides on.
    public let phase: Int
    /// Decisions made so far.
    public private(set) var decisions = 0

    private var brain: BotBrain

    /// The bot for `seat` in the race with `raceSeed`, its style drawn from its own seed.
    public init(seat: Int, raceSeed: RaceSeed) {
        let seed = botSeed(raceSeed: raceSeed, seat: seat)
        var rng = SplitMix64(seed: seed)
        self.init(seat: seat, seed: seed, style: BotStyle(rng: &rng))
    }

    /// The bot for `seat` with a given style, e.g. a retuned one.
    public init(seat: Int, raceSeed: RaceSeed, style: BotStyle) {
        self.init(seat: seat, seed: botSeed(raceSeed: raceSeed, seat: seat), style: style)
    }

    private init(seat: Int, seed: UInt64, style: BotStyle) {
        self.seat = seat
        self.seed = seed
        phase = seat % BotDriver.decisionInterval
        brain = BotBrain(style: style)
    }

    /// Whether the driver decides when the race is at `tick`.
    public func decides(atTick tick: Int) -> Bool {
        (tick + phase).isMultiple(of: BotDriver.decisionInterval)
    }

    /// Call once per tick, before `race.step()`. On a decision tick, reads the race as it stands
    /// and sends its decision for the next tick; otherwise the last decision stays held.
    /// Returns the decision it sent, if any.
    @discardableResult
    public mutating func drive(_ race: Race) -> BotDecision? {
        guard !race.isOver, decides(atTick: race.tick) else { return nil }
        let decision = brain.decide(for: seat, in: race)
        decisions += 1
        let next = race.tick + 1
        race.apply(decision.input, seat: seat, atTick: next)
        if let tap = decision.tap { race.tap(tap, seat: seat, atTick: next) }
        return decision
    }
}
