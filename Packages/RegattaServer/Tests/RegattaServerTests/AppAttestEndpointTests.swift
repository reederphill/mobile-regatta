import AppAttest
import Crypto
import Foundation
import RegattaProtocol
@testable import RegattaServerKit
import RegattaServiceClient
import RegattaServices
import SwiftASN1
import Synchronization
import Testing
import X509

/// A device and an App Attestation chain made at test time, on the wall clock (the endpoint's verifier reads `Date()`):
/// attestations and assertions over a connection's client data, as App Attest makes them. `AppAttestTests` has the full
/// set of knobs; this is the endpoint's share.
struct AttestingDevice: Sendable {
    let root: Certificate
    let intermediate: Certificate
    let intermediateKey: P256.Signing.PrivateKey
    let key = P256.Signing.PrivateKey()
    let appID: String
    var keyID: [UInt8] { Array(SHA256.hash(data: Array(key.publicKey.x963Representation))) }

    init(appID: String = "\(IdentitySettings().teamID).\(IdentitySettings().bundleID)") throws {
        self.appID = appID
        let rootKey = P256.Signing.PrivateKey()
        intermediateKey = P256.Signing.PrivateKey()
        let rootName = try DistinguishedName { CommonName("Test App Attestation Root CA") }
        let intermediateName = try DistinguishedName { CommonName("Test App Attestation CA 1") }
        let now = Date()
        root = try Certificate(
            version: .v3, serialNumber: Certificate.SerialNumber(), publicKey: Certificate.PrivateKey(rootKey).publicKey,
            notValidBefore: now - 86_400, notValidAfter: now + 86_400 * 30, issuer: rootName, subject: rootName,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: nil))
                Critical(KeyUsage(keyCertSign: true))
            },
            issuerPrivateKey: Certificate.PrivateKey(rootKey))
        intermediate = try Certificate(
            version: .v3, serialNumber: Certificate.SerialNumber(), publicKey: Certificate.PrivateKey(intermediateKey).publicKey,
            notValidBefore: now - 86_400, notValidAfter: now + 86_400 * 30, issuer: rootName, subject: intermediateName,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
                Critical(KeyUsage(keyCertSign: true))
            },
            issuerPrivateKey: Certificate.PrivateKey(rootKey))
    }

    static func der(_ certificate: Certificate) throws -> [UInt8] {
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        return serializer.serializedBytes
    }

    private static func cbor(_ major: UInt8, _ n: Int) -> [UInt8] {
        switch n {
        case 0...23: [major << 5 | UInt8(n)]
        case 24...0xFF: [major << 5 | 24, UInt8(n)]
        default: [major << 5 | 25, UInt8(n >> 8), UInt8(n & 0xFF)]
        }
    }

    private static func bytes(_ b: [UInt8]) -> [UInt8] { cbor(2, b.count) + b }
    private static func text(_ t: String) -> [UInt8] { cbor(3, t.utf8.count) + Array(t.utf8) }

    func authData(counter: UInt32, attested: Bool, environment: AppAttestEnvironment = .development) -> [UInt8] {
        var data = Array(SHA256.hash(data: Array(appID.utf8))) + [0x40]
        data += (0..<4).reversed().map { UInt8(truncatingIfNeeded: counter >> (8 * UInt32($0))) }
        if attested { data += environment.aaguid + [0, 32] + keyID }
        return data
    }

    /// The attestation object for `clientData`; `tamper` breaks its nonce.
    func attestationObject(_ clientData: AttestationClientData, tamper: Bool = false) throws -> [UInt8] {
        let authData = authData(counter: 0, attested: true)
        var nonce = Array(SHA256.hash(data: authData + clientData.hash))
        if tamper { nonce[0] ^= 1 }
        var ext = DER.Serializer()
        try ext.appendConstructedNode(identifier: .sequence) { s in
            try s.appendConstructedNode(identifier: ASN1Identifier(tagWithNumber: 1, tagClass: .contextSpecific)) { s in
                try s.serialize(ASN1OctetString(contentBytes: ArraySlice(nonce)))
            }
        }
        let leaf = try Certificate(
            version: .v3, serialNumber: Certificate.SerialNumber(), publicKey: Certificate.PublicKey(key.publicKey),
            notValidBefore: Date() - 3600, notValidAfter: Date() + 86_400, issuer: intermediate.subject,
            subject: try DistinguishedName { CommonName("credential") }, signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Certificate.Extension(oid: AttestationObject.nonceExtensionOID, critical: false, value: ArraySlice(ext.serializedBytes))
            },
            issuerPrivateKey: Certificate.PrivateKey(intermediateKey))
        let statement = [0xA2] + Self.text("x5c") + [0x82] + Self.bytes(try Self.der(leaf)) + Self.bytes(try Self.der(intermediate))
            + Self.text("receipt") + Self.bytes([1, 2, 3])
        return [0xA3] + Self.text("fmt") + Self.text("apple-appattest") + Self.text("attStmt") + statement
            + Self.text("authData") + Self.bytes(authData)
    }

    func assertionObject(_ clientData: AttestationClientData, counter: UInt32) throws -> [UInt8] {
        let authData = authData(counter: counter, attested: false)
        let signature = try key.signature(for: Array(SHA256.hash(data: authData + clientData.hash)))
        return [0xA2] + Self.text("signature") + Self.bytes(Array(signature.derRepresentation))
            + Self.text("authenticatorData") + Self.bytes(authData)
    }

    static func clientData(for player: GameCenterPlayer) -> AttestationClientData {
        AttestationClientData(nonce: (0..<16).map { _ in UInt8.random(in: 0...255) }, binding: player.wire.attestationBinding)
    }

    func attestation(for player: GameCenterPlayer, tamper: Bool = false) throws -> VersionedPayload {
        let clientData = Self.clientData(for: player)
        return try AttestationProof.attestation(keyID: keyID, object: try attestationObject(clientData, tamper: tamper), clientData: clientData).payload()
    }

    func assertion(for player: GameCenterPlayer, counter: UInt32) throws -> VersionedPayload {
        let clientData = Self.clientData(for: player)
        return try AttestationProof.assertion(keyID: keyID, assertion: try assertionObject(clientData, counter: counter), clientData: clientData).payload()
    }
}

