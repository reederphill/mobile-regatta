import GameKit
import RegattaServices
import UIKit

/// Game Center as the `IdentityService` (#16, #138). `start()` at launch sets `authenticateHandler`, which signs a
/// returning player in silently; Game Center's own sign-in sheet, when it offers one, is held and shown only by
/// `signIn()` (Race online, or the lobby area's Sign in), never at launch (#23). The restrictions are reported as
/// Game Center gives them, for the server's gate (#145, #161).
///
/// Tests and UI tests never touch it (`AppDelegate.makeServices`): the owner checks it once on a device.
nonisolated final class GameKitIdentityService: IdentityService {
    private let core: Core

    @MainActor init() { core = Core() }

    /// Sets the authenticate handler, once, at launch.
    @MainActor func start() { core.start() }

    func state() async -> GameCenterState { await core.state() }

    func stateUpdates() -> AsyncStream<GameCenterState> {
        let (stream, continuation) = AsyncStream.makeStream(of: GameCenterState.self)
        let core = core
        Task { @MainActor in core.add(continuation) }
        return stream
    }

    func gamePlayerID() async -> GamePlayerID? { await core.state().player?.gamePlayerID }

    func identitySignature() async throws -> IdentitySignature { try await core.identitySignature() }

    func signIn() async -> GameCenterState { await core.signIn() }
}

/// `GKLocalPlayer` and the held sign-in sheet, on the main actor.
@MainActor private final class Core {
    /// How long a sign-in waits for the handler's first answer, when Race online is tapped before it came.
    static let firstAnswerWait = Duration.seconds(3)
    /// How long a dismissed sign-in sheet waits for the handler's answer.
    static let answerAfterDismissWait = Duration.seconds(2)

    /// Game Center's sign-in sheet, held from the handler until `signIn()` shows it.
    private var signInController: UIViewController?
    /// How many times the handler has answered.
    private var answers = 0
    private var listeners: [Int: AsyncStream<GameCenterState>.Continuation] = [:]
    private var nextListener = 0

    func start() {
        // GameKit calls the handler at launch and whenever the player's state changes, on a queue of its own choosing.
        GKLocalPlayer.local.authenticateHandler = { @Sendable [weak self] controller, _ in
            Task { @MainActor in self?.answered(controller) }
        }
    }

    private func answered(_ controller: UIViewController?) {
        answers += 1
        signInController = controller
        let state = state()
        for listener in listeners.values { listener.yield(state) }
    }

    func state() -> GameCenterState {
        let local = GKLocalPlayer.local
        guard local.isAuthenticated else { return .signedOut }
        return .signedIn(GameCenterPlayer(
            gamePlayerID: GamePlayerID(local.gamePlayerID), alias: local.alias, isUnderage: local.isUnderage,
            isPersonalizedCommunicationRestricted: local.isPersonalizedCommunicationRestricted,
            isMultiplayerGamingRestricted: local.isMultiplayerGamingRestricted))
    }

    func add(_ continuation: AsyncStream<GameCenterState>.Continuation) {
        let id = nextListener
        nextListener += 1
        listeners[id] = continuation
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { @MainActor in self?.listeners[id] = nil }
        }
        continuation.yield(state())
    }

    /// Shows the held sign-in sheet and waits for Game Center's answer. Still signed out when the player declines,
    /// or when Game Center offers no sheet (declined too often, or turned off in Settings): no message (question 12).
    func signIn() async -> GameCenterState {
        if case .signedIn = state() { return state() }
        await wait(for: Self.firstAnswerWait) { self.answers > 0 }
        guard let controller = signInController, let presenter = Self.topController() else { return state() }
        signInController = nil
        let before = answers
        presenter.present(controller, animated: true)
        // Until GameKit answers again, or its sheet is gone without an answer; then a moment for the answer.
        while answers == before, controller.presentingViewController != nil || controller.isBeingPresented {
            try? await Task.sleep(for: .milliseconds(200))
        }
        await wait(for: Self.answerAfterDismissWait) { self.answers > before }
        return state()
    }

    func identitySignature() async throws -> IdentitySignature {
        guard let player = state().player else { throw IdentityError.notSignedIn }
        let local = GKLocalPlayer.local
        return try await withCheckedThrowingContinuation { continuation in
            local.fetchItems(forIdentityVerificationSignature: { @Sendable url, signature, salt, timestamp, error in
                if let url, let signature, let salt {
                    continuation.resume(returning: IdentitySignature(
                        gamePlayerID: player.gamePlayerID, publicKeyURL: url.absoluteString, signature: [UInt8](signature),
                        salt: [UInt8](salt), timestamp: timestamp))
                } else {
                    continuation.resume(throwing: error ?? IdentityError.notSignedIn)
                }
            })
        }
    }

    private func wait(for limit: Duration, until done: () -> Bool) async {
        let deadline = ContinuousClock.now + limit
        while !done(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// The controller on top of the foreground scene's key window, to present from.
    private static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
