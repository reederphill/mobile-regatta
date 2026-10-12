import Foundation
import Persistence
import PostgresNIO
import Testing

/// #156: the analytics tables in Postgres: raw events recorded once and read back as sent, the roll-up counting each
/// event and each actor once a day across passes, the purge taking only counted rows, and a player's server events
/// going with her.
@Suite(TestDatabase.available) struct AnalyticsStoreTests {
    static let time = Date(timeIntervalSince1970: 1_791_460_800)
    static let day = StoredAnalyticsEvent.day(of: time)

    static func device(_ install: String, _ sequence: Int64, name: String = "queue_wait", segment: String = "",
                       received: Date = time, _ properties: [String: StoredAnalyticsValue] = [:]) -> StoredAnalyticsEvent {
        StoredAnalyticsEvent(source: .device, installID: install, sequence: sequence, name: name, day: day, segment: segment, occurredAt: time,
                             receivedAt: received, properties: properties)
    }

    @Test func deviceEventsAreRecordedOnceAndReadBackAsSent() async throws {
        try await TestDatabase.withMigratedSchema { database in
            let store = AnalyticsEventStore(database)
            let properties: [String: StoredAnalyticsValue] = [
                "count": .int(-3), "big": .int(Int64.max), "ratio": .double(0.25), "whole": .double(2e300), "flag": .bool(false),
                "text": .string("quote \" backslash \\ tab \t newline \n bell \u{07} nul \u{0} ⛵"),
            ]
            let first = [Self.device("i", 1, properties), Self.device("i", 2), Self.device("i", 2)]
            #expect(try await store.recordDevice(first) == AnalyticsRecordResult(accepted: 2, duplicates: 1))
            #expect(try await store.recordDevice([Self.device("i", 2), Self.device("i", 3), Self.device("j", 1)])
                == AnalyticsRecordResult(accepted: 2, duplicates: 1))
            let stored = try await store.deviceEvents(installID: "i")
            #expect(stored.map(\.sequence) == [1, 2, 3])
            var expected = properties
            expected["text"] = .string("quote \" backslash \\ tab \t newline \n bell \u{07} nul  ⛵")
            #expect(stored[0].properties == expected)
            #expect(stored[0].occurredAt == Self.time && stored[0].receivedAt == Self.time && stored[0].playerID == nil)
        }
    }

    @Test func rollUpCountsEachEventAndEachActorOnceADayAcrossPasses() async throws {
        try await TestDatabase.withMigratedSchema { database in
            let store = AnalyticsEventStore(database)
            _ = try await store.recordDevice([
                Self.device("a", 1, ["wait_s": .int(10)]), Self.device("a", 2, ["wait_s": .double(20)]),
                Self.device("b", 1, ["wait_s": .int(30), "long": .string(String(repeating: "x", count: 65)), "late": .bool(true)]),
            ])
            // Two at a time: install A's second event lands in a later transaction and isn't counted as a second install.
            #expect(try await store.rollUp(limit: 2) == 2)
            #expect(try await store.rollUp(limit: 2) == 1)
            #expect(try await store.rollUp(limit: 2) == 0)
            _ = try await store.recordDevice([Self.device("a", 3, ["wait_s": .int(40)])])
            #expect(try await store.rollUp(limit: 10) == 1)

            #expect(try await store.daily(.device, "queue_wait")
                == [AnalyticsDaily(day: Self.day, source: .device, name: "queue_wait", segment: "", events: 4, actors: 2)])
            #expect(try await store.dailyProperties(.device, "queue_wait") == [
                AnalyticsPropertyStats(day: Self.day, source: .device, name: "queue_wait", segment: "", key: "late", kind: .category,
                                       value: "true", count: 1),
                AnalyticsPropertyStats(day: Self.day, source: .device, name: "queue_wait", segment: "", key: "wait_s", kind: .number,
                                       value: "", count: 4, sum: 100, sumSquares: 3_000, min: 10, max: 40),
            ])
        }
    }

    @Test func purgeTakesOnlyCountedRowsReceivedBeforeTheCut() async throws {
        try await TestDatabase.withMigratedSchema { database in
            let store = AnalyticsEventStore(database)
            _ = try await store.recordDevice([Self.device("a", 1), Self.device("a", 2, received: Self.time + 10)])
            #expect(try await store.purge(receivedBefore: Self.time + 60) == 0)
            try await store.rollUp(limit: 10)
            #expect(try await store.purge(receivedBefore: Self.time + 5) == 1)
            #expect(try await store.deviceEvents(installID: "a").map(\.sequence) == [2])
            #expect(try await store.daily(.device, "queue_wait").map(\.events) == [2])
        }
    }

    @Test func serverEventsGoWithTheirPlayer() async throws {
        try await TestDatabase.withMigratedSchema { database in
            _ = try await PlayerStore(database).signIn(teamPlayerID: "T:a", gamePlayerID: "G:a", displayName: "a")
            let store = AnalyticsEventStore(database)
            func event(_ player: String?) -> StoredAnalyticsEvent {
                StoredAnalyticsEvent(source: .server, playerID: player, name: "earned_unlock", day: Self.day, occurredAt: Self.time,
                                     receivedAt: Self.time, properties: ["design": .string("stripe")])
            }
            try await store.recordServer(event("T:a"))
            try await store.recordServer(event("T:unknown"))
            try await store.recordServer(event(nil))
            #expect(try await store.serverEvents(named: "earned_unlock").map(\.playerID) == ["T:a", nil, nil])
            try await store.rollUp(limit: 10)
            #expect(try await store.daily(.server, "earned_unlock").map { [$0.events, $0.actors] } == [[3, 1]])

            try await database.client.query("DELETE FROM players WHERE team_player_id = 'T:a'")
            #expect(try await store.serverEvents(named: "earned_unlock").map(\.playerID) == [nil, nil])
            #expect(try await store.daily(.server, "earned_unlock").map(\.events) == [3])
        }
    }

    @Test func aDeviceEventCanNotNameAPlayer() async throws {
        try await TestDatabase.withMigratedSchema { database in
            _ = try await PlayerStore(database).signIn(teamPlayerID: "T:a", gamePlayerID: "G:a", displayName: "a")
            await #expect(throws: (any Error).self) {
                try await database.client.query("""
                    INSERT INTO analytics_events (source, install_id, sequence, player_id, name, day, segment, occurred_at, received_at, properties)
                    VALUES ('device', 'i', 1, 'T:a', 'drop', 0, '', now(), now(), '{}')
                    """)
            }
        }
    }
}
