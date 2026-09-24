import Foundation
import Testing
@testable import RegattaCore

/// Steps a race along a log: before each step, applies the log's inputs stamped for the next tick.
struct LogFeeder {
    let log: RaceLog

    func step(_ race: Race) {
        let next = race.tick + 1
        for record in log.inputs where record.tick == next {
            switch record.kind {
            case .held(let input): race.apply(input, seat: record.seat, atTick: next)
            case .tap(let tap): race.tap(tap, seat: record.seat, atTick: next)
            }
        }
        race.step()
    }

    /// The race at `tick`, fed from the start of the log.
    func race(at tick: Int) -> Race {
        let race = Race(setup: log.header.setup, windSeed: log.header.windSeed)
        while race.tick < tick { step(race) }
        return race
    }
}

@Suite struct WorldSnapshotTests {
    static let log = try! ScriptedLog.fixture()
    static let feeder = LogFeeder(log: log)

    /// A fresh race of the same setup and wind seed that imports `snapshot`.
    static func imported(_ snapshot: WorldSnapshot, log: RaceLog = log) throws -> Race {
        let race = Race(setup: log.header.setup, windSeed: log.header.windSeed)
        try race.importSnapshot(snapshot)
        return race
    }

    /// Steps both races `steps` ticks on the log's inputs, expecting equal digests and events every tick.
    static func expectSameFuture(_ original: Race, _ copy: Race, steps: Int, feeder: LogFeeder = feeder,
                                 sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(copy.digest() == original.digest(), "differs at import, tick \(original.tick)", sourceLocation: sourceLocation)
        for _ in 0..<steps {
            feeder.step(original)
            feeder.step(copy)
            guard copy.digest() == original.digest(), copy.drainEvents() == original.drainEvents() else {
                Issue.record("diverged at tick \(original.tick)", sourceLocation: sourceLocation)
                return
            }
        }
        #expect(copy.isOver == original.isOver, sourceLocation: sourceLocation)
        #expect(copy.firstFinishTime == original.firstFinishTime, sourceLocation: sourceLocation)
    }

    /// The acceptance test: import(export(s)) then N steps == stepping s N steps, by digest, across the
    /// sequence, the gun, starts, OCS returns, roundings and the finish of the golden 16-seat race.
    @Test(arguments: [-1800, -1799, -900, -1, 0, 1, 450, 1101, 1500, 2400])
    func importOfExportSteppedNTimesMatchesTheOriginal(tick: Int) throws {
        let original = Self.feeder.race(at: tick)
        _ = original.drainEvents()
        let copy = try Self.imported(original.exportSnapshot())
        Self.expectSameFuture(original, copy, steps: min(900, Self.log.finalTick - tick))
    }

    /// Contact memory is world state: a snapshot taken mid-contact must not hit the boats' speed again.
    @Test func importMidContactMatchesAndContactMemoryIsLoadBearing() throws {
        let race = Self.feeder.race(at: -1800)
        var found: WorldSnapshot?
        while race.tick < Self.log.finalTick {
            Self.feeder.step(race)
            let snapshot = race.exportSnapshot()
            if !snapshot.boatContacts.isEmpty && !snapshot.foulMemory.isEmpty { found = snapshot; break }
        }
        let snapshot = try #require(found, "the golden race has no boat contact")
        _ = race.drainEvents()
        Self.expectSameFuture(race, try Self.imported(snapshot), steps: 300)

        // Dropping the contact memory changes the future: the contact would count as new again.
        var forgetful = snapshot
        forgetful.boatContacts = []
        forgetful.foulMemory = []
        let original = try Self.imported(snapshot)
        let copy = try Self.imported(forgetful)
        Self.feeder.step(original)
        Self.feeder.step(copy)
        #expect(copy.digest() != original.digest())
    }

    @Test func importMidObstacleContactMatches() throws {
        // The golden race never touches a mark, so sail seat 0 into the pin: an import is a fine way to put her there.
        let race = Self.feeder.race(at: -1800)
        var aimed = race.exportSnapshot()
        let heading = Double.pi / 3
        aimed.seats[0].boat.position = race.course.pin - Vec2.heading(heading) * 3.4
        aimed.seats[0].boat.heading = heading
        aimed.seats[0].boat.speed = 3
        try race.importSnapshot(aimed)
        var found: WorldSnapshot?
        while race.tick < -1500 {
            Self.feeder.step(race)
            let snapshot = race.exportSnapshot()
            if !snapshot.obstacleContacts.isEmpty { found = snapshot; break }
        }
        let snapshot = try #require(found, "the golden race has no mark contact")
        _ = race.drainEvents()
        Self.expectSameFuture(race, try Self.imported(snapshot), steps: 300)
    }

    /// A client imports the server's world at an earlier tick than its own, then predicts forward again.
    @Test func importingAnEarlierTickRewindsTheWind() throws {
        let server = Self.feeder.race(at: 1200)
        _ = server.drainEvents()
        let client = Self.feeder.race(at: 1230)
        try client.importSnapshot(server.exportSnapshot())
        #expect(client.tick == 1200)
        #expect(client.wind.tick == server.wind.tick)
        Self.expectSameFuture(server, client, steps: 300)
    }

