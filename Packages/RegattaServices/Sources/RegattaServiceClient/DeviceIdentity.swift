import RegattaServices
import Synchronization

// The device's side of the player's identity (#161): Game Center on the phone. The online session reads who is
// signed in here, and asks it for the signature the server verifies; what the app shows as "signed in" is the
// session, not this.

/// The device's Game Center player, with the id the server keys her by.
public struct DevicePlayer: Equatable, Sendable {
    /// `GKPlayer.teamPlayerID`: what the signature covers, and what a session token is kept under.
    public var teamPlayerID: String
    public var player: GameCenterPlayer

    public init(teamPlayerID: String, player: GameCenterPlayer) {
        self.teamPlayerID = teamPlayerID
        self.player = player
    }

    /// Whether a session is any use to her: she can chat or race online (the `OnlineAccess` rule, #138).
    public var canUseOnline: Bool { player.canChat || player.canRaceOnline }
}

public protocol DeviceIdentitySource: Sendable {
    /// The player now, then each change (signing in or out, another account, a restriction changing).
    func playerUpdates() -> AsyncStream<DevicePlayer?>
    /// A fresh signature for the signed-in player. Throws `IdentityError.notSignedIn` when there is none.
    func identitySignature() async throws -> IdentitySignature
    /// Asks the device to sign a player in (Game Center's own sheet) and returns who is signed in afterwards.
    func signIn() async -> DevicePlayer?
}

/// A device identity that says what it is told: tests, the contract runner, and the app's Debug dev identity.
public final class ScriptedDeviceIdentity: DeviceIdentitySource {
    private struct State {
        var player: DevicePlayer?
        var afterSignIn: DevicePlayer?
        var listeners: [Int: AsyncStream<DevicePlayer?>.Continuation] = [:]
        var nextListener = 0
    }

    private let state: Mutex<State>
    private let sign: @Sendable (DevicePlayer) async throws -> IdentitySignature

    /// `afterSignIn` is who `signIn()` signs in when nobody is (nil: the player declines). `sign` makes each signature.
    public init(player: DevicePlayer?, afterSignIn: DevicePlayer? = nil,
                sign: @escaping @Sendable (DevicePlayer) async throws -> IdentitySignature) {
        state = Mutex(State(player: player, afterSignIn: afterSignIn))
        self.sign = sign
    }

    public var player: DevicePlayer? { state.withLock { $0.player } }

    /// The device now has `player` (nil: signed out).
    public func set(_ player: DevicePlayer?) {
        state.withLock { state in
            state.player = player
            for listener in state.listeners.values { listener.yield(player) }
        }
    }

    public func playerUpdates() -> AsyncStream<DevicePlayer?> {
        let (stream, continuation) = AsyncStream.makeStream(of: DevicePlayer?.self)
        let id = state.withLock { state in
            state.nextListener += 1
            state.listeners[state.nextListener] = continuation
            continuation.yield(state.player)
            return state.nextListener
        }
        continuation.onTermination = { [weak self] _ in self?.state.withLock { $0.listeners[id] = nil } }
        return stream
    }

    public func identitySignature() async throws -> IdentitySignature {
        guard let player else { throw IdentityError.notSignedIn }
        return try await sign(player)
    }

    public func signIn() async -> DevicePlayer? {
        let (player, changed) = state.withLock { state -> (DevicePlayer?, Bool) in
            guard state.player == nil, let next = state.afterSignIn else { return (state.player, false) }
            state.player = next
            return (next, true)
        }
        if changed { set(player) }
        return player
    }
}
