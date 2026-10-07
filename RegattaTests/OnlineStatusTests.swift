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
    /// multiplayer; offline wins over the restriction.
    @Test func raceOnlineShowsWhyItIsUnavailable() {
        var restricted = LobbyStatus()
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
}
