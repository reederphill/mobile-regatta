import Foundation
import RegattaClient
import RegattaCore
import RegattaProtocol
import RegattaServices
import Testing
@testable import Regatta

/// The Debug fake race a `-fakeServices` launch sails after fleet lock (#141): the host's close, cancel and
/// `LeaveRace`, and the director's `rejoinable` and `race-gone` scenarios. What the UI tests and the local screenshots
/// stand on; the server's own behaviour is RegattaServer's to test.
@MainActor @Suite struct FakeRaceHostTests {
    /// A host on a virtual clock with one client joined to it, in a one-second start sequence.
    @MainActor final class Rig {
        let clock = VirtualClock(now: 1_000_000)
        let host: FakeRaceHost
        private(set) var connection = FakeRaceConnection()
        private(set) var received: [Message] = []
        private(set) var ends: [FakeRaceHost.Ending] = []
        private(set) var releases = 0

        init(closeTick: Int = 60, cancelTick: Int? = nil) throws {
            let briefing = FakeServiceScenario.briefing()
            let setup = try RaceSetup(raceSeed: briefing.setup.raceSeed, seats: briefing.setup.seats, laps: briefing.setup.laps,
                                      startSequenceTicks: Race.tickRate)
            let clock = clock
            host = try FakeRaceHost(setup: setup, names: briefing.fleet.map(\.name), closeTick: closeTick, now: { clock.now })
            host.cancelTick = cancelTick
            host.onEnd = { [unowned self] in ends.append($0) }
            host.onSeatReleased = { [unowned self] in releases += 1 }
        }

        /// A new connection, joined if the host takes it.
        @discardableResult func join() -> Bool {
            connection = FakeRaceConnection()
            host.accept(connection)
            let join = RaceJoin(connection: connection, token: [1], clientBuild: "test", now: clock.now)
            for _ in 0..<200 where !join.isFinished && connection.isConnected {
                clock.advance(by: 1000)
                host.poll()
                join.poll(now: clock.now)
            }
            if case .joined = join.state { return true }
            return false
        }

        /// Runs the host until the race clock reads `tick`, or it ends.
        func run(to tick: Int) {
            for _ in 0..<100_000 where host.tick < tick && host.ending == nil {
                clock.advance(by: 4000)
                host.poll()
                read()
            }
            read()
        }

        func send(_ message: Message) throws {
            connection.send(try Frame(seq: 900, tick: host.tick, message: message).encoded())
            host.poll()
            read()
        }

        private func read() {
            received += connection.receive().compactMap { try? Frame(decoding: $0).message }
        }
    }

    private static func isClosed(_ message: Message) -> Bool {
        if case .raceClosed = message { true } else { false }
    }

    private static func isCancelled(_ message: Message) -> Bool {
        if case .raceCancelled = message { true } else { false }
    }

    /// The race closes at its close tick with `RaceClosed`, once; it can be rejoined from the gun until then, and
    /// nobody joins it after.
    @Test func theHostClosesItsRaceAndOffersTheRejoinUntilThen() throws {
        let rig = try Rig(closeTick: 60)
        #expect(rig.join())
        #expect(!rig.host.isRejoinable && rig.host.holdsSeat, "nothing to rejoin before the gun")
        rig.run(to: 10)
        #expect(rig.host.isRejoinable)
        // A drop keeps the seat.
        rig.connection.close()
        rig.run(to: 20)
        #expect(rig.host.isRejoinable && rig.host.holdsSeat)
        #expect(rig.join(), "the dropped seat can't be taken back")
        rig.run(to: 100)
        #expect(rig.host.ending == .closed && rig.ends == [.closed])
        #expect(rig.received.filter(Self.isClosed).count == 1 && !rig.received.contains(where: Self.isCancelled))
        #expect(!rig.host.isRejoinable && !rig.host.holdsSeat)
        #expect(!rig.join(), "a closed race took a join")
    }

