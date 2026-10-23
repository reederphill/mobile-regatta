import AppAttest
import Crypto
import Foundation
import SwiftASN1
import X509

/// A test-only CBOR encoder: definite lengths, the shortest head, map pairs in the order given (as Apple writes them).
enum TestCBOR {
    indirect enum Item {
        case unsigned(UInt64)
        case bytes([UInt8])
        case text(String)
        case array([Item])
        case map([(String, Item)])
    }

    static func head(_ major: UInt8, _ n: UInt64) -> [UInt8] {
        let m = major << 5
        switch n {
        case 0...23: return [m | UInt8(n)]
        case 24...0xFF: return [m | 24, UInt8(n)]
        case 0x100...0xFFFF: return [m | 25, UInt8(n >> 8), UInt8(n & 0xFF)]
        case 0x1_0000...0xFFFF_FFFF: return [m | 26] + (0..<4).reversed().map { UInt8(truncatingIfNeeded: n >> (8 * UInt64($0))) }
        default: return [m | 27] + (0..<8).reversed().map { UInt8(truncatingIfNeeded: n >> (8 * UInt64($0))) }
        }
    }

    static func encode(_ item: Item) -> [UInt8] {
        switch item {
        case .unsigned(let v): head(0, v)
        case .bytes(let b): head(2, UInt64(b.count)) + b
        case .text(let t): head(3, UInt64(t.utf8.count)) + Array(t.utf8)
        case .array(let items): head(4, UInt64(items.count)) + items.flatMap(encode)
        case .map(let pairs): head(5, UInt64(pairs.count)) + pairs.flatMap { encode(.text($0.0)) + encode($0.1) }
        }
    }
}

/// A chain made at test time standing in for Apple's: root → intermediate → credential certificate, the last carrying
/// the nonce extension Apple writes. The clock is pinned.
struct TestAttestCA: Sendable {
    /// 2026-10-08T12:00:00Z.
    static let now = Date(timeIntervalSince1970: 1_791_460_800)
    static let teamID = "TEAM123456"
    static let bundleID = "com.phillreeder.regatta"
    static var appID: String { "\(teamID).\(bundleID)" }

    let root: Certificate
    let intermediate: Certificate
    let intermediateKey: P256.Signing.PrivateKey

    init() throws {
        let rootKey = P256.Signing.PrivateKey()
        intermediateKey = P256.Signing.PrivateKey()
        let rootName = try DistinguishedName { CommonName("Test App Attestation Root CA") }
        let intermediateName = try DistinguishedName { CommonName("Test App Attestation CA 1") }
        let validity = Self.now.addingTimeInterval(-86_400 * 365)...Self.now.addingTimeInterval(86_400 * 365)
        root = try Certificate(
            version: .v3, serialNumber: Certificate.SerialNumber(), publicKey: Certificate.PrivateKey(rootKey).publicKey,
            notValidBefore: validity.lowerBound, notValidAfter: validity.upperBound,
            issuer: rootName, subject: rootName, signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: nil))
                Critical(KeyUsage(keyCertSign: true))
            },
            issuerPrivateKey: Certificate.PrivateKey(rootKey))
        intermediate = try Certificate(
            version: .v3, serialNumber: Certificate.SerialNumber(), publicKey: Certificate.PrivateKey(intermediateKey).publicKey,
            notValidBefore: validity.lowerBound, notValidAfter: validity.upperBound,
            issuer: rootName, subject: intermediateName, signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
                Critical(KeyUsage(keyCertSign: true))
            },
            issuerPrivateKey: Certificate.PrivateKey(rootKey))
    }

    func config(environments: Set<AppAttestEnvironment> = [.development, .production], appID: String = Self.appID) -> AppAttestConfig {
        AppAttestConfig(appID: appID, environments: environments, trustedRoots: [root])
    }

    func verifier(environments: Set<AppAttestEnvironment> = [.development, .production], now: Date = Self.now) -> AppAttestVerifier {
        AppAttestVerifier(config: config(environments: environments), now: { now })
    }

    static func nonceExtension(_ nonce: [UInt8]) throws -> Certificate.Extension {
        var serializer = DER.Serializer()
        try serializer.appendConstructedNode(identifier: .sequence) { s in
            try s.appendConstructedNode(identifier: ASN1Identifier(tagWithNumber: 1, tagClass: .contextSpecific)) { s in
                try s.serialize(ASN1OctetString(contentBytes: ArraySlice(nonce)))
            }
        }
        return Certificate.Extension(oid: AttestationObject.nonceExtensionOID, critical: false, value: ArraySlice(serializer.serializedBytes))
    }

    /// A credential certificate for `key`, with `nonces` as its nonce extensions (none, one or two).
    func credentialCertificate(for key: P256.Signing.PublicKey, nonces: [[UInt8]], validity: ClosedRange<Date>? = nil) throws -> [UInt8] {
        let validity = validity ?? Self.now.addingTimeInterval(-3600)...Self.now.addingTimeInterval(86_400 * 3)
        var extensions = Certificate.Extensions()
        try extensions.append(Critical(KeyUsage(digitalSignature: true)).makeCertificateExtension())
        // swift-certificates refuses a repeated extension, so a second nonce goes in under a stand-in OID of the same
        // length (…8.9) and is patched to the nonce's (…8.2) in the DER: the certificate Apple would never send.
        for (k, nonce) in nonces.enumerated() {
            var ext = try Self.nonceExtension(nonce)
            if k > 0 { ext = Certificate.Extension(oid: Self.standInOID, critical: false, value: ext.value) }
            try extensions.append(ext)
        }
        let leaf = try Certificate(
            version: .v3, serialNumber: Certificate.SerialNumber(), publicKey: Certificate.PublicKey(key),
            notValidBefore: validity.lowerBound, notValidAfter: validity.upperBound,
            issuer: intermediate.subject, subject: try DistinguishedName { CommonName("test-credential") },
            signatureAlgorithm: .ecdsaWithSHA256, extensions: extensions,
            issuerPrivateKey: Certificate.PrivateKey(intermediateKey))
        var der = Self.der(leaf)
        if nonces.count > 1 {
            let standIn: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x63, 0x64, 0x08, 0x09]
            for start in 0...(der.count - standIn.count) where Array(der[start..<(start + standIn.count)]) == standIn {
                der[start + standIn.count - 1] = 0x02
            }
        }
        return der
    }

    static let standInOID: ASN1ObjectIdentifier = [1, 2, 840, 113635, 100, 8, 9]

    static func der(_ certificate: Certificate) -> [UInt8] {
        var serializer = DER.Serializer()
        try! serializer.serialize(certificate)
        return serializer.serializedBytes
    }
}

