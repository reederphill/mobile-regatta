import Foundation
import Persistence
@testable import RegattaServerKit
import RegattaServiceClient
import RegattaServices
import Synchronization
import Testing

/// A clock the test moves by hand.
final class AnalyticsTestClock: Sendable {
    private let time: Mutex<Date>

    init(_ start: Date) { time = Mutex(start) }

    var now: @Sendable () -> Date { { [self] in time.withLock { $0 } } }

    func advance(days: Double) { time.withLock { $0 += days * 86_400 } }
}

/// The 90-day purge (#156, #28) on a fake clock, against any store: the in-memory one here, Postgres in
/// `AnalyticsPersistenceTests`. Raw events are counted into the daily aggregates, then deleted 90 days after they
/// arrived; the aggregates stay as they were.
enum RetentionScenario {
    static let start = Date(timeIntervalSince1970: 1_791_460_800)

    static func event(_ sequence: Int, _ name: AnalyticsEventName, _ properties: [String: AnalyticsValue], at time: Date = start) -> AnalyticsEvent {
        AnalyticsEvent(sequence: sequence, name: name, time: Int64(time.timeIntervalSince1970), properties: properties)
    }

    static func run(store: any AnalyticsStore, rawCount: @Sendable () async throws -> Int) async throws {
        let clock = AnalyticsTestClock(start)
        let settings = AnalyticsSettings()
        let ingest = AnalyticsIngest(settings: settings, store: store, now: clock.now)
        let retention = AnalyticsRetention(settings: settings, store: store, now: clock.now)
        let a = InstallID("install-a"), b = InstallID("install-b")
        let first = AnalyticsBatch(installID: a, events: [
            event(1, .hintRetired, ["hint": .string("tack"), "mode": .string("learned")]),
            event(2, .hintRetired, ["hint": .string("tack"), "mode": .string("shown_twice")]),
            event(3, .queueWait, ["wait_s": .double(12.5)]),
        ])
        #expect(try await ingest.record(first) == AnalyticsReceipt(accepted: 3, duplicates: 0))
        #expect(try await ingest.record(first) == AnalyticsReceipt(accepted: 0, duplicates: 3))
        #expect(try await ingest.record(AnalyticsBatch(installID: b, events: [event(1, .queueWait, ["wait_s": .int(20)])]))
            == AnalyticsReceipt(accepted: 1, duplicates: 0))
        #expect(try await retention.run() == AnalyticsRetention.Pass(rolledUp: 4, purged: 0))

        // Later the same day, after the first roll-up: install A again. Counted as an event, not as another install.
        clock.advance(days: 0.25)
        _ = try await ingest.record(AnalyticsBatch(installID: a, events: [event(4, .queueWait, ["wait_s": .double(30)])]))
        #expect(try await retention.run() == AnalyticsRetention.Pass(rolledUp: 1, purged: 0))

        let day = StoredAnalyticsEvent.day(of: start)
        let queueDaily = [AnalyticsDaily(day: day, source: .device, name: "queue_wait", segment: "", events: 3, actors: 2)]
        let queueWait = [AnalyticsPropertyStats(day: day, source: .device, name: "queue_wait", segment: "", key: "wait_s", kind: .number,
                                                value: "", count: 3, sum: 62.5, sumSquares: 12.5 * 12.5 + 400 + 900, min: 12.5, max: 30)]
        let hintDaily = [AnalyticsDaily(day: day, source: .device, name: "hint_retired", segment: "hint=tack", events: 2, actors: 1)]
        let hintModes = ["learned", "shown_twice"].map {
            AnalyticsPropertyStats(day: day, source: .device, name: "hint_retired", segment: "hint=tack", key: "mode", kind: .category,
                                   value: $0, count: 1)
        }
        func expectAggregates() async throws {
            #expect(try await store.daily(.device, "queue_wait") == queueDaily)
            #expect(try await store.dailyProperties(.device, "queue_wait") == queueWait)
            #expect(try await store.daily(.device, "hint_retired") == hintDaily)
            #expect(try await store.dailyProperties(.device, "hint_retired") == hintModes)
        }
        try await expectAggregates()

