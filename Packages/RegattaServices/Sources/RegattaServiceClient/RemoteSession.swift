import RegattaProtocol
import RegattaServices

// The connection's signed-in session (#145) on the service messages: sign in with a Game Center identity signature,
// resume with the token a sign-in gave, or sign out. Until one of these succeeds the server answers identity as
// signed out and turns the lobby and the queue away.

/// Why the server didn't open a session.
public enum SessionRefusal: Equatable, Sendable {
    case invalidSignature
    case staleSignature
    case gamePlayerIDConflict
    case sessionExpired
    case unavailable

    public init(wire: WireSessionRefusal) {
        switch wire {
        case .invalidSignature: self = .invalidSignature
        case .staleSignature: self = .staleSignature
        case .gamePlayerIDConflict: self = .gamePlayerIDConflict
        case .sessionExpired: self = .sessionExpired
        case .unavailable: self = .unavailable
        }
    }
}

public enum SessionError: Error, Equatable, Sendable {
    case refused(SessionRefusal)
}

/// An open session: the token resumes it on a later connection; the player is as the server keeps it.
public struct OpenSession: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var token: [UInt8]
    public var player: GameCenterPlayer

    public init(token: [UInt8], player: GameCenterPlayer) {
        self.token = token
        self.player = player
    }

    // The token never prints (#161): not in a description, a debug description or a dump.
    public var description: String { "OpenSession(\(player.gamePlayerID.rawValue))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["player": player]) }
}

public struct RemoteSession: Sendable {
    public let connection: ServiceConnection

    public init(_ connection: ServiceConnection) { self.connection = connection }

    private func call(_ call: SessionCall) async throws -> SessionResult {
        let reply = try await connection.request { .sessionRequest(ServiceRequest(id: $0, call: call)) }
        guard case .sessionReply(let reply) = reply else { throw ServiceLinkError.unexpectedReply("\(reply.type) to a session call") }
        return reply.result
    }

    private func open(_ call: SessionCall) async throws -> OpenSession {
        switch try await self.call(call) {
        case .signedIn(let token, let player): return OpenSession(token: token, player: GameCenterPlayer(wire: player))
        case .refused(let refusal): throw SessionError.refused(SessionRefusal(wire: refusal))
        // The call isn't named by value: a resume carries its token, a sign-in its signature (#161).
        case .signedOut: throw ServiceLinkError.unexpectedReply("signedOut to \(call.name)")
        }
    }

    /// Signs `player` in with Game Center's `signature` for it; its restrictions are what Game Center reports now.
    public func signIn(_ signature: IdentitySignature, as player: GameCenterPlayer) async throws -> OpenSession {
        try await open(.signIn(signature: signature.wire, player: player.wire))
    }

    /// Resumes the session `token` names.
    public func resume(token: [UInt8], as player: GameCenterPlayer) async throws -> OpenSession {
        try await open(.resume(token: token, player: player.wire))
    }

    public func signOut() async throws {
        guard case .signedOut = try await call(.signOut) else { throw ServiceLinkError.unexpectedReply("to signOut") }
    }
}

extension SessionCall {
    /// Which call it is, without what it carries.
    var name: String {
        switch self {
        case .signIn: "signIn"
        case .resume: "resume"
        case .signOut: "signOut"
        }
    }
}
