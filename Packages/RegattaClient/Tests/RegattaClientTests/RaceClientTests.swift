import RegattaCore
import RegattaProtocol
import Testing
@testable import RegattaClient

/// #149: the client's roster follows the server's `RosterChange`s, and `leave()` gives the seat up.
@Suite struct RaceClientTests {
    @Test func rosterChangeUpdatesTheRosterAndLeaveSendsLeaveRace() throws {
        let setup = try RaceSetup(raceSeed: RaceSeed(149), seats: [.human, .human, .bot, .bot], laps: 1, startSequenceTicks: 600)
        let race = Race(setup: setup, windSeed: WindSeed(0x149))
        let keys = try WindKeyGenerator(windSeed: WindSeed(0x149), setup: race.windSetup, windows: race.wind.windows)
        var generator = keys
        let names = ["Ann", "Bea", "Gannet", "Petrel"]
        let roster = names.enumerated().map { RosterEntry(name: $1, colorIndex: $0) }
        let start = RaceStart(yourSeat: 0, setup: setup, roster: roster, windKeys: generator.keys(through: 1))
        let transport = ManualTransport()
        let client = RaceClient(start: start, transport: transport)
        // The setup's bots are bots from the start; the players aren't.
        #expect(client.roster.map(\.isBot) == [false, false, true, true])
        #expect(client.roster.map(\.name) == names)

        // Bea gives her seat up before the gun: her entry becomes a bot's, on the reliable stream. A decoded
        // `RaceStart` never changes its setup for it.
        let change = RosterChange(seat: 1, entry: RosterEntry(name: "Skua", colorIndex: 1, isBot: true))
        try transport.deliver(Frame(seq: 1, tick: -450, message: .rosterChange(change)))
        client.update(now: 0)
        #expect(client.roster[1] == change.entry)
        #expect(client.roster.map(\.isBot) == [false, true, true, true])
        #expect(client.predicted.start.setup.seats == [.human, .human, .bot, .bot])
        // It is no race event: nothing for the owner to show (no line, toast or sound).
        #expect(client.drainServerEvents().isEmpty)

        // The same frame again, and one out of order, change nothing; a seat no roster has is ignored.
        try transport.deliver(Frame(seq: 1, tick: -450, message: .rosterChange(change)))
        try transport.deliver(Frame(seq: 2, tick: -440, message: .rosterChange(RosterChange(seat: 9, entry: change.entry))))
        client.update(now: 16_667)
        #expect(client.roster.count == 4 && client.roster[1] == change.entry && client.roster[0].name == "Ann")

        // A rejoin's `RaceStart` carries the roster as it is now.
        var current = roster
        current[1] = change.entry
        try transport.deliver(Frame(seq: 5, tick: -300, message: .raceStart(RaceStart(yourSeat: 0, setup: setup, roster: current,
                                                                                    windKeys: start.windKeys))))
        client.update(now: 33_334)
        #expect(client.roster == RaceStart(yourSeat: 0, setup: setup, roster: current).roster)

        // Leaving sends one empty `LeaveRace`, clock sync or not.
        #expect(!transport.outbox.contains { $0.message == .leaveRace })
        client.leave()
        #expect(transport.outbox.filter { $0.message == .leaveRace }.count == 1)
        // Not over a dead connection, nor once the race has ended.
        transport.isConnected = false
        client.leave()
        transport.isConnected = true
        try transport.deliver(Frame(seq: 6, tick: -290, message: .raceCancelled(RaceCancelled(reason: .unspecified))))
        client.update(now: 50_000)
        client.leave()
        #expect(transport.outbox.filter { $0.message == .leaveRace }.count == 1)
    }

    /// #150: a dropped player's seat is marked disconnected by a `RosterChange` and cleared by the next; nothing else
    /// of her entry moves, and it is no race event.
    @Test func rosterChangeMarksAndClearsDisconnected() throws {
        let setup = try RaceSetup(raceSeed: RaceSeed(150), seats: [.human, .human, .bot], laps: 1, startSequenceTicks: 600)
        let race = Race(setup: setup, windSeed: WindSeed(0x150))
        var generator = try WindKeyGenerator(windSeed: WindSeed(0x150), setup: race.windSetup, windows: race.wind.windows)
        let roster = ["Ann", "Bea", "Gannet"].enumerated().map { RosterEntry(name: $1, colorIndex: $0) }
        let start = RaceStart(yourSeat: 0, setup: setup, roster: roster, windKeys: generator.keys(through: 1))
        let transport = ManualTransport()
        let client = RaceClient(start: start, transport: transport)
        #expect(client.roster.map(\.isDisconnected) == [false, false, false])

        var gone = roster[1]
        gone.isDisconnected = true
        try transport.deliver(Frame(seq: 1, tick: -450, message: .rosterChange(RosterChange(seat: 1, entry: gone))))
        client.update(now: 0)
        #expect(client.roster.map(\.isDisconnected) == [false, true, false])
        #expect(client.roster[1].name == "Bea" && !client.roster[1].isBot && client.roster[1].colorIndex == 1)
        #expect(client.predicted.start.setup.seats == [.human, .human, .bot])
        #expect(client.drainServerEvents().isEmpty)

        // Seen again after a resync: the whole entry, so nothing changes.
        try transport.deliver(Frame(seq: 2, tick: -440, message: .rosterChange(RosterChange(seat: 1, entry: gone))))
        client.update(now: 16_667)
        #expect(client.roster.map(\.isDisconnected) == [false, true, false])

        // She is back: the mark goes with the next change.
        try transport.deliver(Frame(seq: 3, tick: -400, message: .rosterChange(RosterChange(seat: 1, entry: roster[1]))))
        client.update(now: 33_334)
        #expect(client.roster == start.roster)
        #expect(client.drainServerEvents().isEmpty)

        // A rejoin's `RaceStart` carries the marks as they stand.
        var current = roster
        current[1] = gone
        try transport.deliver(Frame(seq: 6, tick: -300, message: .raceStart(RaceStart(yourSeat: 0, setup: setup, roster: current,
                                                                                    windKeys: start.windKeys))))
        client.update(now: 50_000)
        #expect(client.roster.map(\.isDisconnected) == [false, true, false])
    }
}
