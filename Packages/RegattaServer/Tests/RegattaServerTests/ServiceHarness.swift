import Foundation
import GameCenterIdentity
import Persistence
import RegattaCore
import RegattaProtocol
import RegattaServerKit
import RegattaServiceClient
import RegattaServices
import Synchronization

/// A service connection to a `ServiceConnectionHandler` in this process: the client's frames go to the handler in
/// order, one awaited at a time, as the server's socket loop feeds them; the handler's frames come back on
/// `incoming`. `open` does the version handshake first, so a `ServiceConnection` takes over after it.
final class InProcessServiceLink: ServiceLink, @unchecked Sendable {
    // @unchecked: the mutable state is behind `state`; `forward` is set once in init, before any frame flows.
    private struct State {
        var handshake: [[UInt8]]? = []
        var closeReason: String?
    }

    let handler: ServiceConnectionHandler
    let incoming: AsyncStream<[UInt8]>
    private let toClient: AsyncStream<[UInt8]>.Continuation
    private let toServer: AsyncStream<[UInt8]>.Continuation
    private let state = Mutex(State())

    private init(endpoint: ServiceEndpoint) {
        (incoming, toClient) = AsyncStream<[UInt8]>.makeStream()
        let (serverInbox, toServer) = AsyncStream<[UInt8]>.makeStream()
        self.toServer = toServer
        let forward = Forward()
        handler = ServiceConnectionHandler(endpoint: endpoint, sink: forward)
        forward.link = self
        let target = handler
        Task {
            for await bytes in serverInbox { await target.receive(bytes) }
            await target.ended()
        }
    }

    /// The handler's sink: this link's server side.
    private final class Forward: ServiceFrameSink, @unchecked Sendable {
        weak var link: InProcessServiceLink?
        func send(_ frame: [UInt8]) { link?.fromServer(frame) }
        func close(reason: String) { link?.closedByServer(reason) }
    }

    /// A link past the handshake (`Hello` answered `HelloAck`); throws the server's other answers.
    static func open(_ endpoint: ServiceEndpoint, hello: Hello = Hello(clientBuild: "test", files: [])) async throws -> InProcessServiceLink {
        let link = InProcessServiceLink(endpoint: endpoint)
        await link.handler.receive(try Frame(seq: 1, tick: 0, message: .hello(hello)).encoded())
        let answered = link.state.withLock { state in
            defer { state.handshake = nil }
            return state.handshake ?? []
        }
        guard answered.count == 1, case .helloAck? = try? Frame(decoding: answered[0]).message else {
            throw HandshakeRefused(frames: answered.compactMap { try? Frame(decoding: $0).message }, closed: link.closeReason != nil)
        }
        return link
    }

    struct HandshakeRefused: Error {
        let frames: [Message]
        let closed: Bool
    }

    /// Why the server closed the connection, once it has.
    var closeReason: String? { state.withLock { $0.closeReason } }

    private func fromServer(_ frame: [UInt8]) {
        let held: Bool = state.withLock { state in
            guard state.handshake != nil else { return false }
            state.handshake?.append(frame)
            return true
        }
        if !held { toClient.yield(frame) }
    }

    private func closedByServer(_ reason: String) {
        state.withLock { $0.closeReason = $0.closeReason ?? reason }
        toClient.finish()
        toServer.finish()
    }

    /// Sends raw bytes to the server, as a client would.
    func send(_ frame: [UInt8]) { toServer.yield(frame) }

    func close() {
        toServer.finish()
        toClient.finish()
    }
}

/// Accepts any claim with a signature, as the dev verifier does, but with no clock: the timestamp is ignored. A claim
/// whose signature is `[0]` fails as a bad signature, `[1]` as stale.
struct StubVerifier: GameCenterVerifier {
    func verify(_ claim: GameCenterIdentityClaim) async throws -> String {
        if claim.signature == [0] { throw GameCenterVerificationError.badSignature }
        if claim.signature == [1] { throw GameCenterVerificationError.staleTimestamp }
        return claim.teamPlayerID
    }
}

/// A queue that records joins: what the gate lets through.
actor RecordingQueue: QueueService {
    private(set) var joins = 0

    nonisolated func stateUpdates() -> AsyncStream<QueueState> {
        AsyncStream { $0.yield(.idle) }
    }

    func join() { joins += 1 }
    func leave() throws { throw QueueError.notQueued }
}

enum ServiceFixtures {
    static func endpoint(store: any AccountStore = InMemoryAccountStore(), termsVersion: Int = 1, idle: Duration = .seconds(60),
                         frameCap: Int = serviceFrameLimit, queue: RecordingQueue? = nil) -> ServiceEndpoint {
        ServiceEndpoint(
            config: ServiceEndpointConfig(termsVersion: termsVersion, streamIdleTimeout: idle, frameCap: frameCap),
            sessions: SessionAuthority(store: store, verifier: StubVerifier()),
            backends: ServiceBackends(queue: { _ in queue }))
    }

    static func player(_ name: String, multiplayerRestricted: Bool = false, underage: Bool = false) -> GameCenterPlayer {
        GameCenterPlayer(gamePlayerID: GamePlayerID("G:\(name)"), alias: name, isUnderage: underage,
                         isMultiplayerGamingRestricted: multiplayerRestricted)
    }

    static func signature(_ name: String, team: String? = nil, signature: [UInt8] = [9, 9]) -> IdentitySignature {
        IdentitySignature(gamePlayerID: GamePlayerID("G:\(name)"), teamPlayerID: team ?? "T:\(name)",
                          publicKeyURL: "https://static.gc.apple.com/public-key/test.cer", signature: signature, salt: [3],
                          timestamp: UInt64(Date().timeIntervalSince1970 * 1000))
    }

    /// A connection signed in as `name`.
    static func signedIn(_ endpoint: ServiceEndpoint, _ name: String, multiplayerRestricted: Bool = false,
                         underage: Bool = false) async throws -> (InProcessServiceLink, ServiceConnection, OpenSession) {
        let link = try await InProcessServiceLink.open(endpoint)
        let connection = ServiceConnection(link)
        let session = try await RemoteSession(connection).signIn(
            signature(name), as: player(name, multiplayerRestricted: multiplayerRestricted, underage: underage))
        return (link, connection, session)
    }
}
