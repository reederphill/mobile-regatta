import AppAttest
import Foundation
import Persistence
import Synchronization

// The App Attest key store (#158, ADR 0014): each attested key and its last counter. A key is the install's, never the
// player's, so it has no player link (nothing for Delete my online data to erase); keys unused for
// `DeletionSettings.inactiveAfterDays` are purged by the retention job.

public protocol AppAttestKeyStore: Sendable {
    /// Stores a newly attested key. The same key again is a no-op (true, its counter kept); a different public key under
    /// a known id is refused (false).
    func register(_ key: AppAttestKey, at time: Date) async throws -> Bool
    func key(_ keyID: [UInt8]) async throws -> AppAttestKey?
    /// The compare-and-set: moves the counter to `counter` only if it is above the stored one. False: a replay, an
    /// out-of-order connection, or an unknown key.
    func advance(_ keyID: [UInt8], to counter: UInt32, at time: Date) async throws -> Bool
    /// Deletes keys last used before `cutoff`. Returns how many.
    func purge(unusedSince cutoff: Date) async throws -> Int
}

/// Keys in memory, for dev and tests. Lost on restart, so never outside dev (`ServerConfig` requires a database there).
public final class InMemoryAppAttestKeyStore: AppAttestKeyStore {
    private struct Entry {
        var key: AppAttestKey
        var lastUsed: Date
    }

    private let keys = Mutex<[[UInt8]: Entry]>([:])

    public init() {}

    public func register(_ key: AppAttestKey, at time: Date) async throws -> Bool {
        keys.withLock { keys in
            if let known = keys[key.keyID] { return known.key.publicKey == key.publicKey }
            keys[key.keyID] = Entry(key: key, lastUsed: time)
            return true
        }
    }

    public func key(_ keyID: [UInt8]) async throws -> AppAttestKey? { keys.withLock { $0[keyID]?.key } }

    public func advance(_ keyID: [UInt8], to counter: UInt32, at time: Date) async throws -> Bool {
        keys.withLock { keys in
            guard var entry = keys[keyID], entry.key.counter < counter else { return false }
            entry.key.counter = counter
            entry.lastUsed = time
            keys[keyID] = entry
            return true
        }
    }

    public func purge(unusedSince cutoff: Date) async throws -> Int {
        keys.withLock { keys in
            let stale = keys.filter { $0.value.lastUsed < cutoff }.map(\.key)
            for id in stale { keys[id] = nil }
            return stale.count
        }
    }
}

/// Keys in Postgres (migration 0018).
public struct PostgresAppAttestKeyStore: AppAttestKeyStore {
    let records: AppAttestKeyRecordStore

    public init(_ database: Database) { records = AppAttestKeyRecordStore(database) }

    public func register(_ key: AppAttestKey, at time: Date) async throws -> Bool {
        try await records.register(StoredAppAttestKey(keyID: key.keyID, publicKey: key.publicKey, counter: key.counter,
                                                      environment: key.environment.rawValue, receipt: key.receipt), at: time)
    }

    public func key(_ keyID: [UInt8]) async throws -> AppAttestKey? {
        guard let stored = try await records.key(keyID), let environment = AppAttestEnvironment(rawValue: stored.environment) else { return nil }
        return AppAttestKey(keyID: stored.keyID, publicKey: stored.publicKey, counter: stored.counter, environment: environment,
                            receipt: stored.receipt)
    }

    public func advance(_ keyID: [UInt8], to counter: UInt32, at time: Date) async throws -> Bool {
        try await records.advance(keyID, to: counter, at: time)
    }

    public func purge(unusedSince cutoff: Date) async throws -> Int { try await records.purge(unusedSince: cutoff) }
}