/// #158 on the service endpoint: `HelloAck`'s status, the gate on the queue, the lobby and race sessions, the binding.
@Suite(.timeLimit(.minutes(1))) struct AppAttestEndpointTests {
    struct Rig {
        let device: AttestingDevice
        let store = InMemoryAccountStore()
        let keys = InMemoryAppAttestKeyStore()
        let endpoint: ServiceEndpoint

        init(bypass: Bool = false, keys: (any AppAttestKeyStore)? = nil, checkDeadline: Duration? = nil) throws {
            device = try AttestingDevice()
            var config = ServerConfig.dev()
            config.appAttest.bypass = bypass
            config.appAttest.trustedRoots = [device.root]
            if let checkDeadline { config.appAttest.checkDeadline = checkDeadline }
            endpoint = try ServiceEndpoint.make(config: config, store: store, wordList: .empty, appAttestKeys: keys ?? self.keys)
        }

        /// A connection with `attestation` in its Hello, signed in as `name` (with `player`'s flags), terms accepted.
        func connect(_ name: String, attestation: VersionedPayload, as player: GameCenterPlayer? = nil)
            async throws -> (link: InProcessServiceLink, connection: ServiceConnection) {
            let link = try await InProcessServiceLink.open(endpoint, hello: Hello(clientBuild: "test", files: [], attestation: attestation))
            let connection = ServiceConnection(link)
            _ = try await RemoteSession(connection).signIn(ServiceFixtures.signature(name), as: player ?? ServiceFixtures.player(name))
            _ = try await RemoteTermsService(connection).accept(TermsVersion(1))
            return (link, connection)
        }
    }

    @Test func attestedHelloThenSignInJoinsTheQueueAndOpensTheLobby() async throws {
        let rig = try Rig()
        let wren = ServiceFixtures.player("wren")
        let (link, connection) = try await rig.connect("wren", attestation: try rig.device.attestation(for: wren))
        #expect(link.ack?.attestation == .verified)
        try await RemoteQueueService(connection).join()
        #expect(try await RemoteLobbyService(connection).state().access != .closed(.communicationRestricted))
        #expect(try await rig.keys.key(rig.device.keyID)?.counter == 0)
        try await RemoteQueueService(connection).leave()
        link.close()

        // The next connection asserts with the attested key.
        let (next, nextConnection) = try await rig.connect("wren", attestation: try rig.device.assertion(for: wren, counter: 1))
        #expect(next.ack?.attestation == .verified)
        try await RemoteQueueService(nextConnection).join()
        #expect(try await rig.keys.key(rig.device.keyID)?.counter == 1)
    }

    @Test func unattestedHelloWithTheBypassOffIsRefusedTheQueueTheLobbyAndRaces() async throws {
        let rig = try Rig()
        let (link, connection) = try await rig.connect("finn", attestation: .none)
        #expect(link.ack?.attestation == .failed)
        await #expect(throws: QueueError.refused(.attestationFailed)) { try await RemoteQueueService(connection).join() }
        var states = RemoteQueueService(connection).stateUpdates().makeAsyncIterator()
        #expect(await states.next() == .unavailable(.attestationFailed))
        #expect(try await RemoteLobbyService(connection).state().access == .closed(.communicationRestricted))
        // A race session call answers as no race and leaves the connection open.
        let race = RemoteRaceSessionService(connection)
        await #expect(throws: RaceSessionError.noRace) { try await race.rejoin() }
        await #expect(throws: RaceSessionError.noRace) { try await race.handOff() }
        #expect(try await race.lastRace() == nil)
        #expect(link.closeReason == nil)
        // The profile and the terms work.
        _ = try await RemoteProfileService(connection).profile()
        _ = try await RemoteTermsService(connection).accept(TermsVersion(1))
        #expect(link.closeReason == nil)
    }

    /// The flags ride in the asserted request: a session call whose player isn't the one the proof binds (here she
    /// claims she isn't under age after attesting that she is) leaves the connection unattested.
    @Test func bindingMismatchIsUnattested() async throws {
        let rig = try Rig()
        let underage = ServiceFixtures.player("ivy", underage: true)
        let (link, connection) = try await rig.connect("ivy", attestation: try rig.device.attestation(for: underage),
                                                       as: ServiceFixtures.player("ivy"))
        #expect(link.ack?.attestation == .verified)
        await #expect(throws: QueueError.refused(.attestationFailed)) { try await RemoteQueueService(connection).join() }
        #expect(try await RemoteLobbyService(connection).state().access == .closed(.communicationRestricted))

        // A matching sign-in, then a second session call naming another player: unattested for good.
        let (other, otherConnection) = try await rig.connect("ivy", attestation: try rig.device.assertion(for: underage, counter: 1),
                                                             as: underage)
        #expect(other.ack?.attestation == .verified)
        try await RemoteQueueService(otherConnection).join()
        try await RemoteQueueService(otherConnection).leave()
        _ = try? await RemoteSession(otherConnection).signIn(ServiceFixtures.signature("ivy"), as: ServiceFixtures.player("ivy"))
        await #expect(throws: QueueError.refused(.attestationFailed)) { try await RemoteQueueService(otherConnection).join() }
    }

    @Test func helloAckStatusInEachCase() async throws {
        let rig = try Rig()
        let wren = ServiceFixtures.player("wren")
        func status(_ payload: VersionedPayload, on endpoint: ServiceEndpoint? = nil) async throws -> AttestationStatus? {
            let link = try await InProcessServiceLink.open(endpoint ?? rig.endpoint, hello: Hello(clientBuild: "test", files: [], attestation: payload))
            defer { link.close() }
            return link.ack?.attestation
        }
        // 1: verified, the attestation and then an assertion.
        let attestation = try rig.device.attestation(for: wren)
        #expect(try await status(attestation) == .verified)
        // 4: the attestation again is a replay.
        #expect(try await status(attestation) == .failed)
        let first = try rig.device.assertion(for: wren, counter: 1)
        #expect(try await status(first) == .verified)
        // 4: the same assertion replayed, an older counter, a broken attestation, unsupported and unavailable.
        #expect(try await status(first) == .failed)
        #expect(try await status(try rig.device.assertion(for: wren, counter: 1)) == .failed)
        #expect(try await status(try AttestingDevice().attestation(for: wren)) == .failed) // another root
        #expect(try await status(try rig.device.attestation(for: wren, tamper: true)) == .failed)
        #expect(try await status(try AttestationProof.unsupported.payload()) == .failed)
        #expect(try await status(try AttestationProof.unavailable.payload()) == .failed)
        #expect(try await status(VersionedPayload(schema: 1, bytes: [9])) == .failed)
        // 3: an assertion under a key the server doesn't know.
        #expect(try await status(try AttestingDevice().assertion(for: wren, counter: 1)) == .keyUnknown)
        // 2: the dev bypass, for no proof and for the simulator's.
        let bypassing = try Rig(bypass: true)
        #expect(try await status(.none, on: bypassing.endpoint) == .bypassed)
        #expect(try await status(try AttestationProof.unsupported.payload(), on: bypassing.endpoint) == .bypassed)
        // 0: a race connection doesn't check (`SeatConnection`; EndToEndTests).
    }

    /// The dev default (the bypass on): the load client's and the contract runner's `.none` queues.
    @Test func devDefaultBypassQueuesWithNoProof() async throws {
        let rig = try Rig(bypass: true)
        let (link, connection) = try await rig.connect("dev", attestation: .none)
        #expect(link.ack?.attestation == .bypassed)
        try await RemoteQueueService(connection).join()
        // The dev default the in-process endpoints name is the same.
        #expect(ConnectionAttestation.devDefault().bypass)
    }

    /// Under the bypass a real proof is still verified: a bad one is unattested.
    @Test func realPayloadUnderTheBypassIsStillVerified() async throws {
        let rig = try Rig(bypass: true)
        let wren = ServiceFixtures.player("wren")
        let (link, connection) = try await rig.connect("wren", attestation: try rig.device.attestation(for: wren, tamper: true))
        #expect(link.ack?.attestation == .failed)
        await #expect(throws: QueueError.refused(.attestationFailed)) { try await RemoteQueueService(connection).join() }
        let (good, _) = try await rig.connect("wren", attestation: try rig.device.attestation(for: wren))
        #expect(good.ack?.attestation == .verified)
    }
}

