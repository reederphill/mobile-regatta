import SwiftASN1
import X509

// The two CBOR shapes App Attest hands the app (#158), and the authenticator data inside both.

/// WebAuthn authenticator data as App Attest writes it: `rpIdHash` (32) | `flags` (1) | `signCount` (4, big-endian),
/// then, in an attestation, `aaguid` (16) | `credentialIdLength` (2, big-endian) | `credentialId` | the COSE key (not
/// read: the key comes from the credential certificate). An assertion's is the first 37 bytes only. Which one is read
/// is the caller's, not the flags': App Attest sets the attested-credential flag in assertions too (the public vector).
public struct AuthenticatorData: Equatable, Sendable {
    public static let assertionLength = 37

    public var rpIDHash: [UInt8]
    public var flags: UInt8
    public var signCount: UInt32
    /// Nil in an assertion.
    public var aaguid: [UInt8]?
    public var credentialID: [UInt8]?

    /// `attested`: an attestation's, with credential data; otherwise an assertion's, exactly 37 bytes.
    public init(_ bytes: [UInt8], attested: Bool) throws(AppAttestError) {
        guard bytes.count >= Self.assertionLength else { throw .malformed("authenticator data") }
        rpIDHash = Array(bytes[0..<32])
        flags = bytes[32]
        signCount = bytes[33..<37].reduce(0) { $0 << 8 | UInt32($1) }
        guard attested else {
            guard bytes.count == Self.assertionLength else { throw .malformed("authenticator data") }
            aaguid = nil
            credentialID = nil
            return
        }
        guard bytes.count >= 37 + 16 + 2 else { throw .malformed("authenticator data") }
        aaguid = Array(bytes[37..<53])
        let idLength = Int(bytes[53]) << 8 | Int(bytes[54])
        guard bytes.count >= 55 + idLength else { throw .malformed("credential id") }
        credentialID = Array(bytes[55..<(55 + idLength)])
    }
}

/// The attestation object: `{fmt: "apple-appattest", attStmt: {x5c: [credCert, intermediate…], receipt}, authData}`.
public struct AttestationObject: Sendable {
    public static let format = "apple-appattest"
    /// The credential certificate's extension holding the nonce: `SEQUENCE { [1] EXPLICIT OCTET STRING }`.
    public static let nonceExtensionOID: ASN1ObjectIdentifier = [1, 2, 840, 113635, 100, 8, 2]

    /// DER certificates, the credential certificate first.
    public var x5c: [[UInt8]]
    public var receipt: [UInt8]
    public var authData: [UInt8]

    public init(cbor bytes: [UInt8]) throws(AppAttestError) {
        let root: CBOR
        do { root = try CBORDecoder.decode(bytes) } catch { throw .malformed("cbor: \(error)") }
        guard let format = root["fmt"]?.textString else { throw .malformed("fmt") }
        guard format == Self.format else { throw .wrongFormat }
        guard let statement = root["attStmt"], let chain = statement["x5c"]?.arrayItems, chain.count >= 2 else {
            throw .malformed("x5c")
        }
        var certificates: [[UInt8]] = []
        for item in chain {
            guard let der = item.byteString else { throw .malformed("x5c") }
            certificates.append(der)
        }
        guard let receipt = statement["receipt"]?.byteString else { throw .malformed("receipt") }
        guard let authData = root["authData"]?.byteString else { throw .malformed("authData") }
        x5c = certificates
        self.receipt = receipt
        self.authData = authData
    }

    /// The nonce the credential certificate carries. Missing, doubled or misshapen → refused.
    static func nonce(in certificate: Certificate) throws(AppAttestError) -> [UInt8] {
        let matches = certificate.extensions.filter { $0.oid == nonceExtensionOID }
        guard matches.count == 1, let ext = matches.first else { throw .malformed("nonce extension") }
        do {
            let node = try DER.parse(ext.value)
            return try DER.sequence(node, identifier: .sequence) { nodes in
                try DER.explicitlyTagged(&nodes, tagNumber: 1, tagClass: .contextSpecific) { node in
                    Array(try ASN1OctetString(derEncoded: node).bytes)
                }
            }
        } catch {
            throw .malformed("nonce extension")
        }
    }
}

/// An assertion: `{signature: DER ECDSA signature, authenticatorData}`.
public struct AssertionObject: Sendable {
    public var signature: [UInt8]
    public var authenticatorData: [UInt8]

    public init(cbor bytes: [UInt8]) throws(AppAttestError) {
        let root: CBOR
        do { root = try CBORDecoder.decode(bytes) } catch { throw .malformed("cbor: \(error)") }
        guard let signature = root["signature"]?.byteString else { throw .malformed("signature") }
        guard let authenticatorData = root["authenticatorData"]?.byteString else { throw .malformed("authenticatorData") }
        self.signature = signature
        self.authenticatorData = authenticatorData
    }
}
