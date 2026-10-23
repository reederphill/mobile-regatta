import Foundation
import Persistence
import PostgresNIO
import Testing

/// #158: App Attest keys in Postgres (migration 0018): register is idempotent, another public key under a known id is
/// refused, `advance` is a compare-and-set that exactly one of 8 concurrent callers wins per counter, purge works.
@Suite(TestDatabase.available) struct AppAttestKeyStoreTests {
    static let time = Date(timeIntervalSince1970: 1_791_460_800)

    static func sample(_ byte: UInt8, publicKey: [UInt8] = [4, 1, 2]) -> StoredAppAttestKey {
        StoredAppAttestKey(keyID: Array(repeating: byte, count: 32), publicKey: publicKey, counter: 0, environment: "development",
                           receipt: [0x30, 0x80, 1])
    }

    @Test func registerIsIdempotentAndRefusesAnotherPublicKey() async throws {
        try await TestDatabase.withMigratedSchema { (database: Database) async throws in
            let store = AppAttestKeyRecordStore(database)
            #expect(try await store.register(Self.sample(1), at: Self.time))
            #expect(try await store.key(Self.sample(1).keyID) == Self.sample(1))
            #expect(try await store.advance(Self.sample(1).keyID, to: 4, at: Self.time))
            #expect(try await store.register(Self.sample(1), at: Self.time))
            #expect(try await store.key(Self.sample(1).keyID)?.counter == 4)
            #expect(try await store.register(Self.sample(1, publicKey: [4, 9]), at: Self.time) == false)
            #expect(try await store.key(Self.sample(1).keyID)?.publicKey == [4, 1, 2])
            #expect(try await store.key(Self.sample(2).keyID) == nil)
        }
    }

    @Test func advanceIsACompareAndSet() async throws {
        try await TestDatabase.withMigratedSchema { database in
            let store = AppAttestKeyRecordStore(database)
            let id = Self.sample(1).keyID
            #expect(try await store.advance(id, to: 1, at: Self.time) == false)
            _ = try await store.register(Self.sample(1), at: Self.time)
            #expect(try await store.advance(id, to: 1, at: Self.time))
            #expect(try await store.advance(id, to: 1, at: Self.time) == false)
            #expect(try await store.advance(id, to: 5, at: Self.time))
            #expect(try await store.advance(id, to: 3, at: Self.time) == false)
            #expect(try await store.advance(id, to: UInt32.max, at: Self.time))
            #expect(try await store.key(id)?.counter == UInt32.max)
        }
    }

    @Test func eightConcurrentAdvancesWinOncePerCounter() async throws {
        try await TestDatabase.withMigratedSchema { database in
            let store = AppAttestKeyRecordStore(database)
            let id = Self.sample(1).keyID
            _ = try await store.register(Self.sample(1), at: Self.time)
            for counter: UInt32 in 1...10 {
                let wins = try await withThrowingTaskGroup(of: Bool.self) { group in
                    for _ in 0..<8 { group.addTask { try await store.advance(id, to: counter, at: Self.time) } }
                    return try await group.reduce(0) { $0 + ($1 ? 1 : 0) }
                }
                #expect(wins == 1)
            }
        }
    }

    @Test func purgeDropsKeysUnusedSinceTheCutoff() async throws {
        try await TestDatabase.withMigratedSchema { database in
            let store = AppAttestKeyRecordStore(database)
            _ = try await store.register(Self.sample(1), at: Self.time)
            _ = try await store.register(Self.sample(2), at: Self.time)
            _ = try await store.advance(Self.sample(2).keyID, to: 1, at: Self.time + 100)
            #expect(try await store.purge(unusedSince: Self.time + 50) == 1)
            #expect(try await store.key(Self.sample(1).keyID) == nil)
            #expect(try await store.key(Self.sample(2).keyID) != nil)
        }
    }
}
