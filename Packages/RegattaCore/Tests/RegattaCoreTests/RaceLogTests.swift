import Foundation
import Testing
@testable import RegattaCore

/// `Packages/RegattaCore/Tests`.
let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

/// A race for tests: by default seat 0 is human and `opponents` bot seats follow, sailed by brains.
func testRace(
    opponents: Int = 7, seats: [SeatKind]? = nil, laps: Int = 2, prestartSeconds: Int = 60,
    seed: UInt64, brains: [Int]? = nil
) -> Race {
    let seats = seats ?? [.human] + Array(repeating: .bot, count: opponents)
    let setup = try! RaceSetup(raceSeed: RaceSeed(seed), seats: seats, laps: laps,
                               startSequenceTicks: prestartSeconds * Race.tickRate)
    let brainSeats = brains ?? seats.indices.filter { seats[$0] == .bot }
    return Race(setup: setup, windSeed: WindSeed(seed &* 0x9E37_79B9_7F4A_7C15 &+ 1), botBrainSeats: brainSeats)
}

/// The golden input log: 16 seats sailed by a seeded script, with every kind of input and seat event.
/// Checked in as `Tests/Fixtures/golden-16-seat.racelog.json`; regenerate it with
/// `REGATTA_WRITE_REPLAY_FIXTURE=1 swift test --filter fixtureIsTheScript` (it should never need to change).
enum ScriptedLog {
    /// The version the fixture was recorded with. Fixed, so the fixture outlives revisions.
    static let recordedVersion = "2/swift-6.3.3/glibc-2.39/x86_64"
    static let seats: [SeatKind] = (0..<16).map { [0, 2, 5, 9].contains($0) ? .human : .bot }
    static let ticks = 4800
    static let startSequenceTicks = 60 * Race.tickRate
    static let windSeed = WindSeed(0xD1CE_0000_0059_0002)

    static var fixtureURL: URL { testsDirectory.appendingPathComponent("Fixtures/golden-16-seat.racelog.json") }

    static func fixture() throws -> RaceLog {
        try RaceLog(jsonData: Data(contentsOf: fixtureURL))
    }

    static func setup() throws -> RaceSetup {
        try RaceSetup(simulationVersion: recordedVersion, raceSeed: RaceSeed(0x0059_5EED_0000_0001), seats: seats,
                      laps: 2, startSequenceTicks: startSequenceTicks)
    }

    static var seatEvents: [SeatEvent] {
        let start = -startSequenceTicks
        return seats.indices.map { SeatEvent(tick: start, seat: $0, kind: .joined(seats[$0])) } + [
            SeatEvent(tick: -900, seat: 9, kind: .leftBeforeGun),
            SeatEvent(tick: -900, seat: 9, kind: .botTookOver(.fleet)),
            SeatEvent(tick: -600, seat: 5, kind: .disconnected),
            SeatEvent(tick: -585, seat: 5, kind: .dropped),
            SeatEvent(tick: -585, seat: 5, kind: .botTookOver(.cautious)),
            SeatEvent(tick: 300, seat: 5, kind: .rejoined),
            SeatEvent(tick: 1100, seat: 2, kind: .left),
        ]
    }

    /// Seat 0's helm: bear up to close-hauled, ease and wait, then sail through the line after the
    /// gun and tack. Every other seat follows the seeded random script.
    static let startingHelm: [(tick: Int, input: BoatInput)] = [
        (-1790, BoatInput(rudder: Int8(-100), ease: true)),
        (-1770, BoatInput(rudder: Int8(0), ease: true)),
        (-600, .neutral),
    ]
    static let startingTack = 900

