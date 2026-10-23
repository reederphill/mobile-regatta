import RegattaCore
import RegattaProtocol
import RegattaServiceClient
import RegattaServices
import Synchronization

// What the online session's tests run on (#161): a scripted `/service` peer, a sleeper whose time only the test
// moves, and recorders a test can wait on. No network, no Game Center, no wall clock.

/// A list a test can wait on.
final class Recorder<Item: Sendable>: Sendable {
    private struct State {
        var items: [Item] = []
        var waiters: [(done: @Sendable ([Item]) -> Bool, continuation: CheckedContinuation<[Item], Never>)] = []
    }

    private let state = Mutex(State())

    var items: [Item] { state.withLock { $0.items } }

    func add(_ item: Item) {
        let ready = state.withLock { state -> [(CheckedContinuation<[Item], Never>, [Item])] in
            state.items.append(item)
            let items = state.items
            let ready = state.waiters.filter { $0.done(items) }.map { ($0.continuation, items) }
            state.waiters.removeAll { $0.done(items) }
            return ready
        }
        for (continuation, items) in ready { continuation.resume(returning: items) }
    }

    /// The items once `done` holds for them.
    @discardableResult func wait(_ done: @escaping @Sendable ([Item]) -> Bool) async -> [Item] {
        await withCheckedContinuation { continuation in
            let items: [Item]? = state.withLock { state in
                if done(state.items) { return state.items }
                state.waiters.append((done, continuation))
                return nil
            }
            if let items { continuation.resume(returning: items) }
        }
    }
}

/// Time that moves only when the test says.
final class VirtualSleeper: Sendable {
    private struct Sleeping {
        var duration: Duration
        var due: Duration
        var continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Duration.zero
        var sleeping: [Int: Sleeping] = [:]
        var cancelled: Set<Int> = []
        var nextID = 0
        var requested: [Duration] = []
        var watchers: [(duration: Duration, continuation: CheckedContinuation<Void, Never>)] = []
    }

    private let state = Mutex(State())

    var now: Duration { state.withLock { $0.now } }
    /// Every sleep asked for, in order.
    var requested: [Duration] { state.withLock { $0.requested } }
    var sleepingNow: [Duration] { state.withLock { $0.sleeping.values.map(\.duration) } }

    func sleep(_ duration: Duration) async throws {
        let id = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let (cancelled, watchers) = state.withLock { state -> (Bool, [CheckedContinuation<Void, Never>]) in
                    if state.cancelled.remove(id) != nil { return (true, []) }
                    state.requested.append(duration)
                    state.sleeping[id] = Sleeping(duration: duration, due: state.now + duration, continuation: continuation)
                    let watchers = state.watchers.filter { $0.duration == duration }.map(\.continuation)
                    state.watchers.removeAll { $0.duration == duration }
                    return (false, watchers)
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
                for watcher in watchers { watcher.resume() }
            }
        } onCancel: {
            let sleeping = state.withLock { state -> Sleeping? in
                if let sleeping = state.sleeping.removeValue(forKey: id) { return sleeping }
                state.cancelled.insert(id)
                return nil
            }
            sleeping?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Returns once something is asleep for exactly `duration`.
    func waitForSleep(of duration: Duration) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let already = state.withLock { state in
                if state.sleeping.values.contains(where: { $0.duration == duration }) { return true }
                state.watchers.append((duration, continuation))
                return false
            }
            if already { continuation.resume() }
        }
    }

    /// Moves time on, waking whatever is due.
    func advance(by duration: Duration) {
        let due = state.withLock { state -> [Sleeping] in
            state.now += duration
            let due = state.sleeping.filter { $0.value.due <= state.now }
            for id in due.keys { state.sleeping[id] = nil }
            return due.values.sorted { $0.due < $1.due }
        }
        for sleeping in due { sleeping.continuation.resume() }
    }
}

/// A scripted `/service` peer.
final class FakeService: Sendable {
    enum Event: Equatable, Sendable {
        case signature
        case connect
        case hello
        case signIn(team: String)
        case resume([UInt8])
        case signOut(link: Int)
        case ping
        case closed(link: Int)
        /// A queue, race session or profile call (#162), by its name.
        case call(String, link: Int)
    }

