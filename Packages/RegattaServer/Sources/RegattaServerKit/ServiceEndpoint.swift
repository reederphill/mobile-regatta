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
// `StreamNext` on it is answered `StreamEnd`). Every service behind the identity, session and terms calls is gated
// (#34), deny by default: signed in, allowed by Game Center's restrictions, and the current Terms of Use accepted
// (deleting the player's online data needs only the sign-in). The lobby and the queue answer a refusal in the shape
// the `OnlineAccess` contracts expect; the rest close the connection.
// Until a session is signed in the connection's frames are capped at `preSignInFrameCap`, at the frame's header.

/// What the endpoint is run with.
public struct ServiceEndpointConfig: Sendable {
    /// The Terms of Use version players must have accepted (`TERMS_VERSION`). A bump re-asks everyone.
    public var termsVersion: Int
    /// How long a session lasts from its last sign-in or resume.
    public var sessionLifetime: TimeInterval
    /// A stream with no `StreamNext` for this long is dropped.
    public var streamIdleTimeout: Duration
    /// The largest frame either way (`serviceFrameLimit`), once signed in.
    public var frameCap: Int
    /// The largest frame a client may send before it is signed in: Hello and a session call are a few hundred bytes.
    public var preSignInFrameCap: Int
    /// Streams a connection may hold open at once, and before it is signed in.
    public var maxOpenStreams: Int
    public var maxOpenStreamsBeforeSignIn: Int
    /// The player's last online session time (G8) moves on lobby, queue or race use at most this often.
    public var sessionTouchInterval: TimeInterval
    /// A connection past `Hello` that isn't signed in this long after it (or after signing out) is closed (#146, R4).
    public var signInDeadline: Duration
    /// A connection with no frame either way (a WebSocket ping counts) for this long is closed (#146, R4).
    public var idleTimeout: Duration
    public var serverBuild: String

    public init(termsVersion: Int = 1, sessionLifetime: TimeInterval = 30 * 86_400, streamIdleTimeout: Duration = .seconds(60),
                frameCap: Int = serviceFrameLimit, preSignInFrameCap: Int = 1 << 14, maxOpenStreams: Int = 16,
                maxOpenStreamsBeforeSignIn: Int = 4, sessionTouchInterval: TimeInterval = 3_600,
                signInDeadline: Duration = .seconds(10), idleTimeout: Duration = .seconds(120), serverBuild: String = "dev") {
        self.signInDeadline = signInDeadline
        self.idleTimeout = idleTimeout
        self.termsVersion = termsVersion
        self.sessionLifetime = sessionLifetime
        self.streamIdleTimeout = streamIdleTimeout
        self.frameCap = frameCap
        self.preSignInFrameCap = min(preSignInFrameCap, frameCap)
        self.maxOpenStreams = maxOpenStreams
        self.maxOpenStreamsBeforeSignIn = min(maxOpenStreamsBeforeSignIn, maxOpenStreams)
        self.sessionTouchInterval = sessionTouchInterval
        self.serverBuild = serverBuild
    }
}

/// The services behind the gate, one set per signed-in connection: later tickets (#146 on) fill these in. A request
/// to one that isn't there closes the connection, as on the loopback.
///
/// Every stream a backend returns is read one item per client `StreamNext`, so a client that stops reading leaves
/// the items in the stream's own buffer: each must be bounded (#146, R6). A stream of states coalesces to the
/// latest (`bufferingNewest(1)`), a stream of events keeps a fixed number (`bufferingNewest(n)`); none is unbounded.
/// A backend that is also `ConnectionScoped` hears when its connection ends.
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

/// A backend that holds something for its connection (a place in the queue): told once when the connection ends,
/// or when the connection signs in as someone else.
public protocol ConnectionScoped: Sendable {
    func connectionEnded() async
}

/// Everything a service connection needs from the server.
public struct ServiceEndpoint: Sendable {
    public let config: ServiceEndpointConfig
    public let sessions: SessionAuthority
    public let backends: ServiceBackends
    /// The global queue (#146), when the server has one: the server drives it, and `POST /dev/situation` arranges it.
    public let matchmaker: QueueMatchmaker?

    public init(config: ServiceEndpointConfig, sessions: SessionAuthority, backends: ServiceBackends = .none,
                matchmaker: QueueMatchmaker? = nil) {
        self.config = config
        self.sessions = sessions
        self.backends = backends
        self.matchmaker = matchmaker
    }

    public var store: any AccountStore { sessions.store }
}

/// Where a connection's frames go: each `send` one WebSocket message; `close` ends the connection.
public protocol ServiceFrameSink: Sendable {
    func send(_ frame: [UInt8])
    func close(reason: String)
    /// From now on the client may send frames up to `bytes` (the transport refuses larger ones at their header).
    /// Called before the reply that changes it is sent.
    func allowFrames(upTo bytes: Int)
}