    /// Sails the script through a live race (no brains) and returns the race's own log.
    static func make() throws -> RaceLog {
        let race = Race(setup: try setup(), windSeed: windSeed)
        var rng = SplitMix64(seed: 59)
        var nextChange = seats.indices.map { _ in rng.int(in: 1...60) }
        let events = seatEvents
        var nextEvent = 0
        func recordDue() {
            while nextEvent < events.count && events[nextEvent].tick == race.tick {
                race.record(events[nextEvent].kind, seat: events[nextEvent].seat)
                nextEvent += 1
            }
        }

        recordDue()
        let start = race.tick
        for step in 1...ticks {
            let t = start + step
            for (tick, input) in startingHelm where tick == t { race.apply(input, seat: 0, atTick: t) }
            if t == startingTack { race.tap(.tackGybe, seat: 0, atTick: t) }
            for seat in seats.indices where seat > 0 && step == nextChange[seat] {
                let tacks = rng.int(in: 0..<8) == 0
                // Mostly straight lines, so boats reach the line, start, go OCS and meet; some hard turns.
                let roll = rng.int(in: 0..<20)
                var rudder = roll < 10 ? 0 : roll < 16 ? rng.int(in: -20...20) : roll < 19 ? rng.int(in: -80...80) : (rng.bool() ? 127 : -127)
                let ease = rng.int(in: 0..<10) < (t < 0 ? 3 : 1)
                if tacks { rudder = 0 } // hands off while the tack autopilot runs
                race.apply(BoatInput(rudder: Int8(rudder), ease: ease), seat: seat, atTick: t)
                if tacks { race.tap(.tackGybe, seat: seat, atTick: t) }
                nextChange[seat] = step + rng.int(in: 20...150)
            }
            if step == 1500 { race.tap(.protest(target: 7), seat: 3, atTick: t) }
            if step == 2400 { race.tap(.protest(target: 0), seat: 12, atTick: t) }
            race.step()
            recordDue()
        }
        precondition(nextEvent == events.count, "seat events past the end of the script")
        return race.log
    }
}

@Suite struct RaceSetupTests {
    @Test func fleetSizeOneAndSeventeenAreRejected() {
        #expect(throws: RaceSetupError.fleetSize(1)) { try RaceSetup(raceSeed: RaceSeed(1), seats: [.human]) }
        #expect(throws: RaceSetupError.fleetSize(17)) {
            try RaceSetup(raceSeed: RaceSeed(1), seats: Array(repeating: .bot, count: 17))
        }
        #expect(throws: RaceSetupError.fleetSize(0)) { try RaceSetup(raceSeed: RaceSeed(1), seats: []) }
    }

    @Test func fleetSizesTwoToSixteenAreAccepted() throws {
        for size in 2...16 {
            let setup = try RaceSetup(raceSeed: RaceSeed(1), seats: [.human] + Array(repeating: .bot, count: size - 1))
            #expect(setup.fleetSize == size)
            #expect(setup.laps == 2)
            #expect(setup.simulationVersion == simulationVersion)
        }
        #expect(try RaceSetup(raceSeed: RaceSeed(1), seats: [.human, .bot], laps: 1).laps == 1)
    }

    @Test func lapsAndSequenceAreValidated() {
        #expect(throws: RaceSetupError.laps(0)) { try RaceSetup(raceSeed: RaceSeed(1), seats: [.human, .bot], laps: 0) }
        #expect(throws: RaceSetupError.startSequenceTicks(0)) {
            try RaceSetup(raceSeed: RaceSeed(1), seats: [.human, .bot], startSequenceTicks: 0)
        }
    }

    @Test func decodingValidatesTheFleetSize() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ScriptedLog.setup())) as! [String: Any]
        json["seats"] = Array(repeating: "bot", count: 17)
        let data = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: RaceSetupError.fleetSize(17)) { try JSONDecoder().decode(RaceSetup.self, from: data) }
    }

    /// ADR 0001: the wind comes from the wind seed alone, placement from the race seed alone.
    @Test func windSeedIsIndependentOfTheRaceSeed() throws {
        let setup = try RaceSetup(raceSeed: RaceSeed(1), seats: [.human, .bot, .bot, .bot])
        let other = try RaceSetup(raceSeed: RaceSeed(2), seats: [.human, .bot, .bot, .bot])
        let a = Race(setup: setup, windSeed: WindSeed(10))
        let b = Race(setup: setup, windSeed: WindSeed(11))
        let c = Race(setup: other, windSeed: WindSeed(10))
        #expect(a.boats.map(\.position) == b.boats.map(\.position))
        #expect(a.boats.map(\.position) != c.boats.map(\.position))
        // The default conditions have no trend or build, so the public setup doesn't touch the keys.
        #expect(a.wind.keys.bytes != b.wind.keys.bytes)
        #expect(a.wind.keys.bytes == c.wind.keys.bytes)
    }
}

@Suite struct InputTests {
    @Test func rudderMapsBetweenInt8AndMinusOneToOne() {
        #expect(BoatInput(rudder: 1.0).rudder == 127)
        #expect(BoatInput(rudder: -1.0).rudder == -127)
        #expect(BoatInput(rudder: 3.0).rudder == 127)
        #expect(BoatInput(rudder: 0.5).rudder == 64)
        #expect(BoatInput(rudder: Int8.min).rudder == -127)
        #expect(BoatInput(rudder: Int8(127)).rudderValue == 1)
        #expect(BoatInput(rudder: Int8(-127)).rudderValue == -1)
        #expect(BoatInput.neutral.rudderValue == 0)
    }

