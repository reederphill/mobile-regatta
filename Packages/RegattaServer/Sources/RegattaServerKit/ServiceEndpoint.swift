import Foundation
import GameCenterIdentity
import Persistence
import RegattaCore
import RegattaProtocol
import RegattaServiceClient
import RegattaServiceLoopback
import RegattaServices

// The service endpoint (#145): one WebSocket per client at `/service`, carrying the service messages (#143). The
// connection opens with the version handshake (`Hello`, answered `HelloAck` or `UpdateRequired`, as on `/race`),
// then a session call signs the player in (a Game Center identity signature) or resumes a session by its token.
// Requests are answered in order; a `StreamNext` waits for its item on its own, so a stream with nothing to say
// never holds up the requests behind it. A stream nobody reads for `streamIdleTimeout` is dropped (a later
// `StreamNext` on it is answered `StreamEnd`). The lobby and the queue are gated (#34): signed in, allowed by Game
// Center's restrictions, and the current Terms of Use accepted, or the refusal the `OnlineAccess` contracts expect.

/// What the endpoint is run with.
public struct ServiceEndpointConfig: Sendable {
    /// The Terms of Use version players must have accepted (`TERMS_VERSION`). A bump re-asks everyone.
    public var termsVersion: Int
    /// How long a session lasts from its last sign-in or resume.
    public var sessionLifetime: TimeInterval
    /// A stream with no `StreamNext` for this long is dropped.
    public var streamIdleTimeout: Duration
    /// The largest frame either way (`serviceFrameLimit`).
    public var frameCap: Int
    public var serverBuild: String

    public init(termsVersion: Int = 1, sessionLifetime: TimeInterval = 30 * 86_400, streamIdleTimeout: Duration = .seconds(60),
                frameCap: Int = serviceFrameLimit, serverBuild: String = "dev") {
        self.termsVersion = termsVersion
        self.sessionLifetime = sessionLifetime
        self.streamIdleTimeout = streamIdleTimeout
        self.frameCap = frameCap
        self.serverBuild = serverBuild
    }
}

/// The services behind the gate, one set per signed-in connection: later tickets (#146 on) fill these in. A request
/// to one that isn't there closes the connection, as on the loopback.
public struct ServiceBackends: Sendable {
    public typealias Factory<Service> = @Sendable (AccountPlayer) -> Service?

    public var queue: Factory<any QueueService>
    public var raceSession: Factory<any RaceSessionService>
    public var lobby: Factory<any LobbyService>
    public var profile: Factory<any ProfileService>
    public var analytics: Factory<any AnalyticsTransport>
    public var deletion: Factory<any DataDeletionService>

    public init(
        queue: @escaping Factory<any QueueService> = { _ in nil }, raceSession: @escaping Factory<any RaceSessionService> = { _ in nil },
        lobby: @escaping Factory<any LobbyService> = { _ in nil }, profile: @escaping Factory<any ProfileService> = { _ in nil },
        analytics: @escaping Factory<any AnalyticsTransport> = { _ in nil }, deletion: @escaping Factory<any DataDeletionService> = { _ in nil }
    ) {
        self.queue = queue
        self.raceSession = raceSession
        self.lobby = lobby
        self.profile = profile
        self.analytics = analytics
        self.deletion = deletion
    }

    public static let none = ServiceBackends()
}

/// Everything a service connection needs from the server.
public struct ServiceEndpoint: Sendable {
    public let config: ServiceEndpointConfig
    public let sessions: SessionAuthority
    public let backends: ServiceBackends

    public init(config: ServiceEndpointConfig, sessions: SessionAuthority, backends: ServiceBackends = .none) {
        self.config = config
        self.sessions = sessions
        self.backends = backends
    }

    public var store: any AccountStore { sessions.store }
}

/// Where a connection's frames go: each `send` one WebSocket message; `close` ends the connection.
public protocol ServiceFrameSink: Sendable {
    func send(_ frame: [UInt8])
    func close(reason: String)
}

