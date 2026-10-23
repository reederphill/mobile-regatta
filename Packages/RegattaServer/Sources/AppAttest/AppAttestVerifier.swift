import Crypto
import Foundation
import SwiftASN1
import X509

// App Attest verification (#158, ADR 0014), Apple's steps in order ("Validating apps that connect to your server"):
//
// attestation, once per key
//   1. the x5c chain verifies to Apple's App Attestation root at the server's now()
//   2. nonce = SHA256(authData ‖ clientDataHash) equals the credential certificate's nonce extension
//   3. the key id equals SHA256 of the credential certificate's public key (uncompressed, 65 bytes)
//   4. the RP ID hash equals SHA256(TeamID.bundleID)
//   5. the counter is 0
//   6. the AAGUID names an environment the server accepts (it follows the app's entitlement)
//   7. the credential id equals the key id
// assertion, every later connection
//   1. nonce = SHA256(authenticatorData ‖ clientDataHash); the DER ECDSA P-256 signature verifies over the nonce
//      (ECDSA-SHA256, so the nonce is hashed again) under the stored key
//   2. the RP ID hash equals SHA256(TeamID.bundleID)
//   3. the counter is above the stored one (the store's compare-and-set makes it stick)
//
// The receipt is kept, not checked: the server needs no Apple service at run time. Pure: no sockets, an injected clock.

public enum AppAttestError: Error, Equatable, Sendable {
    /// Bytes that aren't the shape App Attest writes.
    case malformed(String)
    /// The attestation object's `fmt` isn't `apple-appattest`.
    case wrongFormat
    /// The x5c chain doesn't verify to the trusted root at now (an expired leaf lands here).
    case untrustedChain(String)
    case nonceMismatch
    /// The key id isn't SHA256 of the credential certificate's public key, or isn't the one the client named.
    case keyIDMismatch
    /// The authenticator data's credential id isn't the key id.
    case credentialIDMismatch
    /// The RP ID hash isn't SHA256 of the configured App ID.
    case wrongAppID
    /// The AAGUID names an environment the server doesn't accept.
    case wrongEnvironment
    /// An attestation whose counter isn't 0.
    case nonZeroCounter
    case badSignature
    /// An assertion whose counter isn't above the stored one: a replay, or an out-of-order connection.
    case counterNotIncreased
    /// An assertion under a key the server doesn't know.
    case unknownKey
}

/// The App Attest environment, as the entitlement sets it and the AAGUID says.
public enum AppAttestEnvironment: String, Sendable, CaseIterable, Codable {
    case development
    case production

    /// `appattestdevelop`, or `appattest` and seven zero bytes.
    public var aaguid: [UInt8] {
        switch self {
        case .development: Array("appattestdevelop".utf8)
        case .production: Array("appattest".utf8) + Array(repeating: 0, count: 7)
        }
    }

    public init?(aaguid: [UInt8]) {
        guard let match = Self.allCases.first(where: { $0.aaguid == aaguid }) else { return nil }
        self = match
    }
}

public struct AppAttestConfig: Sendable {
    /// `TeamID.bundleID`.
    public var appID: String
    /// The environments whose keys the server accepts.
    public var environments: Set<AppAttestEnvironment>
    /// The anchors: Apple's App Attestation root, or a test root.
    public var trustedRoots: [Certificate]

    public init(appID: String, environments: Set<AppAttestEnvironment>, trustedRoots: [Certificate] = [AppleAppAttestRoot.certificate]) {
        self.appID = appID
        self.environments = environments
        self.trustedRoots = trustedRoots
    }

    public init(teamID: String, bundleID: String, environments: Set<AppAttestEnvironment>,
                trustedRoots: [Certificate] = [AppleAppAttestRoot.certificate]) {
        self.init(appID: "\(teamID).\(bundleID)", environments: environments, trustedRoots: trustedRoots)
    }

    var rpIDHash: [UInt8] { Array(SHA256.hash(data: Array(appID.utf8))) }
}

/// A key the server knows: what an attestation proved and the last counter an assertion used.
public struct AppAttestKey: Equatable, Sendable {
    public var keyID: [UInt8]
    /// Uncompressed X9.63, 65 bytes.
    public var publicKey: [UInt8]
    public var counter: UInt32
    public var environment: AppAttestEnvironment
    public var receipt: [UInt8]

