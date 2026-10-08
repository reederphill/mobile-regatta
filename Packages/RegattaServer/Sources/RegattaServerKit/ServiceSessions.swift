import Crypto
import Foundation
import GameCenterIdentity
import Persistence
import RegattaProtocol
import RegattaServices

// Signing in on the service endpoint (#145): a Game Center identity signature, verified, opens a session whose token
// (32 random bytes; only its SHA-256 is stored) resumes it on later connections. Sessions slide: each sign-in or
// resume moves the expiry to `sessionLifetime` from now. The restrictions Game Center reports are taken from the
// client with each sign-in or resume and stored on the session; TODO(#158): they travel inside the App Attest–asserted
// request once #158 lands, and are trusted only then.

/// The connection's signed-in player.
public struct SignedInSession: Sendable, Equatable {
    public var sessionID: UUID
    public var player: AccountPlayer
    public var restrictions: SessionRestrictions
    /// The signature this connection signed in with; nil after a resume.
    public var signature: IdentitySignature?

    public var gameCenterPlayer: GameCenterPlayer {
        GameCenterPlayer(gamePlayerID: GamePlayerID(player.gamePlayerID), alias: player.alias, isUnderage: restrictions.isUnderage,
                         isPersonalizedCommunicationRestricted: restrictions.isPersonalizedCommunicationRestricted,
                         isMultiplayerGamingRestricted: restrictions.isMultiplayerGamingRestricted)
    }
}

/// Opens, resumes and ends sessions.
public struct SessionAuthority: Sendable {
    public let store: any AccountStore
    public let verifier: any GameCenterVerifier
    public let lifetime: TimeInterval
    public let now: @Sendable () -> Date

    public init(store: any AccountStore, verifier: any GameCenterVerifier, lifetime: TimeInterval = 30 * 86_400,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.verifier = verifier
        self.lifetime = lifetime
        self.now = now
    }

    public enum Outcome: Sendable, Equatable {
        case signedIn(token: [UInt8], session: SignedInSession)
        case refused(WireSessionRefusal)
    }

    /// Verifies `signature`, signs the player in (binding the gamePlayerID), and opens a session.
    public func signIn(_ signature: WireIdentitySignature, player: WirePlayer) async -> Outcome {
        guard player.gamePlayerID == signature.gamePlayerID, !signature.gamePlayerID.isEmpty else { return .refused(.invalidSignature) }
        let claim = GameCenterIdentityClaim(
            teamPlayerID: signature.teamPlayerID, gamePlayerID: signature.gamePlayerID, publicKeyURL: signature.publicKeyURL,
            signature: signature.signature, salt: signature.salt, timestamp: signature.timestamp)
        let teamPlayerID: String
        do {
            teamPlayerID = try await verifier.verify(claim)
        } catch GameCenterVerificationError.staleTimestamp {
            return .refused(.staleSignature)
        } catch GameCenterVerificationError.fetchFailed {
            return .refused(.unavailable)
        } catch {
            return .refused(.invalidSignature)
        }
        let restrictions = SessionRestrictions(wire: player)
        do {
            let account = try await store.signIn(teamPlayerID: teamPlayerID, gamePlayerID: signature.gamePlayerID, alias: player.alias)
            let token = Self.newToken()
            let time = now()
            let session = try await store.createSession(playerID: teamPlayerID, tokenHash: Self.hash(token),
                                                        expiresAt: time + lifetime, restrictions: restrictions)
            try await store.touchSession(teamPlayerID: teamPlayerID, at: time)
            let identity = IdentitySignature(
                gamePlayerID: GamePlayerID(signature.gamePlayerID), teamPlayerID: teamPlayerID, publicKeyURL: signature.publicKeyURL,
                signature: signature.signature, salt: signature.salt, timestamp: signature.timestamp)
            return .signedIn(token: token, session: SignedInSession(sessionID: session.id, player: account, restrictions: restrictions,
                                                                    signature: identity))
        } catch AccountStoreError.gamePlayerIDConflict {
            return .refused(.gamePlayerIDConflict)
        } catch {
            return .refused(.unavailable)
        }
    }

