import Crypto
import Foundation
import GameCenterIdentity
import Testing
import X509

/// The verifier against a chain made at test time (#145): Apple's checks, without Apple.
@Suite struct GameCenterVerifierTests {
    @Test func validSignatureVerifiesTheTeamPlayerID() async throws {
        let chain = try TestChain()
        let id = try await chain.verifier().verify(try chain.claim(teamPlayerID: "T:_alice"))
        #expect(id == "T:_alice")
    }

    @Test func signedPayloadIsTeamPlayerIDBundleTimestampBigEndianThenSalt() {
        let bytes = GameCenterSignedPayload.bytes(teamPlayerID: "T", bundleID: "b", timestamp: 0x0102_0304_0506_0708, salt: [9])
        #expect(bytes == [0x54, 0x62, 1, 2, 3, 4, 5, 6, 7, 8, 9])
    }

    @Test func wrongBundleIDIsRefused() async throws {
        let chain = try TestChain()
        await #expect(throws: GameCenterVerificationError.badSignature) {
            try await chain.verifier().verify(try chain.claim(bundleID: "com.example.other"))
        }
    }

    /// Only the signed fields are trusted: a claim naming another teamPlayerID under the same signature fails.
    @Test func tamperedTeamPlayerIDIsRefused() async throws {
        let chain = try TestChain()
        var claim = try chain.claim(teamPlayerID: "T:_alice")
        claim.teamPlayerID = "T:_mallory"
        await #expect(throws: GameCenterVerificationError.badSignature) { try await chain.verifier().verify(claim) }
    }

    /// The gamePlayerID isn't signed: changing it doesn't break the signature (the server binds it, not the verifier).
    @Test func gamePlayerIDIsNotPartOfTheSignature() async throws {
        let chain = try TestChain()
        var claim = try chain.claim()
        claim.gamePlayerID = "G:other"
        #expect(try await chain.verifier().verify(claim) == claim.teamPlayerID)
    }

    @Test(arguments: [-301.0, 301.0, -86_400.0])
    func staleTimestampIsRefused(offset: Double) async throws {
        let chain = try TestChain()
        let claim = try chain.claim(timestamp: TestChain.now.addingTimeInterval(offset))
        await #expect(throws: GameCenterVerificationError.staleTimestamp) { try await chain.verifier().verify(claim) }
    }

    @Test(arguments: [-299.0, 299.0])
    func timestampInsideTheWindowPasses(offset: Double) async throws {
        let chain = try TestChain()
        let claim = try chain.claim(timestamp: TestChain.now.addingTimeInterval(offset))
        #expect(try await chain.verifier().verify(claim) == claim.teamPlayerID)
    }

    @Test func certificateNotChainedToTheConfiguredRootIsRefused() async throws {
        let chain = try TestChain()
        let other = try TestChain()
        await #expect(throws: GameCenterVerificationError.self) {
            try await chain.verifier(roots: [other.root]).verify(try chain.claim())
        }
        do {
            _ = try await chain.verifier(roots: [other.root]).verify(try chain.claim())
        } catch GameCenterVerificationError.untrustedCertificate {
        } catch {
            Issue.record("expected untrustedCertificate, got \(error)")
        }
    }

    @Test func leafSignedByAnotherKeyIsRefused() async throws {
        let chain = try TestChain(signedBy: P256.Signing.PrivateKey())
        await #expect { try await chain.verifier().verify(try chain.claim()) } throws: { error in
            if case GameCenterVerificationError.untrustedCertificate = error { true } else { false }
        }
    }

    @Test func expiredCertificateIsRefused() async throws {
        let chain = try TestChain(leafValidity: TestChain.now.addingTimeInterval(-86_400 * 60)...TestChain.now.addingTimeInterval(-86_400))
        await #expect { try await chain.verifier().verify(try chain.claim()) } throws: { error in
            if case GameCenterVerificationError.untrustedCertificate = error { true } else { false }
        }
    }

    @Test(arguments: [
        "http://static.gc.apple.com/public-key/gc-prod-10.cer",
        "https://static.gc.apple.com.evil.example/key.cer",
        "https://evilapple.com/key.cer",
        "https://example.com/key.cer",
        "not a url",
    ])
    func publicKeyURLOffAppleIsRefused(url: String) async throws {
        let chain = try TestChain()
        await #expect(throws: GameCenterVerificationError.untrustedPublicKeyURL(url)) {
            try await chain.verifier().verify(try chain.claim(url: url))
        }
    }

    @Test func garbageCertificateIsRefused() async throws {
        let chain = try TestChain()
        let verifier = AppleGameCenterVerifier(config: GameCenterVerifierConfig(bundleID: TestChain.bundleID, trustedRoots: [chain.root]),
                                               fetcher: FixedFetcher(bytes: [1, 2, 3]), now: { TestChain.now })
        await #expect { try await verifier.verify(try chain.claim()) } throws: { error in
            if case GameCenterVerificationError.badCertificate = error { true } else { false }
        }
    }

    @Test func certificateIsFetchedOncePerURL() async throws {
        let chain = try TestChain()
        let fetcher = FixedFetcher(bytes: chain.leafDER)
        let verifier = AppleGameCenterVerifier(config: GameCenterVerifierConfig(bundleID: TestChain.bundleID, trustedRoots: [chain.root]),
                                               fetcher: fetcher, now: { TestChain.now })
        for player in ["T:_a", "T:_b", "T:_c"] { _ = try await verifier.verify(try chain.claim(teamPlayerID: player)) }
        #expect(fetcher.count == 1)
    }

    @Test func rootsLoadFromAPEMFileWithSeveralCertificates() throws {
        let a = try TestChain(), b = try TestChain()
        let pem = try a.root.serializeAsPEM().pemString + "\n" + b.root.serializeAsPEM().pemString + "\n"
        #expect(try GameCenterVerifierConfig.certificates(pem: pem) == [a.root, b.root])
    }

    @Test func devVerifierAcceptsAnyFreshWellFormedClaimOnly() async throws {
        let dev = DevGameCenterVerifier(now: { TestChain.now })
        let millis = UInt64(TestChain.now.timeIntervalSince1970 * 1000)
        let claim = GameCenterIdentityClaim(teamPlayerID: "T:_dev", gamePlayerID: "G:dev", publicKeyURL: "https://dev.invalid",
                                            signature: [1], salt: [1], timestamp: millis)
        #expect(try await dev.verify(claim) == "T:_dev")
        var stale = claim
        stale.timestamp -= 600_000
        await #expect(throws: GameCenterVerificationError.staleTimestamp) { try await dev.verify(stale) }
        var empty = claim
        empty.signature = []
        await #expect(throws: GameCenterVerificationError.malformed("signature")) { try await dev.verify(empty) }
    }
}

