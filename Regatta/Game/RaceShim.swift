import RegattaCore

/// Thin shim over the per-seat input API (#59) until the practice driver owns input and
/// `myBoatIndex` (#61). A practice race puts you in seat 0.
extension Race {
    var playerIndex: Int { 0 }
    var player: Boat { boats[playerIndex] }

    /// Builds a practice race from the app's settings.
    convenience init(config: RaceConfig) {
        self.init(setup: config.setup, windSeed: WindSeed(config.windSeed), botBrainSeats: config.botBrainSeats)
    }

    /// Rudder from the touch controls, −1…1, held from the next tick. Any real input cancels an auto-tack.
    func setPlayerRudder(_ value: Double) {
        apply(BoatInput(rudder: value), seat: playerIndex, atTick: tick + 1)
    }

    /// Mirror the heading across the wind: a tack when upwind, a gybe when downwind.
    func playerTackOrGybe() {
        tap(.tackGybe, seat: playerIndex, atTick: tick + 1)
    }
}

extension Boat {
    /// The only human seat in a practice race is yours.
    var displayName: String { isPlayer ? "You" : name }
}

/// A practice race as the app starts it: you in seat 0 and `opponents` bots, the race seed, and the
/// wind seed the device holds for practice (ADR 0001; online, the server keeps it).
struct RaceConfig: Equatable {
    var opponents = 7
    var laps = RaceSetup.defaultLaps
    var prestartSeconds = 60.0
    /// The public race seed: placement and bot styles.
    var seed: UInt64
    /// Keys the wind. Never computed from the race seed in play; see `windSeed(pinnedTo:)`.
    var windSeed: UInt64
    /// A bot sails your boat too (`-demo`, `-perf`).
    var autopilotPlayer = false

    /// `windSeed` nil pins it to `seed` with `windSeed(pinnedTo:)`, so tests reproduce the whole race.
    init(opponents: Int = 7, laps: Int = RaceSetup.defaultLaps, prestartSeconds: Double = 60,
         seed: UInt64, windSeed: UInt64? = nil, autopilotPlayer: Bool = false) {
        self.opponents = opponents
        self.laps = laps
        self.prestartSeconds = prestartSeconds
        self.seed = seed
        self.windSeed = windSeed ?? Self.windSeed(pinnedTo: seed)
        self.autopilotPlayer = autopilotPlayer
    }

    /// The wind seed for a race pinned to `seed` by a developer (`-seed`) or a test: a fixed mix of the
    /// launch option, so a pinned launch replays the same wind. Real races draw both seeds independently.
    static func windSeed(pinnedTo seed: UInt64) -> UInt64 {
        var rng = SplitMix64(seed: seed ^ 0x5749_4E44_5345_4544) // "WINDSEED"
        return rng.next()
    }

    /// The menu keeps opponents in 1...15 and `-perf` sails 15, so the fleet is always a valid 2...16.
    var setup: RaceSetup {
        try! RaceSetup(
            raceSeed: RaceSeed(seed),
            seats: [.human] + Array(repeating: .bot, count: opponents),
            laps: laps,
            startSequenceTicks: Int((prestartSeconds * Double(Race.tickRate)).rounded())
        )
    }

    var botBrainSeats: [Int] {
        Array((autopilotPlayer ? 0 : 1)...opponents)
    }
}
