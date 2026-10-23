import AppAttest
import Crypto
import Foundation
import Testing

/// The decoder's shapes and refusals, and a seeded fuzz over 10,000 inputs (#158, Fable's T3).
@Suite struct CBORTests {
    @Test func lengthsInTheOneTwoAndFourByteForms() throws {
        #expect(try CBORDecoder.decode([0x17]) == .unsigned(23))
        #expect(try CBORDecoder.decode([0x18, 0xFF]) == .unsigned(255))
        #expect(try CBORDecoder.decode([0x19, 0x01, 0x00]) == .unsigned(256))
        #expect(try CBORDecoder.decode([0x1A, 0x00, 0x01, 0x00, 0x00]) == .unsigned(65_536))
        #expect(try CBORDecoder.decode([0x1B, 0, 0, 0, 1, 0, 0, 0, 0]) == .unsigned(1 << 32))
        let payload = Array(repeating: UInt8(7), count: 300)
        #expect(try CBORDecoder.decode([0x58, 3, 1, 2, 3]) == .bytes([1, 2, 3]))
        #expect(try CBORDecoder.decode([0x59, 0x01, 0x2C] + payload) == .bytes(payload))
        #expect(try CBORDecoder.decode([0x5A, 0, 0, 0x01, 0x2C] + payload) == .bytes(payload))
        #expect(try CBORDecoder.decode([0x78, 2, 0x68, 0x69]) == .text("hi"))
        #expect(try CBORDecoder.decode([0x82, 0x01, 0x41, 0x09]) == .array([.unsigned(1), .bytes([9])]))
        #expect(try CBORDecoder.decode(TestCBOR.encode(.map([("a", .unsigned(1)), ("b", .text("x"))])))["b"] == .text("x"))
    }

    @Test func refusals() {
        // An 8-byte length, indefinite lengths and reserved codes.
        #expect(throws: CBORError.unsupported("8-byte length")) { try CBORDecoder.decode([0x5B, 0, 0, 0, 0, 0, 0, 0, 1, 0]) }
        #expect(throws: CBORError.unsupported("indefinite length")) { try CBORDecoder.decode([0x5F, 0x41, 0x00, 0xFF]) }
        #expect(throws: CBORError.unsupported("indefinite length")) { try CBORDecoder.decode([0x9F, 0xFF]) }
        #expect(throws: CBORError.unsupported("reserved length code")) { try CBORDecoder.decode([0x1C]) }
        // Major types App Attest doesn't use.
        #expect(throws: CBORError.unsupported("negative integer")) { try CBORDecoder.decode([0x20]) }
        #expect(throws: CBORError.unsupported("tag")) { try CBORDecoder.decode([0xC0, 0x01]) }
        #expect(throws: CBORError.unsupported("float or simple value")) { try CBORDecoder.decode([0xF5]) }
        #expect(throws: CBORError.unsupported("float or simple value")) { try CBORDecoder.decode([0xFB, 0, 0, 0, 0, 0, 0, 0, 0]) }
        // Duplicate keys, also a text key against itself in another spelling of its length.
        #expect(throws: CBORError.duplicateKey) { try CBORDecoder.decode([0xA2, 0x61, 0x61, 0x01, 0x61, 0x61, 0x02]) }
        #expect(throws: CBORError.duplicateKey) { try CBORDecoder.decode([0xA2, 0x61, 0x61, 0x01, 0x78, 0x01, 0x61, 0x02]) }
        #expect(throws: CBORError.duplicateKey) { try CBORDecoder.decode([0xA2, 0x01, 0x01, 0x18, 0x01, 0x02]) }
        // Depth, trailing bytes, bad UTF-8, lengths past the end (never reserved).
        #expect(throws: CBORError.tooDeep) { try CBORDecoder.decode([0x81, 0x81, 0x81, 0x81, 0x81, 0x01]) }
        _ = try? CBORDecoder.decode([0x81, 0x81, 0x81, 0x81, 0x01])
        #expect(throws: CBORError.trailingBytes) { try CBORDecoder.decode([0x01, 0x01]) }
        #expect(throws: CBORError.invalidText) { try CBORDecoder.decode([0x62, 0xC3, 0x28]) }
        #expect(throws: CBORError.truncated) { try CBORDecoder.decode([0x5A, 0xFF, 0xFF, 0xFF, 0xFF]) }
        #expect(throws: CBORError.truncated) { try CBORDecoder.decode([0x9A, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]) }
        #expect(throws: CBORError.truncated) { try CBORDecoder.decode([0xBA, 0x00, 0x01, 0x00, 0x00, 0x01, 0x01]) }
        #expect(throws: CBORError.truncated) { try CBORDecoder.decode([]) }
        #expect(throws: CBORError.unsupported("too many items")) { try CBORDecoder.decode([0x98, 65] + Array(repeating: 0x01, count: 65)) }
    }