    struct Script: Sendable {
        /// The next this many connects fail.
        var connectFailures = 0
        /// The answer to `Hello`; nil for none.
        var hello: Message? = .helloAck(HelloAck(serverBuild: "fake"))
        /// The answers to the next sign-ins, then a session with a fresh token.
        var signIn: [SessionResult] = []
        /// The answers to the next resumes, then the session resumed.
        var resume: [SessionResult] = []
        /// A sign-out's wrong answer, to see what a client says of it.
        var answersSessionCallsWith: SessionResult?
        var answersPings = true
        var queue = QueueState.idle
        var terms = WireTermsStatus.needsAcceptance(current: 2, lastAccepted: nil)
        /// The answers to the queue's join and leave; nil for none.
        var join: QueueResult? = .done
        var leave: QueueResult? = .done
        /// The answers to the race session's calls; nil for none (the request is held: `answerHeld`).
        var handOff: RaceSessionResult? = .noRace
        var rejoin: RaceSessionResult? = .noRace
        var lastRace: RaceSessionResult? = .noLastRace
        /// What a results or rating stream is primed with when it opens.
        var results: [RaceUpdate] = []
        var ratings: [RatingChange] = []
        var profile: ProfileResult? = .notSignedIn
        /// The answer to `saveLivery`; nil stores what was sent.
        var saveLivery: ProfileResult?
        /// The answer to an analytics batch (#166); nil: every event accepted.
        var analytics: AnalyticsResult?
        /// Whether the server holds online data for the player (#166): a plan, then a delete with its confirmation,
        /// deletes it. A newer plan voids the one before.
        var holdsOnlineData = true
    }

    /// Each `Hello`'s attestation, and each session call's player (#158).
    let hellos = Recorder<VersionedPayload>()
    let sessionPlayers = Recorder<WirePlayer>()

    private struct State {
        var script = Script()
        var links: [FakeLink] = []
        var issued = 0
        var held: [(link: FakeLink, id: UInt32)] = []
        var deletionPlans = 0
    }

    let events = Recorder<Event>()
    private let state = Mutex(State())

    func script(_ change: (inout Script) -> Void) { state.withLock { change(&$0.script) } }

    /// The `n`th token this server gives out: 32 bytes no other number has.
    static func token(_ n: Int) -> [UInt8] { (0..<32).map { UInt8(200 + n) &+ UInt8($0) } }

    func count(_ matching: (Event) -> Bool) -> Int { events.items.filter(matching).count }
    var connects: Int { count { $0 == .connect } }

    func connect() throws -> FakeLink {
        events.add(.connect)
        return try state.withLock { state in
            if state.script.connectFailures > 0 {
                state.script.connectFailures -= 1
                throw ServiceLinkError.closed
            }
            let link = FakeLink(self, number: state.links.count + 1)
            state.links.append(link)
            return link
        }
    }

    /// The server's end of the newest link closes.
    func dropLink() { state.withLock { $0.links.last }?.close() }

    /// The queue's state changes, for the newest link's stream.
    func push(_ queue: QueueState) {
        let link = state.withLock { state in
            state.script.queue = queue
            return state.links.last
        }
        link?.push(.queue) { .queueReply(ServiceReply(id: $0, result: .state(queue.wire))) }
    }

    /// The race's results change, for the newest link's results streams.
    func push(_ update: RaceUpdate) {
        state.withLock { $0.links.last }?.push(.results) { .raceSessionReply(ServiceReply(id: $0, result: .update(update.wire))) }
    }

    /// A rating change, for the newest link's rating streams.
    func push(_ change: RatingChange) {
        state.withLock { $0.links.last }?.push(.ratings) { .raceSessionReply(ServiceReply(id: $0, result: .ratingChange(change.wire))) }
    }

    /// Answers the race session calls the script left unanswered, late.
    func answerHeld(_ result: RaceSessionResult) {
        let held = state.withLock { state in
            defer { state.held = [] }
            return state.held
        }
        for (link, id) in held { link.deliver(.raceSessionReply(ServiceReply(id: id, result: result))) }
    }

    fileprivate func answersPings() -> Bool { state.withLock { $0.script.answersPings } }

