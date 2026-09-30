/// What a `ScriptedIdentityService` plays.
public struct IdentityScenario: Sendable {
    /// Game Center's state at the start.
    public var initial: GameCenterState
    /// The state after `signIn()`, when it starts signed out: signed in, or still out if the player declines.
    public var afterSignIn: GameCenterState

    public init(initial: GameCenterState, afterSignIn: GameCenterState? = nil) {
        self.initial = initial
        self.afterSignIn = afterSignIn ?? initial
    }
}

/// An `IdentityService` that plays its scenario and nothing else: no Game Center, no network, no clock.
/// The signature is a function of the player's id, so a run always reads the same.
public actor ScriptedIdentityService: IdentityService {
    private var current: GameCenterState
    private let afterSignIn: GameCenterState

    public init(_ scenario: IdentityScenario) {
        current = scenario.initial
        afterSignIn = scenario.afterSignIn
    }

    public func state() -> GameCenterState { current }

    public func gamePlayerID() -> GamePlayerID? { current.player?.gamePlayerID }

    public func identitySignature() throws -> IdentitySignature {
        guard let player = current.player else { throw IdentityError.notSignedIn }
        return IdentitySignature(
            gamePlayerID: player.gamePlayerID, publicKeyURL: "https://scripted.invalid/gc-public-key.cer",
            signature: Array(player.gamePlayerID.rawValue.utf8), salt: [1, 2, 3, 4], timestamp: 1)
    }

    public func signIn() -> GameCenterState {
        if case .signedOut = current { current = afterSignIn }
        return current
    }
}
