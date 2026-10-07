import Foundation
import PostgresNIO
import RegattaCore

/// What a store refuses.
public enum PersistenceError: Error, Equatable, CustomStringConvertible {
    case raceNotFound(UUID)
    /// Only a running race closes or is cancelled; only a cancelled one is deleted.
    case raceNotInState(UUID, expected: RaceState, actual: RaceState)
    case raceExists(UUID)
    /// A race's log is written once.
    case raceLogExists(UUID)
    /// The content's hash isn't the one the `FileRef` names.
    case hashMismatch(DataFileKey)
    /// This id and version is stored with a different hash: a released version never changes (#32).
    case versionConflict(DataFileKey)
    /// Tuned copies sail practice races only (#229) and never reach the server's store.
    case tunedFile(DataFileKey)
    /// A race names each data file once.
    case duplicateFile(String)

    public var description: String {
        switch self {
        case .raceNotFound(let id): "no race \(id)"
        case .raceNotInState(let id, let expected, let actual): "race \(id) is \(actual.rawValue), not \(expected.rawValue)"
        case .raceExists(let id): "race \(id) is already registered"
        case .raceLogExists(let id): "race \(id) already has a log"
        case .hashMismatch(let key): "\(key)'s content doesn't match its hash"
        case .versionConflict(let key): "\(key) is already stored with a different hash"
        case .tunedFile(let key): "\(key) is a tuned copy"
        case .duplicateFile(let id): "the race names \(id) more than once"
        }
    }
}

// MARK: - Players

public struct Player: Sendable, Equatable {
    public let gameCenterID: String
    public let displayName: String
    public let createdAt: Date
    public let lastSeenAt: Date
}

/// Players keyed by Game Center id (#145 signs them in).
public struct PlayerStore: Sendable {
    let database: Database
    public init(_ database: Database) { self.database = database }

    /// Creates the player, or updates its name and last-seen time.
    @discardableResult
    public func upsert(gameCenterID: String, displayName: String) async throws -> Player {
        let rows = try await database.client.query("""
            INSERT INTO players (game_center_id, display_name) VALUES (\(gameCenterID), \(displayName))
            ON CONFLICT (game_center_id) DO UPDATE SET display_name = EXCLUDED.display_name, last_seen_at = now()
            RETURNING game_center_id, display_name, created_at, last_seen_at
            """, logger: database.logger)
        return try await Self.players(rows)[0]
    }

    public func player(gameCenterID: String) async throws -> Player? {
        let rows = try await database.client.query("""
            SELECT game_center_id, display_name, created_at, last_seen_at FROM players WHERE game_center_id = \(gameCenterID)
            """, logger: database.logger)
        return try await Self.players(rows).first
    }

    /// Deletes the player and its sessions. Returns whether there was one.
    @discardableResult
    public func delete(gameCenterID: String) async throws -> Bool {
        let rows = try await database.client.query(
            "DELETE FROM players WHERE game_center_id = \(gameCenterID) RETURNING game_center_id", logger: database.logger)
        return try await rows.collect().count == 1
    }

    static func players(_ rows: PostgresRowSequence) async throws -> [Player] {
        var players: [Player] = []
        for try await (id, name, created, seen) in rows.decode((String, String, Date, Date).self) {
            players.append(Player(gameCenterID: id, displayName: name, createdAt: created, lastSeenAt: seen))
        }
        return players
    }
}

// MARK: - Sessions

public struct Session: Sendable, Equatable {
    public let id: UUID
    public let playerID: String
    public let tokenHash: Data
    public let createdAt: Date
    public let expiresAt: Date
}

/// A player's sessions, by the hash of the session token. The minimal shape #145 builds on.
public struct SessionStore: Sendable {
    let database: Database
    public init(_ database: Database) { self.database = database }

    @discardableResult
    public func create(playerID: String, tokenHash: Data, expiresAt: Date, id: UUID = UUID()) async throws -> Session {
        let rows = try await database.client.query("""
            INSERT INTO sessions (id, player_id, token_hash, expires_at) VALUES (\(id), \(playerID), \(tokenHash), \(expiresAt))
            RETURNING id, player_id, token_hash, created_at, expires_at
            """, logger: database.logger)
        return try await Self.sessions(rows)[0]
    }

    /// The unexpired session with this token hash, if any.
    public func session(tokenHash: Data, at now: Date = Date()) async throws -> Session? {
        let rows = try await database.client.query("""
            SELECT id, player_id, token_hash, created_at, expires_at FROM sessions
            WHERE token_hash = \(tokenHash) AND expires_at > \(now)
            """, logger: database.logger)
        return try await Self.sessions(rows).first
    }

    @discardableResult
    public func delete(id: UUID) async throws -> Bool {
        let rows = try await database.client.query("DELETE FROM sessions WHERE id = \(id) RETURNING id",
                                                   logger: database.logger)
        return try await rows.collect().count == 1
    }

    /// Deletes sessions expired at `now`. Returns how many.
    @discardableResult
    public func deleteExpired(at now: Date = Date()) async throws -> Int {
        let rows = try await database.client.query("DELETE FROM sessions WHERE expires_at <= \(now) RETURNING id",
                                                   logger: database.logger)
        return try await rows.collect().count
    }

    static func sessions(_ rows: PostgresRowSequence) async throws -> [Session] {
        var sessions: [Session] = []
        for try await (id, player, hash, created, expires) in rows.decode((UUID, String, Data, Date, Date).self) {
            sessions.append(Session(id: id, playerID: player, tokenHash: hash, createdAt: created, expiresAt: expires))
        }
        return sessions
    }
}