    /// The app stood still for a while (a long frame on a slow machine at a fast `-timescale`): the host sails every
    /// tick it missed in its next poll and keeps its clock, so the client's clock stays true. Only a stall longer
    /// than one poll sails makes the race clock slip, by the rest.
    @Test func aStallIsCaughtUpInOnePollAndTheClockKept() throws {
        let rig = try Rig(closeTick: 3000)
        #expect(rig.join())
        rig.run(to: 10)
        let before = rig.host.tick
        rig.clock.advance(by: 2_000_000)
        rig.host.poll()
        #expect(rig.host.tick == before + 2 * Race.tickRate, "two seconds' ticks in the one poll")
        #expect(rig.connection.isConnected)

        rig.clock.advance(by: 10_000_000)
        rig.host.poll()
        let caught = before + 2 * Race.tickRate + FakeRaceHost.pollTicks
        #expect(rig.host.tick == caught, "one poll sails four seconds at most")
        rig.clock.advance(by: 1_000_000)
        rig.host.poll()
        #expect((caught + Race.tickRate...caught + Race.tickRate + 2).contains(rig.host.tick),
                "the rest was let go: the clock slipped rather than the app catching up for good")
    }

    /// `cancelled-race`: the race is cancelled at its tick, before the close, with `RaceCancelled`.
    @Test func theHostCancelsAtItsScriptedTick() throws {
        let rig = try Rig(closeTick: 600, cancelTick: 30)
        #expect(rig.join())
        rig.run(to: 100)
        #expect(rig.host.tick == 30)
        #expect(rig.host.ending == .cancelled && rig.ends == [.cancelled])
        #expect(rig.received.contains(where: Self.isCancelled) && !rig.received.contains(where: Self.isClosed))
        #expect(!rig.host.isRejoinable && !rig.host.holdsSeat)
    }

    /// `LeaveRace` before the gun: a bot takes the seat under a sailing name, for good. After it: the seat is
    /// released as it is. Either way the connection goes and the seat can't be joined again.
    @Test func leaveRaceReleasesTheSeatAndBeforeTheGunABotTakesIt() throws {
        let early = try Rig()
        #expect(early.join())
        early.run(to: -10)
        try early.send(.leaveRace)
        #expect(early.host.hasLeft && early.releases == 1 && !early.host.holdsSeat)
        let seat = early.host.roster[FakeRaceHost.seat]
        #expect(seat.isBot && seat.name == "Gannet")
        #expect(!early.connection.isConnected)
        #expect(!early.join(), "a seat she left took her back")
        early.run(to: 5)
        #expect(!early.host.isRejoinable)

        let late = try Rig()
        #expect(late.join())
        late.run(to: 10)
        let before = late.host.roster[FakeRaceHost.seat]
        try late.send(.leaveRace)
        #expect(late.host.hasLeft && late.releases == 1 && !late.host.isRejoinable)
        #expect(late.host.roster[FakeRaceHost.seat] == before, "after the gun no bot takes the seat")
        #expect(!late.connection.isConnected)
    }

    /// `rejoinable` launches into a race under way that she dropped out of: the session offers the way back with the
    /// race clock, and the queue is closed to her meanwhile, as the server's is.
    @Test func rejoinableOffersTheRaceItLaunchedInto() async throws {
        let services = ServiceSet.fake(.rejoinable)
        // The race's clock stands still: under way and a minute from its close, however long the suites beside this
        // one hold the main actor (on the wall clock it had closed by the time a slow run asked the queue).
        let director = FakeRaceDirector(scenario: .rejoinable, base: services.raceSession, timescale: 1, raceSeconds: nil,
                                        now: { 0 })
        let offer = try await FakeRaceSession(director).rejoin()
        #expect(offer.handOff.raceID == FakeRaceDirector.raceID && offer.seat == FakeRaceHost.seat)
        let under = FakeRaceDirector.rejoinableSeconds * Race.tickRate
        #expect(offer.clock.tick == under)
        #expect(director.holdsSeat)
        await #expect(throws: QueueError.alreadyQueued) { try await DirectedQueue(services.queue, director: director).join() }
        var states = DirectedQueue(services.queue, director: director).stateUpdates().makeAsyncIterator()
        #expect(await states.next() == .fleetLocked, "the stream says the race holds her")
        // Her seat answers a join.
        let connection = director.connect(offer.handOff.token)
        #expect(connection.isConnected)
    }

    /// `race-gone`: fleet lock hands her a seat, and nothing ever answers on the race link.
    @Test func raceGoneNeverAnswersTheRaceLink() async throws {
        let services = ServiceSet.fake(.raceGone)
        let director = FakeRaceDirector(scenario: .raceGone, base: services.raceSession, timescale: 1, raceSeconds: nil,
                                        now: { 0 })
        let handOff = try await director.handOff()
        #expect(handOff.briefing != nil)
        let connection = director.connect(handOff.token)
        let clock = VirtualClock()
        let join = RaceJoin(connection: connection, token: handOff.token.bytes, clientBuild: "test", now: clock.now)
        for _ in 0..<50 {
            clock.advance(by: 20_000)
            director.host?.poll()
            join.poll(now: clock.now)
        }
        #expect(join.state == .awaitingAck && connection.isConnected, "something answered")
        #expect(throws: RaceSessionError.noRace) { try director.rejoin() }
    }
}
