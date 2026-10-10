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
    /// Another player is bound to this gamePlayerID (#145: bound 1:1 to the teamPlayerID).
    case gamePlayerIDBound(String)
    /// This teamPlayerID is bound to a different gamePlayerID.
    case gamePlayerIDMismatch(String)

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
        case .gamePlayerIDBound(let id): "gamePlayerID \(id) is bound to another player"
        case .gamePlayerIDMismatch(let id): "player \(id) is bound to another gamePlayerID"
        }
    }
}

// MARK: - Players

public struct Player: Sendable, Equatable {
    /// Game Center's `teamPlayerID`, verified by the identity signature (#145): the player's key.
    public let teamPlayerID: String
    /// Game Center's `gamePlayerID`, from the authenticated client (not signed), bound 1:1 to the teamPlayerID. App
    /// Store Connect's score endpoints need it. Nil only for a player from before #145.
    public let gamePlayerID: String?
    public let displayName: String
    public let createdAt: Date
    public let lastSeenAt: Date
    /// The last signed-in online session (lobby, queue or race): the retention clock (G8, #160).
    public let lastSessionAt: Date
}

/// Players keyed by the verified teamPlayerID (#145).
public struct PlayerStore: Sendable {
    let database: Database
    public init(_ database: Database) { self.database = database }

    /// Signs the player in: creates it or updates its name and last-seen time, and binds `gamePlayerID` to it. Throws
    /// `gamePlayerIDBound` when another player holds that gamePlayerID, and `gamePlayerIDMismatch` when this player is
    /// bound to another one; neither changes anything.
    @discardableResult
    public func signIn(teamPlayerID: String, gamePlayerID: String, displayName: String) async throws -> Player {
        try await database.transaction { connection in
            let holders = try await connection.query(
                "SELECT team_player_id FROM players WHERE game_player_id = \(gamePlayerID) FOR UPDATE", logger: database.logger)
            for try await holder in holders.decode(String.self) where holder != teamPlayerID {
                throw PersistenceError.gamePlayerIDBound(gamePlayerID)
            }
            let player: Player
            do {
                let rows = try await connection.query("""
                    INSERT INTO players (team_player_id, game_player_id, display_name) VALUES (\(teamPlayerID), \(gamePlayerID), \(displayName))
                    ON CONFLICT (team_player_id) DO UPDATE SET display_name = EXCLUDED.display_name, last_seen_at = now(),
                        game_player_id = COALESCE(players.game_player_id, EXCLUDED.game_player_id)
                    RETURNING team_player_id, game_player_id, display_name, created_at, last_seen_at, last_session_at
                    """, logger: database.logger)
                player = try await Self.players(rows)[0]
            } catch let error as PSQLError where error.serverInfo?[.sqlState] == "23505" {
                // Another sign-in bound the gamePlayerID between the check and the insert.
                throw PersistenceError.gamePlayerIDBound(gamePlayerID)
            }
            guard player.gamePlayerID == gamePlayerID else { throw PersistenceError.gamePlayerIDMismatch(teamPlayerID) }
            return player
        }
    }

    public func player(teamPlayerID: String) async throws -> Player? {
        let rows = try await database.client.query("""
            SELECT team_player_id, game_player_id, display_name, created_at, last_seen_at, last_session_at
            FROM players WHERE team_player_id = \(teamPlayerID)
            """, logger: database.logger)
        return try await Self.players(rows).first
    }

    /// Records a signed-in online session now (G8): signing in, the lobby, the queue or a race.
    public func touchSession(teamPlayerID: String, at time: Date = Date()) async throws {
        try await database.client.query(
            "UPDATE players SET last_session_at = \(time) WHERE team_player_id = \(teamPlayerID)", logger: database.logger)
    }

    /// Deletes the player, its sessions and its terms acceptances. Returns whether there was one.
    @discardableResult
    public func delete(teamPlayerID: String) async throws -> Bool {
        let rows = try await database.client.query(
            "DELETE FROM players WHERE team_player_id = \(teamPlayerID) RETURNING team_player_id", logger: database.logger)
        return try await rows.collect().count == 1
    }

