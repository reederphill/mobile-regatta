import Foundation
import Persistence
import PostgresNIO
import Testing

/// #152: the lobby's lines and blocks in Postgres: what a restart reads back, what a take-down, the retention prune
/// and a player's deletion leave.
@Suite(TestDatabase.available) struct LobbyStoreTests {
    static let time = Date(timeIntervalSince1970: 1_791_460_800)

    static func players(_ database: Database, _ names: [String]) async throws {
        for name in names { _ = try await PlayerStore(database).signIn(teamPlayerID: "T:\(name)", gamePlayerID: "G:\(name)", displayName: name) }
    }

    static func text(_ author: String, _ body: String, at offset: TimeInterval) -> StoredLobbyLine {
        StoredLobbyLine(kind: .text, authorID: "T:\(author)",
                        author: .init(gamePlayerID: "G:\(author)", nickname: author, rating: 1512, isProvisional: true, chipDeck: "navy", chipSail: "white"),
                        body: body, createdAt: time + offset)
    }

    @Test func linesRoundTripAndSurviveARestart() async throws {
        try await TestDatabase.withFreshSchema { database, configuration in
            try await Migrator().up(database)
            try await Self.players(database, ["a", "b"])
            let store = LobbyMessageStore(database)
            var lines = [
                Self.text("a", "fair winds ⛵", at: 0),
                StoredLobbyLine(kind: .quick, authorID: "T:b",
                                author: .init(gamePlayerID: "G:b", nickname: "b", rating: 1500, isProvisional: false, chipDeck: "red", chipSail: "sand"),
                                quick: "gg", createdAt: Self.time + 1),
                StoredLobbyLine(kind: .gun, venue: "Bay", boats: 10, humans: 3, createdAt: Self.time + 2),
                StoredLobbyLine(kind: .winner, subjectID: "T:a", venue: "Bay", winnerName: "a", createdAt: Self.time + 3),
            ]
            for index in lines.indices { lines[index].id = try await store.append(lines[index]) }
            // Ids ascend in the order stored.
            #expect(lines.map(\.id) == lines.map(\.id).sorted() && Set(lines.map(\.id)).count == 4)

            // A new pool on the same schema: the server restarted.
            let restored = try await Database.withDatabase(configuration) { try await LobbyMessageStore($0).recent(since: Self.time, limit: 10) }
            #expect(restored == lines)
            // The newest `limit`, oldest first; none older than `since`.
            #expect(try await store.recent(since: Self.time, limit: 2) == Array(lines.suffix(2)))
            #expect(try await store.recent(since: Self.time + 2, limit: 10) == Array(lines.suffix(2)))
        }
    }

