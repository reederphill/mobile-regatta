import Foundation
import Testing
@testable import RegattaCore

/// #151: a stored log says which seats' humans were at the gun, from the code the race scores `rated` by.
@Suite struct RaceLogPresenceTests {
    /// One race's seat events: who joins, and what happens before and after the gun (1 s of sequence: tick -30…0).
    struct Script: Sendable, CustomStringConvertible {
        var name: String
        var seats: [SeatKind]
        /// (tick, seat, event), in order; every seat joins at the first tick unless `unjoined`.
        var events: [(Int, Int, SeatEvent.Kind)]
        var unjoined: Set<Int> = []
        var atGun: [Int]
        var description: String { name }
    }

    static let scripts: [Script] = [
        Script(name: "all four at the gun", seats: [.human, .human, .human, .human], events: [], atGun: [0, 1, 2, 3]),
        Script(name: "bots are never at the gun", seats: [.human, .bot, .human, .bot], events: [], atGun: [0, 2]),
        Script(name: "one human and bots", seats: [.human, .bot, .bot], events: [], atGun: [0]),
        Script(name: "a seat given away before the gun", seats: [.human, .human, .human],
               events: [(-20, 1, .leftBeforeGun), (-20, 1, .botTookOver(.fleet))], atGun: [0, 2]),
        Script(name: "given away, leaving one", seats: [.human, .human, .bot],
               events: [(-20, 1, .leftBeforeGun), (-20, 1, .botTookOver(.fleet))], atGun: [0]),
        Script(name: "dropped before the gun, back before it", seats: [.human, .human],
               events: [(-25, 1, .dropped), (-5, 1, .rejoined)], atGun: [0, 1]),
        Script(name: "dropped before the gun, back after it", seats: [.human, .human, .human],
               events: [(-25, 1, .dropped), (20, 1, .rejoined)], atGun: [0, 2]),
        Script(name: "a late rejoiner leaves one at the gun", seats: [.human, .human],
               events: [(-25, 1, .dropped), (20, 1, .rejoined)], atGun: [0]),
        Script(name: "never attached", seats: [.human, .human, .human], events: [(-10, 2, .dropped)], unjoined: [2], atGun: [0, 1]),
        Script(name: "left after the gun", seats: [.human, .human, .bot], events: [(15, 1, .left)], atGun: [0, 1]),
        Script(name: "dropped after the gun", seats: [.human, .human], events: [(15, 0, .dropped), (15, 0, .botTookOver(.cautious))],
               atGun: [0, 1]),
        Script(name: "only disconnected at the gun", seats: [.human, .human], events: [(-3, 1, .disconnected)], atGun: [0, 1]),
    ]

    @Test(arguments: scripts) func humansAtGunAgreesWithRated(_ script: Script) throws {
        let race = testRace(seats: script.seats, prestartSeconds: 1, seed: 151)
        for seat in race.boats.indices where !script.unjoined.contains(seat) { race.record(.joined(race.setup.seats[seat]), seat: seat) }
        for (tick, seat, kind) in script.events {
            while race.tick < tick { race.step() }
            race.record(kind, seat: seat)
        }
        while race.tick < 40 { race.step() }
        let humans = script.seats.indices.filter { script.seats[$0] == .human }
        #expect(race.closeAllGone(atTick: race.tick, leaveOrder: humans) || race.isOver)
        let results = try #require(race.results), log = try #require(race.log)
        #expect(log.humanSeatsAtGun == script.atGun)
        #expect(results.rated == (log.humanSeatsAtGun.count >= 2))
        // The stored form says the same, and so does its replay.
        let stored = try RaceLog(jsonData: log.jsonData())
        #expect(stored.humanSeatsAtGun == script.atGun)
        #expect(try Replayer.replay(stored).results?.rated == results.rated)
    }

    /// The checked-in 16-seat log (every kind of seat event): only human seats, and the same list from its bytes.
    @Test func theGoldenLogsHumansAtTheGunAreHumanSeats() throws {
        let log = try ScriptedLog.fixture()
        let humans = Set(ScriptedLog.seats.indices.filter { ScriptedLog.seats[$0] == .human })
        #expect(Set(log.humanSeatsAtGun).isSubset(of: humans))
        #expect(log.humanSeatsAtGun == log.humanSeatsAtGun.sorted())
        #expect(try RaceLog(jsonData: log.jsonData()).humanSeatsAtGun == log.humanSeatsAtGun)
    }
}