        // Day 89 after the first batches: nothing is past the retention yet.
        clock.advance(days: 88.75)
        #expect(try await retention.run() == AnalyticsRetention.Pass(rolledUp: 0, purged: 0))
        #expect(try await rawCount() == 5)

        // A batch arriving now, not yet counted when the cut passes the first ones.
        _ = try await ingest.record(AnalyticsBatch(installID: b, events: [event(2, .drop, [:], at: start + 89 * 86_400)]))
        // Day 91: the first five are past 90 days and go; the new one is counted and stays. The aggregates are unchanged.
        clock.advance(days: 2)
        #expect(try await retention.run() == AnalyticsRetention.Pass(rolledUp: 1, purged: 5))
        #expect(try await rawCount() == 1)
        try await expectAggregates()
        #expect(try await store.daily(.device, "drop").map(\.events) == [1])

        // A resend of a purged batch is new again: its raw event is gone, and the device's sequence decides nothing more.
        #expect(try await ingest.record(AnalyticsBatch(installID: b, events: [event(1, .queueWait, ["wait_s": .int(20)])])).accepted == 1)
    }
}

@Suite struct AnalyticsIngestTests {
    /// Acceptance (#156): the 90-day purge on a fake clock; the aggregates survive it.
    @Test func ninetyDayPurgeKeepsTheAggregates() async throws {
        let store = InMemoryAnalyticsStore()
        try await RetentionScenario.run(store: store) { store.raw().count }
    }

    /// Acceptance (#156): a signed-in device's batch over `/service` is stored under its install id alone: neither the
    /// teamPlayerID nor the gamePlayerID the connection signed in with is anywhere in what is stored.
    @Test func aBatchIsStoredUnderItsInstallNeverThePlayer() async throws {
        let store = InMemoryAnalyticsStore()
        let ingest = AnalyticsIngest(store: store)
        let endpoint = ServiceEndpoint(config: ServiceEndpointConfig(), sessions: SessionAuthority(store: InMemoryAccountStore(), verifier: StubVerifier()),
                                       backends: ServiceBackends(analytics: { ingest.service(for: $0) }),
                                       analytics: ingest)
        let (link, connection, _) = try await ServiceFixtures.signedIn(endpoint, "sailor")
        _ = try await RemoteTermsService(connection).accept(TermsVersion(1))
        let batch = AnalyticsBatch(installID: InstallID("device-1"), events: [
            RetentionScenario.event(1, .gameCenterPrompt, ["accepted": .bool(true)]),
            RetentionScenario.event(2, .roundTrip, ["p50_ms": .int(80), "over_warning_s": .double(1.5)]),
        ])
        #expect(try await RemoteAnalyticsTransport(connection).send(batch) == AnalyticsReceipt(accepted: 2, duplicates: 0))
        let raw = store.raw()
        #expect(raw.map(\.installID) == ["device-1", "device-1"] && raw.allSatisfy { $0.playerID == nil && $0.source == .device })
        #expect(!"\(raw)".contains("sailor"))
        #expect(raw[1].properties == ["p50_ms": .int(80), "over_warning_s": .double(1.5)])
        withExtendedLifetime(link) {}
    }

