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
            let back = try snapshot.applied(to: world, tick: decoded.tick)
            for (a, b) in zip(world.seats, back.seats) { expectWithinSteps(a, b) }
            checked += 1
        }
        #expect(checked > 2000)
    }

    /// A merge overwrites only wire fields: the rest (roster, derived and event fields) and race-level
    /// state stay as the receiver has them.
    @Test func applyingKeepsTheReceiversExcludedFields() throws {
        var gen = Gen(seed: 0xE8C1)
        let sender = gen.world(seats: 8)
        var receiver = gen.world(seats: 8)
        receiver.firstFinishTime = 12
        receiver.isOver = true
        receiver.boatContacts = [.init(1, 2)]
        let merged = try Snapshot(world: sender).applied(to: receiver, tick: 77)
        #expect(merged.tick == 77)
        #expect(merged.firstFinishTime == 12 && merged.isOver && merged.boatContacts == [.init(1, 2)])
        for i in 0..<8 {
            let (m, r, s) = (merged.seats[i].boat, receiver.seats[i].boat, sender.seats[i].boat)
            #expect(m.name == r.name && m.isPlayer == r.isPlayer && m.colorIndex == r.colorIndex && m.id == r.id)
            #expect(m.desiredRudder == r.desiredRudder && m.windDirection == r.windDirection)
            #expect(m.windSpeed == r.windSpeed && m.shadow == r.shadow)
            #expect(m.finishTime == r.finishTime && m.place == r.place)
            expectWithinSteps(sender.seats[i], merged.seats[i])
            #expect(m.status == s.status)
        }
        #expect(throws: WorldSnapshotError.seatCount(expected: 7, found: 8)) {
            var short = receiver
            short.seats.removeLast()
            _ = try Snapshot(world: sender).applied(to: short, tick: 0)
        }
    }

    /// Importing a quantised snapshot predicts almost exactly like importing the exact world: over the
    /// 100 ms to the next snapshot, and well beyond it.
    @Test func quantisedImportPredictsCloseToTheExactWorld() throws {
        let server = botRace()
        var worst100ms = 0.0, worst1s = 0.0, samples = 0
        while !server.isOver && server.tick < 9000 {
            for _ in 0..<30 { server.step() }
            let world = server.exportSnapshot()
            let exact = Race(setup: server.setup, windSeed: server.windSeed)
            try exact.importSnapshot(world)
            let quantised = Race(setup: server.setup, windSeed: server.windSeed)
            let bytes = try Frame(seq: 0, tick: world.tick, message: .snapshot(Snapshot(world: world))).encoded()
            guard case .snapshot(let snapshot) = try Frame(decoding: bytes).message else { return }
            // Merged into the exact world, so only quantisation differs: a predicting client's own
            // excluded fields and contact memory are close to the server's, not exact.
            try quantised.importSnapshot(snapshot.applied(to: world, tick: world.tick))
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

        let client = Race(setup: server.setup, windSeed: server.windSeed)
        try client.importSnapshot(back.world(base: client.exportSnapshot(), tick: decoded.tick))
        #expect(client.tick == server.tick)
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