    @Test func outOfRangeRudderIsRejectedWhenDecoded() {
        let json = Data(#"{"tick": 1, "seat": 0, "rudder": -128, "ease": false}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(InputRecord.self, from: json) }
    }

    @Test func malformedInputRecordsAreRejected() throws {
        let malformed = [
            #"{"tick": 1, "seat": 0, "tap": "tackGybe", "rudder": 10, "ease": false}"#,
            #"{"tick": 1, "seat": 0, "tap": "protest", "target": 2, "ease": true}"#,
            #"{"tick": 1, "seat": 0, "tap": "tackGybe", "target": 2}"#,
            #"{"tick": 1, "seat": 0, "tap": "protest"}"#,
            #"{"tick": 1, "seat": 0, "rudder": 10, "ease": false, "target": 2}"#,
            #"{"tick": 1, "seat": 0, "tap": null, "rudder": 10, "ease": false}"#,
            #"{"tick": 1, "seat": 0, "rudder": 10}"#,
            #"{"tick": 1, "seat": 0, "tap": "gybe"}"#,
        ]
        for json in malformed {
            #expect(throws: DecodingError.self, "\(json)") { try JSONDecoder().decode(InputRecord.self, from: Data(json.utf8)) }
        }
        let wellFormed = [
            #"{"tick": 1, "seat": 0, "rudder": 10, "ease": false}"#,
            #"{"tick": 1, "seat": 0, "tap": "tackGybe"}"#,
            #"{"tick": 1, "seat": 0, "tap": "protest", "target": 2}"#,
        ]
        for json in wellFormed {
            _ = try JSONDecoder().decode(InputRecord.self, from: Data(json.utf8))
        }
    }

    @Test func heldInputStampedTAppliesFromTickT() {
        let race = testRace(seats: [.human, .human], seed: 5, brains: [])
        let t = race.tick + 10
        let input = BoatInput(rudder: Int8(127), ease: true)
        #expect(race.apply(input, seat: 0, atTick: t) == t)

        for _ in 0..<9 { race.step() }
        #expect(race.tick == t - 1)
        #expect(race.heldInputs[0] == .neutral)
        #expect(race.boats[0].desiredRudder == 0)

        race.step()
        #expect(race.heldInputs[0] == input)
        #expect(race.boats[0].desiredRudder == 1)

        for _ in 0..<30 { race.step() }
        #expect(race.heldInputs[0] == input, "held until the seat sends another")
        #expect(race.log.inputs == [InputRecord(tick: t, seat: 0, kind: .held(input))])
    }

    @Test func lateInputAppliesAtTheNextTickAndIsLoggedThere() {
        let race = testRace(seats: [.human, .human], seed: 5, brains: [])
        for _ in 0..<5 { race.step() }
        let next = race.tick + 1
        #expect(race.apply(BoatInput(rudder: -0.5), seat: 1, atTick: race.tick - 3) == next)
        race.step()
        #expect(race.log.inputs.map(\.tick) == [next])
    }

    @Test func unchangedHeldInputIsNotLoggedAgain() {
        let race = testRace(seats: [.human, .human], seed: 5, brains: [])
        let input = BoatInput(rudder: 0.25)
        for _ in 0..<20 {
            race.apply(input, seat: 0, atTick: race.tick + 1)
            race.apply(input, seat: 0, atTick: race.tick + 1)
            race.step()
        }
        #expect(race.log.inputs.count == 1)
    }

    @Test func tapAppliesOnce() {
        let race = testRace(seats: [.human, .human], seed: 3, brains: [])
        let t = race.tick + 10
        #expect(race.tap(.tackGybe, seat: 0, atTick: t) == t)
        #expect(race.tap(.protest(target: 1), seat: 0, atTick: t) == t)

        var autopilotStarts: [Int] = []
        var protests: [RaceEvent] = []
        var engaged = false
        for _ in 0..<(Race.tickRate * 10) {
            race.step()
            let now = race.boats[0].autopilot != nil
            if now && !engaged { autopilotStarts.append(race.tick) }
            engaged = now
            protests += race.drainEvents().filter { $0.kind == .protest(seat: 0, target: 1) }
        }
        #expect(autopilotStarts == [t])
        #expect(!engaged, "the tack finished and wasn't started again")
        #expect(protests == [RaceEvent(tick: t, kind: .protest(seat: 0, target: 1))])
        #expect(race.log.inputs == [
            InputRecord(tick: t, seat: 0, kind: .tap(.tackGybe)),
            InputRecord(tick: t, seat: 0, kind: .tap(.protest(target: 1))),
        ])
    }

    @Test func rudderInputCancelsTheTackAutopilot() {
        let race = testRace(seats: [.human, .human], seed: 3, brains: [])
        let t = race.tick + 1
        race.tap(.tackGybe, seat: 0, atTick: t)
        race.apply(BoatInput(rudder: 0.5), seat: 0, atTick: t + 5)
        for _ in 0..<5 { race.step() }
        #expect(race.boats[0].autopilot != nil)
        race.step()
        #expect(race.boats[0].autopilot == nil)
        #expect(race.boats[0].desiredRudder == BoatInput(rudder: 0.5).rudderValue)
    }

    @Test func badInputsAreRejected() {
        let race = testRace(seats: [.human, .bot], seed: 3)
        #expect(race.apply(.neutral, seat: 2, atTick: race.tick + 1) == nil)
        #expect(race.apply(.neutral, seat: -1, atTick: race.tick + 1) == nil)
        #expect(race.apply(.neutral, seat: 1, atTick: race.tick + 1) == nil, "seat 1 is sailed by a brain")
        #expect(race.tap(.protest(target: 0), seat: 0, atTick: race.tick + 1) == nil)
        #expect(race.tap(.protest(target: 5), seat: 0, atTick: race.tick + 1) == nil)
        #expect(race.record(.left, seat: 9) == nil)
    }

    @Test func easeSlowsTheBoat() {
        let eased = testRace(seats: [.human, .human], seed: 8, brains: [])
        let sailing = testRace(seats: [.human, .human], seed: 8, brains: [])
        eased.apply(BoatInput(rudder: Int8(0), ease: true), seat: 0, atTick: eased.tick + 1)
        for _ in 0..<(Race.tickRate * 10) {
            eased.step()
            sailing.step()
        }
        #expect(eased.boats[0].speed < sailing.boats[0].speed * 0.5)
    }
}

