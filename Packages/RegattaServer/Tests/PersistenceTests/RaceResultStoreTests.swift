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
