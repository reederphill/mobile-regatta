import Foundation
@testable import Persistence
import PostgresNIO
import RegattaCore
import Testing

@Suite struct MigratorTests {
    private func migration(_ version: Int) -> Migration {
        Migration(version: version, name: "m\(version)", up: ["SELECT 1"], down: ["SELECT 1"])
    }

    @Test func testServerMigrationsAreNumberedInSequence() throws {
        try Migrator.validate(Migration.all)
        #expect(Migration.all.map(\.version) == Array(1...Migration.all.count))
        #expect(Set(Migration.all.map(\.name)).count == Migration.all.count)
    }

    @Test func testMigrationsOutOfSequenceAreRefused() {
        #expect(throws: Migrator.ValidationError.versionOutOfSequence(expected: 2, found: 3)) {
            try Migrator(migrations: [migration(1), migration(3)])
        }
        #expect(throws: Migrator.ValidationError.versionOutOfSequence(expected: 2, found: 1)) {
            try Migrator(migrations: [migration(1), migration(1)])
        }
        #expect(throws: Migrator.ValidationError.emptyMigration(version: 1)) {
            try Migrator(migrations: [Migration(version: 1, name: "empty", up: [], down: ["SELECT 1"])])
        }
    }

    @Test func testPendingAndRevertingFollowTheAppliedVersions() throws {
        let migrator = try Migrator(migrations: (1...4).map(migration))
        #expect(try migrator.pending(applied: []).map(\.version) == [1, 2, 3, 4])
        #expect(try migrator.pending(applied: [1, 2]).map(\.version) == [3, 4])
        #expect(try migrator.reverting(applied: [1, 2, 3, 4], to: 1).map(\.version) == [4, 3, 2])
        #expect(try migrator.reverting(applied: [1, 2], to: 0).map(\.version) == [2, 1])
        #expect(try migrator.reverting(applied: [1, 2], to: 3).isEmpty)
        #expect(throws: Migrator.MigrationError.unknownAppliedVersion(5)) { try migrator.pending(applied: [1, 5]) }
        #expect(throws: Migrator.MigrationError.targetOutOfRange(5)) { try migrator.reverting(applied: [1], to: 5) }
    }

    /// Acceptance (#144): every migration goes up on an empty database and all the way down again, leaving it
    /// empty but for `schema_migrations`, and goes up again after.
    @Test(TestDatabase.available) func testMigrationsUpAndDownOnEmptyDatabase() async throws {
        try await TestDatabase.withFreshSchema { database in
            let migrator = try Migrator()
            let all = Migration.all.map(\.version)
            #expect(try await tables(database) == [])

            #expect(try await migrator.up(database) == all)
            #expect(try await migrator.applied(database) == all)
            #expect(try await tables(database)
                == ["analytics_daily", "analytics_daily_properties", "analytics_events", "briefing_leaves", "data_files", "lobby_blocks", "lobby_messages", "moderation_penalties", "moderation_reports", "player_liveries", "player_stats", "players", "race_bots", "race_files", "race_logs", "race_players",
                    "race_results", "races", "rating_history", "ratings", "schema_migrations", "sessions", "terms_acceptances"])
            #expect(try await migrator.up(database) == [])

            #expect(try await migrator.down(database, to: 3) == [14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4])
            #expect(try await migrator.applied(database) == [1, 2, 3])
            #expect(try await tables(database) == ["data_files", "players", "schema_migrations", "sessions"])

            #expect(try await migrator.down(database, to: 0) == [3, 2, 1])
            #expect(try await migrator.applied(database) == [])
            #expect(try await tables(database) == ["schema_migrations"])
            #expect(try await functions(database) == [])

            #expect(try await migrator.up(database) == all)
            #expect(try await migrator.down(database, to: 0) == all.reversed())
        }
    }

    /// #149: migration 0009 adds `race_bots` alone, and takes it away again.
    @Test(TestDatabase.available) func testRaceBotsMigrationGoesUpAndDown() async throws {
        try await TestDatabase.withFreshSchema { database in
            let migrator = try Migrator()
            try await migrator.up(database)
            let with = try await tables(database)
            #expect(with.contains("race_bots"))
            #expect(try await migrator.down(database, to: 8) == [14, 13, 12, 11, 10, 9])
            #expect(try await tables(database) == with.filter { !(["race_bots", "player_stats", "rating_history", "ratings", "lobby_blocks", "lobby_messages"]
                + Self.analyticsTables + Self.liveryTables + Self.moderationTables).contains($0) })
            #expect(try await migrator.applied(database) == Array(1...8))
            #expect(try await migrator.up(database) == [9, 10, 11, 12, 13, 14])
            #expect(try await tables(database) == with)
        }
    }

    /// #151: migration 0010 adds the rating tables and `race_results.rating_state`, and takes them away again, with
    /// rows in them; a race closed before it reads as `none`.
    @Test(TestDatabase.available) func testRatingsMigrationGoesUpAndDown() async throws {
        try await TestDatabase.withFreshSchema { database in
            let migrator = try Migrator()
            try await migrator.up(database)
            let with = try await tables(database)
            let added = ["player_stats", "rating_history", "ratings"]
            #expect(added.allSatisfy(with.contains))
            #expect(try await migrator.down(database, to: 9) == [14, 13, 12, 11, 10])
            #expect(try await tables(database) == with.filter { !(added + ["lobby_blocks", "lobby_messages"] + Self.analyticsTables + Self.liveryTables + Self.moderationTables).contains($0) })
            #expect(try await migrator.applied(database) == Array(1...9))

            // A race closed on the schema before it.
            _ = try await PlayerStore(database).signIn(teamPlayerID: "T:a", gamePlayerID: "G:a", displayName: "a")
            let race = try await RaceRegistryStore(database).create(players: [RaceSeatHolder(playerID: "T:a", seat: 0)])
            try await database.client.query("UPDATE races SET state = 'closed', ended_at = now() WHERE id = \(race.id)")
            try await database.client.query("INSERT INTO race_results (race_id, results, incidents, rated) VALUES (\(race.id), '\\x7b7d', '\\x7b7d', true)")

            #expect(try await migrator.up(database) == [10, 11, 12, 13, 14])
            #expect(try await tables(database) == with)
            let old = try #require(try await RaceResultStore(database).lastRace(of: "T:a"))
            #expect(old.ratingState == .none && old.ratingChange == nil)
            #expect(try await RatingStore(database).ratings(of: ["T:a"]).isEmpty)
            #expect(try await RatingStore(database).reset("T:a", reason: "test", at: Date()))
            #expect(try await migrator.down(database, to: 9) == [14, 13, 12, 11, 10])
            #expect(try await migrator.up(database) == [10, 11, 12, 13, 14])
            #expect(try await RatingStore(database).ratings(of: ["T:a"]).isEmpty)
        }
    }

    /// #152: migration 0011 adds the lobby's two tables alone, and takes them away again, with rows in them.
    @Test(TestDatabase.available) func testLobbyMigrationGoesUpAndDown() async throws {
        try await TestDatabase.withFreshSchema { database in
            let migrator = try Migrator()
            try await migrator.up(database)
            let with = try await tables(database)
            let added = ["lobby_blocks", "lobby_messages"]
            #expect(added.allSatisfy(with.contains))
            for name in ["a", "b"] { _ = try await PlayerStore(database).signIn(teamPlayerID: "T:\(name)", gamePlayerID: "G:\(name)", displayName: name) }
            let store = LobbyMessageStore(database)
            _ = try await store.append(StoredLobbyLine(kind: .gun, venue: "Bay", boats: 10, humans: 2, createdAt: Date()))
            try await store.block("T:b", by: "T:a", at: Date())
            #expect(try await migrator.down(database, to: 10) == [14, 13, 12, 11])
            #expect(try await tables(database) == with.filter { !(added + Self.analyticsTables + Self.liveryTables + Self.moderationTables).contains($0) })
            #expect(try await migrator.applied(database) == Array(1...10))
            #expect(try await PlayerStore(database).player(teamPlayerID: "T:a") != nil)
            #expect(try await migrator.up(database) == [11, 12, 13, 14])
            #expect(try await tables(database) == with)
            #expect(try await store.recent(since: .distantPast, limit: 10).isEmpty)
            #expect(try await store.blocks().isEmpty)
        }
    }

    static let analyticsTables = ["analytics_daily", "analytics_daily_properties", "analytics_events"]
    static let liveryTables = ["player_liveries"]
    static let moderationTables = ["moderation_penalties", "moderation_reports"]

    /// #156: migration 0012 adds the analytics tables alone, and takes them away again, with rows in them.
    @Test(TestDatabase.available) func testAnalyticsMigrationGoesUpAndDown() async throws {
        try await TestDatabase.withFreshSchema { database in
            let migrator = try Migrator()
            try await migrator.up(database)
            let with = try await tables(database)
            #expect(Self.analyticsTables.allSatisfy(with.contains))
            let store = AnalyticsEventStore(database)
            let time = Date(timeIntervalSince1970: 1_791_460_800)
            _ = try await store.recordDevice([StoredAnalyticsEvent(source: .device, installID: "i", sequence: 1, name: "drop",
                                                                   day: StoredAnalyticsEvent.day(of: time), occurredAt: time, receivedAt: time)])
            try await store.rollUp(limit: 10)
            #expect(try await migrator.down(database, to: 11) == [14, 13, 12])
            #expect(try await tables(database) == with.filter { !(Self.analyticsTables + Self.liveryTables + Self.moderationTables).contains($0) })
            #expect(try await migrator.up(database) == [12, 13, 14])
            #expect(try await tables(database) == with)
            #expect(try await store.rawCount() == 0)
            #expect(try await store.daily(.device, "drop").isEmpty)
        }
    }

    /// #159: migration 0013 adds `player_liveries` alone, and takes it away again, with a row in it.
    @Test(TestDatabase.available) func testLiveriesMigrationGoesUpAndDown() async throws {
        try await TestDatabase.withFreshSchema { database in
            let migrator = try Migrator()
            try await migrator.up(database)
            let with = try await tables(database)
            #expect(Self.liveryTables.allSatisfy(with.contains))
            _ = try await PlayerStore(database).signIn(teamPlayerID: "T:a", gamePlayerID: "G:a", displayName: "a")
            let livery = Livery(design: DesignID("skiff-plain"), colours: [SwatchID("charcoal"), SwatchID("off-white")], sailNumber: 7)
            #expect(try await PlayerLiveryStore(database).save(livery, for: "T:a", at: Date()))
            #expect(try await migrator.down(database, to: 12) == [14, 13])
            #expect(try await tables(database) == with.filter { !(Self.liveryTables + Self.moderationTables).contains($0) })
            #expect(try await migrator.up(database) == [13, 14])
            #expect(try await tables(database) == with)
            #expect(try await PlayerLiveryStore(database).livery(of: "T:a") == nil)
        }
    }

    /// #153: migration 0014 adds the moderation tables alone, and takes them away again, with rows in them.
    @Test(TestDatabase.available) func testModerationMigrationGoesUpAndDown() async throws {
        try await TestDatabase.withFreshSchema { database in
            let migrator = try Migrator()
            try await migrator.up(database)
            let with = try await tables(database)
            #expect(Self.moderationTables.allSatisfy(with.contains))
            let store = ModerationRecordStore(database), time = Date(timeIntervalSince1970: 1_791_460_800)
            let report = try await store.file(StoredReport(kind: .player, reporterID: "T:a", subjectID: "T:b", subjectNickname: "b",
                                                           createdAt: time, dueAt: time + 86_400))
            _ = try await store.add(StoredPenalty(playerID: "T:b", kind: .nicknameOverride, actorID: "admin", reportID: report.id, startsAt: time))
            #expect(try await migrator.down(database, to: 13) == [14])
            #expect(try await tables(database) == with.filter { !Self.moderationTables.contains($0) })
            #expect(try await migrator.up(database) == [14])
            #expect(try await tables(database) == with)
            #expect(try await store.penalties(of: "T:b").isEmpty)
        }
    }

    /// A migration that fails leaves nothing behind: `up()` is one transaction.
    @Test(TestDatabase.available) func testFailedMigrationRollsBack() async throws {
        try await TestDatabase.withFreshSchema { database in
            let broken = try Migrator(migrations: [
                Migration(version: 1, name: "ok", up: ["CREATE TABLE ok (id int)"], down: ["DROP TABLE ok"]),
                Migration(version: 2, name: "broken", up: ["CREATE TABLE nope (id no_such_type)"], down: ["SELECT 1"]),
            ])
            await #expect(throws: (any Error).self) { try await broken.up(database) }
            #expect(try await Migrator().applied(database) == [])
            #expect(try await tables(database) == ["schema_migrations"])
        }
    }

    private func tables(_ database: Database) async throws -> [String] {
        let rows = try await database.client.query("""
            SELECT table_name::text FROM information_schema.tables WHERE table_schema = current_schema() ORDER BY 1
            """)
        var names: [String] = []
        for try await name in rows.decode(String.self) { names.append(name) }
        return names
    }

    private func functions(_ database: Database) async throws -> [String] {
        let rows = try await database.client.query("""
            SELECT routine_name::text FROM information_schema.routines WHERE routine_schema = current_schema() ORDER BY 1
            """)
        var names: [String] = []
        for try await name in rows.decode(String.self) { names.append(name) }
        return names
    }
}

