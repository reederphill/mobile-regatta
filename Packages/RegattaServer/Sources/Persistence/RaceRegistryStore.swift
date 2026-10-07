import Foundation
import PostgresNIO
import RegattaCore

/// Where a registered race is (#30): running until it closes, or is cancelled (by hand or as an orphan when the
/// server restarts).
public enum RaceState: String, Sendable, Equatable, CaseIterable {
    case running, closed, cancelled
}

public struct RaceRecord: Sendable, Equatable {
    public let id: UUID
    public let state: RaceState
    public let createdAt: Date
    public let endedAt: Date?
    /// The data files the race names at race start (#32), by id.
    public let files: [DataFileKey]
}

/// The race registry (#30): each race the server starts, its state and the data files it names.
public struct RaceRegistryStore: Sendable {
    let database: Database
    public init(_ database: Database) { self.database = database }

    /// Registers a running race naming `files`, each of which must already be in the data-file store with that
    /// hash (the server names each file's hash at race start, #32).
    @discardableResult
    public func create(id: UUID = UUID(), files: [FileRef] = []) async throws -> RaceRecord {
        try await database.transaction { connection in
            let inserted = try await connection.query(
                "INSERT INTO races (id, state) VALUES (\(id), 'running') ON CONFLICT (id) DO NOTHING RETURNING id",
                logger: database.logger)
            guard try await inserted.collect().count == 1 else { throw PersistenceError.raceExists(id) }
            for file in files {
                let stored = try await connection.query(
                    "SELECT hash FROM data_files WHERE id = \(file.id) AND version = \(file.version)",
                    logger: database.logger)
                var matches = false
                for try await hash in stored.decode(Data.self) { matches = hash == Data(file.hash.bytes) }
                guard matches, file.tune == nil else { throw PersistenceError.hashMismatch(file.key) }
                try await connection.query("""
                    INSERT INTO race_files (race_id, file_id, file_version) VALUES (\(id), \(file.id), \(file.version))
                    """, logger: database.logger)
            }
            return try await Self.record(id, on: connection, logger: database.logger)!
        }
    }

    public func race(_ id: UUID) async throws -> RaceRecord? {
        try await database.client.withConnection { connection in
            try await Self.record(id, on: connection, logger: database.logger)
        }
    }

    /// The races in `state`, oldest first.
    public func races(in state: RaceState) async throws -> [RaceRecord] {
        try await database.client.withConnection { connection in
            let rows = try await connection.query(
                "SELECT id FROM races WHERE state = \(state.rawValue) ORDER BY created_at, id", logger: database.logger)
            var ids: [UUID] = []
            for try await id in rows.decode(UUID.self) { ids.append(id) }
            var records: [RaceRecord] = []
            for id in ids {
                if let record = try await Self.record(id, on: connection, logger: database.logger) { records.append(record) }
            }
            return records
        }
    }

    /// A running race finished.
    @discardableResult
    public func close(_ id: UUID) async throws -> RaceRecord { try await end(id, as: .closed) }

    /// A running race was stopped without a result.
    @discardableResult
    public func cancel(_ id: UUID) async throws -> RaceRecord { try await end(id, as: .cancelled) }

    /// Cancels every race still running (#30): run at server start, when no race can still be running, so a
    /// crash's orphans don't stay "running". Returns their ids.
    @discardableResult
    public func cancelOrphans() async throws -> [UUID] {
        let rows = try await database.client.query("""
            UPDATE races SET state = 'cancelled', ended_at = now() WHERE state = 'running' RETURNING id
            """, logger: database.logger)
        var ids: [UUID] = []
        for try await id in rows.decode(UUID.self) { ids.append(id) }
        return ids.sorted { $0.uuidString < $1.uuidString }
    }

    /// Deletes a cancelled race (one with no result or log). A running or closed race isn't deleted.
    public func delete(_ id: UUID) async throws {
        try await database.transaction { connection in
            let state = try await Self.state(id, on: connection, logger: database.logger)
            guard state == .cancelled else {
                throw PersistenceError.raceNotInState(id, expected: .cancelled, actual: state)
            }
            try await connection.query("DELETE FROM race_logs WHERE race_id = \(id)", logger: database.logger)
            try await connection.query("DELETE FROM races WHERE id = \(id)", logger: database.logger)
        }
    }

    private func end(_ id: UUID, as state: RaceState) async throws -> RaceRecord {
        try await database.transaction { connection in
            let current = try await Self.state(id, on: connection, logger: database.logger, lock: true)
            guard current == .running else { throw PersistenceError.raceNotInState(id, expected: .running, actual: current) }
            try await connection.query("UPDATE races SET state = \(state.rawValue), ended_at = now() WHERE id = \(id)",
                                       logger: database.logger)
            return try await Self.record(id, on: connection, logger: database.logger)!
        }
    }

    static func state(_ id: UUID, on connection: PostgresConnection, logger: Logger,
                              lock: Bool = false) async throws -> RaceState {
        let rows = try await connection.query(
            lock ? "SELECT state FROM races WHERE id = \(id) FOR UPDATE" : "SELECT state FROM races WHERE id = \(id)",
            logger: logger)
        for try await state in rows.decode(String.self) {
            if let state = RaceState(rawValue: state) { return state }
        }
        throw PersistenceError.raceNotFound(id)
    }

    private static func record(_ id: UUID, on connection: PostgresConnection, logger: Logger) async throws -> RaceRecord? {
        let rows = try await connection.query(
            "SELECT state, created_at, ended_at FROM races WHERE id = \(id)", logger: logger)
        var found: (RaceState, Date, Date?)?
        for try await (state, created, ended) in rows.decode((String, Date, Date?).self) {
            guard let state = RaceState(rawValue: state) else { continue }
            found = (state, created, ended)
        }
        guard let (state, created, ended) = found else { return nil }
        let files = try await connection.query(
            "SELECT file_id, file_version FROM race_files WHERE race_id = \(id) ORDER BY file_id", logger: logger)
        var keys: [DataFileKey] = []
        for try await (fileID, version) in files.decode((String, Int).self) {
            keys.append(DataFileKey(id: fileID, version: version))
        }
        return RaceRecord(id: id, state: state, createdAt: created, endedAt: ended, files: keys)
    }
}

/// Each race's log, as bytes in Postgres (ADR 0009). Behind a protocol so an object store can take over later
/// without the callers changing.
public protocol RaceLogStoring: Sendable {
    func put(_ log: Data, for race: UUID) async throws
    func log(for race: UUID) async throws -> Data?
}

public struct RaceLogStore: RaceLogStoring {
    let database: Database
    public init(_ database: Database) { self.database = database }

    /// Stores a race's log, once. The race must be registered.
    public func put(_ log: Data, for race: UUID) async throws {
        try await database.transaction { connection in
            _ = try await RaceRegistryStore.state(race, on: connection, logger: database.logger)
            let rows = try await connection.query("""
                INSERT INTO race_logs (race_id, log) VALUES (\(race), \(log)) ON CONFLICT (race_id) DO NOTHING RETURNING race_id
                """, logger: database.logger)
            guard try await rows.collect().count == 1 else { throw PersistenceError.raceLogExists(race) }
        }
    }

    public func log(for race: UUID) async throws -> Data? {
        let rows = try await database.client.query("SELECT log FROM race_logs WHERE race_id = \(race)",
                                                   logger: database.logger)
        for try await log in rows.decode(Data.self) { return log }
        return nil
    }
}
