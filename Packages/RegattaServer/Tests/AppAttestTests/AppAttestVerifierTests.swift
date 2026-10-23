import AppAttest
import Crypto
import Foundation
import Testing
import X509

private func hash(_ bytes: [UInt8]) -> [UInt8] { Array(SHA256.hash(data: bytes)) }

/// #158's four ticket fixtures, on a chain and a device the tests make.
@Suite struct AppAttestTicketTests {
    let ca: TestAttestCA
    let device = TestDevice()
    let clientDataHash = hash(Array("client data".utf8))

    init() throws { ca = try TestAttestCA() }

    @Test func valid() async throws {
        let verifier = ca.verifier()
        var key = try await verifier.verifyAttestation(try device.attestation(ca, clientDataHash: clientDataHash),
                                                       keyID: device.keyID, clientDataHash: clientDataHash)
        #expect(key.keyID == device.keyID && key.counter == 0 && key.environment == .development)
        #expect(key.publicKey == Array(device.key.publicKey.x963Representation))
        #expect(key.receipt == [0x30, 0x80, 1, 2, 3])
        for counter: UInt32 in [1, 2, 5] {
            let request = hash(Array("request \(counter)".utf8))
            let assertion = try device.assertion(clientDataHash: request, counter: counter)
            #expect(try verifier.verifyAssertion(assertion, clientDataHash: request, key: key) == counter)
            key.counter = counter
        }
    }

    @Test func wrongAppID() async throws {
        for appID in ["OTHERTEAM1.\(TestAttestCA.bundleID)", "\(TestAttestCA.teamID).com.example.other"] {
            var knobs = TestDevice.Attestation()
            knobs.appID = appID
            await #expect(throws: AppAttestError.wrongAppID) {
                try await ca.verifier().verifyAttestation(try device.attestation(ca, clientDataHash: clientDataHash, knobs),
                                                          keyID: device.keyID, clientDataHash: clientDataHash)
            }
            let key = try await ca.verifier().verifyAttestation(try device.attestation(ca, clientDataHash: clientDataHash),
                                                                keyID: device.keyID, clientDataHash: clientDataHash)
            let assertion = try device.assertion(clientDataHash: clientDataHash, counter: 1, appID: appID)
            #expect(throws: AppAttestError.wrongAppID) { try ca.verifier().verifyAssertion(assertion, clientDataHash: clientDataHash, key: key) }
        }
    }

    @Test func replayedCounter() async throws {
        let verifier = ca.verifier()
        var key = try await verifier.verifyAttestation(try device.attestation(ca, clientDataHash: clientDataHash),
                                                       keyID: device.keyID, clientDataHash: clientDataHash)
        let first = try device.assertion(clientDataHash: clientDataHash, counter: 1)
        key.counter = try verifier.verifyAssertion(first, clientDataHash: clientDataHash, key: key)
        // The same assertion again.
        #expect(throws: AppAttestError.counterNotIncreased) { try verifier.verifyAssertion(first, clientDataHash: clientDataHash, key: key) }
        key.counter = try verifier.verifyAssertion(try device.assertion(clientDataHash: clientDataHash, counter: 5),
                                                   clientDataHash: clientDataHash, key: key)
        // Counter 3 after 5.
        #expect(throws: AppAttestError.counterNotIncreased) {
            try verifier.verifyAssertion(try device.assertion(clientDataHash: clientDataHash, counter: 3), clientDataHash: clientDataHash, key: key)
        }
    }

    @Test func wrongEnvironment() async throws {
        var development = TestDevice.Attestation(), production = TestDevice.Attestation()
        development.environment = .development
        production.environment = .production
        let developmentObject = try device.attestation(ca, clientDataHash: clientDataHash, development)
        let productionObject = try device.attestation(ca, clientDataHash: clientDataHash, production)
        await #expect(throws: AppAttestError.wrongEnvironment) {
            try await ca.verifier(environments: [.production]).verifyAttestation(developmentObject, keyID: device.keyID, clientDataHash: clientDataHash)
        }
        await #expect(throws: AppAttestError.wrongEnvironment) {
            try await ca.verifier(environments: [.development]).verifyAttestation(productionObject, keyID: device.keyID, clientDataHash: clientDataHash)
        }
        let both = ca.verifier(environments: [.development, .production])
        #expect(try await both.verifyAttestation(developmentObject, keyID: device.keyID, clientDataHash: clientDataHash).environment == .development)
        #expect(try await both.verifyAttestation(productionObject, keyID: device.keyID, clientDataHash: clientDataHash).environment == .production)
    }
}

/// Every other refusal, each with its error.
@Suite struct AppAttestErrorTests {
    let ca: TestAttestCA
    let device = TestDevice()
    let clientDataHash = hash(Array("client data".utf8))

    init() throws { ca = try TestAttestCA() }

    private func attest(_ knobs: TestDevice.Attestation = TestDevice.Attestation(), verifier: AppAttestVerifier? = nil,
                        keyID: [UInt8]? = nil) async throws -> AppAttestKey {
        try await (verifier ?? ca.verifier()).verifyAttestation(try device.attestation(ca, clientDataHash: clientDataHash, knobs),
                                                                 keyID: keyID ?? device.keyID, clientDataHash: clientDataHash)
    }

