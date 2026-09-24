import RegattaCore
@testable import RegattaProtocol
import Testing

typealias Q = SnapshotQuantisation

/// The error bound of each wire field, keyed like `SnapshotFields.wire`: half its step, or exact.
let wireFieldBounds: [String: @Sendable (WorldSnapshot.Seat, WorldSnapshot.Seat) -> Bool] = [
    "boat.position": { abs($0.boat.position.x - $1.boat.position.x) <= Q.positionStep / 2
        && abs($0.boat.position.y - $1.boat.position.y) <= Q.positionStep / 2 },
    "boat.heading": { angleError($0.boat.heading, $1.boat.heading) <= Q.headingStep / 2 + 1e-12 },
    "boat.speed": { abs($0.boat.speed - $1.boat.speed) <= Q.speedStep / 2 },
    "boat.rudder": { abs($0.boat.rudder - $1.boat.rudder) <= Q.rudderStep / 2 + 1e-15 },
    "boat.autopilot": {
        switch ($0.boat.autopilot, $1.boat.autopilot) {
        case (nil, nil): true
        case let (a?, b?): angleError(a, b) <= Q.headingStep / 2 + 1e-12
        default: false
        }
    },
    "boat.penaltyProgress": { abs($0.boat.penaltyProgress - $1.boat.penaltyProgress) <= Q.penaltyProgressStep / 2 },
    "boat.status": { $0.boat.status == $1.boat.status },
    "boat.legIndex": { $0.boat.legIndex == $1.boat.legIndex },
    "boat.roundingStage": { $0.boat.roundingStage == $1.boat.roundingStage },
    "boat.penaltyTurnsOwed": { $0.boat.penaltyTurnsOwed == $1.boat.penaltyTurnsOwed },
    "boat.isTacking": { $0.boat.isTacking == $1.boat.isTacking },
    "heldInput.rudder": { $0.heldInput.rudder == $1.heldInput.rudder },
    "heldInput.ease": { $0.heldInput.ease == $1.heldInput.ease },
]

func angleError(_ a: Double, _ b: Double) -> Double { abs(wrapAngle(a - b)) }

func expectWithinSteps(_ original: WorldSnapshot.Seat, _ decoded: WorldSnapshot.Seat,
                       sourceLocation: SourceLocation = #_sourceLocation) {
    for field in SnapshotFields.wire {
        guard let within = wireFieldBounds[field] else {
            Issue.record("no error bound for wire field \(field)", sourceLocation: sourceLocation)
            continue
        }
        #expect(within(original, decoded), "\(field) outside its quantisation step: \(original.boat) vs \(decoded.boat)",
                sourceLocation: sourceLocation)
    }
}

/// Quantisation on real race states, and what it does to prediction (ADR 0005).
@Suite struct QuantisationTests {
    @Test func everyWireFieldHasAnErrorBound() {
        #expect(Set(wireFieldBounds.keys) == Set(SnapshotFields.wire))
    }

    @Test func stepsAreFineEnough() {
        #expect(Q.positionStep <= 0.004)             // < 4 mm
        #expect(Q.headingStep <= 0.0001)             // < 0.006°
        #expect(Q.speedStep <= 0.001)                // < 1 mm/s
        #expect(Q.rudderStep * 127 < 0.01)           // far finer than a held input's int8 step
        #expect(Q.penaltyProgressStep < 0.001)
        // Ranges: 5 penalty turns, the whole course area, a planing dinghy.
        #expect(32_767 * Q.penaltyProgressStep > 5 * 2 * .pi)
        #expect(Double(1 << 23) * Q.positionStep >= 32_768)
        #expect(65_535 * Q.speedStep > 60)
    }

    /// Every field of every seat of a real 16-boat race, at every 3rd tick, comes back within its step.
    @Test func realRaceSnapshotsAreWithinTheirSteps() throws {
        let race = botRace()
        var checked = 0
        while !race.isOver && race.tick < 9000 {
            for _ in 0..<3 { race.step() }
            let world = race.exportSnapshot()
            let frame = Frame(seq: UInt32(checked), tick: race.tick, message: .snapshot(try Snapshot(world: world)))
            let decoded = try Frame(decoding: frame.encoded())
            guard case .snapshot(let snapshot) = decoded.message else { Issue.record("not a snapshot"); return }
            let back = try snapshot.applied(to: world, tick: decoded.tick, events: EventState(world: world, nextEventSeq: 0))
            for (a, b) in zip(world.seats, back.seats) { expectWithinSteps(a, b) }
            checked += 1
        }
        #expect(checked > 2000)
    }