    fileprivate func handle(_ message: Message, from link: FakeLink) {
        switch message {
        case .hello(let hello):
            events.add(.hello)
            hellos.add(hello.attestation)
            if let answer = state.withLock({ $0.script.hello }) { link.deliver(answer) }
        case .sessionRequest(let request):
            let result: SessionResult
            switch request.call {
            case .signIn(let signature, let player):
                events.add(.signIn(team: signature.teamPlayerID))
                sessionPlayers.add(player)
                result = state.withLock { state in
                    if let wrong = state.script.answersSessionCallsWith { return wrong }
                    if !state.script.signIn.isEmpty { return state.script.signIn.removeFirst() }
                    state.issued += 1
                    return .signedIn(token: Self.token(state.issued), player: player)
                }
            case .resume(let token, let player):
                events.add(.resume(token))
                sessionPlayers.add(player)
                result = state.withLock { state in
                    if let wrong = state.script.answersSessionCallsWith { return wrong }
                    if !state.script.resume.isEmpty { return state.script.resume.removeFirst() }
                    return .signedIn(token: token, player: player)
                }
            case .signOut:
                events.add(.signOut(link: link.number))
                result = .signedOut
            }
            if case .signedIn(_, let player) = result { link.player.withLock { $0 = player } }
            link.deliver(.sessionReply(ServiceReply(id: request.id, result: result)))
        case .identityRequest(let request):
            link.deliver(.identityReply(ServiceReply(id: request.id, result: .state(link.player.withLock { $0 }))))
        case .termsRequest(let request):
            let result: TermsResult = state.withLock { state in
                guard case .accept(let version) = request.call else { return .status(state.script.terms) }
                let current: Int
                switch state.script.terms {
                case .accepted(let version): current = version
                case .needsAcceptance(let version, _): current = version
                }
                guard version == current else { return .staleVersion(current: current) }
                state.script.terms = .accepted(version: version)
                return .status(state.script.terms)
            }
            link.deliver(.termsReply(ServiceReply(id: request.id, result: result)))
        case .queueRequest(let request):
            let script = state.withLock { $0.script }
            switch request.call {
            case .openStateUpdates:
                link.open(.queue, id: request.id, primed: [{ .queueReply(ServiceReply(id: $0, result: .state(script.queue.wire))) }])
            case .join:
                events.add(.call("join", link: link.number))
                if let result = script.join { link.deliver(.queueReply(ServiceReply(id: request.id, result: result))) }
            case .leave:
                events.add(.call("leave", link: link.number))
                if let result = script.leave { link.deliver(.queueReply(ServiceReply(id: request.id, result: result))) }
            }
        case .raceSessionRequest(let request):
            events.add(.call("\(request.call)", link: link.number))
            let script = state.withLock { $0.script }
            let result: RaceSessionResult?
            switch request.call {
            case .handOff: result = script.handOff
            case .rejoin: result = script.rejoin
            case .lastRace: result = script.lastRace
            case .openResults:
                return link.open(.results, id: request.id, primed: script.results.map { update in
                    { .raceSessionReply(ServiceReply(id: $0, result: .update(update.wire))) }
                })
            case .openRatingChanges:
                return link.open(.ratings, id: request.id, primed: script.ratings.map { change in
                    { .raceSessionReply(ServiceReply(id: $0, result: .ratingChange(change.wire))) }
                })
            }
            if let result {
                link.deliver(.raceSessionReply(ServiceReply(id: request.id, result: result)))
            } else {
                state.withLock { $0.held.append((link, request.id)) }
            }
        case .profileRequest(let request):
            let script = state.withLock { $0.script }
            switch request.call {
            case .profile:
                events.add(.call("profile", link: link.number))
                if let result = script.profile { link.deliver(.profileReply(ServiceReply(id: request.id, result: result))) }
            case .saveLivery(let livery):
                events.add(.call("saveLivery \(livery.sailNumber)", link: link.number))
                link.deliver(.profileReply(ServiceReply(id: request.id, result: script.saveLivery ?? .livery(livery))))
            }
        case .analyticsRequest(let request):
            events.add(.call("analytics \(request.call.events.count)", link: link.number))
            let result = state.withLock { $0.script.analytics } ?? .receipt(accepted: request.call.events.count, duplicates: 0)
            link.deliver(.analyticsReply(ServiceReply(id: request.id, result: result)))
        case .deletionRequest(let request):
            let result: DeletionResult = state.withLock { state in
                guard link.player.withLock({ $0 }) != nil else { return .notSignedIn }
                guard state.script.holdsOnlineData else { return .nothingToDelete }
                switch request.call {
                case .plan:
                    state.deletionPlans += 1
                    return .plan(WireDeletionPlan(deletes: WireOnlineData.allCases, anonymisesRaceLogs: true,
                                                  confirmation: "plan-\(state.deletionPlans)"))
                case .delete(let confirmation):
                    guard confirmation == "plan-\(state.deletionPlans)" else { return .invalidConfirmation }
                    state.script.holdsOnlineData = false
                    return .deleted
                }
            }
            switch request.call {
            case .plan: events.add(.call("plan", link: link.number))
            case .delete: events.add(.call("delete", link: link.number))
            }
            link.deliver(.deletionReply(ServiceReply(id: request.id, result: result)))
        case .streamNext(let next):
            link.asked(next.id, stream: next.stream)
        case .streamClose(let close):
            events.add(.call("streamClose", link: link.number))
            link.closeStream(close.stream)
        default:
            break
        }
    }
}