/// The security review's endpoint findings (#158, PR #589).
@Suite(.timeLimit(.minutes(1))) struct AppAttestReviewTests {
    /// Two copies of one attestation checked at once, `runs` times: how often both were verified, and how often
    /// neither was.
    static func race(_ runs: Int, keys: @escaping () -> any AppAttestKeyStore) async throws -> (both: Int, neither: Int) {
        var both = 0, neither = 0
        for _ in 0..<runs {
            let device = try AttestingDevice()
            var settings = AppAttestSettings()
            settings.trustedRoots = [device.root]
            let check = ConnectionAttestation(settings: settings, teamID: IdentitySettings().teamID, bundleID: IdentitySettings().bundleID,
                                              keys: keys())
            let payload = try device.attestation(for: ServiceFixtures.player("wren"))
            async let a = check.check(payload, purpose: .service)
            async let b = check.check(payload, purpose: .service)
            let verified = [await a, await b].filter { $0.status == .verified }.count
            if verified == 2 { both += 1 }
            if verified == 0 { neither += 1 }
        }
        return (both, neither)
    }

    /// Finding 2: registration is the one, atomic check, so exactly one of two concurrent copies is verified, on the
    /// in-memory store and on one with a database's round trips.
    @Test func sameAttestationTwiceConcurrentlyIsVerifiedOnce() async throws {
        let fast = try await Self.race(50) { InMemoryAppAttestKeyStore() }
        #expect(fast.both == 0 && fast.neither == 0)
        let slow = try await Self.race(20) { SlowAppAttestKeyStore() }
        #expect(slow.both == 0 && slow.neither == 0)
    }

    /// Finding 3: a hand-built staging or production config with the bypass on refuses to start, and so does one
    /// handed a bypassing endpoint, or production taking development keys.
    @Test func bypassOutsideDevRefusesToStart() async throws {
        let bypassOn = ServerConfigError.invalid(variable: "APP_ATTEST_BYPASS", value: "on", expected: "off or unset outside ENV=dev")
        for environment in [ServerEnvironment.staging, .production] {
            var config = ServerConfig.dev()
            config.environment = environment
            config.auth = .raceToken
            #expect(config.appAttest.bypass)
            await #expect(throws: bypassOn) { _ = try await RegattaHTTPServer.start(config: config) }
            #expect(throws: bypassOn) { _ = try ServiceEndpoint.make(config: config, store: InMemoryAccountStore(), wordList: .empty) }
            // The config's bypass off (and production's keys only), the endpoint's on.
            config.appAttest.bypass = false
            config.appAttest.environments = [.production]
            let dev = try ServiceEndpoint.make(config: ServerConfig.dev(), store: InMemoryAccountStore(), wordList: .empty)
            await #expect(throws: bypassOn) { _ = try await RegattaHTTPServer.start(config: config, services: dev) }
        }
        var production = ServerConfig.dev()
        production.environment = .production
        production.auth = .raceToken
        production.appAttest.bypass = false
        #expect(production.appAttest.environments == [.development, .production])
        await #expect(throws: ServerConfigError.invalid(variable: "APP_ATTEST_ENVIRONMENT", value: "development,production",
                                                        expected: "production in ENV=production")) {
            _ = try await RegattaHTTPServer.start(config: production)
        }
        // Defaults: the settings' bypass is off; only a dev config turns it on.
        #expect(!AppAttestSettings().bypass)
        #expect(ServerConfig.dev().appAttest.bypass)
    }

    /// Finding 5: a session call whose player the proof doesn't bind drops the connection to unattested, and her place
    /// in the queue goes with it.
    @Test func droppingToUnattestedEndsTheQueuePlace() async throws {
        let rig = try AppAttestEndpointTests.Rig()
        let underage = ServiceFixtures.player("ivy", underage: true)
        let (link, connection) = try await rig.connect("ivy", attestation: try rig.device.attestation(for: underage), as: underage)
        #expect(link.ack?.attestation == .verified)
        try await RemoteQueueService(connection).join()
        let matchmaker = try #require(rig.endpoint.matchmaker)
        #expect(await matchmaker.queuedCount == 1)
        // The same player, other flags: not what the proof binds.
        _ = try await RemoteSession(connection).signIn(ServiceFixtures.signature("ivy"), as: ServiceFixtures.player("ivy"))
        #expect(await matchmaker.queuedCount == 0)
        await #expect(throws: QueueError.refused(.attestationFailed)) { try await RemoteQueueService(connection).join() }
        #expect(await matchmaker.queuedCount == 0)
    }

    /// Finding 7: a key store that doesn't answer leaves the Hello unattested at the deadline, not held.
    @Test func attestationCheckHasADeadline() async throws {
        let rig = try AppAttestEndpointTests.Rig(keys: HangingAppAttestKeyStore(), checkDeadline: .milliseconds(200))
        let wren = ServiceFixtures.player("wren")
        let start = ContinuousClock.now
        let link = try await InProcessServiceLink.open(rig.endpoint, hello: Hello(clientBuild: "test", files: [],
                                                                                  attestation: try rig.device.attestation(for: wren)))
        defer { link.close() }
        #expect(link.ack?.attestation == .failed)
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    /// The unattested log: one line per reason a minute, saying how many were held back.
    @Test func unattestedLogIsLimitedPerReason() {
        let clock = Mutex(ContinuousClock.now)
        let log = UnattestedLog(interval: .seconds(60), now: { clock.withLock { $0 } })
        #expect(log.admit("none") == 0)
        #expect(log.admit("none") == nil)
        #expect(log.admit("none") == nil)
        #expect(log.admit("malformed") == 0)
        clock.withLock { $0 += .seconds(61) }
        #expect(log.admit("none") == 2)
        #expect(UnattestedReason.failed(.untrustedChain("a; b")).logKey == UnattestedReason.failed(.untrustedChain("c")).logKey)
    }
}

