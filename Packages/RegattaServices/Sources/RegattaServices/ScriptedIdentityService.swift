/// What a `ScriptedIdentityService` plays.
public struct IdentityScenario: Sendable {
    /// Game Center's state at the start.
    public var initial: GameCenterState
    /// The state after `signIn()`, when it starts signed out: signed in, or still out if the player declines.
    public var afterSignIn: GameCenterState
    /// Changes Game Center makes on its own, one per read of a stream: signing out, a restriction changing.
    public var background: [GameCenterState]

    public init(initial: GameCenterState, afterSignIn: GameCenterState? = nil, background: [GameCenterState] = []) {
        self.initial = initial
        self.afterSignIn = afterSignIn ?? initial
        self.background = background
    }
}

/// An `IdentityService` that plays its scenario and nothing else: no Game Center, no network, no clock.
/// The signature is a function of the player's id, so a run always reads the same. A stream gives the state now,
/// then one change per read (the background, and each sign-in that changed something), finishing when there is
/// none left (a real one stays open).
public actor ScriptedIdentityService: IdentityService {
    private var current: GameCenterState
    private let afterSignIn: GameCenterState
    private let initial: GameCenterState
    private let script: StreamScript<GameCenterState>

    public init(_ scenario: IdentityScenario) {
        current = scenario.initial
        initial = scenario.initial
        afterSignIn = scenario.afterSignIn
        script = StreamScript(scenario.background)
    }

    public func state() -> GameCenterState { current }

    public nonisolated func stateUpdates() -> AsyncStream<GameCenterState> {
        let cursor = script.cursor()
        return AsyncStream { await self.next(cursor) }
    }

    private func next(_ cursor: StreamCursor) -> GameCenterState? {
        let loaded = cursor.load()
        var position = loaded.position
        guard loaded.hasStarted else {
            let (start, before) = script.steps(before: position)
            cursor.store(start)
            return before.last ?? initial
        }
        defer { cursor.store(position) }
        guard let (_, state, isFirstRead) = script.next(&position) else { return nil }
        if isFirstRead { current = state }
        return state
    }

    public func gamePlayerID() -> GamePlayerID? { current.player?.gamePlayerID }

    public func identitySignature() throws -> IdentitySignature {
        guard let player = current.player else { throw IdentityError.notSignedIn }
        return IdentitySignature(
            gamePlayerID: player.gamePlayerID, teamPlayerID: "T:" + player.gamePlayerID.rawValue, publicKeyURL: "https://scripted.invalid/gc-public-key.cer",
            signature: Array(player.gamePlayerID.rawValue.utf8), salt: [1, 2, 3, 4], timestamp: 1)
    }

    public func signIn() -> GameCenterState {
        if case .signedOut = current, afterSignIn != current {
            current = afterSignIn
            script.appendTaken(current)
        }
        return current
    }
}
