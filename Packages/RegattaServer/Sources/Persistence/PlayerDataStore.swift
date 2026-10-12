import Foundation
import PostgresNIO

/// A kind of online data the server holds for a player (#28, #160).
public enum StoredOnlineData: String, Sendable, CaseIterable {
    /// Her completed races and wins.
    case profile
    case rating
    case livery
    /// Lobby lines she posted.
    case chat
    case reportsFiled
    /// A rating the Game Center leaderboard shows.
    case leaderboard
    case terms
}

/// What the server holds for a player: by kind, and whether she sat in a race (whose log keeps a seat for her).
public struct HeldOnlineData: Sendable, Equatable {
    public var kinds: Set<StoredOnlineData>
    public var hasRaced: Bool

    public init(kinds: Set<StoredOnlineData> = [], hasRaced: Bool = false) {
        self.kinds = kinds
        self.hasRaced = hasRaced
    }

    public var isEmpty: Bool { kinds.isEmpty && !hasRaced }
}

/// Why a player's online data was deleted (#160).
public enum DeletionReason: String, Sendable, Equatable {
    /// Delete my online data.
    case request
    /// 730 days without an online session (G8).
    case inactive
}

/// A deletion whose leaderboard scores aren't blocked yet: Game Center knows her only by `gamePlayerID`.
public struct PendingScoreBlock: Sendable, Equatable {
    public var id: Int64
    public var gamePlayerID: String
    /// Only scores submitted by then are hers to block: a player who came back may have new ones.
    public var deletedAt: Date
    public var failures: Int

    public init(id: Int64, gamePlayerID: String, deletedAt: Date, failures: Int) {
        self.id = id
        self.gamePlayerID = gamePlayerID
        self.deletedAt = deletedAt
        self.failures = failures
    }
}

/// A deletion's audit record: nothing that names her once her scores are blocked.
public struct DeletionRecord: Sendable, Equatable {
    public var id: Int64
    public var reason: DeletionReason
    public var deletedAt: Date
    /// Until her scores are blocked.
    public var gamePlayerID: String?
    public var scoresBlocked: Int?

    public init(id: Int64, reason: DeletionReason, deletedAt: Date, gamePlayerID: String?, scoresBlocked: Int?) {
        self.id = id
        self.reason = reason
        self.deletedAt = deletedAt
        self.gamePlayerID = gamePlayerID
        self.scoresBlocked = scoresBlocked
    }
}

/// A player's online data in Postgres, as Delete my online data takes it away (#160, #28; migration 0015's audit).
///
/// One transaction: her seats in race logs and her server analytics move to an anonymous player row (`anonymousID`,
/// no Game Center id), so past races still replay and other players' results don't change; the reports she filed and
/// her lobby lines go; then her `players` row, and with it everything that references it (sessions, terms, rating and
/// its history, counts, livery, blocks she made and blocks of her, briefing leaves). Reports against her and her
/// penalties name her only by id and stay for their #28 retention (#153).
public struct PlayerDataStore: Sendable {
    /// Anonymous players' ids start with this: never a Game Center id, and never deleted for inactivity.
    public static let anonymousPrefix = "deleted:"

    let database: Database
    public init(_ database: Database) { self.database = database }

    public func held(by playerID: String) async throws -> HeldOnlineData {
        let rows = try await database.client.query("""
            SELECT EXISTS (SELECT 1 FROM player_stats WHERE player_id = \(playerID) AND (completed_races > 0 OR wins > 0)),
                EXISTS (SELECT 1 FROM ratings WHERE player_id = \(playerID)),
                EXISTS (SELECT 1 FROM player_liveries WHERE player_id = \(playerID)),
                EXISTS (SELECT 1 FROM lobby_messages WHERE author_id = \(playerID)),
                EXISTS (SELECT 1 FROM moderation_reports WHERE reporter_id = \(playerID)),
                EXISTS (SELECT 1 FROM ratings WHERE player_id = \(playerID) AND mirrored_rating IS NOT NULL),
                EXISTS (SELECT 1 FROM terms_acceptances WHERE player_id = \(playerID)),
                EXISTS (SELECT 1 FROM race_players WHERE player_id = \(playerID))
            """, logger: database.logger)
        for try await (profile, rating, livery, chat, reports, leaderboard, terms, raced)
            in rows.decode((Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool).self) {
            let flags: [(StoredOnlineData, Bool)] = [(.profile, profile), (.rating, rating), (.livery, livery), (.chat, chat),
                                                     (.reportsFiled, reports), (.leaderboard, leaderboard), (.terms, terms)]
            return HeldOnlineData(kinds: Set(flags.filter(\.1).map(\.0)), hasRaced: raced)
        }
        return HeldOnlineData()
    }

