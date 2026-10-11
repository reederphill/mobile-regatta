import RegattaCore
import RegattaProtocol
import Testing
@testable import RegattaClient

/// The client side of the online rules authority (#96, ADR 0005): the server's events change the prediction at
/// their ticks, its relations are the umpire's from the last snapshot, and an event is surfaced once.
@Suite struct OnlineRulesTests {
    static func owed(_ predicted: PredictedRace, _ seat: Int) -> Int { predicted.race.boats[seat].penaltyTurnsOwed }

    /// A server event for a tick the prediction has sailed changes it as of that tick (at the next advance); one
    /// for a tick ahead waits for it; one a snapshot already holds changes nothing; and the server's world wins at
    /// each snapshot.
    @Test func serverEventsChangeThePredictionAtTheirTicks() throws {
        var (host, generator) = try ReviewRegressionTests.host()
        let predicted = PredictedRace(start: ReviewRegressionTests.start(host, keys: generator.keys(through: 4)))
        predicted.advance(to: -560)
        predicted.record(RaceEvent(tick: -570, kind: .markTouch(seat: 1, mark: "Windward")), seq: 1)
        #expect(Self.owed(predicted, 1) == 0, "taken in at the next advance")
        predicted.advance(to: -560)
        #expect(Self.owed(predicted, 1) == 1)
        #expect(predicted.race.boats[1].penaltyClockTick == -570)
        #expect(predicted.tick == -560)

        predicted.record(RaceEvent(tick: -550, kind: .penaltyServed(seat: 1)), seq: 2)
        #expect(Self.owed(predicted, 1) == 1, "not served until the prediction sails its tick")
        predicted.advance(to: -551)
        #expect(Self.owed(predicted, 1) == 1)
        predicted.advance(to: -550)
        #expect(Self.owed(predicted, 1) == 0)

        // The server's world at -547, which owes nothing: an event at or before it is in it already.
        while host.tick < -547 { host.step() }
        #expect(try predicted.apply(Snapshot(world: host.exportSnapshot()), tick: host.tick))
        #expect(Self.owed(predicted, 1) == 0)
        predicted.record(RaceEvent(tick: -548, kind: .markTouch(seat: 2, mark: "Windward")), seq: 3)
        #expect(Self.owed(predicted, 2) == 0)
        predicted.record(RaceEvent(tick: -544, kind: .markTouch(seat: 2, mark: "Windward")), seq: 4)
        predicted.advance(to: -540)
        #expect(Self.owed(predicted, 2) == 1)
        #expect(predicted.race.boats[2].penaltyClockTick == -544)
        // A snapshot from before its tick doesn't hold it: it is applied again as the prediction sails on.
        while host.tick < -545 { host.step() }
        #expect(try predicted.apply(Snapshot(world: host.exportSnapshot()), tick: host.tick))
        #expect(predicted.tick == -540)
        #expect(Self.owed(predicted, 2) == 1)
        #expect(predicted.race.boats[2].penaltyClockTick == -544)
    }

    /// The prediction's relations are the last snapshot's (the server umpire's), never its own world's; a resync
    /// forgets them until the next snapshot.
    @Test func theRelationsAreTheLastSnapshots() throws {
        var (host, generator) = try ReviewRegressionTests.host()
        let keys = generator.keys(through: 1)
        let predicted = PredictedRace(start: ReviewRegressionTests.start(host, keys: keys))
        while host.tick < -500 { host.step() }
        #expect(host.race.keepClearRelations(of: 0).contains { $0 != nil }, "the start line has relations")
        #expect(predicted.race.keepClearRelations(of: 0).allSatisfy { $0 == nil })
        var snapshot = try Snapshot(world: host.exportSnapshot())
        snapshot.relations = WireRelation.relations(of: 0, in: host.race)
        predicted.advance(to: -495)
        #expect(try predicted.apply(snapshot, tick: host.tick))
        #expect(predicted.race.keepClearRelations(of: 0) == WireRelation.umpireRelations(snapshot.relations!, seat: 0).keepClear)
        #expect(predicted.race.keepClearRelations(of: 0).contains { $0 != nil })
        try predicted.apply(Resync(raceSeed: host.setup.raceSeed, world: host.exportSnapshot(), windKeys: keys, nextEventSeq: 1),
                            tick: host.tick)
        #expect(predicted.race.keepClearRelations(of: 0).allSatisfy { $0 == nil })
    }

