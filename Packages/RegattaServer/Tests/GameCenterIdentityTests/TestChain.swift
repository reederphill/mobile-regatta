import Crypto
import Foundation
import GameCenterIdentity
import SwiftASN1
import X509
import _CryptoExtras

/// A certificate chain made at test time, standing in for Apple's: a throwaway root CA and a leaf with an RSA key
/// that signs claims exactly as Game Center does. No network: `fetcher` serves the leaf at `url`.
struct TestChain: Sendable {
    static let url = "https://static.gc.apple.com/public-key/gc-test-1.cer"
    static let bundleID = "com.phillreeder.regatta"
    /// The test clock: 2026-10-08T12:00:00Z.
    static let now = Date(timeIntervalSince1970: 1_791_460_800)

    let root: Certificate
    let leaf: Certificate
    let leafKey: _RSA.Signing.PrivateKey

    /// `leafValidity` is the leaf's validity window; `signedBy` signs the leaf with another root's key instead.
    init(leafValidity: ClosedRange<Date>? = nil, signedBy other: P256.Signing.PrivateKey? = nil) throws {
        let rootKey = P256.Signing.PrivateKey()
        let rootName = try DistinguishedName { CommonName("Test Apple Root") }
        root = try Certificate(
            version: .v3, serialNumber: Certificate.SerialNumber(), publicKey: Certificate.PrivateKey(rootKey).publicKey,
            notValidBefore: Self.now.addingTimeInterval(-86_400 * 365), notValidAfter: Self.now.addingTimeInterval(86_400 * 365),
            issuer: rootName, subject: rootName, signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: nil))
                Critical(KeyUsage(keyCertSign: true))
            },
            issuerPrivateKey: Certificate.PrivateKey(rootKey))
        leafKey = Self.sharedLeafKey
        let validity = leafValidity ?? Self.now.addingTimeInterval(-86_400)...Self.now.addingTimeInterval(86_400 * 30)
        leaf = try Certificate(
            version: .v3, serialNumber: Certificate.SerialNumber(), publicKey: Certificate.PrivateKey(leafKey).publicKey,
            notValidBefore: validity.lowerBound, notValidAfter: validity.upperBound,
            issuer: rootName, subject: try DistinguishedName { CommonName("gc-test-1") }, signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions { Critical(KeyUsage(digitalSignature: true)) },
            issuerPrivateKey: Certificate.PrivateKey(other ?? rootKey))
    }

    /// RSA key generation is slow; one key serves every chain.
    private static let sharedLeafKey = try! _RSA.Signing.PrivateKey(keySize: .bits2048)

    var leafDER: [UInt8] {
        var serializer = DER.Serializer()
        try! serializer.serialize(leaf)
        return serializer.serializedBytes
    }

    /// A claim signed as Game Center signs it, over `bundleID`.
    func claim(teamPlayerID: String = "T:_test1", gamePlayerID: String = "G:test1", bundleID: String = Self.bundleID,
               timestamp: Date = Self.now, url: String = Self.url) throws -> GameCenterIdentityClaim {
        let salt: [UInt8] = [7, 1, 2, 3, 4, 5, 6, 8]
        let millis = UInt64(timestamp.timeIntervalSince1970 * 1000)
        let payload = GameCenterSignedPayload.bytes(teamPlayerID: teamPlayerID, bundleID: bundleID, timestamp: millis, salt: salt)
        let signature = try leafKey.signature(for: SHA256.hash(data: payload), padding: .insecurePKCS1v1_5)
        return GameCenterIdentityClaim(teamPlayerID: teamPlayerID, gamePlayerID: gamePlayerID, publicKeyURL: url,
                                       signature: Array(signature.rawRepresentation), salt: salt, timestamp: millis)
    }

    func verifier(now: Date = Self.now, roots: [Certificate]? = nil) -> AppleGameCenterVerifier {
        AppleGameCenterVerifier(
            config: GameCenterVerifierConfig(bundleID: Self.bundleID, trustedRoots: roots ?? [root]),
            fetcher: FixedFetcher(bytes: leafDER), now: { now })
    }
}

/// Serves the same bytes for any URL and counts the fetches.
final class FixedFetcher: CertificateFetching, @unchecked Sendable {
    let bytes: [UInt8]
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }

    init(bytes: [UInt8]) { self.bytes = bytes }

    func fetch(_ url: URL) async throws -> [UInt8] {
        lock.withLock { _count += 1 }
        return bytes
    }
}
