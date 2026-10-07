// Who the player is: Game Center is the only identity, and online play needs it (#16).
//
// How the four services in this package use time and streams:
// - A service is `Sendable` and `async` where it does I/O.
// - State that changes on its own (identity, the queue, the race session) comes as an `AsyncStream`: Game Center
//   can sign the player out or change her restrictions at any time (#314). State that changes only by the
//   caller's own calls (terms) is returned by them, so no stream is needed.
// - Times are whole seconds or race ticks the service reports. Nothing here reads a clock.

/// Game Center's opaque id for a player (`GKPlayer.gamePlayerID`). The server keys the player's profile by it (#16).
public struct GamePlayerID: Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// A signed-in Game Center player, with the restrictions Game Center reports (#34).
public struct GameCenterPlayer: Equatable, Sendable {
    public var gamePlayerID: GamePlayerID
    /// The Game Center alias other players see.
    public var alias: String
    /// `GKLocalPlayer.isUnderage`: chat is hidden (#34).
    public var isUnderage: Bool
    /// `isPersonalizedCommunicationRestricted`: chat is hidden (#34).
    public var isPersonalizedCommunicationRestricted: Bool
    /// `isMultiplayerGamingRestricted`: practice races only; Race online is disabled with a reason (#34).
    public var isMultiplayerGamingRestricted: Bool

    public init(
        gamePlayerID: GamePlayerID, alias: String, isUnderage: Bool = false,
        isPersonalizedCommunicationRestricted: Bool = false, isMultiplayerGamingRestricted: Bool = false
    ) {
        self.gamePlayerID = gamePlayerID
        self.alias = alias
        self.isUnderage = isUnderage
        self.isPersonalizedCommunicationRestricted = isPersonalizedCommunicationRestricted
        self.isMultiplayerGamingRestricted = isMultiplayerGamingRestricted
    }

    public var canRaceOnline: Bool { !isMultiplayerGamingRestricted }
    public var canChat: Bool { !isUnderage && !isPersonalizedCommunicationRestricted }
}

/// Whether Game Center has a player. Signed out means the player is prompted to turn it on before racing online (#16).
public enum GameCenterState: Equatable, Sendable {
    case signedOut
    case signedIn(GameCenterPlayer)

    public var player: GameCenterPlayer? {
        if case .signedIn(let player) = self { player } else { nil }
    }
}

/// What Game Center signs to prove the player's id to the server
/// (`generateIdentityVerificationSignature`): the server checks it and keeps a profile keyed by `gamePlayerID` (#16).
public struct IdentitySignature: Equatable, Sendable {
    public var gamePlayerID: GamePlayerID
    /// Where the server fetches the certificate that verifies the signature.
    public var publicKeyURL: String
    public var signature: [UInt8]
    public var salt: [UInt8]
    public var timestamp: UInt64

    public init(gamePlayerID: GamePlayerID, publicKeyURL: String, signature: [UInt8], salt: [UInt8], timestamp: UInt64) {
        self.gamePlayerID = gamePlayerID
        self.publicKeyURL = publicKeyURL
        self.signature = signature
        self.salt = salt
        self.timestamp = timestamp
    }
}

public enum IdentityError: Error, Equatable, Sendable {
    /// There is no player to sign for.
    case notSignedIn
}

public protocol IdentityService: Sendable {
    /// Game Center's state now.
    func state() async -> GameCenterState
    /// Game Center's state now, then each change as it comes (signing out or in, a restriction changing,
    /// `signIn()`'s answer), for as long as the stream is held (#314). A racing suspension isn't Game Center's:
    /// the queue's stream carries it (`QueueRefusal.suspended`) and the profile reports it.
    func stateUpdates() -> AsyncStream<GameCenterState>
    /// The signed-in player's id, or nil when signed out.
    func gamePlayerID() async -> GamePlayerID?
    /// A signature for the signed-in player, for the server to verify. Throws `IdentityError.notSignedIn`
    /// when signed out.
    func identitySignature() async throws -> IdentitySignature
    /// Asks Game Center to sign the player in (the Race online tap, or signing in from the lobby area) and
    /// returns the state afterwards, still signed out if the player declined.
    func signIn() async -> GameCenterState
}