    static func players(_ rows: PostgresRowSequence) async throws -> [Player] {
        var players: [Player] = []
        for try await (id, game, name, created, seen, session) in rows.decode((String, String?, String, Date, Date, Date).self) {
            players.append(Player(teamPlayerID: id, gamePlayerID: game, displayName: name, createdAt: created, lastSeenAt: seen,
                                  lastSessionAt: session))
        }
        return players
    }
}

// MARK: - Sessions

/// What Game Center reported about the player when the session began (#34). Client-asserted until #158's App
/// Attest assertion covers the request that carries them (TODO(#158)).
public struct SessionRestrictions: Sendable, Equatable {
    public var isUnderage: Bool
    public var isPersonalizedCommunicationRestricted: Bool
    public var isMultiplayerGamingRestricted: Bool

    public init(isUnderage: Bool = false, isPersonalizedCommunicationRestricted: Bool = false, isMultiplayerGamingRestricted: Bool = false) {
        self.isUnderage = isUnderage
        self.isPersonalizedCommunicationRestricted = isPersonalizedCommunicationRestricted
        self.isMultiplayerGamingRestricted = isMultiplayerGamingRestricted
    }

    public static let unrestricted = SessionRestrictions()
}

public struct Session: Sendable, Equatable {
    public let id: UUID
    public let playerID: String
    public let tokenHash: Data
    public let createdAt: Date
    public let expiresAt: Date
    public let restrictions: SessionRestrictions
}

/// A player's sessions, by the SHA-256 of the session token (never the token).
public struct SessionStore: Sendable {
    let database: Database
    public init(_ database: Database) { self.database = database }

    /// A new session. `createdAt` starts its absolute lifetime (#146); nil: the database's now.
    @discardableResult
    public func create(playerID: String, tokenHash: Data, expiresAt: Date, restrictions: SessionRestrictions = .unrestricted,
                       id: UUID = UUID(), createdAt: Date? = nil) async throws -> Session {
        let rows = try await database.client.query("""
            INSERT INTO sessions (id, player_id, token_hash, created_at, expires_at, underage, communication_restricted, multiplayer_restricted)
            VALUES (\(id), \(playerID), \(tokenHash), COALESCE(\(createdAt), now()), \(expiresAt), \(restrictions.isUnderage),
                \(restrictions.isPersonalizedCommunicationRestricted), \(restrictions.isMultiplayerGamingRestricted))
            RETURNING id, player_id, token_hash, created_at, expires_at, underage, communication_restricted, multiplayer_restricted
            """, logger: database.logger)
        return try await Self.sessions(rows)[0]
    }

    /// The unexpired session with this token hash, if any.
    public func session(tokenHash: Data, at now: Date = Date()) async throws -> Session? {
        let rows = try await database.client.query("""
            SELECT id, player_id, token_hash, created_at, expires_at, underage, communication_restricted, multiplayer_restricted
            FROM sessions WHERE token_hash = \(tokenHash) AND expires_at > \(now)
            """, logger: database.logger)
        return try await Self.sessions(rows).first
    }

    /// Moves an unexpired session's expiry to `expiresAt` (a sliding lifetime), and its restrictions to what Game
    /// Center reports now when given. Returns the session, or nil when it's gone or expired.
    public func refresh(id: UUID, expiresAt: Date, restrictions: SessionRestrictions?, at now: Date = Date()) async throws -> Session? {
        let rows: PostgresRowSequence
        if let restrictions {
            rows = try await database.client.query("""
                UPDATE sessions SET expires_at = \(expiresAt), underage = \(restrictions.isUnderage),
                    communication_restricted = \(restrictions.isPersonalizedCommunicationRestricted),
                    multiplayer_restricted = \(restrictions.isMultiplayerGamingRestricted)
                WHERE id = \(id) AND expires_at > \(now)
                RETURNING id, player_id, token_hash, created_at, expires_at, underage, communication_restricted, multiplayer_restricted
                """, logger: database.logger)
        } else {
            rows = try await database.client.query("""
                UPDATE sessions SET expires_at = \(expiresAt) WHERE id = \(id) AND expires_at > \(now)
                RETURNING id, player_id, token_hash, created_at, expires_at, underage, communication_restricted, multiplayer_restricted
                """, logger: database.logger)
        }
        return try await Self.sessions(rows).first
    }

