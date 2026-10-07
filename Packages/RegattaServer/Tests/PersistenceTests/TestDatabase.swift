import Foundation
import Persistence
import PostgresNIO
import Testing

/// The Postgres the database tests run against: `REGATTA_TEST_DATABASE_URL` (ADR 0009, README). Without it the
/// database tests are skipped with that reason, except in CI (`CI=true`), where they run and fail on the missing
/// variable, so a CI job that lost its database can't pass by skipping.
enum TestDatabase {
    static let urlKey = "REGATTA_TEST_DATABASE_URL"

    static var url: String? {
        guard let url = ProcessInfo.processInfo.environment[urlKey], !url.isEmpty else { return nil }
        return url
    }

    static var isCI: Bool { ProcessInfo.processInfo.environment["CI"] == "true" }

    /// The trait every database test carries.
    static let available = ConditionTrait.enabled(
        if: url != nil || isCI,
        "\(urlKey) is unset: no Postgres to test against (see docs/adr/0009-postgres-for-server-persistence.md)")

    /// Runs `body` against a fresh, empty schema of its own, dropped afterwards, so the tests run in parallel.
    static func withFreshSchema(_ body: @Sendable (Database) async throws -> Void) async throws {
        guard let url else {
            Issue.record("\(urlKey) is unset in CI: the persistence job must name its Postgres service")
            return
        }
        let base = try DatabaseConfiguration(url: url)
        let schema = "t_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        try await Database.withDatabase(base) { admin in
            try await admin.client.query(PostgresQuery(unsafeSQL: "CREATE SCHEMA \(schema)"))
            var scoped = base
            scoped.searchPath = schema
            do {
                try await Database.withDatabase(scoped, body)
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
