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
    /// What she sails with: her skill's, her profile's, or an override's (#367).
    public var weaknesses: BotWeaknesses { brain.weaknesses }
    /// Her handling skill, 0…1 (#443): how well she steers by hand, drawn apart from her skill (`BotTier.handling`), as
    /// her hand steering's weaknesses scale. Nil when a profile or an override sets those (`weaknesses`).
    public let handling: Double?
    /// The bot suite's scripted profile she sails (#231), or nil for a live bot.
    public let profile: BotProfile?
    /// Which of the three ticks this seat decides on.
    public let phase: Int
    /// Decisions made so far.
    public private(set) var decisions = 0
    /// Whether the decision she holds is the suite's hunter turning at the boat she hunts (#355, `BotBrain.hunting`):
    /// a luff, or a turn that brings a boat that must keep clear of her closer. Never for a live bot.
    public private(set) var isHuntingTurn = false
    /// Her taps that played a fleet tactic (#234), by tactic, and her decisions luffing a windward boat before her start
    /// (#337, `BotBrain.startLuffing`): what the suite counts by engagement band.
    public private(set) var leeBowTaps = 0
    public private(set) var tackOnWindTaps = 0
    public private(set) var coverTaps = 0
    public private(set) var startLuffDecisions = 0

    private var brain: BotBrain
    /// Her own hand on the helm for a class whose autohelm doesn't hold a centred rudder (#434); idle otherwise.
    private var helm: BotHelm

    /// The bot for `seat` in the race with `raceSeed`, a Mixed fleet's (CONTEXT.md **Mixed fleet**, the default
    /// for practice): her tier drawn from her own seed by the bot-tier file's shares (`BotTier.mixedFleetDraw`),
    /// her skill inside its band and her style from the same seed; her handling inside that tier's handling band
    /// (`BotTier.handling(seed:)`, #443).
    public init(seat: Int, raceSeed: RaceSeed) {
        self.init(seat: seat, raceSeed: raceSeed, profile: nil)
    }

    /// `init(seat:raceSeed:)` sailing `profile` if the bot suite gives her one (#231): a Mixed fleet's draw.
    public init(seat: Int, raceSeed: RaceSeed, profile: BotProfile?) {
        let seed = botSeed(raceSeed: raceSeed, seat: seat)
        let drawn = BotTier.mixedFleetDraw(seed: seed)
        self.init(seat: seat, raceSeed: raceSeed, skill: drawn.skill, handling: drawn.tier.handling(seed: seed),
                  profile: profile)
    }

    /// The bot for `seat` with a given style, e.g. a retuned one, sailing `profile` if the bot suite gives
    /// her one (#231).
    public init(seat: Int, raceSeed: RaceSeed, style: BotStyle, profile: BotProfile? = nil) {
        self.init(seat: seat, seed: botSeed(raceSeed: raceSeed, seat: seat), style: style, profile: profile)
    }

    /// `init(seat:raceSeed:style:profile:)` with `weaknesses`, if given, in place of her skill's and profile's
    /// (`BotDriver(seat:raceSeed:skill:profile:weaknesses:)`, #367).
    init(seat: Int, raceSeed: RaceSeed, style: BotStyle, handling: Double?, profile: BotProfile?,
         overriding weaknesses: BotWeaknesses?) {
        self.init(seat: seat, seed: botSeed(raceSeed: raceSeed, seat: seat), style: style, handling: handling,
                  profile: profile, weaknesses: weaknesses)
    }

    /// The bot for `seat` with a given style and `weaknesses` in place of her skill's (`BotWeaknesses`), cautious
    /// (#104, `BotBrain.Caution`) with `caution`: `BotDriver.cautious` builds on it, and tests of a mechanism her
    /// weaknesses would blur use it.
    init(seat: Int, raceSeed: RaceSeed, style: BotStyle, weaknesses: BotWeaknesses, caution: BotBrain.Caution? = nil) {
        self.init(seat: seat, seed: botSeed(raceSeed: raceSeed, seat: seat), style: style, weaknesses: weaknesses,
                  caution: caution)
    }

    /// `handling` nil draws hers from `seed` in the handling band of the tier holding her skill (`BotTier.holding`).
    private init(seat: Int, seed: UInt64, style: BotStyle, handling: Double? = nil, profile: BotProfile? = nil,
                 weaknesses: BotWeaknesses? = nil, caution: BotBrain.Caution? = nil) {
        self.seat = seat
        self.seed = seed
        self.profile = profile
        phase = seat % BotDriver.decisionInterval
        let handling = handling ?? BotTier.holding(skill: style.skill).handling(seed: seed)
        self.handling = weaknesses == nil && profile == nil ? handling : nil
        brain = BotBrain(style: style, profile: profile, seed: seed, handling: handling, weaknesses: weaknesses,
                         caution: caution)
        helm = BotHelm(hand: HandSteering(brain.weaknesses, seed: seed))
    }

    /// Whether she is the cautious bot that sails a dropped player's boat (#104, `cautious(seat:raceSeed:)`).
    public var isCautious: Bool { brain.caution != nil }

    /// This driver taking a seat over at any tick (#19, #104): mid-race, mid-tack, mid-penalty, OCS, in irons, on the
    /// race area's edge, or before the gun. Her first decision rebuilds her plan from what the seat sees and nothing
    /// else (`BotBrain.adopt`): the tack the boat is on, a tap the autohelm is sailing, a penalty turn's way. A driver
    /// that sails a seat from the start needs none of it.
    public func takingOver() -> BotDriver {
        var driver = self
        driver.brain.takingOver = true
        return driver
    }

    /// Whether the driver decides when the race is at `tick`.
    public func decides(atTick tick: Int) -> Bool {
        (tick + phase).isMultiple(of: BotDriver.decisionInterval)
    }

    /// Call once per tick, before `race.step()`. On a decision tick, hands its brain what the seat sees
    /// now (`Race.seatView(for:)`, #98), never the race, and sends the decision for the next tick;
    /// otherwise the last decision stays held. Returns the decision it sent, if any.
    @discardableResult
    public mutating func drive(_ race: Race) -> BotDecision? {
        guard !race.isOver, decides(atTick: race.tick) else { return nil }
        return drive(race, seeing: race.seatView(for: seat))
    }

    /// Decides on `view`, the seat's view of `race` now (a decision tick of a race not over), and sends the
    /// decision for the next tick: `drive(_:)` with the view built by the caller, as `SeatControllers` builds
    /// the fleet's together.
    @discardableResult
    mutating func drive(_ race: Race, seeing view: SeatView) -> BotDecision {
        precondition(view.seat == seat && view.tick == race.tick, "seat \(seat) at tick \(race.tick) given the view of seat \(view.seat) at tick \(view.tick)")
        var decision = brain.decide(helm.view(view))
        decision.input = helm.input(decision.input, view, tapping: decision.tap != nil)
        decisions += 1
        isHuntingTurn = decision.hunt == .turn
        if decision.tap != nil {
            switch decision.play {
            case .leeBow: leeBowTaps += 1
            case .tackOnWind: tackOnWindTaps += 1
            case .cover: coverTaps += 1
            case .holdLane, nil: break
            }
        }
        if decision.startLuff { startLuffDecisions += 1 }
        let next = race.tick + 1
        race.apply(decision.input, seat: seat, atTick: next)
        if let tap = decision.tap { race.tap(tap, seat: seat, atTick: next) }
        return decision
    }
}
