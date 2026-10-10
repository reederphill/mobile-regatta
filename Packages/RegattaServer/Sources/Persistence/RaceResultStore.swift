import Foundation
import PostgresNIO

/// A race as it closed (#148): what the close writes, in one transaction.
public struct ClosedRaceRecord: Sendable, Equatable {
    public let id: UUID
    /// The host's log, verbatim (`RaceLog.jsonData`): what `regatta-replay` replays to `digest` (ADR 0002).
    public let log: Data
    public let digest: UInt64
    public let simulationVersion: String
    public let toolchain: String
    /// The results as canonical bytes (rows, roster, served turns), and the incident index's (`IncidentIndex`'s
    /// Codable form, which doesn't depend on the platform).
    public let results: Data
    public let incidents: Data
    /// At least 2 humans at the gun (#30).
    public let rated: Bool

    public init(id: UUID, log: Data, digest: UInt64, simulationVersion: String, toolchain: String, results: Data, incidents: Data,
                rated: Bool) {
        self.id = id
        self.log = log
        self.digest = digest
        self.simulationVersion = simulationVersion
        self.toolchain = toolchain
        self.results = results
        self.incidents = incidents
        self.rated = rated
    }
}

/// A closed race's stored results, as one of its players reads them.
public struct StoredRaceResult: Sendable, Equatable {
    public let raceID: UUID
    /// The player's seat, when read for a player; nil when read by race.
    public let seat: Int?
    public let results: Data
    public let incidents: Data
    public let rated: Bool
    public let endedAt: Date

    public init(raceID: UUID, seat: Int?, results: Data, incidents: Data, rated: Bool, endedAt: Date) {
        self.raceID = raceID
        self.seat = seat
        self.results = results
        self.incidents = incidents
        self.rated = rated
        self.endedAt = endedAt
    }
}

/// Closed races' results (#148, ADR 0009): written once with the close, never for a cancelled race. A player's last
/// race is the newest closed race she sat in, so it stays hers until her next race closes (#24).
public struct RaceResultStore: Sendable {
    let database: Database
    public init(_ database: Database) { self.database = database }

    /// Closes a running race with its log, digest, versions and results, all or nothing.
    @discardableResult
    public func close(_ race: ClosedRaceRecord) async throws -> RaceRecord {
        try await database.transaction { connection in
            let logger = database.logger
            let current = try await RaceRegistryStore.state(race.id, on: connection, logger: logger, lock: true)
            guard current == .running else { throw PersistenceError.raceNotInState(race.id, expected: .running, actual: current) }
            let digest = Int64(bitPattern: race.digest)
            try await connection.query("""
                UPDATE races SET state = 'closed', ended_at = now(), digest = \(digest), sim_version = \(race.simulationVersion),
                    toolchain = \(race.toolchain) WHERE id = \(race.id)
                """, logger: logger)
            let logged = try await connection.query("""
                INSERT INTO race_logs (race_id, log) VALUES (\(race.id), \(race.log)) ON CONFLICT (race_id) DO NOTHING RETURNING race_id
                """, logger: logger)
            guard try await logged.collect().count == 1 else { throw PersistenceError.raceLogExists(race.id) }
            try await connection.query("""
                INSERT INTO race_results (race_id, results, incidents, rated) VALUES (\(race.id), \(race.results), \(race.incidents), \(race.rated))
                """, logger: logger)
            return try await RaceRegistryStore.record(race.id, on: connection, logger: logger)!
        }
    }

    /// The race's results, nil unless it closed.
    public func results(for race: UUID) async throws -> StoredRaceResult? {
        let rows = try await database.client.query("""
            SELECT rr.results, rr.incidents, rr.rated, r.ended_at FROM race_results rr JOIN races r ON r.id = rr.race_id
            WHERE rr.race_id = \(race)
            """, logger: database.logger)
        for try await (results, incidents, rated, ended) in rows.decode((Data, Data, Bool, Date).self) {
            return StoredRaceResult(raceID: race, seat: nil, results: results, incidents: incidents, rated: rated, endedAt: ended)
        }
        return nil
    }

    /// The newest closed race `playerID` sat in, with her seat; nil before her first (#24). A cancelled race isn't one.
    public func lastRace(of playerID: String) async throws -> StoredRaceResult? {
        let rows = try await database.client.query("""
            SELECT r.id, p.seat, rr.results, rr.incidents, rr.rated, r.ended_at
            FROM race_players p JOIN races r ON r.id = p.race_id JOIN race_results rr ON rr.race_id = r.id
            WHERE p.player_id = \(playerID) AND r.state = 'closed'
            ORDER BY r.ended_at DESC, r.created_at DESC, r.id DESC LIMIT 1
            """, logger: database.logger)
        for try await (id, seat, results, incidents, rated, ended) in rows.decode((UUID, Int, Data, Data, Bool, Date).self) {
            return StoredRaceResult(raceID: id, seat: seat, results: results, incidents: incidents, rated: rated, endedAt: ended)
        }
        return nil
    }

    /// The race's players by seat.
    public func players(of race: UUID) async throws -> [RaceSeatHolder] {
        let rows = try await database.client.query(
            "SELECT player_id, seat FROM race_players WHERE race_id = \(race) ORDER BY seat", logger: database.logger)
        var players: [RaceSeatHolder] = []
        for try await (player, seat) in rows.decode((String, Int).self) { players.append(RaceSeatHolder(playerID: player, seat: seat)) }
        return players
    }
}