/// One client's service connection. The transport feeds it each frame in order (`receive`), awaiting each; it
/// answers through the sink.
public actor ServiceConnectionHandler {
    private enum Phase { case awaitingHello, open, closed }

    private let endpoint: ServiceEndpoint
    private let sink: any ServiceFrameSink
    private var phase = Phase.awaitingHello
    private var seq: UInt32 = 0
    private let identity = ConnectionIdentity()
    private var backends: Backends?
    private var streams: [UInt32: OpenStream] = [:]
    private var touched = false

    /// The backend services for the signed-in player, made once per session.
    private struct Backends {
        var queue: (any QueueService)?
        var raceSession: (any RaceSessionService)?
        var lobby: (any LobbyService)?
        var profile: (any ProfileService)?
        var analytics: (any AnalyticsTransport)?
        var deletion: (any DataDeletionService)?
    }

    public init(endpoint: ServiceEndpoint, sink: any ServiceFrameSink) {
        self.endpoint = endpoint
        self.sink = sink
    }

    public var isClosed: Bool { phase == .closed }

    /// One frame from the client.
    public func receive(_ bytes: [UInt8]) async {
        switch phase {
        case .closed: return
        case .awaitingHello: hello(bytes)
        case .open:
            guard bytes.count <= endpoint.config.frameCap else { return close("frame over the cap") }
            guard let message = try? Frame(decoding: bytes).message, message.type.direction == .clientToServer,
                  message.type.rawValue >= MessageType.identityRequest.rawValue
            else { return close("not a service request") }
            await handle(message)
        }
    }

    /// The transport closed.
    public func ended() async {
        phase = .closed
        for stream in streams.values { stream.idle?.cancel() }
        streams = [:]
        await identity.finish()
    }

    // MARK: Handshake

    private func hello(_ bytes: [UInt8]) {
        guard let version = Frame.helloProtocolVersion(in: bytes) else { return close("expected Hello") }
        guard version == wireProtocolVersion else { return updateRequired(.protocolVersion) }
        guard let frame = try? Frame(decoding: bytes), case .hello(let hello) = frame.message else { return close("undecodable Hello") }
        guard SeatConnection.canSail(clientSimulationVersion: hello.simulationVersion) else { return updateRequired(.simulationVersion) }
        phase = .open
        send(.helloAck(HelloAck(serverBuild: endpoint.config.serverBuild)))
    }

    private func updateRequired(_ reason: UpdateRequired.Reason) {
        send(.updateRequired(UpdateRequired(reason: reason)))
        close("update required")
    }

    // MARK: Requests

    private func handle(_ message: Message) async {
        switch message {
        case .sessionRequest(let request):
            reply(.sessionReply(ServiceReply(id: request.id, result: await session(request.call))))
        case .streamNext(let next):
            streamNext(next)
        case .streamClose(let close):
            streams.removeValue(forKey: close.stream)?.idle?.cancel()
        case .identityRequest(let request):
            if request.call == .openStateUpdates {
                return open(request.id, identity.stateUpdates()) { .identityReply(ServiceReply(id: $0, result: .state($1.wire))) }
            }
            answer(await ServiceAnswers.identity(request.call, identity)) { .identityReply(ServiceReply(id: request.id, result: $0)) }
        case .termsRequest(let request):
            guard let session = await identity.signedIn else { return close("terms before signing in") }
            touch(session)
            let terms = StoreTermsService(store: endpoint.store, playerID: session.player.teamPlayerID,
                                          currentVersion: endpoint.config.termsVersion, now: endpoint.sessions.now)
            answer(await ServiceAnswers.terms(request.call, terms)) { .termsReply(ServiceReply(id: request.id, result: $0)) }
        case .queueRequest(let request):
            let service: any QueueService
            if let refusal = await queueRefusal() {
                service = ClosedQueueService(refusal: refusal)
            } else if let queue = backends?.queue {
                service = queue
            } else {
                return close("no queue service")
            }
            if request.call == .openStateUpdates {
                return open(request.id, service.stateUpdates()) { .queueReply(ServiceReply(id: $0, result: .state($1.wire))) }
            }
            answer(await ServiceAnswers.queue(request.call, service)) { .queueReply(ServiceReply(id: request.id, result: $0)) }
        case .lobbyRequest(let request):
            let service: any LobbyService
            if let closure = await lobbyClosure() {
                service = ClosedLobbyService(closure: closure)
            } else if let lobby = backends?.lobby {
                service = lobby
            } else {
                return close("no lobby service")
            }
            if request.call == .openFeed {
                return open(request.id, service.feed()) { .lobbyReply(ServiceReply(id: $0, result: .event($1.wire))) }
            }
            answer(await ServiceAnswers.lobby(request.call, service)) { .lobbyReply(ServiceReply(id: request.id, result: $0)) }
        case .raceSessionRequest(let request):
            guard let service = await signedInBackends()?.raceSession else { return close("no race session service") }
            switch request.call {
            case .openResults:
                open(request.id, service.results()) { .raceSessionReply(ServiceReply(id: $0, result: .update($1.wire))) }
            case .openRatingChanges:
                open(request.id, service.ratingChanges()) { .raceSessionReply(ServiceReply(id: $0, result: .ratingChange($1.wire))) }
            default:
                answer(await ServiceAnswers.raceSession(request.call, service)) { .raceSessionReply(ServiceReply(id: request.id, result: $0)) }
            }
        case .profileRequest(let request):
            guard let service = await signedInBackends()?.profile else { return close("no profile service") }
            answer(await ServiceAnswers.profile(request.call, service)) { .profileReply(ServiceReply(id: request.id, result: $0)) }
        case .analyticsRequest(let request):
            guard let service = await signedInBackends()?.analytics else { return close("no analytics service") }
            answer(await ServiceAnswers.analytics(request.call, service)) { .analyticsReply(ServiceReply(id: request.id, result: $0)) }
        case .deletionRequest(let request):
            guard let service = await signedInBackends()?.deletion else { return close("no deletion service") }
            answer(await ServiceAnswers.deletion(request.call, service)) { .deletionReply(ServiceReply(id: request.id, result: $0)) }
        default:
            close("\(message.type) isn't a service request")
        }
    }

    private func answer<Result>(_ result: Result?, _ wrap: (Result) -> Message) {
        guard let result else { return close("the service had no answer") }
        reply(wrap(result))
    }

    private func session(_ call: SessionCall) async -> SessionResult {
        let outcome: SessionAuthority.Outcome
        switch call {
        case .signIn(let signature, let player): outcome = await endpoint.sessions.signIn(signature, player: player)
        case .resume(let token, let player): outcome = await endpoint.sessions.resume(token: token, player: player)
        case .signOut:
            if let session = await identity.signedIn { await endpoint.sessions.signOut(session) }
            await setSession(nil)
            return .signedOut
        }
        switch outcome {
        case .signedIn(let token, let session):
            await setSession(session)
            return .signedIn(token: token, player: session.gameCenterPlayer.wire)
        case .refused(let refusal):
            return .refused(refusal)
        }
    }

    private func setSession(_ session: SignedInSession?) async {
        let previous = await identity.signedIn
        if previous?.player.teamPlayerID != session?.player.teamPlayerID {
            backends = session.map { Self.backends(endpoint.backends, $0.player) }
        }
        touched = session != nil
        await identity.set(session)
    }

    private static func backends(_ factories: ServiceBackends, _ player: AccountPlayer) -> Backends {
        Backends(queue: factories.queue(player), raceSession: factories.raceSession(player), lobby: factories.lobby(player),
                 profile: factories.profile(player), analytics: factories.analytics(player), deletion: factories.deletion(player))
    }

    private func signedInBackends() async -> Backends? {
        guard let session = await identity.signedIn else { return nil }
        touch(session)
        return backends
    }

    // MARK: The gate (#34, #145)

    private func termsAccepted(_ session: SignedInSession) async -> Bool {
        guard let last = try? await endpoint.store.lastAcceptedTerms(playerID: session.player.teamPlayerID) else { return false }
        return last >= endpoint.config.termsVersion
    }

    /// Why this connection can't use the queue now, or nil.
    private func queueRefusal() async -> QueueRefusal? {
        guard let session = await identity.signedIn else { return .notSignedIn }
        if session.restrictions.isMultiplayerGamingRestricted { return .multiplayerRestricted }
        guard await termsAccepted(session) else { return .termsNotAccepted }
        touch(session)
        return nil
    }

    /// Why the lobby is closed to this connection now, or nil.
    private func lobbyClosure() async -> LobbyClosure? {
        guard let session = await identity.signedIn else { return .notSignedIn }
        if session.restrictions.isUnderage || session.restrictions.isPersonalizedCommunicationRestricted { return .communicationRestricted }
        guard await termsAccepted(session) else { return .termsNotAccepted }
        touch(session)
        return nil
    }

    /// The lobby, the queue or a race in use: the player's last online session is now (G8). Once per connection
    /// beyond the sign-in, which records it too.
    private func touch(_ session: SignedInSession) {
        guard !touched else { return }
        touched = true
        let store = endpoint.store, now = endpoint.sessions.now
        Task { try? await store.touchSession(teamPlayerID: session.player.teamPlayerID, at: now()) }
    }

    // MARK: Streams

    /// A stream the client opened: each `StreamNext` takes its next item; one read at a time.
    private final class OpenStream: @unchecked Sendable {
        let next: @Sendable (UInt32) async -> Message?
        var reading = false
        var idle: Task<Void, Never>?

        init<Element: Sendable>(_ stream: AsyncStream<Element>, reply: @escaping @Sendable (UInt32, Element) -> Message) {
            let box = IteratorBox(stream.makeAsyncIterator())
            next = { id in await box.next().map { reply(id, $0) } }
        }
    }

    private func open<Element: Sendable>(
        _ id: UInt32, _ stream: AsyncStream<Element>, reply: @escaping @Sendable (UInt32, Element) -> Message
    ) {
        guard streams[id] == nil else { return close("stream \(id) is already open") }
        let open = OpenStream(stream, reply: reply)
        streams[id] = open
        armIdle(id, open)
    }

    private func streamNext(_ next: StreamNext) {
        guard let stream = streams[next.stream] else { return reply(.streamEnd(StreamEnd(id: next.id))) }
        guard !stream.reading else { return close("two reads of stream \(next.stream) at once") }
        stream.reading = true
        stream.idle?.cancel()
        Task {
            let item = await stream.next(next.id)
            self.delivered(item, for: next, stream)
        }
    }

    private func delivered(_ item: Message?, for next: StreamNext, _ stream: OpenStream) {
        guard phase == .open else { return }
        stream.reading = false
        guard let item, streams[next.stream] === stream else {
            if streams[next.stream] === stream { streams[next.stream] = nil }
            return reply(.streamEnd(StreamEnd(id: next.id)))
        }
        reply(item)
        armIdle(next.stream, stream)
    }

    private func armIdle(_ id: UInt32, _ stream: OpenStream) {
        let timeout = endpoint.config.streamIdleTimeout
        stream.idle = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self.expire(id, stream)
        }
    }

    private func expire(_ id: UInt32, _ stream: OpenStream) {
        guard streams[id] === stream, !stream.reading else { return }
        streams[id] = nil
    }

    /// Open streams, for tests.
    public var openStreamCount: Int { streams.count }

    // MARK: Sending

    private func reply(_ message: Message) { send(message) }

    private func send(_ message: Message) {
        guard phase != .closed else { return }
        seq &+= 1
        guard let bytes = try? Frame(seq: seq, tick: 0, message: message).encoded() else { return close("unencodable \(message.type)") }
        guard bytes.count <= endpoint.config.frameCap else { return close("\(message.type) over the frame cap") }
        sink.send(bytes)
    }

    private func close(_ reason: String) {
        guard phase != .closed else { return }
        phase = .closed
        sink.close(reason: reason)
    }
}

