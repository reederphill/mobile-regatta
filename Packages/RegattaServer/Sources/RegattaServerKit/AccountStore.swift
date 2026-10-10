import Foundation
import Persistence

// What the service endpoint (#145) keeps about players: who they are (by the verified teamPlayerID, with their
// gamePlayerID bound 1:1), their sessions (by the token's SHA-256) and the Terms of Use versions they accepted. In
// Postgres when `REGATTA_DATABASE_URL` is set (ADR 0009); in memory for a dev server without one, and for tests.

/// A signed-in player as the endpoint sees it.
public struct AccountPlayer: Sendable, Equatable {
    public var teamPlayerID: String
    public var gamePlayerID: String
    public var alias: String
}

/// A live session.
public struct AccountSession: Sendable, Equatable {
    public var id: UUID
    public var playerID: String
    /// When it was opened: its absolute lifetime runs from here (#146, R11).
    public var createdAt: Date
    public var expiresAt: Date
    public var restrictions: SessionRestrictions
}

public enum AccountStoreError: Error, Equatable, Sendable {
    /// Another player holds the gamePlayerID, or this player holds another one (#145: bound 1:1).
    case gamePlayerIDConflict
}

public protocol AccountStore: Sendable {
    /// Creates or updates the player and binds `gamePlayerID` to it; throws `gamePlayerIDConflict` without changing anything.
    func signIn(teamPlayerID: String, gamePlayerID: String, alias: String) async throws -> AccountPlayer
    func player(teamPlayerID: String) async throws -> AccountPlayer?
    /// Records a signed-in online session (G8's retention clock).
    func touchSession(teamPlayerID: String, at time: Date) async throws
    func createSession(playerID: String, tokenHash: Data, expiresAt: Date, restrictions: SessionRestrictions, at time: Date) async throws -> AccountSession
    /// Caps the player's sessions: deletes its expired ones and all but the newest `keep`, never `protecting` (#146, R11).
    func trimSessions(playerID: String, keep: Int, protecting: UUID, at time: Date) async throws
    /// Deletes every session expired at `time`; returns how many (#146, R11).
    func deleteExpiredSessions(at time: Date) async throws -> Int
    func session(tokenHash: Data, at time: Date) async throws -> AccountSession?
    /// Slides an unexpired session's expiry and takes the restrictions Game Center reports now.
    func refreshSession(id: UUID, expiresAt: Date, restrictions: SessionRestrictions, at time: Date) async throws -> AccountSession?
    func deleteSession(id: UUID) async throws
    func lastAcceptedTerms(playerID: String) async throws -> Int?
    func acceptTerms(playerID: String, version: Int, at time: Date) async throws
}

/// The Postgres store (ADR 0009), over `Persistence`'s tables (migration 0006).
public struct PostgresAccountStore: AccountStore {
    let players: PlayerStore
    let sessions: SessionStore
    let terms: TermsStore

    public init(_ database: Database) {
        players = PlayerStore(database)
        sessions = SessionStore(database)
        terms = TermsStore(database)
    }

    public func signIn(teamPlayerID: String, gamePlayerID: String, alias: String) async throws -> AccountPlayer {
        do {
            let player = try await players.signIn(teamPlayerID: teamPlayerID, gamePlayerID: gamePlayerID, displayName: alias)
            return AccountPlayer(teamPlayerID: player.teamPlayerID, gamePlayerID: gamePlayerID, alias: player.displayName)
        } catch PersistenceError.gamePlayerIDBound, PersistenceError.gamePlayerIDMismatch {
            throw AccountStoreError.gamePlayerIDConflict
        }
    }

    public func player(teamPlayerID: String) async throws -> AccountPlayer? {
        guard let player = try await players.player(teamPlayerID: teamPlayerID), let game = player.gamePlayerID else { return nil }
        return AccountPlayer(teamPlayerID: player.teamPlayerID, gamePlayerID: game, alias: player.displayName)
    }

    public func touchSession(teamPlayerID: String, at time: Date) async throws {
        try await players.touchSession(teamPlayerID: teamPlayerID, at: time)
    }

    public func createSession(playerID: String, tokenHash: Data, expiresAt: Date, restrictions: SessionRestrictions,
                              at time: Date) async throws -> AccountSession {
        Self.session(try await sessions.create(playerID: playerID, tokenHash: tokenHash, expiresAt: expiresAt, restrictions: restrictions,
                                               createdAt: time))
    }

    public func trimSessions(playerID: String, keep: Int, protecting: UUID, at time: Date) async throws {
        try await sessions.trim(playerID: playerID, keep: keep, protecting: protecting, at: time)
    }

    public func deleteExpiredSessions(at time: Date) async throws -> Int { try await sessions.deleteExpired(at: time) }