    /// A merge overwrites the wire fields from the snapshot and race-level state (finishes, first finish,
    /// the race's end) from the server's event state. The rest (roster, derived fields, contact and
    /// foul memory) stays as the receiver has it.
    @Test func applyingKeepsTheReceiversExcludedFields() throws {
        var gen = Gen(seed: 0xE8C1)
        let sender = gen.world(seats: 8)
        var receiver = gen.world(seats: 8)
        receiver.firstFinishTime = 12
        receiver.isOver = true
        receiver.touchingBoats = [.init(1, 2)]
        receiver.foulMemory = [.init(pair: .init(1, 2), time: 11)]
        let events = EventState(nextEventSeq: 9, finishes: [.init(seat: 3, place: 1, tick: 600)], firstFinishTick: 600)
        let merged = try Snapshot(world: sender).applied(to: receiver, tick: 77, events: events)
        #expect(merged.tick == 77)
        #expect(merged.firstFinishTime == 20 && !merged.isOver)
        #expect(merged.touchingBoats == [.init(1, 2)] && merged.foulMemory == receiver.foulMemory)
        for i in 0..<8 {
            let (m, r, s) = (merged.seats[i].boat, receiver.seats[i].boat, sender.seats[i].boat)
            #expect(m.isPlayer == r.isPlayer && m.colorIndex == r.colorIndex && m.id == r.id)
            #expect(m.desiredRudder == r.desiredRudder && m.windDirection == r.windDirection)
            #expect(m.windSpeed == r.windSpeed && m.shadow == r.shadow)
            #expect(m.place == (i == 3 ? 1 : nil))
            #expect(m.finishTime == (i == 3 ? 20 : nil))
            expectWithinSteps(sender.seats[i], merged.seats[i])
            #expect(m.status == s.status)
        }
        #expect(throws: WorldSnapshotError.seatCount(expected: 7, found: 8)) {
            var short = receiver
            short.seats.removeLast()
            _ = try Snapshot(world: sender).applied(to: short, tick: 0, events: events)
        }
        #expect(throws: WireError.invalidValue("finishes.seat")) {
            _ = try Snapshot(world: sender).applied(to: receiver, tick: 0, events: EventState(nextEventSeq: 0, finishes: [.init(seat: 8, place: 1, tick: 0)]))
        }
    }

    /// The freeze the review found: a client whose own prediction ended the race kept `isOver` through
    /// every snapshot, so it stopped predicting and refused inputs. The server's event state now wins.
    @Test func aClientThatWronglyEndedTheRaceRecoversAtTheNextSnapshot() throws {
        let server = botRace()
        var events = EventState(nextEventSeq: 1)
        func sail(_ ticks: Int) {
            for _ in 0..<ticks {
                server.step()
                for event in server.drainEvents() { events.record(event) }
            }
        }
        sail(600)
        var wrong = server.exportSnapshot()
        wrong.isOver = true
        wrong.firstFinishTime = 1
        let client = Race(setup: server.setup, windSeed: try #require(server.windSeed))
        try client.importSnapshot(wrong)
        #expect(client.apply(.neutral, seat: 0, atTick: client.tick + 1) == nil) // frozen

        sail(3)
        let snapshot = try Snapshot(world: server.exportSnapshot())
        try client.importSnapshot(snapshot.applied(to: client.exportSnapshot(), tick: server.tick, events: events))
        #expect(!client.isOver && client.firstFinishTime == nil)
        #expect(client.apply(.neutral, seat: 0, atTick: client.tick + 1) != nil)
        let tick = client.tick
        client.step()
        #expect(client.tick == tick + 1)
    }

    /// `EventState.record` of the reliable events keeps the same state the server's world has.
    @Test func recordedEventsMatchTheServersEventState() throws {
        let server = botRace()
        var events = EventState(nextEventSeq: 1)
        var checked = 0
        while !server.isOver && server.tick < 30_000 {
            server.step()
            for event in server.drainEvents() { events.record(event) }
            if server.tick % 90 == 0 {
                #expect(events == EventState(world: server.exportSnapshot(), nextEventSeq: 1))
                checked += 1
            }
        }
        #expect(server.isOver)
        #expect(events == EventState(world: server.exportSnapshot(), nextEventSeq: 1))
        #expect(!events.finishes.isEmpty && checked > 50)
    }

    /// The review's crash: a snapshot with a leg the course doesn't have decoded and imported, then
    /// trapped in the next step. The import now refuses it and the race is unchanged.
    @Test func aSnapshotTheRaceCantSailFromIsRefused() throws {
        var gen = Gen(seed: 1)
        var seats = gen.wireSeats(2)
        for i in seats.indices {
            seats[i].legIndex = 200
            seats[i].status = .racing
            seats[i].roundingStage = 0
            seats[i].x = 0
            seats[i].y = 0
        }
        let setup = try RaceSetup(raceSeed: RaceSeed(1), seats: [.human, .human], startSequenceTicks: 30)
        let race = Race(setup: setup, windSeed: WindSeed(2))
        for _ in 0..<40 { race.step() }
        let bytes = try Frame(seq: 0, tick: race.tick, message: .snapshot(Snapshot(seats: seats))).encoded()
        guard case .snapshot(let snapshot) = try Frame(decoding: bytes).message else { return }
        let base = race.exportSnapshot()
        let world = try snapshot.applied(to: base, tick: race.tick, events: EventState(world: base, nextEventSeq: 0))
        let digest = race.digest()
        #expect(throws: WorldSnapshotError.invalidBoat(seat: 0, field: "legIndex")) { try race.importSnapshot(world) }
        #expect(race.digest() == digest)
        race.step()
        #expect(race.tick == 11)
    }

    /// Importing a quantised snapshot predicts almost exactly like importing the exact world: over the
    /// 100 ms to the next snapshot, and well beyond it.
    @Test func quantisedImportPredictsCloseToTheExactWorld() throws {
        let server = botRace()
        var worst100ms = 0.0, worst1s = 0.0, samples = 0
        while !server.isOver && server.tick < 9000 {
            for _ in 0..<30 { server.step() }
            let world = server.exportSnapshot()
            let exact = Race(setup: server.setup, windSeed: try #require(server.windSeed))
            try exact.importSnapshot(world)
            let quantised = Race(setup: server.setup, windSeed: try #require(server.windSeed))
            let bytes = try Frame(seq: 0, tick: world.tick, message: .snapshot(Snapshot(world: world))).encoded()
            guard case .snapshot(let snapshot) = try Frame(decoding: bytes).message else { return }
            // Merged into the exact world, so only quantisation differs: a predicting client's own
            // excluded fields and contact memory are close to the server's, not exact.
            try quantised.importSnapshot(snapshot.applied(to: world, tick: world.tick, events: EventState(world: world, nextEventSeq: 0)))
            // Both hold every boat's last input, as a predicting client does.
            for step in 1...30 {
                exact.step()
                quantised.step()
                let error = zip(exact.boats, quantised.boats).map { ($0.position - $1.position).length }.max() ?? 0
                if step <= 3 { worst100ms = max(worst100ms, error) }
                worst1s = max(worst1s, error)
            }
            samples += 1
        }
        print("PREDICTION quantised-vs-exact worst position error: \(worst100ms) m over 3 ticks, \(worst1s) m over 30 ticks, \(samples) samples")
        #expect(samples > 100)
        // Steps are 3.9 mm and 0.0055°; a contact can amplify an error, so the bounds leave room.
        #expect(worst100ms < 0.05)
        // Far below a boat length (4.2 m), past which a client snaps visibly (ADR 0005).
        #expect(worst1s < 1)
    }

    /// A Resync rebuilds a fresh race's world: seats within their steps, finishes and the race's end exact.
    @Test func resyncRebuildsTheWorld() throws {
        let server = botRace()
        while !server.isOver && !server.boats.contains(where: { $0.status == .finished }) { server.step() }
        for _ in 0..<600 { server.step() }
        let world = server.exportSnapshot()
        #expect(world.seats.contains { $0.boat.place != nil })

        let resync = try Resync(raceSeed: server.setup.raceSeed, world: world, nextEventSeq: 42)
        let decoded = try Frame(decoding: Frame(seq: 0, tick: world.tick, message: .resync(resync)).encoded())
        guard case .resync(let back) = decoded.message else { Issue.record("not a resync"); return }
        #expect(back == resync)

        let client = Race(setup: server.setup, windSeed: try #require(server.windSeed))
        try client.importSnapshot(back.world(base: client.exportSnapshot(), tick: decoded.tick))
        #expect(client.tick == server.tick)
        #expect(client.wind == server.wind) // the revealed keys came with it
        #expect(client.firstFinishTime == server.firstFinishTime)
        #expect(client.isOver == server.isOver)
        let rebuilt = client.exportSnapshot()
        for (a, b) in zip(world.seats, rebuilt.seats) {
            expectWithinSteps(a, b)
            #expect(a.boat.place == b.boat.place)
            #expect(a.boat.finishTime == b.boat.finishTime)
        }
    }
}
