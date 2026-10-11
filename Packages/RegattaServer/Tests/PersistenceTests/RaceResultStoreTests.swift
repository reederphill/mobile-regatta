import Foundation
import Persistence
import PostgresNIO
import Testing

/// #148: a closed race's log, digest, versions and results are written once, together; a cancelled race writes none;
/// a player's last race is the newest closed race she sat in.
@Suite(TestDatabase.available) struct RaceResultStoreTests {
    private static func closed(_ id: UUID, digest: UInt64 = 0xFEDC_BA98_7654_3210, rated: Bool = true) -> ClosedRaceRecord {
        ClosedRaceRecord(id: id, log: Data("{\"log\":1}".utf8), digest: digest, simulationVersion: "sim/1", toolchain: "swift-test",
                         results: Data("{\"rows\":[]}".utf8), incidents: Data("{\"incidents\":[]}".utf8), rated: rated)
    }

    private static func players(_ database: Database, _ ids: String...) async throws {
        for id in ids { _ = try await PlayerStore(database).signIn(teamPlayerID: id, gamePlayerID: "G" + id, displayName: id) }
    }

    @Test func testClosedRaceWritesItsResultsLogAndDigestAtomically() async throws {
        try await TestDatabase.withMigratedSchema { database in
            try await Self.players(database, "T:a", "T:b")
            let registry = RaceRegistryStore(database), results = RaceResultStore(database)
            let race = try await registry.create(players: [RaceSeatHolder(playerID: "T:a", seat: 0), RaceSeatHolder(playerID: "T:b", seat: 1)])
            #expect(try await results.players(of: race.id) == [RaceSeatHolder(playerID: "T:a", seat: 0), RaceSeatHolder(playerID: "T:b", seat: 1)])
            #expect(try await results.results(for: race.id) == nil)

            let record = Self.closed(race.id)
            let closed = try await results.close(record)
            #expect(closed.state == .closed && closed.digest == record.digest)
            #expect(closed.simulationVersion == "sim/1" && closed.toolchain == "swift-test")
            #expect(try await RaceLogStore(database).log(for: race.id) == record.log)
            let stored = try #require(try await results.results(for: race.id))
            #expect(stored.results == record.results && stored.incidents == record.incidents && stored.rated)
            #expect(try await results.lastRace(of: "T:b")?.seat == 1)
            await #expect(throws: PersistenceError.raceNotInState(race.id, expected: .running, actual: .closed)) {
                try await results.close(record)
            }
        }
    }

    /// The close is one transaction: a log already there fails it, and nothing of it is written.
    @Test func testAFailedCloseWritesNothing() async throws {
        try await TestDatabase.withMigratedSchema { database in
            let registry = RaceRegistryStore(database), results = RaceResultStore(database)
            let race = try await registry.create()
            try await RaceLogStore(database).put(Data([1]), for: race.id)
            await #expect(throws: PersistenceError.raceLogExists(race.id)) { try await results.close(Self.closed(race.id)) }
            #expect(try await registry.race(race.id)?.state == .running)
            #expect(try await registry.race(race.id)?.digest == nil)
            #expect(try await results.results(for: race.id) == nil)
        }
    }

    @Test func testCancelledRaceWritesNoResults() async throws {
        try await TestDatabase.withMigratedSchema { database in
            try await Self.players(database, "T:a")
            let registry = RaceRegistryStore(database), results = RaceResultStore(database)
            let race = try await registry.create(players: [RaceSeatHolder(playerID: "T:a", seat: 0)])
            #expect(try await registry.cancelOrphans() == [race.id])
            #expect(try await results.results(for: race.id) == nil)
            #expect(try await results.lastRace(of: "T:a") == nil)
            await #expect(throws: PersistenceError.raceNotInState(race.id, expected: .running, actual: .cancelled)) {
                try await results.close(Self.closed(race.id))
            }
            try await registry.delete(race.id)
            #expect(try await results.players(of: race.id).isEmpty)
        }
    }

    /// The last race stays until the next one closes; a cancelled race in between doesn't replace it.
    @Test func testLastRaceIsTheNewestClosedRace() async throws {
        try await TestDatabase.withMigratedSchema { database in
            try await Self.players(database, "T:a")
            let registry = RaceRegistryStore(database), results = RaceResultStore(database)
            let seat = { (s: Int) in [RaceSeatHolder(playerID: "T:a", seat: s)] }
            let first = try await registry.create(players: seat(0))
            try await results.close(Self.closed(first.id, digest: 1))
            let second = try await registry.create(players: seat(2))
            #expect(try await results.lastRace(of: "T:a")?.raceID == first.id)
            try await registry.cancel(second.id)
            #expect(try await results.lastRace(of: "T:a")?.raceID == first.id)
            let third = try await registry.create(players: seat(1))
            try await results.close(Self.closed(third.id, digest: 3, rated: false))
            let last = try #require(try await results.lastRace(of: "T:a"))
            #expect(last.raceID == third.id && last.seat == 1 && !last.rated)
            #expect(try await results.lastRace(of: "T:nobody") == nil)
        }
    }

    /// #149: a closed race's bots are written with the close and read back as written; a cancelled race has none.
    @Test func botsRoundTripAndACancelledRaceHasNone() async throws {
        try await TestDatabase.withMigratedSchema { database in
            try await Self.players(database, "T:a", "T:b")
            let registry = RaceRegistryStore(database), results = RaceResultStore(database)
            let bots = [
                StoredRaceBot(seat: 1, source: .takeover, rating: 1362, skill: 0.4948, handling: 0.61, mapVersion: 1, takenTick: -1200),
                StoredRaceBot(seat: 2, source: .fill, rating: 1650, skill: 0.65, handling: 0.4125, mapVersion: 1),
                StoredRaceBot(seat: 3, source: .fill, rating: 1500, skill: 0.55, handling: 0.75, mapVersion: 1),
            ]
            let seats = [RaceSeatHolder(playerID: "T:a", seat: 0), RaceSeatHolder(playerID: "T:b", seat: 1)]
            let race = try await registry.create(players: seats)
            #expect(try await results.bots(of: race.id).isEmpty)
            let base = Self.closed(race.id)
            let record = ClosedRaceRecord(id: race.id, log: base.log, digest: base.digest, simulationVersion: base.simulationVersion,
                                          toolchain: base.toolchain, results: base.results, incidents: base.incidents, rated: true, bots: bots)
            try await results.close(record)
            #expect(try await results.bots(of: race.id) == bots)
            // The seat a bot took before the gun isn't its player's last race; the other player's is.
            #expect(try await results.lastRace(of: "T:a")?.raceID == race.id)
            #expect(try await results.lastRace(of: "T:b") == nil)

            // A seat is a bot's once, and a source is one of the two.
            let twice = try await registry.create()
            let again = ClosedRaceRecord(id: twice.id, log: base.log, digest: 2, simulationVersion: "sim/1", toolchain: "swift-test",
                                         results: base.results, incidents: base.incidents, rated: false, bots: [bots[1], bots[1]])
            await #expect(throws: (any Error).self) { try await results.close(again) }
            #expect(try await registry.race(twice.id)?.state == .running)
            #expect(try await results.bots(of: twice.id).isEmpty)

            // A cancelled race has none, and the closed race's are still as written.
            let cancelled = try await registry.create(players: [RaceSeatHolder(playerID: "T:a", seat: 0)])
            try await registry.cancel(cancelled.id)
            #expect(try await results.bots(of: cancelled.id).isEmpty)
            #expect(try await results.lastRace(of: "T:a")?.raceID == race.id)
            #expect(try await results.bots(of: race.id) == bots)
        }
    }

    /// A player's races go with her (G8).
    @Test func testDeletingAPlayerDeletesHerSeats() async throws {
        try await TestDatabase.withMigratedSchema { database in
            try await Self.players(database, "T:a")
            let race = try await RaceRegistryStore(database).create(players: [RaceSeatHolder(playerID: "T:a", seat: 0)])
            #expect(try await PlayerStore(database).delete(teamPlayerID: "T:a"))
            #expect(try await RaceResultStore(database).players(of: race.id).isEmpty)
        }
    }
}
