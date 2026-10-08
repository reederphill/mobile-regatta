import Crypto
import Foundation
import SwiftASN1
import X509
import _CryptoExtras

// Game Center identity verification (#145): the client's `fetchItems(forIdentityVerificationSignature:)` gives a
// public key URL, a signature, a salt and a timestamp; the server fetches the certificate at the URL, chains it to
// Apple's root, and checks the RSA PKCS#1 v1.5 SHA-256 signature over
//
//     teamPlayerID (UTF-8) | bundle id (UTF-8) | timestamp (UInt64, big-endian) | salt
//
// Only the signed fields are trusted: the teamPlayerID (the player's key on the server) and nothing else. The
// gamePlayerID the client sends alongside isn't signed; the server binds it 1:1 to the verified teamPlayerID.

/// What the client sends to prove who it is.
public struct GameCenterIdentityClaim: Equatable, Sendable {
    /// `GKPlayer.teamPlayerID`: signed.
    public var teamPlayerID: String
    /// `GKPlayer.gamePlayerID`: not signed; bound to the teamPlayerID by the server.
    public var gamePlayerID: String
    public var publicKeyURL: String
    public var signature: [UInt8]
    public var salt: [UInt8]
    /// Milliseconds since the epoch, as Game Center gives it.
    public var timestamp: UInt64

    public init(teamPlayerID: String, gamePlayerID: String, publicKeyURL: String, signature: [UInt8], salt: [UInt8], timestamp: UInt64) {
        self.teamPlayerID = teamPlayerID
        self.gamePlayerID = gamePlayerID
        self.publicKeyURL = publicKeyURL
        self.signature = signature
        self.salt = salt
        self.timestamp = timestamp
    }
}

/// The bytes Game Center signs.
public enum GameCenterSignedPayload {
    public static func bytes(teamPlayerID: String, bundleID: String, timestamp: UInt64, salt: [UInt8]) -> [UInt8] {
        var bytes = Array(teamPlayerID.utf8) + Array(bundleID.utf8)
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: timestamp >> UInt64(shift))) }
        return bytes + salt
    }
}

public enum GameCenterVerificationError: Error, Equatable, Sendable {
    /// Not https, or not on an `apple.com` host.
    case untrustedPublicKeyURL(String)
    /// The certificate couldn't be fetched.
    case fetchFailed(String)
    /// The fetched bytes aren't a DER (or PEM) certificate with an RSA key.
    case badCertificate(String)
    /// The certificate doesn't chain to the configured root, or isn't valid now.
    case untrustedCertificate(String)
    /// The signature doesn't verify over the payload (a wrong bundle id lands here: the payload is the server's).
    case badSignature
    /// The timestamp is outside the freshness window.
    case staleTimestamp
    /// A field is empty.
    case malformed(String)
}

/// Checks a claim and returns the verified teamPlayerID.
public protocol GameCenterVerifier: Sendable {
    func verify(_ claim: GameCenterIdentityClaim) async throws -> String
}

/// Fetches the certificate at Game Center's public key URL. The server's is an HTTPS client; tests hand over bytes.
public protocol CertificateFetching: Sendable {
    func fetch(_ url: URL) async throws -> [UInt8]
}

/// What the verifier checks against.
public struct GameCenterVerifierConfig: Sendable {
    public var bundleID: String
    /// The certificates trusted as anchors (Apple's root, plus any intermediate the operator pins).
    public var trustedRoots: [Certificate]
    /// How far the timestamp may be from now, either side.
    public var freshness: Duration
    /// Host suffix the public key URL must have.
    public var allowedHostSuffix: String

    public init(bundleID: String, trustedRoots: [Certificate], freshness: Duration = .seconds(300), allowedHostSuffix: String = ".apple.com") {
        self.bundleID = bundleID
        self.trustedRoots = trustedRoots
        self.freshness = freshness
        self.allowedHostSuffix = allowedHostSuffix
    }

    /// Every certificate in a PEM file (one or more `BEGIN CERTIFICATE` blocks).
    public static func certificates(pem: String) throws -> [Certificate] {
        let end = "-----END CERTIFICATE-----"
        return try pem.components(separatedBy: end).dropLast().map { try Certificate(pemEncoded: $0 + end) }
    }
}

/// The real verifier: fetch (cached by URL), chain to the trusted roots at `now()`, check the signature and the timestamp.
public final class AppleGameCenterVerifier: GameCenterVerifier {
    private let config: GameCenterVerifierConfig
    private let fetcher: any CertificateFetching
    private let now: @Sendable () -> Date
    private let cache = CertificateCache()

    public init(config: GameCenterVerifierConfig, fetcher: any CertificateFetching, now: @escaping @Sendable () -> Date = { Date() }) {
        self.config = config
        self.fetcher = fetcher
        self.now = now
    }