/// A key store with a database's round trip on every call.
final class SlowAppAttestKeyStore: AppAttestKeyStore {
    let inner = InMemoryAppAttestKeyStore()

    private func pause() async throws { try await Task.sleep(for: .milliseconds(5)) }

    func register(_ key: AppAttestKey, at time: Date) async throws -> Bool {
        try await pause()
        let stored = try await inner.register(key, at: time)
        try await pause()
        return stored
    }

    func key(_ keyID: [UInt8]) async throws -> AppAttestKey? {
        try await pause()
        return try await inner.key(keyID)
    }

    func advance(_ keyID: [UInt8], to counter: UInt32, at time: Date) async throws -> Bool {
        try await pause()
        return try await inner.advance(keyID, to: counter, at: time)
    }

    func purge(unusedSince cutoff: Date) async throws -> Int { try await inner.purge(unusedSince: cutoff) }
}

/// A key store stuck in a dead connection: no call returns within the test.
final class HangingAppAttestKeyStore: AppAttestKeyStore {
    private func hang() async throws -> Never {
        try await Task.sleep(for: .seconds(3600))
        throw CancellationError()
    }

    func register(_ key: AppAttestKey, at time: Date) async throws -> Bool { try await hang() }
    func key(_ keyID: [UInt8]) async throws -> AppAttestKey? { try await hang() }
    func advance(_ keyID: [UInt8], to counter: UInt32, at time: Date) async throws -> Bool { try await hang() }
    func purge(unusedSince cutoff: Date) async throws -> Int { try await hang() }
}

