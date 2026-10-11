import Foundation
import Persistence
import RaceHost
import RegattaBots
import RegattaCore
import RegattaLoadClient
import RegattaProtocol
@testable import RegattaServerKit
import RegattaServices
import Testing

extension RaceSims {
    /// #149: `LeaveRace`, a seated connection's word that its player gives the seat up for good. Before the gun a bot
    /// of the fleet's level has the boat from there, the leave counts once and she may queue again; after the gun the
    /// boat is covered and she is free at once; from anyone else, twice, or once the race has ended, it does nothing.
    @Suite(.serialized, .timeLimit(.minutes(2))) struct LeaveRaceTests {
        typealias QueueRig = BriefingLeaveCooldownTests.QueueRig

        @Test func leaveBeforeTheGunFreesHerToQueueAndCountsOnce() async throws {
            let queue = QueueRig()
            let players = [QueueMatchmakerTests.player(0), QueueMatchmakerTests.player(1)]
            let race = try await queue.lock(players)
            let transports = [KeptTransport(), KeptTransport()]
            for seat in 0..<2 { try await race.join(seat: seat, transport: transports[seat]) }
            #expect(await queue.matchmaker.state(of: "T:1") == .fleetLocked)
            await queue.rig.run(race, to: -60)
            let before = await race.host.boat(seat: 1)

            // The connection holding the seat says so; one that doesn't hold it is ignored.
            #expect(await !race.quit(seat: 1, transport: KeptTransport()))
            #expect(await !race.host.hasLeft(seat: 1))
            #expect(await race.quit(seat: 1, transport: transports[1]))
            #expect(transports[1].isClosed)

            // A fleet bot has the boat, where it was, under a sailing name; the other player is told.
            let after = await race.host.boat(seat: 1)
            #expect(after.position == before.position && after.heading == before.heading)
            guard case .bot(let driver) = await race.host.controller(seat: 1) else {
                Issue.record("seat 1 isn't a fleet bot")
                return
            }
            let fleet = try #require(await queue.matchmaker.lastFleet)
            #expect(driver.style.skill == fleet.fill.plan(seat: 1, raceSeed: race.setup.raceSeed).skill && !driver.isCautious)
            let entry = await race.host.rosterEntries[1]
            #expect(entry.isBot && FleetRoster.sailingNames.contains(entry.name))
            #expect(transports[0].messages.contains(.rosterChange(RosterChange(seat: 1, entry: entry))))
            // The other player's entry is still hers (she has sent nothing yet, so her boat is covered and marked, #150).
            let other = await race.host.rosterEntries[0]
            #expect(other.name == "P0" && other.colorIndex == 0 && !other.isBot)

            // Counted at once, once; she is free, the race is no longer hers, and she may queue again.
            #expect(await eventually { (try? await queue.leaves("T:1")) == 1 })
            #expect(await eventually { await queue.matchmaker.state(of: "T:1") == .idle })
            #expect(await eventually { await queue.rig.lifecycle.seat(of: "T:1") == nil })
            await #expect(throws: RaceSessionError.noRace) { try await queue.matchmaker.handOff(for: "T:1") }
            #expect(await !queue.rig.lifecycle.rejoinable("T:1"))
            try await queue.matchmaker.join(players[1])
            #expect(await queue.matchmaker.state(of: "T:0") == .fleetLocked)

            // Again, and at the gun: nothing more.
            #expect(await !race.quit(seat: 1, transport: transports[1]))
            #expect(await !race.quit(seat: 1))
            await queue.rig.run(race, to: 5)
            #expect(await !eventually(seconds: 0.1) { (try? await queue.leaves("T:1")) != 1 })
            #expect(try await queue.leaves("T:0") == 0)
            #expect(await !queue.rig.lifecycle.rejoinable("T:1"))
        }

        /// After the gun (decision, #149): she is free to queue at once and the race is no longer hers; nothing is
        /// counted, her boat is covered as a dropped boat is (#150: by the cautious bot, marked disconnected), and no
        /// name or seat kind changes.
        @Test func leaveAfterTheGunFreesHerAndCountsNothing() async throws {
            let queue = QueueRig()
            let players = [QueueMatchmakerTests.player(0), QueueMatchmakerTests.player(1)]
            let race = try await queue.lock(players)
            let transports = [KeptTransport(), KeptTransport()]
            for seat in 0..<2 { try await race.join(seat: seat, transport: transports[seat]) }
            var seq: UInt32 = 0
            await queue.rig.sail(race, [0, 1], to: 30, seq: &seq)
            #expect(await queue.rig.lifecycle.rejoinable("T:1"))
            let roster = await race.host.rosterEntries
            #expect(await race.quit(seat: 1, transport: transports[1]))
            #expect(await eventually { await queue.matchmaker.state(of: "T:1") == .idle })
            #expect(await eventually { await queue.rig.lifecycle.seat(of: "T:1") == nil })
            #expect(await !queue.rig.lifecycle.rejoinable("T:1"))
            try await queue.matchmaker.join(players[1])
            await queue.rig.sail(race, [0], to: 60, seq: &seq)
            if case .dropped = await race.host.controller(seat: 1) {} else { Issue.record("seat 1 isn't covered") }
            #expect(await race.host.controller(seat: 1).driver?.isCautious == true)
            var marked = roster
            marked[1].isDisconnected = true
            #expect(await race.host.rosterEntries == marked)
            #expect(await race.host.botSeats.allSatisfy { $0.source == .fill })
            #expect(transports[0].messages.filter { $0.type == .rosterChange } == [.rosterChange(RosterChange(seat: 1, entry: marked[1]))])
            #expect(try await queue.leaves("T:1") == 0)
            #expect(await queue.matchmaker.state(of: "T:0") == .fleetLocked)
        }

        @Test func leaveFromABotSeatOrAfterCloseIsIgnored() async throws {
            let rig = LifecycleRig(settings: LifecycleRig.quickGrace())
            let race = try await rig.race(["T:0"], seats: 4)
            let transport = KeptTransport()
            try await race.join(seat: 0, transport: transport)
            await rig.run(race, to: -30)
            let roster = await race.host.rosterEntries
            // A bot's seat, a seat no race has, and a connection that holds no seat.
            #expect(await !race.quit(seat: 2))
            #expect(await !race.quit(seat: 2, transport: transport))
            #expect(await !race.quit(seat: 9))
            #expect(await !race.quit(seat: 0, transport: KeptTransport()))
            #expect(await race.host.rosterEntries == roster)
            #expect(await race.host.botSeats.map(\.seat) == [1, 2, 3])
            #expect(await !race.host.hasLeft(seat: 0))
            #expect(!transport.isClosed)

            // Once the race has ended, cancelled or closed, a leave does nothing and counts nothing.
            await race.host.cancel(.unspecified)
            #expect(await !race.quit(seat: 0, transport: transport))
            #expect(await !race.host.hasLeft(seat: 0))
            await rig.end(race)

            let closed = try await rig.race(["T:1"], seats: 4)
            let held = KeptTransport()
            try await closed.join(seat: 0, transport: held)
            await rig.run(closed, to: 30)
            let outcome = await closed.host.close()
            #expect(await !closed.quit(seat: 0, transport: held))
            #expect(await closed.host.close().log.seatEvents == outcome.log.seatEvents)
            #expect(await closed.host.rosterEntries.map(\.isBot) == [false, true, true, true])
        }

        /// Over a real race connection: `LeaveRace` from a seated connection gives the seat to a bot and closes the
        /// connection; the other seat's connection gets the `RosterChange`; from a connection that hasn't joined it is
        /// out of turn, and changes nothing.
        @Test func leaveRaceOverTheRaceConnection() async throws {
            let config = ServerConfig.dev(host: "127.0.0.1", port: 0)
            let server = try await RegattaHTTPServer.start(config: config)
            do {
                let setup = try RaceSetup(raceSeed: RaceSeed(149), seats: [.human, .human, .bot, .bot], laps: 1,
                                          startSequenceTicks: 60 * Race.tickRate)
                let session = RaceSession(setup: setup, windSeed: WindSeed(149),
                                          roster: LockedFleet.roster(setup: setup, humans: ["Ann", "Bea"]),
                                          fleet: FleetFill(medianRating: 1500))
                try await server.registry.start(session)
                func token(_ seat: Int) throws -> [UInt8] {
                    try #require(RaceToken(raceID: session.id, seat: seat, expiresAt: Int64(Date().timeIntervalSince1970) + 600)
                        .signed(with: config.tokenKey))
                }
                func open(_ seat: Int?) async throws -> WebSocketRaceTransport {
                    let transport = try await WebSocketRaceTransport.connect(host: "127.0.0.1", port: server.port, clock: { 0 })
                    transport.send(try Frame(seq: 1, tick: 0, message: .hello(Hello(clientBuild: "test", files: []))).encoded())
                    if let seat { transport.send(try Frame(seq: 2, tick: 0, message: .joinRace(JoinRace(token: try token(seat)))).encoded()) }
                    return transport
                }
                // Closed by the server: up until what came before the close has been read.
                func gone(_ transport: WebSocketRaceTransport) async -> Bool {
                    await eventually {
                        _ = transport.receive()
                        return !transport.isConnected
                    }
                }
                let ann = try await open(0), bea = try await open(1)
                #expect(await eventually { await session.host.isAttached(seat: 0) })
                #expect(await eventually { await session.host.isAttached(seat: 1) })

                // Out of turn: before any join.
                let stranger = try await open(nil)
                stranger.send(try Frame(seq: 2, tick: 0, message: .leaveRace).encoded())
                #expect(await gone(stranger))
                #expect(await !session.host.hasLeft(seat: 0))
                #expect(await !session.host.hasLeft(seat: 1))

                bea.send(try Frame(seq: 3, tick: 0, message: .leaveRace).encoded())
                #expect(await eventually { await session.host.hasLeft(seat: 1) })
                #expect(await gone(bea))
                let entry = await session.host.rosterEntries[1]
                #expect(entry.isBot && FleetRoster.sailingNames.contains(entry.name))
                if case .bot = await session.host.controller(seat: 1) {} else { Issue.record("seat 1 isn't a fleet bot") }
                let heard = Kept<Message>()
                #expect(await eventually {
                    for bytes in ann.receive() { if let frame = try? Frame(decoding: bytes) { heard.append(frame.message) } }
                    return heard.all.contains(.rosterChange(RosterChange(seat: 1, entry: entry)))
                })
                guard case .raceStart(let start)? = heard.all.first(where: { $0.type == .raceStart }) else {
                    Issue.record("no RaceStart")
                    await server.shutdown()
                    return
                }
                #expect(start.roster.map(\.isBot) == [false, false, true, true] && start.setup.seats == setup.seats)
                #expect(ann.isConnected)
                #expect(await session.host.isAttached(seat: 0))
                // Her token no longer seats anyone.
                let again = try await open(1)
                #expect(await gone(again))
                await session.host.cancel(.unspecified)
                await ann.close()
            } catch {
                await server.shutdown()
                throw error
            }
            await server.shutdown()
        }
    }
}
