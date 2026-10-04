import Foundation
import Testing
@testable import RegattaCore

/// The rules configuration file (#73): its values, its hash, and where the race reads it.
@Suite struct RulesConfigTests {
    /// The bundled bytes of fleet-rules@`version`: by default the default file, @5.
    static func bundledData(version: Int = 5) throws -> Data {
        try #require(try RulesConfigFile.bundledData(id: "fleet-rules", version: version))
    }

    /// The bundled bytes of fleet-rules@`version` with `old` replaced by `new` exactly once.
    static func tampered(_ old: String, _ new: String, version: Int = 5) throws -> Data {
        let text = try #require(String(data: try bundledData(version: version), encoding: .utf8))
        #expect(text.components(separatedBy: old).count == 2, "\(old) must appear exactly once")
        return Data(text.replacingOccurrences(of: old, with: new).utf8)
    }

    @Test func bundledV1YieldsTheListedValues() throws {
        let file = try RulesConfigFile.bundled(id: "fleet-rules", version: 1)
        #expect(file.ref.id == "fleet-rules" && file.ref.version == 1)
        let rules = file.content
        let incidents = rules.incidents
        #expect(incidents.nearMissSweep.heading == deg2rad(10))
        #expect(incidents.nearMissSweep.seconds == 0.5)
        #expect(incidents.escape.horizon == 2)
        #expect(incidents.separation == HullLengths(2))
        #expect(incidents.lastPointOfCertainty == 0.5)
        #expect(RulesConfig.ticks(incidents.lastPointOfCertainty) == 15)
        #expect(rules.zone.radius == HullLengths(3))

        // The builder values are data in the file, each listed by pointer.
        #expect(incidents.nearMissSweep.headingSamples == 5)
        let offsets = incidents.nearMissSweep.headingOffsets
        #expect(offsets.count == 5 && offsets.first == -deg2rad(10) && offsets[2] == 0 && offsets.last == deg2rad(10))
        #expect(abs(offsets[1] + deg2rad(5)) < 1e-12 && abs(offsets[3] - deg2rad(5)) < 1e-12)
        #expect(incidents.nearMissSweep.stepTicks == 1)
        #expect(incidents.nearMissSweep.clearance == HullLengths(0))
        #expect(incidents.escape.candidates.count == 10)
        #expect(incidents.escape.candidates.first == BoatInput(rudder: -1.0, ease: false))
        #expect(incidents.escape.candidates.last == BoatInput(rudder: 1.0, ease: true))
        #expect(incidents.escape.startTickOffset == 1)
        #expect(incidents.escape.initially == 2)
        #expect(rules.markRoomGiven == .init(roundingDistance: HullLengths(1), clearance: HullLengths(0.25)))
        #expect(rules.onABeat == .init(maxTrueWindAngle: deg2rad(60), windwardLegOnly: true))
        #expect(rules.builderValues == [
            "/incidents/nearMissSweep/headingSamples", "/incidents/nearMissSweep/stepTicks",
            "/incidents/nearMissSweep/clearanceHullLengths", "/incidents/escape/candidates",
            "/incidents/escape/startTickOffset", "/incidents/escape/initiallySeconds", "/markRoomGiven", "/onABeat",
        ])
    }

    @Test func tamperedBytesChangeTheHash() throws {
        let data = try Self.bundledData()
        let original = try RulesConfigFile(data: data)
        let tampered = try RulesConfigFile(data: try Self.tampered(
            #""lastPointOfCertaintySeconds": 0.5"#, #""lastPointOfCertaintySeconds": 1"#))
        #expect(tampered.content.incidents.lastPointOfCertainty == 1)
        #expect(tampered.ref.id == original.ref.id && tampered.ref.version == original.ref.version)
        #expect(tampered.ref.hash != original.ref.hash)
        // Even a change no decoder sees (whitespace) is a different file.
        let reformatted = try RulesConfigFile(data: data + Data("\n".utf8))
        #expect(reformatted.ref.hash != original.ref.hash)
        // And a race can't be handed tampered bytes under the original's ref.
        #expect(throws: DataFileError.self) { try RulesConfigFile(data: try Self.tampered(
            #""lastPointOfCertaintySeconds": 0.5"#, #""lastPointOfCertaintySeconds": 1"#), expecting: original.ref) }
    }

    @Test func raceFormatValuesLoadFromTheFile() throws {
        let format = try RulesConfigFile.bundled(id: "fleet-rules", version: 1).content.raceFormat
        #expect(format.penalty.start == 15)
        #expect(format.penalty.complete == 30)
        #expect(format.penalty.startedTurn == deg2rad(30))
        #expect(format.protestWindow == 15)
        #expect(format.finishWindow == 120)
        #expect(format.timeLimit == 960)
        #expect(format.startSequence == 60)
        #expect(format.startSequenceTicks == 1800)
        #expect(RaceSetup.defaultStartSequenceTicks == format.startSequenceTicks)
        // Line 1.25 × N × L, at least 42 m (#80's cases with the 4.2 m dinghy).
        #expect(format.startLine.length(fleetSize: 10, hullLength: 4.2) == 52.5)
        #expect(format.startLine.length(fleetSize: 2, hullLength: 4.2) == 42)
        #expect(format.startLine.length(fleetSize: 16, hullLength: 4.2) == 84)
        #expect(format.leewardGate.aboveLineBeatDivisor == 6)
        #expect(format.leewardGate.width.metres(hullLength: 4.2) == 42)
        #expect(format.offsetMark.toPort == HullLengths(12))
        #expect(format.raceArea == .init(acrossAxisBeatFraction: 0.75, belowLineLineLengths: 1, aboveWindwardBeatFraction: 0.25))
        #expect(format.startRow == .init(depthLineLengths: 0.5, spreadLineLengths: 1.5, trueWindAngle: deg2rad(90),
                                         polarSpeedFraction: 1))
        #expect(format.startRow.minimumSpacing == nil, "schema 1: no spacing floor")
        #expect(format.penalty.stackedPenaltyDeadlines == .fromCall, "before schema 3: each turn's clock from its call")
        #expect(format.edgeSpeedRetention == 0.3)
        #expect(format.beatSizing == .init(leaderSeconds: 480, maxMetres: 360, calibrationFactor: 1))
    }

    /// fleet-rules@2 (schema 2, #85) is @1 with the start row's spacing floor, 1.25 hull lengths, listed as a
    /// placeholder: every other value the same. @1 still loads, with no floor.
    @Test func version2IsVersion1WithTheStartRowSpacingFloor() throws {
        let v1 = try RulesConfigFile.bundled(id: "fleet-rules", version: 1)
        let v2 = try RulesConfigFile.bundled(id: "fleet-rules", version: 2)
        #expect(v1.header.schemaVersion == 1 && v2.header.schemaVersion == 2)
        #expect(v1.content.raceFormat.startRow.minimumSpacing == nil)
        #expect(v2.content.raceFormat.startRow.minimumSpacing == HullLengths(1.25))
        let spacing = "/raceFormat/startRow/minimumSpacingHullLengths"
        #expect(v2.header.placeholders.contains(spacing) && !v1.header.placeholders.contains(spacing))
        #expect(v2.header.placeholders.filter { $0 != spacing } == v1.header.placeholders)

        var format = v1.content.raceFormat
        format.startRow.minimumSpacing = HullLengths(1.25)
        #expect(v2.content.raceFormat == format)
        #expect(v2.content.incidents == v1.content.incidents && v2.content.zone == v1.content.zone)
        #expect(v2.content.markRoomGiven == v1.content.markRoomGiven && v2.content.onABeat == v1.content.onABeat)
        #expect(v2.content.builderValues == v1.content.builderValues)
    }

    /// The spacing floor is schema 2's: required there and positive, refused in a schema-1 file.
    @Test func startRowSpacingFloorNeedsSchema2() throws {
        let kind = RulesConfig.kind
        let field = #""minimumSpacingHullLengths": 1.25"#
        #expect(try RulesConfigFile(data: Self.tampered(field, #""minimumSpacingHullLengths": 2"#, version: 2))
            .content.raceFormat.startRow.minimumSpacing == HullLengths(2))
        for bad in ["0", "-1"] {
            #expect(throws: DataFileError.invalidContent(
                kind: kind, id: "fleet-rules", reason: "raceFormat.startRow.minimumSpacingHullLengths must be positive")) {
                try RulesConfigFile(data: Self.tampered(field, #""minimumSpacingHullLengths": "# + bad, version: 2))
            }
        }
        // Schema 2 without it (and without its placeholder, which would point at nothing).
        var text = try #require(String(data: try Self.tampered(",\n      " + field, "", version: 2), encoding: .utf8))
        text = text.replacingOccurrences(of: "\n    \"/raceFormat/startRow/minimumSpacingHullLengths\",", with: "")
        #expect(!text.contains(#""minimumSpacingHullLengths""#) && !text.contains(#"/minimumSpacingHullLengths""#))
        #expect(throws: DataFileError.malformed(kind: kind, reason: "schema 2 needs raceFormat.startRow.minimumSpacingHullLengths")) {
            try RulesConfigFile(data: Data(text.utf8))
        }
        // Schema 1 with it: @1 given the field, or @2 claiming schema 1.
        let needsSchema2 = DataFileError.invalidContent(
            kind: kind, id: "fleet-rules", reason: "raceFormat.startRow.minimumSpacingHullLengths needs schema 2")
        #expect(throws: needsSchema2) {
            try RulesConfigFile(data: Self.tampered(#""polarSpeedFraction": 1"#, #""polarSpeedFraction": 1, "# + field, version: 1))
        }
        #expect(throws: needsSchema2) {
            try RulesConfigFile(data: Self.tampered(#""schemaVersion": 2"#, #""schemaVersion": 1"#, version: 2))
        }
    }

    /// fleet-rules@3 (schema 3, #89) is @2 with sequential penalty deadlines (G4), loosened a little from #9's
    /// 15 s and 30 s to 20 s and 40 s (the owner): every other value the same. It was the default until #92; @1
    /// and @2 still load, with #9's deadlines and each turn's clock from its own call, as they meant.
    @Test func version3IsVersion2WithLooserSequentialPenaltyDeadlines() throws {
        let v1 = try RulesConfigFile.bundled(id: "fleet-rules", version: 1)
        let v2 = try RulesConfigFile.bundled(id: "fleet-rules", version: 2)
        let v3 = try RulesConfigFile.bundled(id: "fleet-rules", version: 3)
        #expect(v3.header.schemaVersion == 3)
        #expect(v1.content.raceFormat.penalty.stackedPenaltyDeadlines == .fromCall)
        #expect(v2.content.raceFormat.penalty.stackedPenaltyDeadlines == .fromCall)
        #expect(v3.content.raceFormat.penalty.stackedPenaltyDeadlines == .sequential)
        #expect(v3.header.placeholders == v2.header.placeholders)

        for old in [v1, v2] { #expect(old.content.raceFormat.penalty.start == 15 && old.content.raceFormat.penalty.complete == 30) }
        #expect(v3.content.raceFormat.penalty.start == 20 && v3.content.raceFormat.penalty.complete == 40)

        var format = v2.content.raceFormat
        format.penalty.stackedPenaltyDeadlines = .sequential
        format.penalty.start = 20
        format.penalty.complete = 40
        #expect(v3.content.raceFormat == format)
        #expect(v3.content.incidents == v2.content.incidents && v3.content.zone == v2.content.zone)
        #expect(v3.content.markRoomGiven == v2.content.markRoomGiven && v3.content.onABeat == v2.content.onABeat)
        #expect(v3.content.builderValues == v2.content.builderValues)
    }

    /// The stacking of penalty deadlines is schema 3's: required there and one of its values, refused before it.
    @Test func stackedPenaltyDeadlinesNeedsSchema3() throws {
        let kind = RulesConfig.kind
        let field = #""stackedPenaltyDeadlines": "sequential""#
        #expect(try RulesConfigFile(data: Self.tampered(field, #""stackedPenaltyDeadlines": "fromCall""#))
            .content.raceFormat.penalty.stackedPenaltyDeadlines == .fromCall)
        #expect(throws: DataFileError.invalidContent(
            kind: kind, id: "fleet-rules", reason: "raceFormat.penalty.stackedPenaltyDeadlines must be one of sequential, fromCall")) {
            try RulesConfigFile(data: Self.tampered(field, #""stackedPenaltyDeadlines": "stacked""#))
        }
        // Schema 3 without it.
        #expect(throws: DataFileError.malformed(kind: kind, reason: "schema 3 needs raceFormat.penalty.stackedPenaltyDeadlines")) {
            try RulesConfigFile(data: Self.tampered(",\n      " + field, "", version: 3))
        }
        // Before schema 3 with it: @2 given the field, or @3 claiming schema 2.
        let needsSchema3 = DataFileError.invalidContent(
            kind: kind, id: "fleet-rules", reason: "raceFormat.penalty.stackedPenaltyDeadlines needs schema 3")
        #expect(throws: needsSchema3) {
            try RulesConfigFile(data: Self.tampered(#""startedTurnDegrees": 30"#, #""startedTurnDegrees": 30, "# + field, version: 2))
        }
        #expect(throws: needsSchema3) {
            try RulesConfigFile(data: Self.tampered(#""schemaVersion": 3"#, #""schemaVersion": 2"#, version: 3))
        }
    }

    /// fleet-rules@4 (schema 4, #92) is @3 with the escape simulation's "changes course" rate, 12°/s, listed as a
    /// builder value: every other value the same. @1 to @3 still load, with none: their
    /// races run no escape simulation, and never call rules 15 or 16.1, as before #92.
    @Test func version4IsVersion3WithTheChangesCourseRate() throws {
        let v3 = try RulesConfigFile.bundled(id: "fleet-rules", version: 3)
        let v4 = try RulesConfigFile.bundled(id: "fleet-rules", version: 4)
        #expect(v4.header.schemaVersion == 4)
        for version in 1...3 {
            #expect(try RulesConfigFile.bundled(id: "fleet-rules", version: version).content.incidents.escape.changesCourse == nil)
        }
        #expect(v4.content.incidents.escape.changesCourse == deg2rad(12))
        #expect(v4.header.placeholders == v3.header.placeholders)
        let rate = "/incidents/escape/changesCourseDegreesPerSecond"
        #expect(v4.content.builderValues.contains(rate) && v4.content.builderValues.filter { $0 != rate } == v3.content.builderValues)

        var incidents = v3.content.incidents
        incidents.escape.changesCourse = deg2rad(12)
        #expect(v4.content.incidents == incidents)
        #expect(v4.content.raceFormat == v3.content.raceFormat && v4.content.zone == v3.content.zone)
        #expect(v4.content.markRoomGiven == v3.content.markRoomGiven && v4.content.onABeat == v3.content.onABeat)
        // The umpire records the boats long enough for a 2 s horizon a tick after a course change, and to
        // see right of way acquired 2 s ago against the tick before.
        #expect(v4.content.incidents.escape.recordedTicks == 62)
    }

    /// The "changes course" rate is schema 4's: required there and positive, refused before it.
    @Test func changesCourseRateNeedsSchema4() throws {
        let kind = RulesConfig.kind
        let field = #""changesCourseDegreesPerSecond": 12"#
        #expect(try RulesConfigFile(data: Self.tampered(field, #""changesCourseDegreesPerSecond": 20"#))
            .content.incidents.escape.changesCourse == deg2rad(20))
        for bad in ["0", "-3"] {
            #expect(throws: DataFileError.invalidContent(
                kind: kind, id: "fleet-rules", reason: "incidents.escape.changesCourseDegreesPerSecond must be positive")) {
                try RulesConfigFile(data: Self.tampered(field, #""changesCourseDegreesPerSecond": "# + bad))
            }
        }
        // Schema 4 without it (and without its builder value, which would point at nothing).
        var text = try #require(String(data: try Self.tampered(",\n      " + field, "", version: 4), encoding: .utf8))
        text = text.replacingOccurrences(of: "\n    \"/incidents/escape/changesCourseDegreesPerSecond\",", with: "")
        #expect(!text.contains(#""changesCourseDegreesPerSecond""#) && !text.contains(#"/changesCourseDegreesPerSecond""#))
        #expect(throws: DataFileError.malformed(kind: kind, reason: "schema 4 needs incidents.escape.changesCourseDegreesPerSecond")) {
            try RulesConfigFile(data: Data(text.utf8))
        }
        // Before schema 4 with it: @3 given the field, or @4 claiming schema 3.
        let needsSchema4 = DataFileError.invalidContent(
            kind: kind, id: "fleet-rules", reason: "incidents.escape.changesCourseDegreesPerSecond needs schema 4")
        #expect(throws: needsSchema4) {
            try RulesConfigFile(data: Self.tampered(#""initiallySeconds": 2"#, #""initiallySeconds": 2, "# + field, version: 3))
        }
        #expect(throws: needsSchema4) {
            try RulesConfigFile(data: Self.tampered(#""schemaVersion": 4"#, #""schemaVersion": 3"#, version: 4))
        }
        #expect(throws: DataFileError.unsupportedSchemaVersion(kind: kind, found: 6, supported: [1, 2, 3, 4, 5])) {
            try RulesConfigFile(data: Self.tampered(#""schemaVersion": 5"#, #""schemaVersion": 6"#))
        }
    }

    /// fleet-rules@5 (schema 5, #345) is @4 with rule 17's limits: 2 hull lengths, 5° on a beat, 8° on a reach or
    /// run, a 4 s "promptly sails astern" window, the tolerances and window listed as builder values; every other
    /// value the same. It is the default. @1 to @4 still load, with none: their races never call rule 17.
    @Test func version5IsVersion4WithRule17Limits() throws {
        let v4 = try RulesConfigFile.bundled(id: "fleet-rules", version: 4)
        let v5 = try RulesConfigFile.bundled(id: "fleet-rules", version: 5)
        #expect(v5.header.schemaVersion == 5)
        #expect(v5.ref == RaceFiles.defaults.rulesConfiguration.ref && v5.ref == Race.defaultRulesConfiguration.ref)
        for version in 1...4 {
            #expect(try RulesConfigFile.bundled(id: "fleet-rules", version: version).content.incidents.properCourse == nil)
        }
        let limits = try #require(v5.content.incidents.properCourse)
        #expect(limits == RulesConfig.ProperCourseLimits(distance: HullLengths(2), beatTolerance: deg2rad(5),
                                                          reachRunTolerance: deg2rad(8), promptlyAstern: 4))
        #expect(limits.tolerance(.beat) == deg2rad(5) && limits.tolerance(.reach) == deg2rad(8)
            && limits.tolerance(.run) == deg2rad(8))
        #expect(v5.header.placeholders == v4.header.placeholders)
        let added = ["/incidents/properCourse/beatToleranceDegrees", "/incidents/properCourse/reachRunToleranceDegrees",
                     "/incidents/properCourse/promptlyAsternSeconds"]
        #expect(v5.content.builderValues.filter { !added.contains($0) } == v4.content.builderValues)
        #expect(added.allSatisfy(v5.content.builderValues.contains))

        var incidents = v5.content.incidents
        incidents.properCourse = nil
        #expect(incidents == v4.content.incidents)
        #expect(v5.content.raceFormat == v4.content.raceFormat && v5.content.zone == v4.content.zone)
        #expect(v5.content.markRoomGiven == v4.content.markRoomGiven && v5.content.onABeat == v4.content.onABeat)
    }

    /// Rule 17's limits are schema 5's: required there and checked, refused before it.
    @Test func properCourseLimitsNeedSchema5() throws {
        let kind = RulesConfig.kind
        #expect(try RulesConfigFile(data: Self.tampered(#""beatToleranceDegrees": 5"#, #""beatToleranceDegrees": 7"#))
            .content.incidents.properCourse?.beatTolerance == deg2rad(7))
        for (old, new, reason) in [
            (#""distanceHullLengths": 2"#, #""distanceHullLengths": 0"#, "incidents.properCourse.distanceHullLengths must be positive"),
            (#""beatToleranceDegrees": 5"#, #""beatToleranceDegrees": 0"#,
             "incidents.properCourse.beatToleranceDegrees must be in (0, 45] degrees"),
            (#""reachRunToleranceDegrees": 8"#, #""reachRunToleranceDegrees": 50"#,
             "incidents.properCourse.reachRunToleranceDegrees must be in (0, 45] degrees"),
            (#""promptlyAsternSeconds": 4"#, #""promptlyAsternSeconds": 4.01"#,
             "incidents.properCourse.promptlyAsternSeconds must be a whole number of ticks (1/30 s)"),
        ] {
            #expect(throws: DataFileError.invalidContent(kind: kind, id: "fleet-rules", reason: reason)) {
                try RulesConfigFile(data: Self.tampered(old, new))
            }
        }
        // Schema 5 without it (and without its builder values, which would point at nothing).
        var text = try #require(String(data: try Self.bundledData(), encoding: .utf8))
        let block = try #require(text.range(of: #",\n    "properCourse": \{[^}]*\}"#, options: .regularExpression))
        text.removeSubrange(block)
        for pointer in ["beatToleranceDegrees", "reachRunToleranceDegrees", "promptlyAsternSeconds"] {
            text = text.replacingOccurrences(of: "\n    \"/incidents/properCourse/\(pointer)\",", with: "")
        }
        #expect(!text.contains(#""properCourse""#) && !text.contains("/incidents/properCourse/"))
        #expect(throws: DataFileError.malformed(kind: kind, reason: "schema 5 needs incidents.properCourse")) {
            try RulesConfigFile(data: Data(text.utf8))
        }
        // Before schema 5 with it: @5 claiming schema 4.
        #expect(throws: DataFileError.invalidContent(kind: kind, id: "fleet-rules", reason: "incidents.properCourse needs schema 5")) {
            try RulesConfigFile(data: Self.tampered(#""schemaVersion": 5"#, #""schemaVersion": 4"#))
        }
    }

    /// Changing one race-format value makes a different file, and the race log header records it.
    @Test func changingARaceFormatValueChangesTheHashInTheLogHeader() throws {
        func header(_ data: Data) throws -> RaceLog.Header {
            let file = try RulesConfigFile(data: data)
            let setup = try RaceSetup(raceSeed: RaceSeed(7), seats: [.human, .bot], rulesConfiguration: file.ref)
            return RaceLog.Header(setup: setup, windSeed: WindSeed(9), tideStateAtGun: nil)
        }
        let original = try header(Self.bundledData())
        let retuned = try header(Self.tampered(#""finishWindowSeconds": 120"#, #""finishWindowSeconds": 150"#))
        #expect(try RulesConfigFile(data: Self.tampered(#""finishWindowSeconds": 120"#, #""finishWindowSeconds": 150"#))
            .content.raceFormat.finishWindow == 150)
        let before = original.setup.rulesConfiguration
        let after = retuned.setup.rulesConfiguration
        #expect(before == Race.defaultRulesConfiguration.ref)
        #expect(after.hash != before.hash)

        // Through the log's JSON, as it is stored and replayed.
        let log = RaceLog(header: retuned, inputs: [], seatEvents: [], finalTick: 0)
        let decoded = try RaceLog(jsonData: log.jsonData())
        #expect(decoded.header.setup.rulesConfiguration == after)
    }

    @Test func noRuleIsNumbered22AndRule21IsReturningAndPenalised() {
        let numbers = RacingRule.allCases.map(\.rawValue)
        #expect(!numbers.contains("22"))
        #expect(!numbers.contains { $0.hasPrefix("22") })
        #expect(RacingRule(rawValue: "22") == nil)
        #expect(RacingRule.returningToStart.rawValue == "21.1")
        #expect(RacingRule.takingAPenalty.rawValue == "21.2")
        #expect(numbers == ["10", "11", "12", "13", "15", "16.1", "17", "18.1", "18.2", "18.3", "21.1", "21.2", "28", "29.1",
                            "31", "43.1(a)", "43.1(b)"])
        #expect(Set(RacingRule.allCases.map(\.title)).count == RacingRule.allCases.count)
    }

    /// The judge names rule 21.1 for a boat returning to start, 21.2 for one taking a penalty.
    @Test func judgeCallsRule21ForReturningAndPenalisedBoats() {
        let hull = Race.defaultBoatClass.hull
        let course = try! CourseLayoutTests.layout()
        // OCS and sailing straight back down the axis: returning (#85).
        var returning = Boat(id: 1, isPlayer: false, colorIndex: 1, position: Vec2(0, -10), heading: course.axis + .pi, speed: 3)
        returning.status = .ocs
        #expect(course.isReturning(returning))
        var penalised = Boat(id: 3, isPlayer: false, colorIndex: 3, position: Vec2(0, 100), heading: .pi / 2, speed: 3)
        penalised.status = .racing
        penalised.penaltyTurnsOwed = 1
        penalised.penaltyProgress = 1 // radians: past the 30° that counts as taking it
        var clean = Boat(id: 2, isPlayer: false, colorIndex: 2, position: Vec2(2, -10), heading: -.pi / 2, speed: 3)
        clean.status = .prestart
        #expect(Rules.judge(returning, clean, overlapped: true, course: course, hull: hull) == Verdict(rule: .returningToStart, offender: 1, victim: 2))
        // OCS but sailing on up the course, or along the line: not returning, so rule 21.1 doesn't make her
        // keep clear (#9: only while she sails back towards the line).
        for heading in [course.axis, course.axis + .pi / 2] {
            var sailingOn = returning
            sailingOn.heading = heading
            #expect(!course.isReturning(sailingOn))
            #expect(Rules.judge(sailingOn, clean, overlapped: true, course: course, hull: hull)?.rule != .returningToStart)
        }
        clean.status = .racing
        clean.position = Vec2(2, 100)
        #expect(Rules.judge(clean, penalised, overlapped: true, course: course, hull: hull) == Verdict(rule: .takingAPenalty, offender: 3, victim: 2))
    }

    @Test func zoneRadiusIsThreeClassHullLengths() throws {
        let rules = try RulesConfigFile.bundled(id: "fleet-rules", version: 1).content
        for length in [4.2, 2.0, 7.5] {
            #expect(rules.zoneRadius(hullLength: length) == 3 * length)
        }
        let race = Race(setup: try RaceSetup(raceSeed: RaceSeed(1), seats: [.human, .bot]), windSeed: WindSeed(2))
        #expect(race.course.zoneRadius == 3 * race.boatClass.hull.length)
        #expect(race.course.zoneRadius == 3 * 4.9) // the skiff's hull (#248)
    }

    @Test func unknownFieldsAndUnresolvedBuilderValuesAreRefused() throws {
        #expect(throws: DataFileError.self) {
            try RulesConfigFile(data: Self.tampered(#""timeLimitSeconds": 960"#, #""timeLimitSeconds": 960, "timeLimitSecs": 1"#))
        }
        #expect(throws: DataFileError.self) {
            try RulesConfigFile(data: Self.tampered(#""/onABeat""#, #""/onABeet""#))
        }
        // Durations are whole ticks.
        #expect(throws: DataFileError.self) {
            try RulesConfigFile(data: Self.tampered(#""protestWindowSeconds": 15"#, #""protestWindowSeconds": 15.01"#))
        }
        #expect(throws: DataFileError.self) {
            try RulesConfigFile(data: Self.tampered(#""headingSamples": 5"#, #""headingSamples": 4"#))
        }
    }

    /// The race's first rule call opens an incident that links back to it, with deadlines from the file: the
    /// fixture's fleet-rules@1 (schema 1: `fromCall`) fixes every call's clock at the call. A call costs one turn.
    @Test func ruleCallsOpenLinkedIncidents() throws {
        let feeder = LogFeeder(log: try ScriptedLog.fixture())
        let race = Race(setup: feeder.log.header.setup, windSeed: feeder.log.header.windSeed)
        var calls: [RuleCall] = []
        while race.tick < feeder.log.finalTick && calls.count < 3 {
            feeder.step(race)
            for event in race.drainEvents() {
                if case .ruleCall(let call) = event.kind {
                    #expect(event.tick == call.tick)
                    calls.append(call)
                }
            }
        }
        try #require(!calls.isEmpty, "the golden race has no rule call")
        for (k, call) in calls.enumerated() {
            #expect(call.incidentId == k)
            let incident = try #require(race.incidents[call.incidentId])
            #expect(incident.parties == SeatPair(call.offender, call.victim))
            #expect(incident.tick == call.tick && incident.leg == call.leg)
            #expect(incident.outcome == .called(call))
            #expect(call.startDeadlineTick == call.tick + 15 * Race.tickRate)
            #expect(call.completeDeadlineTick == call.tick + 30 * Race.tickRate)
            #expect(call.turnsOwed == 1)
        }
    }
}

@Suite struct IncidentIndexTests {
    static func sample() -> IncidentIndex {
        var index = IncidentIndex()
        index.open(between: 5, and: 2, tick: 100, leg: 0)
        index.open(between: 0, and: 7, tick: 130, leg: 1)
        var third = index.open(between: 2, and: 5, tick: 400, leg: 1)
        third.exonerate(5)
        third.outcome = .called(RuleCall(incidentId: third.id, tick: 400, rule: .exoneratedEntitledRoom, offender: 2,
                                         victim: 5, leg: 1, turnsOwed: 1, startDeadlineTick: 850, completeDeadlineTick: 1300))
        index.update(third)
        var second = index[1]!
        second.outcome = .noCall
        index.update(second)
        index.recordObstructionContact(ObstructionContact(tick: 410, leg: 1, seat: 6, kind: .boundary))
        index.recordObstructionContact(ObstructionContact(tick: 412, leg: 1, seat: 2, kind: .land))
        return index
    }

    @Test func pairKeysAreSortedAndLookupsWorkEitherWayRound() {
        let index = Self.sample()
        #expect(index.count == 3)
        #expect(index.obstructionContacts.map(\.seat) == [6, 2])
        #expect(index.pairs == [SeatPair(0, 7), SeatPair(2, 5)])
        #expect(SeatPair(5, 2) == SeatPair(2, 5) && SeatPair(5, 2).low == 2)
        #expect(index.incidents(between: 5, and: 2).map(\.id) == [0, 2])
        #expect(index.incidents(between: 2, and: 5).map(\.id) == [0, 2])
        #expect(index.latest(between: 7, and: 0)?.id == 1)
        #expect(index.incidents(between: 1, and: 3).isEmpty)
        #expect(index.latest(between: 4, and: 4) == nil)
        #expect(index[2]?.exonerated == [5])
        #expect(index[3] == nil)
    }

    @Test func codableRoundTrip() throws {
        let index = Self.sample()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(index)
        let decoded = try JSONDecoder().decode(IncidentIndex.self, from: data)
        #expect(decoded == index)
        #expect(decoded.obstructionContacts == index.obstructionContacts)
        #expect(decoded.pairs == index.pairs)
        #expect(decoded.incidents(between: 2, and: 5) == index.incidents(between: 2, and: 5))
        #expect(try encoder.encode(decoded) == data)

        // Ids must count up from 0, and a call must name its own incident.
        var json = try #require(String(data: data, encoding: .utf8))
        json = json.replacingOccurrences(of: #""id":1"#, with: #""id":4"#)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(IncidentIndex.self, from: Data(json.utf8)) }
        let badCall = Incident(id: 0, tick: 1, leg: 0, parties: SeatPair(0, 1), outcome: .called(RuleCall(
            incidentId: 9, tick: 1, rule: .portStarboard, offender: 0, victim: 1, leg: 0, turnsOwed: 1,
            startDeadlineTick: 2, completeDeadlineTick: 3)))
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Incident.self, from: JSONEncoder().encode(badCall)) }
    }

    /// The golden race's incident index (#94): replaying the fixture twice gives byte-identical encodings, the
    /// same as the live race the script sails, and a log carries it through its JSON byte for byte. Its two
    /// protests are recorded as the script taps them.
    @Test func replayReproducesByteIdenticalIndex() throws {
        let fixture = try ScriptedLog.fixture()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let first = try Replayer.replay(fixture, requireMatchingVersion: false)
        let second = try Replayer.replay(fixture, requireMatchingVersion: false)
        let bytes = try encoder.encode(first.incidents)
        #expect(try encoder.encode(second.incidents) == bytes)
        #expect(try encoder.encode(ScriptedLog.race().incidents) == bytes)

        let log = try #require(first.log)
        #expect(log.incidentIndex == first.incidents)
        let read = try RaceLog(jsonData: log.jsonData())
        #expect(try encoder.encode(#require(read.incidentIndex)) == bytes)
        #expect(read == log)

        // The script's two protests (steps 1500 and 2400), neither within 15 s of an incident of its pair.
        let start = -ScriptedLog.startSequenceTicks
        #expect(first.incidents.protests == [
            Protest(tick: start + 1500, leg: 0, protester: 3, protested: 7, matchedIncidentId: nil),
            Protest(tick: start + 2400, leg: 0, protester: 12, protested: 0, matchedIncidentId: nil),
        ])
        let counts: [Int] = [first.incidents.count, first.incidents.contacts.count, first.incidents.obstructionContacts.count,
                  first.incidents.markTouches.count]
        // #377: the shadow is the ribbons for every class, skiff@1 too (its ribbons seeded from its cone), so the scripted
        // fleet, sailing fixed inputs, meets differently: 5 incidents and 4 contacts, where the cone gave 6 and 6.
        #expect(counts == [5, 4, 9, 0])
        #expect(first.incidents.contacts.allSatisfy { $0.incidentId != nil }, "every contact of racing boats is in an incident")
    }

    /// A short scripted race's index, entry by entry (#94): a contact the umpire calls, a touch again inside the
    /// incident, a protest 5 s after and one with no incident. Pinned as JSON, integers and strings only, so it
    /// reads the same on every platform.
    @Test func scriptedIndexIsPinned() throws {
        let race = try IncidentFixture.race()
        try IncidentFixture.touching(race, tick: 300)
        race.step()
        let length = race.boatClass.hull.length
        try IncidentFixture.apart(race, tick: race.tick, at: race.boats[0].position, gap: length)
        race.step()
        try IncidentFixture.touching(race, tick: race.tick, at: race.boats[0].position)
        race.step()
        try IncidentFixture.apart(race, tick: race.tick, at: race.boats[0].position, gap: 3 * length)
        race.tap(.protest(target: 1), seat: 0, atTick: 451)
        race.tap(.protest(target: 0), seat: 1, atTick: 900)
        while race.tick < 900 { race.step() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = String(decoding: try encoder.encode(race.incidents), as: UTF8.self)
        #expect(json == ##"{"contacts":[{"incidentId":0,"leg":0,"parties":{"high":1,"low":0},"tick":301},"## +
            ##"{"incidentId":0,"leg":0,"parties":{"high":1,"low":0},"tick":303}],"## +
            ##""incidents":[{"exonerated":[],"id":0,"leg":0,"outcome":{"called":{"_0":{"completeDeadlineTick":1501,"## +
            ##""incidentId":0,"leg":0,"offender":1,"rule":"11","startDeadlineTick":901,"tick":301,"turnsOwed":1,"victim":0}}},"## +
            ##""parties":{"high":1,"low":0},"tick":301,"trigger":"contact"}],"markTouches":[],"obstructionContacts":[],"## +
            ##""protests":[{"leg":0,"matchedIncidentId":0,"protested":1,"protester":0,"tick":451},"## +
            ##"{"leg":0,"protested":0,"protester":1,"tick":900}]}"##)
        #expect(try JSONDecoder().decode(IncidentIndex.self, from: Data(json.utf8)) == race.incidents)
    }

    /// The new records round-trip, and decoding refuses records out of tick order or naming another pair's
    /// incident, or a later one (#94).
    @Test func decodingValidatesContactsAndProtests() throws {
        var index = Self.sample()
        index.recordBoatContact(BoatContact(tick: 100, leg: 0, parties: SeatPair(2, 5), incidentId: 0))
        index.recordBoatContact(BoatContact(tick: 120, leg: 0, parties: SeatPair(3, 4), incidentId: nil))
        index.recordMarkTouch(MarkTouch(tick: 200, leg: 1, seat: 4, mark: "windward"))
        index.recordProtest(Protest(tick: 410, leg: 1, protester: 5, protested: 2, matchedIncidentId: 2))
        index.recordProtest(Protest(tick: 500, leg: 1, protester: 6, protested: 1, matchedIncidentId: nil))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(index)
        #expect(try JSONDecoder().decode(IncidentIndex.self, from: data) == index)
        #expect(index.protests(by: 5).map(\.tick) == [410])
        #expect(index.incidents(involving: 2).map(\.id) == [0, 2])
        let json = String(decoding: data, as: UTF8.self)
        for (from, to) in [(#""tick":120"#, #""tick":90"#),                // contacts out of order
                           (#""matchedIncidentId":2"#, #""matchedIncidentId":1"#), // another pair's incident
                           (#""tick":410"#, #""tick":390"#),               // before its incident
                           (#""protester":6"#, #""protester":1"#)] {        // herself
            #expect(throws: DecodingError.self, "\(to)") {
                try JSONDecoder().decode(IncidentIndex.self, from: Data(json.replacingOccurrences(of: from, with: to).utf8))
            }
        }
    }

    /// A log carries its race's index, and a replay refuses a log whose index it doesn't reproduce (#94).
    @Test func replayRefusesAnotherIncidentIndex() throws {
        let race = testRace(seats: [.human, .human], seed: 5)
        race.tap(.protest(target: 1), seat: 0, atTick: race.tick + 5)
        for _ in 0..<30 { race.step() }
        var log = try #require(race.log)
        #expect(log.incidentIndex?.protests.map(\.protester) == [0])
        #expect(try Replayer.replay(log).incidents == race.incidents)
        log.incidentIndex = IncidentIndex()
        #expect(throws: ReplayError.incidentIndexMismatch) { try Replayer.replay(log) }
        // With the version check off a replay is only this build's reading, and the index isn't checked.
        #expect(try Replayer.replay(log, requireMatchingVersion: false).incidents == race.incidents)
        // A log with no index (every log before #94) replays as before.
        log.incidentIndex = nil
        #expect(try Replayer.replay(log).incidents == race.incidents)
    }

    /// Deterministic containers (ADR 0002): the rules model's sources declare no `Set` or `Dictionary`,
    /// so nothing in them can iterate one. Stricter than the package-wide iteration scan.
    @Test func rulesModelSourcesUseNoSetOrDictionary() throws {
        let names = ["RegattaCore/Incident.swift", "RegattaCore/Rules.swift", "RegattaCore/RaceEvent.swift",
                     "RegattaCore/RulesConfig.swift", "RegattaCore/Overlap.swift"]
        let files = try SourceScanTests.sources().filter { names.contains($0.name) }
        #expect(files.count == names.count)
        #expect(try SourceScanTests.unorderedNames(in: files) == [])
        let unorderedTypes = #"\bSet<|\bDictionary<|\bSet\(|\[\s*\w+\s*:\s*\w+\s*\]"#
        #expect(try SourceScanTests.violations(unorderedTypes, in: files) == [])
        #expect(try SourceScanTests.iterations(of: SourceScanTests.unorderedNames(in: SourceScanTests.sources()), in: files) == [])
        // The scan sees a dictionary type when there is one.
        #expect(try SourceScanTests.violations(unorderedTypes, in: [(name: "S.swift", text: "var x: [SeatPair: Int] = [:]")]).count == 1)
    }
}
