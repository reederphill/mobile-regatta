import Foundation
import PostgresNIO

/// An online racing suspension (#26; #153 sets it): until a time, or for good.
public struct StoredSuspension: Sendable, Equatable {
    /// When it ends; nil: permanent.
    public let until: Date?

    public init(until: Date?) { self.until = until }

    public static let permanent = StoredSuspension(until: nil)

    /// Whether it still applies at `time`.
    public func applies(at time: Date) -> Bool { until.map { $0 > time } ?? true }
}

/// What may keep a player out of the queue (#26, #147), as stored.
public struct PlayerRestrictions: Sendable, Equatable {
    /// The briefing-leave cooldown's end, if one was set (it may have passed).
    public var cooldownUntil: Date?
    public var suspension: StoredSuspension?
    /// App Attest failed (#158; the client's word until then, ADR 0010).
    public var attestationFailed: Bool

    public init(cooldownUntil: Date? = nil, suspension: StoredSuspension? = nil, attestationFailed: Bool = false) {
        self.cooldownUntil = cooldownUntil
        self.suspension = suspension
        self.attestationFailed = attestationFailed
    }

    public static let none = PlayerRestrictions()
}

/// Queue restrictions in Postgres (#147, ADR 0009): columns on `players` and the `briefing_leaves` rows. A player who
/// isn't stored has none, and setting one for her does nothing (every queued player signed in first).
public struct PlayerRestrictionStore: Sendable {
    let database: Database
    public init(_ database: Database) { self.database = database }

    public func restrictions(of playerID: String) async throws -> PlayerRestrictions {
        let rows = try await database.client.query("""
            SELECT cooldown_until, racing_suspended_until, racing_suspended_permanent, attestation_failed
            FROM players WHERE team_player_id = \(playerID)
            """, logger: database.logger)
        for try await (cooldown, suspendedUntil, permanent, attestation) in rows.decode((Date?, Date?, Bool, Bool).self) {
            let suspension: StoredSuspension? = permanent ? .permanent : suspendedUntil.map { StoredSuspension(until: $0) }
            return PlayerRestrictions(cooldownUntil: cooldown, suspension: suspension, attestationFailed: attestation)
        }
        return .none
    }

    /// Her briefing leaves at or after `since`, oldest first. Older rows are deleted: only the rolling window counts.
    public func briefingLeaves(of playerID: String, since: Date) async throws -> [Date] {
        try await database.transaction { connection in
            try await connection.query("DELETE FROM briefing_leaves WHERE player_id = \(playerID) AND left_at < \(since)",
                                       logger: database.logger)
            let rows = try await connection.query("""
                SELECT left_at FROM briefing_leaves WHERE player_id = \(playerID) ORDER BY left_at
                """, logger: database.logger)
            var times: [Date] = []
            for try await time in rows.decode(Date.self) { times.append(time) }
            return times
        }
    }

    public func recordBriefingLeave(_ playerID: String, race: UUID?, at time: Date) async throws {
        try await database.client.query("""
            INSERT INTO briefing_leaves (player_id, left_at, race_id)
            SELECT team_player_id, \(time), \(race) FROM players WHERE team_player_id = \(playerID)
            """, logger: database.logger)
    }

    public func clearBriefingLeaves(of playerID: String) async throws {
        try await database.client.query("DELETE FROM briefing_leaves WHERE player_id = \(playerID)", logger: database.logger)
    }

    public func setCooldown(_ playerID: String, until: Date?) async throws {
        try await database.client.query("UPDATE players SET cooldown_until = \(until) WHERE team_player_id = \(playerID)",
                                        logger: database.logger)
    }

    /// Sets or lifts (nil) her suspension (#153).
    public func setSuspension(_ playerID: String, _ suspension: StoredSuspension?) async throws {
        let permanent = suspension != nil && suspension?.until == nil
        let until = suspension?.until
        try await database.client.query("""
            UPDATE players SET racing_suspended_until = \(until), racing_suspended_permanent = \(permanent)
            WHERE team_player_id = \(playerID)
            """, logger: database.logger)
    }

    /// Sets or clears her failed-attestation flag (#158).
    public func setAttestationFailed(_ playerID: String, _ failed: Bool) async throws {
        try await database.client.query("UPDATE players SET attestation_failed = \(failed) WHERE team_player_id = \(playerID)",
                                        logger: database.logger)
    }
}
