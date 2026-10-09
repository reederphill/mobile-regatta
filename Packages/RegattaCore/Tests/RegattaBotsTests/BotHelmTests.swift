import Foundation
import Testing
@testable import RegattaCore
@testable import RegattaBots

/// #434: bots steer by hand (`BotHelm`) when the class's autohelm doesn't hold a centred rudder.
@Suite struct BotHelmTests {
    /// The default class's file headed as schema 4 with `holdsWhenCentred` set to `holds`, as tune 1.
    static func skiff(holds: Bool) throws -> BoatClassFile {
        let key = RaceFiles.defaults.boatClass.ref.key
        var text = String(decoding: try #require(try BoatClassFile.bundledData(id: key.id, version: key.version)), as: UTF8.self)
        for (of, with) in [(#""schemaVersion": 3,"#, #""schemaVersion": 4,"#),
                           (#""grooveWindAverageSeconds": 30"#, #""grooveWindAverageSeconds": 30, "holdsWhenCentred": \#(holds)"#)] {
            #expect(text.contains(of), "the default class no longer holds \(of)")
            text = text.replacingOccurrences(of: of, with: with)
        }
        return try BoatClassFile(data: Data(text.utf8), tune: 1)
    }

    /// `botRace(seed:)`'s race, every seat a bot, sailing `boatClass`.
    static func race(seed: UInt64, boatClass: BoatClassFile, seats: Int = 8) throws -> Race {
        var catalog = RaceFileCatalog()
        try catalog.boatClasses.add(boatClass)
        let setup = try RaceSetup(raceSeed: RaceSeed(seed), seats: Array(repeating: .bot, count: seats), laps: 2,
                                  startSequenceTicks: 45 * Race.tickRate, boatClass: boatClass.ref)
        return try Race(setup: setup, files: RaceFiles(resolving: setup, from: catalog),
                        mode: .authoritative(windSeed: WindSeed(seed &* 0x9E37_79B9_7F4A_7C15 &+ 1)))
    }

    /// Each seat's position every second for `seconds`, the fleet sailed by bots; steering by hand perfectly if
    /// `perfectHands` (#435: the app's bots steer by hand as well as their skill lets them).
    static func track(seed: UInt64, boatClass: BoatClassFile, seconds: Int, seats: Int = 8,
                      perfectHands: Bool = false) throws -> [[Vec2]] {
        let race = try race(seed: seed, boatClass: boatClass, seats: seats)
        var controllers = perfectHands
            ? SeatControllers(race.boats.indices.map {
                .bot(BotHandSteeringTests.steering(like: BotWeaknesses(skill: 1))($0, race.setup.raceSeed))
            })
            : allBots(race)
        var track: [[Vec2]] = []
        sail(race, &controllers, ticks: seconds * Race.tickRate) { race in
            if race.tick % Race.tickRate == 0 { track.append(race.boats.map(\.position)) }
        }
        return track
    }

    /// A seeded bot race sailed with the autohelm off: the bots steer by hand and sail within a tolerance of today's
    /// track. Two bots, so the track is the helm's, not the fleet's: in a full fleet one tap a tick apart changes who
    /// meets whom, and the tracks part on the first beat (seed 5's eight bots drift 20 lengths apart in 90 s while each
    /// helm sails as well as ever). Five minutes, the start, a beat and a run: neither strays more than 2 hull lengths
    /// (0.6 when written). With it on (the value set true), today's race to the bit, the full fleet's too.
    @Test func sameTrackWithAutohelmOff() throws {
        let seed: UInt64 = 5
        let fleet = try Self.track(seed: seed, boatClass: RaceFiles.defaults.boatClass, seconds: 90)
        #expect(try Self.track(seed: seed, boatClass: Self.skiff(holds: true), seconds: 90) == fleet)

        let today = try Self.track(seed: seed, boatClass: RaceFiles.defaults.boatClass, seconds: 300, seats: 2)
        #expect(try Self.track(seed: seed, boatClass: Self.skiff(holds: true), seconds: 300, seats: 2) == today)
        // #435: steering by hand perfectly; the app's bots steer as well as their skill lets them, and stray further.
        let off = try Self.track(seed: seed, boatClass: Self.skiff(holds: false), seconds: 300, seats: 2, perfectHands: true)
        #expect(off.count == today.count)
        let hull = RaceFiles.defaults.boatClass.content.hull.length
        var worst = 0.0
        var total = 0.0
        for (a, b) in zip(today, off) {
            for (p, q) in zip(a, b) {
                let d = (p - q).length / hull
                worst = max(worst, d)
                total += d
            }
        }
        let mean = total / Double(today.count * 2)
        #expect(worst < 2, "a bot strayed \(worst) hull lengths from today's track")
        #expect(mean < 1, "the bots strayed \(mean) hull lengths on average")
    }
}