@Suite struct DatabaseConfigurationTests {
    @Test func testDatabaseURLIsParsed() throws {
        let full = try DatabaseConfiguration(url: "postgres://regatta:p%40ss@db.example:6543/races?sslmode=require")
        #expect(full == DatabaseConfiguration(host: "db.example", port: 6543, username: "regatta", password: "p@ss",
                                              database: "races", tls: .require))
        let local = try DatabaseConfiguration(url: "postgresql://phill@localhost/regatta_test")
        #expect(local == DatabaseConfiguration(host: "localhost", username: "phill", database: "regatta_test"))
    }

    @Test func testBadDatabaseURLsAreRefused() {
        #expect(throws: DatabaseConfiguration.URLError.unsupportedScheme("mysql")) {
            try DatabaseConfiguration(url: "mysql://u@h/d")
        }
        #expect(throws: DatabaseConfiguration.URLError.missingUser) { try DatabaseConfiguration(url: "postgres://h/d") }
        #expect(throws: DatabaseConfiguration.URLError.malformed) { try DatabaseConfiguration(url: "postgres://u:secret@h:port/d") }
        #expect(throws: DatabaseConfiguration.URLError.unsupportedSSLMode("verify-full")) {
            try DatabaseConfiguration(url: "postgres://u@h/d?sslmode=verify-full")
        }
    }

    @Test func testServerReadsRegattaDatabaseURL() throws {
        #expect(try DatabaseConfiguration.fromEnvironment([:]) == nil)
        #expect(try DatabaseConfiguration.fromEnvironment(["REGATTA_DATABASE_URL": "postgres://u@h:1/d"])
            == DatabaseConfiguration(host: "h", port: 1, username: "u", database: "d"))
    }
}