    /// Deletes the player's online data, as above, and records the deletion. False when she isn't stored.
    @discardableResult
    public func erase(_ playerID: String, as anonymousID: String, reason: DeletionReason, at time: Date) async throws -> Bool {
        precondition(anonymousID.hasPrefix(Self.anonymousPrefix), "an anonymous id starts \(Self.anonymousPrefix)")
        return try await database.transaction { connection in
            let logger = database.logger
            let found = try await connection.query(
                "SELECT game_player_id FROM players WHERE team_player_id = \(playerID) FOR UPDATE", logger: logger)
            var gamePlayerID: String??
            for try await game in found.decode(String?.self) { gamePlayerID = .some(game) }
            guard let gamePlayerID else { return false }
            try await connection.query("""
                INSERT INTO players (team_player_id, display_name, created_at, last_seen_at, last_session_at)
                VALUES (\(anonymousID), '', \(time), \(time), \(time))
                """, logger: logger)
            try await connection.query("UPDATE race_players SET player_id = \(anonymousID) WHERE player_id = \(playerID)", logger: logger)
            try await connection.query("UPDATE analytics_events SET player_id = \(anonymousID) WHERE player_id = \(playerID)", logger: logger)
            try await connection.query("DELETE FROM moderation_reports WHERE reporter_id = \(playerID)", logger: logger)
            try await connection.query("DELETE FROM lobby_messages WHERE author_id = \(playerID) OR subject_id = \(playerID)", logger: logger)
            try await connection.query("DELETE FROM players WHERE team_player_id = \(playerID)", logger: logger)
            try await connection.query("""
                INSERT INTO data_deletions (reason, deleted_at, game_player_id) VALUES (\(reason.rawValue), \(time), \(gamePlayerID))
                """, logger: logger)
            return true
        }
    }

    /// Players whose last online session was before `time` (G8), oldest first. Never an anonymous one.
    public func inactivePlayers(lastSessionBefore time: Date, limit: Int) async throws -> [String] {
        let rows = try await database.client.query("""
            SELECT team_player_id FROM players
            WHERE last_session_at < \(time) AND team_player_id NOT LIKE \(Self.anonymousPrefix + "%")
            ORDER BY last_session_at, team_player_id LIMIT \(Int64(limit))
            """, logger: database.logger)
        var players: [String] = []
        for try await id in rows.decode(String.self) { players.append(id) }
        return players
    }

    /// Deletions whose scores aren't blocked yet: the fewest failures first, then the oldest.
    public func pendingScoreBlocks(limit: Int) async throws -> [PendingScoreBlock] {
        let rows = try await database.client.query("""
            SELECT id, game_player_id, deleted_at, block_failures FROM data_deletions WHERE game_player_id IS NOT NULL
            ORDER BY block_failures, id LIMIT \(Int64(limit))
            """, logger: database.logger)
        var pending: [PendingScoreBlock] = []
        for try await (id, game, deleted, failures) in rows.decode((Int64, String, Date, Int32).self) {
            pending.append(PendingScoreBlock(id: id, gamePlayerID: game, deletedAt: deleted, failures: Int(failures)))
        }
        return pending
    }

    /// The deletion's scores are blocked: her Game Center id is forgotten, the count kept.
    public func scoresBlocked(_ id: Int64, count: Int, at time: Date) async throws {
        try await database.client.query("""
            UPDATE data_deletions SET game_player_id = NULL, scores_blocked = \(Int32(count)), scores_blocked_at = \(time) WHERE id = \(id)
            """, logger: database.logger)
    }

    public func scoreBlockFailed(_ id: Int64) async throws {
        try await database.client.query("UPDATE data_deletions SET block_failures = block_failures + 1 WHERE id = \(id)",
                                        logger: database.logger)
    }

    /// The audit, newest first.
    public func deletions(limit: Int) async throws -> [DeletionRecord] {
        let rows = try await database.client.query("""
            SELECT id, reason, deleted_at, game_player_id, scores_blocked FROM data_deletions ORDER BY id DESC LIMIT \(Int64(limit))
            """, logger: database.logger)
        var records: [DeletionRecord] = []
        for try await (id, reason, at, game, blocked) in rows.decode((Int64, String, Date, String?, Int32?).self) {
            guard let reason = DeletionReason(rawValue: reason) else { continue }
            records.append(DeletionRecord(id: id, reason: reason, deletedAt: at, gamePlayerID: game, scoresBlocked: blocked.map(Int.init)))
        }
        return records
    }
}
