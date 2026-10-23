import RegattaCore

// App Attest in `Hello` (#158, ADR 0014): schema 1 of `Hello.attestation`. The device proves the connection comes from
// the genuine app with an attestation (its key's first use) or an assertion (every later connection); the client data
// it signs binds the proof to the player the session call then names.

/// What the device signs over, encoded: `purpose` u8 | `nonce` 16 bytes | `binding` 32 bytes. The device signs
/// `SHA256(encoded)` (`hash`). The nonce makes every proof's client data unique; the binding is the
/// `WirePlayer.attestationBinding` of the player the connection's session call names, so the restriction flags ride
/// in the asserted request (#145).
public struct AttestationClientData: Equatable, Sendable {
    public enum Purpose: UInt8, Equatable, Sendable, CaseIterable {
        /// The `/service` connection's session.
        case service = 1
    }

    public static let nonceLength = 16
    public static let bindingLength = 32

    public var purpose: Purpose
    public var nonce: [UInt8]
    public var binding: [UInt8]

    public init(purpose: Purpose = .service, nonce: [UInt8], binding: [UInt8]) {
        self.purpose = purpose
        self.nonce = nonce
        self.binding = binding
    }

    /// The exact bytes the hash covers.
    public var encoded: [UInt8] { [purpose.rawValue] + nonce + binding }

    /// `SHA256(encoded)`: App Attest's `clientDataHash`.
    public var hash: [UInt8] { ContentHash(of: .init(encoded)).bytes }

    func encode(to w: inout WireWriter) throws {
        guard nonce.count == Self.nonceLength else { throw WireError.outOfRange("attestation.nonce") }
        guard binding.count == Self.bindingLength else { throw WireError.outOfRange("attestation.binding") }
        w.raw(encoded)
    }

    init(from r: inout WireReader) throws {
        guard let purpose = Purpose(rawValue: try r.u8()) else { throw WireError.invalidValue("attestation.purpose") }
        self.init(purpose: purpose, nonce: try r.raw(Self.nonceLength), binding: try r.raw(Self.bindingLength))
    }
}

/// `Hello.attestation` schema 1: the proof a connection carries (#158). A key id is SHA-256 of the key's public key,
/// 32 bytes.
public enum AttestationProof: Equatable, Sendable {
    /// A new key's attestation: the CBOR attestation object App Attest returned for `clientData.hash`.
    case attestation(keyID: [UInt8], object: [UInt8], clientData: AttestationClientData)
    /// An attested key's assertion: the CBOR assertion App Attest generated for `clientData.hash`.
    case assertion(keyID: [UInt8], assertion: [UInt8], clientData: AttestationClientData)
    /// App Attest isn't supported here (`DCAppAttestService.isSupported` is false: the simulator).
    case unsupported
    /// Apple's attestation service didn't answer; the key is kept for the next try.
    case unavailable

    public static let schema: UInt16 = 1
    public static let keyIDLength = 32

    /// The proof as `Hello.attestation`. Throws for a value the wire can't carry (a key id that isn't 32 bytes, an
    /// object over the payload limit).
    public func payload() throws -> VersionedPayload {
        var w = WireWriter()
        switch self {
        case .attestation(let keyID, let object, let clientData):
            w.u8(1)
            try Self.encodeKeyID(keyID, to: &w)
            try w.blob(object, limit: WireLimit.payload, "attestation.object")
            try clientData.encode(to: &w)
        case .assertion(let keyID, let assertion, let clientData):
            w.u8(2)
            try Self.encodeKeyID(keyID, to: &w)
            try w.blob(assertion, limit: WireLimit.token, "attestation.assertion")
            try clientData.encode(to: &w)
        case .unsupported: w.u8(3)
        case .unavailable: w.u8(4)
        }
        guard w.bytes.count <= WireLimit.payload else { throw WireError.tooLong("attestation") }
        return VersionedPayload(schema: Self.schema, bytes: w.bytes)
    }

    /// Decodes schema 1 strictly: another schema, an unknown kind, a short key id or trailing bytes are refused.
    public init(payload: VersionedPayload) throws {
        guard payload.schema == Self.schema else { throw WireError.invalidValue("attestation.schema") }
        var r = WireReader(payload.bytes)
        switch try r.u8() {
        case 1:
            let keyID = try r.raw(Self.keyIDLength)
            let object = try r.blob(limit: WireLimit.payload, "attestation.object")
            self = .attestation(keyID: keyID, object: object, clientData: try AttestationClientData(from: &r))
        case 2:
            let keyID = try r.raw(Self.keyIDLength)
            let assertion = try r.blob(limit: WireLimit.token, "attestation.assertion")
            self = .assertion(keyID: keyID, assertion: assertion, clientData: try AttestationClientData(from: &r))
        case 3: self = .unsupported
        case 4: self = .unavailable
        default: throw WireError.invalidValue("attestation.kind")
        }
        try r.finish()
    }

    private static func encodeKeyID(_ keyID: [UInt8], to w: inout WireWriter) throws {
        guard keyID.count == keyIDLength else { throw WireError.outOfRange("attestation.keyID") }
        w.raw(keyID)
    }
}

/// What the server made of a connection's `Hello.attestation`, in `HelloAck` (#158). No reason detail beyond these.
public enum AttestationStatus: UInt8, Equatable, Sendable, CaseIterable {
    /// Not checked: a `/race` connection, whose seat rides on a race token.
    case notChecked = 0
    /// The attestation or assertion verified: the connection is attested.
    case verified = 1
    /// The dev bypass accepted a connection with no proof (or `unsupported`).
    case bypassed = 2
    /// The assertion's key isn't one the server knows: drop it, make a new key and attest on the next connection.
    case keyUnknown = 3
    /// The proof didn't verify (or the device said Apple was unavailable): the connection is unattested. One retry
    /// with a fresh assertion covers an out-of-order counter.
    case failed = 4
}

extension WirePlayer {
    /// `SHA256` of the player's wire encoding: the binding a service connection's client data carries, so client and
    /// server hash the same bytes. A player the wire can't carry hashes to nothing (no proof can bind it).
    public var attestationBinding: [UInt8] {
        var w = WireWriter()
        guard (try? encode(to: &w)) != nil else { return [] }
        return ContentHash(of: .init(w.bytes)).bytes
    }
}