    @Test func untrustedRoot() async throws {
        let other = try TestAttestCA()
        let verifier = AppAttestVerifier(config: other.config(), now: { TestAttestCA.now })
        await #expect { try await attest(verifier: verifier) } throws: { error in
            if case AppAttestError.untrustedChain = error { return true }
            return false
        }
        // Apple's real root doesn't trust the test chain either.
        let apple = AppAttestVerifier(config: AppAttestConfig(appID: TestAttestCA.appID, environments: [.development]), now: { TestAttestCA.now })
        await #expect { try await attest(verifier: apple) } throws: { error in
            if case AppAttestError.untrustedChain = error { return true }
            return false
        }
    }

    @Test func expiredLeafAtNow() async throws {
        var knobs = TestDevice.Attestation()
        knobs.validity = TestAttestCA.now.addingTimeInterval(-86_400 * 3)...TestAttestCA.now.addingTimeInterval(-60)
        await #expect { try await attest(knobs) } throws: { error in
            if case AppAttestError.untrustedChain = error { return true }
            return false
        }
        // The same object passes at a time inside its validity: the chain is checked at the server's now().
        let earlier = ca.verifier(now: TestAttestCA.now.addingTimeInterval(-86_400))
        _ = try await attest(knobs, verifier: earlier)
    }

    @Test func nonceMismatch() async throws {
        var knobs = TestDevice.Attestation()
        knobs.nonce = hash([1, 2, 3])
        await #expect(throws: AppAttestError.nonceMismatch) { try await attest(knobs) }
        // An attestation made for other client data.
        let object = try device.attestation(ca, clientDataHash: hash([9]))
        await #expect(throws: AppAttestError.nonceMismatch) {
            try await ca.verifier().verifyAttestation(object, keyID: device.keyID, clientDataHash: clientDataHash)
        }
    }

    @Test func missingOrDoubledNonceExtension() async throws {
        var missing = TestDevice.Attestation()
        missing.nonceCount = 0
        await #expect(throws: AppAttestError.malformed("nonce extension")) { try await attest(missing) }
        var doubled = TestDevice.Attestation()
        doubled.nonceCount = 2
        // swift-certificates may refuse a certificate with a repeated extension before the nonce is read: either way
        // the attestation is refused as malformed.
        await #expect { try await attest(doubled) } throws: { error in
            if case AppAttestError.malformed = error { return true }
            return false
        }
    }

    /// Hard refusal (Fable's guard): the key id is SHA256 of the certified public key, never just what the client says.
    @Test func keyIDMustBeTheHashOfThePublicKey() async throws {
        await #expect(throws: AppAttestError.keyIDMismatch) { try await attest(keyID: hash([0])) }
        // A certificate for another key, with the device's key id claimed and as the credential id.
        var knobs = TestDevice.Attestation()
        knobs.certifiedKey = P256.Signing.PrivateKey().publicKey
        await #expect(throws: AppAttestError.keyIDMismatch) { try await attest(knobs) }
    }

    /// Hard refusal (Fable's guard): the credential id is the key id.
    @Test func credentialIDMustBeTheKeyID() async throws {
        var knobs = TestDevice.Attestation()
        knobs.credentialID = hash([7])
        await #expect(throws: AppAttestError.credentialIDMismatch) { try await attest(knobs) }
        knobs.credentialID = Array(device.keyID.prefix(16))
        await #expect(throws: AppAttestError.credentialIDMismatch) { try await attest(knobs) }
    }

    @Test func attestationCounterMustBeZero() async throws {
        var knobs = TestDevice.Attestation()
        knobs.counter = 1
        await #expect(throws: AppAttestError.nonZeroCounter) { try await attest(knobs) }
    }

    @Test func badSignature() async throws {
        let key = try await attest()
        let forged = try device.assertion(clientDataHash: clientDataHash, counter: 1, signer: P256.Signing.PrivateKey())
        #expect(throws: AppAttestError.badSignature) { try ca.verifier().verifyAssertion(forged, clientDataHash: clientDataHash, key: key) }
        // Signed for other client data.
        let other = try device.assertion(clientDataHash: hash([4]), counter: 1)
        #expect(throws: AppAttestError.badSignature) { try ca.verifier().verifyAssertion(other, clientDataHash: clientDataHash, key: key) }
        // Not DER at all.
        let garbage = TestCBOR.encode(.map([("signature", .bytes([1, 2, 3])),
                                            ("authenticatorData", .bytes(TestDevice.authData(appID: TestAttestCA.appID, counter: 1, credential: nil)))]))
        #expect(throws: AppAttestError.badSignature) { try ca.verifier().verifyAssertion(garbage, clientDataHash: clientDataHash, key: key) }
    }

    @Test func assertionUnderAnUnknownKey() throws {
        let assertion = try device.assertion(clientDataHash: clientDataHash, counter: 1)
        #expect(throws: AppAttestError.unknownKey) { try ca.verifier().verifyAssertion(assertion, clientDataHash: clientDataHash, key: nil) }
    }

    @Test func formatMustBeAppleAppAttest() async throws {
        var knobs = TestDevice.Attestation()
        knobs.format = "packed"
        await #expect(throws: AppAttestError.wrongFormat) { try await attest(knobs) }
        // Not CBOR, or CBOR of the wrong shape.
        await #expect { try await ca.verifier().verifyAttestation([0xFF], keyID: device.keyID, clientDataHash: clientDataHash) } throws: { error in
            if case AppAttestError.malformed = error { return true }
            return false
        }
        await #expect(throws: AppAttestError.malformed("x5c")) {
            try await ca.verifier().verifyAttestation(TestCBOR.encode(.map([("fmt", .text("apple-appattest"))])), keyID: device.keyID,
                                                      clientDataHash: clientDataHash)
        }
    }
}

