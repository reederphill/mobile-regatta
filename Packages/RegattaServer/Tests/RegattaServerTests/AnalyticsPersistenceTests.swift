import Foundation
import Persistence
import PostgresNIO
@testable import RegattaServerKit
import RegattaServiceClient
import RegattaServices
import Testing

/// Analytics (#156) on Postgres: the 90-day purge with a fake clock, and a device's batch over `/service` stored
/// under its install id alone. Named `…PersistenceTests` so CI's `persistence` job runs it.
@Suite(EndpointDatabase.available, .timeLimit(.minutes(1))) struct AnalyticsPersistenceTests {
    /// Acceptance (#156): the 90-day purge with a fake clock against Postgres; the aggregates survive it.
    @Test func ninetyDayPurgeKeepsTheAggregates() async throws {
        try await EndpointDatabase.withMigratedSchema { database in
            let store = AnalyticsEventStore(database)
            try await RetentionScenario.run(store: store) { try await store.rawCount() }
        }
    }

    /// A signed-in device's batch is stored under its install id: no player id in the row.
    @Test func aBatchIsStoredUnderItsInstallNeverThePlayer() async throws {
        try await EndpointDatabase.withMigratedSchema { database in
            let store = AnalyticsEventStore(database)
            let ingest = AnalyticsIngest(store: store)
            let endpoint = ServiceEndpoint(config: ServiceEndpointConfig(),
                                           sessions: SessionAuthority(store: PostgresAccountStore(database), verifier: StubVerifier()),
                                           backends: ServiceBackends(analytics: { ingest.service(for: $0) }), analytics: ingest)
            let (link, connection, _) = try await ServiceFixtures.signedIn(endpoint, "sailor")
            _ = try await RemoteTermsService(connection).accept(TermsVersion(1))
            let batch = AnalyticsBatch(installID: InstallID("device-1"), events: [RetentionScenario.event(1, .drop, ["reason": .string("network")])])
            #expect(try await RemoteAnalyticsTransport(connection).send(batch) == AnalyticsReceipt(accepted: 1, duplicates: 0))
            let raw = try await store.deviceEvents(installID: "device-1")
            #expect(raw.count == 1 && raw[0].playerID == nil && raw[0].properties == ["reason": .string("network")])
            let rows = try await database.client.query("SELECT count(*) FROM analytics_events WHERE player_id IS NOT NULL")
            for try await count in rows.decode(Int64.self) { #expect(count == 0) }
            withExtendedLifetime(link) {}
        }
    }
}
