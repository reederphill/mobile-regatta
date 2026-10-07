import Foundation
@testable import Persistence
import PostgresNIO
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
                == ["data_files", "players", "race_files", "race_logs", "races", "schema_migrations", "sessions"])
            #expect(try await migrator.up(database) == [])

            #expect(try await migrator.down(database, to: 3) == [5, 4])
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
