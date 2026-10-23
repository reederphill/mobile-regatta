import Foundation
import RegattaProtocol
import RegattaServiceClient
import RegattaServices
import Synchronization
import Testing

/// `DCAppAttestService` as a script (#158): counts every call, and fails the next ones as told.
final class FakeAppAttestor: AppAttestor {
    struct State {
        var generated = 0
        var attested = 0
        var asserted = 0
        var attestFailures: [AppAttestorError] = []
        var assertFailures: [AppAttestorError] = []
        var keys: [[UInt8]] = []
        /// The key ids `attestKey` was called with, in order.
        var attestedKeys: [[UInt8]] = []
    }

    let isSupported: Bool
    let state = Mutex(State())

    init(isSupported: Bool = true) { self.isSupported = isSupported }

    var generated: Int { state.withLock { $0.generated } }
    var attested: Int { state.withLock { $0.attested } }
    var asserted: Int { state.withLock { $0.asserted } }

    func generateKey() async throws(AppAttestorError) -> [UInt8] {
        state.withLock { state in
            state.generated += 1
            let key = (0..<32).map { UInt8(state.generated) &+ UInt8($0) }
            state.keys.append(key)
            return key
        }
    }

    func attestKey(_ keyID: [UInt8], clientDataHash: [UInt8]) async throws(AppAttestorError) -> [UInt8] {
        let failure: AppAttestorError? = state.withLock { state in
            state.attested += 1
            state.attestedKeys.append(keyID)
            return state.attestFailures.isEmpty ? nil : state.attestFailures.removeFirst()
        }
        if let failure { throw failure }
        return [0xA3] + clientDataHash
    }

    func generateAssertion(_ keyID: [UInt8], clientDataHash: [UInt8]) async throws(AppAttestorError) -> [UInt8] {
        let failure: AppAttestorError? = state.withLock { state in
            state.asserted += 1
            return state.assertFailures.isEmpty ? nil : state.assertFailures.removeFirst()
        }
        if let failure { throw failure }
        return [0xA2] + clientDataHash
    }
}

/// Distinct nonces, deterministically.
enum Nonces {
    private static let count = Mutex<UInt8>(0)
    static let next: @Sendable () -> [UInt8] = { count.withLock { n in n &+= 1; return Array(repeating: n, count: 16) } }
}

/// The client's six fake cases (#158): the key's life over connections, against `FakeAppAttestor`.
@Suite struct ConnectionAttesterTests {
    static let player = GameCenterPlayer(gamePlayerID: GamePlayerID("G:wren"), alias: "Wren")

    /// One connection: prepare, the proof, the server's answer. Returns the proof sent.
    @discardableResult
    static func connect(_ attester: ConnectionAttester, answer: AttestationStatus = .verified) async throws
        -> (proof: AttestationProof, action: ConnectionAttester.AckAction) {
        await attester.prepare(for: player)
        let proof = try AttestationProof(payload: await attester.proof(for: player))
        return (proof, await attester.noteAck(answer))
    }

    static func kind(_ proof: AttestationProof) -> Int {
        switch proof {
        case .attestation: 1
        case .assertion: 2
        case .unsupported: 3
        case .unavailable: 4
        }
    }

    static func keyID(_ proof: AttestationProof) -> [UInt8]? {
        switch proof {
        case .attestation(let keyID, _, _), .assertion(let keyID, _, _): keyID
        default: nil
        }
    }