    public func verify(_ claim: GameCenterIdentityClaim) async throws -> String {
        guard !claim.teamPlayerID.isEmpty else { throw GameCenterVerificationError.malformed("teamPlayerID") }
        guard !claim.signature.isEmpty else { throw GameCenterVerificationError.malformed("signature") }
        guard !claim.salt.isEmpty else { throw GameCenterVerificationError.malformed("salt") }
        let now = now()
        let signedAt = Date(timeIntervalSince1970: Double(claim.timestamp) / 1000)
        let window = Double(config.freshness.components.seconds)
        guard abs(signedAt.timeIntervalSince(now)) <= window else { throw GameCenterVerificationError.staleTimestamp }

        let url = try trustedURL(claim.publicKeyURL)
        let leaf = try await certificate(at: url)
        try await validateChain(leaf, at: now)
        guard let key = _RSA.Signing.PublicKey(leaf.publicKey) else {
            throw GameCenterVerificationError.badCertificate("not an RSA key")
        }
        let payload = GameCenterSignedPayload.bytes(teamPlayerID: claim.teamPlayerID, bundleID: config.bundleID,
                                                    timestamp: claim.timestamp, salt: claim.salt)
        let signature = _RSA.Signing.RSASignature(rawRepresentation: claim.signature)
        guard key.isValidSignature(signature, for: SHA256.hash(data: payload), padding: .insecurePKCS1v1_5) else {
            throw GameCenterVerificationError.badSignature
        }
        return claim.teamPlayerID
    }

    private func trustedURL(_ string: String) throws -> URL {
        guard let url = URL(string: string), url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              host.hasSuffix(config.allowedHostSuffix) || "." + host == config.allowedHostSuffix
        else { throw GameCenterVerificationError.untrustedPublicKeyURL(string) }
        return url
    }

    private func certificate(at url: URL) async throws -> Certificate {
        if let cached = await cache.certificate(for: url) { return cached }
        let bytes: [UInt8]
        do {
            bytes = try await fetcher.fetch(url)
        } catch {
            throw GameCenterVerificationError.fetchFailed("\(error)")
        }
        let certificate: Certificate
        do {
            certificate = try Self.parse(bytes)
        } catch {
            throw GameCenterVerificationError.badCertificate("\(error)")
        }
        await cache.store(certificate, for: url)
        return certificate
    }

    /// DER, as Apple serves it, or PEM.
    static func parse(_ bytes: [UInt8]) throws -> Certificate {
        if let text = String(bytes: bytes, encoding: .utf8), text.contains("-----BEGIN") {
            return try Certificate(pemEncoded: text)
        }
        return try Certificate(derEncoded: bytes)
    }

    private func validateChain(_ leaf: Certificate, at time: Date) async throws {
        var verifier = Verifier(rootCertificates: CertificateStore(config.trustedRoots)) { RFC5280Policy(validationTime: time) }
        switch await verifier.validate(leaf: leaf, intermediates: CertificateStore()) {
        case .validCertificate: return
        case .couldNotValidate(let failures):
            throw GameCenterVerificationError.untrustedCertificate(failures.map { "\($0.policyFailureReason)" }.joined(separator: "; "))
        }
    }
}

/// Fetched certificates by URL. Game Center rotates its key rarely; the chain is re-checked on every use, so a
/// cached certificate past its expiry fails then.
actor CertificateCache {
    private var certificates: [URL: Certificate] = [:]
    private static let capacity = 16

    func certificate(for url: URL) -> Certificate? { certificates[url] }

    func store(_ certificate: Certificate, for url: URL) {
        if certificates.count >= Self.capacity { certificates.removeAll() }
        certificates[url] = certificate
    }
}

/// The dev server's verifier (ENV=dev only): any well-formed, fresh claim passes, so the contract runner and the
/// load client reach the server without Apple. Never in a non-dev config.
public struct DevGameCenterVerifier: GameCenterVerifier {
    private let freshness: Duration
    private let now: @Sendable () -> Date

    public init(freshness: Duration = .seconds(300), now: @escaping @Sendable () -> Date = { Date() }) {
        self.freshness = freshness
        self.now = now
    }

    public func verify(_ claim: GameCenterIdentityClaim) async throws -> String {
        guard !claim.teamPlayerID.isEmpty else { throw GameCenterVerificationError.malformed("teamPlayerID") }
        guard !claim.signature.isEmpty, !claim.salt.isEmpty else { throw GameCenterVerificationError.malformed("signature") }
        let signedAt = Date(timeIntervalSince1970: Double(claim.timestamp) / 1000)
        guard abs(signedAt.timeIntervalSince(now())) <= Double(freshness.components.seconds) else {
            throw GameCenterVerificationError.staleTimestamp
        }
        return claim.teamPlayerID
    }
}