/// A real Game Center payload captured on a device (#175), when it's there:
/// `Packages/RegattaServer/Tests/Fixtures/real/gc-identity.json`, with Apple's root in `apple-root.pem` beside it.
/// The JSON: `teamPlayerID`, `gamePlayerID`, `bundleID`, `publicKeyURL`, `signature`, `salt` and `certificate` (base64,
/// the DER Apple served at the URL when it was captured) and `timestamp` (milliseconds). Verified at its own
/// timestamp, so its age doesn't matter. Skipped when absent, the expected state until #175.
@Suite struct RealGameCenterPayloadTests {
    struct Payload: Decodable {
        var teamPlayerID: String
        var gamePlayerID: String
        var bundleID: String
        var publicKeyURL: String
        var signature: String
        var salt: String
        var certificate: String
        var timestamp: UInt64
    }

    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/real")
    static var payloadURL: URL { directory.appendingPathComponent("gc-identity.json") }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: payloadURL.path), "no Fixtures/real/gc-identity.json yet (#175)"))
    func realPayloadVerifiesAgainstApplesRoot() async throws {
        let payload = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: Self.payloadURL))
        let roots = try GameCenterVerifierConfig.certificates(
            pem: String(contentsOf: Self.directory.appendingPathComponent("apple-root.pem"), encoding: .utf8))
        let certificate = try #require(Data(base64Encoded: payload.certificate))
        let verifier = AppleGameCenterVerifier(
            config: GameCenterVerifierConfig(bundleID: payload.bundleID, trustedRoots: roots),
            fetcher: FixedFetcher(bytes: Array(certificate)),
            now: { Date(timeIntervalSince1970: Double(payload.timestamp) / 1000) })
        let claim = GameCenterIdentityClaim(
            teamPlayerID: payload.teamPlayerID, gamePlayerID: payload.gamePlayerID, publicKeyURL: payload.publicKeyURL,
            signature: Array(try #require(Data(base64Encoded: payload.signature))), salt: Array(try #require(Data(base64Encoded: payload.salt))),
            timestamp: payload.timestamp)
        #expect(try await verifier.verify(claim) == payload.teamPlayerID)
    }
}