    @Test func firstConnectionAttestsOnceThenAsserts() async throws {
        let device = FakeAppAttestor(), store = InMemoryAttestationKeyStore()
        let attester = ConnectionAttester(attestor: device, store: store, nonce: Nonces.next)
        let first = try await Self.connect(attester).proof
        #expect(Self.kind(first) == 1 && device.attested == 1 && device.generated == 1)
        guard case .attestation(_, _, let clientData) = first else { return }
        #expect(clientData.binding == Self.player.wire.attestationBinding && clientData.purpose == .service)
        #expect(store.load()?.attested == true)
        var nonces: Set<[UInt8]> = [clientData.nonce]
        for _ in 0..<3 {
            let next = try await Self.connect(attester).proof
            #expect(Self.kind(next) == 2 && Self.keyID(next) == Self.keyID(first))
            if case .assertion(_, _, let data) = next { nonces.insert(data.nonce) }
        }
        #expect(device.attested == 1 && device.asserted == 3 && device.generated == 1)
        #expect(nonces.count == 4)
        // A later launch reads the attested key from the store: assertions straight away.
        let relaunched = ConnectionAttester(attestor: device, store: store, nonce: Nonces.next)
        #expect(Self.kind(try await Self.connect(relaunched).proof) == 2)
        #expect(device.attested == 1)
    }

