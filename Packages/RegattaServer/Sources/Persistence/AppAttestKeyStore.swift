import Foundation
import PostgresNIO

/// An attested App Attest key as stored (#158): the verifier's `AppAttestKey`, its environment as text.
public struct StoredAppAttestKey: Sendable, Equatable {
    public var keyID: [UInt8]
    public var publicKey: [UInt8]
    public var counter: UInt32
    public var environment: String
    public var receipt: [UInt8]

    public init(keyID: [UInt8], publicKey: [UInt8], counter: UInt32, environment: String, receipt: [UInt8]) {
        self.keyID = keyID
        self.publicKey = publicKey
        self.counter = counter
        self.environment = environment
        self.receipt = receipt
    }
}

/// App Attest keys in Postgres (#158, migration 0018). No player link (ADR 0014).
public struct AppAttestKeyRecordStore: Sendable {
    let database: Database
    public init(_ database: Database) { self.database = database }

    /// Stores a newly attested key, insert-only: true only when this statement inserted the row (`RETURNING`). A known
    /// id is refused (false, the row untouched) whatever its public key, so concurrent copies of one attestation
    /// register once.
    public func register(_ key: StoredAppAttestKey, at time: Date) async throws -> Bool {
        let id = Data(key.keyID), publicKey = Data(key.publicKey), receipt = Data(key.receipt), counter = Int64(key.counter)
        let inserted = try await database.client.query("""
            INSERT INTO app_attest_keys (key_id, public_key, counter, environment, receipt, created_at, last_used_at)
            VALUES (\(id), \(publicKey), \(counter), \(key.environment), \(receipt), \(time), \(time))
            ON CONFLICT (key_id) DO NOTHING RETURNING 1
            """, logger: database.logger)
        return try await inserted.collect().count == 1
    }

    public func key(_ keyID: [UInt8]) async throws -> StoredAppAttestKey? {
        let rows = try await database.client.query("""
            SELECT public_key, counter, environment, receipt FROM app_attest_keys WHERE key_id = \(Data(keyID))
            """, logger: database.logger)
        for try await (publicKey, counter, environment, receipt) in rows.decode((Data, Int64, String, Data?).self) {
            return StoredAppAttestKey(keyID: keyID, publicKey: Array(publicKey), counter: UInt32(clamping: counter),
                                      environment: environment, receipt: receipt.map(Array.init) ?? [])
        }
        return nil
    }

    /// Moves the key's counter to `counter` if it is above the stored one, atomically: false is a replay (or an
    /// unknown key). Two connections racing with the same counter: exactly one wins.
    public func advance(_ keyID: [UInt8], to counter: UInt32, at time: Date) async throws -> Bool {
        let rows = try await database.client.query("""
            UPDATE app_attest_keys SET counter = \(Int64(counter)), last_used_at = \(time)
            WHERE key_id = \(Data(keyID)) AND counter < \(Int64(counter)) RETURNING 1
            """, logger: database.logger)
        return try await rows.collect().count == 1
    }

    /// Deletes keys last used before `cutoff`. Returns how many.
    public func purge(unusedSince cutoff: Date) async throws -> Int {
        let rows = try await database.client.query("DELETE FROM app_attest_keys WHERE last_used_at < \(cutoff) RETURNING 1",
                                                   logger: database.logger)
        return try await rows.collect().count
    }
}
