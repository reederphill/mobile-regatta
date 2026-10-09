import RegattaCore

/// A bot's own hand on the helm (#434, ADR 0011), for a class whose autohelm doesn't hold a centred rudder
/// (`BoatClass.AutohelmTuning.holdsWhenCentred` false). Her brain sails by centring the rudder on her aim and leaving
/// the autohelm to hold it (`BotBrain`, ADR 0007); with no autohelm to hold it, a centred rudder would sail her
/// straight on through every shift. So the helm keeps the angle the class's autohelm would have taken on the tick she
/// centred (`Autohelm.engage`: her angle, or the groove within a snap of it) and turns it into a held rudder each
/// decision with the autohelm's own rudder law (`Autohelm.rudder`): she sails the same track either way, close to it
/// rather than bit for bit, since she steers ten times a second where the autohelm steers every tick. A correction inside
/// the autohelm's dead band (`Autohelm.deadBand`, about 0.5° of error at the class's gain) is a centred rudder, so she can
/// sit that far off her aim; and she steers by the headed angle she sees under a backwind header, where the race's
/// autohelm holds a groove's heading through it (#377).
///
/// Her brain reads the angle it holds as her autohelm's (`view(_:)`), so it decides exactly as it does with the
/// autohelm on. A rudder her brain holds off centre is hers, and lets the angle go. The tack/gybe tap is still the
/// race's autohelm's: hands off while it sails her, and once it hands her back she holds the groove it sailed her to,
/// as the autohelm on would. For a class whose autohelm holds a centred rudder she does nothing: every input passes.
/// Sees only her seat's view (#98), like the brain.
///
/// She steers by hand as well as her skill lets her (#435, `HandSteering`): she aims by the wind she last re-aimed to,
/// not the wind at her, re-aiming only `shiftLag` seconds after a shift or puff reaches her, past the new angle by her
/// `overshoot`, and she wanders slowly about her aim. At skill 1 she has none of these and sails exactly as above.
struct BotHelm: Sendable, Equatable {
    /// What she holds by hand: the autohelm the class's would be, engaged when her brain last centred the rudder; nil
    /// while her brain holds the rudder or she has never centred it.
    private(set) var held: Autohelm?
    /// How well she steers by hand (#435).
    let hand: HandSteering
    /// The wind she steers by while she holds an angle and her hand isn't perfect; nil otherwise.
    private(set) var steering: HandSteering.SteeredWind?

    /// A helm steering by hand with `hand`'s imperfections; perfect by default.
    init(hand: HandSteering = .perfect) {
        self.hand = hand
    }

    /// `view` as her brain should read it: her own autohelm's reading the angle she holds by hand, while the race's
    /// autohelm doesn't have her.
    func view(_ view: SeatView) -> SeatView {
        guard !view.boatClass.steering.autohelm.holdsWhenCentred, view.own.autohelm == nil, let held else { return view }
        return view.holdingOwnHelm(held.reading(tws: view.own.polarWindSpeed, grooveTWS: view.own.grooveWindSpeed,
                                                boatClass: view.boatClass))
    }

    /// The held input she sends for `input`, her brain's decision on `view`, the seat's view as the race shows it, with
    /// the tack/gybe tap if `tapping`: then the rudder stays as her brain left it, centred, for the race's autohelm to
    /// sail the tap (a rudder held off centre would cancel it).
    mutating func input(_ input: BoatInput, _ view: SeatView, tapping: Bool = false) -> BoatInput {
        let boatClass = view.boatClass
        guard !boatClass.steering.autohelm.holdsWhenCentred, !tapping else {
            held = nil
            steering = nil
            return input
        }
        // Her brain steers: the rudder is hers, and the angle she held goes.
        guard abs(input.rudderValue) <= Autohelm.deadBand else {
            held = nil
            steering = nil
            return input
        }
        let own = view.own
        if let tapping = own.autohelm {
            // The race's autohelm is sailing her tap, or settling her on the new groove: hands off. When it lets go she
            // holds what it held, aiming afresh by the wind then.
            held = Autohelm(target: tapping.target)
            steering = nil
            return input
        }
        let angle = own.boomSide.sailingAngle(relativeWind: own.relativeWind)
        let helm = held ?? Autohelm.engage(sailingAngle: angle, tws: own.grooveWindSpeed, boatClass: boatClass).autohelm
        held = helm
        guard !hand.isPerfect else {
            let rudder = helm.rudder(sailingAngle: angle, boomSide: own.boomSide, tws: own.polarWindSpeed,
                                     grooveTWS: own.grooveWindSpeed, boatClass: boatClass)
            return BoatInput(rudder: rudder, ease: input.ease)
        }
        // By hand: her angle read against the wind she steers by, not the wind at her.
        let wind = hand.steer(&steering, own: own, tick: view.tick)
        let steeredAngle = own.boomSide.sailingAngle(relativeWind: wrapAngle(wind.direction - own.heading))
        let rudder = helm.rudder(sailingAngle: steeredAngle, boomSide: own.boomSide, tws: wind.tws,
                                 grooveTWS: wind.grooveTWS, boatClass: boatClass)
        return BoatInput(rudder: rudder, ease: input.ease)
    }
}

