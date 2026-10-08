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

/// Apple's shape (#145 review): root → intermediate → leaf, with Game Center serving the leaf only.
struct IntermediateChain: Sendable {
    let root: Certificate
    let intermediate: Certificate
    let leaf: Certificate
    let leafKey: _RSA.Signing.PrivateKey

    init() throws {
        let base = try TestChain()
        let rootKey = P256.Signing.PrivateKey(), intermediateKey = P256.Signing.PrivateKey()
        let rootName = try DistinguishedName { CommonName("Test Apple Root") }
        let intermediateName = try DistinguishedName { CommonName("Test Apple Intermediate") }
        let validity = TestChain.now.addingTimeInterval(-86_400 * 365)...TestChain.now.addingTimeInterval(86_400 * 365)
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
        leafKey = base.leafKey
        leaf = try Certificate(
            version: .v3, serialNumber: Certificate.SerialNumber(), publicKey: Certificate.PrivateKey(leafKey).publicKey,
            notValidBefore: TestChain.now.addingTimeInterval(-86_400), notValidAfter: TestChain.now.addingTimeInterval(86_400 * 30),
            issuer: intermediateName, subject: try DistinguishedName { CommonName("gc-test-2") }, signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions { Critical(KeyUsage(digitalSignature: true)) },
            issuerPrivateKey: Certificate.PrivateKey(intermediateKey))
    }

    var leafDER: [UInt8] {
        var serializer = DER.Serializer()
        try! serializer.serialize(leaf)
        return serializer.serializedBytes
    }

    func claim(teamPlayerID: String = "T:_test2") throws -> GameCenterIdentityClaim {
        let salt: [UInt8] = [3, 1, 4, 1, 5, 9]
        let millis = UInt64(TestChain.now.timeIntervalSince1970 * 1000)
        let payload = GameCenterSignedPayload.bytes(teamPlayerID: teamPlayerID, bundleID: TestChain.bundleID, timestamp: millis, salt: salt)
        let signature = try leafKey.signature(for: SHA256.hash(data: payload), padding: .insecurePKCS1v1_5)
        return GameCenterIdentityClaim(teamPlayerID: teamPlayerID, gamePlayerID: "G:test2", publicKeyURL: TestChain.url,
                                       signature: Array(signature.rawRepresentation), salt: salt, timestamp: millis)
    }

    func verifier(_ config: GameCenterVerifierConfig) -> AppleGameCenterVerifier {
        AppleGameCenterVerifier(config: config, fetcher: FixedFetcher(bytes: leafDER), now: { TestChain.now })
    }
}

/// Holds every fetch until released, counting those in flight.
actor HeldFetcher: CertificateFetching {
    let bytes: [UInt8]
    private(set) var started = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(bytes: [UInt8]) { self.bytes = bytes }

    func fetch(_ url: URL) async throws -> [UInt8] {
        started += 1
        await withCheckedContinuation { waiting.append($0) }
        return bytes
    }

    func release() {
        for continuation in waiting { continuation.resume() }
        waiting = []
    }
}
