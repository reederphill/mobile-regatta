import Foundation
import RegattaServiceClient
import RegattaServices

// The online session's services in the app (#162): what a real launch's queue, race and livery run on, where the race
// link connects, and where Race online leads past its gate.

extension OnlineEndpoint {
    /// Opens a hand-off's race connection on the services' host (#162). The token isn't the transport's: `RaceJoin`
    /// sends it once the socket is up.
    @MainActor static func raceConnector(serviceURL: URL, open: @escaping (URL) -> any RaceConnection = { WebSocketTransport(url: $0) }) -> RaceConnector? {
        guard let url = raceURL(serviceURL) else { return nil }
        return { _ in open(url) }
    }
}

extension ServiceSet {
    /// The services the online session carries (#161, #162, #166) in place of this set's: identity, the terms, the
    /// queue, the race session, the profile, usage analytics and Delete my online data. The rest stay as they are
    /// until their tickets.
    nonisolated mutating func adopt(_ session: OnlineSession) {
        identity = session.identity
        terms = session.terms
        queue = session.queue
        raceSession = session.raceSession
        profile = session.profile
        analytics = session.analytics
        deletion = session.deletion
    }
}

/// Where Race online leads past its gate (#162).
nonisolated enum QueueEntry: Equatable {
    /// The queue: the session's, or the fakes'.
    case queue
    /// A Debug build with no session: the dev server's instant race (#68).
    case devInstantRace
    /// No server address in this build (Release until #167): "Online racing is on its way".
    case stubAlert

    #if DEBUG
    static let isDebugBuild = true
    #else
    static let isDebugBuild = false
    #endif

    init(launchOptions: LaunchOptions, hasSession: Bool, isDebug: Bool = QueueEntry.isDebugBuild) {
        if launchOptions.fakeServices != nil || hasSession {
            self = .queue
        } else if isDebug, !launchOptions.uiTesting {
            self = .devInstantRace
        } else {
            self = .stubAlert
        }
    }
}
