import Foundation
import PostgresNIO

/// A lobby line as stored (#152): a player's text or quick-chat with her as she showed then, or one of the server's
/// two lines.
public struct StoredLobbyLine: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case text, quick, gun, winner
    }

    /// The author of a player's line, as the lobby showed her when she posted it.
    public struct Author: Sendable, Equatable {
        public var gamePlayerID: String
        public var nickname: String
        public var rating: Int
        public var isProvisional: Bool
        public var chipDeck: String
        public var chipSail: String

        public init(gamePlayerID: String, nickname: String, rating: Int, isProvisional: Bool, chipDeck: String, chipSail: String) {
            self.gamePlayerID = gamePlayerID
            self.nickname = nickname
            self.rating = rating
            self.isProvisional = isProvisional
            self.chipDeck = chipDeck
            self.chipSail = chipSail
        }
    }

    /// Assigned by the store, ascending, never reused. 0 on a line not yet stored.
    public var id: Int64
    public var kind: Kind
    /// The player who posted it (teamPlayerID); nil on a system line.
    public var authorID: String?
    /// The player a winner's line names; nil otherwise.
    public var subjectID: String?
    public var author: Author?
    /// A text line's words.
    public var body: String?
    /// A quick-chat line's phrase, by name.
    public var quick: String?
    public var venue: String?
    public var boats: Int?
    public var humans: Int?
    public var winnerName: String?
    public var createdAt: Date

    public init(id: Int64 = 0, kind: Kind, authorID: String? = nil, subjectID: String? = nil, author: Author? = nil, body: String? = nil,
                quick: String? = nil, venue: String? = nil, boats: Int? = nil, humans: Int? = nil, winnerName: String? = nil,
                createdAt: Date) {
        self.id = id
        self.kind = kind
        self.authorID = authorID
        self.subjectID = subjectID
        self.author = author
        self.body = body
        self.quick = quick
        self.venue = venue
        self.boats = boats
        self.humans = humans
        self.winnerName = winnerName
        self.createdAt = createdAt
    }
}

/// The insert gave no id back.
public struct LobbyAppendFailed: Error, Equatable, Sendable {}

/// A player as the lobby's block list knows her.
public struct LobbyPlayerRef: Sendable, Equatable, Hashable {
    public var teamPlayerID: String
    public var gamePlayerID: String
    public var nickname: String

    public init(teamPlayerID: String, gamePlayerID: String, nickname: String) {
        self.teamPlayerID = teamPlayerID
        self.gamePlayerID = gamePlayerID
        self.nickname = nickname
    }
}

/// The lobby in Postgres (#152, migration 0011): its lines and its blocks. The server keeps the last hour and the
/// block graph in memory and writes through; this is what a restart reads back.
public struct LobbyMessageStore: Sendable {
    let database: Database
    public init(_ database: Database) { self.database = database }

    /// Stores `line` and returns its id.
    public func append(_ line: StoredLobbyLine) async throws -> Int64 {
        let author = line.author
        let boats = line.boats.map(Int32.init), humans = line.humans.map(Int32.init), rating = author.map { Int32($0.rating) }
        let rows = try await database.client.query("""
            INSERT INTO lobby_messages (kind, author_id, subject_id, body, quick, venue, boats, humans, winner_name,
                author_game_player_id, author_nickname, author_rating, author_provisional, author_chip_deck, author_chip_sail, created_at)
            VALUES (\(line.kind.rawValue), \(line.authorID), \(line.subjectID), \(line.body), \(line.quick), \(line.venue), \(boats),
                \(humans), \(line.winnerName), \(author?.gamePlayerID), \(author?.nickname), \(rating), \(author?.isProvisional),
                \(author?.chipDeck), \(author?.chipSail), \(line.createdAt))
            RETURNING id
            """, logger: database.logger)
        for try await id in rows.decode(Int64.self) { return id }
        throw LobbyAppendFailed()
    }

    /// The newest `limit` lines created at or after `since` that weren't taken down, oldest first.
    public func recent(since: Date, limit: Int) async throws -> [StoredLobbyLine] {
        let rows = try await database.client.query("""
            SELECT id, kind, author_id, subject_id, body, quick, venue, boats, humans, winner_name, author_game_player_id,
                author_nickname, author_rating, author_provisional, author_chip_deck, author_chip_sail, created_at
            FROM lobby_messages WHERE removed_at IS NULL AND created_at >= \(since)
            ORDER BY id DESC LIMIT \(Int64(limit))
            """, logger: database.logger)
        var lines: [StoredLobbyLine] = []
        for try await row in rows {
            let cells = row.makeRandomAccess()
            func read<T: PostgresDecodable>(_ column: String, _ type: T.Type = T.self) throws -> T { try cells[column].decode(T.self, context: .default) }
            guard let kind = StoredLobbyLine.Kind(rawValue: try read("kind", String.self)) else { continue }
            var author: StoredLobbyLine.Author?
            if let game = try read("author_game_player_id", String?.self) {
                author = StoredLobbyLine.Author(
                    gamePlayerID: game, nickname: try read("author_nickname", String?.self) ?? "",
                    rating: Int(try read("author_rating", Int32?.self) ?? 0), isProvisional: try read("author_provisional", Bool?.self) ?? true,
                    chipDeck: try read("author_chip_deck", String?.self) ?? "", chipSail: try read("author_chip_sail", String?.self) ?? "")
            }
            lines.append(StoredLobbyLine(
                id: try read("id"), kind: kind, authorID: try read("author_id"), subjectID: try read("subject_id"), author: author,
                body: try read("body"), quick: try read("quick"), venue: try read("venue"), boats: try read("boats", Int32?.self).map(Int.init),
                humans: try read("humans", Int32?.self).map(Int.init), winnerName: try read("winner_name"), createdAt: try read("created_at")))
        }
        return lines.reversed()
    }

