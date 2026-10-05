import RegattaCore
import RegattaProtocol
import Testing
@testable import RegattaClient

/// The client side of the online rules authority (#96, ADR 0005): the server's events change the prediction at
/// their ticks, its relations are the umpire's from the last snapshot, and an event is surfaced once.
@Suite struct OnlineRulesTests {
    static func owed(_ predicted: PredictedRace, _ seat: Int) -> Int { predicted.race.boats[seat].penaltyTurnsOwed }

    /// A server event for a tick the prediction has sailed changes it as of that tick; one for a tick ahead waits
    /// for it; one a snapshot already holds changes nothing; and the server's world wins at each snapshot.
    @Test func serverEventsChangeThePredictionAtTheirTicks() throws {
        var (host, generator) = try ReviewRegressionTests.host()
        let predicted = PredictedRace(start: ReviewRegressionTests.start(host, keys: generator.keys(through: 4)))
        predicted.advance(to: -560)
        predicted.record(RaceEvent(tick: -570, kind: .markTouch(seat: 1, mark: "Windward")), seq: 1)
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

    /// Every server event reaches the owner once, with its reliable seq as its id: a frame delivered again after a
    /// rejoin of the same race (a duplicate, or a host that numbered afresh) is never surfaced a second time.
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

        // A rejoin: the race again, a resync from seq 1, and the same frame again.
        try transport.deliver(Frame(seq: 1, tick: host.tick, message: .raceStart(start)))
        try transport.deliver(Frame(seq: 2, tick: host.tick, message: .resync(
            Resync(raceSeed: host.setup.raceSeed, world: host.exportSnapshot(), windKeys: revealed, nextEventSeq: 1))))
        try transport.deliver(Frame(seq: 1, event: gun))
        let started = RaceEvent(tick: -40, kind: .started(seat: 0))
        try transport.deliver(Frame(seq: 2, event: started))
        client.update(now: 1_016_667)
        let again = client.drainServerEvents()
        #expect(again == [started])
        #expect(again.map(\.id) == [2])
    }
}