    @discardableResult
    public func delete(id: UUID) async throws -> Bool {
        let rows = try await database.client.query("DELETE FROM sessions WHERE id = \(id) RETURNING id",
                                                   logger: database.logger)
        return try await rows.collect().count == 1
    }

    /// Caps the player's sessions (#146, R11): deletes the expired ones and all but the newest `keep` of the rest,
    /// never `protecting` (the session just opened). Returns how many it deleted.
    @discardableResult
    public func trim(playerID: String, keep: Int, protecting: UUID, at now: Date = Date()) async throws -> Int {
        let others = max(0, keep - 1)
        let rows = try await database.client.query("""
            DELETE FROM sessions WHERE player_id = \(playerID) AND id <> \(protecting) AND (expires_at <= \(now) OR id NOT IN (
                SELECT id FROM sessions WHERE player_id = \(playerID) AND id <> \(protecting) AND expires_at > \(now)
                ORDER BY created_at DESC, id LIMIT \(others)))
            RETURNING id
            """, logger: database.logger)
        return try await rows.collect().count
    }

    /// The player's sessions, newest first (expired ones too): for tests and the session cap.
    public func sessions(playerID: String) async throws -> [Session] {
        let rows = try await database.client.query("""
            SELECT id, player_id, token_hash, created_at, expires_at, underage, communication_restricted, multiplayer_restricted
            FROM sessions WHERE player_id = \(playerID) ORDER BY created_at DESC, id
            """, logger: database.logger)
        return try await Self.sessions(rows)
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
        for try await (id, player, hash, created, expires, underage, communication, multiplayer)
            in rows.decode((UUID, String, Data, Date, Date, Bool, Bool, Bool).self) {
            sessions.append(Session(id: id, playerID: player, tokenHash: hash, createdAt: created, expiresAt: expires,
                                    restrictions: SessionRestrictions(isUnderage: underage, isPersonalizedCommunicationRestricted: communication,
                                                                      isMultiplayerGamingRestricted: multiplayer)))
        }
        return sessions
    }
}

// MARK: - Terms of Use

/// Which Terms of Use versions each player accepted, and when (#145, #34). Kept while the player is active and
/// deleted with the player's online data (G8).
public struct TermsStore: Sendable {
    let database: Database
    public init(_ database: Database) { self.database = database }

    /// Records the player's acceptance of `version`; accepting a version twice keeps the first time.
    public func accept(playerID: String, version: Int, at time: Date = Date()) async throws {
        try await database.client.query("""
            INSERT INTO terms_acceptances (player_id, version, accepted_at) VALUES (\(playerID), \(version), \(time))
            ON CONFLICT (player_id, version) DO NOTHING
            """, logger: database.logger)
    }

    /// The newest version the player accepted, or nil.
    public func lastAccepted(playerID: String) async throws -> Int? {
        let rows = try await database.client.query(
            "SELECT max(version) FROM terms_acceptances WHERE player_id = \(playerID)", logger: database.logger)
        for try await version in rows.decode(Int?.self) { return version }
        return nil
    }

    /// When the player accepted `version`, or nil.
    public func acceptedAt(playerID: String, version: Int) async throws -> Date? {
        let rows = try await database.client.query(
            "SELECT accepted_at FROM terms_acceptances WHERE player_id = \(playerID) AND version = \(version)", logger: database.logger)
        for try await time in rows.decode(Date.self) { return time }
        return nil
    }
}
