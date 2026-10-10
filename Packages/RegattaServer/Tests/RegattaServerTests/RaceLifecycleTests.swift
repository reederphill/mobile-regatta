import Crypto
import Foundation
import Persistence
import RaceHost
import RegattaCore
import RegattaProtocol
@testable import RegattaServerKit
import RegattaServices
import Testing

/// #148: an online race from fleet lock to its close or cancel, driven by hand on a manual clock.
@Suite(.timeLimit(.minutes(2))) struct RaceLifecycleTests {
    /// Acceptance: rejoin after the gun restores control within one snapshot: a fresh token for her seat and the race
    /// clock; the join sends `RaceStart` and a `Resync`, and her next input is acknowledged in the next snapshot.
    @Test func rejoinAfterGunRestoresControlWithinOneSnapshot() async throws {
        let rig = LifecycleRig()
        let race = try await rig.race(["T:0"])
        let first = KeptTransport()
        try await race.join(seat: 0, transport: first)
        var seq: UInt32 = 0
        await rig.sail(race, [0], to: -20, seq: &seq)
        await race.leave(seat: 0, transport: first)
        await rig.run(race, to: 30)
        #expect(await rig.lifecycle.phase(of: race.id) == .racing)

        let offer = try await rig.lifecycle.rejoin("T:0")
        #expect(offer.seat == 0)
        #expect(offer.clock.tick == 30)
        #expect(try #require(offer.clock.expectedCloseTick) > 30)
        #expect(offer.handOff.raceID == RaceResultsFeed.raceID(race.id))
        let token = try RaceToken.verify(offer.handOff.token.bytes, key: LifecycleRig.key, now: Int64(Date().timeIntervalSince1970))
        #expect(token.raceID == race.id && token.seat == 0)

        let back = KeptTransport()
        try await race.join(seat: token.seat, transport: back)
        #expect(back.messages.map(\.type).prefix(2) == [.raceStart, .resync])
        seq += 1
        await race.host.receive(try Frame(seq: seq, tick: 31, message: .inputHeld(BoatInput(rudder: 20 as Int8))).encoded(), from: 0)
        await rig.run(race, to: 33)
        let acked = back.messages.contains { message in
            if case .snapshot(let snapshot) = message { snapshot.ack?.seq == seq } else { false }
        }
        #expect(acked, "the snapshot at tick 33 doesn't acknowledge her input")
        #expect(await rig.lifecycle.rejoinable("T:0"))
    }

    /// #66: no rejoin before the gun (a seat left then goes to a bot; the briefing and sequence have no rejoin).
    @Test func rejoinBeforeGunRefused() async throws {
        let rig = LifecycleRig()
        let race = try await rig.race(["T:0"], startSequenceTicks: 600)
        await rig.run(race, to: -500)
        #expect(await rig.lifecycle.phase(of: race.id) == .briefing)
        await #expect(throws: RaceSessionError.noRace) { try await rig.lifecycle.rejoin("T:0") }
        await rig.run(race, to: -10)
        #expect(await rig.lifecycle.phase(of: race.id) == .sequence)
        await #expect(throws: RaceSessionError.noRace) { try await rig.lifecycle.rejoin("T:0") }
        #expect(await !rig.lifecycle.rejoinable("T:0"))
        await #expect(throws: RaceSessionError.noRace) { try await rig.lifecycle.rejoin("T:nobody") }
    }

    /// Acceptance: the queue refuses her while she has a race to rejoin, and takes her once it closes.
    @Test func queueJoinRefusedWhileRejoinableAllowedAfterClose() async throws {
        let rig = LifecycleRig()
        let clock = VirtualClock()
        var settings = QueueSettings()
        settings.startSequenceTicks = 60
        let matchmaker = QueueMatchmaker(settings: settings, registry: RaceRegistry(),
                                         draw: RaceDraw(pairings: OnlinePairing.bundled(), seeds: FixtureWindSeedPools(poolSize: 8)),
                                         tokenKey: LifecycleRig.key, tokenLifetime: 600, random: SeededRandom(seed: 3), now: { clock.now },
                                         launch: rig.lifecycle.launcher(clock: rig.clock))
        let player = QueueMatchmakerTests.player(0)
        let queue = ServerQueueService(matchmaker: matchmaker, player: player, lifecycle: rig.lifecycle)
        try await queue.join()
        clock.advance(60)
        await matchmaker.step()
        let race = try #require(await rig.started.sessions.first)

        await rig.run(race, to: 15)
        #expect(await rig.lifecycle.rejoinable(player.teamPlayerID))
        await #expect(throws: QueueError.alreadyQueued) { try await queue.join() }

        // She never attached: dropped 1 s after the race started, so every human is gone; the race closes after the grace.
        await rig.runUntilEnded(race, limit: 1_200)
        #expect(await race.host.outcome?.results != nil)
        await rig.started.end(race)
        let deadline = ContinuousClock.now + .seconds(5)
        while await matchmaker.state(of: player.teamPlayerID) != .idle, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await !rig.lifecycle.rejoinable(player.teamPlayerID))
        try await queue.join()
        #expect(await matchmaker.queuedCount == 1)
    }

    /// Two humans sail through the gun and both drop at once after it (G3's mass drop), nobody back in the grace.
    private func massDrop(_ policy: SimultaneousLossPolicy) async throws -> (LifecycleRig, RaceSession) {
        var settings = RaceLifecycleSettings()
        settings.allGone.simultaneousLossPolicy = policy
        let rig = LifecycleRig(settings: settings)
        let race = try await rig.race(["T:0", "T:1"])
        let transports = [KeptTransport(), KeptTransport()]
        for seat in 0..<2 { try await race.join(seat: seat, transport: transports[seat]) }
        var seq: UInt32 = 0
        await rig.sail(race, [0, 1], to: 30, seq: &seq)
        for seat in 0..<2 { await race.leave(seat: seat, transport: transports[seat]) }
        await rig.runUntilEnded(race, limit: 1_200)
        return (rig, race)
    }

    /// Acceptance (`cancel`, G3's default): a mass drop cancels the race: no results, no log, no last race, and the
    /// results stream says cancelled.
    @Test func simultaneousLossPolicyCancelDropsEverything() async throws {
        let (rig, race) = try await massDrop(.cancel)
        #expect(await race.host.cancelled == .unspecified)
        #expect(await race.host.outcome == nil)
        let updates = rig.lifecycle.results(for: "T:1")
        await rig.end(race)
        let read = await collect(updates) { if case .cancelled = $0 { true } else { false } }
        #expect(read.last == .cancelled(.unspecified))
        #expect(try await rig.archive.state(of: race.id) == .cancelled)
        #expect(try await rig.archive.closedRace(race.id) == nil)
        #expect(try await rig.lifecycle.lastRace(of: "T:0") == nil)
        #expect(await !rig.lifecycle.rejoinable("T:0"))
        // Her stream after the cancel says it too.
        #expect(await collect(rig.lifecycle.results(for: "T:0")) { _ in true } == [.cancelled(.unspecified)])
    }

    /// Acceptance (`ret`): the same mass drop closes the race as any all-gone race: RET in reverse leave order, rated.
    @Test func simultaneousLossPolicyRatedRetRanksByLeaveOrder() async throws {
        let (rig, race) = try await massDrop(.ret)
        let outcome = try #require(await race.host.outcome)
        let results = try #require(outcome.results)
        #expect(results.rated)
        // Both dropped in the same tick: the first gone (seat 0, by seat) is last.
        #expect(results.rows.filter { $0.code == .ret }.map(\.seat) == [1, 0])
        #expect(outcome.log.allGoneClose?.leaveOrder == [0, 1])
        await rig.end(race)
        #expect(try await rig.archive.state(of: race.id) == .closed)
        // Rated: no `.unrated` push (ratings are a later ticket's).
        let last = try #require(try await rig.lifecycle.lastRace(of: "T:0"))
        #expect(last.report.results.rated && last.report.isClosed)
    }

    /// Acceptance: every human gone (one, then the other more than 2 s later) closes via `closeAllGone` at the trigger's
    /// tick, the humans RET by leave order, the latest gone highest; the stored log replays to the stored digest.
    @Test func everyHumanGoneClosesViaCloseAllGoneRankedByLeaveOrder() async throws {
        let rig = LifecycleRig()
        let lines = rig.lifecycle.systemLines()
        let race = try await rig.race(["T:0", "T:1"])
        let transports = [KeptTransport(), KeptTransport()]
        for seat in 0..<2 { try await race.join(seat: seat, transport: transports[seat]) }
        var seq: UInt32 = 0
        await rig.sail(race, [0, 1], to: 30, seq: &seq)
        await race.leave(seat: 1, transport: transports[1])
        await rig.sail(race, [0], to: 200, seq: &seq)
        await race.leave(seat: 0, transport: transports[0])
        await rig.runUntilEnded(race, limit: 1_400)

        let outcome = try #require(await race.host.outcome)
        let results = try #require(outcome.results)
        let close = try #require(outcome.log.allGoneClose)
        #expect(close.leaveOrder == [1, 0])
        #expect(close.tick == outcome.log.finalTick)
        #expect(results.rows.filter { $0.code == .ret }.map(\.seat) == [0, 1])
        #expect(results.rows.count == 4)

        await rig.end(race)
        let stored = try #require(try await rig.archive.closedRace(race.id))
        #expect(stored.digest == outcome.digest)
        #expect(stored.simulationVersion == RegattaCore.simulationVersion && stored.toolchain == "test")
        #expect(try Replayer.digest(of: RaceLog(jsonData: stored.log)) == stored.digest)
        let line = await collect(lines) { _ in true }
        #expect(line.count == 1)
        if case .winner(let venue, _)? = line.first { #expect(venue == "Test Bay") } else { Issue.record("no winner line: \(line)") }
    }
}

