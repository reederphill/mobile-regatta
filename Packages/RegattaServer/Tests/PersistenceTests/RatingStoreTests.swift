import Foundation
import Persistence
import PostgresNIO
import Ratings
import Testing

/// #151: a race's ratings and profile counts are written in the transaction that closes it, exactly once; a rating step
/// that fails leaves the race closed and marked; a close that fails leaves no ratings.
@Suite(TestDatabase.available) struct RatingStoreTests {
    static let time = Date(timeIntervalSince1970: 1_800_000_000)

    private static func players(_ database: Database, _ ids: String...) async throws {
        for id in ids { _ = try await PlayerStore(database).signIn(teamPlayerID: id, gamePlayerID: "G" + id, displayName: "N" + id) }
    }

    /// A race for `ids` in seats 0…, and the record that closes it with them placed in that order (unless `places`).
    private static func race(_ database: Database, _ ids: [String], places: [Int]? = nil, rated: Bool = true, at time: Date = time,
                             config: RatingConfig = RatingConfig(), bots: [StoredRaceBot] = []) async throws -> ClosedRaceRecord {
        let stored = Set(try await RatingStore(database).shownIDs(ids))
        let race = try await RaceRegistryStore(database).create(
            players: ids.enumerated().filter { stored.contains($0.element) }.map { RaceSeatHolder(playerID: $0.element, seat: $0.offset) })
        let places = places ?? Array(1...ids.count)
        return ClosedRaceRecord(
            id: race.id, log: Data("{}".utf8), digest: 1, simulationVersion: "sim/1", toolchain: "swift-test", results: Data("{}".utf8),
            incidents: Data("{}".utf8), rated: rated, bots: bots,
            rating: rated ? RatingInput(participants: zip(ids, places).map { RatingInput.Participant(playerID: $0, place: $1) }, ratedAt: time,
                                        config: config) : nil,
            stats: zip(ids, places).map { PlayerRaceStat(playerID: $0, completed: true, won: $1 == 1) })
    }

    private static func count(_ database: Database, _ table: String) async throws -> Int {
        let rows = try await database.client.query(PostgresQuery(unsafeSQL: "SELECT count(*) FROM \(table)"))
        for try await count in rows.decode(Int.self) { return count }
        return -1
    }