private final class IteratorBox<Element: Sendable>: @unchecked Sendable {
    var iterator: AsyncStream<Element>.Iterator

    init(_ iterator: AsyncStream<Element>.Iterator) { self.iterator = iterator }

    func next() async -> Element? { await iterator.next() }
}

// MARK: - The gate's refusals, as services

/// The queue to a connection the gate turns away: unavailable for `refusal` (#34).
struct ClosedQueueService: QueueService {
    let refusal: QueueRefusal

    func stateUpdates() -> AsyncStream<QueueState> {
        AsyncStream { continuation in
            continuation.yield(.unavailable(refusal))
            continuation.finish()
        }
    }

    func join() throws { throw QueueError.refused(refusal) }
    func leave() throws { throw QueueError.notQueued }
}

/// The lobby to a connection the gate turns away: closed for `closure`, reading and posting both (#17, #34).
struct ClosedLobbyService: LobbyService {
    let closure: LobbyClosure

    var closedState: LobbyState { LobbyState(access: .closed(closure), canPostFreeText: false) }

    func state() -> LobbyState { closedState }
    func history() throws -> [LobbyMessage] { throw LobbyError.closed(closure) }

    func feed() -> AsyncStream<LobbyEvent> {
        AsyncStream { continuation in
            continuation.yield(.state(closedState))
            continuation.finish()
        }
    }

    func post(_ text: String) throws -> LobbyMessage { throw LobbyError.closed(closure) }
    func post(_ quickChat: QuickChat) throws -> LobbyMessage { throw LobbyError.closed(closure) }
    func block(_ player: GamePlayerID) throws { throw LobbyError.closed(closure) }
    func unblock(_ player: GamePlayerID) throws { throw LobbyError.closed(closure) }
    func blockedPlayers() throws -> [BlockedPlayer] { throw LobbyError.closed(closure) }
    func report(message: MessageID) throws { throw LobbyError.closed(closure) }
    func report(player: GamePlayerID) throws { throw LobbyError.closed(closure) }
    func report(race: RaceID, seat: Int, reason: RaceReportReason) throws { throw LobbyError.closed(closure) }
}
