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
    /// The terms' current version, which the Terms of Use sheet shows and its I agree accepts (#138); nil signed out
    /// or not yet read.
    var termsVersion: TermsVersion? = nil

    /// The gating matrix (#138) for this status: what Race online, the lobby area and Race online's gate read.
    func access(isOnline: Bool) -> OnlineAccess {
        OnlineAccess(isOnline: isOnline, isSignedIn: isSignedIn, canChat: canChat, canRaceOnline: canRaceOnline,
                     termsAccepted: hasAcceptedTerms)
    }

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
        // Game Center can sign the player out, or change her restrictions, at any time (#314).
        Task { [weak self] in
            for await _ in services.identity.stateUpdates() { await self?.refreshAccount() }
        }
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

    /// Reads the player, her restrictions and the terms again: after signing in, say. Terms that can't be read
    /// are due (`LocalTermsService` already falls back to what the device last recorded).
    func refreshAccount() async {
        let player = await services.identity.state().player
        let terms = player == nil ? nil : try? await services.terms.status()
        lobbyStatus.isSignedIn = player != nil
        lobbyStatus.hasAcceptedTerms = terms?.isAccepted ?? false
        lobbyStatus.termsVersion = terms?.current
        lobbyStatus.canChat = player?.canChat ?? true
        lobbyStatus.canRaceOnline = player?.canRaceOnline ?? true
    }

    /// The gating matrix now (#138).
    var access: OnlineAccess { lobbyStatus.access(isOnline: isOnline) }

    /// Where Race online's gate leaves the player (#138).
    enum GateStep: Equatable {
        /// Through: the queue.
        case proceed
        /// Signed in, terms due: the Terms of Use sheet.
        case terms
        /// Sign-in declined, offline, or practice races only: stay home.
        case stopped
    }

    /// Race online's gate (#23, #34, #138): signs in first when signed out (Game Center's own sheet), then says
    /// whether the terms are due. A player who turns out to be multiplayer-restricted but can chat still gets the
    /// terms straight after signing in, for the lobby; one who can do neither gets nothing (question 1).
    func passGate(analytics: Analytics) async -> GateStep {
        if access.next == .signIn, !(await signIn(analytics: analytics)) { return .stopped }
        let access = access
        if access.termsDue { return .terms }
        return access.next == .proceed ? .proceed : .stopped
    }

    /// Game Center's sign-in, from Race online or the lobby's Sign in: true when it signed the player in. Logs the
    /// prompt's answer, and the funnel's "GC signed in" step (#128).
    @discardableResult func signIn(analytics: Analytics) async -> Bool {
        let signedIn = await services.identity.signIn().player != nil
        analytics.log(.gameCenterPrompt(accepted: signedIn))
        if signedIn { analytics.log(.practiceToOnline(.gameCenterSignedIn)) }
        await refreshAccount()
        return signedIn
    }

    /// The Terms of Use sheet's I agree (#34): accepts the version the sheet showed, and logs the funnel's "terms
    /// accepted" step (#128). False when it didn't take: a newer version came, or the service failed.
    func acceptTerms(analytics: Analytics) async -> Bool {
        guard let version = lobbyStatus.termsVersion else { return false }
        let accepted = (try? await services.terms.accept(version))?.isAccepted ?? false
        if accepted { analytics.log(.practiceToOnline(.termsAccepted)) }
        await refreshAccount()
        return accepted && lobbyStatus.hasAcceptedTerms
    }
}

extension EnvironmentValues {
    @Entry var isOnline = true
    @Entry var lobbyStatus = LobbyStatus()
    /// Every service, for what acts on them outside the lobby: the online results' Race again joins the queue, and the
    /// `-onlineResults` harness reads the race session (#133). Nil in previews and tests.
    @Entry var onlineServices: ServiceSet? = nil
    /// The services' state, for Race online's gate and the lobby's Sign in and Terms of Use (#138). Nil in previews
    /// and tests.
    @Entry var onlineStatus: OnlineStatus? = nil
}
