import AppAttest
import Crypto
import Foundation
import RegattaProtocol
import RegattaServerKit
import RegattaServiceClient
import RegattaServices
import SwiftASN1
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

        init(bypass: Bool = false) throws {
            device = try AttestingDevice()
            var config = ServerConfig.dev()
            config.appAttest.bypass = bypass
            config.appAttest.trustedRoots = [device.root]
            endpoint = try ServiceEndpoint.make(config: config, store: store, wordList: .empty, appAttestKeys: keys)
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
        #expect(try await status(try rig.device.attestation(for: wren)) == .verified)
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
        // ServiceEndpoint's own default is the same.
        #expect(ServiceEndpoint(config: ServiceEndpointConfig(), sessions: SessionAuthority(store: InMemoryAccountStore(), verifier: StubVerifier()))
            .attestation.bypass)
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
