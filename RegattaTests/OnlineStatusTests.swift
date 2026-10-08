import RegattaServices
import Testing
@testable import Regatta

/// What Home reads from the services (#242, #314): connectivity from the first frame, the queued count only while
/// queued, and Race online's restricted state.
@MainActor @Suite struct OnlineStatusTests {
    private static func options(_ arguments: String...) -> LaunchOptions { LaunchOptions(arguments: ["Regatta"] + arguments) }

    /// The offline scenario is offline before its connectivity stream says so: no online first frame.
    @Test func theOfflineScenarioIsOfflineFromTheFirstFrame() {
        let offline = Self.options("-fakeServices", "offline")
        let status = OnlineStatus(services: .fake(.offline), isInitiallyOnline: OnlineStatus.isInitiallyOnline(offline))
        #expect(!status.isOnline)
        #expect(OnlineStatus.isInitiallyOnline(Self.options()), "the device's path starts optimistic")
        #expect(OnlineStatus.isInitiallyOnline(Self.options("-fakeServices", "queued")))
    }

    /// The queued count shows while queued and clears when the player isn't any more.
    @Test func theQueuedCountClearsWhenNoLongerQueued() {
        let status = OnlineStatus(services: .fake(.signedOut))
        for after: QueueState in [.idle, .fleetLocked, .unavailable(.cooldown(secondsRemaining: 30))] {
            status.show(.queued(QueuedStatus(queuedPlayers: 7, secondsToLock: 20)))
            #expect(status.lobbyStatus.queuedPlayers == 7)
            status.show(after)
            #expect(status.lobbyStatus.queuedPlayers == nil, "\(after) keeps a queued count")
        }
    }