    @Test func exportOfAnImportIsTheSameWorld() throws {
        let original = Self.feeder.race(at: 1500)
        let copy = try Self.imported(original.exportSnapshot())
        let a = original.exportSnapshot(), b = copy.exportSnapshot()
        #expect(a.tick == b.tick)
        #expect(a.boatContacts == b.boatContacts)
        #expect(a.obstacleContacts == b.obstacleContacts)
        #expect(a.foulMemory == b.foulMemory)
        #expect(a.firstFinishTime == b.firstFinishTime)
        #expect(a.isOver == b.isOver)
        #expect(a.seats.map(\.heldInput) == b.seats.map(\.heldInput))
        // Every stored boat field, bit for bit: the description prints each Double in full.
        #expect(a.seats.map { String(describing: $0.boat) } == b.seats.map { String(describing: $0.boat) })
    }

    /// Bots are predicted like anyone else, on their held inputs (ADR 0005): a race without brains that
    /// imports a bot race and is fed the inputs the bots' brains applied follows it exactly.
    @Test func aBrainlessImportFedTheBotsAppliedInputsFollowsTheBotRace() throws {
        let botRace = testRace(opponents: 9, prestartSeconds: 30, seed: 63)
        for _ in 0..<1500 { botRace.step() }
        _ = botRace.drainEvents()
        let snapshot = botRace.exportSnapshot()
        let copy = Race(setup: botRace.setup, windSeed: botRace.windSeed)
        try copy.importSnapshot(snapshot)
        #expect(copy.digest() == botRace.digest())
        for _ in 0..<600 {
            botRace.step()
            for record in botRace.log.inputs where record.tick == copy.tick + 1 {
                if case .held(let input) = record.kind { copy.apply(input, seat: record.seat, atTick: record.tick) }
            }
            copy.step()
            #expect(copy.digest() == botRace.digest())
        }
    }

    @Test func invalidSnapshotsAreRejected() throws {
        let race = Self.feeder.race(at: -1700)
        let good = race.exportSnapshot()

        var short = good
        short.seats.removeLast()
        #expect(throws: WorldSnapshotError.seatCount(expected: 16, found: 15)) { try Self.imported(short) }

        var swapped = good
        swapped.seats.swapAt(2, 3)
        #expect(throws: WorldSnapshotError.boatID(seat: 2, found: 3)) { try Self.imported(swapped) }

        var early = good
        early.tick = -1801
        #expect(throws: WorldSnapshotError.tickBeforeStart(-1801)) { try Self.imported(early) }

        for bad in [WorldSnapshot.SeatPair(3, 3), .init(4, 2), .init(0, 16)] {
            var contact = good
            contact.boatContacts = [bad]
            #expect(throws: WorldSnapshotError.invalidContact) { try Self.imported(contact) }
        }
        var obstacle = good
        obstacle.obstacleContacts = [.init(seat: 0, obstacle: 99)]
        #expect(throws: WorldSnapshotError.invalidContact) { try Self.imported(obstacle) }

        // A rejected import leaves the race as it was.
        let digest = race.digest()
        #expect(throws: WorldSnapshotError.self) { try race.importSnapshot(short) }
        #expect(race.digest() == digest)
    }
}

/// The world snapshot must hold everything `Race` keeps that its future depends on. Every stored
/// property of `Race` is either carried by `WorldSnapshot` or excluded here with the reason. A new
/// stored property fails this test until it is listed: carried (extend `WorldSnapshot`, export and
/// import) or excluded.
@Suite struct WorldSnapshotCoverageTests {
    /// Race properties carried by `WorldSnapshot`.
    static let carried: Set<String> = [
        "tick", "boats", "heldInputs", "boatContacts", "obstacleContacts", "lastFoul", "firstFinishTime", "isOver",
    ]

    /// Race properties deliberately left out, and why.
    static let excluded: [String: String] = [
        "setup": "fixed for the race; the importing race is built from the same setup",
        "windSeed": "secret key, never in a snapshot (ADR 0001); the importing race has its own wind",
        "course": "fixed for the race, derived from the setup",
        "polar": "fixed for the race",
        "wind": "a function of the tick and the wind's keys (ADR 0001); import brings it to the snapshot's tick",
        "botBrainsInterval": "profiling hook, never changes output",
        "brains": "bot brains run only where the race is hosted; a boat's future is its held input (ADR 0005)",
        "finishers": "derived on import: the count of finished boats",
        "pending": "inputs not yet applied are not world state; import drops them",
        "events": "undrained output, not state; import drops them",
        "appliedInputs": "the race log, not world state",
        "seatEvents": "the race log, not world state",
    ]

    @Test func everyStoredRacePropertyIsCarriedOrExcluded() {
        let race = testRace(opponents: 3, seed: 1)
        let stored = Mirror(reflecting: race).children.compactMap(\.label)
        #expect(stored.count > 10)
        let unlisted = stored.filter { !Self.carried.contains($0) && Self.excluded[$0] == nil }
        #expect(unlisted == [], "Race gained stored state: carry it in WorldSnapshot or exclude it with a reason")
        let stale = (Self.carried.union(Self.excluded.keys)).filter { !stored.contains($0) }.sorted()
        #expect(stale == [], "listed properties Race no longer has")
        #expect(Self.carried.isDisjoint(with: Self.excluded.keys))
    }
}
