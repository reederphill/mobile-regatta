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
    /// The copy takes the original's umpire memory first: which incidents are open is never world state
    /// (#88), so without it the copy could call a pair the original, still inside their incident, doesn't.
    static func expectSameFuture(_ original: Race, _ copy: Race, steps: Int, feeder: LogFeeder = feeder,
                                 sourceLocation: SourceLocation = #_sourceLocation) {
        copy.umpire = original.umpire
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
        #expect(copy.incidents == original.incidents, sourceLocation: sourceLocation)
    }

    /// The acceptance test: import(export(s)) then N steps == stepping s N steps, by digest, across the
    /// sequence, the gun, starts, OCS returns and roundings of the golden 16-seat race (its log ends 100 s
    /// after the gun, before anyone finishes).
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
            if !snapshot.touchingBoats.isEmpty { found = snapshot; break }
        }
        let snapshot = try #require(found, "the golden race has no boat contact")
        _ = race.drainEvents()
        Self.expectSameFuture(race, try Self.imported(snapshot), steps: 300)

        // Dropping the contact memory changes the future: the contact would count as new again.
        var forgetful = snapshot
        forgetful.touchingBoats = []
        let original = try Self.imported(snapshot)
        let copy = try Self.imported(forgetful)
        Self.feeder.step(original)
        Self.feeder.step(copy)
        #expect(copy.digest() != original.digest())
    }

    /// A rule call carries its incident's id, so a race imported after incidents goes on numbering from
    /// where the original was, not from 0. The test sails on 10 s past the golden race's first call and puts
    /// the two boats back as they were the tick before it, overlap and all, in a race that imports that: its
    /// umpire holds no incident open (`UmpireState` is never in a snapshot), so the pair is called again.
    @Test func importAfterIncidentsNumbersTheNextCallOn() throws {
        let race = Self.feeder.race(at: -1800)
        var firstCall: RuleCall?
        while race.tick < Self.log.finalTick && firstCall == nil {
            Self.feeder.step(race)
            for event in race.drainEvents() { if case .ruleCall(let call) = event.kind { firstCall = call } }
        }
        let call = try #require(firstCall, "the golden race has no rule call")
        let before = Self.feeder.race(at: call.tick - 1).exportSnapshot()
        var aimed = Self.feeder.race(at: call.tick + 10 * Race.tickRate).exportSnapshot()
        let incidentsBefore = aimed.incidents.count
        #expect(incidentsBefore > 0)
        let pair = WorldSnapshot.SeatPair(min(call.offender, call.victim), max(call.offender, call.victim))
        for seat in [call.offender, call.victim] { aimed.seats[seat] = before.seats[seat] }
        aimed.touchingBoats.removeAll { $0 == pair }
        aimed.overlaps = (aimed.overlaps.filter { $0.pair != pair } + before.overlaps.filter { $0.pair == pair })
            .sorted { ($0.pair.a, $0.pair.b) < ($1.pair.a, $1.pair.b) }
        let original = try Self.imported(aimed)
        let copy = try Self.imported(original.exportSnapshot())

        Self.feeder.step(original)
        Self.feeder.step(copy)
        let ids = { (race: Race) in
            race.drainEvents().compactMap { event -> Int? in
                if case .ruleCall(let call) = event.kind { return call.incidentId } else { return nil }
            }
        }
        #expect(ids(original) == [incidentsBefore])
        #expect(ids(copy) == [incidentsBefore])
        Self.expectSameFuture(original, copy, steps: 300)

        // Without the incidents the call would reuse id 0.
        var forgetful = aimed
        forgetful.incidents = IncidentIndex()
        let amnesiac = try Self.imported(forgetful)
        Self.feeder.step(amnesiac)
        #expect(ids(amnesiac) == [0])
    }

    @Test func importMidObstacleContactMatches() throws {
        // The golden race never touches a mark, so sail seat 0 into the pin: an import is a fine way to put her there.
        let race = Self.feeder.race(at: -1800)
        var aimed = race.exportSnapshot()
        let heading = Double.pi / 3
        aimed.seats[0].boat.position = race.course.startLine.pin.position - Vec2.heading(heading) * 3.4
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
        // Keys below the first window the wind needs aren't: the window before the snapshot's, or further
        // back for puffs that may still be alive (#76), three windows for classic oscillating's 90 s.
        let later = Self.feeder.race(at: 2900).exportSnapshot()
        let laterWindow = race.wind.windows.window(containing: 2900)
        let firstNeeded = race.wind.firstWindowNeeded(atTick: 2900)
        #expect(firstNeeded == laterWindow - 3)
        var recent = later
        for window in 0..<firstNeeded { recent.windKeys.remove(window: window) }
        let fromRecent = try Self.imported(recent)
        for _ in 0..<1200 { Self.feeder.step(fromRecent) }
        var tooRecent = recent
        tooRecent.windKeys.remove(window: firstNeeded)
        #expect(throws: WorldSnapshotError.missingWindKey(firstNeeded)) { try Self.imported(tooRecent) }

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
        #expect(a.touchingEdges == b.touchingEdges)
        #expect(a.incidents == b.incidents)
        #expect(a.firstFinishTime == b.firstFinishTime)
        #expect(a.isOver == b.isOver)
        #expect(a.windKeys == b.windKeys)
        #expect(a.seats.map(\.heldInput) == b.seats.map(\.heldInput))
        // Every stored boat field, bit for bit: the description prints each Double in full.
        #expect(a.seats.map { String(describing: $0.boat) } == b.seats.map { String(describing: $0.boat) })
    }

    /// #248: planing, the spinnaker mid-hoist and the averaged groove wind are world state: an import
    /// carries them, and a race that imports goes on exactly like the one that exported.
    @Test func importCarriesPlaningTheSpinnakerAndTheAveragedWind() throws {
        let original = Self.feeder.race(at: 600)
        var snapshot = original.exportSnapshot()
        snapshot.seats[4].boat.isPlaning = !snapshot.seats[4].boat.isPlaning
        snapshot.seats[4].boat.spinnaker = .hoisting(remaining: 1.5)
        snapshot.seats[4].boat.averagedWindSpeed = (snapshot.seats[4].boat.averagedWindSpeed ?? 4) + 1
        try original.importSnapshot(snapshot)
        let copy = try Self.imported(original.exportSnapshot())
        copy.umpire = original.umpire // not world state (#88)
        #expect(copy.boats[4].spinnaker == .hoisting(remaining: 1.5))
        #expect(copy.boats[4].averagedWindSpeed == snapshot.seats[4].boat.averagedWindSpeed)
        #expect(copy.digest() == original.digest())
        for _ in 0..<300 {
            original.step()
            copy.step()
            #expect(copy.digest() == original.digest())
        }
        var changed = original.exportSnapshot()
        changed.seats[4].boat.spinnaker = .dropping(remaining: 0.7)
        let other = try Self.imported(changed)
        #expect(other.digest() != original.digest(), "the spinnaker is in the digest")
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
        // Edge contacts: a seat outside the fleet, out of order, repeated.
        for bad: [WorldSnapshot.EdgeContact] in [
            [.init(seat: 16, kind: .land)],
            [.init(seat: 1, kind: .boundary), .init(seat: 1, kind: .land)],
            [.init(seat: 2, kind: .land), .init(seat: 1, kind: .land)],
            [.init(seat: 1, kind: .land), .init(seat: 1, kind: .land)],
        ] {
            var edge = good
            edge.touchingEdges = bad
            #expect(throws: WorldSnapshotError.invalidContact) { try Self.imported(edge) }
        }
        var edges = good
        edges.touchingEdges = [.init(seat: 1, kind: .land), .init(seat: 1, kind: .boundary), .init(seat: 4, kind: .land)]
        _ = try Self.imported(edges)

        let lastLeg = race.course.legs.count - 1
        // Seats outside the fleet, a tick after the snapshot's, a leg the course doesn't have.
        let badIncidents = [(0, 16, good.tick, 0), (-1, 2, good.tick, 0), (0, 1, good.tick + 1, 0), (0, 1, good.tick, lastLeg + 1)]
        for (a, b, tick, leg) in badIncidents {
            var incident = good
            incident.incidents.open(between: 2, and: 3, tick: good.tick, leg: lastLeg) // valid: the error names the next
            incident.incidents.open(between: a, and: b, tick: tick, leg: leg)
            #expect(throws: WorldSnapshotError.invalidIncident(id: 1)) { try Self.imported(incident) }
        }

        // Obstruction contacts: a seat outside the fleet, a tick after the snapshot's, a leg the course doesn't have.
        let badContacts = [(16, good.tick, 0), (-1, good.tick, 0), (0, good.tick + 1, 0), (0, good.tick, lastLeg + 1)]
        for (seat, tick, leg) in badContacts {
            var contact = good
            contact.incidents.recordObstructionContact(.init(tick: good.tick, leg: lastLeg, seat: 3, kind: .land))
            contact.incidents.recordObstructionContact(.init(tick: tick, leg: leg, seat: seat, kind: .boundary))
            #expect(throws: WorldSnapshotError.invalidObstructionContact(index: 1)) { try Self.imported(contact) }
        }

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
            // #89: a clock exactly while a turn is owed, not after the snapshot's tick; queued calls fewer than
            // the turns owed, in order, and not after the tick either.
            ("penaltyClockTick", { $0.penaltyTurnsOwed = 1; $0.penaltyClockTick = nil }),
            ("penaltyClockTick", { $0.penaltyTurnsOwed = 0; $0.penaltyClockTick = good.tick }),
            ("penaltyClockTick", { $0.penaltyTurnsOwed = 1; $0.penaltyClockTick = good.tick + 1 }),
            ("penaltyClockTick", { $0.penaltyTurnsOwed = 1; $0.penaltyClockTick = -race.setup.startSequenceTicks - 1 }),
            ("queuedPenaltyCallTicks", { $0.queuedPenaltyCallTicks = [good.tick] }),
            ("queuedPenaltyCallTicks", { $0.penaltyTurnsOwed = 2; $0.penaltyClockTick = good.tick; $0.queuedPenaltyCallTicks = [good.tick - 2, good.tick - 1] }),
            ("queuedPenaltyCallTicks", { $0.penaltyTurnsOwed = 3; $0.penaltyClockTick = good.tick; $0.queuedPenaltyCallTicks = [good.tick - 1, good.tick - 2] }),
            ("queuedPenaltyCallTicks", { $0.penaltyTurnsOwed = 2; $0.penaltyClockTick = good.tick; $0.queuedPenaltyCallTicks = [good.tick + 1] }),
            ("position.x", { $0.position.x = .nan }),
            ("heading", { $0.heading = .infinity }),
            ("speed", { $0.speed = .nan }),
            ("autohelm", { $0.autohelm = Autohelm(target: .angle(-.infinity)) }),
            ("penaltyProgress", { $0.penaltyProgress = .nan }),
            ("shadow", { $0.shadow = .nan }),
            ("finishTime", { $0.finishTime = .nan }),
            ("averagedWindSpeed", { $0.averagedWindSpeed = .infinity }),
            ("spinnaker", { $0.spinnaker = .hoisting(remaining: .nan) }),
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
        "tick", "boats", "heldInputs", "boatContacts", "obstacleContacts", "edgeContacts", "incidents",
        "firstFinishTime",
        "isOver",
        "results", // a closed race can't score itself again: the seat events it reads aren't world state
        "overlaps", // as the pairs overlapped or changing
        "wind", // as its keys, `windKeys`; its setup and window grid are fixed for the race
    ]

    /// Race properties deliberately left out, and why.
    static let excluded: [String: String] = [
        "setup": "fixed for the race; the importing race is built from the same setup",
        "windSeed": "secret key, never in a snapshot (ADR 0001); the importing race has its own wind",
        "course": "fixed for the race, derived from the setup",
        "legTargets": "fixed for the race, derived from the course",
        "remainingAfterTarget": "fixed for the race, derived from the course",
        "ladderAxis": "fixed for the race, derived from the course",
        "isReachLeg": "fixed for the race, derived from the course",
        "ladderAfterTarget": "fixed for the race, derived from the course",
        "allGoneClose": "the race log, not world state; the results it made are carried (`results`)",
        "files": "fixed for the race: the class, venue, conditions and rules configuration the setup names (ADR 0004)",
        "current": "fixed for the race, derived from the venue and the public race seed",
        "tideStateAtGun": "fixed for the race, drawn from the venue and the public race seed (ADR 0003)",
        "umpire": "umpire memory (which incidents are open, #88; rule 18 records and zone presence, #91; the recorded track the escape simulation reads, #92), the authoritative race's own, never sent to clients, in a snapshot or in the digest",
        "windSetup": "fixed for the race, drawn from the public race seed",
        "windKeys": "the key generator: it holds the wind seed, never in a snapshot (ADR 0001); import moves it past the snapshot's keys",
        "finishers": "derived on import: the count of finished boats",
        "pending": "inputs not yet applied are not world state; import drops them",
        "events": "undrained output, not state; import drops them",
        "appliedInputs": "the race log, not world state",
        "seatEvents": "the race log, not world state",
        "pressureMapDrawn": "the seat views' pressure map kept until its next refresh (#290): drawn from the wind, not world state; import drops it",
        "scriptedWind": "a test's wind in place of the keyed wind, fixed at construction like the setup (`Race.init(setup:files:mode:current:wind:)`)",
    ]

    /// The start state (#85) travels in the snapshot: OCS and started are the boat's status, and returning
    /// (`CourseLayout.isReturning`) is derived from it and her motion, so an import agrees on all three and
    /// clears on the same tick. Nothing new is stored on `Race` or `Boat` for them.
    @Test func startStateTravelsInTheSnapshot() throws {
        // Running back down the axis at the line's centre, half a metre below it: her stern is over at the gun.
        let original = try raceEdited { boat, race in
            boat.heading = race.course.axis + .pi + 0.3
            boat.boomSide = .port
            boat.speed = 2
            boat.position = race.course.startLine.centre - race.course.upwind * 0.5
        }
        original.step()
        #expect(original.drainEvents().map(\.kind).contains(.ocsNotice(recipient: 0)))
        let copy = testRace(seats: [.human, .human], prestartSeconds: 1, seed: 5)
        try copy.importSnapshot(original.exportSnapshot())
        var wasReturning = false
        for _ in 0..<60 {
            #expect(copy.boats.map(\.status) == original.boats.map(\.status))
            #expect(copy.boats.map(copy.course.isReturning) == original.boats.map(original.course.isReturning))
            wasReturning = wasReturning || original.course.isReturning(original.boats[0])
            original.step()
            copy.step()
            #expect(copy.digest() == original.digest())
            #expect(copy.drainEvents() == original.drainEvents())
        }
        #expect(wasReturning)
        #expect(original.boats[0].status == .prestart)
    }

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
