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
    /// Her taps (on a class she turns by hand, #459, her hand turns) that played a fleet tactic (#234), by tactic, and her decisions luffing a windward boat before her start
    /// (#337, `BotBrain.startLuffing`): what the suite counts by engagement band.
    public private(set) var leeBowTaps = 0
    public private(set) var tackOnWindTaps = 0
    public private(set) var coverTaps = 0
    public private(set) var startLuffDecisions = 0
    /// Decisions she avoided a boat clearly not keeping clear of her on (#537, `BotBrain.avoidingContact`): the suite's
    /// trace; nothing reads it in play.
    public private(set) var avoidContactDecisions = 0
    /// Before the gun (#541, `BotBrain.avoidance`), the suite's trace; nothing reads them in play. Her decisions
    /// avoiding a boat not keeping clear by a luff, by a bear-away, and by holding her heading with the rudder centred;
    /// of the turns, those to the heading that passes furthest (none clearing); her centred holds given up as early;
    /// of those, the ones she turned away and the ones she held centred all the same (`Avoidance.heldEarly`), the
    /// rest left to her plan; the seconds to the gun of her last held-early hold (negative), nil with none; her
    /// luffs taken early for a boat that can't keep clear, no other heading clearing (`Avoidance.earlyLuff`);
    /// the largest turn up, radians, and the turns up over 10° (every turn towards the wind, the furthest pass's
    /// included); the luff preference's own picks (a clearing luff over a bear-away that also cleared) and their sizes,
    /// radians; and the seconds to the gun of her last avoidance (negative), nil with none.
    public private(set) var preGunAvoidLuffs = 0
    public private(set) var preGunAvoidBearAways = 0
    public private(set) var preGunAvoidHolds = 0
    public private(set) var preGunAvoidFurthest = 0
    public private(set) var preGunHoldsRefusedEarly = 0
    public private(set) var preGunRefusedHoldsTurned = 0
    public private(set) var preGunHeldEarly = 0
    public private(set) var preGunLastHeldEarlyTime: Double?
    public private(set) var preGunEarlyLuffs = 0
    public private(set) var preGunAvoidLargestTurnUp = 0.0
    public private(set) var preGunAvoidTurnsUpOver10 = 0
    public private(set) var preGunPreferredLuffs: [Double] = []
    public private(set) var preGunLastAvoidTime: Double?
    /// Before the gun, her avoidance's commitment (#542 Q8: her plan refused, she held or turned further away) and its
    /// early headings taken for a boat that can't keep clear (#542 Q4). Report-only.
    public private(set) var preGunAvoidCommitted = 0
    public private(set) var preGunAvoidEarly = 0
    /// Before the gun (#477, report-only): her decisions on port with her plan wanting starboard and no turn started
    /// (held off her tack: too slow to tack, or boats in the way), and whether her last decision was one
    /// (`heldOffTack`, which the suite joins with the rule 10 calls on her).
    public private(set) var preGunHeldOffTackDecisions = 0
    public private(set) var heldOffTack = false

    private(set) var brain: BotBrain
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
    /// the fleet's together. `humans`, by seat, the seats people sail (`SeatControllers`): the keep-clear scorer never
    /// rolls one giving way (#531). Empty when the caller doesn't say: every boat a bot's.
    @discardableResult
    mutating func drive(_ race: Race, seeing view: SeatView, humans: [Bool] = []) -> BotDecision {
        precondition(view.seat == seat && view.tick == race.tick, "seat \(seat) at tick \(race.tick) given the view of seat \(view.seat) at tick \(view.tick)")
        if brain.humanSeats != humans { brain.humanSeats = humans }
        var decision = brain.decide(helm.view(view))
        decision.input = helm.input(decision.input, view, tapping: decision.tap != nil, centred: decision.centred,
                                    holdsHerAngle: decision.holdsHerAngle)
        decisions += 1
        isHuntingTurn = decision.hunt == .turn
        // A play is her tap's, or on a class she turns by hand (#459) the decision she puts the rudder over on.
        switch decision.play {
        case .leeBow: leeBowTaps += 1
        case .tackOnWind: tackOnWindTaps += 1
        case .cover: coverTaps += 1
        case .holdLane, nil: break
        }
        if decision.startLuff { startLuffDecisions += 1 }
        if decision.avoidsContact { avoidContactDecisions += 1 }
        if let avoidance = decision.avoidance, view.own.status == .prestart, view.time < 0 { notePreGun(avoidance, view) }
        heldOffTack = brain.planWantsStarboardOnPort && decision.tap == nil && brain.handTurn == nil
        if heldOffTack { preGunHeldOffTackDecisions += 1 }
        let next = race.tick + 1
        race.apply(decision.input, seat: seat, atTick: next)
        if let tap = decision.tap { race.tap(tap, seat: seat, atTick: next) }
        return decision
    }

    /// Counts an avoidance before the gun (#541's report-only rows).
    private mutating func notePreGun(_ avoidance: BotBrain.Avoidance, _ view: SeatView) {
        if avoidance.refusedEarlyHold {
            preGunHoldsRefusedEarly += 1
            if avoidance.heldEarly {
                preGunHeldEarly += 1
                preGunLastHeldEarlyTime = view.time
            } else if avoidance.turn != nil {
                preGunRefusedHoldsTurned += 1
            }
        }
        if avoidance.earlyLuff { preGunEarlyLuffs += 1 }
        if avoidance.committed { preGunAvoidCommitted += 1 }
        if avoidance.early { preGunAvoidEarly += 1 }
        guard let turn = avoidance.turn else { return }
        preGunLastAvoidTime = view.time
        switch turn {
        case .luff:
            preGunAvoidLuffs += 1
            preGunAvoidLargestTurnUp = max(preGunAvoidLargestTurnUp, avoidance.turnSize)
            if avoidance.turnSize > deg2rad(10) + 1e-9 { preGunAvoidTurnsUpOver10 += 1 }
            if avoidance.preferredLuff { preGunPreferredLuffs.append(avoidance.turnSize) }
        case .bearAway: preGunAvoidBearAways += 1
        case .hold: preGunAvoidHolds += 1
        }
        if avoidance.furthest { preGunAvoidFurthest += 1 }
    }
}