    @Test func fuzzNeverTrapsOnTenThousandInputs() throws {
        let ca = try TestAttestCA(), device = TestDevice()
        let hash = Array(SHA256.hash(data: [1]))
        let seeds: [[UInt8]] = [
            try device.attestation(ca, clientDataHash: hash),
            try device.assertion(clientDataHash: hash, counter: 1),
            TestCBOR.encode(.map([("a", .array([.unsigned(1), .bytes([1, 2]), .text("x")])), ("b", .map([("c", .unsigned(70_000))]))])),
        ]
        var rng = SystemRandomNumberGenerator.Seeded(seed: 158)
        var decoded = 0, refusedDuplicates = 0, inputs = 0
        for i in 0..<10_000 {
            var input: [UInt8]
            switch i % 5 {
            case 0: // random bytes
                input = (0..<Int(rng.next() % 64)).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
            case 1: // a truncated real object
                let seed = seeds[Int(rng.next() % UInt64(seeds.count))]
                input = Array(seed.prefix(Int(rng.next() % UInt64(seed.count))))
            case 2: // a real object with bytes flipped
                input = seeds[Int(rng.next() % UInt64(seeds.count))]
                for _ in 0..<(1 + Int(rng.next() % 4)) {
                    input[Int(rng.next() % UInt64(input.count))] = UInt8(truncatingIfNeeded: rng.next())
                }
            case 3: // heads with 1, 2, 4 and 8-byte arguments claiming huge lengths, then a little payload
                let major = UInt8(rng.next() % 8) << 5
                let info = [24, 25, 26, 27, 31][Int(rng.next() % 5)]
                input = [major | UInt8(info)] + (0..<Int(rng.next() % 12)).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
            default: // a map whose keys repeat
                let first = 0x61 + UInt8(rng.next() % 26), second = 0x61 + UInt8(rng.next() % 26)
                input = [0xA3, 0x61, first, 0x01, 0x61, second &+ (second == first ? 1 : 0), 0x02, 0x61, first, 0x03]
            }
            inputs += 1
            do {
                let item = try CBORDecoder.decode(input)
                decoded += 1
                #expect(size(of: item) <= input.count)
            } catch .duplicateKey {
                refusedDuplicates += 1
            } catch {}
        }
        #expect(inputs == 10_000)
        #expect(refusedDuplicates >= 2000) // every repeated-key map is refused
        #expect(decoded > 0)
    }

    /// The bytes a decoded item holds: never more than its input.
    private func size(of item: CBOR) -> Int {
        switch item {
        case .unsigned: 1
        case .bytes(let b): 1 + b.count
        case .text(let t): 1 + t.utf8.count
        case .array(let items): 1 + items.map(size).reduce(0, +)
        case .map(let pairs): 1 + pairs.map { size(of: $0.key) + size(of: $0.value) }.reduce(0, +)
        }
    }
}

extension SystemRandomNumberGenerator {
    /// SplitMix64: the same inputs on every run.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