@Suite struct RaceLogTests {
    @Test func raceLogJSONRoundTripIsEqual() throws {
        let fixture = try ScriptedLog.fixture()
        #expect(try RaceLog(jsonData: fixture.jsonData()) == fixture)
        #expect(try RaceLog(jsonData: fixture.jsonData(pretty: false)) == fixture)

        let file = FileRef(id: "ilca-dinghy", version: 1, hash: ContentHash(of: Data("class".utf8)))
        let setup = try RaceSetup(raceSeed: RaceSeed(.max), seats: [.human, .bot], laps: 1, startSequenceTicks: 90,
                                  boatClass: file, venue: FileRef(id: "dev-venue", version: 1, hash: ContentHash(of: Data("venue".utf8))),
                                  conditions: nil, rulesConfiguration: FileRef(id: "rules", version: 3, hash: ContentHash(of: Data("rules".utf8))))
        let log = RaceLog(
            header: .init(setup: setup, windSeed: WindSeed(0xFFFF_FFFF_FFFF_FFFE)),
            inputs: [
                InputRecord(tick: -89, seat: 0, kind: .held(BoatInput(rudder: Int8(-127), ease: true))),
                InputRecord(tick: -89, seat: 0, kind: .tap(.tackGybe)),
                InputRecord(tick: 4, seat: 1, kind: .tap(.protest(target: 0))),
            ],
            seatEvents: [
                SeatEvent(tick: -90, seat: 0, kind: .joined(.human)),
                SeatEvent(tick: -90, seat: 1, kind: .joined(.bot)),
                SeatEvent(tick: -50, seat: 0, kind: .disconnected),
                SeatEvent(tick: -35, seat: 0, kind: .dropped),
                SeatEvent(tick: -35, seat: 0, kind: .botTookOver(.cautious)),
                SeatEvent(tick: -10, seat: 0, kind: .rejoined),
                SeatEvent(tick: -5, seat: 1, kind: .leftBeforeGun),
                SeatEvent(tick: -5, seat: 1, kind: .botTookOver(.fleet)),
                SeatEvent(tick: 7, seat: 0, kind: .left),
            ],
            finalTick: 8
        )
        let data = try log.jsonData()
        #expect(try RaceLog(jsonData: data) == log)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""raceSeed" : "0xffffffffffffffff""#))
        #expect(text.contains(#""windSeed" : "0xfffffffffffffffe""#))
        #expect(text.contains(#""hash" : "\#(file.hash.hex)""#), "FileRef keeps #58's {id, version, hash} shape")
    }