    public init(keyID: [UInt8], publicKey: [UInt8], counter: UInt32, environment: AppAttestEnvironment, receipt: [UInt8]) {
        self.keyID = keyID
        self.publicKey = publicKey
        self.counter = counter
        self.environment = environment
        self.receipt = receipt
    }
}

public struct AppAttestVerifier: Sendable {
    public let config: AppAttestConfig
    private let now: @Sendable () -> Date

    public init(config: AppAttestConfig, now: @escaping @Sendable () -> Date = { Date() }) {
        self.config = config
        self.now = now
    }

    /// Verifies a new key's attestation over `clientDataHash` and returns the key to store, at counter 0.
    public func verifyAttestation(_ object: [UInt8], keyID: [UInt8], clientDataHash: [UInt8]) async throws(AppAttestError) -> AppAttestKey {
        let attestation = try AttestationObject(cbor: object)
        let certificates: [Certificate]
        do { certificates = try attestation.x5c.map { try Certificate(derEncoded: $0) } } catch { throw .malformed("x5c certificate") }
        let leaf = certificates[0]
        try await validateChain(leaf, intermediates: Array(certificates.dropFirst()))

        let nonce = Array(SHA256.hash(data: attestation.authData + clientDataHash))
        guard try AttestationObject.nonce(in: leaf) == nonce else { throw .nonceMismatch }

        guard let key = P256.Signing.PublicKey(leaf.publicKey) else { throw .malformed("credential key") }
        let publicKey = Array(key.x963Representation)
        guard Array(SHA256.hash(data: publicKey)) == keyID else { throw .keyIDMismatch }

        let authData = try AuthenticatorData(attestation.authData, attested: true)
        guard authData.rpIDHash == config.rpIDHash else { throw .wrongAppID }
        guard authData.signCount == 0 else { throw .nonZeroCounter }
        guard let aaguid = authData.aaguid, let credentialID = authData.credentialID else { throw .malformed("credential data") }
        guard let environment = AppAttestEnvironment(aaguid: aaguid), config.environments.contains(environment) else {
            throw .wrongEnvironment
        }
        guard credentialID == keyID else { throw .credentialIDMismatch }
        return AppAttestKey(keyID: keyID, publicKey: publicKey, counter: 0, environment: environment, receipt: attestation.receipt)
    }

    /// Verifies an assertion over `clientDataHash` under `key` (nil: the server doesn't know it) and returns its
    /// counter, which must be above the stored one. The caller's store makes the new counter stick atomically.
    public func verifyAssertion(_ assertion: [UInt8], clientDataHash: [UInt8], key: AppAttestKey?) throws(AppAttestError) -> UInt32 {
        guard let key else { throw .unknownKey }
        let object = try AssertionObject(cbor: assertion)
        let authData = try AuthenticatorData(object.authenticatorData, attested: false)
        let nonce = Array(SHA256.hash(data: object.authenticatorData + clientDataHash))
        guard let publicKey = try? P256.Signing.PublicKey(x963Representation: key.publicKey) else { throw .malformed("stored key") }
        guard let signature = try? P256.Signing.ECDSASignature(derRepresentation: object.signature) else { throw .badSignature }
        guard publicKey.isValidSignature(signature, for: nonce) else { throw .badSignature }
        guard authData.rpIDHash == config.rpIDHash else { throw .wrongAppID }
        guard authData.signCount > key.counter else { throw .counterNotIncreased }
        return authData.signCount
    }

    private func validateChain(_ leaf: Certificate, intermediates: [Certificate]) async throws(AppAttestError) {
        let time = now()
        var verifier = Verifier(rootCertificates: CertificateStore(config.trustedRoots)) { RFC5280Policy(validationTime: time) }
        switch await verifier.validate(leaf: leaf, intermediates: CertificateStore(intermediates)) {
        case .validCertificate: return
        case .couldNotValidate(let failures):
            throw .untrustedChain(failures.map { "\($0.policyFailureReason)" }.joined(separator: "; "))
        }
    }
}
