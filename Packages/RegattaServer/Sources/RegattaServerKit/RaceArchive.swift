import Foundation
import Persistence
import Synchronization

// Where races are kept once registered (#148): Postgres in production (ADR 0009), memory in a dev server without a
// database. One protocol, as `AccountStore`. Written by `RaceLifecycle` only.

/// The race registry, logs and results the lifecycle writes and the results API reads.
public protocol RaceArchive: Sendable {
    /// A race starts: `running`, with its human seats' players.
    func register(_ race: UUID, players: [RaceSeatHolder]) async throws
    /// A running race closed: its log, digest, versions and results, all at once.
    func close(_ race: ClosedRaceRecord) async throws
    /// A running race was cancelled: no results, no log.
    func cancel(_ race: UUID) async throws
    /// Server start: every race still `running` was left by a crash (#30). Cancels them and returns their ids.
    func cancelOrphans() async throws -> [UUID]
    /// Nil for a race this archive never registered.
    func state(of race: UUID) async throws -> RaceState?
    /// The newest closed race the player sat in, with her seat (#24).
    func lastRace(of playerID: String) async throws -> StoredRaceResult?
    /// A closed race as it was written, nil unless it closed.
    func closedRace(_ race: UUID) async throws -> ClosedRaceRecord?
}

/// Postgres (`RaceRegistryStore`, `RaceResultStore`, `RaceLogStore`).
public struct PostgresRaceArchive: RaceArchive {
    let database: Database

    public init(_ database: Database) { self.database = database }

    public func register(_ race: UUID, players: [RaceSeatHolder]) async throws {
        try await RaceRegistryStore(database).create(id: race, players: players)
    }

    public func close(_ race: ClosedRaceRecord) async throws { try await RaceResultStore(database).close(race) }

    public func cancel(_ race: UUID) async throws { try await RaceRegistryStore(database).cancel(race) }

    public func cancelOrphans() async throws -> [UUID] { try await RaceRegistryStore(database).cancelOrphans() }

    public func state(of race: UUID) async throws -> RaceState? { try await RaceRegistryStore(database).race(race)?.state }

    public func lastRace(of playerID: String) async throws -> StoredRaceResult? {
        try await RaceResultStore(database).lastRace(of: playerID)
    }

    public func closedRace(_ race: UUID) async throws -> ClosedRaceRecord? {
        guard let record = try await RaceRegistryStore(database).race(race), record.state == .closed,
              let digest = record.digest, let version = record.simulationVersion, let toolchain = record.toolchain,
              let log = try await RaceLogStore(database).log(for: race),
              let results = try await RaceResultStore(database).results(for: race) else { return nil }
        return ClosedRaceRecord(id: race, log: log, digest: digest, simulationVersion: version, toolchain: toolchain,
                                results: results.results, incidents: results.incidents, rated: results.rated)
    }
}

/// In memory, for a dev server without `REGATTA_DATABASE_URL`: nothing outlives the process, so there are never orphans.
public final class InMemoryRaceArchive: RaceArchive {
    private struct Entry {
        var state: RaceState
        var players: [RaceSeatHolder]
        var closed: ClosedRaceRecord?
        var endedAt: Date?
        /// Order of closing, for the last race.
        var closeOrder = 0
    }

    private let entries = Mutex<(races: [UUID: Entry], closes: Int)>(([:], 0))

    public init() {}

    public func register(_ race: UUID, players: [RaceSeatHolder]) async throws {
        try entries.withLock { state in
            guard state.races[race] == nil else { throw PersistenceError.raceExists(race) }
            state.races[race] = Entry(state: .running, players: players)
        }
    }

    public func close(_ race: ClosedRaceRecord) async throws {
        try entries.withLock { state in
            let entry = try Self.running(race.id, in: state.races)
            state.closes += 1
            state.races[race.id] = Entry(state: .closed, players: entry.players, closed: race, endedAt: Date(), closeOrder: state.closes)
        }
    }

    public func cancel(_ race: UUID) async throws {
        try entries.withLock { state in
            var entry = try Self.running(race, in: state.races)
            entry.state = .cancelled
            entry.endedAt = Date()
            state.races[race] = entry
        }
    }

    public func cancelOrphans() async throws -> [UUID] { [] }

    public func state(of race: UUID) async throws -> RaceState? { entries.withLock { $0.races[race]?.state } }

    public func lastRace(of playerID: String) async throws -> StoredRaceResult? {
        entries.withLock { state in
            let theirs = state.races.filter { $0.value.state == .closed && $0.value.players.contains { $0.playerID == playerID } }
            guard let (id, entry) = theirs.max(by: { $0.value.closeOrder < $1.value.closeOrder }), let closed = entry.closed else { return nil }
            return StoredRaceResult(raceID: id, seat: entry.players.first { $0.playerID == playerID }?.seat, results: closed.results,
                                    incidents: closed.incidents, rated: closed.rated, endedAt: entry.endedAt ?? Date())
        }
    }

    public func closedRace(_ race: UUID) async throws -> ClosedRaceRecord? { entries.withLock { $0.races[race]?.closed } }

    private static func running(_ id: UUID, in races: [UUID: Entry]) throws -> Entry {
        guard let entry = races[id] else { throw PersistenceError.raceNotFound(id) }
        guard entry.state == .running else { throw PersistenceError.raceNotInState(id, expected: .running, actual: entry.state) }
        return entry
    }
}
