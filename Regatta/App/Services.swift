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
}

/// The services' state as the views read it: connectivity and the lobby status, kept up to date from the
/// services' streams.
@MainActor @Observable
final class OnlineStatus {
    private(set) var isOnline: Bool
    private(set) var lobbyStatus = LobbyStatus()
    let services: ServiceSet

    /// `isOnline` starts optimistic until the connectivity service says, so Race online doesn't flash "Offline".
    init(services: ServiceSet) {
        self.services = services
        isOnline = true
        Task { [weak self] in
            for await status in services.connectivity.statusUpdates() { self?.isOnline = status.isOnline }
        }
        Task { [weak self] in await self?.refreshAccount() }
        Task { [weak self] in
            for await state in services.queue.stateUpdates() {
                if case .queued(let queued) = state { self?.lobbyStatus.queuedPlayers = queued.queuedPlayers }
            }
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
}
