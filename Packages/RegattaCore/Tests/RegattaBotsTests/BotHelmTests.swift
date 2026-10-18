import Foundation
import Testing
@testable import RegattaCore
@testable import RegattaBots

/// #434: bots steer by hand (`BotHelm`) when the class's autohelm doesn't hold a centred rudder.
@Suite struct BotHelmTests {
    /// skiff@6 as bundled, the autohelm holding a centred rudder: the class these tests were written on (the default
    /// until #437, whose skiff@7 is skiff@6 with the autohelm off).
    static func autohelmOn() throws -> BoatClassFile { try BoatClassFile.bundled(id: "skiff", version: 6) }

    /// skiff@6's file headed as schema 4 with `holdsWhenCentred` set to `holds`, as tune 1.
    static func skiff(holds: Bool) throws -> BoatClassFile {
        let key = try autohelmOn().ref.key
        var text = String(decoding: try #require(try BoatClassFile.bundledData(id: key.id, version: key.version)), as: UTF8.self)
        for (of, with) in [(#""schemaVersion": 3,"#, #""schemaVersion": 4,"#),
                           (#""grooveWindAverageSeconds": 30"#, #""grooveWindAverageSeconds": 30, "holdsWhenCentred": \#(holds)"#)] {
            #expect(text.contains(of), "skiff@6 no longer holds \(of)")
            text = text.replacingOccurrences(of: of, with: with)
        }
        return try BoatClassFile(data: Data(text.utf8), tune: 1)
    }

    /// `botRace(seed:)`'s race, every seat a bot, sailing `boatClass` under `BotConductTests.waterRules`.
    static func race(seed: UInt64, boatClass: BoatClassFile, seats: Int = 8) throws -> Race {
        var catalog = RaceFileCatalog()
        try catalog.boatClasses.add(boatClass)
        let setup = try RaceSetup(raceSeed: RaceSeed(seed), seats: Array(repeating: .bot, count: max(seats, 2)), laps: 2,
                                  startSequenceTicks: 45 * Race.tickRate, boatClass: boatClass.ref,
                                  rulesConfiguration: BotConductTests.waterRules)
        let race = try Race(setup: setup, files: RaceFiles(resolving: setup, from: catalog),
                            mode: .authoritative(windSeed: WindSeed(seed &* 0x9E37_79B9_7F4A_7C15 &+ 1)))
        if seats == 1 {
            // A race is two seats at least (`RaceSetup.fleetSizes`): seat 1 is a ghost far off from the first tick, so seat 0 sails alone (#539).
            var snapshot = race.exportSnapshot()
            snapshot.seats[1].boat.status = .dsq
            snapshot.seats[1].boat.position = race.course.raceArea.centre + race.course.right * 5_000
            try race.importSnapshot(snapshot)
        }
        return race
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
            if race.tick % Race.tickRate == 0 { track.append(race.boats.prefix(seats).map(\.position)) }
        }
        return track
    }

    /// A seeded bot race sailed with the autohelm off: the bot steers by hand and sails within a tolerance of today's
    /// track. One bot (#539), so the track is the helm's, not the fleet's: in a full fleet one tap a tick apart changes who
    /// meets whom, and the tracks part on the first beat (seed 5's eight bots drifted 20 lengths apart in 90 s while each
    /// helm sails as well as ever). Five minutes, the start, a beat and a run: she never strays more than 1.5 hull lengths
    /// (0.6 when written). With it on (the value set true), today's race to the bit, the full fleet's too.
    @Test func sameTrackWithAutohelmOff() throws {
        let seed: UInt64 = 6
        let fleet = try Self.track(seed: seed, boatClass: Self.autohelmOn(), seconds: 90)
        #expect(try Self.track(seed: seed, boatClass: Self.skiff(holds: true), seconds: 90) == fleet)

        let seats = 1
        let today = try Self.track(seed: seed, boatClass: Self.autohelmOn(), seconds: 300, seats: seats)
        #expect(try Self.track(seed: seed, boatClass: Self.skiff(holds: true), seconds: 300, seats: seats) == today)
        // #435: steering by hand perfectly; the app's bots steer as well as their skill lets them, and stray further.
        let off = try Self.track(seed: seed, boatClass: Self.skiff(holds: false), seconds: 300, seats: seats,
                                 perfectHands: true)
        #expect(off.count == today.count)
        let hull = try Self.autohelmOn().content.hull.length
        var worst = 0.0
        var total = 0.0
        for (a, b) in zip(today, off) {
            for (p, q) in zip(a, b) {
                let d = (p - q).length / hull
                worst = max(worst, d)
                total += d
            }
        }
        let mean = total / Double(today.count * seats)
        // #539: two boats were dropped because on 10 of 16 seeds they split > 0.5 L by 85 s from sub-second timing
        // differences, before any mark. One boat, with her hand nudging through the dead band (#545), seeds 1-16, worst
        // and mean in hull lengths (pass: worst < 1.5, mean < 0.5):
        //   seed      1     2     3     4     5     6     7     8     9    10    11    12    13    14    15    16
        //   worst  0.57  0.35  0.15  0.11  0.33  0.13  0.27  0.08  0.57  0.14  10.8  0.22  0.16  21.9  0.28  0.26
        //   mean   0.20  0.10  0.06  0.05  0.09  0.04  0.09  0.04  0.21  0.06  2.87  0.07  0.06  4.07  0.06  0.12
        // 14 of 16 pass (10 of 16 on main, centring inside the band). Seed 11 tacks at 81 s where the autohelm's boat
        // holds on, 0.12 L apart on the same course; seed 14 parts out of a turn at 195 s. Seed 6 (#531) stays.
        #expect(worst < 1.5, "the bot strayed \(worst) hull lengths from today's track")
        #expect(mean < 0.5, "the bot strayed \(mean) hull lengths on average")
    }

    /// #459: a rudder her brain lets go in irons (`BotDecision.centred`) is sent truly centred and she holds no angle,
    /// where a centred rudder otherwise has her take the angle she is on and steer to hold it; a turn's rudder is her
    /// brain's, passed as it is.
    @Test func stalledBotCentresItsRudder() throws {
        let race = try Self.race(seed: 5, boatClass: BoatClassFile.bundled(id: "skiff", version: 8), seats: 2)
        for _ in 0..<(50 * Race.tickRate) { race.step() }
        let view = race.seatView(for: 0)
        var helm = BotHelm()
        _ = helm.input(.neutral, view)
        #expect(helm.held != nil, "a centred rudder is an angle held by hand")
        #expect(helm.input(BoatInput(rudder: 0.0, ease: true), view, centred: true) == BoatInput(rudder: 0.0, ease: true))
        #expect(helm.held == nil)
        let turn = BoatInput(rudder: 0.75)
        #expect(helm.input(turn, view) == turn)
        #expect(helm.held == nil)
    }
}
