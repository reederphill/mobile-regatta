import Foundation
import Persistence
import PostgresNIO
import Testing

/// #147: a player's queue restrictions (briefing-leave cooldown, suspension, failed attestation) and her briefing leaves
/// are stored: they survive a restart, prune past the window, and go with the player.
@Suite(TestDatabase.available) struct RestrictionStoreTests {
    static let time = Date(timeIntervalSince1970: 1_791_460_800)

    @Test func cooldownSurvivesRestart() async throws {
        try await TestDatabase.withFreshSchema { database, configuration in
            try await Migrator().up(database)
            _ = try await PlayerStore(database).signIn(teamPlayerID: "T:a", gamePlayerID: "G:a", displayName: "a")
            let store = PlayerRestrictionStore(database)
            #expect(try await store.restrictions(of: "T:a") == .none)
            try await store.setCooldown("T:a", until: Self.time + 300)
            try await store.setSuspension("T:a", StoredSuspension(until: Self.time + 3600))
            try await store.setAttestationFailed("T:a", true)
            try await store.recordBriefingLeave("T:a", race: UUID(), at: Self.time)

            // A new pool on the same schema: the server restarted.
            let (restored, leaves) = try await Database.withDatabase(configuration) { restarted in
                let store = PlayerRestrictionStore(restarted)
                return (try await store.restrictions(of: "T:a"), try await store.briefingLeaves(of: "T:a", since: Self.time - 3600))
            }
            #expect(restored == PlayerRestrictions(cooldownUntil: Self.time + 300, suspension: StoredSuspension(until: Self.time + 3600),
                                                   attestationFailed: true))
            #expect(leaves == [Self.time])
        }
    }

    @Test func suspensionsAreTimedOrPermanentAndLift() async throws {
        try await TestDatabase.withMigratedSchema { database in
            _ = try await PlayerStore(database).signIn(teamPlayerID: "T:a", gamePlayerID: "G:a", displayName: "a")
            let store = PlayerRestrictionStore(database)
            try await store.setSuspension("T:a", .permanent)
            #expect(try await store.restrictions(of: "T:a").suspension == .permanent)
            try await store.setSuspension("T:a", nil)
            #expect(try await store.restrictions(of: "T:a") == .none)
            // Nobody stored: nothing to restrict, nothing written.
            try await store.setCooldown("T:nobody", until: Self.time)
            try await store.recordBriefingLeave("T:nobody", race: nil, at: Self.time)
            #expect(try await store.restrictions(of: "T:nobody") == .none)
            #expect(try await store.briefingLeaves(of: "T:nobody", since: .distantPast) == [])
        }
    }

    /// Leaves older than the window are pruned when read; clearing empties them; deleting the player takes them (G8).
    @Test func leavesPruneAndGoWithThePlayer() async throws {
        try await TestDatabase.withMigratedSchema { database in
            let players = PlayerStore(database)
            _ = try await players.signIn(teamPlayerID: "T:a", gamePlayerID: "G:a", displayName: "a")
            let store = PlayerRestrictionStore(database)
            for minutes in [0.0, 30, 70] { try await store.recordBriefingLeave("T:a", race: nil, at: Self.time + minutes * 60) }
            #expect(try await store.briefingLeaves(of: "T:a", since: Self.time + 10 * 60) == [Self.time + 1800, Self.time + 4200])
            #expect(try await store.briefingLeaves(of: "T:a", since: .distantPast) == [Self.time + 1800, Self.time + 4200])
            try await store.clearBriefingLeaves(of: "T:a")
            #expect(try await store.briefingLeaves(of: "T:a", since: .distantPast) == [])

            try await store.recordBriefingLeave("T:a", race: nil, at: Self.time)
            #expect(try await players.delete(teamPlayerID: "T:a"))
            let rows = try await database.client.query("SELECT count(*) FROM briefing_leaves")
            for try await count in rows.decode(Int.self) { #expect(count == 0) }
        }
    }
}
