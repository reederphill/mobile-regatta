import Foundation
import Testing
@testable import RegattaCore

/// The four bundled v1.0 conditions files and edited copies of their bytes.
enum ConditionsFixtures {
    /// SHA-256 of each `Resources/conditions/<id>@1.json`. A released file never changes (ADR 0004):
    /// if one fails, ship the change as `<id>@2.json` instead of editing version 1.
    static let pinnedHashes: [(id: String, hash: String)] = [
        ("light-and-patchy", "0e7e134e5bf241780f82eb14c48e401dbb4f3d8e87cfaf4641f891532ccdda00"),
        ("classic-oscillating", "e781e852b3f441eb822a19a156bb17495b4c1e7d12ad61dc410b51c677f537a9"),
        ("sea-breeze", "523d49ec57070dad2ad0405a6fe9fd8fe278f6568efaf05a926bd8f37d2d639b"),
        ("gusty-offshore", "11b14b6b23a76f57bfeef939fc24f6b6c7bd34384ffc1ebed9362123e328e518"),
    ]
    static let ids = pinnedHashes.map(\.id)

    static func file(_ id: String) throws -> ConditionsFile {
        try ConditionsFile.bundled(id: id, version: 1)
    }

    /// The bundled file with each `(of, with)` replacement applied, each of which must match.
    static func edited(_ id: String, _ replacements: [(of: String, with: String)]) throws -> Data {
        var text = String(decoding: try #require(try ConditionsFile.bundledData(id: id, version: 1)), as: UTF8.self)
        for r in replacements {
            #expect(text.contains(r.of), "\(id) no longer contains \(r.of)")
            text = text.replacingOccurrences(of: r.of, with: r.with)
        }
        return Data(text.utf8)
    }
}

@Suite struct ConditionsFileTests {
    @Test(arguments: ConditionsFixtures.pinnedHashes.map(\.id))
    func bundledFileDecodesWithPinnedHash(id: String) throws {
        let file = try ConditionsFixtures.file(id)
        #expect(file.schemaVersion == 1 && file.id == id && file.version == 1)
        let pinned = try #require(ConditionsFixtures.pinnedHashes.first { $0.id == id }?.hash)
        #expect(file.ref.hash.hex == pinned)
        let bytes = try #require(try ConditionsFile.bundledData(id: id, version: 1))
        #expect(file.ref.hash == ContentHash(of: bytes))
        // Puff columns ship as placeholders awaiting tuning.
        #expect(file.header.placeholders.contains("/puffs"))
    }

    @Test func fourConditionsMatchTheWindModel() throws {
        // #10: name, strength kn, oscillation ± degrees, period s, trend.
        let expected: [(id: String, name: String, knots: ClosedRange<Double>, amplitude: Double,
                        period: ClosedRange<Double>, trend: Bool)] = [
            ("light-and-patchy", "Light and patchy", 6...9, 10, 150...180, false),
            ("classic-oscillating", "Classic oscillating", 9...14, 8, 110...130, false),
            ("sea-breeze", "Sea breeze", 11...16, 5, 110...130, true),
            ("gusty-offshore", "Gusty offshore", 14...20, 12, 90...120, false),
        ]
        #expect(expected.map(\.id) == ConditionsFixtures.ids)
        for e in expected {
            let c = try ConditionsFixtures.file(e.id).content
            #expect(c.name == e.name)
            #expect(c.strength == metresPerSecond(knots: e.knots.lowerBound)...metresPerSecond(knots: e.knots.upperBound))
            #expect(c.shift.amplitude == deg2rad(e.amplitude))
            #expect(c.shift.period == e.period)
            #expect(Conditions.shiftPeriodEnvelope.contains(c.shift.period.lowerBound))
            #expect(Conditions.shiftPeriodEnvelope.contains(c.shift.period.upperBound))
            #expect((c.trend != nil) == e.trend)
            #expect((c.build != nil) == e.trend)
            // #10's shared puff ranges.
            let p = c.puffs
            #expect(p.coverage > 0.25 && p.coverage < 0.40)
            #expect(p.diameter.lowerBound >= 60 && p.diameter.upperBound <= 150)
            #expect(p.gain.lowerBound >= 0.20 && p.gain.upperBound <= 0.35)
            #expect(p.lullLoss.lowerBound >= 0.15 && p.lullLoss.upperBound <= 0.25)
            #expect(p.fan > 0 && p.fan <= deg2rad(8))
            #expect(p.drift == 0.3...0.5)
        }
    }

