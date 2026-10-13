import RegattaCore
import RegattaProtocol
import RegattaServiceClient
import RegattaServices
import Testing

/// The queue, the race session and the profile on the online session (#162): calls on whichever connection is open,
/// a wait for one that isn't, a timeout for a server that doesn't answer, and streams that outlive their connections.
/// On the session's scripted peer and virtual time (`SessionRig`).
@Suite(.timeLimit(.minutes(1))) struct SessionServicesTests {
    private func calls(_ rig: SessionRig) -> [String] {
        rig.server.events.items.compactMap { if case .call(let name, _) = $0 { name } else { nil } }
    }

    /// The server's queue stream says "terms not accepted" and ends for a player who hasn't (its gate): once she has
    /// accepted them on the session, the queue is read again, or the join that follows would never hear its state.
    @Test func theQueueStreamIsReadAgainOnceTheTermsAreAccepted() async throws {
        let rig = SessionRig()
        rig.server.script { $0.queue = .unavailable(.termsNotAccepted) }
        await rig.opened()
        var queue = rig.session.queue.stateUpdates().makeAsyncIterator()
        #expect(await queue.next() == .unavailable(.termsNotAccepted))
        rig.server.script { $0.queue = .idle }
        #expect(try await rig.session.terms.accept(TermsVersion(2)) == .accepted(TermsVersion(2)))
        #expect(await queue.next() == .idle)
        #expect(rig.server.connects == 1)
    }

    @Test func joinAndLeaveGoThroughTheOpenConnection() async throws {
        let rig = SessionRig()
        await rig.opened()
        let queue = rig.session.queue
        try await queue.join()
        try await queue.leave()
        #expect(calls(rig) == ["join", "leave"])

        // The server's answers are the queue's errors, not the session's.
        rig.server.script { $0.join = .refused(QueueRefusal.cooldown(secondsRemaining: 252).wire) }
        await #expect(throws: QueueError.refused(.cooldown(secondsRemaining: 252))) { try await queue.join() }
        rig.server.script { $0.join = .alreadyQueued }
        await #expect(throws: QueueError.alreadyQueued) { try await queue.join() }
        rig.server.script { $0.leave = .notQueued }
        await #expect(throws: QueueError.notQueued) { try await queue.leave() }
        #expect(rig.server.connects == 1)

        // With no connection there is no place to give up (the server dropped it with the connection): a leave says so
        // at once.
        await rig.session.setOnline(false)
        await #expect(throws: QueueError.notQueued) { try await queue.leave() }
        #expect(!rig.sleeper.requested.contains(SessionRig.openWait))
    }

    @Test func aCallWaitsForTheSessionToOpenThenSaysNotConnected() async throws {
        let rig = SessionRig(isOnline: false)
        await rig.session.start()
        let queue = rig.session.queue
        // The session opens while the call waits: it goes through.
        async let joined: Void = queue.join()
        await rig.sleeper.waitForSleep(of: SessionRig.openWait)
        #expect(calls(rig) == [])
        await rig.session.setOnline(true)
        try await joined
        #expect(calls(rig) == ["join"])

        // It doesn't: the wait runs out.
        await rig.session.setOnline(false)
        let late = Task { try await queue.join() }
        await rig.sleeper.waitForSleep(of: SessionRig.openWait)
        rig.sleeper.advance(by: SessionRig.openWait)
        await #expect(throws: OnlineSessionError.notConnected) { try await late.value }
        #expect(calls(rig) == ["join"])
    }

    @Test func aRequestWithNoReplyTimesOut() async throws {
        let rig = SessionRig()
        await rig.opened()
        rig.server.script { $0.handOff = nil }
        let raceSession = rig.session.raceSession
        let handOff = Task { try await raceSession.handOff() }
        await rig.sleeper.waitForSleep(of: SessionRig.callTimeout)
        rig.sleeper.advance(by: SessionRig.callTimeout)
        // No answer isn't "no race".
        await #expect(throws: OnlineSessionError.timedOut) { _ = try await handOff.value }

        // The answer that comes after all is dropped, and the connection is as good as before.
        rig.server.answerHeld(.noRace)
        rig.server.script { $0.handOff = .handOff(Fixtures.handOff.wire) }
        #expect(try await raceSession.handOff() == Fixtures.handOff)
        rig.server.script { $0.rejoin = .noRace }
        await #expect(throws: RaceSessionError.noRace) { _ = try await raceSession.rejoin() }
        #expect(try await raceSession.lastRace() == nil)
        #expect(rig.server.connects == 1)
        #expect(await rig.session.phase == .open(SessionRig.wren.player))
    }

    @Test func theResultsStreamIsReopenedAfterAReconnectAndEndsAtTheClose() async {
        let rig = SessionRig()
        await rig.opened()
        rig.server.script { $0.results = [.report(Fixtures.reports[0])] }
        var results = rig.session.raceSession.results().makeAsyncIterator()
        #expect(await results.next() == .report(Fixtures.reports[0]))
        rig.server.push(RaceUpdate.report(Fixtures.reports[1]))
        #expect(await results.next() == .report(Fixtures.reports[1]))

        // The connection goes: the same stream, primed by the new connection with the report as it stands.
        rig.server.script { $0.results = [.report(Fixtures.reports[1])] }
        rig.server.dropLink()
        await rig.opens(2)
        #expect(await results.next() == .report(Fixtures.reports[1]))
        rig.server.push(RaceUpdate.report(Fixtures.reports[2]))
        #expect(await results.next() == .report(Fixtures.reports[2]))
        // Closed: nothing more comes.
        #expect(await results.next() == nil)
        #expect(calls(rig).filter { $0 == "openResults" }.count == 2)
    }

    @Test func theRatingStreamOutlivesReconnectsAndGetsPendingChanges() async {
        let rig = SessionRig(isOnline: false)
        await rig.session.start()
        // Held from before there was a session.
        var ratings = rig.session.raceSession.ratingChanges().makeAsyncIterator()
        let pending = RatingChange(raceID: RaceID("race-6"), outcome: .unrated)
        rig.server.script { $0.ratings = [pending] }
        await rig.session.setOnline(true)
        #expect(await ratings.next() == pending)
        rig.server.script { $0.ratings = [] }
        rig.server.dropLink()
        await rig.opens(2)
        await rig.server.events.wait { $0.filter { $0 == .call("openRatingChanges", link: 2) }.count == 1 }
        rig.server.push(Fixtures.rating)
        #expect(await ratings.next() == Fixtures.rating)
    }

    @Test func aCancelledRaceEndsTheResultsStream() async {
        let rig = SessionRig()
        await rig.opened()
        rig.server.script { $0.results = [.report(Fixtures.reports[0]), .cancelled(.serverShutdown)] }
        var results = rig.session.raceSession.results().makeAsyncIterator()
        #expect(await results.next() == .report(Fixtures.reports[0]))
        #expect(await results.next() == .cancelled(.serverShutdown))
        #expect(await results.next() == nil)
    }

    @Test func profileLiveryGoesThroughTheOpenConnection() async throws {
        let rig = SessionRig()
        await rig.opened()
        let stored = Fixtures.profile(races: 0, wins: 0)
        rig.server.script { $0.profile = .profile(stored.wire) }
        let profile = rig.session.profile
        #expect(try await profile.profile() == stored)
        var mine = Fixtures.livery
        mine.sailNumber = 88
        #expect(try await profile.saveLivery(mine) == mine)
        rig.server.script { $0.saveLivery = .liveryLocked }
        await #expect(throws: ProfileError.liveryLocked) { _ = try await profile.saveLivery(mine) }
        rig.server.script { $0.saveLivery = .invalidLivery(.notOwned) }
        await #expect(throws: ProfileError.invalidLivery(.notOwned)) { _ = try await profile.saveLivery(mine) }
        #expect(calls(rig) == ["profile", "saveLivery 88", "saveLivery 88", "saveLivery 88"])
    }
}