    /// Race online: enabled online; "Offline" offline; "Practice races only" when Game Center restricts
    /// multiplayer (a signed-in player's flag); offline wins over the restriction.
    @Test func raceOnlineShowsWhyItIsUnavailable() {
        var restricted = LobbyStatus()
        restricted.isSignedIn = true
        restricted.canRaceOnline = false
        #expect(RaceOnlineAvailability(isOnline: true, lobbyStatus: LobbyStatus()) == RaceOnlineAvailability(isEnabled: true, reason: nil))
        #expect(RaceOnlineAvailability(isOnline: false, lobbyStatus: LobbyStatus()) == RaceOnlineAvailability(isEnabled: false, reason: "Offline"))
        #expect(RaceOnlineAvailability(isOnline: true, lobbyStatus: restricted)
            == RaceOnlineAvailability(isEnabled: false, reason: "Practice races only"))
        #expect(RaceOnlineAvailability(isOnline: false, lobbyStatus: restricted) == RaceOnlineAvailability(isEnabled: false, reason: "Offline"))
    }

    /// The restricted scenarios reach the lobby status: no online racing, or no chat.
    @Test func restrictedScenariosReachTheLobbyStatus() async {
        let multiplayer = OnlineStatus(services: .fake(.multiplayerRestricted))
        await multiplayer.refreshAccount()
        #expect(!multiplayer.lobbyStatus.canRaceOnline)
        #expect(multiplayer.lobbyStatus.canChat)
        #expect(!RaceOnlineAvailability(isOnline: true, lobbyStatus: multiplayer.lobbyStatus).isEnabled)

        let underage = OnlineStatus(services: .fake(.underage))
        await underage.refreshAccount()
        #expect(!underage.lobbyStatus.canChat)
        #expect(underage.lobbyStatus.canRaceOnline)
    }

    /// Home for every combination of connection, sign-in, Game Center's restrictions, the terms and Hide lobby chat
    /// (#138): Race online's state and the lobby area's, against the rules written out.
    @Test func homeFollowsTheGatingMatrixForEveryFlagCombination() {
        for bits in 0..<64 {
            let isOnline = bits & 1 != 0
            var status = LobbyStatus()
            status.isSignedIn = bits & 2 != 0
            status.canChat = bits & 4 != 0
            status.canRaceOnline = bits & 8 != 0
            status.hasAcceptedTerms = bits & 16 != 0
            status.hidesChat = bits & 32 != 0
            status.queuedPlayers = 3
            let label = "online \(isOnline), \(status)"

            let raceOnline: RaceOnlineAvailability
            let panel: LobbyPanelState
            if !isOnline {
                raceOnline = RaceOnlineAvailability(isEnabled: false, reason: "Offline")
                panel = .offline
            } else if !status.isSignedIn {
                raceOnline = RaceOnlineAvailability(isEnabled: true, reason: nil)
                panel = .signIn
            } else {
                raceOnline = status.canRaceOnline ? RaceOnlineAvailability(isEnabled: true, reason: nil)
                    : RaceOnlineAvailability(isEnabled: false, reason: "Practice races only")
                let fullyRestricted = !status.canChat && !status.canRaceOnline
                if !status.hasAcceptedTerms && !fullyRestricted {
                    panel = .acceptTerms
                } else if status.canChat && !status.hidesChat {
                    panel = .lobby
                } else {
                    panel = .chatHidden(queuedPlayers: 3)
                }
            }
            #expect(RaceOnlineAvailability(isOnline: isOnline, lobbyStatus: status) == raceOnline, "\(label)")
            #expect(LobbyPanelState(isOnline: isOnline, status: status) == panel, "\(label)")
        }
    }

    /// An analytics that keeps what's logged, to read back.
    private static func recording() -> Analytics {
        Analytics(transport: ScriptedAnalyticsTransport(), storage: InMemoryAnalyticsStorage(), isSharing: true,
                  makeInstallID: { "test" }, now: { 0 })
    }

    private static func logged(_ analytics: Analytics) -> [UsageEvent] {
        analytics.pending.map { UsageEvent(name: $0.name, properties: $0.properties) }
    }

    /// Race online signed out (#23, #34): Game Center's sign-in, then the terms; I agree, and the next tap goes
    /// through. The prompt's answer and the funnel's two steps are logged (#128).
    @Test func raceOnlineSignsInThenAsksForTheTerms() async {
        let status = OnlineStatus(services: .fake(.signedOut))
        let analytics = Self.recording()
        await status.refreshAccount()
        #expect(LobbyPanelState(isOnline: true, status: status.lobbyStatus) == .signIn)

        #expect(await status.passGate(analytics: analytics) == .terms)
        #expect(LobbyPanelState(isOnline: true, status: status.lobbyStatus) == .acceptTerms, "declining leaves the reopen")
        #expect(status.lobbyStatus.termsVersion == TermsVersion(1))
        #expect(await status.acceptTerms(analytics: analytics))
        #expect(await status.passGate(analytics: analytics) == .proceed)
        #expect(LobbyPanelState(isOnline: true, status: status.lobbyStatus) == .lobby)
        #expect(Self.logged(analytics) == [
            .gameCenterPrompt(accepted: true), .practiceToOnline(.gameCenterSignedIn), .practiceToOnline(.termsAccepted),
        ])
    }

    /// Declining Game Center's sign-in stops at home, says nothing, and logs the prompt declined (question 12).
    @Test func decliningSignInStaysHome() async {
        var services = ServiceSet.fake(.signedOut)
        services.identity = ScriptedIdentityService(IdentityScenario(initial: .signedOut))
        let status = OnlineStatus(services: services)
        let analytics = Self.recording()
        #expect(await status.passGate(analytics: analytics) == .stopped)
        #expect(!status.lobbyStatus.isSignedIn)
        #expect(Self.logged(analytics) == [.gameCenterPrompt(accepted: false)])
    }

    /// A version bump asks again, signed in, without Game Center's prompt (#34).
    @Test func aTermsVersionBumpAsksAgain() async {
        let status = OnlineStatus(services: .fake(.termsBump))
        let analytics = Self.recording()
        await status.refreshAccount()
        #expect(LobbyPanelState(isOnline: true, status: status.lobbyStatus) == .acceptTerms)
        #expect(await status.passGate(analytics: analytics) == .terms)
        #expect(status.lobbyStatus.termsVersion == TermsVersion(2))
        #expect(await status.acceptTerms(analytics: analytics))
        #expect(await status.passGate(analytics: analytics) == .proceed)
        #expect(Self.logged(analytics) == [.practiceToOnline(.termsAccepted)])
    }

    /// Restricted players (#34, question 1): multiplayer-restricted signing in still gets the terms, for the lobby,
    /// but never the queue; a player who can neither chat nor race gets no sheet at all.
    @Test func restrictedPlayersAreGatedByTheMatrix() async {
        let multiplayer = OnlineStatus(services: .fake(.multiplayerRestricted))
        await multiplayer.refreshAccount()
        #expect(await multiplayer.passGate(analytics: .discarding()) == .stopped, "terms accepted, but practice races only")

        var restricted = GameCenterPlayer(gamePlayerID: GamePlayerID("G:r"), alias: "R", isMultiplayerGamingRestricted: true)
        var services = ServiceSet.fake(.signedOut)
        services.identity = ScriptedIdentityService(IdentityScenario(initial: .signedOut, afterSignIn: .signedIn(restricted)))
        let canChat = OnlineStatus(services: services)
        #expect(await canChat.passGate(analytics: .discarding()) == .terms)
        #expect(!canChat.access.onlineAllowed, "the sheet doesn't lead to the queue")

        restricted.isUnderage = true
        services = ServiceSet.fake(.signedOut)
        services.identity = ScriptedIdentityService(IdentityScenario(initial: .signedOut, afterSignIn: .signedIn(restricted)))
        let neither = OnlineStatus(services: services)
        #expect(await neither.passGate(analytics: .discarding()) == .stopped)
        #expect(LobbyPanelState(isOnline: true, status: neither.lobbyStatus) == .chatHidden(queuedPlayers: nil))
        #expect(RaceOnlineAvailability(isOnline: true, lobbyStatus: neither.lobbyStatus).reason == "Practice races only")
    }
}
