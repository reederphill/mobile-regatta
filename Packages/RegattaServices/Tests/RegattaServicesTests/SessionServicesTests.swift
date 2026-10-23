import RegattaCore
import RegattaProtocol
import RegattaServiceClient
import RegattaServiceContracts
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
        // The device's player given at once, not through `start()`'s task: a join before that task has run finds
        // nobody signed in and is refused, and the wait below would never see its sleep.
        await rig.session.deviceChanged(SessionRig.wren)
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

    /// #163 (T3): the session reads rating changes on one server stream and fans them out, so a change the server
    /// replays once, on the stream it primes first, reaches every reader: the next race's results and the follower of
    /// the race before. A reader that comes later still hears the latest.
    @Test func ratingChangesAreOneStreamFannedOutToEveryReader() async {
        let rig = SessionRig()
        await rig.opened()
        let pending = RatingChange(raceID: RaceID("race-1"), outcome: .unrated)
        rig.server.script { $0.ratings = [pending] }
        var results = rig.session.raceSession.ratingChanges().makeAsyncIterator()
        var follower = rig.session.raceSession.ratingChanges().makeAsyncIterator()
        #expect(await results.next() == pending)
        #expect(await follower.next() == pending)
        rig.server.push(Fixtures.rating)
        #expect(await results.next() == Fixtures.rating)
        #expect(await follower.next() == Fixtures.rating)
        var late = rig.session.raceSession.ratingChanges().makeAsyncIterator()
        #expect(await late.next() == Fixtures.rating)
        #expect(calls(rig).filter { $0 == "openRatingChanges" }.count == 1, "one server stream for every reader")
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

    /// #166 (T1): a batch goes on the open connection only, and only for a player through the terms: the server closes the
    /// connection on a batch from one who isn't, and the session would open it again. Each case is 0 or 1 frames.
    @Test func analyticsGoOnlyOnAnOpenConnectionThroughTheTerms() async throws {
        let rig = SessionRig(isOnline: false)
        await rig.session.start()
        let analytics = rig.session.analytics
        let batch = AnalyticsBatch(installID: InstallID("install"), events: [AnalyticsEvent(sequence: 1, name: .drop, time: 1)])
        func sent() -> Int { calls(rig).filter { $0.hasPrefix("analytics") }.count }

        // No connection: the buffer keeps it, with no wait for one.
        await #expect(throws: AnalyticsError.unavailable) { try await analytics.send(batch) }
        #expect(sent() == 0)
        #expect(!rig.sleeper.requested.contains(SessionRig.openWait))

        // Open, the terms not accepted: nothing sent, and the connection stays.
        await rig.session.setOnline(true)
        await rig.opens(1)
        await #expect(throws: AnalyticsError.unavailable) { try await analytics.send(batch) }
        #expect(sent() == 0)
        #expect(rig.server.connects == 1 && !rig.server.events.items.contains(.closed(link: 1)))

        // Accepted: one frame, its receipt passed through.
        _ = try await rig.session.terms.accept(TermsVersion(2))
        #expect(try await analytics.send(batch) == AnalyticsReceipt(accepted: 1, duplicates: 0))
        #expect(sent() == 1)
        // The server's budget spent: kept for next time.
        rig.server.script { $0.analytics = .unavailable }
        await #expect(throws: AnalyticsError.unavailable) { try await analytics.send(batch) }
        #expect(sent() == 2)
        #expect(rig.server.connects == 1)
    }

    /// #166: the plan and the delete on the open connection, the server's answers as the service's errors; a delete holds
    /// her (the session idle, her token gone), and a held player is answered with no connection (T9).
    @Test func deletionPlansAndDeletesOnTheOpenConnection() async throws {
        let rig = SessionRig()
        await rig.opened()
        let deletion = rig.session.deletion
        let plan = try await deletion.plan()
        #expect(plan.deletes == Set(OnlineData.allCases) && plan.anonymisesRaceLogs)
        await #expect(throws: DataDeletionError.invalidConfirmation) {
            try await deletion.delete(confirmedBy: DeletionConfirmation(token: "forged"))
        }
        try await deletion.delete(confirmedBy: plan.confirmation)
        #expect(calls(rig) == ["plan", "delete", "delete"])
        #expect(await rig.session.isHeld)
        #expect(await rig.session.phase == .idle)
        #expect(rig.tokens.all == [:])
        await #expect(throws: DataDeletionError.nothingToDelete) { _ = try await deletion.plan() }
        #expect(calls(rig).count == 3 && rig.server.connects == 1)

        // Nothing held on the server: said so, and nobody is held.
        let empty = SessionRig()
        empty.server.script { $0.holdsOnlineData = false }
        await empty.opened()
        await #expect(throws: DataDeletionError.nothingToDelete) { _ = try await empty.session.deletion.plan() }
        #expect(await !empty.session.isHeld)

        // No Game Center player: no connection to wait for.
        let signedOut = SessionRig(player: nil)
        await #expect(throws: DataDeletionError.notSignedIn) { _ = try await signedOut.session.deletion.plan() }
        #expect(signedOut.server.connects == 0)
    }

    /// The #109 contract, on the session over the scripted server.
    @Test func theSessionsDeletionKeepsTheContract() async throws {
        try await DataDeletionServiceContract().run { situation in
            let rig = SessionRig(player: situation == .signedOut ? nil : SessionRig.wren)
            rig.server.script { $0.holdsOnlineData = situation == .hasOnlineData }
            if situation != .signedOut { await rig.opened() }
            return rig.session.deletion
        }
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