    @Test func seaBreezeTrendAndBuildAreConvertedOnce() throws {
        let c = try ConditionsFixtures.file("sea-breeze").content
        let trend = try #require(c.trend)
        #expect(trend.size == deg2rad(5)...deg2rad(15))
        #expect(trend.duration == 960)
        #expect(try #require(c.build).fraction == 0...0.15)
        #expect(c.puffs.fan == deg2rad(4))
    }

    @Test(arguments: [0, 2])
    func wrongSchemaVersionThrows(schemaVersion: Int) throws {
        let data = try ConditionsFixtures.edited("sea-breeze", [(of: #""schemaVersion": 1,"#, with: #""schemaVersion": \#(schemaVersion),"#)])
        #expect(throws: DataFileError.unsupportedSchemaVersion(kind: "conditions", found: schemaVersion, supported: [1])) {
            try ConditionsFile(data: data)
        }
    }

    @Test(arguments: [
        // Outside the 90–180 s envelope (#10), either end.
        (#""periodSeconds": { "min": 90, "max": 120 }"#, #""periodSeconds": { "min": 80, "max": 120 }"#),
        (#""periodSeconds": { "min": 90, "max": 120 }"#, #""periodSeconds": { "min": 90, "max": 200 }"#),
        // Backwards ranges.
        (#""periodSeconds": { "min": 90, "max": 120 }"#, #""periodSeconds": { "min": 120, "max": 90 }"#),
        (#""minKnots": 14, "maxKnots": 20"#, #""minKnots": 20, "maxKnots": 14"#),
        (#""minKnots": 14, "maxKnots": 20"#, #""minKnots": 0, "maxKnots": 20"#),
        (#""lullShare": 0.35"#, #""lullShare": 1.5"#),
        (#""coverage": 0.38"#, #""coverage": 0"#),
        (#""lullLoss": { "min": 0.20, "max": 0.25 }"#, #""lullLoss": { "min": 0.20, "max": 1 }"#),
        (#""name": "Gusty offshore""#, #""name": """#),
    ])
    func invalidContentThrows(of: String, with: String) throws {
        let data = try ConditionsFixtures.edited("gusty-offshore", [(of: of, with: with)])
        #expect {
            try ConditionsFile(data: data)
        } throws: { error in
            if case .invalidContent(kind: "conditions", id: "gusty-offshore", reason: _) = error as? DataFileError { return true }
            return false
        }
    }

    @Test func missingColumnIsMalformed() throws {
        let data = try ConditionsFixtures.edited("classic-oscillating", [(of: #""lullShare": 0.3,"#, with: "")])
        #expect {
            try ConditionsFile(data: data)
        } throws: { error in
            if case .malformed(kind: "conditions", reason: _) = error as? DataFileError { return true }
            return false
        }
    }

    @Test func notBundledThrows() {
        #expect(throws: DataFileError.notBundled(kind: "conditions", id: "sea-breeze", version: 99)) {
            try ConditionsFile.bundled(id: "sea-breeze", version: 99)
        }
    }
}

@Suite struct WindSetupTests {
    static let seeds = (0..<1000).map { UInt64($0) &* 0x9E37_79B9_7F4A_7C15 ^ 0x5EED }

    @Test(arguments: ConditionsFixtures.pinnedHashes.map(\.id))
    func baseStrengthIsInTheConditionsRangeFor1000Seeds(id: String) throws {
        let file = try ConditionsFixtures.file(id)
        var lowest = Double.infinity, highest = -Double.infinity
        for seed in Self.seeds {
            let setup = WindSetup(conditions: file, pairing: .stub, raceSeed: RaceSeed(seed))
            #expect(file.content.strength.contains(setup.baseStrength))
            lowest = min(lowest, setup.baseStrength)
            highest = max(highest, setup.baseStrength)
        }
        // Drawn across the range, not stuck at one end.
        let span = file.content.strength.upperBound - file.content.strength.lowerBound
        #expect(lowest < file.content.strength.lowerBound + 0.05 * span)
        #expect(highest > file.content.strength.upperBound - 0.05 * span)
    }

    @Test func sameRaceSeedGivesIdenticalWindSetup() throws {
        let file = try ConditionsFixtures.file("sea-breeze")
        let pairing = VenuePairing(meanDirection: deg2rad(250), trend: .either)
        for seed in Self.seeds.prefix(100) {
            let a = WindSetup(conditions: file, pairing: pairing, raceSeed: RaceSeed(seed))
            let b = WindSetup(conditions: file, pairing: pairing, raceSeed: RaceSeed(seed))
            #expect(a == b)
            #expect(a.forecast == b.forecast)
        }
        let a = WindSetup(conditions: file, pairing: pairing, raceSeed: RaceSeed(1))
        let b = WindSetup(conditions: file, pairing: pairing, raceSeed: RaceSeed(2))
        #expect(a != b)
        #expect(a.baseStrength != b.baseStrength && a.meanDirection != b.meanDirection)
    }

    /// Pinned bit for bit on every platform: the draw uses only IEEE arithmetic and `fmod`, no libm trig.
    /// If this fails, every race's wind setup (and briefing) changed.
    @Test func drawIsPinned() throws {
        #expect(WindSetup.seedStream == 0x7769_6E64_7365_7470) // "windsetp"; its stream is pinned in RandomTests
        let classic = WindSetup(conditions: try ConditionsFixtures.file("classic-oscillating"), pairing: .stub, raceSeed: RaceSeed(42))
        #expect(classic.meanDirection.bitPattern == 13_817_625_872_785_592_704) // −0.1412 rad, 351.9°
        #expect(classic.baseStrength.bitPattern == 4_617_673_216_712_196_771) // 5.3177 m/s, 10.34 kn
        #expect(classic.trend == nil)
        let seaBreeze = WindSetup(conditions: try ConditionsFixtures.file("sea-breeze"), pairing: .stub, raceSeed: RaceSeed(42))
        #expect(seaBreeze.meanDirection == classic.meanDirection)
        #expect(seaBreeze.trend == .left)
    }

    @Test func meanDirectionIsWithinTenDegreesOfAuthored() throws {
        let file = try ConditionsFixtures.file("gusty-offshore")
        // Includes an authored direction near ±π, where the result wraps.
        for authored in [0.0, deg2rad(90), deg2rad(179), deg2rad(-175)] {
            var below = 0, above = 0
            for seed in Self.seeds {
                let setup = WindSetup(conditions: file, pairing: VenuePairing(meanDirection: authored, trend: .either),
                                      raceSeed: RaceSeed(seed))
                let offset = wrapAngle(setup.meanDirection - authored)
                #expect(abs(offset) <= deg2rad(10) + 1e-12)
                #expect(setup.meanDirection >= -.pi && setup.meanDirection < .pi)
                if offset < 0 { below += 1 } else { above += 1 }
            }
            #expect(below > 400 && above > 400)
        }
    }

    @Test func trendDirectionFollowsThePairing() throws {
        let seaBreeze = try ConditionsFixtures.file("sea-breeze")
        let noTrend = try ["light-and-patchy", "classic-oscillating", "gusty-offshore"].map(ConditionsFixtures.file)
        var lefts = 0, rights = 0
        for seed in Self.seeds {
            let raceSeed = RaceSeed(seed)
            #expect(WindSetup(conditions: seaBreeze, pairing: .init(meanDirection: 0, trend: .left), raceSeed: raceSeed).trend == .left)
            #expect(WindSetup(conditions: seaBreeze, pairing: .init(meanDirection: 0, trend: .right), raceSeed: raceSeed).trend == .right)
            switch WindSetup(conditions: seaBreeze, pairing: .init(meanDirection: 0, trend: .either), raceSeed: raceSeed).trend {
            case .left: lefts += 1
            case .right: rights += 1
            case nil: Issue.record("sea breeze has a trend")
            }
            // Conditions with no trend never get one, whatever the pairing says.
            for file in noTrend {
                for trend in [VenuePairing.Trend.left, .right, .either] {
                    let setup = WindSetup(conditions: file, pairing: .init(meanDirection: 0, trend: trend), raceSeed: raceSeed)
                    #expect(setup.trend == nil)
                }
            }
        }
        #expect(lefts > 400 && rights > 400)
    }

    @Test func pairingDoesNotMoveTheOtherDraws() throws {
        // Each draw has a fixed slot: the trend choice never shifts the direction or the strength.
        let file = try ConditionsFixtures.file("sea-breeze")
        for seed in Self.seeds.prefix(100) {
            let fixed = WindSetup(conditions: file, pairing: .init(meanDirection: 1, trend: .left), raceSeed: RaceSeed(seed))
            let either = WindSetup(conditions: file, pairing: .init(meanDirection: 1, trend: .either), raceSeed: RaceSeed(seed))
            #expect(fixed.meanDirection == either.meanDirection)
            #expect(fixed.baseStrength == either.baseStrength)
        }
    }

    @Test func carriesTheConditionsRefAndRaceArea() throws {
        let file = try ConditionsFixtures.file("light-and-patchy")
        let setup = WindSetup(conditions: file, pairing: .stub, raceSeed: RaceSeed(7))
        #expect(setup.conditionsRef == file.ref)
        #expect(setup.conditions == file.content)
        #expect(setup.pairing == .stub)
        #expect(setup.raceArea == nil)

        let area = RaceArea(centre: Vec2(0, 150), axis: 0, halfWidth: 270, halfLength: 300)
        let withArea = WindSetup(conditions: file, pairing: .stub, raceSeed: RaceSeed(7), raceArea: area)
        #expect(withArea.raceArea == area)
        #expect(withArea.baseStrength == setup.baseStrength && withArea.meanDirection == setup.meanDirection)
    }

    @Test func withRaceAreaAttachesTheAreaAndKeepsEveryOtherField() throws {
        let file = try ConditionsFixtures.file("sea-breeze")
        let pairing = VenuePairing(meanDirection: deg2rad(200), trend: .either)
        let area = RaceArea(centre: Vec2(10, 150), axis: deg2rad(200), halfWidth: 270, halfLength: 300)
        for seed in Self.seeds.prefix(100) {
            let drawn = WindSetup(conditions: file, pairing: pairing, raceSeed: RaceSeed(seed))
            let attached = drawn.with(raceArea: area)
            #expect(attached.raceArea == area)
            #expect(attached.conditionsRef == drawn.conditionsRef)
            #expect(attached.conditions == drawn.conditions)
            #expect(attached.pairing == drawn.pairing)
            #expect(attached.meanDirection.bitPattern == drawn.meanDirection.bitPattern)
            #expect(attached.baseStrength.bitPattern == drawn.baseStrength.bitPattern)
            #expect(attached.trend == drawn.trend)
            #expect(attached.forecast == drawn.forecast)
            // The same as drawing with the area up front, and removable again.
            #expect(attached == WindSetup(conditions: file, pairing: pairing, raceSeed: RaceSeed(seed), raceArea: area))
            #expect(attached.with(raceArea: nil) == drawn)
        }
    }
}

@Suite struct WindForecastTests {
    @Test func forecastShowsRangeDirectionShiftAndPuffCharacter() throws {
        let file = try ConditionsFixtures.file("sea-breeze")
        let setup = WindSetup(conditions: file, pairing: VenuePairing(meanDirection: deg2rad(-90), trend: .right),
                              raceSeed: RaceSeed(3))
        let f = setup.forecast
        #expect(f.conditionsName == "Sea breeze")
        #expect(abs(f.strengthRangeKnots.lowerBound - 11) < 1e-9 && abs(f.strengthRangeKnots.upperBound - 16) < 1e-9)
        #expect(f.strengthRangeKnots.contains(f.baseStrengthKnots))
        #expect(abs(f.baseStrengthKnots - knots(metresPerSecond: setup.baseStrength)) < 1e-12)
        // Authored 270°, within ±10°, as a compass bearing.
        #expect(f.meanDirectionDegrees >= 260 && f.meanDirectionDegrees <= 280)
        #expect(f.trend == .right)
        #expect(abs(f.shiftAmplitudeDegrees - 5) < 1e-9)
        #expect(f.shiftPeriodSeconds == 110...130)
        #expect(f.puffs.coverage == 0.33)
        #expect(f.puffs.gain == 0.20...0.24)
        #expect(f.puffs.lullShare == 0.15)
        #expect(f.puffs.lullLoss == 0.15...0.18)
        #expect(abs(f.puffs.fanDegrees - 4) < 1e-9)
    }

    @Test func meanDirectionDegreesIsACompassBearing() throws {
        let file = try ConditionsFixtures.file("classic-oscillating")
        for seed in WindSetupTests.seeds.prefix(200) {
            for authored in [0.0, deg2rad(5), deg2rad(355), deg2rad(180)] {
                let f = WindSetup(conditions: file, pairing: .init(meanDirection: authored, trend: .either),
                                  raceSeed: RaceSeed(seed)).forecast
                #expect(f.meanDirectionDegrees >= 0 && f.meanDirectionDegrees < 360)
                let offset = wrapAngle(deg2rad(f.meanDirectionDegrees) - authored)
                #expect(abs(offset) <= deg2rad(10) + 1e-9)
            }
        }
    }
}
