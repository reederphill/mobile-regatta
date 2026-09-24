import Foundation
import Testing
@testable import RegattaCore

/// Conditions version 2 (schema 2): version 1 plus the keyed wind's tuning (#75).
@Suite struct ConditionsVersion2Tests {
    /// SHA-256 of each `Resources/conditions/<id>@2.json`, pinned like version 1's (ADR 0004).
    static let pinnedHashes: [(id: String, hash: String)] = [
        ("light-and-patchy", "ed8b1c4ec9eff76919e14d07c46ff4192c44e1afc6c871686da421ae15ac5c1e"),
        ("classic-oscillating", "7b58f303eb7ff1b2262b4ff8990cd158ca85659e879fbe850c0d2dda4dac7d7e"),
        ("sea-breeze", "e31d26760cb92b41475f1ff6525bfc3f28890a036c679b2cbb1e6a85f6adf6e0"),
        ("gusty-offshore", "d20a27af924c0aa11449ab5f6d644f5d4b052b485875a5c45129f930f46e3a5a"),
    ]

    static func edited(_ id: String, _ replacements: [(of: String, with: String)]) throws -> Data {
        var text = String(decoding: try #require(try ConditionsFile.bundledData(id: id, version: 2)), as: UTF8.self)
        for r in replacements {
            #expect(text.contains(r.of), "\(id)@2 no longer contains \(r.of)")
            text = text.replacingOccurrences(of: r.of, with: r.with)
        }
        return Data(text.utf8)
    }

    @Test(arguments: pinnedHashes.map(\.id))
    func version2DecodesWithPinnedHashAndMatchesVersion1(id: String) throws {
        let v2 = try ConditionsFile.bundled(id: id, version: 2)
        #expect(v2.schemaVersion == 2 && v2.id == id && v2.version == 2)
        #expect(v2.ref.hash.hex == Self.pinnedHashes.first { $0.id == id }?.hash)

        // Everything version 1 had is unchanged; only the keyed-wind tuning is new.
        let v1 = try ConditionsFixtures.file(id).content
        let c = v2.content
        #expect(c.name == v1.name && c.strength == v1.strength && c.shift == v1.shift)
        #expect(c.trend == v1.trend && c.build == v1.build && c.puffs == v1.puffs)
        #expect(v1.keyedWind == nil)
        let keyed = try #require(c.keyedWind)
        #expect(keyed.wobble > 0 && keyed.wobble < c.shift.amplitude)
        #expect((keyed.trendRamp != nil) == (c.trend != nil))
        #expect((keyed.buildDuration != nil) == (c.build != nil))
        #expect((keyed.buildRamp != nil) == (c.build != nil))

        // The wobble and strength-channel values ship as placeholders awaiting tuning.
        let placeholders = v2.header.placeholders
        #expect(placeholders.contains("/shift/wobbleDegrees"))
        if c.trend != nil { #expect(placeholders.contains("/trend/rampFraction")) }
        if c.build != nil {
            #expect(placeholders.contains("/build/overSeconds"))
            #expect(placeholders.contains("/build/rampFraction"))
        }
        #expect(placeholders.contains("/puffs"))
    }

    @Test func seaBreezeKeyedTuningIsConvertedOnce() throws {
        let keyed = try #require(try ConditionsFile.bundled(id: "sea-breeze", version: 2).content.keyedWind)
        #expect(keyed.wobble == deg2rad(0.6))
        #expect(keyed.trendRamp == 0.5...1)
        #expect(keyed.buildDuration == 960)
        #expect(keyed.buildRamp == 0.5...1)
    }

    /// ADR 0004: both versions load side by side, each with its own ref.
    @Test func versionsOneAndTwoLoadSideBySide() throws {
        var catalog = DataFileCatalog<Conditions>()
        for id in ConditionsFixtures.ids {
            try catalog.add(try ConditionsFile.bundled(id: id, version: 1))
            try catalog.add(try ConditionsFile.bundled(id: id, version: 2))
            #expect(catalog.versions(of: id) == [1, 2])
            #expect(catalog.file(id: id, version: 1)?.ref != catalog.file(id: id, version: 2)?.ref)
        }
    }

    @Test(arguments: [
        // A schema 2 field missing (misspelt, so the decoder ignores it), and its placeholder entry with it.
        (#""wobbleDegrees": 0.6"#, #""wobbleDegreez": 0.6"#, "/shift/wobbleDegrees"),
        (#""maxDegrees": 15, "overSeconds": 960, "rampFraction""#, #""maxDegrees": 15, "overSeconds": 960, "rampFractionz""#,
         "/trend/rampFraction"),
        (#""maxFraction": 0.15, "overSeconds": 960"#, #""maxFraction": 0.15, "overSecondz": 960"#, "/build/overSeconds"),
    ])
    func missingSchema2FieldIsMalformed(of: String, with: String, placeholder: String) throws {
        let data = try Self.edited("sea-breeze", [(of: of, with: with), (of: #""\#(placeholder)","#, with: "")])
        #expect {
            try ConditionsFile(data: data)
        } throws: { error in
            if case .malformed(kind: "conditions", reason: _) = error as? DataFileError { return true }
            return false
        }
    }

    @Test(arguments: [
        // The wobble is smaller than the oscillation (#10).
        (#""wobbleDegrees": 0.6"#, #""wobbleDegrees": 5"#),
        (#""wobbleDegrees": 0.6"#, #""wobbleDegrees": -1"#),
        // A ramp takes some time, and at most the whole span.
        (#""maxDegrees": 15, "overSeconds": 960, "rampFraction": { "min": 0.5"#, #""maxDegrees": 15, "overSeconds": 960, "rampFraction": { "min": 0"#),
        (#""maxFraction": 0.15, "overSeconds": 960, "rampFraction": { "min": 0.5, "max": 1 }"#,
         #""maxFraction": 0.15, "overSeconds": 960, "rampFraction": { "min": 0.5, "max": 1.5 }"#),
        (#""maxFraction": 0.15, "overSeconds": 960"#, #""maxFraction": 0.15, "overSeconds": 0"#),
    ])
    func invalidSchema2ContentThrows(of: String, with: String) throws {
        let data = try Self.edited("sea-breeze", [(of: of, with: with)])
        #expect {
            try ConditionsFile(data: data)
        } throws: { error in
            if case .invalidContent(kind: "conditions", id: "sea-breeze", reason: _) = error as? DataFileError { return true }
            return false
        }
    }

    @Test func schema1FileWithASchema2FieldIsInvalid() throws {
        let data = try ConditionsFixtures.edited(
            "classic-oscillating", [(of: #""amplitudeDegrees": 8,"#, with: #""amplitudeDegrees": 8, "wobbleDegrees": 1,"#)])
        #expect {
            try ConditionsFile(data: data)
        } throws: { error in
            if case .invalidContent(kind: "conditions", id: "classic-oscillating", reason: _) = error as? DataFileError { return true }
            return false
        }
    }
}