    /// The checked-in fixture is exactly what the script records.
    @Test func fixtureIsTheScript() throws {
        let scripted = try ScriptedLog.make()
        if ProcessInfo.processInfo.environment["REGATTA_WRITE_REPLAY_FIXTURE"] == "1" {
            try scripted.jsonData().write(to: ScriptedLog.fixtureURL)
        }
        let fixture = try ScriptedLog.fixture()
        #expect(fixture == scripted)
        #expect(fixture.header.setup.fleetSize == 16)
        #expect(fixture.finalTick == ScriptedLog.ticks - ScriptedLog.startSequenceTicks)
    }

    /// Replaying the fixture reproduces its log exactly: the log is the inputs as applied.
    @Test func replayingTheFixtureReproducesItsLog() throws {
        let fixture = try ScriptedLog.fixture()
        let race = try Replayer.replay(fixture, requireMatchingVersion: false)
        #expect(race.tick == fixture.finalTick)
        #expect(race.log.inputs == fixture.inputs)
        #expect(race.log.seatEvents == fixture.seatEvents)
    }

    /// A live race whose bots are sailed by brains replays, with no brains, to the same digest (ADR 0002).
    @Test func liveRaceWithBrainsReplaysWithoutThem() throws {
        let race = testRace(opponents: 7, prestartSeconds: 30, seed: 42)
        for seat in race.boats.indices { race.record(.joined(race.setup.seats[seat]), seat: seat) }
        var rng = SplitMix64(seed: 9)
        for step in 0..<(Race.tickRate * 80) {
            if step % 40 == 0 {
                race.apply(BoatInput(rudder: Int8(rng.int(in: -60...60)), ease: step < 300), seat: 0, atTick: race.tick + 1)
            }
            if step == 1200 { race.tap(.tackGybe, seat: 0, atTick: race.tick + 2) }
            if step == 1300 { race.tap(.protest(target: 3), seat: 0, atTick: race.tick + 1) }
            race.step()
        }
        race.record(.left, seat: 0)

        let log = race.log
        let replayed = try Replayer.replay(log)
        #expect(replayed.digest() == race.digest())
        #expect(replayed.log == log)
        #expect(log.inputs.contains { $0.seat == 4 }, "brain inputs are logged")
    }

    @Test func replayRefusesAnotherSimulationVersion() throws {
        let fixture = try ScriptedLog.fixture()
        let setup = try RaceSetup(simulationVersion: "0/elsewhere", raceSeed: fixture.header.raceSeed,
                                  seats: fixture.header.setup.seats)
        var log = fixture
        log.header.setup = setup
        #expect(throws: ReplayError.simulationVersion(log: "0/elsewhere", build: simulationVersion)) {
            try Replayer.replay(log)
        }
    }

    @Test func replayRejectsMalformedLogs() throws {
        let setup = try RaceSetup(raceSeed: RaceSeed(1), seats: [.human, .bot], startSequenceTicks: 30)
        let header = RaceLog.Header(setup: setup, windSeed: WindSeed(2))
        let outOfOrder = RaceLog(header: header, inputs: [
            InputRecord(tick: -10, seat: 0, kind: .held(BoatInput(rudder: 0.5))),
            InputRecord(tick: -20, seat: 0, kind: .held(.neutral)),
        ], finalTick: 0)
        #expect(throws: ReplayError.outOfOrderInput(index: 1)) { try Replayer.replay(outOfOrder) }

        let pastTheEnd = RaceLog(header: header, inputs: [InputRecord(tick: 5, seat: 0, kind: .tap(.tackGybe))], finalTick: 0)
        #expect(throws: ReplayError.outOfOrderInput(index: 0)) { try Replayer.replay(pastTheEnd) }

        let badSeat = RaceLog(header: header, inputs: [InputRecord(tick: -5, seat: 7, kind: .tap(.tackGybe))], finalTick: 0)
        #expect(throws: ReplayError.rejectedInput(index: 0)) { try Replayer.replay(badSeat) }

        let early = RaceLog(header: header, finalTick: -31)
        #expect(throws: ReplayError.finalTickBeforeStart(-31)) { try Replayer.replay(early) }
    }
}