final class FakeLink: SessionLink {
    enum StreamKind: Sendable { case queue, results, ratings }
    typealias Item = @Sendable (UInt32) -> Message

    /// One stream the client opened: the items it hasn't read, or the `StreamNext` waiting for one.
    private struct Stream {
        var kind: StreamKind
        var waiting: [Item] = []
        var asked: UInt32?
    }

    let number: Int
    let incoming: AsyncStream<[UInt8]>
    let player = Mutex<WirePlayer?>(nil)
    private let frames: AsyncStream<[UInt8]>.Continuation
    private let gone: AsyncStream<Void>
    private let goneEnd: AsyncStream<Void>.Continuation
    private let isClosed = Mutex(false)
    private let streams = Mutex<[UInt32: Stream]>([:])
    private let server: FakeService

    fileprivate init(_ server: FakeService, number: Int) {
        self.server = server
        self.number = number
        (incoming, frames) = AsyncStream.makeStream()
        (gone, goneEnd) = AsyncStream.makeStream()
    }

    func send(_ frame: [UInt8]) {
        guard !isClosed.withLock({ $0 }), let message = try? Frame(decoding: frame).message else { return }
        server.handle(message, from: self)
    }

    func close() {
        let first = isClosed.withLock { closed in
            defer { closed = true }
            return !closed
        }
        guard first else { return }
        server.events.add(.closed(link: number))
        frames.finish()
        goneEnd.finish()
    }

    func ping() async throws {
        if isClosed.withLock({ $0 }) { throw ServiceLinkError.closed }
        server.events.add(.ping)
        if server.answersPings() { return }
        // No pong: until the link closes or the caller gives up.
        for await _ in gone {}
        throw ServiceLinkError.closed
    }

    fileprivate func deliver(_ message: Message) {
        frames.yield(try! Frame(seq: 0, tick: 0, message: message).encoded())
    }

    fileprivate func open(_ kind: StreamKind, id: UInt32, primed: [Item]) {
        streams.withLock { $0[id] = Stream(kind: kind, waiting: primed) }
    }

    fileprivate func closeStream(_ id: UInt32) { streams.withLock { $0[id] = nil } }

    /// `item` to every stream of `kind` the client has open.
    fileprivate func push(_ kind: StreamKind, _ item: @escaping Item) {
        let asked = streams.withLock { streams -> [UInt32] in
            var asked: [UInt32] = []
            for id in streams.keys where streams[id]?.kind == kind {
                if let request = streams[id]?.asked {
                    streams[id]?.asked = nil
                    asked.append(request)
                } else {
                    streams[id]?.waiting.append(item)
                }
            }
            return asked
        }
        for request in asked { deliver(item(request)) }
    }

    fileprivate func asked(_ id: UInt32, stream: UInt32) {
        let item = streams.withLock { streams -> Item? in
            guard streams[stream] != nil else { return nil }
            guard streams[stream]?.waiting.isEmpty == false else {
                streams[stream]?.asked = id
                return nil
            }
            return streams[stream]?.waiting.removeFirst()
        }
        if let item { deliver(item(id)) }
    }
}

