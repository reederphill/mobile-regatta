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
            "online-results", "online-results-unrated", "terms-bump",
        ])
        for scenario in FakeServiceScenario.allCases {
            let services = ServiceSet.fake(scenario)
            let player = await services.identity.state().player
            let queue = await Self.first(services.queue.stateUpdates())
            let lobby = try await services.lobby.state().access
            let online = await services.connectivity.status()

            #expect((player == nil) == (scenario == .signedOut), "\(scenario): signed in")
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
