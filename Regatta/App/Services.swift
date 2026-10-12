import Foundation
import Observation
import RegattaServiceClient
import RegattaServices
import SwiftUI
import UIKit

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
    /// The online session under the services' identity, terms and queue state, and the device identity under it (#161).
    nonisolated struct Session: Sendable {
        let session: OnlineSession
        let device: any DeviceIdentitySource
    }

    private(set) var isOnline: Bool
    private(set) var lobbyStatus = LobbyStatus()
    let services: ServiceSet
    /// Where the online session stands; nil with no session (no service endpoint: the app as before #161).
    private(set) var sessionPhase: SessionPhase?
    /// The device's Game Center player, with a session: she may be signed in on the phone before, or without, a session.
    private(set) var devicePlayer: DevicePlayer?
    /// What the queue's state stream last refused her for (a suspension, the cooldown), if it did.
    private(set) var queueLine: RestrictionLine?
    /// A tap (Race online, the lobby's Sign in or Try again) is waiting for the session: the button's spinner.
    private(set) var isOpeningSession = false
    /// The last tap got no session. An unreachable server is only said after one.
    private(set) var tapFailed = false
    /// The Terms of Use sheet's last I agree couldn't be saved: the sheet stays, with a short line.
    private(set) var termsSaveFailed = false
    /// What the terms ask of her, by the server's version against the bundled text's.
    private(set) var termsPrompt = TermsPrompt.none
    /// The queue, from the Race online tap to fleet lock (#140): the one reader of the queue's state stream.
    let queue: QueueController
    /// The online race from the briefing's end to Home again (#141).
    let race: OnlineRaceController
    /// The livery between My boat and the server (#162).
    let livery: LiverySync
    private let session: Session?
    private let now: () -> Date

    /// `isOnline` starts at `isInitiallyOnline` until the connectivity service says: optimistic for the device's
    /// path, so Race online doesn't flash "Offline", and `isInitiallyOnline(_:)` for a launch's fakes, so the
    /// offline scenario isn't online for its first frame (#314).
    init(services: ServiceSet, isInitiallyOnline: Bool = true, session: Session? = nil, raceTimescale: Double = 1,
         now: @escaping () -> Date = Date.init) {
        self.services = services
        self.session = session
        self.now = now
        isOnline = isInitiallyOnline
        // Until a window attaches its app model's link: a race nobody answers.
        let race = OnlineRaceController(raceSession: services.raceSession, makeLink: { handOff in
            OnlineRaceLink(handOff: handOff, connector: { _ in UnansweredRaceConnection() }, results: nil) { connect, token in
                OnlineLaunch(connect: connect, token: token)
            }
        }, isOnline: isInitiallyOnline, timescale: raceTimescale, now: now)
        self.race = race
        queue = QueueController(queue: services.queue, raceSession: services.raceSession, sequence: race,
                                isOnline: isInitiallyOnline, now: now)
        race.queue = queue
        livery = LiverySync(profile: services.profile)
        livery.isLive = session != nil
        race.mayAskService = { [weak self] in self?.mayAskService ?? false }
        livery.mayAskService = { [weak self] in self?.mayAskService ?? false }
        Task { [weak self] in
            for await status in services.connectivity.statusUpdates() {
                self?.isOnline = status.isOnline
                self?.queue.connectionChanged(isOnline: status.isOnline)
                self?.race.connectionChanged(isOnline: status.isOnline)
                // Offline the session tries nothing; back online it connects at once (#161).
                await session?.session.setOnline(status.isOnline)
            }
        }
        if let session {
            sessionPhase = .idle
            Task { [weak self] in
                for await phase in session.session.phaseUpdates() { self?.show(phase) }
            }
            Task { [weak self] in
                for await player in session.device.playerUpdates() { await self?.deviceChanged(player) }
            }
        }
        Task { [weak self] in await self?.refreshAccount() }
        // Game Center can sign the player out, or change her restrictions, at any time (#314).
        Task { [weak self] in
            for await _ in services.identity.stateUpdates() { await self?.refreshAccount() }
        }
        queue.onState = { [weak self] state in self?.show(state) }
        queue.announce = { UIAccessibility.post(notification: .announcement, argument: $0) }
        queue.whileAwake = { work in
            let awake = BackgroundAssertion(name: "Leave queue")
            return Task {
                await work()
                awake.end()
            }
        }
        queue.start()
    }

    /// Whether the app starts online for these launch options: not on the offline scenario's fakes.
    nonisolated static func isInitiallyOnline(_ launchOptions: LaunchOptions) -> Bool { launchOptions.fakeServices != .offline }

    /// The queued count while the player is queued; none once she isn't (#314).
    func show(_ queue: QueueState) {
        switch queue {
        case .queued(let queued): lobbyStatus.queuedPlayers = queued.queuedPlayers
        case .idle, .unavailable, .fleetLocked: lobbyStatus.queuedPlayers = nil
        }
        // A cooldown's seconds are counted from now (#161).
        queueLine = RestrictionLine(queue: queue, now: now())
    }

    /// The phone's Game Center player changed (#161).
    func deviceChanged(_ player: DevicePlayer?) async {
        devicePlayer = player
        await refreshAccount()
    }

    func show(_ phase: SessionPhase) {
        let wasOpen = isSessionOpen
        sessionPhase = phase
        if case .open = phase { tapFailed = false }
        guard session != nil else { return }
        // Queued, a session that is gone took her place with it (#162).
        queue.sessionChanged(isOpen: isSessionOpen)
        if isSessionOpen, !wasOpen {
            Task {
                await refreshAccount()
                throughTheGate()
            }
        }
    }

    private var isSessionOpen: Bool {
        if case .open = sessionPhase { true } else { false }
    }

    /// With a session (#162): one is there to join the queue on.
    var hasSession: Bool { session != nil }

    /// Whether the race session and the profile may be asked (#162): the server closes the connection on either from
    /// a player who hasn't accepted the current terms or may not race online, and the session would open it again, and
    /// again. With no session (the fakes) there is nothing to close.
    var mayAskService: Bool {
        guard session != nil else { return true }
        return isSessionOpen && lobbyStatus.hasAcceptedTerms && lobbyStatus.canRaceOnline
    }

    /// The session opened, or the terms were just accepted on it: a race she dropped out of may still run (a cold
    /// launch after a drop), and the livery is brought in line with the server's.
    private func throughTheGate() {
        guard session != nil, mayAskService else { return }
        race.sessionOpened()
        Task { await livery.sessionOpened() }
    }

    /// The scene became active, or went to the background: the queue is left there (#140), and the session's socket
    /// follows (#161).
    func setSceneActive(_ active: Bool) {
        queue.sceneChanged(isBackground: !active)
        race.sceneChanged(isBackground: !active)
        guard let session else { return }
        Task { await session.session.setActive(active) }
    }

    /// The line under Race online for what the server or the session says, when the gating matrix has none of its
    /// own ("Offline", "Practice races only"): an update, a suspension, the cooldown, a refusal, and, after a tap
    /// that failed, an unreachable server (#161).
    var restrictionLine: RestrictionLine? {
        if !isOnline || !lobbyStatus.canRaceOnline { return nil }
        if termsPrompt == .updateRequired { return .updateRequired }
        if let sessionPhase {
            let line = RestrictionLine(phase: sessionPhase, tapFailed: tapFailed)
            if let line, !line.allowsTap { return line }
            if case .open = sessionPhase, let queueLine { return queueLine }
            return line
        }
        return queueLine
    }

    /// The server didn't answer her last tap, or wouldn't sign her in: the lobby area says so, with Try again, where
    /// it would ask her to sign in to Game Center, which she is.
    var lobbyRetryLine: RestrictionLine? { restrictionLine.flatMap { $0.allowsTap ? $0 : nil } }

    /// Reads the player, her restrictions and the terms again: after signing in, say. Terms that can't be read
    /// are due (`LocalTermsService` already falls back to what the device last recorded).
    func refreshAccount() async {
        var player = await services.identity.state().player
        let terms = player == nil ? nil : try? await services.terms.status()
        // A player who can neither chat nor race online gets no session (#161), but is no less signed in: Race
        // online still says "Practice races only".
        if player == nil, let devicePlayer, !devicePlayer.canUseOnline { player = devicePlayer.player }
        // With a session the server says which terms are current: newer than the bundled text, there is no sheet.
        termsPrompt = session == nil ? .none : TermsPrompt(status: terms, bundled: TermsOfUse.version)
        lobbyStatus.isSignedIn = player != nil
        lobbyStatus.hasAcceptedTerms = terms?.isAccepted ?? false
        lobbyStatus.termsVersion = termsPrompt == .updateRequired ? nil : terms?.current
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
        tapFailed = false
        let access = access
        // Terms newer than the text this build carries: nothing to agree to until an update (#161).
        if termsPrompt == .updateRequired || restrictionLine.map({ !$0.allowsTap }) == true { return .stopped }
        if access.termsDue { return .terms }
        return access.next == .proceed ? .proceed : .stopped
    }

    /// Game Center's sign-in, from Race online or the lobby's Sign in or Try again: true when it signed the player in.
    /// Logs the prompt's answer, and the funnel's "GC signed in" step (#128). With a session (#161) signed in means the
    /// session is open: a tap that got none is remembered (`tapFailed`), and the next one tries again.
    @discardableResult func signIn(analytics: Analytics) async -> Bool {
        // Game Center's sheet was only a prospect if nobody was signed in on the phone (#161).
        let prompts = devicePlayer == nil
        // With Game Center already signed in on the phone, the tap is waiting for the session alone.
        isOpeningSession = !prompts
        let signedIn = await services.identity.signIn().player != nil
        isOpeningSession = false
        if let session { show(await session.session.phase) }
        tapFailed = !signedIn && session != nil && devicePlayer?.canUseOnline == true
        if prompts { analytics.log(.gameCenterPrompt(accepted: signedIn)) }
        if signedIn, prompts { analytics.log(.practiceToOnline(.gameCenterSignedIn)) }
        await refreshAccount()
        return signedIn
    }

    /// The Terms of Use sheet's I agree (#34): accepts the version the sheet showed, and logs the funnel's "terms
    /// accepted" step (#128). False when it didn't take: a newer version came, or the service failed.
    /// `shown` is the version the sheet opened with (#161): that one is accepted, even if another is current by now.
    func acceptTerms(_ shown: TermsVersion? = nil, analytics: Analytics) async -> Bool {
        guard let version = shown ?? lobbyStatus.termsVersion else { return false }
        var accepted = false
        do {
            accepted = try await services.terms.accept(version).isAccepted
            termsSaveFailed = false
        } catch is TermsError {
            // A newer version came: the sheet shows it, and nothing failed.
            termsSaveFailed = false
        } catch {
            // The server didn't take it (#161): the sheet stays, and says so.
            termsSaveFailed = true
        }
        if accepted { analytics.log(.practiceToOnline(.termsAccepted)) }
        await refreshAccount()
        if accepted { throughTheGate() }
        return accepted && lobbyStatus.hasAcceptedTerms
    }

    /// The Terms of Use sheet went away: the next one opens without the last one's line.
    func termsSheetClosed() { termsSaveFailed = false }
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

/// A background task (#140): the app stays awake from here to `end()`, or until the system calls time.
final class BackgroundAssertion {
    private var id = UIBackgroundTaskIdentifier.invalid

    init(name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in self?.end() }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