    /// Resumes the session `token` names for the player it belongs to; the restrictions are what Game Center reports now.
    public func resume(token: [UInt8], player: WirePlayer) async -> Outcome {
        do {
            let time = now()
            guard let session = try await store.session(tokenHash: Self.hash(token), at: time),
                  let account = try await store.player(teamPlayerID: session.playerID)
            else { return .refused(.sessionExpired) }
            guard account.gamePlayerID == player.gamePlayerID else { return .refused(.gamePlayerIDConflict) }
            let restrictions = SessionRestrictions(wire: player)
            guard let refreshed = try await store.refreshSession(id: session.id, expiresAt: time + lifetime, restrictions: restrictions, at: time)
            else { return .refused(.sessionExpired) }
            try await store.touchSession(teamPlayerID: account.teamPlayerID, at: time)
            var named = account
            named.alias = player.alias
            return .signedIn(token: token, session: SignedInSession(sessionID: refreshed.id, player: named, restrictions: restrictions,
                                                                    signature: nil))
        } catch {
            return .refused(.unavailable)
        }
    }

    public func signOut(_ session: SignedInSession) async {
        try? await store.deleteSession(id: session.sessionID)
    }

    static func newToken() -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }

    static func hash(_ token: [UInt8]) -> Data { Data(SHA256.hash(data: token)) }
}

extension SessionRestrictions {
    init(wire player: WirePlayer) {
        self.init(isUnderage: player.isUnderage, isPersonalizedCommunicationRestricted: player.isPersonalizedCommunicationRestricted,
                  isMultiplayerGamingRestricted: player.isMultiplayerGamingRestricted)
    }
}

// MARK: - The services the endpoint answers itself

/// Game Center as the server sees this connection (#16, #314): signed in once a session is open, signed out before
/// and after. Each change goes to every open `stateUpdates()` stream, buffered until the client reads it.
public actor ConnectionIdentity: IdentityService {
    private var session: SignedInSession?
    private var watchers: [UUID: AsyncStream<GameCenterState>.Continuation] = [:]

    public init() {}

    public var signedIn: SignedInSession? { session }

    public func set(_ session: SignedInSession?) {
        self.session = session
        let state = currentState
        for watcher in watchers.values { watcher.yield(state) }
    }

    private var currentState: GameCenterState { session.map { .signedIn($0.gameCenterPlayer) } ?? .signedOut }

    public func state() -> GameCenterState { currentState }

    public nonisolated func stateUpdates() -> AsyncStream<GameCenterState> {
        let (stream, continuation) = AsyncStream<GameCenterState>.makeStream(bufferingPolicy: .bufferingNewest(16))
        let id = UUID()
        Task { await self.watch(id, continuation) }
        continuation.onTermination = { _ in Task { await self.unwatch(id) } }
        return stream
    }

    private func watch(_ id: UUID, _ continuation: AsyncStream<GameCenterState>.Continuation) {
        continuation.yield(currentState)
        watchers[id] = continuation
    }

    private func unwatch(_ id: UUID) { watchers[id] = nil }

    public func finish() {
        for watcher in watchers.values { watcher.finish() }
        watchers = [:]
    }

    public func gamePlayerID() -> GamePlayerID? { session.map { GamePlayerID($0.player.gamePlayerID) } }

    /// The signature this connection signed in with. A resumed session has none to show: answered as not signed in.
    public func identitySignature() throws -> IdentitySignature {
        guard let signature = session?.signature else { throw IdentityError.notSignedIn }
        return signature
    }

    /// The server can't sign a player in on its own: the client signs in with a session call. The state as it is.
    public func signIn() -> GameCenterState { currentState }
}

/// The Terms of Use for one signed-in player (#34, #145), against the server's current `termsVersion`.
public struct StoreTermsService: TermsService {
    public let store: any AccountStore
    public let playerID: String
    public let currentVersion: Int
    public let now: @Sendable () -> Date

    public init(store: any AccountStore, playerID: String, currentVersion: Int, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.playerID = playerID
        self.currentVersion = currentVersion
        self.now = now
    }

    public func status() async throws -> TermsStatus {
        let last = try await store.lastAcceptedTerms(playerID: playerID)
        if let last, last >= currentVersion { return .accepted(TermsVersion(currentVersion)) }
        return .needsAcceptance(current: TermsVersion(currentVersion), lastAccepted: last.map(TermsVersion.init))
    }

    public func accept(_ version: TermsVersion) async throws -> TermsStatus {
        guard version.rawValue == currentVersion else { throw TermsError.staleVersion(current: TermsVersion(currentVersion)) }
        try await store.acceptTerms(playerID: playerID, version: currentVersion, at: now())
        return try await status()
    }
}
