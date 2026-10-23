import AppAttest
import Foundation
import RegattaProtocol
import Synchronization

// App Attest on a service connection (#158, ADR 0014). `Hello.attestation` carries the proof: a new key's attestation
// (verified, then registered) or an attested key's assertion (verified, then its counter advanced by the store's
// compare-and-set, the replay defence). The proof's client data binds the player the session call then names. A
// connection that isn't attested keeps its profile, terms and deletion; the queue, the lobby and race sessions are
// closed to it (the gate). A failure is this connection's only: nothing is written about the player.

/// What a connection's `Hello.attestation` came to.
public enum AttestationState: Equatable, Sendable {
    /// Verified: the binding the device signed.
    case verified(binding: [UInt8])
    /// The dev bypass let a connection with no proof through.
    case bypassed
    case unattested(UnattestedReason)

    public var status: AttestationStatus {
        switch self {
        case .verified: .verified
        case .bypassed: .bypassed
        case .unattested(.keyUnknown): .keyUnknown
        case .unattested: .failed
        }
    }
}

public enum UnattestedReason: Equatable, Sendable, CustomStringConvertible {
    /// No proof (schema 0), with the bypass off.
    case none
    /// The device can't attest (the simulator), with the bypass off.
    case unsupported
    /// The device said Apple's attestation service didn't answer.
    case unavailable
    /// An assertion under a key the server doesn't know.
    case keyUnknown
    case failed(AppAttestError)
    /// Bytes that aren't schema 1, or a proof for another purpose.
    case malformed
    /// The key store couldn't be read or written.
    case storeUnavailable
    /// A session call named a player the proof doesn't bind.
    case bindingMismatch
    /// An attestation for a key the server already registered.
    case attestationReplayed

    public var description: String {
        switch self {
        case .none: "no proof"
        case .unsupported: "App Attest unsupported on the device"
        case .unavailable: "Apple's attestation service unavailable to the device"
        case .keyUnknown: "assertion under an unknown key"
        case .failed(let error): "\(error)"
        case .malformed: "malformed proof"
        case .storeUnavailable: "key store unavailable"
        case .bindingMismatch: "the session call's player isn't the one the proof binds"
        case .attestationReplayed: "attestation of a key already registered"
        }
    }
}

/// Checks each connection's proof against the verifier and the key store.
public struct ConnectionAttestation: Sendable {
    public let verifier: AppAttestVerifier
    public let keys: any AppAttestKeyStore
    /// `APP_ATTEST_BYPASS` (dev only): no proof, or `unsupported`, counts as attested; a real proof is still verified.
    public let bypass: Bool
    /// How long the service endpoint lets `check` take before it answers `storeUnavailable`.
    public let checkDeadline: Duration
    let now: @Sendable () -> Date
    private let log: UnattestedLog

    public init(verifier: AppAttestVerifier, keys: any AppAttestKeyStore, bypass: Bool, checkDeadline: Duration = .seconds(5),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.verifier = verifier
        self.keys = keys
        self.bypass = bypass
        self.checkDeadline = checkDeadline
        self.now = now
        log = UnattestedLog()
    }

    /// The server's: Apple's root (or the settings' test root), its App ID, its environments.
    public init(settings: AppAttestSettings, teamID: String, bundleID: String, keys: any AppAttestKeyStore,
                now: @escaping @Sendable () -> Date = { Date() }) {
        let config = AppAttestConfig(teamID: teamID, bundleID: bundleID, environments: settings.environments, trustedRoots: settings.trustedRoots)
        self.init(verifier: AppAttestVerifier(config: config, now: now), keys: keys, bypass: settings.bypass,
                  checkDeadline: settings.checkDeadline, now: now)
    }

    /// A dev server's: the bypass on, keys in memory. Never outside dev: `validate` refuses it there.
    public static func devDefault() -> ConnectionAttestation {
        var settings = AppAttestSettings()
        settings.bypass = true
        return ConnectionAttestation(settings: settings, teamID: IdentitySettings().teamID, bundleID: IdentitySettings().bundleID,
                                     keys: InMemoryAppAttestKeyStore())
    }

