import Foundation
import Persistence
import PostgresNIO
import RegattaCore
import Testing

/// #159: players' stored liveries in Postgres: one per player, replaced whole, gone with her; a player the store
/// doesn't know stores nothing.
@Suite(TestDatabase.available) struct LiveryStoreTests {
    @Test func aLiveryIsStoredPerPlayerReplacedAndGoesWithHer() async throws {
        try await TestDatabase.withMigratedSchema { database in
            for name in ["a", "b"] { _ = try await PlayerStore(database).signIn(teamPlayerID: "T:\(name)", gamePlayerID: "G:\(name)", displayName: name) }
            let store = PlayerLiveryStore(database)
            let time = Date(timeIntervalSince1970: 1_791_460_800)
            let first = Livery(design: DesignID("skiff-stripe"), colours: [SwatchID("charcoal"), SwatchID("sky-blue"), SwatchID("off-white")], sailNumber: 42)
            let second = Livery(design: DesignID("skiff-plain"), colours: [SwatchID("charcoal"), SwatchID("off-white")], sailNumber: 9999)
            #expect(try await store.livery(of: "T:a") == nil)
            #expect(try await store.save(first, for: "T:a", at: time))
            // A new pool on the same database: another server, or a restart.
            #expect(try await store.livery(of: "T:a") == first)
            #expect(try await store.livery(of: "T:b") == nil)
            #expect(try await store.save(second, for: "T:a", at: time + 1))
            #expect(try await store.livery(of: "T:a") == second)
            #expect(try await !store.save(first, for: "T:nobody", at: time))
            await #expect(throws: (any Error).self) {
                try await store.save(Livery(design: DesignID("skiff-plain"), colours: [], sailNumber: 0), for: "T:b", at: time)
            }
            try await database.client.query("DELETE FROM players WHERE team_player_id = 'T:a'")
            #expect(try await store.livery(of: "T:a") == nil)
        }
    }
}