/// The embedded root is the one downloaded from apple.com/certificateauthority (ADR 0014).
@Suite struct AppleRootTests {
    @Test func embeddedRootFingerprintIsPinned() throws {
        let der = TestAttestCA.der(AppleAppAttestRoot.certificate)
        let fingerprint = hash(der).map { String(format: "%02x", $0) }.joined()
        #expect(fingerprint == "1cb9823ba28ba6ad2d33a006941de2ae4f513ef1d4e831b9f7e0fa7b6242c932")
        #expect(AppleAppAttestRoot.certificate.subject == AppleAppAttestRoot.certificate.issuer)
        #expect(AppleAppAttestRoot.certificate.notValidAfter > Date(timeIntervalSince1970: 2_366_000_000)) // after 2044
    }
}

/// Real-device vectors, verified against the embedded Apple root at their own capture time with their own App ID.
/// The JSON: `teamID`, `bundleID`, `environment`, `keyID` (base64), `attestation` and `attestationClientData`,
/// `assertion` and `assertionClientData` (base64; the device signed SHA256 of each client data), `capturedAt` (ms).
@Suite struct RealAppAttestTests {
    struct Vector: Decodable {
        var teamID: String
        var bundleID: String
        var environment: AppAttestEnvironment
        var keyID: String
        var attestation: String
        var attestationClientData: String
        var assertion: String
        var assertionClientData: String
        var assertionCounter: UInt32?
        var capturedAt: UInt64
    }

    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/real")
    static var publicURL: URL { directory.appendingPathComponent("app-attest-public.json") }
    static var capturedURL: URL { directory.appendingPathComponent("app-attest.json") }

    static func verify(_ url: URL) async throws {
        let vector = try JSONDecoder().decode(Vector.self, from: Data(contentsOf: url))
        let bytes = { (b64: String) throws -> [UInt8] in Array(try #require(Data(base64Encoded: b64))) }
        let verifier = AppAttestVerifier(
            config: AppAttestConfig(teamID: vector.teamID, bundleID: vector.bundleID, environments: [vector.environment]),
            now: { Date(timeIntervalSince1970: Double(vector.capturedAt) / 1000) })
        let keyID = try bytes(vector.keyID)
        let key = try await verifier.verifyAttestation(try bytes(vector.attestation), keyID: keyID,
                                                       clientDataHash: hash(try bytes(vector.attestationClientData)))
        #expect(key.keyID == keyID && key.environment == vector.environment && !key.receipt.isEmpty)
        let counter = try verifier.verifyAssertion(try bytes(vector.assertion), clientDataHash: hash(try bytes(vector.assertionClientData)), key: key)
        #expect(counter > 0)
        if let expected = vector.assertionCounter { #expect(counter == expected) }
        // Another App ID or environment refuses the same bytes.
        let otherApp = AppAttestVerifier(config: AppAttestConfig(teamID: "XXXXXXXXXX", bundleID: vector.bundleID, environments: [vector.environment]),
                                         now: { Date(timeIntervalSince1970: Double(vector.capturedAt) / 1000) })
        await #expect(throws: AppAttestError.wrongAppID) {
            try await otherApp.verifyAttestation(try bytes(vector.attestation), keyID: keyID, clientDataHash: hash(try bytes(vector.attestationClientData)))
        }
        // Long after capture the short-lived credential certificate has expired.
        let late = AppAttestVerifier(config: verifier.config, now: { Date(timeIntervalSince1970: Double(vector.capturedAt) / 1000 + 86_400 * 400) })
        await #expect { try await late.verifyAttestation(try bytes(vector.attestation), keyID: keyID,
                                                         clientDataHash: hash(try bytes(vector.attestationClientData))) } throws: { error in
            if case AppAttestError.untrustedChain = error { return true }
            return false
        }
    }

    /// A public real-device vector (veehaitch/devicecheck-appattest, iOS 14.4, Apache-2.0: `LICENSE` beside it).
    /// Always runs: it proves the format, the nonce extension and the signature convention before #175.
    @Test func publicVectorVerifiesAgainstApplesRoot() async throws {
        try await Self.verify(Self.publicURL)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: capturedURL.path), "no Fixtures/real/app-attest.json yet (#175)"))
    func capturedAttestationVerifiesAgainstApplesRoot() async throws {
        try await Self.verify(Self.capturedURL)
    }
}