    public func session(tokenHash: Data, at time: Date) async throws -> AccountSession? {
        try await sessions.session(tokenHash: tokenHash, at: time).map(Self.session)
    }

    public func refreshSession(id: UUID, expiresAt: Date, restrictions: SessionRestrictions, at time: Date) async throws -> AccountSession? {
        try await sessions.refresh(id: id, expiresAt: expiresAt, restrictions: restrictions, at: time).map(Self.session)
    }

    public func deleteSession(id: UUID) async throws { try await sessions.delete(id: id) }

    public func lastAcceptedTerms(playerID: String) async throws -> Int? { try await terms.lastAccepted(playerID: playerID) }

    public func acceptTerms(playerID: String, version: Int, at time: Date) async throws {
        try await terms.accept(playerID: playerID, version: version, at: time)
    }

    static func session(_ session: Session) -> AccountSession {
        AccountSession(id: session.id, playerID: session.playerID, createdAt: session.createdAt, expiresAt: session.expiresAt,
                       restrictions: session.restrictions)
    }
}

/// The same rules in memory: a dev server without a database, and the endpoint tests that don't need Postgres.
public actor InMemoryAccountStore: AccountStore {
    private var players: [String: AccountPlayer] = [:]
    private var sessions: [Data: AccountSession] = [:]
    /// Creation order, to break ties between sessions opened at the same time.
    private var order: [UUID: Int] = [:]
    private var created = 0
    private var terms: [String: Set<Int>] = [:]
    /// Each player's last online session, for tests.
    public private(set) var lastSession: [String: Date] = [:]

    public init() {}

    public func signIn(teamPlayerID: String, gamePlayerID: String, alias: String) throws -> AccountPlayer {
        if let holder = players.values.first(where: { $0.gamePlayerID == gamePlayerID }), holder.teamPlayerID != teamPlayerID {
            throw AccountStoreError.gamePlayerIDConflict
        }
        if let existing = players[teamPlayerID], existing.gamePlayerID != gamePlayerID { throw AccountStoreError.gamePlayerIDConflict }
        let player = AccountPlayer(teamPlayerID: teamPlayerID, gamePlayerID: gamePlayerID, alias: alias)
        players[teamPlayerID] = player
        return player
    }

    public func player(teamPlayerID: String) -> AccountPlayer? { players[teamPlayerID] }

    public func touchSession(teamPlayerID: String, at time: Date) { lastSession[teamPlayerID] = time }

    public func createSession(playerID: String, tokenHash: Data, expiresAt: Date, restrictions: SessionRestrictions,
                              at time: Date) throws -> AccountSession {
        let session = AccountSession(id: UUID(), playerID: playerID, createdAt: time, expiresAt: expiresAt, restrictions: restrictions)
        sessions[tokenHash] = session
        created += 1
        order[session.id] = created
        return session
    }

    public func trimSessions(playerID: String, keep: Int, protecting: UUID, at time: Date) {
        let live = sessions.values.filter { $0.playerID == playerID && $0.id != protecting && $0.expiresAt > time }
            .sorted { ($0.createdAt, order[$0.id] ?? 0) > ($1.createdAt, order[$1.id] ?? 0) }
        let kept = Set(live.prefix(max(0, keep - 1)).map(\.id))
        sessions = sessions.filter { $0.value.playerID != playerID || $0.value.id == protecting || kept.contains($0.value.id) }
    }

    public func deleteExpiredSessions(at time: Date) -> Int {
        let before = sessions.count
        sessions = sessions.filter { $0.value.expiresAt > time }
        return before - sessions.count
    }

    /// The player's sessions, live or expired, for tests.
    public func sessions(playerID: String) -> [AccountSession] { sessions.values.filter { $0.playerID == playerID } }

    public func session(tokenHash: Data, at time: Date) -> AccountSession? {
        guard let session = sessions[tokenHash], session.expiresAt > time else { return nil }
        return session
    }

    public func refreshSession(id: UUID, expiresAt: Date, restrictions: SessionRestrictions, at time: Date) -> AccountSession? {
        guard let (hash, session) = sessions.first(where: { $0.value.id == id }), session.expiresAt > time else { return nil }
        var refreshed = session
        refreshed.expiresAt = expiresAt
        refreshed.restrictions = restrictions
        sessions[hash] = refreshed
        return refreshed
    }

    public func deleteSession(id: UUID) { sessions = sessions.filter { $0.value.id != id } }

    public func lastAcceptedTerms(playerID: String) -> Int? { terms[playerID]?.max() }

    public func acceptTerms(playerID: String, version: Int, at time: Date) { terms[playerID, default: []].insert(version) }
}
