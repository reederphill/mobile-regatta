#if DEBUG
import Foundation
import RegattaServiceClient

/// The #161 design gate: `-gatePreview <state>` draws one of the proposed visual states (V1–V4) on Home, on top
/// of whatever services the launch runs on, for a local screenshot the owner signs off before B2 wires the states to
/// `OnlineStatus`. Debug builds only; nothing here is reachable in a shipped build.
nonisolated enum GatePreview: String, CaseIterable {
    // V1: the line under Race online.
    case suspended
    case suspendedPermanent = "suspended-permanent"
    case cooldown
    case cannotRace = "cannot-race"
    case updateRequired = "update-required"
    case unreachable
    case sessionFailed = "session-failed"
    /// V2: Race online while a tap waits for the session.
    case connecting
    /// V3: the Terms of Use sheet after a save that failed.
    case termsSaveFailed = "terms-save-failed"
    /// V4: the lobby card with the server unreachable.
    case lobbyUnreachable = "lobby-unreachable"

    /// The line under Race online, for a preview that came up at `start`.
    func line(since start: Date) -> RestrictionLine? {
        switch self {
        case .suspended: .suspended(until: start.addingTimeInterval(3 * 86400))
        case .suspendedPermanent: .suspended(until: nil)
        // About 4:12 by the time a screenshot is taken, and counting.
        case .cooldown: .cooldown(until: start.addingTimeInterval(258))
        case .cannotRace: .cannotRace
        case .updateRequired: .updateRequired
        case .unreachable, .lobbyUnreachable: .unreachable
        case .sessionFailed: .couldNotSignIn
        case .connecting, .termsSaveFailed: nil
        }
    }
}
#endif
