import RegattaProtocol
import RegattaServices
import Synchronization

// App Attest on the client (#158, ADR 0014). The device makes one key, attests it once with Apple (`attestKey`, which
// talks to Apple: before the socket opens), and asserts with it on every later connection (`generateAssertion`, local to
// the Secure Enclave: after the socket opens, just before `Hello`). The proof's client data binds the player the
// session call names. No DeviceCheck, Foundation or randomness here: the app wraps `DCAppAttestService` (and its base64
// key ids) and supplies the nonces; tests pass a fake.

public enum AppAttestorError: Error, Equatable, Sendable {
    /// App Attest isn't supported on this device.
    case unsupported
    /// Apple's attestation service didn't answer. The key is kept for the next try.
    case serverUnavailable
    /// The key is unusable (unknown to the Secure Enclave, or already attested): make a new one.
    case invalidKey
    case other
}

/// `DCAppAttestService`'s shape. Key ids are its base64 strings' bytes: SHA256 of the public key, 32 bytes.
public protocol AppAttestor: Sendable {
    var isSupported: Bool { get }
    func generateKey() async throws(AppAttestorError) -> [UInt8]
    func attestKey(_ keyID: [UInt8], clientDataHash: [UInt8]) async throws(AppAttestorError) -> [UInt8]
    func generateAssertion(_ keyID: [UInt8], clientDataHash: [UInt8]) async throws(AppAttestorError) -> [UInt8]
}

/// The key the device attests with, and whether the server has acknowledged its attestation. The attestation object
/// itself is never kept: it lives in memory until acknowledged.
public struct AttestationKeyRecord: Equatable, Sendable, Codable {
    public var keyID: [UInt8]
    public var attested: Bool

    public init(keyID: [UInt8], attested: Bool) {
        self.keyID = keyID
        self.attested = attested
    }
}

/// Where the key id is kept between launches: the Keychain in the app.
public protocol AttestationKeyStore: Sendable {
    func load() -> AttestationKeyRecord?
    func save(_ record: AttestationKeyRecord?)
}

public final class InMemoryAttestationKeyStore: AttestationKeyStore {
    private let record: Mutex<AttestationKeyRecord?>

    public init(_ record: AttestationKeyRecord? = nil) { self.record = Mutex(record) }

    public func load() -> AttestationKeyRecord? { record.withLock { $0 } }
    public func save(_ record: AttestationKeyRecord?) { self.record.withLock { $0 = record } }
}

/// The key's life over a device's connections: `prepare` before connecting, `proof` after the socket opens, `noteAck`
/// with the server's answer.
public actor ConnectionAttester {
    /// What `noteAck` asks of the session.
    public enum AckAction: Equatable, Sendable {
        case proceed
        /// The assertion failed (most likely a counter overtaken by another connection): reconnect once with a fresh one.
        case retry
    }

    private enum Sent { case attestation, assertion, other }

    private let attestor: any AppAttestor
    private let store: any AttestationKeyStore
    private let nonce: @Sendable () -> [UInt8]
    private var record: AttestationKeyRecord?
    /// A new key's attestation, waiting to be sent and acknowledged. Memory only (ADR 0014).
    private var pending: (object: [UInt8], clientData: AttestationClientData)?
    private var unavailable = false
    private var sent = Sent.other
    private var retried = false

    /// `nonce` makes each proof's 16 bytes: random in the app.
    public init(attestor: any AppAttestor, store: any AttestationKeyStore, nonce: @escaping @Sendable () -> [UInt8]) {
        self.attestor = attestor
        self.store = store
        self.nonce = nonce
        record = store.load()
    }

    /// Whether the last proof said Apple was unavailable: a queue refused for attestation then is worth a reconnect later.
    public var lastProofWasUnavailable: Bool { unavailable }

    /// Before connecting: the first time (or after the server lost the key, or the key went bad) makes a key and its
    /// attestation, which talks to Apple and may be slow. Apple unavailable keeps the key for the next try.
    public func prepare(for player: GameCenterPlayer) async {
        guard attestor.isSupported, pending == nil, record?.attested != true else { return }
        unavailable = false
        for _ in 0..<2 {
            do {
                let keyID: [UInt8]
                if let known = record?.keyID {
                    keyID = known
                } else {
                    keyID = try await attestor.generateKey()
                    setRecord(AttestationKeyRecord(keyID: keyID, attested: false))
                }
                let clientData = clientData(for: player)
                pending = (try await attestor.attestKey(keyID, clientDataHash: clientData.hash), clientData)
                return
            } catch .serverUnavailable {
                unavailable = true
                return
            } catch .invalidKey {
                setRecord(nil) // a new key on the next pass
            } catch {
                unavailable = true
                return
            }
        }
    }

    /// After the socket opens, just before `Hello`: what `Hello.attestation` carries.
    public func proof(for player: GameCenterPlayer) async -> VersionedPayload {
        sent = .other
        guard attestor.isSupported else { return Self.payload(.unsupported) }
        if let pending, let record {
            sent = .attestation
            return Self.payload(.attestation(keyID: record.keyID, object: pending.object, clientData: pending.clientData))
        }
        guard let record, record.attested else { return Self.payload(.unavailable) }
        let clientData = clientData(for: player)
        do {
            let assertion = try await attestor.generateAssertion(record.keyID, clientDataHash: clientData.hash)
            sent = .assertion
            return Self.payload(.assertion(keyID: record.keyID, assertion: assertion, clientData: clientData))
        } catch .invalidKey {
            setRecord(nil)
        } catch {}
        return Self.payload(.unavailable)
    }

    /// The server's answer to the proof `proof` made.
    public func noteAck(_ status: AttestationStatus) -> AckAction {
        defer { sent = .other }
        switch (status, sent) {
        case (.verified, .attestation):
            pending = nil
            if let keyID = record?.keyID { setRecord(AttestationKeyRecord(keyID: keyID, attested: true)) }
        case (.verified, _):
            retried = false
        case (.keyUnknown, _):
            // The server lost or never had the key: a new key, attested on the next connection.
            dropKey()
        case (.failed, .attestation):
            // `attestKey` is one-shot: an attestation the server didn't take is never sent again.
            dropKey()
        case (.failed, .assertion):
            guard !retried else { return .proceed }
            retried = true
            return .retry
        default:
            break
        }
        return .proceed
    }

    /// Forgets the key and any attestation waiting: the next `prepare` makes a new key. (A connection that carried the
    /// waiting attestation but ended before its answer leaves it waiting: the next one carries it again, and if the
    /// server had registered it, its refusal of a known key lands here.)
    private func dropKey() {
        pending = nil
        retried = false
        setRecord(nil)
    }

    private func setRecord(_ record: AttestationKeyRecord?) {
        self.record = record
        store.save(record)
    }

    private func clientData(for player: GameCenterPlayer) -> AttestationClientData {
        AttestationClientData(purpose: .service, nonce: nonce(), binding: player.wire.attestationBinding)
    }

    private static func payload(_ proof: AttestationProof) -> VersionedPayload { (try? proof.payload()) ?? .none }
}
