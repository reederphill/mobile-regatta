import AppAttest
import Foundation
import RegattaServerKit
import Testing

/// The in-memory key store (#158): Postgres has the same tests in `PersistenceTests`.
@Suite struct AppAttestKeyStoreTests {
    static let time = Date(timeIntervalSince1970: 1_791_460_800)

    static func sample(_ byte: UInt8, publicKey: [UInt8] = [4, 1, 2]) -> AppAttestKey {
        AppAttestKey(keyID: Array(repeating: byte, count: 32), publicKey: publicKey, counter: 0, environment: .production, receipt: [1])
    }

    /// Insert-only (the review's finding 2): only the call that stored the key gets true.
    @Test func registerIsInsertOnlyAndRefusesAnotherPublicKey() async throws {
        let store = InMemoryAppAttestKeyStore()
        #expect(try await store.register(Self.sample(1), at: Self.time))
        #expect(try await store.advance(Self.sample(1).keyID, to: 4, at: Self.time))
        // The same key again is refused and keeps its counter.
        #expect(try await store.register(Self.sample(1), at: Self.time) == false)
        #expect(try await store.key(Self.sample(1).keyID)?.counter == 4)
        #expect(try await store.register(Self.sample(1, publicKey: [4, 9, 9]), at: Self.time) == false)
        #expect(try await store.key(Self.sample(1).keyID)?.publicKey == [4, 1, 2])
        #expect(try await store.key(Self.sample(2).keyID) == nil)
    }

    /// The replayed-counter fixture through the compare-and-set: the same counter twice, and 3 after 5.
    @Test func advanceIsACompareAndSet() async throws {
        let store = InMemoryAppAttestKeyStore()
        let id = Self.sample(1).keyID
        #expect(try await store.advance(id, to: 1, at: Self.time) == false) // unknown key
        _ = try await store.register(Self.sample(1), at: Self.time)
        #expect(try await store.advance(id, to: 1, at: Self.time))
        #expect(try await store.advance(id, to: 1, at: Self.time) == false)
        #expect(try await store.advance(id, to: 5, at: Self.time))
        #expect(try await store.advance(id, to: 3, at: Self.time) == false)
        #expect(try await store.key(id)?.counter == 5)
    }

    @Test func eightConcurrentRegistersOfOneKeyWinOnce() async throws {
        let store = InMemoryAppAttestKeyStore()
        for byte: UInt8 in 1...20 {
            let wins = try await withThrowingTaskGroup(of: Bool.self) { group in
                for _ in 0..<8 { group.addTask { try await store.register(Self.sample(byte), at: Self.time) } }
                return try await group.reduce(0) { $0 + ($1 ? 1 : 0) }
            }
            #expect(wins == 1)
        }
    }

    @Test func eightConcurrentAdvancesWinOncePerCounter() async throws {
        let store = InMemoryAppAttestKeyStore()
        let id = Self.sample(1).keyID
        _ = try await store.register(Self.sample(1), at: Self.time)
        for counter: UInt32 in 1...20 {
            let wins = try await withThrowingTaskGroup(of: Bool.self) { group in
                for _ in 0..<8 { group.addTask { try await store.advance(id, to: counter, at: Self.time) } }
                return try await group.reduce(0) { $0 + ($1 ? 1 : 0) }
            }
            #expect(wins == 1)
        }
    }

    @Test func purgeDropsKeysUnusedSinceTheCutoff() async throws {
        let store = InMemoryAppAttestKeyStore()
        _ = try await store.register(Self.sample(1), at: Self.time)
        _ = try await store.register(Self.sample(2), at: Self.time)
        _ = try await store.advance(Self.sample(2).keyID, to: 1, at: Self.time + 100)
        #expect(try await store.purge(unusedSince: Self.time + 50) == 1)
        #expect(try await store.key(Self.sample(1).keyID) == nil)
        #expect(try await store.key(Self.sample(2).keyID) != nil)
    }

    /// The retention job purges keys unused for as long as an inactive player (730 days).
    @Test func retentionPurgesKeysUnusedFor730Days() async throws {
        let rig = DeletionRig()
        let keys = InMemoryAppAttestKeyStore()
        let retention = RetentionJobs(deletion: rig.deletion, moderation: rig.moderation, lobby: rig.hub, appAttestKeys: keys, now: { rig.clock.now })
        _ = try await keys.register(Self.sample(1), at: rig.clock.now)
        rig.clock.advance(729 * 86_400)
        _ = try await keys.register(Self.sample(2), at: rig.clock.now)
        #expect(await retention.runOnce().appAttestKeys == 0)
        rig.clock.advance(2 * 86_400)
        #expect(await retention.runOnce().appAttestKeys == 1)
        #expect(try await keys.key(Self.sample(2).keyID) != nil)
    }
}
