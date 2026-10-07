import Observation
import RegattaServices
import SwiftUI

// The app's online services (#242): the `RegattaServices` protocols (#109, #241), read into the environment values
// the views use, so the views don't change when the real services arrive (#161–#166). A launch runs on
// `ServiceSet.unconnected` (the device's connectivity, signed out) or, with `-fakeServices <scenario>`, on a
// scenario's scripted fakes.

/// What the home screen's lobby area knows about the player's account and the lobby.
struct LobbyStatus: Equatable {
    var isSignedIn = false
    var hasAcceptedTerms = false
    /// Settings' Hide lobby chat.
    var hidesChat = false
    /// Players in the queue, when known.
    var queuedPlayers: Int?
    /// False for Game Center's `isUnderage` or `isPersonalizedCommunicationRestricted`: no chat (#17, #34).
    var canChat = true
    /// False for Game Center's `isMultiplayerGamingRestricted`: practice races only (#34).
    var canRaceOnline = true

    /// This status with Settings' Hide lobby chat (#110), a device setting the services don't know.
    func hidingChat(_ hides: Bool) -> LobbyStatus {
        var status = self
        status.hidesChat = hides
        return status
    }
}

/// The services' state as the views read it: connectivity and the lobby status, kept up to date from the
/// services' streams.
@MainActor @Observable
final class OnlineStatus {
    private(set) var isOnline: Bool
    private(set) var lobbyStatus = LobbyStatus()
    let services: ServiceSet

    /// `isOnline` starts at `isInitiallyOnline` until the connectivity service says: optimistic for the device's
    /// path, so Race online doesn't flash "Offline", and `isInitiallyOnline(_:)` for a launch's fakes, so the
    /// offline scenario isn't online for its first frame (#314).
    init(services: ServiceSet, isInitiallyOnline: Bool = true) {
        self.services = services
        isOnline = isInitiallyOnline
        Task { [weak self] in
            for await status in services.connectivity.statusUpdates() { self?.isOnline = status.isOnline }
        }
        Task { [weak self] in await self?.refreshAccount() }
        Task { [weak self] in
            for await state in services.queue.stateUpdates() { self?.show(state) }
        }
    }

    /// Whether the app starts online for these launch options: not on the offline scenario's fakes.
    nonisolated static func isInitiallyOnline(_ launchOptions: LaunchOptions) -> Bool { launchOptions.fakeServices != .offline }

    /// The queued count while the player is queued; none once she isn't (#314).
    func show(_ queue: QueueState) {
        switch queue {
        case .queued(let queued): lobbyStatus.queuedPlayers = queued.queuedPlayers
        case .idle, .unavailable, .fleetLocked: lobbyStatus.queuedPlayers = nil
        }
    }

    /// Reads the player, her restrictions and the terms again: after signing in, say.
    func refreshAccount() async {
        let player = await services.identity.state().player
        let accepted = player == nil ? false : ((try? await services.terms.status().isAccepted) ?? false)
        lobbyStatus.isSignedIn = player != nil
        lobbyStatus.hasAcceptedTerms = accepted
        lobbyStatus.canChat = player?.canChat ?? true
        lobbyStatus.canRaceOnline = player?.canRaceOnline ?? true
    }
}

extension EnvironmentValues {
    @Entry var isOnline = true
    @Entry var lobbyStatus = LobbyStatus()
    /// Every service, for what acts on them outside the lobby: the online results' Race again joins the queue, and the
    /// `-onlineResults` harness reads the race session (#133). Nil in previews and tests.
    @Entry var onlineServices: ServiceSet? = nil
}