    /// Names, keys, texts and the number of properties are held to the limits; numbers that aren't finite are left out;
    /// a device's clock is held to 30 days before arrival and never after; the segment comes from the settings.
    @Test func eventsAreHeldToTheLimits() throws {
        let received = RetentionScenario.start
        let ingest = AnalyticsIngest(store: InMemoryAnalyticsStore(), now: { received })
        let settings = ingest.settings
        var properties: [String: AnalyticsValue] = [:]
        for index in 0..<40 { properties[String(format: "k%02d", index)] = .int(index) }
        properties[String(repeating: "x", count: 65)] = .bool(true)
        properties["k00"] = .string(String(repeating: "é", count: 300))
        properties["k01"] = .double(.nan)
        properties["device_model"] = .string("iPhone17,1")
        let event = AnalyticsEvent(sequence: 7, name: AnalyticsEventName(String(repeating: "n", count: 80)), time: 0, properties: properties)
        let stored = ingest.stored(event, installID: InstallID("i"), receivedAt: received)
        #expect(stored.name.count == settings.maxNameLength)
        #expect(stored.properties.count == settings.maxProperties)
        #expect(stored.properties["k00"] == .string(String(repeating: "é", count: settings.maxTextLength)))
        #expect(stored.properties["k01"] == nil && stored.properties[String(repeating: "x", count: 65)] == nil)
        // A time far in the past counts 30 days before it arrived; one in the future counts when it arrived.
        #expect(stored.occurredAt == received - settings.maxEventAge && stored.day == StoredAnalyticsEvent.day(of: received - settings.maxEventAge))
        let future = ingest.stored(AnalyticsEvent(sequence: 8, name: .drop, time: Int64.max), installID: InstallID("i"), receivedAt: received)
        #expect(future.occurredAt == received && future.day == StoredAnalyticsEvent.day(of: received))

        let performance = UsageEvent.performance({
            var summary = MetricSummary(deviceModel: "iPhone17,1", osVersion: "iOS 26.1", appBuild: "412")
            summary.cpuSeconds = 41.5
            summary.memoryLimitExits = 1
            return summary
        }())
        let metrics = ingest.stored(AnalyticsEvent(sequence: 9, name: performance.name, time: 1_791_460_800, properties: performance.properties),
                                    installID: InstallID("i"), receivedAt: received)
        #expect(metrics.segment == "device_model=iPhone17,1")
        #expect(metrics.properties["cpu_s"] == .double(41.5) && metrics.properties["memory_limit_exits"] == .int(1))
    }

