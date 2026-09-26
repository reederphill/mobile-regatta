import Foundation
import Testing
@testable import RegattaCore

/// The rules configuration file (#73): its values, its hash, and where the race reads it.
@Suite struct RulesConfigTests {
    static func bundledData() throws -> Data {
        try #require(try RulesConfigFile.bundledData(id: "fleet-rules", version: 1))
    }

    /// The bundled bytes with `old` replaced by `new` exactly once.
    static func tampered(_ old: String, _ new: String) throws -> Data {
        let text = try #require(String(data: try bundledData(), encoding: .utf8))
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
        #expect(format.edgeSpeedRetention == 0.3)
        #expect(format.beatSizing == .init(leaderSeconds: 480, maxMetres: 360, calibrationFactor: 1))
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
        #expect(numbers == ["10", "11", "12", "13", "15", "16.1", "18.1", "18.2", "18.3", "21.1", "21.2", "28", "29.1",
                            "31", "43.1(a)", "43.1(b)"])
        #expect(Set(RacingRule.allCases.map(\.title)).count == RacingRule.allCases.count)
    }

    /// The judge names rule 21.1 for a boat returning to start, 21.2 for one taking a penalty.
    @Test func judgeCallsRule21ForReturningAndPenalisedBoats() {
        let hull = Race.defaultBoatClass.hull
        let course = try! CourseLayoutTests.layout()
        var returning = Boat(id: 1, isPlayer: false, colorIndex: 1, position: Vec2(0, -10), heading: .pi / 2, speed: 3)
        returning.status = .ocs
        var penalised = Boat(id: 3, isPlayer: false, colorIndex: 3, position: Vec2(0, 100), heading: .pi / 2, speed: 3)
        penalised.status = .racing
        penalised.penaltyTurnsOwed = 1
        penalised.penaltyProgress = 1 // radians: past the 30° that counts as taking it
        var clean = Boat(id: 2, isPlayer: false, colorIndex: 2, position: Vec2(2, -10), heading: -.pi / 2, speed: 3)
        clean.status = .prestart
        #expect(Rules.judge(returning, clean, course: course, hull: hull) == Verdict(rule: .returningToStart, offender: 1, victim: 2))
        clean.status = .racing
        clean.position = Vec2(2, 100)
        #expect(Rules.judge(clean, penalised, course: course, hull: hull) == Verdict(rule: .takingAPenalty, offender: 3, victim: 2))
    }

    @Test func zoneRadiusIsThreeClassHullLengths() throws {
        let rules = try RulesConfigFile.bundled(id: "fleet-rules", version: 1).content
        for length in [4.2, 2.0, 7.5] {
            #expect(rules.zoneRadius(hullLength: length) == 3 * length)
        }
        let race = Race(setup: try RaceSetup(raceSeed: RaceSeed(1), seats: [.human, .bot]), windSeed: WindSeed(2))
        #expect(race.course.zoneRadius == 3 * race.boatClass.hull.length)
        #expect(race.course.zoneRadius == 3 * 4.2)
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

    /// The race's first rule call opens an incident that links back to it, with deadlines from the file.
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
            #expect(call.turnsOwed == 2)
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
        return index
    }

    @Test func pairKeysAreSortedAndLookupsWorkEitherWayRound() {
        let index = Self.sample()
        #expect(index.count == 3)
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

    /// Deterministic containers (ADR 0002): the rules model's sources declare no `Set` or `Dictionary`,
    /// so nothing in them can iterate one. Stricter than the package-wide iteration scan.
    @Test func rulesModelSourcesUseNoSetOrDictionary() throws {
        let names = ["RegattaCore/Incident.swift", "RegattaCore/Rules.swift", "RegattaCore/RaceEvent.swift",
                     "RegattaCore/RulesConfig.swift"]
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