/// A real attestation in a `Hello` fits the frame a client may send before signing in (16 KiB): the public vector
/// always, #175's capture when it's there. Its object carries the x5c chain and Apple's receipt.
@Suite struct AppAttestSizeTests {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/real")

    static func helloSize(_ url: URL) throws -> (object: Int, frame: Int) {
        struct Vector: Decodable { var keyID: String; var attestation: String }
        let vector = try JSONDecoder().decode(Vector.self, from: Data(contentsOf: url))
        let object = Array(try #require(Data(base64Encoded: vector.attestation)))
        let proof = AttestationProof.attestation(keyID: Array(try #require(Data(base64Encoded: vector.keyID))), object: object,
                                                 clientData: AttestationClientData(nonce: Array(repeating: 0, count: 16),
                                                                                   binding: Array(repeating: 0, count: 32)))
        let hello = Hello(clientBuild: "1.0 (100)", files: [], attestation: try proof.payload())
        return (object.count, try Frame(seq: 1, tick: 0, message: .hello(hello)).encoded().count)
    }

    @Test func publicVectorHelloFitsThePreSignInFrame() throws {
        let (object, frame) = try Self.helloSize(Self.directory.appendingPathComponent("app-attest-public.json"))
        #expect(object > 4000) // a real object: two certificates and a receipt
        #expect(frame <= ServiceEndpointConfig().preSignInFrameCap)
        #expect(frame <= 1 << 14)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: directory.appendingPathComponent("app-attest.json").path),
                   "no Fixtures/real/app-attest.json yet (#175)"))
    func capturedHelloFitsThePreSignInFrame() throws {
        let (_, frame) = try Self.helloSize(Self.directory.appendingPathComponent("app-attest.json"))
        #expect(frame <= ServiceEndpointConfig().preSignInFrameCap)
    }
}
