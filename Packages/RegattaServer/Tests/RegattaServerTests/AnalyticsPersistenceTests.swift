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

    /// Text Postgres can't hold or index is made safe at ingest: NUL anywhere (name, install id, key, value, segment),
    /// a segment value faking another key, and grapheme-heavy text far over its byte limit in characters. The batch is
    /// stored, the roll-up counts it, and the purge runs.
    @Test func poisonTextIsMadeSafeAtIngest() async throws {
        try await EndpointDatabase.withMigratedSchema { database in
            let store = AnalyticsEventStore(database)
            let ingest = AnalyticsIngest(store: store, now: { RetentionScenario.start })
            // 64 family emoji: 64 characters, 1,600 UTF-8 bytes.
            let heavy = String(repeating: "👨‍👩‍👧‍👦", count: 64)
            let batch = AnalyticsBatch(installID: InstallID("dev\u{0}ice"), events: [
                RetentionScenario.event(1, AnalyticsEventName("dr\u{0}op"), ["re\u{0}ason": .string("net\u{0}work")]),
                RetentionScenario.event(2, .performance, ["device_model": .string("x;tier=gold\u{0}"), "cpu_s": .double(1)]),
                RetentionScenario.event(3, .hintRetired, ["hint": .string(heavy), "mode": .string(heavy)]),
            ])
            #expect(try await ingest.record(batch) == AnalyticsReceipt(accepted: 3, duplicates: 0))
            let stored = try await store.deviceEvents(installID: "device")
            #expect(stored.map(\.name) == ["drop", "performance", "hint_retired"])
            #expect(stored[0].properties == ["reason": .string("network")])
            #expect(stored[1].segment == "device_model=x_tier_gold")
            #expect(stored[2].segment.utf8.count <= "hint=".utf8.count + 64)
            #expect(try await AnalyticsRetention(store: store, now: { RetentionScenario.start }).run() == AnalyticsRetention.Pass(rolledUp: 3, purged: 0))
            #expect(try await store.daily(.device, "performance").map(\.segment) == ["device_model=x_tier_gold"])
            // The long value is kept raw, and not counted by value.
            #expect(try await store.dailyProperties(.device, "hint_retired").isEmpty)
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