    private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= 0.05 }

    @Test func closeAppliesRatingsInTheClosingTransaction() async throws {
        try await TestDatabase.withMigratedSchema { database in
            try await Self.players(database, "T:a", "T:b")
            let results = RaceResultStore(database), ratings = RatingStore(database)
            #expect(try await ratings.ratings(of: ["T:a", "T:b"]).isEmpty, "no row until a race rates her")
            let record = try await Self.race(database, ["T:a", "T:b"])
            let closed = try await results.closing(record)
            #expect(closed.record.state == .closed && closed.rating.state == .applied)
            #expect(closed.rating.changes.map(\.playerID) == ["T:a", "T:b"])

            let stored = try await ratings.ratings(of: ["T:a", "T:b", "T:nobody"])
            let a = try #require(stored["T:a"]), b = try #require(stored["T:b"])
            #expect(near(a.glicko.rating, 1662.21) && near(b.glicko.rating, 1337.79) && near(a.glicko.deviation, 290.23))
            #expect(a.ratedRaces == 1 && !a.established && a.lastRatedAt == Self.time && stored["T:nobody"] == nil)
            #expect(closed.rating.changes[0].after == a && closed.rating.changes[0].before == PlayerRating())

            let history = try await ratings.changes(of: record.id)
            #expect(history.map(\.playerID) == ["T:a", "T:b"] && history.map(\.place) == [1, 2] && history.map(\.opponents) == [1, 1])
            #expect(history[0].before.glicko == Glicko2() && history[0].after.glicko == a.glicko)
            #expect(try await results.results(for: record.id)?.ratingState == .applied)
            let last = try #require(try await results.lastRace(of: "T:b"))
            #expect(last.ratingState == .applied && last.ratingChange?.before.displayed == 1500 && last.ratingChange?.after.displayed == 1338)
            #expect(last.ratingChange?.after.isProvisional == true)
            #expect(try await ratings.standing(of: "T:a") == PlayerStanding(displayName: "NT:a", rating: a, completedRaces: 1, wins: 1))
            #expect(try await ratings.standing(of: "T:b")?.wins == 0)
            #expect(try await ratings.standing(of: "T:nobody") == nil)

            // Closed is rated exactly once: a second close of the same race changes nothing.
            await #expect(throws: PersistenceError.raceNotInState(record.id, expected: .running, actual: .closed)) {
                try await results.closing(record)
            }
            #expect(try await ratings.ratings(of: ["T:a"])["T:a"] == a)
            #expect(try await Self.count(database, "rating_history") == 2)
            #expect(try await ratings.standing(of: "T:a")?.completedRaces == 1)

            // The next race starts from what this one left, a day on.
            let next = try await Self.race(database, ["T:b", "T:a"], at: Self.time + 86_400)
            let again = try await results.closing(next).rating
            #expect(again.changes.first { $0.playerID == "T:a" }?.before == a)
            #expect(try await ratings.ratings(of: ["T:a"])["T:a"]?.ratedRaces == 2)
        }
    }

    /// A close that fails after the rating step (here: its bots can't be written) leaves the race running and nothing
    /// of the ratings, counts or history: what a crash before the commit leaves. The restart then cancels the race.
    @Test func failedCloseWritesNoRatings() async throws {
        try await TestDatabase.withMigratedSchema { database in
            try await Self.players(database, "T:a", "T:b")
            let bot = StoredRaceBot(seat: 2, source: .fill, rating: 1500, skill: 0.5, handling: 0.5, mapVersion: 1)
            let record = try await Self.race(database, ["T:a", "T:b"], bots: [bot, bot])
            await #expect(throws: (any Error).self) { try await RaceResultStore(database).closing(record) }
            #expect(try await RaceRegistryStore(database).race(record.id)?.state == .running)
            #expect(try await RatingStore(database).ratings(of: ["T:a", "T:b"]).isEmpty)
            for table in ["rating_history", "player_stats", "ratings"] { #expect(try await Self.count(database, table) == 0) }
            #expect(try await RaceRegistryStore(database).cancelOrphans() == [record.id])
            #expect(try await RaceResultStore(database).lastRace(of: "T:a") == nil)
            for table in ["rating_history", "player_stats", "ratings"] { #expect(try await Self.count(database, table) == 0) }
        }
    }

    /// The rating step fails (the history can't be written; then a parameter that makes no number): the close commits
    /// with its log and results, marked `failed`, nobody's rating moved, and the profile counts are kept.
    @Test func ratingFailureCommitsTheCloseAndMarksFailed() async throws {
        try await TestDatabase.withMigratedSchema { database in
            try await Self.players(database, "T:a", "T:b")
            let results = RaceResultStore(database), ratings = RatingStore(database)
            let first = try await Self.race(database, ["T:a", "T:b"])
            try await results.close(first)
            let before = try await ratings.ratings(of: ["T:a", "T:b"])

            try await database.client.query("ALTER TABLE rating_history ADD CONSTRAINT broken CHECK (place > 99) NOT VALID")
            let second = try await Self.race(database, ["T:b", "T:a"], at: Self.time + 3_600)
            let outcome = try await results.closing(second)
            #expect(outcome.record.state == .closed && outcome.rating.state == .failed && outcome.rating.changes.isEmpty)
            #expect(outcome.rating.failure?.isEmpty == false)
            #expect(try await RaceLogStore(database).log(for: second.id) == second.log)
            #expect(try await results.results(for: second.id)?.ratingState == .failed)
            #expect(try await ratings.ratings(of: ["T:a", "T:b"]) == before, "the ratings written before the history failed are rolled back")
            #expect(try await ratings.changes(of: second.id).isEmpty)
            #expect(try await ratings.standing(of: "T:b") == PlayerStanding(displayName: "NT:b", rating: before["T:b"], completedRaces: 2, wins: 1))
            let last = try #require(try await results.lastRace(of: "T:a"))
            #expect(last.raceID == second.id && last.ratingState == .failed && last.ratingChange == nil)
            try await database.client.query("ALTER TABLE rating_history DROP CONSTRAINT broken")

            var nonsense = RatingConfig()
            nonsense.tau = .nan
            let third = try await Self.race(database, ["T:a", "T:b"], at: Self.time + 7_200, config: nonsense)
            #expect(try await results.closing(third).rating.state == .failed)
            #expect(try await ratings.ratings(of: ["T:a", "T:b"]) == before)

            // The store is whole afterwards: the next race is rated.
            let fourth = try await Self.race(database, ["T:a", "T:b"], at: Self.time + 10_800)
            #expect(try await results.closing(fourth).rating.state == .applied)
        }
    }

    @Test func historyIsUniquePerRacePlayer() async throws {
        try await TestDatabase.withMigratedSchema { database in
            try await Self.players(database, "T:a", "T:b")
            let results = RaceResultStore(database)
            let record = try await Self.race(database, ["T:a", "T:b"])
            try await results.close(record)
            await #expect(throws: (any Error).self) {
                try await database.client.query("""
                    INSERT INTO rating_history (player_id, race_id, kind, at, before_rating, before_deviation, before_volatility,
                        before_established, after_rating, after_deviation, after_volatility, after_established)
                    VALUES ('T:a', \(record.id), 'race', now(), 1500, 350, 0.06, false, 1500, 350, 0.06, false)
                    """)
            }
            // A participant named twice is no fleet: nothing is rated, and the race still closes.
            let twice = try await RaceRegistryStore(database).create(players: [RaceSeatHolder(playerID: "T:a", seat: 0)])
            let named = ClosedRaceRecord(
                id: twice.id, log: Data("{}".utf8), digest: 2, simulationVersion: "sim/1", toolchain: "t", results: Data("{}".utf8),
                incidents: Data("{}".utf8), rated: true,
                rating: RatingInput(participants: [.init(playerID: "T:a", place: 1), .init(playerID: "T:a", place: 2)], ratedAt: Self.time + 60))
            #expect(try await results.closing(named).rating.state == .failed)
            #expect(try await Self.count(database, "rating_history") == 2)
        }
    }

    @Test func resetGivesProvisional1500() async throws {
        try await TestDatabase.withMigratedSchema { database in
            try await Self.players(database, "T:a", "T:b")
            let ratings = RatingStore(database)
            try await database.client.query("""
                INSERT INTO ratings (player_id, rating, deviation, volatility, rated_races, established, last_rated_at, mirrored_rating)
                VALUES ('T:a', 1812.4, 61, 0.058, 40, true, now(), 1812)
                """)
            #expect(try await ratings.reset("T:a", reason: "collusion, case 12", at: Self.time))
            let fresh = try #require(try await ratings.ratings(of: ["T:a"])["T:a"])
            #expect(fresh == PlayerRating() && fresh.isProvisional && fresh.displayed == 1500)
            let rows = try await database.client.query(
                "SELECT kind, race_id IS NULL, before_rating, before_established, after_rating, note FROM rating_history WHERE player_id = 'T:a'")
            var history: [String] = []
            for try await (kind, noRace, before, was, after, note) in rows.decode((String, Bool, Double, Bool, Double, String?).self) {
                history.append("\(kind) \(noRace) \(before) \(was) \(after) \(note ?? "")")
            }
            #expect(history == ["reset true 1812.4 true 1500.0 collusion, case 12"])
            // What the leaderboard was last sent is untouched; she is provisional, so nothing new is sent.
            let mirrored = try await database.client.query("SELECT mirrored_rating FROM ratings WHERE player_id = 'T:a'")
            for try await value in mirrored.decode(Int?.self) { #expect(value == 1812) }
            #expect(try await ratings.mirrorPending(maxFailures: 5, limit: 10).isEmpty)
            // A new player can be reset too; a player who isn't stored can't.
            #expect(try await ratings.reset("T:b", reason: "test", at: Self.time))
            #expect(try await ratings.reset("T:nobody", reason: "test", at: Self.time) == false)
        }
    }

    /// The counts come from every closed race, rated or not; an unrated race writes no rating and no history.
    @Test func statsCountCompletedCodesAndWins() async throws {
        try await TestDatabase.withMigratedSchema { database in
            try await Self.players(database, "T:a", "T:b")
            let results = RaceResultStore(database), ratings = RatingStore(database)
            // One human and bots: she wins. Unrated.
            var solo = try await Self.race(database, ["T:a"], rated: false)
            #expect(try await results.closing(solo).rating == .none)
            #expect(try await results.results(for: solo.id)?.ratingState == RatingState.none)
            #expect(try await ratings.standing(of: "T:a") == PlayerStanding(displayName: "NT:a", rating: nil, completedRaces: 1, wins: 1))
            #expect(try await Self.count(database, "ratings") == 0)
            #expect(try await Self.count(database, "rating_history") == 0)
            #expect(try await results.lastRace(of: "T:a")?.ratingChange == nil)
            // Retired (not completed), then DSQ (completed, no win), then a cancelled race (nothing).
            for (completed, won) in [(false, false), (true, false)] {
                solo = try await Self.race(database, ["T:a"], rated: false)
                solo = ClosedRaceRecord(id: solo.id, log: solo.log, digest: 1, simulationVersion: "s", toolchain: "t", results: solo.results,
                                        incidents: solo.incidents, rated: false, stats: [PlayerRaceStat(playerID: "T:a", completed: completed, won: won)])
                try await results.close(solo)
            }
            let cancelled = try await Self.race(database, ["T:a"], rated: false)
            try await RaceRegistryStore(database).cancel(cancelled.id)
            #expect(try await ratings.standing(of: "T:a") == PlayerStanding(displayName: "NT:a", completedRaces: 2, wins: 1))
            #expect(try await ratings.standing(of: "T:b") == PlayerStanding(displayName: "NT:b"))
        }
    }

    /// A participant whose account went during the race (#160) isn't rated: the rest are, if 2 are left; else skipped.
    @Test func aDeletedParticipantIsLeftOut() async throws {
        try await TestDatabase.withMigratedSchema { database in
            try await Self.players(database, "T:a", "T:b", "T:c")
            let results = RaceResultStore(database), ratings = RatingStore(database)
            let three = try await Self.race(database, ["T:a", "T:b", "T:c"])
            #expect(try await PlayerStore(database).delete(teamPlayerID: "T:b"))
            let outcome = try await results.closing(three).rating
            #expect(outcome.state == .applied && outcome.changes.map(\.playerID) == ["T:a", "T:c"] && outcome.changes.map(\.opponents) == [1, 1])
            #expect(try await ratings.standing(of: "T:b") == nil)

            let two = try await Self.race(database, ["T:a", "T:c"], at: Self.time + 60)
            let before = try await ratings.ratings(of: ["T:a"])
            #expect(try await PlayerStore(database).delete(teamPlayerID: "T:c"))
            let skipped = try await results.closing(two).rating
            #expect(skipped.state == .skipped && skipped.changes.isEmpty)
            #expect(try await results.results(for: two.id)?.ratingState == .skipped)
            #expect(try await ratings.ratings(of: ["T:a"]) == before)
            #expect(try await ratings.standing(of: "T:a")?.completedRaces == 2)
            // Her history went with her.
            #expect(try await Self.count(database, "rating_history") == 1)
        }
    }

    /// Two races sharing a player close at once: the closes take their players' rows in one order, so neither waits
    /// on the other for ever and the second starts from what the first left.
    @Test func twoClosesSharingAPlayerAreSerialised() async throws {
        try await TestDatabase.withMigratedSchema { database in
            try await Self.players(database, "T:a", "T:b", "T:c")
            let results = RaceResultStore(database), ratings = RatingStore(database)
            for round in 0..<6 {
                let time = Self.time + Double(round) * 60
                let one = try await Self.race(database, ["T:a", "T:b"], at: time), other = try await Self.race(database, ["T:c", "T:a"], at: time)
                async let first = results.closing(one), second = results.closing(other)
                let outcomes = try await [first.rating, second.rating]
                #expect(outcomes.allSatisfy { $0.state == .applied })
                let mine = outcomes.compactMap { outcome in outcome.changes.first { $0.playerID == "T:a" } }
                #expect(mine.count == 2)
                #expect(mine[0].after == mine[1].before || mine[1].after == mine[0].before, "one close saw the other's result")
            }
            #expect(try await ratings.ratings(of: ["T:a"])["T:a"]?.ratedRaces == 12)
            #expect(try await ratings.standing(of: "T:a")?.completedRaces == 12)
            #expect(try await Self.count(database, "rating_history") == 24)
        }
    }

    @Test func theMirrorListsEstablishedPlayersWhoseRatingMoved() async throws {
        try await TestDatabase.withMigratedSchema { database in
            try await Self.players(database, "T:a", "T:b", "T:c")
            let ratings = RatingStore(database)
            try await database.client.query("""
                INSERT INTO ratings (player_id, rating, deviation, volatility, rated_races, established, mirrored_rating) VALUES
                    ('T:a', 1712.5, 70, 0.06, 20, true, NULL), ('T:b', 1400.2, 200, 0.06, 3, false, NULL), ('T:c', 1650.49, 60, 0.06, 30, true, 1650)
                """)
            #expect(try await ratings.mirrorPending(maxFailures: 5, limit: 10) == [MirrorEntry(playerID: "T:a", gamePlayerID: "GT:a", rating: 1713)])
            #expect(try await ratings.mirrorPending(["T:b", "T:c"], maxFailures: 5, limit: 10).isEmpty)
            try await ratings.mirrorFailed("T:a")
            try await ratings.mirrorFailed("T:a")
            #expect(try await ratings.mirrorPending(maxFailures: 2, limit: 10).isEmpty)
            #expect(try await ratings.mirrorPending(["T:a"], maxFailures: 3, limit: 10).count == 1)
            try await ratings.mirrored("T:a", rating: 1713)
            #expect(try await ratings.mirrorPending(maxFailures: 5, limit: 10).isEmpty)
        }
    }
}

extension RatingStore {
    /// The ids among `ids` that are stored players.
    func shownIDs(_ ids: [String]) async throws -> [String] {
        var stored: [String] = []
        for id in ids where try await standing(of: id) != nil { stored.append(id) }
        return stored
    }
}
