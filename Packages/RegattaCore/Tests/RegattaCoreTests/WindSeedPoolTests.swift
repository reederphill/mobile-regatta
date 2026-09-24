import Foundation
import Testing
@testable import RegattaCore

@Suite struct WindSeedPoolTests {
    static var fixtureURL: URL { testsDirectory.appendingPathComponent("Fixtures/wind-seed-pool.json") }
    static let pairing = WindSeedPool.Pairing(
        venue: .init(id: "test-venue", version: 1),
        conditions: .init(id: "classic-oscillating", version: 2),
        tideStateDegrees: 90
    )

    static func fixture() throws -> Data { try Data(contentsOf: fixtureURL) }

    static func edited(_ of: String, _ with: String) throws -> Data {
        let text = String(decoding: try fixture(), as: UTF8.self)
        #expect(text.contains(of), "fixture no longer contains \(of)")
        return Data(text.replacingOccurrences(of: of, with: with).utf8)
    }

    @Test func fixtureLoadsForItsPairing() throws {
        let pool = try WindSeedPool(data: Self.fixture(), for: Self.pairing)
        #expect(pool.pairing == Self.pairing)
        #expect(pool.seeds.map(\.value) == [0x0123_4567_89AB_CDEF, 0xD1CE_0000_0059_0002, 0xFFFF_FFFF_FFFF_FFFE, 1])
    }

    /// #106: a pool for another venue version (or conditions version, or tide state) is refused.
    @Test func poolForAnotherPairingIsRefused() throws {
        let others = [
            WindSeedPool.Pairing(venue: .init(id: "test-venue", version: 2), conditions: Self.pairing.conditions, tideStateDegrees: 90),
            WindSeedPool.Pairing(venue: .init(id: "other-venue", version: 1), conditions: Self.pairing.conditions, tideStateDegrees: 90),
            WindSeedPool.Pairing(venue: Self.pairing.venue, conditions: .init(id: "classic-oscillating", version: 1), tideStateDegrees: 90),
            WindSeedPool.Pairing(venue: Self.pairing.venue, conditions: .init(id: "sea-breeze", version: 2), tideStateDegrees: 90),
            WindSeedPool.Pairing(venue: Self.pairing.venue, conditions: Self.pairing.conditions, tideStateDegrees: 270),
            WindSeedPool.Pairing(venue: Self.pairing.venue, conditions: Self.pairing.conditions, tideStateDegrees: nil),
        ]
        for other in others {
            #expect(throws: WindSeedPoolError.wrongPairing(expected: other, found: Self.pairing)) {
                try WindSeedPool(data: Self.fixture(), for: other)
            }
        }
    }

    @Test func roundTripIsEqualAndNoTideIsNull() throws {
        let pool = try WindSeedPool(data: Self.fixture())
        #expect(try WindSeedPool(data: pool.jsonData()) == pool)

        let still = try WindSeedPool(
            pairing: .init(venue: .init(id: "lake", version: 3), conditions: .init(id: "light-and-patchy", version: 2), tideStateDegrees: nil),
            seeds: [WindSeed(7), WindSeed(.max)])
        let data = try still.jsonData()
        #expect(String(decoding: data, as: UTF8.self).contains(#""tideStateDegrees" : null"#))
        #expect(String(decoding: data, as: UTF8.self).contains(#""0xffffffffffffffff""#))
        #expect(try WindSeedPool(data: data) == still)
    }

    @Test func badPoolsAreRefused() throws {
        #expect(throws: WindSeedPoolError.unsupportedSchemaVersion(found: 2, supported: [1])) {
            try WindSeedPool(data: Self.edited(#""schemaVersion": 1"#, #""schemaVersion": 2"#))
        }
        #expect(throws: WindSeedPoolError.wrongKind("conditions")) {
            try WindSeedPool(data: Self.edited(#""kind": "wind-seed-pool""#, #""kind": "conditions""#))
        }
        // G1: each seed sails at most one race, so a pool never lists one twice.
        #expect(throws: WindSeedPoolError.invalid("seed 0xd1ce000000590002 appears more than once")) {
            try WindSeedPool(data: Self.edited(#""0x0000000000000001""#, #""0xd1ce000000590002""#))
        }
        for (of, with) in [
            (#""tideStateDegrees": 90"#, #""tideStateDegrees": 360"#),
            (#""tideStateDegrees": 90"#, #""tideStateDegrees": -1"#),
            (#""id": "test-venue""#, #""id": "Test Venue""#),
            (#""version": 1 }"#, #""version": 0 }"#),
        ] {
            #expect("\(of) → \(with)") {
                try WindSeedPool(data: Self.edited(of, with))
            } throws: { error in
                if case .invalid = error as? WindSeedPoolError { return true }
                return false
            }
        }
        for (of, with) in [
            (#""tideStateDegrees": 90,"#, ""),
            (#""0x0000000000000001""#, #""1""#),
            (#""seeds""#, #""seedz""#),
        ] {
            #expect("\(of) → \(with)") {
                try WindSeedPool(data: Self.edited(of, with))
            } throws: { error in
                if case .malformed = error as? WindSeedPoolError { return true }
                return false
            }
        }
    }
}