    /// Refuses to serve `environment` with the bypass on outside dev, or with keys other than production's in
    /// production (`AppAttestSettings.validate`).
    public func validate(for environment: ServerEnvironment) throws(ServerConfigError) {
        try AppAttestSettings.validate(bypass: bypass, environments: verifier.config.environments, for: environment)
    }

    public func check(_ payload: VersionedPayload, purpose: AttestationClientData.Purpose) async -> AttestationState {
        let state = await evaluate(payload, purpose: purpose)
        if case .unattested(let reason) = state { logUnattested(reason) }
        return state
    }

    /// One stderr line per reason a minute at most, never the key id (Fable's T6): a pre-sign-in Hello is anyone's to
    /// send, so a flood of bad proofs mustn't become a flood of lines.
    public func logUnattested(_ reason: UnattestedReason) {
        guard let suppressed = log.admit(reason.logKey) else { return }
        let more = suppressed > 0 ? " (\(suppressed) more like it in the last minute)" : ""
        Self.log("unattested connection: \(reason)\(more)")
    }

    private func evaluate(_ payload: VersionedPayload, purpose: AttestationClientData.Purpose) async -> AttestationState {
        if payload.schema == 0 { return bypass ? .bypassed : .unattested(.none) }
        let proof: AttestationProof
        do { proof = try AttestationProof(payload: payload) } catch { return .unattested(.malformed) }
        switch proof {
        case .unsupported: return bypass ? .bypassed : .unattested(.unsupported)
        case .unavailable: return .unattested(.unavailable)
        case .attestation(let keyID, let object, let clientData):
            guard clientData.purpose == purpose else { return .unattested(.malformed) }
            do {
                let key = try await verifier.verifyAttestation(object, keyID: keyID, clientDataHash: clientData.hash)
                // An attestation is a key's first use, once: the store's insert-only register is the one check, so of
                // concurrent copies of one attestation exactly one is verified; a known key's again is a replay.
                guard try await keys.register(key, at: now()) else { return .unattested(.attestationReplayed) }
                return .verified(binding: clientData.binding)
            } catch let error as AppAttestError {
                return .unattested(.failed(error))
            } catch {
                return .unattested(.storeUnavailable)
            }
        case .assertion(let keyID, let assertion, let clientData):
            guard clientData.purpose == purpose else { return .unattested(.malformed) }
            do {
                guard let key = try await keys.key(keyID) else { return .unattested(.keyUnknown) }
                let counter = try verifier.verifyAssertion(assertion, clientDataHash: clientData.hash, key: key)
                guard try await keys.advance(keyID, to: counter, at: now()) else { return .unattested(.failed(.counterNotIncreased)) }
                return .verified(binding: clientData.binding)
            } catch let error as AppAttestError {
                return .unattested(.failed(error))
            } catch {
                return .unattested(.storeUnavailable)
            }
        }
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("RegattaServer: app attest: \(message)\n".utf8))
    }
}

extension UnattestedReason {
    /// The reason without its detail (an untrusted chain's failures): what the log's limit counts by.
    var logKey: String { String(description.prefix { $0 != "(" }) }
}

/// Which unattested reasons may be logged now: each at most once an `interval`, with a count of those held back.
final class UnattestedLog: Sendable {
    private struct Entry {
        var last: ContinuousClock.Instant
        var suppressed: Int
    }

    private let interval: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private let entries = Mutex<[String: Entry]>([:])

    init(interval: Duration = .seconds(60), now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.interval = interval
        self.now = now
    }

    /// Nil: held back. Otherwise log it, saying how many were held back since its last line.
    func admit(_ key: String) -> Int? {
        let time = now()
        return entries.withLock { entries in
            if var entry = entries[key], time - entry.last < interval {
                entry.suppressed += 1
                entries[key] = entry
                return nil
            }
            let suppressed = entries[key]?.suppressed ?? 0
            entries[key] = Entry(last: time, suppressed: 0)
            return suppressed
        }
    }
}
