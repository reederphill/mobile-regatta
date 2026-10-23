import RegattaCore
import RegattaServices
import Synchronization
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
            "joinable-hold", "rejoinable", "race-gone", "profile-established", "lobby-free-text", "lobby-muted", "lobby-banned",
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
            case .joinable, .joinableAlone, .joinableHold, .rejoinable, .raceGone, .profileEstablished, .lobbyFreeText, .lobbyMuted,
                 .lobbyBanned:
                #expect(lobby == (scenario == .rejoinable ? .closed(.racing) : .open), "\(scenario): the lobby")
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

    /// The profile each scenario's server keeps (#139): a new player's, but for `profile-established`'s.
    @Test func everySignedInScenarioHasANewPlayersProfileButTheEstablishedOne() async throws {
        for scenario in FakeServiceScenario.allCases where scenario.startsSignedIn {
            let profile = try await ServiceSet.fake(scenario).profile.profile()
            #expect(profile.nickname == "Sailor", "\(scenario)")
            if scenario == .profileEstablished {
                #expect(profile.rating == Rating(value: 1586, isProvisional: false))
                #expect(profile.completedRaces == 32 && profile.wins == 4)
                #expect(profile.progress == EarnedProgress(
                    earned: [DesignID("skiff-earned-10")], next: EarnedMilestone(design: DesignID("skiff-earned-50"), completedRaces: 50)),
                    "32 / 50 races")
            } else {
                #expect(profile.rating == Rating(value: 1500, isProvisional: true), "\(scenario): a new player")
                #expect(profile.completedRaces == 0 && profile.wins == 0, "\(scenario)")
                #expect(profile.progress == EarnedProgress(
                    earned: [], next: EarnedMilestone(design: DesignID("skiff-earned-10"), completedRaces: 10)), "\(scenario): 0 / 10 races")
            }
            switch scenario {
            case .suspended: #expect(profile.suspension == RacingSuspension(until: FakeServiceScenario.suspendedUntil))
            case .suspendedPermanent: #expect(profile.suspension == RacingSuspension(until: nil))
            default: #expect(profile.suspension == nil, "\(scenario): no suspension")
            }
        }
    }

    /// The profile follows Game Center (#139): `signed-out`'s comes in with the sign-in, and a scenario whose
    /// sign-in gives nobody never has one.
    @Test func theProfileFollowsTheSignIn() async throws {
        let signedOut = ServiceSet.fake(.signedOut)
        await #expect(throws: ProfileError.notSignedIn) { try await signedOut.profile.profile() }
        await #expect(throws: ProfileError.notSignedIn) { try await signedOut.profile.saveLivery(Livery(
            design: DesignID("skiff-plain"), colours: [SwatchID("sky-blue"), SwatchID("white")], sailNumber: 207)) }
        let player = try #require(await signedOut.identity.signIn().player)
        let profile = try await signedOut.profile.profile()
        #expect(profile.gamePlayerID == player.gamePlayerID)
        #expect(profile.rating == Rating(value: 1500, isProvisional: true) && profile.completedRaces == 0)

        for scenario in FakeServiceScenario.allCases where scenario.playsSession {
            let services = ServiceSet.fake(scenario)
            _ = await services.identity.signIn()
            await #expect(throws: ProfileError.notSignedIn, "\(scenario)") { try await services.profile.profile() }
        }
    }

    /// The lobby follows Game Center and the terms (#142, T6): `signed-out`'s opens after the sign-in and I agree, and
    /// a scenario whose sign-in gives nobody stays closed.
    @Test func theLobbyFollowsTheSignInAndTheTerms() async throws {
        let services = ServiceSet.fake(.signedOut)
        #expect(try await services.lobby.state().access == .closed(.notSignedIn))
        await #expect(throws: LobbyError.closed(.notSignedIn)) { try await services.lobby.history() }
        await #expect(throws: LobbyError.closed(.notSignedIn)) { try await services.lobby.post(.gg) }
        #expect(await Self.first(services.lobby.feed()) == .state(LobbyState(access: .closed(.notSignedIn), canPostFreeText: false)))

        _ = await services.identity.signIn()
        #expect(try await services.lobby.state().access == .closed(.termsNotAccepted))
        await #expect(throws: LobbyError.closed(.termsNotAccepted)) { try await services.lobby.history() }

        #expect(try await services.terms.accept(TermsVersion(1)).isAccepted)
        #expect(try await services.lobby.state().access == .open)
        #expect(try await services.lobby.history().count == 7)
        #expect(await Self.first(services.lobby.feed()) == .state(LobbyState(access: .open, canPostFreeText: false)))
        #expect(try await services.lobby.post(.gg).post?.delivery == .sent)

        let bump = ServiceSet.fake(.termsBump)
        #expect(try await bump.lobby.state().access == .closed(.termsNotAccepted))
        #expect(try await bump.terms.accept(TermsVersion(2)).isAccepted)
        #expect(try await bump.lobby.state().access == .open, "the new terms accepted")

        for scenario in FakeServiceScenario.allCases where scenario.playsSession {
            let services = ServiceSet.fake(scenario)
            _ = await services.identity.signIn()
            #expect(try await services.lobby.state().access == .closed(.notSignedIn), "\(scenario)")
        }
    }

    /// Every scenario's lobby opens on the same lines (#142): a gun and a winner, and five sailors' posts, established
    /// and provisional, quick-chat and free text, Wren's last.
    @Test func everyLobbyOpensOnTheSameRicherHistory() async throws {
        let history = try await ServiceSet.fake(.joinable).lobby.history()
        #expect(history.map(\.id.rawValue) == (1...7).map { "fake-\($0)" })
        #expect(history.first?.kind == .system(.gun(venue: "Fellmere", boats: 10, humans: 2)))
        #expect(history.contains { $0.kind == .system(.winner(venue: "Fellmere", nickname: "Tern")) })
        let posts = history.compactMap(\.post)
        #expect(posts.count == 5)
        #expect(Set(posts.map(\.author.gamePlayerID)).count == 5, "five sailors")
        #expect(posts.contains { $0.author.rating.isProvisional } && posts.contains { !$0.author.rating.isProvisional })
        #expect(posts.contains { if case .text = $0.body { true } else { false } })
        #expect(posts.allSatisfy { $0.delivery == .sent })
        let wren = try #require(posts.last?.author)
        #expect(wren.nickname == "Wren" && wren.gamePlayerID == GamePlayerID("G:fake-2") && wren.rating == Rating(value: 1610, isProvisional: false))
        #expect(posts.last?.body == .quickChat(.oneMore))

        for scenario in FakeServiceScenario.allCases where scenario.startsSignedIn {
            let lobby = ServiceSet.fake(scenario).lobby
            guard try await lobby.state().access == .open else { continue }
            #expect(try await lobby.history() == history, "\(scenario)")
        }
    }

    /// The lobby scenarios (#142): free text unlocked with a filter, a mute with its end, a ban; `rejoinable` silent;
    /// the rest locked to quick-chat, clear.
    @Test func theLobbyScenariosStates() async throws {
        for scenario in FakeServiceScenario.allCases where scenario.startsSignedIn {
            let state = try await ServiceSet.fake(scenario).lobby.state()
            #expect(state.canPostFreeText == (scenario == .lobbyFreeText), "\(scenario): free text")
            switch scenario {
            case .lobbyMuted: #expect(state.standing == .muted(until: FakeServiceScenario.mutedUntil, isAutomatic: false))
            case .lobbyBanned: #expect(state.standing == .banned)
            default: #expect(state.standing == .clear, "\(scenario)")
            }
        }

        let free = ServiceSet.fake(.lobbyFreeText).lobby
        #expect(try await free.post("fair winds").post?.delivery == .sent)
        let scripted = try #require(free as? ScriptedLobbyService)
        await scripted.advance(seconds: 3)
        let blocked = try await free.post("what a badword")
        #expect(blocked.post?.delivery == .notSent && blocked.post?.body == .text("what a badword"))
        #expect(try await free.history().contains { $0.id == blocked.id } == false, "only she sees it")

        let muted = ServiceSet.fake(.lobbyMuted).lobby
        await #expect(throws: LobbyError.muted(until: FakeServiceScenario.mutedUntil)) { try await muted.post(.gg) }
        #expect(try await muted.history().count == 7, "she still reads")
        await #expect(throws: LobbyError.banned) { try await ServiceSet.fake(.lobbyBanned).lobby.post(.gg) }
        await #expect(throws: LobbyError.freeTextLocked) { try await ServiceSet.fake(.joinable).lobby.post("hello") }

        let silent = ServiceSet.fake(.rejoinable).lobby
        await #expect(throws: LobbyError.closed(.racing)) { try await silent.history() }
        await #expect(throws: LobbyError.closed(.racing)) { try await silent.post(.gg) }
        #expect(await Self.first(silent.feed()) == .state(LobbyState(access: .closed(.racing), canPostFreeText: false)))
    }

    /// The fake's cooldown mirrors the hub's (#152, T7): 3 blocked posts inside 60 s → `rateLimited(30)` on the next;
    /// 3 more within 600 s of that start → 120; a refused post counts for nothing.
    @Test func blockedPostsStartTheHubsCooldown() async throws {
        let lobby = try #require(ServiceSet.fake(.lobbyFreeText).lobby as? ScriptedLobbyService)
        for _ in 0..<3 {
            #expect(try await lobby.post("badword").post?.delivery == .notSent)
            await lobby.advance(seconds: 3)
        }
        await #expect(throws: LobbyError.rateLimited(retryAfterSeconds: 27)) { try await lobby.post(.gg) }
        await lobby.advance(seconds: 27)
        #expect(try await lobby.post(.gg).post?.delivery == .sent, "the cooldown is over")

        // Two blocked posts spread past the window start nothing.
        let spread = try #require(ServiceSet.fake(.lobbyFreeText).lobby as? ScriptedLobbyService)
        for _ in 0..<3 {
            _ = try await spread.post("badword")
            await spread.advance(seconds: 31)
        }
        #expect(try await spread.post(.gg).post?.delivery == .sent, "never 3 inside 60 s")

        // Again within the repeat window: the long one.
        await lobby.advance(seconds: 3)
        for _ in 0..<3 {
            _ = try await lobby.post("badword")
            await lobby.advance(seconds: 3)
        }
        await #expect(throws: LobbyError.rateLimited(retryAfterSeconds: 117)) { try await lobby.post(.gg) }
        await #expect(throws: LobbyError.rateLimited(retryAfterSeconds: 117)) { try await lobby.post("badword") }
        await lobby.advance(seconds: 117)
        #expect(try await lobby.post(.wave).post?.delivery == .sent)

        // Past the repeat window, the short one again.
        await lobby.advance(seconds: 700)
        for _ in 0..<3 {
            _ = try await lobby.post("badword")
            await lobby.advance(seconds: 3)
        }
        await #expect(throws: LobbyError.rateLimited(retryAfterSeconds: 27)) { try await lobby.post(.gg) }
    }

    /// Given the app's clock, the lobby's rate limit lifts with time (#142): the app's fakes post more than once.
    @Test func theAppsClockMovesTheRateLimit() async throws {
        final class Clock: Sendable {
            let seconds = Mutex(1_000)
        }
        let clock = Clock()
        let lobby = ServiceSet.fake(.joinable, clock: { clock.seconds.withLock { $0 } }).lobby
        #expect(try await lobby.post(.gg).post?.delivery == .sent)
        await #expect(throws: LobbyError.rateLimited(retryAfterSeconds: 3)) { try await lobby.post(.gg) }
        clock.seconds.withLock { $0 += 3 }
        #expect(try await lobby.post(.wave).post?.delivery == .sent)
    }

    /// The boat cards (#142): another sailor's current livery and sail number; none for herself, a stranger or a
    /// blocked player; closed as the lobby is.
    @Test func theLobbyGivesOtherSailorsBoatCards() async throws {
        let lobby = ServiceSet.fake(.joinable).lobby
        let wren = GamePlayerID("G:fake-2")
        let card = try await lobby.boatCard(wren)
        #expect(card.nickname == "Wren" && card.rating == Rating(value: 1610, isProvisional: false))
        #expect(card.livery.sailNumber == 112)
        let author = try #require(try await lobby.history().compactMap(\.post?.author).first { $0.gamePlayerID == wren })
        #expect(author.chip == LiveryChip(deck: card.livery.colours[0], sail: card.livery.colours[1]), "the chip is the card's livery")
        await #expect(throws: LobbyError.unknownPlayer) { try await lobby.boatCard(GamePlayerID("G:fake-1")) }
        await #expect(throws: LobbyError.unknownPlayer) { try await lobby.boatCard(GamePlayerID("G:nobody")) }
        try await lobby.block(wren)
        await #expect(throws: LobbyError.unknownPlayer) { try await lobby.boatCard(wren) }
        await #expect(throws: LobbyError.closed(.notSignedIn)) { try await ServiceSet.fake(.signedOut).lobby.boatCard(wren) }
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
