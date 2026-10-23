import Foundation
import RegattaCore
import Testing
@testable import RegattaProtocol

/// `Hello.attestation` schema 1 and `HelloAck.attestation` (#158).
@Suite struct AttestationProofTests {
    @Test func everyKindRoundTrips() throws {
        var gen = Gen(seed: 158)
        var kinds = Set<UInt8>()
        for _ in 0..<400 {
            let proof = gen.attestationProof()
            let payload = try proof.payload()
            #expect(payload.schema == 1)
            kinds.insert(payload.bytes[0])
            #expect(try AttestationProof(payload: payload) == proof)
            // Through a whole Hello frame too.
            let hello = Hello(clientBuild: "1.0 (1)", files: [], attestation: payload)
            guard case .hello(let back) = try Frame(decoding: Frame(seq: 0, tick: 0, message: .hello(hello)).encoded()).message else {
                Issue.record("not a hello"); return
            }
            #expect(try AttestationProof(payload: back.attestation) == proof)
        }
        #expect(kinds == [1, 2, 3, 4])
    }

    @Test func malformedProofsAreRefused() throws {
        let clientData = AttestationClientData(nonce: Array(repeating: 1, count: 16), binding: Array(repeating: 2, count: 32))
        let good = try AttestationProof.assertion(keyID: Array(repeating: 3, count: 32), assertion: [9, 9], clientData: clientData).payload()
        #expect(throws: WireError.invalidValue("attestation.schema")) { try AttestationProof(payload: .none) }
        #expect(throws: WireError.invalidValue("attestation.schema")) { try AttestationProof(payload: VersionedPayload(schema: 2, bytes: good.bytes)) }
        for kind: UInt8 in [0, 5, 255] {
            #expect(throws: WireError.invalidValue("attestation.kind")) { try AttestationProof(payload: VersionedPayload(schema: 1, bytes: [kind])) }
        }
        #expect(throws: WireError.trailingBytes(1)) { try AttestationProof(payload: VersionedPayload(schema: 1, bytes: [3, 0])) }
        #expect(throws: WireError.trailingBytes(1)) { try AttestationProof(payload: VersionedPayload(schema: 1, bytes: good.bytes + [0])) }
        var badPurpose = good.bytes
        badPurpose[1 + 32 + 1 + 2] = 7
        #expect(throws: WireError.invalidValue("attestation.purpose")) { try AttestationProof(payload: VersionedPayload(schema: 1, bytes: badPurpose)) }
        // Every prefix is refused.
        for n in 0..<good.bytes.count {
            #expect(throws: (any Error).self) { try AttestationProof(payload: VersionedPayload(schema: 1, bytes: Array(good.bytes.prefix(n)))) }
        }
        // What the wire can't carry throws on encode.
        #expect(throws: WireError.outOfRange("attestation.keyID")) {
            try AttestationProof.assertion(keyID: [1], assertion: [], clientData: clientData).payload()
        }
        #expect(throws: WireError.outOfRange("attestation.nonce")) {
            try AttestationProof.assertion(keyID: Array(repeating: 3, count: 32), assertion: [],
                                           clientData: AttestationClientData(nonce: [1], binding: clientData.binding)).payload()
        }
        #expect(throws: WireError.tooLong("attestation.assertion")) {
            try AttestationProof.assertion(keyID: Array(repeating: 3, count: 32), assertion: Array(repeating: 0, count: 4097), clientData: clientData).payload()
        }
        #expect(throws: (any Error).self) {
            try AttestationProof.attestation(keyID: Array(repeating: 3, count: 32), object: Array(repeating: 0, count: 65_536), clientData: clientData).payload()
        }
    }

    @Test func clientDataHashIsSHA256OfItsBytes() {
        let clientData = AttestationClientData(nonce: Array(0..<16), binding: Array(16..<48))
        #expect(clientData.encoded == [1] + Array(0..<48))
        #expect(clientData.hash == ContentHash(of: Data([1] + Array(0..<48))).bytes)
    }

    @Test func helloAckCarriesTheStatusAndRefusesUnknownCodes() throws {
        for status in AttestationStatus.allCases {
            let ack = HelloAck(serverBuild: "s", attestation: status)
            #expect(try Frame(decoding: Frame(seq: 0, tick: 0, message: .helloAck(ack)).encoded()).message == .helloAck(ack))
        }
        let header: [UInt8] = [MessageType.helloAck.rawValue, 0, 0, 0, 0, 0, 0, 0, 0]
        #expect(throws: WireError.invalidValue("helloAck.attestation")) { try Frame(decoding: header + [1, 0x41, 5]) }
        #expect(throws: WireError.truncated) { try Frame(decoding: header + [1, 0x41]) }
    }

    /// The binding covers the wire encoding: the restriction flags and the alias change it.
    @Test func bindingCoversTheFlags() {
        let player = WirePlayer(gamePlayerID: "G:1", alias: "a", isUnderage: false, isPersonalizedCommunicationRestricted: false,
                                isMultiplayerGamingRestricted: false)
        var restricted = player
        restricted.isUnderage = true
        var renamed = player
        renamed.alias = "b"
        #expect(player.attestationBinding.count == 32)
        #expect(player.attestationBinding == player.attestationBinding)
        #expect(Set([player.attestationBinding, restricted.attestationBinding, renamed.attestationBinding]).count == 3)
    }
}