/// How well a bot steers by hand (#435, `BotWeaknesses.shiftLag`, `wander`, `overshoot`): her skill's imperfections,
/// with the wander's period and phase drawn from her seed. A pure function of her seat's view and seed: no wall clock,
/// no draw after she is built.
struct HandSteering: Sendable, Equatable {
    /// Seconds she sails by the old wind after a shift or puff reaches her.
    let shiftLag: Double
    /// Radians: the wander's amplitude.
    let wander: Double
    /// Seconds: one wander cycle, drawn from her seed in `HandSteeringTable.wanderPeriod`.
    let wanderPeriod: Double
    /// Where in its cycle her wander starts, 0..<1 of a cycle, drawn from her seed.
    let wanderPhase: Double
    /// Radians past the new angle when she re-aims, at most the shift itself.
    let overshoot: Double

    /// No imperfection: she aims by the wind at her, as the autohelm does.
    static let perfect = HandSteering(shiftLag: 0, wander: 0, wanderPeriod: 30, wanderPhase: 0, overshoot: 0)

    init(shiftLag: Double, wander: Double, wanderPeriod: Double, wanderPhase: Double, overshoot: Double) {
        self.shiftLag = shiftLag
        self.wander = wander
        self.wanderPeriod = wanderPeriod
        self.wanderPhase = wanderPhase
        self.overshoot = overshoot
    }

    /// The hand steering of `weaknesses`, her wander's period and phase drawn from `seed` on a stream of its own, so
    /// none of her brain's draws moves.
    init(_ weaknesses: BotWeaknesses, seed: UInt64) {
        var rng = SplitMix64(seed: seed, stream: Self.seedStream)
        let period = rng.range(HandSteeringTable.wanderPeriod.lowerBound, HandSteeringTable.wanderPeriod.upperBound)
        let phase = rng.unit()
        self.init(shiftLag: max(weaknesses.shiftLag, 0), wander: max(weaknesses.wander, 0), wanderPeriod: period,
                  wanderPhase: phase, overshoot: max(weaknesses.overshoot, 0))
    }

    /// Stream tag for `SplitMix64(seed:stream:)` on her bot seed: ASCII "handhelm".
    static let seedStream: UInt64 = 0x6861_6E64_6865_6C6D

    var isPerfect: Bool { shiftLag == 0 && wander == 0 && overshoot == 0 }

    /// Radians of wander at `tick`: a smooth wave of her period and phase, never past `wander`. Parabolic arcs, a
    /// sine's shape to within a few percent, in plain arithmetic so the app and the suite draw it identically.
    func wander(atTick tick: Int) -> Double {
        guard wander > 0 else { return 0 }
        let cycles = Double(tick) / Double(Race.tickRate) / wanderPeriod + wanderPhase
        let x = cycles - cycles.rounded(.down)
        let wave = x < 0.5 ? 16 * x * (0.5 - x) : -16 * (x - 0.5) * (1 - x)
        return wander * wave
    }

    /// The wind she last re-aimed to, and when she noticed it had changed since.
    struct SteeredWind: Sendable, Equatable {
        var direction: Double
        var tws: Double
        var grooveTWS: Double
        /// The tick she noticed a shift or puff she hasn't yet re-aimed to; nil if none.
        var noticedTick: Int?
        /// Radians past the wind she re-aimed to, signed, at `overshootTick`, decaying to none over
        /// `HandSteeringTable.overshootDecay`.
        var overshoot: Double = 0
        var overshootTick: Int = 0
    }

    /// The wind she steers by at `tick`, `own` her boat in her seat's view, advancing `steered`: started on the wind at
    /// her, re-aimed to it `shiftLag` seconds after it changed past what she notices, past it by her overshoot, and her
    /// wander added to the direction.
    func steer(_ steered: inout SteeredWind?, own: SeatView.OwnBoat, tick: Int) -> (direction: Double, tws: Double, grooveTWS: Double) {
        var wind = steered ?? SteeredWind(direction: own.windDirection, tws: own.polarWindSpeed,
                                          grooveTWS: own.grooveWindSpeed, overshootTick: tick)
        let swing = wrapAngle(own.windDirection - wind.direction)
        let changed = abs(swing) > HandSteeringTable.shiftNoticed
            || abs(own.polarWindSpeed - wind.tws) > HandSteeringTable.puffNoticed * max(wind.tws, 0.1)
        if !changed {
            wind.noticedTick = nil
        } else if wind.noticedTick == nil {
            wind.noticedTick = tick
        }
        if let noticed = wind.noticedTick, Double(tick - noticed) / Double(Race.tickRate) >= shiftLag {
            // She re-aims to the wind at her, past it the way it swung.
            wind.overshoot = (swing < 0 ? -1 : 1) * min(overshoot, abs(swing))
            wind.overshootTick = tick
            wind.direction = own.windDirection
            wind.tws = own.polarWindSpeed
            wind.grooveTWS = own.grooveWindSpeed
            wind.noticedTick = nil
        }
        steered = wind
        let decay = max(0, 1 - Double(tick - wind.overshootTick) / Double(Race.tickRate) / HandSteeringTable.overshootDecay)
        return (wrapAngle(wind.direction + wind.overshoot * decay + wander(atTick: tick)), wind.tws, wind.grooveTWS)
    }
}