    /// Every server event reaches the owner once, with its reliable seq as its id: a frame delivered again, a
    /// duplicate or after a rejoin of the same race (whose numbering runs on), is never surfaced a second time.
    @Test func anEventIsSurfacedOnceWithItsId() throws {
        var (host, generator) = try ReviewRegressionTests.host()
        let revealed = generator.keys(through: 1)
        let transport = ManualTransport()
        let start = ReviewRegressionTests.start(host, keys: revealed)
        let client = RaceClient(start: start, transport: transport)
        while host.tick < -40 { host.step() }
        let gun = RaceEvent(tick: -40, kind: .gun)
        try transport.deliver(Frame(seq: 1, event: gun))
        try transport.deliver(Frame(seq: 1, event: gun))
        client.update(now: 1_000_000)
        let first = client.drainServerEvents()
        #expect(first == [gun])
        #expect(first.map(\.id) == [1])

        // A rejoin: the race again, a resync from seq 2 (the host's numbering runs on), and the same frame again.
        try transport.deliver(Frame(seq: 1, tick: host.tick, message: .raceStart(start)))
        try transport.deliver(Frame(seq: 2, tick: host.tick, message: .resync(
            Resync(raceSeed: host.setup.raceSeed, world: host.exportSnapshot(), windKeys: revealed, nextEventSeq: 2))))
        try transport.deliver(Frame(seq: 1, event: gun))
        let started = RaceEvent(tick: -40, kind: .started(seat: 0))
        try transport.deliver(Frame(seq: 2, event: started))
        client.update(now: 1_016_667)
        let again = client.drainServerEvents()
        #expect(again == [started])
        #expect(again.map(\.id) == [2])
    }

    /// A rematch is another race even with the same seed (#96): its `RaceStart` numbers the events afresh, and its
    /// first event is surfaced although the last race surfaced one with that seq.
    @Test func aRematchWithTheSameSeedSurfacesItsEvents() throws {
        var (host, generator) = try ReviewRegressionTests.host()
        let revealed = generator.keys(through: 1)
        let transport = ManualTransport()
        let start = ReviewRegressionTests.start(host, keys: revealed)
        let client = RaceClient(start: start, transport: transport)
        while host.tick < -40 { host.step() }
        let gun = RaceEvent(tick: -40, kind: .gun)
        try transport.deliver(Frame(seq: 1, event: gun))
        client.update(now: 1_000_000)
        #expect(client.drainServerEvents().map(\.id) == [1])

        try transport.deliver(Frame(seq: 1, tick: host.tick, message: .raceStart(start)))
        try transport.deliver(Frame(seq: 2, tick: host.tick, message: .resync(
            Resync(raceSeed: host.setup.raceSeed, world: host.exportSnapshot(), windKeys: revealed, nextEventSeq: 1))))
        try transport.deliver(Frame(seq: 1, event: gun))
        client.update(now: 1_016_667)
        let rematch = client.drainServerEvents()
        #expect(rematch == [gun])
        #expect(rematch.map(\.id) == [1])
    }

    /// The penalty state of `seat`: turns owed, the current turn's clock, the queue and the progress.
    static func penalty(_ predicted: PredictedRace, _ seat: Int) -> String {
        let b = predicted.race.boats[seat]
        return "\(b.penaltyTurnsOwed) \(String(describing: b.penaltyClockTick)) \(b.queuedPenaltyCallTicks) \(b.penaltyProgress)"
    }

    /// A mid-race `Resync` whose event state lacks frames the client had already delivered puts them back on top
    /// (`RaceClient`); the prediction still holds them as rulings, and takes each once, by its seq: the penalty
    /// state is what the server's events make it, as in a prediction that had each of them once.
    @Test func aResyncReplayingDeliveredFramesAppliesEachEventOnce() throws {
        var (host, generator) = try ReviewRegressionTests.host()
        let keys = generator.keys(through: 4)
        let start = ReviewRegressionTests.start(host, keys: keys)
        let transport = ManualTransport()
        let client = RaceClient(start: start, transport: transport)
        while host.tick < -560 { host.step() }
        let events = [RaceEvent(tick: -550, kind: .markTouch(seat: 1, mark: "Windward")),
                      RaceEvent(tick: -549, kind: .markTouch(seat: 1, mark: "Windward")),
                      RaceEvent(tick: -540, kind: .penaltyServed(seat: 1))]
        for (k, event) in events.enumerated() { try transport.deliver(Frame(seq: UInt32(k + 1), event: event)) }
        client.update(now: 1_000_000)
        #expect(client.drainServerEvents().count == 3)
        // The server's world from before them, and its event state without them.
        let resync = try Resync(raceSeed: host.setup.raceSeed, world: host.exportSnapshot(), windKeys: keys, nextEventSeq: 1)
        try transport.deliver(Frame(seq: 4, tick: host.tick, message: .resync(resync)))
        client.update(now: 1_016_667)
        #expect(client.drainServerEvents().isEmpty, "shown once already")
        client.predicted.advance(to: -530)

        let once = PredictedRace(start: start)
        try once.apply(resync, tick: host.tick)
        for (k, event) in events.enumerated() { once.record(event, seq: UInt32(k + 1)) }
        once.advance(to: -530)
        #expect(Self.owed(once, 1) == 1)
        #expect(Self.penalty(client.predicted, 1) == Self.penalty(once, 1))
        #expect(client.predicted.events == once.events)
    }

