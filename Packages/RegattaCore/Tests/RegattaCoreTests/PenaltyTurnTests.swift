import Foundation
import Testing
@testable import RegattaCore

/// fleet-rules@3 in open water, as `openWaterRules` is fleet-rules@1, with `stacking` for its penalty deadlines.
func openWaterPenaltyRules(_ stacking: RulesConfig.StackedPenaltyDeadlines) -> RulesConfigFile {
    var text = String(decoding: try! RulesConfigFile.bundledData(id: "fleet-rules", version: 3)!, as: UTF8.self)
    for (old, new) in [(#""acrossAxisBeatFraction": 0.75"#, #""acrossAxisBeatFraction": 20"#),
                       (#""belowLineLineLengths": 1"#, #""belowLineLineLengths": 30"#),
                       (#""aboveWindwardBeatFraction": 0.25"#, #""aboveWindwardBeatFraction": 5"#),
                       (#""stackedPenaltyDeadlines": "sequential""#, #""stackedPenaltyDeadlines": "\#(stacking.rawValue)""#)] {
        precondition(text.components(separatedBy: old).count == 2, "fleet-rules@3's \(old) has moved")
        text = text.replacingOccurrences(of: old, with: new)
    }
    return try! RulesConfigFile(data: Data(text.utf8))
}

/// #89 acceptance: penalty turns (#9, G4, #219). One turn a call, 360° one way, started 30° by 15 s and
/// completed by 30 s after its clock starts, or DSQ and a ghost at that tick.
@Suite struct PenaltyTurnTests {
    static let start = 15 * Race.tickRate
    static let complete = 30 * Race.tickRate
    static let fullTurn = 2 * Double.pi
    /// A full turn at the dinghy's top turn rate (30°/s) takes 12 s, and the rudder a fifth of a second to go
    /// hard over (`rudderSlewPerSecond` 5): she can serve a turn no sooner than 12 s after the call, and
    /// turning flat out she does it in 12.2 s.
    static let twelveSeconds = 12 * Race.tickRate
    static let flatOut = twelveSeconds + Race.tickRate / 5

    /// A two-boat race in open water (`scriptedWindRace`) under fleet-rules@3 with `stacking`, in `wind`
    /// (10 kn from the north by default): seat 0 on starboard tack (boom to port) close reaching at 60° at
    /// the polar's speed, far from every mark and edge. One step in, her autohelm holds that angle.
    func race(_ stacking: RulesConfig.StackedPenaltyDeadlines = .sequential,
              wind: @escaping (Double) -> Wind = steadyWind(knots: 10)) throws -> Race {
        let race = try scriptedWindRace(rules: openWaterPenaltyRules(stacking), wind: wind) { boat, boatClass in
            let angle = deg2rad(60)
            boat.boomSide = .port
            boat.heading = wrapAngle(boat.windDirection - angle)
            boat.speed = boatClass.polar.speed(twa: angle, tws: boat.windSpeed)
        }
        race.step()
        #expect(race.boats[0].autohelm != nil && race.rules.raceFormat.penalty.stackedPenaltyDeadlines == stacking)
        _ = race.drainEvents()
        return race
    }

    /// Seat 0's held rudder from the next tick: off centre steers her by hand, 0 lets go to the autohelm.
    func helm(_ race: Race, _ rudder: Double) {
        #expect(race.apply(BoatInput(rudder: rudder), seat: 0, atTick: race.tick + 1) != nil)
    }

    /// One step, and the race's events from it.
    func step(_ race: Race) -> [RaceEvent.Kind] {
        race.step()
        return race.drainEvents().map(\.kind)
    }

    /// Steps until `until` holds after a step (at most `limit` ticks), calling `each` after every step; the
    /// events on the way, by tick.
    @discardableResult
    func steps(_ race: Race, limit: Int, until: (Race, [RaceEvent.Kind]) -> Bool = { _, _ in false },
               each: (Race, [RaceEvent.Kind]) -> Void = { _, _ in }) -> [(tick: Int, kinds: [RaceEvent.Kind])] {
        var log: [(tick: Int, kinds: [RaceEvent.Kind])] = []
        for _ in 0..<max(limit, 0) {
            let kinds = step(race)
            log.append((race.tick, kinds))
            each(race, kinds)
            if until(race, kinds) { break }
        }
        return log
    }

    static func served(_ kinds: [RaceEvent.Kind]) -> Bool { kinds.contains(.penaltyServed(seat: 0)) }
    static func disqualified(_ kinds: [RaceEvent.Kind]) -> Bool {
        kinds.contains { if case .disqualified(seat: 0, _) = $0 { true } else { false } }
    }

    // MARK: - Deadlines

    @Test func noTurningBy15sIsDSQAndGhost() throws {
        let race = try race()
        let call = race.tick
        #expect(race.penalize(0) == call)
        let status = race.boats[0].status
        #expect(race.owedPenalty(ofSeat: 0) == OwedPenalty(turnsOwed: 1, startDeadlineTick: call + Self.start,
                                                           completeDeadlineTick: call + Self.complete, progress: 0,
                                                           isStarted: false))
        // Holding her course on the autohelm, she never starts it.
        steps(race, limit: Self.start - 1, each: { race, kinds in
            #expect(!Self.disqualified(kinds) && race.boats[0].status == status)
        })
        #expect(race.tick == call + Self.start - 1 && race.boats[0].penaltyProgress == 0)
        let kinds = step(race)
        #expect(race.tick == call + Self.start)
        #expect(race.boats[0].status == .dsq && race.boats[0].isGhost && race.isGhost(seat: 0))
        let dsq = try #require(kinds.firstIndex(of: .disqualified(seat: 0, reason: Race.missedStart)))
        #expect(kinds[dsq + 1] == .becameGhost(seat: 0))
        #expect(race.boats[0].penaltyTurnsOwed == 0 && race.boats[0].penaltyClockTick == nil)
        #expect(race.owedPenalty(ofSeat: 0) == nil)
    }

    @Test func startedButIncompleteBy30sIsDSQ() throws {
        let race = try race()
        let call = race.tick
        race.penalize(0)
        // Bearing away by hand past 30°, then letting go: the autohelm holds her, part way round.
        helm(race, -1)
        let started = steps(race, limit: Self.start) { race, _ in abs(race.boats[0].penaltyProgress) >= deg2rad(60) }
        #expect(started.contains { $0.kinds.contains(.penaltyStarted(seat: 0)) })
        helm(race, 0)
        steps(race, limit: call + Self.complete - 1 - race.tick, each: { race, kinds in
            #expect(!Self.disqualified(kinds) && race.boats[0].penaltyTurnsOwed == 1)
        })
        #expect(race.tick == call + Self.complete - 1)
        let owed = try #require(race.owedPenalty(ofSeat: 0))
        #expect(owed.isStarted && owed.progress < Self.fullTurn && owed.completeDeadlineTick == call + Self.complete)
        let kinds = step(race)
        #expect(race.boats[0].status == .dsq && race.boats[0].isGhost)
        let dsq = try #require(kinds.firstIndex(of: .disqualified(seat: 0, reason: Race.missedComplete)))
        #expect(kinds[dsq + 1] == .becameGhost(seat: 0))
    }

    // MARK: - One way round

    @Test func reversalResetsProgress() throws {
        let race = try race()
        race.penalize(0)
        helm(race, 1)
        steps(race, limit: Self.complete) { race, _ in abs(race.boats[0].penaltyProgress) >= deg2rad(200) }
        let before = race.boats[0].penaltyProgress
        #expect(abs(before) >= deg2rad(200))
        // Hard the other way: once she turns back, the turn is given up.
        helm(race, -1)
        let log = steps(race, limit: 3 * Race.tickRate) { _, kinds in kinds.contains(.penaltyReset(seat: 0)) }
        let reset = try #require(log.last)
        #expect(reset.kinds.contains(.penaltyReset(seat: 0)))
        #expect(race.boats[0].penaltyProgress == 0 && race.boats[0].penaltyTurnsOwed == 1)
        #expect(!log.contains { Self.served($0.kinds) })
        // Turning on the new way counts afresh, the other way round.
        steps(race, limit: Race.tickRate)
        #expect(race.boats[0].penaltyProgress * before < 0)
        #expect(race.boats[0].penaltyTurnsOwed == 1)
    }

    @Test func fullTurnOneWayServes() throws {
        let race = try race()
        let call = race.tick
        race.penalize(0)
        helm(race, 1)
        var turned = 0.0
        var heading = race.boats[0].heading
        let log = steps(race, limit: Self.flatOut, until: { _, kinds in Self.served(kinds) }, each: { race, _ in
            turned += wrapAngle(race.boats[0].heading - heading)
            heading = race.boats[0].heading
        })
        let done = try #require(log.last)
        #expect(Self.served(done.kinds), "360° in 12 s, turning flat out from the call")
        #expect(done.tick >= call + Self.twelveSeconds && done.tick <= call + Self.flatOut)
        #expect(abs(turned) >= Self.fullTurn && abs(turned) < Self.fullTurn + deg2rad(2))
        // A tack and a gybe on the way; started once, served once, never given up or missed.
        let kinds = log.flatMap(\.kinds)
        #expect(kinds.contains(.tacked(seat: 0)) && kinds.contains(.gybed(seat: 0)))
        #expect(kinds.filter { $0 == .penaltyStarted(seat: 0) }.count == 1)
        #expect(kinds.filter { $0 == .penaltyServed(seat: 0) }.count == 1)
        #expect(!kinds.contains(.penaltyReset(seat: 0)) && !Self.disqualified(kinds))
        let boat = race.boats[0]
        #expect(boat.penaltyTurnsOwed == 0 && boat.penaltyProgress == 0 && boat.penaltyClockTick == nil)
        #expect(race.owedPenalty(ofSeat: 0) == nil && !boat.isGhost)
    }

    // MARK: - Owed turns

    /// Seat 0 placed on the first obstacle (a mark), with no touch remembered: she touches it on the next step
    /// and owes a turn for it (rule 31).
    func touchMark(_ race: Race) throws -> [RaceEvent.Kind] {
        var snapshot = race.exportSnapshot()
        snapshot.seats[0].boat.position = race.course.obstacles[0].position
        snapshot.touchingObstacles = []
        try race.importSnapshot(snapshot)
        return step(race)
    }

    @Test func owedTurnsAddUpWithNoCap() throws {
        let race = try race()
        let mark = race.course.obstacles[0].name
        // Two calls, two turns: the first is current, its clock from its call; the second queues behind it.
        var calls: [Int] = []
        for _ in 0..<2 {
            #expect(try touchMark(race).contains(.markTouch(seat: 0, mark: mark)))
            calls.append(race.tick)
        }
        #expect(race.boats[0].penaltyTurnsOwed == 2)
        #expect(race.boats[0].penaltyClockTick == calls[0] && race.boats[0].queuedPenaltyCallTicks == [calls[1]])
        #expect(race.owedPenalty(ofSeat: 0)?.turnsOwed == 2)
        // Past the old cap of 4, and on.
        for _ in 0..<4 {
            #expect(try touchMark(race).contains(.markTouch(seat: 0, mark: mark)))
            calls.append(race.tick)
        }
        for _ in 0..<4 {
            race.penalize(0)
            calls.append(race.tick)
        }
        #expect(race.boats[0].penaltyTurnsOwed == 10)
        #expect(race.boats[0].penaltyClockTick == calls[0] && race.boats[0].queuedPenaltyCallTicks == Array(calls.dropFirst()))
        let owed = try #require(race.owedPenalty(ofSeat: 0))
        #expect(owed.turnsOwed == 10 && owed.startDeadlineTick == calls[0] + Self.start)
    }

    @Test func finishingWhileOwingDoesNotFinish() throws {
        let race = testRace(seats: [.human, .human], prestartSeconds: 1, seed: 7)
        let finishLeg = race.course.legs.count - 1
        let line = race.course.finishLine
        let upwind = race.course.upwind
        func courseSide(_ p: Vec2) -> Bool { (p - line.centre).dot(upwind) > 0 }
        try jump(race, to: 2_999) { snapshot in
            placeToFinish(&snapshot.seats[0].boat, in: race, penaltyTurnsOwed: 1, penaltyClockTick: 2_999)
            snapshot.seats[0].heldInput = .neutral
        }
        // Owing a turn, she crosses the line and doesn't finish: still racing, on the finish leg.
        var kinds = step(race)
        #expect(!courseSide(race.boats[0].position), "she crossed the line")
        #expect(race.boats[0].status == .racing && race.boats[0].legIndex == finishLeg && race.boats[0].place == nil)
        #expect(race.firstFinishTime == nil && !kinds.contains { if case .finished = $0 { true } else { false } })
        #expect(race.boats[0].penaltyTurnsOwed == 1)

        // Back on the course side, she takes her turn there, all of it, within its deadlines...
        try jump(race, to: race.tick) { snapshot in
            var boat = snapshot.seats[0].boat
            boat.position = line.centre + upwind * 20
            boat.heading = wrapAngle(race.course.axis + .pi / 2)
            boat.speed = 4
            snapshot.seats[0].boat = boat
            snapshot.seats[0].heldInput = BoatInput(rudder: 1.0)
        }
        let log = steps(race, limit: Self.complete - 1, until: { _, kinds in Self.served(kinds) }, each: { race, _ in
            #expect(courseSide(race.boats[0].position))
        })
        #expect(log.last.map { Self.served($0.kinds) } == true)
        #expect(race.boats[0].status == .racing && race.boats[0].penaltyTurnsOwed == 0)

        // ...and crossing again, she finishes.
        try jump(race, to: race.tick) { snapshot in
            placeToFinish(&snapshot.seats[0].boat, in: race)
            snapshot.seats[0].heldInput = .neutral
        }
        kinds = step(race)
        #expect(race.boats[0].status == .finished && race.boats[0].place == 1)
        #expect(kinds.contains(.finished(seat: 0, place: 1)) && race.firstFinishTick == race.tick)
    }

    /// Two calls 5 s apart, the first turn served turning flat out from the second (in about 12 s). Under `sequential` (G4, the
    /// default) the second turn's 15 s and 30 s run from when the first was completed; under `fromCall`, from its
    /// own call (`docs/rules-file.md`). Either way the first turn's run from its call, and the second call fixes
    /// its turn's clock (a rule call's deadlines) only under `fromCall`.
    @Test func stackedDeadlinesFollowTheConfig() throws {
        for stacking in RulesConfig.StackedPenaltyDeadlines.allCases {
            let race = try race(stacking)
            let first = race.tick
            #expect(race.penalize(0) == first)
            steps(race, limit: 5 * Race.tickRate)
            let second = race.tick
            #expect(second == first + 5 * Race.tickRate)
            #expect(race.penalize(0) == (stacking == .fromCall ? second : nil), "\(stacking)")
            #expect(race.owedPenalty(ofSeat: 0) == OwedPenalty(turnsOwed: 2, startDeadlineTick: first + Self.start,
                                                               completeDeadlineTick: first + Self.complete, progress: 0,
                                                               isStarted: false), "\(stacking)")
            helm(race, 1)
            let log = steps(race, limit: Self.flatOut, until: { _, kinds in Self.served(kinds) })
            let completed = try #require(log.last)
            #expect(Self.served(completed.kinds), "\(stacking)")
            #expect(!log.contains { Self.disqualified($0.kinds) }, "\(stacking)")
            let clock = stacking == .sequential ? completed.tick : second
            let owed = try #require(race.owedPenalty(ofSeat: 0))
            #expect(owed.turnsOwed == 1 && owed.startDeadlineTick == clock + Self.start
                    && owed.completeDeadlineTick == clock + Self.complete, "\(stacking): \(owed)")
            #expect(race.boats[0].penaltyClockTick == clock && race.boats[0].queuedPenaltyCallTicks.isEmpty)
            // What she turned past the full turn carries into the second, the same way round.
            #expect(owed.progress > 0 && owed.progress < deg2rad(30), "\(stacking): \(owed.progress)")
        }
    }

    // MARK: - The autohelm (#219)

    /// Let go part way round in a wind wobbling ±6° every 5 s, the autohelm holds her: its corrections turn her
    /// both ways but neither give the turn up nor complete it, and steering on by hand completes it. Let go just
    /// short of the full turn while she is still turning on, the turn waits for her to steer on by hand.
    @Test func autohelmCorrectionsNeitherCompleteNorUndoATurn() throws {
        let wobbly = { (t: Double) in Wind(direction: deg2rad(6) * RegattaCore.sin(2 * .pi * t / 5), speed: metresPerSecond(knots: 10)) }
        let race = try race(wind: wobbly)
        let call = race.tick
        race.penalize(0)
        helm(race, 1)
        steps(race, limit: Self.start) { race, _ in abs(race.boats[0].penaltyProgress) >= deg2rad(200) }
        let direction: Double = race.boats[0].penaltyProgress > 0 ? 1 : -1
        #expect(race.boats[0].penaltyProgress * direction >= deg2rad(200))

        // Let go: 6 s on the autohelm.
        helm(race, 0)
        var turns: [Double] = []
        var heading = race.boats[0].heading
        steps(race, limit: 6 * Race.tickRate, each: { race, kinds in
            let boat = race.boats[0]
            #expect(!kinds.contains(.penaltyReset(seat: 0)) && !Self.served(kinds) && !Self.disqualified(kinds))
            #expect(boat.autohelm != nil && boat.penaltyTurnsOwed == 1)
            #expect(boat.penaltyProgress * direction > 0 && boat.penaltyProgress * direction < Self.fullTurn)
            turns.append(wrapAngle(boat.heading - heading))
            heading = boat.heading
        })
        #expect(turns.contains { $0 * direction < 0 } && turns.contains { $0 * direction > 0 },
                "the autohelm turned her both ways while it held her")

        // Steering on by hand completes it, within its deadline.
        helm(race, 1)
        let log = steps(race, limit: call + Self.complete - race.tick, until: { _, kinds in Self.served(kinds) })
        #expect(log.last.map { Self.served($0.kinds) } == true)
        #expect(!log.contains { Self.disqualified($0.kinds) })

        // Let go just short of the full turn, still turning on: no completion until she steers on by hand.
        let again = try self.race()
        again.penalize(0)
        helm(again, 1)
        steps(again, limit: Self.start) { race, _ in abs(race.boats[0].penaltyProgress) >= Self.fullTurn - deg2rad(2) }
        let way: Double = again.boats[0].penaltyProgress > 0 ? 1 : -1
        helm(again, 0)
        var held = false
        steps(again, limit: 3 * Race.tickRate, each: { race, kinds in
            #expect(!Self.served(kinds) && !kinds.contains(.penaltyReset(seat: 0)) && race.boats[0].penaltyTurnsOwed == 1)
            held = held || race.boats[0].penaltyProgress * way == Race.heldPenaltyProgress
        })
        #expect(held, "the autohelm carried her on to the full turn, and the turn waited")
        helm(again, 1)
        let log2 = steps(again, limit: Race.tickRate, until: { _, kinds in Self.served(kinds) })
        let done = try #require(log2.last)
        #expect(Self.served(done.kinds))
        #expect(again.heldInputs[0].rudderValue > Autohelm.deadBand, "completed on a tick she steered")
        #expect(again.boats[0].penaltyTurnsOwed == 0)
    }
}