    /// #28: MetricKit's performance summaries are counted by device model, each number's sum and range kept; the
    /// device model itself is the segment, not a counted property.
    @Test func performanceIsAggregatedByDeviceModel() async throws {
        let store = InMemoryAnalyticsStore()
        let ingest = AnalyticsIngest(store: store, now: { RetentionScenario.start })
        func summary(_ model: String, cpu: Double) -> AnalyticsEvent.Properties {
            var summary = MetricSummary(deviceModel: model, osVersion: "iOS 26.1", appBuild: "412")
            summary.cpuSeconds = cpu
            return UsageEvent.performance(summary).properties
        }
        _ = try await ingest.record(AnalyticsBatch(installID: InstallID("a"), events: [
            RetentionScenario.event(1, .performance, summary("iPhone17,1", cpu: 40)),
            RetentionScenario.event(2, .performance, summary("iPhone17,1", cpu: 50)),
        ]))
        _ = try await ingest.record(AnalyticsBatch(installID: InstallID("b"), events: [RetentionScenario.event(1, .performance, summary("iPhone14,7", cpu: 90))]))
        try await AnalyticsRetention(store: store, now: { RetentionScenario.start }).run()
        let daily = try await store.daily(.device, "performance")
        #expect(daily.map(\.segment) == ["device_model=iPhone14,7", "device_model=iPhone17,1"] && daily.map(\.events) == [1, 2]
            && daily.map(\.actors) == [1, 1])
        let cpu = try await store.dailyProperties(.device, "performance").filter { $0.key == "cpu_s" }
        #expect(cpu.map(\.mean) == [90, 45] && cpu.map(\.min) == [90, 40] && cpu.map(\.max) == [90, 50])
        #expect(try await store.dailyProperties(.device, "performance").allSatisfy { $0.key != "device_model" })
    }

    /// The 2026-10-04 audit on #156: #370's finishing place, fleet size and tier on "practice race finished" are taken
    /// in, and the funnel is split by step and tier, so the place by tier outlives the raw events.
    @Test func practiceRaceFinishedKeepsPlaceFleetAndTier() async throws {
        let store = InMemoryAnalyticsStore()
        let ingest = AnalyticsIngest(store: store, now: { RetentionScenario.start })
        var properties = UsageEvent.practiceToOnline(.practiceRaceFinished(tuned: false)).properties
        properties["place"] = .int(3)
        properties["fleet_size"] = .int(10)
        properties["tier"] = .string("club")
        _ = try await ingest.record(AnalyticsBatch(installID: InstallID("a"), events: [RetentionScenario.event(1, .practiceToOnline, properties)]))
        try await AnalyticsRetention(store: store, now: { RetentionScenario.start }).run()
        #expect(try await store.daily(.device, "practice_to_online").map(\.segment) == ["step=practice_race_finished;tier=club"])
        let stats = try await store.dailyProperties(.device, "practice_to_online")
        #expect(stats.map(\.key) == ["fleet_size", "place", "tuned"] && stats.first { $0.key == "place" }?.sum == 3)
    }

    /// The server's own events (#28: keyed to the Game Center player) count each player once a day.
    @Test func serverEventsCountEachPlayerOnceADay() async throws {
        let store = InMemoryAnalyticsStore()
        let ingest = AnalyticsIngest(store: store, now: { RetentionScenario.start })
        let unlock = AnalyticsEventName("earned_unlock")
        try await ingest.record(unlock, about: "T:a", properties: ["design": .string("stripe")])
        try await ingest.record(unlock, about: "T:a", properties: ["design": .string("hoops")])
        try await ingest.record(unlock, about: "T:b")
        try await ingest.record(unlock, about: nil)
        #expect(store.raw().map(\.playerID) == ["T:a", "T:a", "T:b", nil] && store.raw().allSatisfy { $0.installID == nil && $0.source == .server })
        try await AnalyticsRetention(store: store, now: { RetentionScenario.start }).run()
        #expect(try await store.daily(.server, "earned_unlock").map { [$0.events, $0.actors] } == [[4, 2]])
        #expect(try await store.daily(.device, "earned_unlock").isEmpty)
    }

    /// A connection's batches past its budget are answered `unavailable` (kept by the device, sent later); another
    /// connection has its own budget. An install id is held to its length.
    @Test func aConnectionsBatchesAreBudgeted() async throws {
        var settings = AnalyticsSettings()
        settings.batchBurst = 3
        settings.batchesPerMinute = 0
        let store = InMemoryAnalyticsStore()
        let ingest = AnalyticsIngest(settings: settings, store: store)
        let player = AccountPlayer(teamPlayerID: "T:a", gamePlayerID: "G:a", alias: "a")
        let connection = ingest.service(for: player)
        let long = InstallID(String(repeating: "i", count: 200))
        for sequence in 1...3 {
            #expect(try await connection.send(AnalyticsBatch(installID: long, events: [RetentionScenario.event(sequence, .drop, [:])])).accepted == 1)
        }
        await #expect(throws: AnalyticsError.unavailable) {
            try await connection.send(AnalyticsBatch(installID: long, events: [RetentionScenario.event(4, .drop, [:])]))
        }
        #expect(try await ingest.service(for: player).send(AnalyticsBatch(installID: long, events: [RetentionScenario.event(4, .drop, [:])])).accepted == 1)
        #expect(store.raw().allSatisfy { $0.installID == String(repeating: "i", count: settings.maxInstallIDLength) })
    }

    /// A store that fails answers `unavailable`, so the device keeps the batch; over the cap is refused before the store.
    @Test func aFailingStoreIsUnavailable() async throws {
        let ingest = AnalyticsIngest(store: FailingAnalyticsStore())
        let batch = AnalyticsBatch(installID: InstallID("a"), events: [RetentionScenario.event(1, .drop, [:])])
        await #expect(throws: AnalyticsError.unavailable) { try await ingest.record(batch) }
        let tooMany = AnalyticsBatch(installID: InstallID("a"), events: (1...101).map { RetentionScenario.event($0, .drop, [:]) })
        await #expect(throws: AnalyticsError.batchTooLarge(max: 100)) { try await ingest.record(tooMany) }
    }
}

extension AnalyticsEvent {
    typealias Properties = [String: AnalyticsValue]
}

struct FailingAnalyticsStore: AnalyticsStore {
    struct Down: Error {}
    func recordDevice(_ events: [StoredAnalyticsEvent]) async throws -> AnalyticsRecordResult { throw Down() }
    func recordServer(_ event: StoredAnalyticsEvent) async throws { throw Down() }
    func rollUp(limit: Int) async throws -> Int { throw Down() }
    func purge(receivedBefore time: Date) async throws -> Int { throw Down() }
    func daily(_ source: AnalyticsSource, _ name: String) async throws -> [AnalyticsDaily] { throw Down() }
    func dailyProperties(_ source: AnalyticsSource, _ name: String) async throws -> [AnalyticsPropertyStats] { throw Down() }
}