    /// The server's events that come for ticks already sailed are taken in together at the next advance, by one
    /// sail from the last server world; with that more than `resailCap` ticks behind, they apply where the race is
    /// instead, and the next snapshot puts each at its tick.
    @Test func lateEventsResailOnceAndNoFurtherThanTheCap() throws {
        var (host, generator) = try ReviewRegressionTests.host()
        let predicted = PredictedRace(start: ReviewRegressionTests.start(host, keys: generator.keys(through: 4)))
        #expect(PredictedRace.resailCap == 2 * Race.tickRate)
        predicted.advance(to: -600 + PredictedRace.resailCap)
        for (k, tick) in [-590, -580, -570].enumerated() {
            predicted.record(RaceEvent(tick: tick, kind: .markTouch(seat: 1, mark: "Windward")), seq: UInt32(k + 1))
        }
        // An event that changes nothing never sails again.
        predicted.record(RaceEvent(tick: -575, kind: .rounded(seat: 1, mark: "Windward")), seq: 4)
        #expect(predicted.resails == 0)
        predicted.advance(to: -600 + PredictedRace.resailCap)
        #expect(predicted.resails == 1)
        #expect(Self.owed(predicted, 1) == 3)
        #expect(predicted.race.boats[1].penaltyClockTick == -590)
        #expect(predicted.race.boats[1].queuedPenaltyCallTicks == [-580, -570])
        predicted.record(RaceEvent(tick: -520, kind: .rounded(seat: 1, mark: "Windward")), seq: 5)
        predicted.advance(to: -500)
        #expect(predicted.resails == 1)

        // 100 ticks past the last server world: past the cap, so it applies at the race's tick.
        predicted.record(RaceEvent(tick: -560, kind: .markTouch(seat: 2, mark: "Windward")), seq: 6)
        predicted.advance(to: -500)
        #expect(predicted.resails == 1 && predicted.cappedResails == 1)
        #expect(Self.owed(predicted, 2) == 1)
        #expect(predicted.tick == -500)
        // The next snapshot, from before its tick, puts it back at its tick.
        while host.tick < -580 { host.step() }
        #expect(try predicted.apply(Snapshot(world: host.exportSnapshot()), tick: host.tick))
        #expect(predicted.tick == -500)
        #expect(Self.owed(predicted, 2) == 1)
        #expect(predicted.race.boats[2].penaltyClockTick == -560)
        #expect(predicted.resails == 1 && predicted.cappedResails == 1)
    }

