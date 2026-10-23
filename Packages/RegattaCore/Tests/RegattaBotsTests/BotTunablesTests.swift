import Foundation
import Testing
@testable import RegattaBots
@testable import RegattaCore

/// #583 stage 2: the bot's tunable constants are data (`BotTunables`, `bot-tunables@<n>.json`), every version bundled
/// and never changed, and a search may hand a bot its own set (`BotDriver.tuned`).
@Suite struct BotTunablesTests {
    /// Version 1 is the constants as they were in code: making them data moved nothing.
    @Test func versionOneIsTheOriginalConstants() throws {
        #expect(try BotTunables.load(version: 1) == BotTunables.original)
    }

    /// Every bundled version loads, names every tunable once and keeps it in its range; the current one is the bundled
    /// set the bots read.
    @Test func everyBundledVersionLoads() throws {
        #expect(Set(BotTunables.parameters.map(\.name)).count == BotTunables.parameters.count)
        for version in 1...BotTunables.currentVersion {
            let tunables = try BotTunables.load(version: version)
            for parameter in BotTunables.parameters {
                #expect(parameter.range.contains(parameter.value(in: tunables)), "v\(version) \(parameter.name)")
            }
        }
        #expect(try BotTunables.load(version: BotTunables.currentVersion) == BotTunables.bundled)
        #expect(throws: (any Error).self) { try BotTunables.load(version: BotTunables.currentVersion + 1) }
    }

    /// A set written as a file reads back as itself (to the file's four decimals), and a file missing a tunable or naming
    /// one twice over is refused.
    @Test func aFileRoundTrips() throws {
        var tunables = BotTunables.original
        tunables.tacticianCorridor = 0.6125
        tunables.puffWeight = deg2rad(9.5)
        let data = try tunables.encoded(version: 9, notes: "test")
        let read = try BotTunables.decode(data)
        for parameter in BotTunables.parameters {
            #expect(abs(parameter.value(in: read) - parameter.value(in: tunables)) < 1e-9, "\(parameter.name)")
        }
        #expect(throws: (any Error).self) { try BotTunables.decode(data, version: 8) }
        var text = String(decoding: data, as: UTF8.self)
        text = text.replacingOccurrences(of: "\"puffWeightDegrees\"", with: "\"puffWeightDegreez\"")
        #expect(throws: (any Error).self) { try BotTunables.decode(Data(text.utf8)) }
    }

    /// A parameter keeps what a search sets inside its range.
    @Test func aParameterClampsToItsRange() {
        let corridor = BotTunables.parameters.first { $0.name == "tacticianCorridor" }!
        #expect(corridor.value(in: corridor.set(99, in: .original)) == corridor.range.upperBound)
        #expect(corridor.value(in: corridor.set(-1, in: .original)) == corridor.range.lowerBound)
    }

    /// A bot handed the bundled set sails the race she sails untuned, to the bit, a live bot and a profile alike; a
    /// tactician handed another set sails another.
    @Test func aTunedBotWithTheBundledSetIsTheSameBot() throws {
        let setup = try RaceSetup(raceSeed: RaceSeed(7), seats: [.bot, .bot], laps: 1)
        func sail(_ profile: BotProfile? = nil, _ tune: (BotDriver) -> BotDriver) -> UInt64 {
            let race = Race(setup: setup, windSeed: WindSeed(8))
            var drivers = [0, 1].map { seat in
                tune(profile.map { BotDriver(seat: seat, raceSeed: setup.raceSeed, skill: 1, profile: $0) }
                    ?? BotDriver(seat: seat, raceSeed: setup.raceSeed, tier: .national))
            }
            while race.tick < 90 * Race.tickRate && !race.isOver {
                for k in drivers.indices { drivers[k].drive(race) }
                race.step()
            }
            return race.digest()
        }
        #expect(sail { $0.tuned(.bundled) } == sail { $0 })
        #expect(sail(.tactician) { $0.tuned(.bundled) } == sail(.tactician) { $0 })
        var other = BotTunables.bundled
        other.tacticianHeaderThreshold = deg2rad(10)
        other.tacticianCorridor = 1.1
        #expect(sail(.tactician) { $0.tuned(other) } != sail(.tactician) { $0 })
    }
}