    @Test func unsupportedSendsKindThreeAndNeverMakesAKey() async throws {
        let device = FakeAppAttestor(isSupported: false)
        let attester = ConnectionAttester(attestor: device, store: InMemoryAttestationKeyStore(), nonce: Nonces.next)
        for _ in 0..<2 { #expect(Self.kind(try await Self.connect(attester, answer: .failed).proof) == 3) }
        #expect(device.generated == 0 && device.attested == 0)
    }

    @Test func serverUnavailableKeepsTheKeyForTheNextConnection() async throws {
        let device = FakeAppAttestor()
        device.state.withLock { $0.attestFailures = [.serverUnavailable] }
        let attester = ConnectionAttester(attestor: device, store: InMemoryAttestationKeyStore(), nonce: Nonces.next)
        #expect(Self.kind(try await Self.connect(attester, answer: .failed).proof) == 4)
        #expect(await attester.lastProofWasUnavailable)
        let next = try await Self.connect(attester).proof
        #expect(Self.kind(next) == 1)
        #expect(device.generated == 1 && device.attested == 2)
        #expect(await !attester.lastProofWasUnavailable)
    }

    @Test func invalidKeyMakesANewKey() async throws {
        let device = FakeAppAttestor()
        device.state.withLock { $0.attestFailures = [.invalidKey] }
        let attester = ConnectionAttester(attestor: device, store: InMemoryAttestationKeyStore(), nonce: Nonces.next)
        let proof = try await Self.connect(attester).proof
        #expect(Self.kind(proof) == 1 && device.generated == 2 && device.attested == 2)
        let keys = device.state.withLock { $0.keys }
        #expect(Self.keyID(proof) == keys.last && Self.keyID(proof) != keys.first)
        // An attested key the Secure Enclave no longer knows: a new key on the next connection.
        device.state.withLock { $0.assertFailures = [.invalidKey] }
        #expect(Self.kind(try await Self.connect(attester, answer: .failed).proof) == 4)
        #expect(Self.kind(try await Self.connect(attester).proof) == 1)
        #expect(device.generated == 3)
    }

    /// The review's finding 6: `attestKey` failing for any reason but Apple being unavailable drops the key (whether
    /// it was used up is unknown); the next connection attests a new one.
    @Test func otherAttestFailureDropsTheKey() async throws {
        let device = FakeAppAttestor()
        device.state.withLock { $0.attestFailures = [.other] }
        let store = InMemoryAttestationKeyStore()
        let attester = ConnectionAttester(attestor: device, store: store, nonce: Nonces.next)
        #expect(Self.kind(try await Self.connect(attester, answer: .failed).proof) == 4)
        #expect(store.load() == nil)
        let next = try await Self.connect(attester).proof
        #expect(Self.kind(next) == 1 && device.generated == 2 && device.attested == 2)
        let attested = device.state.withLock { $0.attestedKeys }
        #expect(attested[0] != attested[1] && Self.keyID(next) == attested[1])
    }

    /// The review's finding 6 (ADR 0014: `attestKey` is one-shot): a key an earlier launch made but whose attestation
    /// the server never acknowledged is replaced, never attested again.
    @Test func notAcknowledgedWithinTheSessionMakesANewKey() async throws {
        let old = Array(repeating: UInt8(9), count: 32)
        let device = FakeAppAttestor()
        let store = InMemoryAttestationKeyStore(AttestationKeyRecord(keyID: old, attested: false))
        let attester = ConnectionAttester(attestor: device, store: store, nonce: Nonces.next)
        let proof = try await Self.connect(attester).proof
        #expect(Self.kind(proof) == 1 && device.generated == 1 && device.attested == 1)
        #expect(Self.keyID(proof) != old && !device.state.withLock { $0.attestedKeys }.contains(old))
        #expect(store.load() == AttestationKeyRecord(keyID: try #require(Self.keyID(proof)), attested: true))

        // Within the session an unanswered attestation is carried again, not re-attested: the connection that carried
        // it ended before its answer.
        let fresh = ConnectionAttester(attestor: FakeAppAttestor(), store: InMemoryAttestationKeyStore(), nonce: Nonces.next)
        await fresh.prepare(for: Self.player)
        let carried = try AttestationProof(payload: await fresh.proof(for: Self.player))
        let again = try await Self.connect(fresh).proof
        #expect(Self.kind(carried) == 1 && Self.kind(again) == 1 && Self.keyID(carried) == Self.keyID(again))

        // A later launch with the record still unacknowledged: a new key again.
        let unacked = InMemoryAttestationKeyStore()
        let first = ConnectionAttester(attestor: device, store: unacked, nonce: Nonces.next)
        await first.prepare(for: Self.player)
        let kept = try #require(unacked.load())
        #expect(!kept.attested)
        let relaunched = ConnectionAttester(attestor: device, store: unacked, nonce: Nonces.next)
        let next = try await Self.connect(relaunched).proof
        #expect(Self.kind(next) == 1 && Self.keyID(next) != kept.keyID)
    }

    /// The record is read on first use, not when the attester is made (before the device's first unlock).
    @Test func storeIsReadLazily() async throws {
        let device = FakeAppAttestor(), store = InMemoryAttestationKeyStore()
        let attester = ConnectionAttester(attestor: device, store: store, nonce: Nonces.next)
        store.save(AttestationKeyRecord(keyID: Array(repeating: 7, count: 32), attested: true))
        let proof = try await Self.connect(attester).proof
        #expect(Self.kind(proof) == 2 && Self.keyID(proof) == Array(repeating: 7, count: 32) && device.generated == 0)
    }

    @Test func keyUnknownMakesANewKeyAndAttestsNext() async throws {
        let device = FakeAppAttestor()
        let attester = ConnectionAttester(attestor: device, store: InMemoryAttestationKeyStore(), nonce: Nonces.next)
        let first = try await Self.connect(attester).proof
        let lost = try await Self.connect(attester, answer: .keyUnknown).proof
        #expect(Self.kind(lost) == 2)
        let next = try await Self.connect(attester).proof
        #expect(Self.kind(next) == 1 && Self.keyID(next) != Self.keyID(first))
        #expect(device.generated == 2 && device.attested == 2)
        // A failed attestation is never sent again either: attestKey is one-shot.
        let refused = try await Self.connect(attester, answer: .failed).proof
        #expect(Self.kind(refused) == 2)
        _ = try await Self.connect(attester, answer: .keyUnknown)
        #expect(Self.kind(try await Self.connect(attester, answer: .failed).proof) == 1)
        #expect(Self.kind(try await Self.connect(attester).proof) == 1)
        #expect(device.generated == 4)
    }

    @Test func failedAssertionRetriesOnceThenStops() async throws {
        let device = FakeAppAttestor()
        let attester = ConnectionAttester(attestor: device, store: InMemoryAttestationKeyStore(), nonce: Nonces.next)
        _ = try await Self.connect(attester)
        let (first, action) = try await Self.connect(attester, answer: .failed)
        #expect(Self.kind(first) == 2 && action == .retry)
        let (retry, again) = try await Self.connect(attester, answer: .failed)
        #expect(Self.kind(retry) == 2 && again == .proceed)
        #expect(device.asserted == 2)
        // A verified connection resets it: the next failure retries again.
        _ = try await Self.connect(attester)
        #expect(try await Self.connect(attester, answer: .failed).action == .retry)
    }
}
