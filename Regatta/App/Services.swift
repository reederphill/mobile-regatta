import Network
import Observation
import SwiftUI

// Injection points for the service contracts. #109's `RegattaServices` protocols replace these placeholders:
// the views read them from the environment, so they don't change when the real services arrive.

/// Whether the device can reach the network. Race online needs it; a practice race doesn't.
protocol Connectivity: AnyObject {
    var isOnline: Bool { get }
}

/// Connectivity from the system's network path, set by `SceneDelegate`.
@Observable
final class PathConnectivity: Connectivity {
    /// Optimistic until the first path update, so Race online doesn't flash "Offline" at launch.
    private(set) var isOnline = true
    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.isOnline = online }
        }
        monitor.start(queue: DispatchQueue(label: "com.phillreeder.regatta.connectivity"))
    }
}

/// A fixed answer, for previews, tests and the environment's default.
final class FixedConnectivity: Connectivity {
    let isOnline: Bool
    init(isOnline: Bool) { self.isOnline = isOnline }
}

/// What the home screen's lobby area knows about the player's account and the lobby. Static until #109's
/// account and lobby services supply it.
struct LobbyStatus: Equatable {
    var isSignedIn = false
    var hasAcceptedTerms = false
    /// Settings' Hide lobby chat.
    var hidesChat = false
    /// Players in the queue, when known.
    var queuedPlayers: Int?
}

extension EnvironmentValues {
    @Entry var connectivity: any Connectivity = FixedConnectivity(isOnline: true)
    @Entry var lobbyStatus = LobbyStatus()
}
