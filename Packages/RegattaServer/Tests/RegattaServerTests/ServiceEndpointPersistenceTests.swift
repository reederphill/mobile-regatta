import Crypto
import Foundation
import Persistence
import PostgresNIO
import RegattaServerKit
import Testing

/// The service endpoint's gate and sign-in against Postgres (#145, ADR 0009), on a schema of its own. Named
/// `…PersistenceTests` so CI's `persistence` job (`--filter PersistenceTests`) runs it; skipped without
/// `REGATTA_TEST_DATABASE_URL`, like the store tests.
@Suite(EndpointDatabase.available, .timeLimit(.minutes(1))) struct ServiceEndpointPersistenceTests {
    /// Acceptance (#145): an unaccepted player can't open the queue or post; bumping `termsVersion` re-gates.
    @Test func theTermsGateAgainstPostgres() async throws {
        try await EndpointDatabase.withMigratedSchema { database in
            try await GateScenario.run(store: PostgresAccountStore(database))
        }
    }

    /// Acceptance (#145, #148): the served contract suites (Identity, Terms, Queue, RaceSession) through the runner against the
    /// server on Postgres.
    @Test func identityAndTermsSuitesPassAgainstTheServerOnPostgres() async throws {
        try await EndpointDatabase.withMigratedSchema { database in
            let config = ServiceEndpointContractTests.config()
            let server = try await RegattaHTTPServer.start(
                config: config, services: try ServiceEndpoint.make(config: config, store: PostgresAccountStore(database),
                                                                   archive: PostgresRaceArchive(database),
                                                                   restrictions: PlayerRestrictionStore(database)))
            do {
                try await ServiceEndpointContractTests.run(ServiceEndpointContractTests.served, against: "ws://127.0.0.1:\(server.port)")
            } catch {
                await server.shutdown()
                throw error
            }
            await server.shutdown()
        }
    }

    @Test func signInStoresThePlayerByTeamPlayerIDAndTheSessionByTokenHash() async throws {
        try await EndpointDatabase.withMigratedSchema { database in
            let endpoint = ServiceFixtures.endpoint(store: PostgresAccountStore(database))
            let (_, _, session) = try await ServiceFixtures.signedIn(endpoint, "pg")
            let player = try await PlayerStore(database).player(teamPlayerID: "T:pg")
            #expect(player?.gamePlayerID == "G:pg")
            let stored = try await SessionStore(database).session(tokenHash: Data(SHA256.hash(data: session.token)))
            #expect(stored?.playerID == "T:pg")
        }
    }
}

/// The database these tests use: the same variables as `PersistenceTests`' `TestDatabase`.
enum EndpointDatabase {
    static var url: String? {
        guard let url = ProcessInfo.processInfo.environment["REGATTA_TEST_DATABASE_URL"], !url.isEmpty else { return nil }
        return url
    }

    static var isRequired: Bool { ProcessInfo.processInfo.environment["REGATTA_REQUIRE_DATABASE"] == "1" }

    static let available = ConditionTrait.enabled(if: url != nil || isRequired, "REGATTA_TEST_DATABASE_URL is unset: no Postgres")

    static func withMigratedSchema(_ body: @Sendable (Database) async throws -> Void) async throws {
        guard let url else {
            Issue.record("REGATTA_TEST_DATABASE_URL is unset but REGATTA_REQUIRE_DATABASE=1")
            return
        }
        let base = try DatabaseConfiguration(url: url)
        let schema = "t_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        try await Database.withDatabase(base) { admin in
            try await admin.client.query(PostgresQuery(unsafeSQL: "CREATE SCHEMA \(schema)"))
            var scoped = base
            scoped.searchPath = schema
            do {
                try await Database.withDatabase(scoped) { database in
                    try await Migrator().up(database)
                    try await body(database)
                }
            } catch {
                _ = try? await admin.client.query(PostgresQuery(unsafeSQL: "DROP SCHEMA \(schema) CASCADE"))
                throw error
            }
            try await admin.client.query(PostgresQuery(unsafeSQL: "DROP SCHEMA \(schema) CASCADE"))
        }
    }
}