/// A session on the fakes.
struct SessionRig: Sendable {
    static let wren = DevicePlayer(teamPlayerID: "T:wren", player: GameCenterPlayer(gamePlayerID: GamePlayerID("G:wren"), alias: "Wren"))
    static let tern = DevicePlayer(teamPlayerID: "T:tern", player: GameCenterPlayer(gamePlayerID: GamePlayerID("G:tern"), alias: "Tern"))
    /// What every test signature is made of.
    static let signatureBytes: [UInt8] = [77, 78, 79, 80, 81, 82, 83, 84]

    /// Unlike any other of the session's waits, so a test can tell them apart.
    static let openDeadline = Duration.seconds(7)
    static let signatureDeadline = Duration.seconds(9)
    static let openWait = Duration.milliseconds(4_500)
    static let callTimeout = Duration.seconds(11)
    static let leaveTimeout = Duration.milliseconds(2_500)

    let server: FakeService
    let sleeper = VirtualSleeper()
    let tokens: InMemorySessionTokenStore
    /// The players held after a deletion (#166): a rig over another rig's store is a relaunch.
    let held: InMemoryHeldPlayerStore
    let device: ScriptedDeviceIdentity
    let logs = Recorder<SessionLogEvent>()
    let phases = Recorder<SessionPhase>()
    let session: OnlineSession
    /// The token store's content at each log event: what was kept by then.
    let keptAtLog = Recorder<[String: [UInt8]]>()

    init(player: DevicePlayer? = SessionRig.wren, afterSignIn: DevicePlayer? = nil, tokens: [String: [UInt8]] = [:],
         isOnline: Bool = true, isActive: Bool = true, signatureNeverComes: Bool = false, attester: ConnectionAttester? = nil,
         held: InMemoryHeldPlayerStore = InMemoryHeldPlayerStore(), tokenStore: InMemorySessionTokenStore? = nil,
         server: FakeService = FakeService()) {
        self.server = server
        self.held = held
        let (sleeper, logs, kept) = (sleeper, logs, keptAtLog)
        let store = tokenStore ?? InMemorySessionTokenStore(tokens)
        self.tokens = store
        device = ScriptedDeviceIdentity(player: player, afterSignIn: afterSignIn) { player in
            server.events.add(.signature)
            if signatureNeverComes {
                for await _ in AsyncStream<Void>.makeStream().stream {}
            }
            return IdentitySignature(gamePlayerID: player.player.gamePlayerID, teamPlayerID: player.teamPlayerID,
                                     publicKeyURL: "https://test.invalid/key.cer", signature: Self.signatureBytes, salt: [5, 6, 7, 8], timestamp: 1)
        }
        var settings = OnlineSession.Settings()
        settings.openDeadline = Self.openDeadline
        settings.signatureDeadline = Self.signatureDeadline
        settings.openWait = Self.openWait
        settings.callTimeout = Self.callTimeout
        settings.leaveTimeout = Self.leaveTimeout
        session = OnlineSession(
            OnlineSession.Dependencies(
                connect: { try server.connect() }, device: device, tokens: store, sleep: { try await sleeper.sleep($0) },
                jitter: { 0 }, clientBuild: "test", attester: attester, held: held,
                log: { event in
                    kept.add(store.all)
                    logs.add(event)
                }),
            settings: settings, isOnline: isOnline, isActive: isActive)
        let (updates, phases) = (session.phaseUpdates(), phases)
        Task { for await phase in updates { phases.add(phase) } }
    }

    /// Starts the session and waits for it to open.
    func opened() async {
        await session.start()
        await opens(1)
    }

    /// Waits until the session has opened `count` times.
    func opens(_ count: Int) async {
        await phases.wait { phases in phases.filter { if case .open = $0 { true } else { false } }.count >= count }
    }

    func reaches(_ phase: SessionPhase) async { await phases.wait { $0.last == phase } }

    /// The back-off's sleeps so far: not the open deadline's or the keep-alive's.
    var backoffs: [Duration] {
        sleeper.requested.filter { ![Self.openDeadline, Self.signatureDeadline, Self.openWait, Self.callTimeout, Self.leaveTimeout, .seconds(30), .seconds(10)].contains($0) }
    }
}