/// A device's App Attest key, signing as the Secure Enclave does: an attestation over a client data hash, then
/// assertions with a counter. Each knob is a way a real attestation could be wrong.
struct TestDevice: Sendable {
    let key = P256.Signing.PrivateKey()
    var keyID: [UInt8] { Array(SHA256.hash(data: Array(key.publicKey.x963Representation))) }

    struct Attestation {
        var appID = TestAttestCA.appID
        var environment: AppAttestEnvironment = .development
        var counter: UInt32 = 0
        var format = "apple-appattest"
        /// The credential id; the key id by default.
        var credentialID: [UInt8]?
        /// The certificate's public key; the device's by default.
        var certifiedKey: P256.Signing.PublicKey?
        /// Overrides the nonce the certificate carries; `nonceCount` 0 or 2 drops or doubles the extension.
        var nonce: [UInt8]?
        var nonceCount = 1
        var validity: ClosedRange<Date>?
        /// The certificates after the credential certificate in x5c; the CA's intermediate by default.
        var chainTail: [[UInt8]]?
    }

    static func authData(appID: String, counter: UInt32, credential: (aaguid: [UInt8], id: [UInt8], key: P256.Signing.PublicKey)?) -> [UInt8] {
        var bytes = Array(SHA256.hash(data: Array(appID.utf8)))
        bytes.append(0x40) // App Attest sets the attested-credential flag in assertions too
        bytes += (0..<4).reversed().map { UInt8(truncatingIfNeeded: counter >> (8 * UInt32($0))) }
        if let credential {
            bytes += credential.aaguid
            bytes += [UInt8(credential.id.count >> 8), UInt8(credential.id.count & 0xFF)]
            bytes += credential.id
            // A COSE EC2 key; the verifier doesn't read it (the key comes from the certificate).
            let raw = Array(credential.key.x963Representation)
            bytes += [0xA5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x21, 0x58, 0x20] + raw[1..<33] + [0x22, 0x58, 0x20] + raw[33..<65]
        }
        return bytes
    }

    func attestation(_ ca: TestAttestCA, clientDataHash: [UInt8], _ knobs: Attestation = Attestation()) throws -> [UInt8] {
        let authData = Self.authData(appID: knobs.appID, counter: knobs.counter,
                                     credential: (knobs.environment.aaguid, knobs.credentialID ?? keyID, key.publicKey))
        let nonce = knobs.nonce ?? Array(SHA256.hash(data: authData + clientDataHash))
        let leaf = try ca.credentialCertificate(for: knobs.certifiedKey ?? key.publicKey,
                                                nonces: Array(repeating: nonce, count: knobs.nonceCount), validity: knobs.validity)
        return TestCBOR.encode(.map([
            ("fmt", .text(knobs.format)),
            ("attStmt", .map([("x5c", .array(([leaf] + (knobs.chainTail ?? [TestAttestCA.der(ca.intermediate)])).map { .bytes($0) })),
                              ("receipt", .bytes([0x30, 0x80, 1, 2, 3]))])),
            ("authData", .bytes(authData)),
        ]))
    }

    /// An assertion with `counter`, signed by `signer` (the device's key by default).
    func assertion(clientDataHash: [UInt8], counter: UInt32, appID: String = TestAttestCA.appID,
                   signer: P256.Signing.PrivateKey? = nil) throws -> [UInt8] {
        let authData = Self.authData(appID: appID, counter: counter, credential: nil)
        let nonce = Array(SHA256.hash(data: authData + clientDataHash))
        let signature = try (signer ?? key).signature(for: nonce)
        return TestCBOR.encode(.map([("signature", .bytes(Array(signature.derRepresentation))), ("authenticatorData", .bytes(authData))]))
    }
}
