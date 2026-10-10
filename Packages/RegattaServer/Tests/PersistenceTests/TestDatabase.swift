import Foundation
import Persistence
import PostgresNIO
import Testing

/// The Postgres the database tests run against: `REGATTA_TEST_DATABASE_URL` (ADR 0009, README). Without it the
/// database tests are skipped with that reason, except where `REGATTA_REQUIRE_DATABASE=1` (set only by CI's
/// `persistence` job), where they run and fail on the missing variable, so that job can't pass by skipping. `CI`
/// alone doesn't require it: GitHub sets `CI=true` on every runner, and the macOS job's check.sh has no database.
enum TestDatabase {
    static let urlKey = "REGATTA_TEST_DATABASE_URL"

    static var url: String? {
        guard let url = ProcessInfo.processInfo.environment[urlKey], !url.isEmpty else { return nil }
        return url
    }

    static let requireKey = "REGATTA_REQUIRE_DATABASE"

    static var isRequired: Bool { ProcessInfo.processInfo.environment[requireKey] == "1" }

    /// The trait every database test carries.
    static let available = ConditionTrait.enabled(
        if: url != nil || isRequired,
        "\(urlKey) is unset: no Postgres to test against (see docs/adr/0009-postgres-for-server-persistence.md)")

    /// Runs `body` against a fresh, empty schema of its own, dropped afterwards, so the tests run in parallel.
    static func withFreshSchema(_ body: @Sendable (Database) async throws -> Void) async throws {
        try await withFreshSchema { database, _ in try await body(database) }
    }

    /// As `withFreshSchema`, also handing `body` the schema's configuration, to open a second pool on it (a restart).
    static func withFreshSchema(_ body: @Sendable (Database, DatabaseConfiguration) async throws -> Void) async throws {
        guard let url else {
            Issue.record("\(urlKey) is unset but \(requireKey)=1: the persistence job must name its Postgres service")
            return
        }
        let base = try DatabaseConfiguration(url: url)
        let schema = "t_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        try await Database.withDatabase(base) { admin in
            try await admin.client.query(PostgresQuery(unsafeSQL: "CREATE SCHEMA \(schema)"))
            var schemaConfiguration = base
            schemaConfiguration.searchPath = schema
            let scoped = schemaConfiguration
            do {
                try await Database.withDatabase(scoped) { try await body($0, scoped) }
            } catch {
                _ = try? await admin.client.query(PostgresQuery(unsafeSQL: "DROP SCHEMA \(schema) CASCADE"))
                throw error
            }
            try await admin.client.query(PostgresQuery(unsafeSQL: "DROP SCHEMA \(schema) CASCADE"))
        }
    }

    /// A fresh schema with every migration applied.
    static func withMigratedSchema(_ body: @Sendable (Database) async throws -> Void) async throws {
        try await withFreshSchema { database in
            try await Migrator().up(database)
            try await body(database)
        }
    }
}