extension ServiceFrameSink {
    public func allowFrames(upTo bytes: Int) {}
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
    /// When this connection last moved the player's last online session time.
    private var lastTouch: Date?
    /// Mirrors `identity.signedIn != nil`, for the frame and stream caps.
    private var isSignedIn = false
    /// Closes a connection that isn't signed in `signInDeadline` after `Hello` or a sign-out (R4).
    private var signInDeadline: Task<Void, Never>?
    /// Closes a connection with no frame either way for `idleTimeout` (R4).
    private var idleWatch: Task<Void, Never>?
    private var lastActivity = ContinuousClock.now

    /// The backend services for the signed-in player, made once per session.
    private struct Backends {
        var queue: (any QueueService)?
        var raceSession: (any RaceSessionService)?
        var lobby: (any LobbyService)?
        var profile: (any ProfileService)?
        var analytics: (any AnalyticsTransport)?
        var deletion: (any DataDeletionService)?

        /// The ones that hold something for the connection.
        var scoped: [any ConnectionScoped] {
            let all: [Any?] = [queue, raceSession, lobby, profile, analytics, deletion]
            return all.compactMap { $0 as? any ConnectionScoped }
        }
    }

    public init(endpoint: ServiceEndpoint, sink: any ServiceFrameSink) {
        self.endpoint = endpoint
        self.sink = sink
    }

    public var isClosed: Bool { phase == .closed }

    /// One frame from the client.
    public func receive(_ bytes: [UInt8]) async {
        lastActivity = .now
        switch phase {
        case .closed: return
        case .awaitingHello: hello(bytes)
        case .open:
            let cap = isSignedIn ? endpoint.config.frameCap : endpoint.config.preSignInFrameCap
            guard bytes.count <= cap else { return close("frame over the cap") }
            guard let message = try? Frame(decoding: bytes).message, message.type.direction == .clientToServer,
                  message.type.rawValue >= MessageType.identityRequest.rawValue
            else { return close("not a service request") }
            await handle(message)
        }
    }

    /// The transport closed.
    public func ended() async {
        phase = .closed
        tearDown()
        await identity.finish()
        for backend in backends?.scoped ?? [] { await backend.connectionEnded() }
        backends = nil
    }

    /// A frame the handler doesn't see (a WebSocket ping) arrived: the connection isn't idle.
    public func noteActivity() { lastActivity = .now }

    /// Stops every timer and every pending read: nothing outlives the connection (R6).
    private func tearDown() {
        signInDeadline?.cancel()
        idleWatch?.cancel()
        for stream in streams.values { stream.cancel() }
        streams = [:]
    }

    // MARK: Handshake

    private func hello(_ bytes: [UInt8]) {
        guard let version = Frame.helloProtocolVersion(in: bytes) else { return close("expected Hello") }
        guard version == wireProtocolVersion else { return updateRequired(.protocolVersion) }
        guard let frame = try? Frame(decoding: bytes), case .hello(let hello) = frame.message else { return close("undecodable Hello") }
        guard SeatConnection.canSail(clientSimulationVersion: hello.simulationVersion) else { return updateRequired(.simulationVersion) }
        phase = .open
        send(.helloAck(HelloAck(serverBuild: endpoint.config.serverBuild)))
        armSignInDeadline()
        watchIdle()
    }

    // MARK: Deadlines (R4)

    private func armSignInDeadline() {
        signInDeadline?.cancel()
        let deadline = endpoint.config.signInDeadline
        signInDeadline = Task {
            try? await Task.sleep(for: deadline)
            guard !Task.isCancelled else { return }
            self.signInDeadlinePassed()
        }
    }

    private func signInDeadlinePassed() {
        guard !isSignedIn else { return }
        close("no sign-in in time")
    }

    private func watchIdle() {
        let timeout = endpoint.config.idleTimeout
        idleWatch = Task {
            while !Task.isCancelled {
                guard let remaining = self.idleRemaining(timeout) else { return }
                guard remaining > .zero else { return self.close("idle") }
                try? await Task.sleep(for: remaining)
            }
        }
    }

    /// How long until the connection is idle, or nil once it's closed.
    private func idleRemaining(_ timeout: Duration) -> Duration? {
        guard phase != .closed else { return nil }
        return timeout - (ContinuousClock.now - lastActivity)
    }

    private func updateRequired(_ reason: UpdateRequired.Reason) {
        send(.updateRequired(UpdateRequired(reason: reason)))
        close("update required")
    }

    // MARK: Requests

