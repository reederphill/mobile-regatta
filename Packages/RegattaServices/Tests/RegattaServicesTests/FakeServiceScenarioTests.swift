import RegattaCore
import RegattaServices
import Testing

/// The app's `-fakeServices` scenarios (#242): each builds every service, and its fakes report the scenario's state.
@Suite struct FakeServiceScenarioTests {
    /// The first item of a stream.
    static func first<Element: Sendable>(_ stream: AsyncStream<Element>) async -> Element? {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
    }

    @Test func everyScenarioBuildsItsServices() async throws {
        #expect(FakeServiceScenario.allCases.map(\.rawValue) == [
            "signed-out", "underage", "communication-restricted", "multiplayer-restricted", "offline", "queued", "cancelled-race",
            "online-results", "online-results-unrated", "terms-bump", "suspended", "suspended-permanent", "cooldown", "cannot-race",
            "update-required", "terms-save-failed", "session-failed", "unreachable", "connecting", "joinable", "joinable-alone",
            "joinable-hold",
        ])
        for scenario in FakeServiceScenario.allCases {
            let services = ServiceSet.fake(scenario)
            let player = await services.identity.state().player
            let queue = await Self.first(services.queue.stateUpdates())
            let lobby = try await services.lobby.state().access
            let online = await services.connectivity.status()

            #expect((player == nil) == !scenario.startsSignedIn, "\(scenario): signed in")
            #expect(online == (scenario == .offline ? .offline : .online), "\(scenario): connectivity")
            if player != nil {
                #expect(try await services.terms.status().isAccepted == (scenario != .termsBump), "\(scenario): terms accepted")
                #expect(try await services.profile.profile().gamePlayerID == player?.gamePlayerID, "\(scenario): profile")
            }

            switch scenario {
            case .signedOut:
                #expect(queue == .unavailable(.notSignedIn))
                #expect(lobby == .closed(.notSignedIn))
                await #expect(throws: ProfileError.notSignedIn) { try await services.profile.profile() }
                #expect(await services.identity.signIn().player != nil, "signing in gives a player")
                // Past the gate she joins the queue (#140): the fake queue takes the join for the sign-in.
                try await services.queue.join()
                var states: [QueueState] = []
                for await state in services.queue.stateUpdates() { states.append(state) }
                #expect(states == [.idle] + FakeServiceScenario.joinable.afterJoin)
            case .underage:
                #expect(player?.isUnderage == true && player?.canChat == false)
                #expect(lobby == .closed(.communicationRestricted))
                #expect(queue == .idle)
            case .communicationRestricted:
                #expect(player?.isPersonalizedCommunicationRestricted == true && player?.canChat == false)
                #expect(lobby == .closed(.communicationRestricted))
                #expect(queue == .idle)
            case .multiplayerRestricted:
                #expect(player?.canRaceOnline == false && player?.canChat == true)
                #expect(queue == .unavailable(.multiplayerRestricted))
                #expect(lobby == .open)
            case .termsBump:
                let terms = try await services.terms.status()
                #expect(terms == .needsAcceptance(current: TermsVersion(2), lastAccepted: TermsVersion(1)), "the sheet asks again")
                #expect(lobby == .closed(.termsNotAccepted))
                #expect(try await services.terms.accept(TermsVersion(2)).isAccepted)
                try await services.queue.join()
                #expect(try await services.raceSession.handOff().briefing == FakeServiceScenario.briefing(), "a queue to join, to its briefing")
            case .offline:
                await #expect(throws: StoreError.offline) { try await services.store.products() }
                await #expect(throws: AnalyticsError.unavailable) {
                    try await services.analytics.send(AnalyticsBatch(installID: InstallID("i"), events: []))
                }
            case .queued:
                guard case .queued(let status)? = queue else {
                    Issue.record("queued starts at \(String(describing: queue))")
                    continue
                }
                #expect(status.queuedPlayers > 0)
                var states = services.queue.stateUpdates().makeAsyncIterator()
                var last: QueueState?
                while let state = await states.next() { last = state }
                #expect(last == .fleetLocked, "the countdown ends in fleet lock")
                #expect(try await services.raceSession.handOff().raceID == RaceID("fake-race"))
                #expect(try await services.raceSession.handOff().briefing == FakeServiceScenario.briefing())
            // The queue from a tap to fleet lock (#140): idle, and a join plays the wait.
            case .joinable, .joinableAlone, .joinableHold:
                #expect(queue == .idle)
                await #expect(throws: QueueError.notQueued) { try await services.queue.leave() }
                try await services.queue.join()
                var states: [QueueState] = []
                for await state in services.queue.stateUpdates() { states.append(state) }
                #expect(states == [.idle] + scenario.afterJoin, "\(scenario): the wait after a join")
                #expect(states.suffix(2) == [.fleetLocked, .idle], "the fakes sail no race: the queue is free after the lock")
                // Race online again after the lock (#140): the wait plays again.
                try await services.queue.join()
                var again: [QueueState] = []
                for await state in services.queue.stateUpdates() { again.append(state) }
                #expect(again == states)
                let waits = states.compactMap { state -> QueuedStatus? in
                    if case .queued(let status) = state { status } else { nil }
                }
                if scenario == .joinableAlone { #expect(waits.allSatisfy { $0.queuedPlayers == 1 }, "nobody else waits") }
                #expect((waits.first?.secondsToLock ?? 0 > 60) == (scenario == .joinableHold), "only a hold waits longer than a minute")
                #expect(waits.last?.secondsToLock == 0, "the fleet is being set before it locks")
                let briefing = try #require(try await services.raceSession.handOff().briefing)
                #expect(briefing.fleet.count == 6 && briefing.setup.fleetSize == 6)
                #expect(briefing.fleet.filter(\.isBot).count == 2)
                #expect(briefing.fleet.allSatisfy { $0.isBot == ($0.rating == nil) }, "a rating for every human, none for a bot")
                #expect(briefing.fleet.indices.allSatisfy { (briefing.setup.seats[$0] == .bot) == briefing.fleet[$0].isBot })
                #expect(Set(briefing.fleet.map(\.livery.sailNumber)).count == 6, "sail numbers as the fleet shows them")
                #expect(briefing.isMe(0) && briefing.briefingSeconds == 15 && briefing.gunInSeconds == 75)
            case .cancelledRace:
                var updates: [RaceUpdate] = []
                for await update in services.raceSession.results() { updates.append(update) }
                #expect(updates.last == .cancelled(.serverShutdown), "the race ends cancelled: \(updates)")
                #expect(try await services.raceSession.lastRace() == nil)
            case .onlineResults, .onlineResultsUnrated:
                // The streams are paced; the last race is their end.
                let last = try await services.raceSession.lastRace()
                #expect(last?.report.isClosed == true)
                #expect(last?.report.results.rated == (scenario == .onlineResults))
                #expect(last?.report.roster.count == 6)
                if case .rated = last?.rating?.outcome { #expect(scenario == .onlineResults) } else { #expect(scenario == .onlineResultsUnrated) }
                #expect(queue == .idle, "Race again can join")
                // Report (#26): another human's seat, never a bot's.
                if scenario == .onlineResults {
                    try await services.lobby.report(race: RaceID("fake-race"), seat: 2, reason: .unsportingConduct)
                }
                await #expect(throws: LobbyError.notReportable) {
                    try await services.lobby.report(race: RaceID("fake-race"), seat: 3, reason: .suspectedCheating)
                }
            // The queue's refusals (#161): each is the state a stream gives first, and stops a join.
            case .suspended:
                #expect(queue == .unavailable(.suspended(until: FakeServiceScenario.suspendedUntil)))
                await #expect(throws: QueueError.refused(.suspended(until: FakeServiceScenario.suspendedUntil))) { try await services.queue.join() }
            case .suspendedPermanent: #expect(queue == .unavailable(.suspended(until: nil)))
            case .cooldown: #expect(queue == .unavailable(.cooldown(secondsRemaining: FakeServiceScenario.cooldownSeconds)))
            case .cannotRace: #expect(queue == .unavailable(.attestationFailed))
            case .updateRequired: #expect(queue == .unavailable(.updateRequired))
            case .termsSaveFailed:
                #expect(await services.identity.signIn().player != nil, "signing in gives a player")
                #expect(try await services.terms.status() == .needsAcceptance(current: TermsVersion(1), lastAccepted: nil))
                await #expect(throws: ScriptedTermsError.notSaved) { try await services.terms.accept(TermsVersion(1)) }
                #expect(try await services.terms.status().isAccepted == false, "nothing was recorded")
            // The session's own states: these fakes stay signed out, and the app plays the session over them.
            case .sessionFailed, .unreachable, .connecting:
                #expect(scenario.playsSession)
                #expect(queue == .unavailable(.notSignedIn))
                #expect(lobby == .closed(.notSignedIn))
                #expect(await services.identity.signIn().player == nil, "no service signs her in")
            }
        }
    }

    /// A paced script gives its results one by one, then its rating change after the last (#133).
    @Test func aPacedRaceFillsInThenRates() async {
        let scenario = FakeServiceScenario.onlineRace(
            rated: true, pacing: RaceSessionPacing(interval: .milliseconds(20)) { try? await Task.sleep(for: $0) })
        let service = ScriptedRaceSessionService(scenario)
        let clock = ContinuousClock()
        let start = clock.now
        var reports: [RaceReport] = []
        for await update in service.results() {
            if case .report(let report) = update { reports.append(report) }
        }
        let closedAt = clock.now
        var ratings = service.ratingChanges().makeAsyncIterator()
        let rating = await ratings.next()
        #expect(reports.map(\.isClosed) == [false, false, false, false, true])
        #expect(reports.map(\.sailing.count) == [5, 4, 3, 2, 0])
        #expect(closedAt - start >= .milliseconds(100), "five updates, one every 20 ms")
        if case .rated(_, let after)? = rating?.outcome { #expect(after == Rating(value: 1512, isProvisional: true)) } else {
            Issue.record("no rated change: \(String(describing: rating))")
        }
    }

    /// Before the real services, the app is signed out on the device's own connectivity.
    @Test func unconnectedIsSignedOutOnTheGivenConnectivity() async {
        let services = ServiceSet.unconnected(connectivity: ScriptedConnectivityService(.offline))
        #expect(await services.identity.state() == .signedOut)
        #expect(await services.connectivity.status() == .offline)
    }
}
