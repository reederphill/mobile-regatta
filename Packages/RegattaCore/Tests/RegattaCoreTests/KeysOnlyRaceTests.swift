import Testing
@testable import RegattaCore

/// A keys-only race (#64): how an online client predicts without the wind seed (ADR 0001). It holds only
/// the keys it's given, and a step that needs a key it doesn't hold throws instead of trapping or
/// guessing the wind.
@Suite struct KeysOnlyRaceTests {
    static let windSeed = WindSeed(0xC0FFEE)

    static func setup() throws -> RaceSetup {
        try RaceSetup(raceSeed: RaceSeed(64), seats: [.human, .bot, .bot, .human], startSequenceTicks: 900)
    }

    /// The server's keys, as its generator makes them, through `window`.
    static func keys(of race: Race, through window: Int) throws -> [WindKey] {
        var generator = try WindKeyGenerator(windSeed: windSeed, setup: race.windSetup, windows: race.wind.windows)
        return generator.keys(through: window)
    }

    /// Sails the bot seats from outside, as their seat controllers would (#60): the same seeded rudder
    /// changes, stamped for the next tick, go to every race in `races`.
    static func steerBots(_ races: Race..., rng: inout SplitMix64) {
        let t = races[0].tick + 1
        for seat in [1, 2] where rng.int(in: 0..<60) == 0 {
            let input = BoatInput(rudder: Int8(rng.int(in: -80...80)))
            for race in races { race.apply(input, seat: seat, atTick: t) }
        }
    }

    /// Given every key the seeded race uses, a keys-only race that imports its snapshot steps bit for bit
    /// like it: the keys, not the seed, are the wind.
    @Test func withTheKeysItStepsExactlyLikeTheSeededRace() throws {
        let seeded = Race(setup: try Self.setup(), windSeed: Self.windSeed)
        var rng = SplitMix64(seed: 64)
        for _ in 0..<300 {
            Self.steerBots(seeded, rng: &rng)
            seeded.step()
        }
        let keys = try Self.keys(of: seeded, through: 8)
        let keysOnly = Race(setup: try Self.setup(), revealedWindKeys: keys)
        #expect(keysOnly.isKeysOnly && !seeded.isKeysOnly)
        #expect(keysOnly.windSeed == nil)
        #expect(keysOnly.log == nil && seeded.log != nil)
        // The import takes the snapshot's keys, which run only through the current window; the keys
        // revealed ahead go back in after it.
        try keysOnly.importSnapshot(seeded.exportSnapshot())
        #expect(keysOnly.wind.keys.endWindow == 2)
        for key in keys { keysOnly.addRevealedWindKey(key) }
        for _ in 0..<(7 * WindWindows.ticksPerWindow) {
            Self.steerBots(seeded, keysOnly, rng: &rng)
            seeded.step()
            try keysOnly.tryStep()
            guard keysOnly.digest() == seeded.digest() else {
                Issue.record("diverged at tick \(seeded.tick)")
                return
            }
        }
    }

    /// At a window it holds no key for, `tryStep` throws `missingKey` and leaves the race as it was; the
    /// revealed key lets it go on. It never makes a key of its own.
    @Test func aMissingKeyThrowsInsteadOfTrappingAndTheRevealedKeyResumes() throws {
        let setup = try Self.setup()
        let seeded = Race(setup: setup, windSeed: Self.windSeed)
        let keys = try Self.keys(of: seeded, through: 4)
        let windows = seeded.wind.windows
        // The race starts in window 1 (tick −900, origin −1800): keys 0 and 1 cover it.
        let race = Race(setup: setup, revealedWindKeys: Array(keys[0...1]))
        #expect(race.boats.allSatisfy { $0.windSpeed > 0 })
        while race.tick < windows.start(of: 2) - 1 { try race.tryStep() }
        let digest = race.digest()
        #expect(throws: WindFieldError.missingKey(2)) { try race.tryStep() }
        #expect(race.digest() == digest && race.tick == windows.start(of: 2) - 1)
        #expect(race.wind.keys.endWindow == 2)

        #expect(race.addRevealedWindKey(keys[2]))
        try race.tryStep()
        #expect(race.tick == windows.start(of: 2))
        // The seeded race ignores revealed keys: it makes its own.
        #expect(!seeded.addRevealedWindKey(keys[3]))
    }

    /// Without the keys for its first tick, the race still builds; its boats' wind waits for a snapshot.
    @Test func withoutItsFirstKeysItBuildsAndWaits() throws {
        let setup = try Self.setup()
        let race = Race(setup: setup, revealedWindKeys: [])
        #expect(race.boats.allSatisfy { $0.windSpeed == 0 })
        #expect(throws: WindFieldError.missingKey(0)) { try race.tryStep() }
        #expect(race.tick == -setup.startSequenceTicks)

        let seeded = Race(setup: setup, windSeed: Self.windSeed)
        for _ in 0..<100 { seeded.step() }
        try race.importSnapshot(seeded.exportSnapshot())
        try race.tryStep()
        seeded.step()
        #expect(race.digest() == seeded.digest())
    }

    /// For a seeded race `tryStep` is `step`.
    @Test func tryStepOfASeededRaceIsStep() throws {
        let a = Race(setup: try Self.setup(), windSeed: Self.windSeed)
        let b = Race(setup: try Self.setup(), windSeed: Self.windSeed)
        var rng = SplitMix64(seed: 64)
        for _ in 0..<2000 {
            Self.steerBots(a, b, rng: &rng)
            a.step()
            try b.tryStep()
        }
        #expect(a.digest() == b.digest())
    }
}