    /// Takes lines down (#153): they stay stored, marked, until the prune. Returns the ids that were up.
    @discardableResult
    public func remove(ids: [Int64], reason: String, at time: Date) async throws -> [Int64] {
        guard !ids.isEmpty else { return [] }
        let rows = try await database.client.query("""
            UPDATE lobby_messages SET removed_at = \(time), removed_reason = \(reason)
            WHERE id = ANY(\(ids)) AND removed_at IS NULL RETURNING id
            """, logger: database.logger)
        var removed: [Int64] = []
        for try await id in rows.decode(Int64.self) { removed.append(id) }
        return removed.sorted()
    }

    /// Takes down every line `playerID` posted (#153). Returns their ids.
    @discardableResult
    public func removeAll(of playerID: String, reason: String, at time: Date) async throws -> [Int64] {
        let rows = try await database.client.query("""
            UPDATE lobby_messages SET removed_at = \(time), removed_reason = \(reason)
            WHERE author_id = \(playerID) AND removed_at IS NULL RETURNING id
            """, logger: database.logger)
        var removed: [Int64] = []
        for try await id in rows.decode(Int64.self) { removed.append(id) }
        return removed.sorted()
    }

    /// Deletes every line created before `time` (retention, #28; #160 schedules it). Returns how many.
    @discardableResult
    public func prune(before time: Date) async throws -> Int {
        let rows = try await database.client.query("DELETE FROM lobby_messages WHERE created_at < \(time) RETURNING id",
                                                   logger: database.logger)
        var count = 0
        for try await _ in rows.decode(Int64.self) { count += 1 }
        return count
    }

    /// Deletes what the lobby holds of `playerID` (#160): the lines she posted, the winner's lines naming her and the
    /// blocks she made. Blocks others made against her stay: they are theirs. Returns the deleted lines' ids.
    @discardableResult
    public func deleteAll(of playerID: String) async throws -> [Int64] {
        try await database.transaction { connection in
            let rows = try await connection.query("""
                DELETE FROM lobby_messages WHERE author_id = \(playerID) OR subject_id = \(playerID) RETURNING id
                """, logger: database.logger)
            var deleted: [Int64] = []
            for try await id in rows.decode(Int64.self) { deleted.append(id) }
            try await connection.query("DELETE FROM lobby_blocks WHERE blocker_id = \(playerID)", logger: database.logger)
            return deleted.sorted()
        }
    }

    // MARK: Blocks

    /// Every block: who hides whom (teamPlayerIDs).
    public func blocks() async throws -> [(blocker: String, blocked: String)] {
        let rows = try await database.client.query("SELECT blocker_id, blocked_id FROM lobby_blocks", logger: database.logger)
        var all: [(String, String)] = []
        for try await (blocker, blocked) in rows.decode((String, String).self) { all.append((blocker, blocked)) }
        return all
    }

    /// Stores the block; nothing if it is there, or either player isn't stored.
    public func block(_ blocked: String, by blocker: String, at time: Date) async throws {
        try await database.client.query("""
            INSERT INTO lobby_blocks (blocker_id, blocked_id, created_at)
            SELECT a.team_player_id, b.team_player_id, \(time) FROM players a, players b
            WHERE a.team_player_id = \(blocker) AND b.team_player_id = \(blocked)
            ON CONFLICT DO NOTHING
            """, logger: database.logger)
    }

    public func unblock(_ blocked: String, by blocker: String) async throws {
        try await database.client.query("DELETE FROM lobby_blocks WHERE blocker_id = \(blocker) AND blocked_id = \(blocked)",
                                        logger: database.logger)
    }

    /// The players `blocker` blocks, oldest block first, under the names they have now.
    public func blockedPlayers(of blocker: String) async throws -> [LobbyPlayerRef] {
        let rows = try await database.client.query("""
            SELECT p.team_player_id, p.game_player_id, p.display_name FROM lobby_blocks b
            JOIN players p ON p.team_player_id = b.blocked_id
            WHERE b.blocker_id = \(blocker) AND p.game_player_id IS NOT NULL ORDER BY b.created_at, p.team_player_id
            """, logger: database.logger)
        var players: [LobbyPlayerRef] = []
        for try await (team, game, name) in rows.decode((String, String, String).self) {
            players.append(LobbyPlayerRef(teamPlayerID: team, gamePlayerID: game, nickname: name))
        }
        return players
    }

    /// The player bound to `gamePlayerID`, if one is stored.
    public func player(gamePlayerID: String) async throws -> LobbyPlayerRef? {
        let rows = try await database.client.query("""
            SELECT team_player_id, display_name FROM players WHERE game_player_id = \(gamePlayerID)
            """, logger: database.logger)
        for try await (team, name) in rows.decode((String, String).self) {
            return LobbyPlayerRef(teamPlayerID: team, gamePlayerID: gamePlayerID, nickname: name)
        }
        return nil
    }
}