    private func handle(_ message: Message) async {
        // Deny by default: only the calls a signed-out connection needs pass without the gate.
        let denial: Denial?
        switch message {
        case .sessionRequest, .streamNext, .streamClose, .identityRequest, .termsRequest: denial = nil
        default: denial = await gate(message.type)
        }
        switch message {
        case .sessionRequest(let request):
            reply(.sessionReply(ServiceReply(id: request.id, result: await session(request.call))))
        case .streamNext(let next):
            streamNext(next)
        case .streamClose(let close):
            streams.removeValue(forKey: close.stream)?.cancel()
        case .identityRequest(let request):
            // The one stream a signed-out connection opens on its own: the Identity contract reads `signedOut` on it.
            if request.call == .openStateUpdates {
                return open(request.id, identity.stateUpdates()) { .identityReply(ServiceReply(id: $0, result: .state($1.wire))) }
            }
            answer(await ServiceAnswers.identity(request.call, identity)) { .identityReply(ServiceReply(id: request.id, result: $0)) }
        case .termsRequest(let request):
            guard let session = await identity.signedIn else { return close("terms before signing in") }
            let terms = StoreTermsService(store: endpoint.store, playerID: session.player.teamPlayerID,
                                          currentVersion: endpoint.config.termsVersion, now: endpoint.sessions.now)
            answer(await ServiceAnswers.terms(request.call, terms)) { .termsReply(ServiceReply(id: request.id, result: $0)) }
        case .queueRequest(let request):
            let service: any QueueService
            if let denial {
                guard let refusal = denial.queueRefusal else { return close("queue refused: \(denial)") }
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
            if let denial {
                guard let closure = denial.lobbyClosure else { return close("lobby refused: \(denial)") }
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
            if let denial { return close("race session refused: \(denial)") }
            guard let service = backends?.raceSession else { return close("no race session service") }
            switch request.call {
            case .openResults:
                open(request.id, service.results()) { .raceSessionReply(ServiceReply(id: $0, result: .update($1.wire))) }
            case .openRatingChanges:
                open(request.id, service.ratingChanges()) { .raceSessionReply(ServiceReply(id: $0, result: .ratingChange($1.wire))) }
            default:
                answer(await ServiceAnswers.raceSession(request.call, service)) { .raceSessionReply(ServiceReply(id: request.id, result: $0)) }
            }
        case .profileRequest(let request):
            if let denial { return close("profile refused: \(denial)") }
            guard let service = backends?.profile else { return close("no profile service") }
            answer(await ServiceAnswers.profile(request.call, service)) { .profileReply(ServiceReply(id: request.id, result: $0)) }
        case .analyticsRequest(let request):
            if let denial { return close("analytics refused: \(denial)") }
            guard let service = backends?.analytics else { return close("no analytics service") }
            answer(await ServiceAnswers.analytics(request.call, service)) { .analyticsReply(ServiceReply(id: request.id, result: $0)) }
        case .deletionRequest(let request):
            if let denial { return close("deletion refused: \(denial)") }
            guard let service = backends?.deletion else { return close("no deletion service") }
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
            // A new sign-in on this connection ends the session it had (R11), unless it resumed that same one.
            if let previous = await identity.signedIn, previous.sessionID != session.sessionID {
                await endpoint.sessions.signOut(previous)
            }
            await setSession(session)
            return .signedIn(token: token, player: session.gameCenterPlayer.wire)
        case .refused(let refusal):
            return .refused(refusal)
        }
    }

    private func setSession(_ session: SignedInSession?) async {
        let previous = await identity.signedIn
        if previous?.player.teamPlayerID != session?.player.teamPlayerID {
            for backend in backends?.scoped ?? [] { await backend.connectionEnded() }
            backends = session.map { Self.backends(endpoint.backends, $0.player) }
        }
        lastTouch = session.map { _ in endpoint.sessions.now() }
        isSignedIn = session != nil
        if isSignedIn { signInDeadline?.cancel() } else if previous != nil { armSignInDeadline() }
        sink.allowFrames(upTo: isSignedIn ? endpoint.config.frameCap : endpoint.config.preSignInFrameCap)
        await identity.set(session)
    }

    private static func backends(_ factories: ServiceBackends, _ player: AccountPlayer) -> Backends {
        Backends(queue: factories.queue(player), raceSession: factories.raceSession(player), lobby: factories.lobby(player),
                 profile: factories.profile(player), analytics: factories.analytics(player), deletion: factories.deletion(player))
    }

    // MARK: The gate (#34, #145)

    private func termsAccepted(_ session: SignedInSession) async -> Bool {
        guard let last = try? await endpoint.store.lastAcceptedTerms(playerID: session.player.teamPlayerID) else { return false }
        return last >= endpoint.config.termsVersion
    }

    /// Why the gate turns a connection away.
    private enum Denial: CustomStringConvertible {
        case notSignedIn, multiplayerRestricted, communicationRestricted, termsNotAccepted

        var queueRefusal: QueueRefusal? {
            switch self {
            case .notSignedIn: .notSignedIn
            case .multiplayerRestricted: .multiplayerRestricted
            case .termsNotAccepted: .termsNotAccepted
            case .communicationRestricted: nil
            }
        }

        var lobbyClosure: LobbyClosure? {
            switch self {
            case .notSignedIn: .notSignedIn
            case .communicationRestricted: .communicationRestricted
            case .termsNotAccepted: .termsNotAccepted
            case .multiplayerRestricted: nil
            }
        }

        var description: String {
            switch self {
            case .notSignedIn: "not signed in"
            case .multiplayerRestricted: "multiplayer restricted"
            case .communicationRestricted: "communication restricted"
            case .termsNotAccepted: "terms not accepted"
            }
        }
    }

    /// The gate in front of every service but identity, sessions and terms: signed in, then the restriction that
    /// service has (multiplayer for the queue and races, communication for the lobby), then the current terms. A
    /// call let through is the player online now (G8). Deleting the player's online data needs only the sign-in
    /// (owner ruling, 2026-10-08): no terms, no restrictions, and it isn't use.
    private func gate(_ type: MessageType) async -> Denial? {
        guard let session = await identity.signedIn else { return .notSignedIn }
        if type == .deletionRequest { return nil }
        switch type {
        case .queueRequest, .raceSessionRequest:
            if session.restrictions.isMultiplayerGamingRestricted { return .multiplayerRestricted }
        case .lobbyRequest:
            if session.restrictions.isUnderage || session.restrictions.isPersonalizedCommunicationRestricted { return .communicationRestricted }
        default:
            break
        }
        guard await termsAccepted(session) else { return .termsNotAccepted }
        await touch(session)
        return nil
    }

    /// The lobby, the queue or a race in use: the player's last online session is now (G8). Sign-in and resume record
    /// it; after that at most once per `sessionTouchInterval`, so a connection that stays up for days keeps it moving.
    private func touch(_ session: SignedInSession) async {
        let now = endpoint.sessions.now()
        if let lastTouch, now.timeIntervalSince(lastTouch) < endpoint.config.sessionTouchInterval { return }
        lastTouch = now
        try? await endpoint.store.touchSession(teamPlayerID: session.player.teamPlayerID, at: now)
    }

    // MARK: Streams

    /// A stream the client opened: each `StreamNext` takes its next item; one read at a time. Its read and idle
    /// timer are cancelled when it closes, expires or the connection ends (R6): a pending read is never left
    /// awaiting a backend stream nobody will answer for.
    private final class OpenStream: @unchecked Sendable {
        let next: @Sendable (UInt32) async -> Message?
        var reading = false
        var idle: Task<Void, Never>?
        var read: Task<Void, Never>?

        func cancel() {
            idle?.cancel()
            read?.cancel()
        }

        init<Element: Sendable>(_ stream: AsyncStream<Element>, reply: @escaping @Sendable (UInt32, Element) -> Message) {
            let box = IteratorBox(stream.makeAsyncIterator())
            next = { id in await box.next().map { reply(id, $0) } }
        }
    }

    private func open<Element: Sendable>(
        _ id: UInt32, _ stream: AsyncStream<Element>, reply: @escaping @Sendable (UInt32, Element) -> Message
    ) {
        guard streams[id] == nil else { return close("stream \(id) is already open") }
        let cap = isSignedIn ? endpoint.config.maxOpenStreams : endpoint.config.maxOpenStreamsBeforeSignIn
        guard streams.count < cap else { return close("more than \(cap) streams open") }
        let open = OpenStream(stream, reply: reply)
        streams[id] = open
        armIdle(id, open)
    }

    private func streamNext(_ next: StreamNext) {
        guard let stream = streams[next.stream] else { return reply(.streamEnd(StreamEnd(id: next.id))) }
        guard !stream.reading else { return close("two reads of stream \(next.stream) at once") }
        stream.reading = true
        stream.idle?.cancel()
        stream.read = Task {
            let item = await stream.next(next.id)
            self.delivered(item, for: next, stream)
        }
    }

    private func delivered(_ item: Message?, for next: StreamNext, _ stream: OpenStream) {
        guard phase == .open else { return }
        stream.reading = false
        stream.read = nil
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
        stream.cancel()
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
        lastActivity = .now
        sink.send(bytes)
    }

    private func close(_ reason: String) {
        guard phase != .closed else { return }
        phase = .closed
        tearDown()
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
