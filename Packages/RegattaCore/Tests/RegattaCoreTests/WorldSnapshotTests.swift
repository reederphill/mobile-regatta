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
            if !snapshot.touchingBoats.isEmpty && !snapshot.foulMemory.isEmpty { found = snapshot; break }
        }
        let snapshot = try #require(found, "the golden race has no boat contact")
        _ = race.drainEvents()
        Self.expectSameFuture(race, try Self.imported(snapshot), steps: 300)

        // Dropping the contact memory changes the future: the contact would count as new again.
        var forgetful = snapshot
        forgetful.touchingBoats = []
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
            if !snapshot.touchingObstacles.isEmpty { found = snapshot; break }
        }
        let snapshot = try #require(found, "the golden race has no mark contact")
        _ = race.drainEvents()
        Self.expectSameFuture(race, try Self.imported(snapshot), steps: 300)
    }

    /// A client imports the server's world at an earlier tick than its own, a window earlier, then
    /// predicts forward again across window boundaries: its key generator was ahead, so it is rebuilt.
    @Test func importingAnEarlierTickRewindsTheWind() throws {
        let server = Self.feeder.race(at: 1200)
        _ = server.drainEvents()
        let client = Self.feeder.race(at: 2000)
        #expect(client.wind.keys.endWindow > server.wind.keys.endWindow)
        try client.importSnapshot(server.exportSnapshot())
        #expect(client.tick == 1200)
        #expect(client.wind == server.wind)
        Self.expectSameFuture(server, client, steps: 1000)
        #expect(client.wind == server.wind)
        #expect(client.wind.keys.endWindow == client.wind.windows.window(containing: client.tick) + 1)
    }

    /// The wind is in a snapshot only as its keys (ADR 0001): enough of them to sample at its tick.
    @Test func theSnapshotCarriesTheKeysAndNeedsThem() throws {
        let race = Self.feeder.race(at: 450)
        _ = race.drainEvents()
        let snapshot = race.exportSnapshot()
        #expect(snapshot.windKeys == race.wind.keys)
        let current = race.wind.windows.window(containing: 450)
        #expect(snapshot.windKeys.endWindow == current + 1)

        var missing = snapshot
        missing.windKeys.remove(window: current)
        #expect(throws: WorldSnapshotError.missingWindKey(current)) { try Self.imported(missing) }
        missing = snapshot
        missing.windKeys = WindKeyChain()
        #expect(throws: WorldSnapshotError.self) { try Self.imported(missing) }

        // A gap between the current window and a key held further ahead would never be filled: the
        // race would trap when the clock reached it (the review's repro). Refused, race unchanged.
        let target = Race(setup: Self.log.header.setup, windSeed: Self.log.header.windSeed)
        let before = target.digest()
        var gapped = snapshot
        gapped.windKeys.insert(Self.feeder.race(at: 2900).wind.keys[current + 3]!)
        #expect(gapped.windKeys.endWindow == current + 4)
        #expect(throws: WorldSnapshotError.missingWindKey(current + 1)) { try target.importSnapshot(gapped) }
        #expect(target.digest() == before && target.tick == -1800)
        // Keys below the window before the snapshot's aren't needed.
        var recent = snapshot
        for window in 0..<(current - 1) { recent.windKeys.remove(window: window) }
        let fromRecent = try Self.imported(recent)
        for _ in 0..<1200 { Self.feeder.step(fromRecent) }

        // Keys revealed ahead (a client's) are kept, and the race makes no key it already holds.
        let ahead = Self.feeder.race(at: 1300).wind.keys
        #expect(ahead.endWindow == snapshot.windKeys.endWindow + 1)
        var withAhead = snapshot
        withAhead.windKeys = ahead
        let copy = try Self.imported(withAhead)
        #expect(copy.wind.keys == ahead)
        Self.expectSameFuture(race, copy, steps: 900)
        #expect(copy.wind == race.wind)
    }

    @Test func exportOfAnImportIsTheSameWorld() throws {
        let original = Self.feeder.race(at: 1500)
        let copy = try Self.imported(original.exportSnapshot())
        let a = original.exportSnapshot(), b = copy.exportSnapshot()
        #expect(a.tick == b.tick)
        #expect(a.touchingBoats == b.touchingBoats)
        #expect(a.touchingObstacles == b.touchingObstacles)
        #expect(a.foulMemory == b.foulMemory)
        #expect(a.firstFinishTime == b.firstFinishTime)
        #expect(a.isOver == b.isOver)
        #expect(a.windKeys == b.windKeys)
        #expect(a.seats.map(\.heldInput) == b.seats.map(\.heldInput))
        // Every stored boat field, bit for bit: the description prints each Double in full.
        #expect(a.seats.map { String(describing: $0.boat) } == b.seats.map { String(describing: $0.boat) })
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
            contact.touchingBoats = [bad]
            #expect(throws: WorldSnapshotError.invalidContact) { try Self.imported(contact) }
        }
        var obstacle = good
        obstacle.touchingObstacles = [.init(seat: 0, obstacle: 99)]
        #expect(throws: WorldSnapshotError.invalidContact) { try Self.imported(obstacle) }

        var late = good
        late.tick = WorldSnapshot.maxTick + 1
        #expect(throws: WorldSnapshotError.tickTooLate(WorldSnapshot.maxTick + 1)) { try Self.imported(late) }

        // Values the step would trap on or carry as NaN: each names its seat and field.
        let finishLeg = race.course.legs.count - 1
        let badBoats: [(String, (inout Boat) -> Void)] = [
            ("legIndex", { $0.legIndex = 200 }),
            ("legIndex", { $0.legIndex = -1 }),
            ("roundingStage", { $0.roundingStage = 2 }),
            ("roundingStage", { $0.roundingStage = -1 }),
            ("roundingStage", { $0.legIndex = finishLeg; $0.roundingStage = 1 }),
            ("penaltyTurnsOwed", { $0.penaltyTurnsOwed = -1 }),
            ("position.x", { $0.position.x = .nan }),
            ("heading", { $0.heading = .infinity }),
            ("speed", { $0.speed = .nan }),
            ("autopilot", { $0.autopilot = Autopilot(heading: -.infinity, boomSide: .port) }),
            ("penaltyProgress", { $0.penaltyProgress = .nan }),
            ("shadow", { $0.shadow = .nan }),
            ("finishTime", { $0.finishTime = .nan }),
        ]
        for (field, spoil) in badBoats {
            var bad = good
            spoil(&bad.seats[5].boat)
            #expect(throws: WorldSnapshotError.invalidBoat(seat: 5, field: field)) { try Self.imported(bad) }
        }
        var finishing = good
        finishing.seats[5].boat.legIndex = finishLeg
        _ = try Self.imported(finishing) // the finish leg itself is fine

        var badTime = good
        badTime.firstFinishTime = .nan
        #expect(throws: WorldSnapshotError.invalidTime) { try Self.imported(badTime) }
        badTime = good
        badTime.foulMemory = [.init(pair: .init(0, 1), time: .infinity)]
        #expect(throws: WorldSnapshotError.invalidTime) { try Self.imported(badTime) }

        // A rejected import leaves the race as it was, and it sails on.
        let digest = race.digest()
        #expect(throws: WorldSnapshotError.self) { try race.importSnapshot(short) }
        var crash = good
        crash.seats[1].boat.status = .racing
        crash.seats[1].boat.legIndex = 200
        #expect(throws: WorldSnapshotError.invalidBoat(seat: 1, field: "legIndex")) { try race.importSnapshot(crash) }
        #expect(race.digest() == digest)
        for _ in 0..<30 { race.step() }
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
        "wind", // as its keys, `windKeys`; its setup and window grid are fixed for the race
    ]

    /// Race properties deliberately left out, and why.
    static let excluded: [String: String] = [
        "setup": "fixed for the race; the importing race is built from the same setup",
        "windSeed": "secret key, never in a snapshot (ADR 0001); the importing race has its own wind",
        "course": "fixed for the race, derived from the setup",
        "boatClass": "fixed for the race: the class file (ADR 0004)",
        "windSetup": "fixed for the race, drawn from the public race seed",
        "windKeys": "the key generator: it holds the wind seed, never in a snapshot (ADR 0001); import moves it past the snapshot's keys",
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