    @Test func removedRowsAreNotLoaded() async throws {
        try await TestDatabase.withMigratedSchema { database in
            try await Self.players(database, ["a", "b"])
            let store = LobbyMessageStore(database)
            let first = try await store.append(Self.text("a", "one", at: 0))
            let second = try await store.append(Self.text("a", "two", at: 1))
            let other = try await store.append(Self.text("b", "three", at: 2))
            #expect(try await store.remove(ids: [first, 999_999], reason: "report", at: Self.time + 5) == [first])
            #expect(try await store.remove(ids: [first], reason: "report", at: Self.time + 6) == [])
            #expect(try await store.recent(since: Self.time, limit: 10).map(\.id) == [second, other])
            #expect(try await store.removeAll(of: "T:a", reason: "ban", at: Self.time + 7) == [second])
            #expect(try await store.recent(since: Self.time, limit: 10).map(\.id) == [other])
            // Taken down, not deleted: the rows are there until the prune.
            let rows = try await database.client.query("SELECT count(*) FROM lobby_messages WHERE removed_reason IS NOT NULL")
            for try await count in rows.decode(Int64.self) { #expect(count == 2) }
        }
    }

    /// Retention (#28): lines older than the cut go, removed or not; the rest stay.
    @Test func pruneDeletesOlderLines() async throws {
        try await TestDatabase.withMigratedSchema { database in
            try await Self.players(database, ["a"])
            let store = LobbyMessageStore(database)
            let day: TimeInterval = 86_400
            let old = try await store.append(Self.text("a", "old", at: 0))
            _ = try await store.append(StoredLobbyLine(kind: .gun, venue: "Bay", boats: 10, humans: 1, createdAt: Self.time + day))
            let kept = try await store.append(Self.text("a", "new", at: 30 * day))
            try await store.remove(ids: [old], reason: "report", at: Self.time + 10)
            // "Now" is day 31: the cut is 30 days back.
            #expect(try await store.prune(before: Self.time + 31 * day - 30 * day - 1) == 1)
            #expect(try await store.prune(before: Self.time + 2 * day) == 1)
            #expect(try await store.recent(since: .distantPast, limit: 10).map(\.id) == [kept])
        }
    }

    @Test func blocksRoundTripAndSurviveARestart() async throws {
        try await TestDatabase.withFreshSchema { database, configuration in
            try await Migrator().up(database)
            try await Self.players(database, ["a", "b", "c"])
            let store = LobbyMessageStore(database)
            try await store.block("T:b", by: "T:a", at: Self.time)
            try await store.block("T:b", by: "T:a", at: Self.time + 1)
            try await store.block("T:c", by: "T:a", at: Self.time + 2)
            try await store.block("T:a", by: "T:c", at: Self.time + 3)
            // A player who isn't stored can't be blocked, or block.
            try await store.block("T:nobody", by: "T:a", at: Self.time)
            try await store.block("T:a", by: "T:nobody", at: Self.time)
            let restored = try await Database.withDatabase(configuration) { try await LobbyMessageStore($0).blocks() }
            #expect(Set(restored.map { "\($0.blocker)>\($0.blocked)" }) == ["T:a>T:b", "T:a>T:c", "T:c>T:a"])
            #expect(try await store.blockedPlayers(of: "T:a") == [LobbyPlayerRef(teamPlayerID: "T:b", gamePlayerID: "G:b", nickname: "b"),
                                                                 LobbyPlayerRef(teamPlayerID: "T:c", gamePlayerID: "G:c", nickname: "c")])
            try await store.unblock("T:b", by: "T:a")
            #expect(try await store.blockedPlayers(of: "T:a").map(\.teamPlayerID) == ["T:c"])
            #expect(try await store.player(gamePlayerID: "G:c") == LobbyPlayerRef(teamPlayerID: "T:c", gamePlayerID: "G:c", nickname: "c"))
            #expect(try await store.player(gamePlayerID: "G:nobody") == nil)
        }
    }

    /// #160: a player's deletion takes her lines, the winner's lines naming her and the blocks she made; blocks against
    /// her are the other players' and stay. Deleting the `players` row itself cascades to all of it.
    @Test func deleteAllOfAPlayer() async throws {
        try await TestDatabase.withMigratedSchema { database in
            try await Self.players(database, ["a", "b"])
            let store = LobbyMessageStore(database)
            let hers = try await store.append(Self.text("a", "mine", at: 0))
            let won = try await store.append(StoredLobbyLine(kind: .winner, subjectID: "T:a", venue: "Bay", winnerName: "a", createdAt: Self.time + 1))
            let theirs = try await store.append(Self.text("b", "theirs", at: 2))
            let gun = try await store.append(StoredLobbyLine(kind: .gun, venue: "Bay", boats: 10, humans: 2, createdAt: Self.time + 3))
            try await store.block("T:b", by: "T:a", at: Self.time)
            try await store.block("T:a", by: "T:b", at: Self.time)
            #expect(try await store.deleteAll(of: "T:a") == [hers, won])
            #expect(try await store.recent(since: .distantPast, limit: 10).map(\.id) == [theirs, gun])
            #expect(try await store.blocks().map { "\($0.blocker)>\($0.blocked)" } == ["T:b>T:a"])
            let rows = try await database.client.query("SELECT count(*) FROM lobby_messages")
            for try await count in rows.decode(Int64.self) { #expect(count == 2) }

            try await database.client.query("DELETE FROM players WHERE team_player_id = 'T:b'")
            #expect(try await store.recent(since: .distantPast, limit: 10).map(\.id) == [gun])
            #expect(try await store.blocks().isEmpty)
        }
    }
}