/// #148 against Postgres: named `…PersistenceTests` so CI's `persistence` job runs it.
@Suite(EndpointDatabase.available, .timeLimit(.minutes(1))) struct RaceLifecyclePersistenceTests {
    /// Acceptance: a race a crash left running (kill -9: no close, no cancel) is cancelled when the server starts again;
    /// it has no results, and a client reconnecting with its token is told `RaceCancelled`.
    @Test func restartMarksRunningRacesCancelledAndTellsReconnectors() async throws {
        try await EndpointDatabase.withMigratedSchema { database in
            let store = PostgresAccountStore(database)
            _ = try await store.signIn(teamPlayerID: "T:crash", gamePlayerID: "G:crash", alias: "Crash")
            let archive = PostgresRaceArchive(database)
            // The first process registered the race and died.
            let race = UUID()
            try await archive.register(race, players: [RaceSeatHolder(playerID: "T:crash", seat: 0)])
            #expect(try await archive.state(of: race) == .running)

            // The new process, as `RegattaServer` starts: orphans cancelled before the listener binds.
            #expect(try await archive.cancelOrphans() == [race])
            var config = ServerConfig.dev()
            config.tokenKey = LifecycleRig.key
            let server = try await RegattaHTTPServer.start(config: config, services: try ServiceEndpoint.make(config: config, store: store,
                                                                                                             archive: archive))
            do {
                #expect(try await archive.state(of: race) == .cancelled)
                #expect(try await RaceResultStore(database).results(for: race) == nil)
                #expect(try await server.services.lifecycle?.lastRace(of: "T:crash") == nil)

                let token = try #require(RaceToken(raceID: race, seat: 0, expiresAt: Int64(Date().timeIntervalSince1970) + 600)
                    .signed(with: LifecycleRig.key))
                let reply = try await RaceConnectionProbe.join(token, port: server.port)
                #expect(reply == [.raceCancelled(RaceCancelled(reason: .unspecified))])
            } catch {
                await server.shutdown()
                throw error
            }
            await server.shutdown()
        }
    }
}