    /// #487: under fleet-rules@6 a prediction counts a penalty turn's crossings as the server does, but never serves
    /// it: on the tick the server serves the turn, the prediction holds the second crossing (both shown made) and
    /// still owes it, until the server's `penaltyServed` serves it. A recross the prediction undoes itself, as the
    /// server does, on the same tick: the server's `penaltyReset` then changes nothing.
    @Test func predictionHoldsTheSecondCrossingForTheServer() throws {
        let rules = try RulesConfigFile.bundled(id: "fleet-rules", version: 6)
        let dinghy = try BoatClassFile.bundled(id: "ilca-dinghy", version: 3)
        let setup = try RaceSetup(raceSeed: RaceSeed(64), seats: [.human, .human], laps: 1, startSequenceTicks: 600,
                                  boatClass: dinghy.ref, rulesConfiguration: rules.ref)
        let host = Race(setup: setup, windSeed: WindSeed(0x5EED))
        var generator = try WindKeyGenerator(windSeed: WindSeed(0x5EED), setup: host.windSetup, windows: host.wind.windows)
        let prediction = Race(setup: setup, revealedWindKeys: generator.keys(through: host.wind.windows.window(containing: 1_800)))
        host.step()
        // Seat 0 owes a turn, seat 1 well clear of her.
        var world = host.exportSnapshot()
        world.seats[0].boat.penaltyTurnsOwed = 1
        world.seats[0].boat.penaltyClockTick = world.tick
        world.seats[1].boat.position = world.seats[0].boat.position + host.course.right * 60
        try host.importSnapshot(world)
        try prediction.importSnapshot(world)
        _ = host.drainEvents()

        func helm(_ rudder: Double) {
            for race in [host, prediction] { _ = race.apply(BoatInput(rudder: rudder), seat: 0, atTick: race.tick + 1) }
        }
        /// Steps both until the host emits `stop` for seat 0 (at most 20 s); the host's events on that tick.
        func sail(until stop: RaceEvent.Kind) throws -> [RaceEvent.Kind] {
            for _ in 0..<(20 * Race.tickRate) {
                host.step()
                try prediction.tryStep()
                _ = prediction.drainEvents()
                #expect(prediction.boats[0].heading == host.boats[0].heading, "the prediction sails as the server")
                let kinds = host.drainEvents().map(\.kind)
                if kinds.contains(stop) { return kinds }
            }
            Issue.record("no \(stop) in 20 s")
            return []
        }
        func sameCrossings() -> Bool {
            let p = prediction.boats[0], h = host.boats[0]
            return p.penaltyTurnsOwed == h.penaltyTurnsOwed && p.penaltyDirection == h.penaltyDirection
                && p.penaltyFirstCrossing == h.penaltyFirstCrossing && p.penaltyDirectionLocked == h.penaltyDirectionLocked
        }

        // The first crossing, turning to starboard: the prediction counts it as the server does.
        helm(1)
        _ = try sail(until: .penaltyStarted(seat: 0))
        #expect(host.boats[0].penaltyDirection == 1 && host.boats[0].penaltyFirstCrossing != nil)
        #expect(sameCrossings() && prediction.boats[0].isTakingPenalty)

        // Back across it: the recross, which the prediction undoes itself; the server's reset changes nothing.
        helm(-1)
        _ = try sail(until: .penaltyReset(seat: 0))
        #expect(host.boats[0].penaltyDirection == -1 && sameCrossings())
        prediction.apply(authoritative: RaceEvent(tick: host.tick, kind: .penaltyReset(seat: 0)))
        #expect(sameCrossings())

        // On round to the other kind: the server serves it; the prediction holds it, owing the turn still.
        let kinds = try sail(until: .penaltyServed(seat: 0))
        #expect(kinds.contains(.tacked(seat: 0)) || kinds.contains(.gybed(seat: 0)))
        #expect(host.boats[0].penaltyTurnsOwed == 0 && host.owedPenalty(ofSeat: 0) == nil)
        let held = try #require(prediction.owedPenalty(ofSeat: 0))
        #expect(prediction.boats[0].penaltyTurnsOwed == 1 && prediction.boats[0].penaltyCrossingHeld)
        #expect(held.isStarted && held.hasTacked && held.hasGybed && held.direction == -1)
        // Sailing on, nothing more counts until the server's word.
        host.step()
        try prediction.tryStep()
        #expect(prediction.boats[0].penaltyTurnsOwed == 1 && prediction.boats[0].penaltyCrossingHeld)
        prediction.apply(authoritative: RaceEvent(tick: host.tick - 1, kind: .penaltyServed(seat: 0)))
        let served = prediction.boats[0]
        #expect(served.penaltyTurnsOwed == 0 && served.penaltyClockTick == nil && !served.penaltyCrossingHeld)
        #expect(served.penaltyDirection == 0 && served.penaltyFirstCrossing == nil && !served.isTakingPenalty)
        #expect(prediction.owedPenalty(ofSeat: 0) == nil)
    }

    /// #487, fleet-rules@6: a turn that becomes current while she is rounding has its clock pending until she is clear
    /// of the mark. The prediction holds it pending as the server does, from the server's call (no deadline) and from
    /// the server's `penaltyServed` of the turn before, and starts it itself on the same tick as the server.
    @Test func predictionStartsAPendingClockWithTheServer() throws {
        let rules = try RulesConfigFile.bundled(id: "fleet-rules", version: 6)
        let dinghy = try BoatClassFile.bundled(id: "ilca-dinghy", version: 3)
        let setup = try RaceSetup(raceSeed: RaceSeed(64), seats: [.human, .human], laps: 1, startSequenceTicks: 600,
                                  boatClass: dinghy.ref, rulesConfiguration: rules.ref)
        let host = Race(setup: setup, windSeed: WindSeed(0x5EED))
        var generator = try WindKeyGenerator(windSeed: WindSeed(0x5EED), setup: host.windSetup, windows: host.wind.windows)
        let keys = generator.keys(through: host.wind.windows.window(containing: 1_800))
        let prediction = Race(setup: setup, revealedWindKeys: keys)
        let called = Race(setup: setup, revealedWindKeys: keys)
        host.step()
        let complete = RulesConfig.ticks(rules.content.raceFormat.penalty.complete)
        // Seat 0 racing, 4 m past the windward mark and sailing away from it (in its zone: rounding), owing two turns,
        // the first's tack made to starboard; seat 1 well clear.
        let mark = try #require(host.course.elements[CourseLayout.windwardIndex].marks.first)
        var world = host.exportSnapshot()
        world.seats[0].boat.status = .racing
        world.seats[0].boat.legIndex = 0
        world.seats[0].boat.roundingStage = 0
        world.seats[0].boat.position = mark.position + Vec2.heading(world.seats[0].boat.heading) * 4
        world.seats[1].boat.position = world.seats[0].boat.position + host.course.right * 60
        var owing = world
        owing.seats[0].boat.penaltyTurnsOwed = 2
        owing.seats[0].boat.penaltyClockTick = world.tick
        owing.seats[0].boat.penaltyDirection = 1
        owing.seats[0].boat.penaltyFirstCrossing = .tack
        try prediction.importSnapshot(owing)
        // The server served the first turn there: the second is current, its clock pending.
        var served = owing
        served.seats[0].boat.penaltyTurnsOwed = 1
        served.seats[0].boat.penaltyClockTick = nil
        served.seats[0].boat.penaltyFirstCrossing = nil
        served.seats[0].boat.penaltyDirectionLocked = true
        try host.importSnapshot(served)
        _ = host.drainEvents()
        prediction.apply(authoritative: RaceEvent(tick: host.tick, kind: .penaltyServed(seat: 0)))
        #expect(prediction.boats[0].penaltyTurnsOwed == 1 && prediction.boats[0].penaltyClockTick == nil)
        #expect(prediction.boats[0].penaltyDirectionLocked)
        let pending = try #require(prediction.owedPenalty(ofSeat: 0))
        #expect(pending.isClockPending && pending.completeDeadlineTick == host.tick + complete)
        #expect(host.owedPenalty(ofSeat: 0) == pending)

        // A call there: the server's call has no deadline, so the prediction's clock is pending; one with a deadline
        // starts it at the call.
        try called.importSnapshot(world)
        func call(deadline: Int?) -> RaceEvent {
            RaceEvent(tick: world.tick, kind: .ruleCall(RuleCall(
                incidentId: 0, tick: world.tick, rule: .portStarboard, offender: 0, victim: 1, leg: 0, turnsOwed: 1,
                startDeadlineTick: deadline, completeDeadlineTick: deadline)))
        }
        called.apply(authoritative: call(deadline: nil))
        #expect(called.boats[0].penaltyTurnsOwed == 1 && called.boats[0].penaltyClockTick == nil)
        try called.importSnapshot(world)
        called.apply(authoritative: call(deadline: world.tick + complete))
        #expect(called.boats[0].penaltyClockTick == world.tick)

        // Sailing out of the zone, both start the clock on the same tick.
        for _ in 0..<(20 * Race.tickRate) {
            host.step()
            try prediction.tryStep()
            _ = prediction.drainEvents()
            _ = host.drainEvents()
            #expect(prediction.boats[0].penaltyClockTick == host.boats[0].penaltyClockTick)
            if host.boats[0].penaltyClockTick != nil { break }
        }
        let clock = try #require(host.boats[0].penaltyClockTick)
        #expect(clock == host.tick && clock > world.tick + Race.tickRate, "started clear of the mark, not at once")
        #expect(prediction.owedPenalty(ofSeat: 0) == host.owedPenalty(ofSeat: 0))
        #expect(host.owedPenalty(ofSeat: 0)?.completeDeadlineTick == clock + complete)
    }
}
