import RegattaCore
import RegattaProtocol
import RegattaServices
import Synchronization

// The client's one session with the services (#161): it opens a connection when the device has a Game Center
// player who can use it, the app is in the foreground and the device is online; signs in or resumes; keeps the
// link alive; and opens it again when it drops. Everything it touches is handed in (the link, the device's
// identity, the token store, the sleeper, the jitter draw), so it runs the same under a test's virtual time.
//
// What the app shows as "signed in" is this session, not Game Center on the device: `identity.state()` is
// `.signedIn` only while the session is open.

/// Where the session stands.
public enum SessionPhase: Equatable, Sendable {
    /// Nothing to connect for: no player, one who can neither chat nor race online, offline, or in the background.
    case idle
    /// Opening, or waiting to try again.
    case connecting
    /// Open, as this player (as the server keeps her).
    case open(GameCenterPlayer)
    /// The tries ran out (`Backoff.maxFailures`). The next foreground, path change or `open()` starts over.
    case unreachable
    /// The server won't sign this player in. `gamePlayerIDConflict` stays until another player signs in;
    /// `invalidSignature` until `open()` tries again.
    case refused(SessionRefusal)
    /// The server won't serve this build: nothing more until the app is updated.
    case updateRequired
}

/// What the session reports for a log. No case carries a token, a signature or a player's id.
public enum SessionLogEvent: Equatable, Sendable {
    case connecting(resuming: Bool)
    case opened(resumed: Bool)
    case failed(SessionFailure)
    case refused(SessionRefusal)
    case updateRequired
    case linkLost
    case gaveUp
    case signedOut
}

/// Why a try at a session failed.
public enum SessionFailure: String, Equatable, Sendable {
    case noSignature
    case connect
    case handshake
    case sessionCall
    case unavailable
    case sessionExpired
    case staleSignature
}

public enum OnlineSessionError: Error, Equatable, Sendable {
    /// No session is open, and none opened within `Settings.openWait`.
    case notConnected
    /// The server didn't answer within `Settings.callTimeout`. Not an answer: never "no race".
    case timedOut
}

public actor OnlineSession {
    public struct Settings: Equatable, Sendable {
        /// A keep-alive ping this often while open. The server drops a connection idle for 120 s.
        public var pingInterval = Duration.seconds(30)
        /// A ping unanswered for this long is a dead link.
        public var pongDeadline = Duration.seconds(10)
        /// From the connect to the session call's answer. The server closes a connection that hasn't signed in 10 s
        /// after its `Hello`.
        public var openDeadline = Duration.seconds(10)
        /// How long the device gets to make a signature (Game Center asks its own servers).
        public var signatureDeadline = Duration.seconds(10)
        public var backoff = Backoff()
        /// A call made with no session open waits this long for one, then throws `notConnected` (#162).
        public var openWait = Duration.seconds(5)
        /// A request the server hasn't answered after this long throws `timedOut`.
        public var callTimeout = Duration.seconds(10)
        /// The queue's leave is best effort: the server drops her place with the connection anyway.
        public var leaveTimeout = Duration.seconds(3)

        public init() {}
    }

    public struct Dependencies: Sendable {
        /// Opens a link to the service endpoint.
        public var connect: @Sendable () async throws -> any SessionLink
        public var device: any DeviceIdentitySource
        public var tokens: any SessionTokenStore
        /// Waits; throws when its task is cancelled.
        public var sleep: @Sendable (Duration) async throws -> Void
        /// A draw in −1…1 for the back-off's jitter.
        public var jitter: @Sendable () -> Double
        /// The app's build, for `Hello`.
        public var clientBuild: String
        public var log: @Sendable (SessionLogEvent) -> Void

        public init(connect: @escaping @Sendable () async throws -> any SessionLink, device: any DeviceIdentitySource,
                    tokens: any SessionTokenStore, sleep: @escaping @Sendable (Duration) async throws -> Void,
                    jitter: @escaping @Sendable () -> Double, clientBuild: String,
                    log: @escaping @Sendable (SessionLogEvent) -> Void = { _ in }) {
            self.connect = connect
            self.device = device
            self.tokens = tokens
            self.sleep = sleep
            self.jitter = jitter
            self.clientBuild = clientBuild
            self.log = log
        }
    }

    private struct Live: Sendable {
        var player: DevicePlayer
        var link: HandshakenLink
        var connection: ServiceConnection
        var session: OpenSession
    }

    private enum Outcome {
        case open(Live, resumed: Bool)
        /// Refused in a way one fresh try can mend: an expired session signs in, a stale or bad signature is fetched again.
        case again(SessionRefusal)
        case ended(SessionPhase)
        case failed(SessionFailure)
    }

    private let dependencies: Dependencies
    private let settings: Settings
    private let phases = Broadcast<SessionPhase>(.idle)
    private let identityStates = Broadcast<GameCenterState>(.signedOut)
    private let queueStates = Broadcast<QueueState>(nil)
    /// Counts the connections opened: what the services' calls and streams wait on (#162).
    private let opens = Broadcast<Int>(nil)
    private var opened = 0

    private var isOnline: Bool
    private var isActive: Bool
    private var device: DevicePlayer?
    /// Who the runner is connecting or connected for.
    private var serving: DevicePlayer?
    /// Bumped whenever the runner is replaced or stopped: a runner acts only in its own epoch.
    private var epoch = 0
    private var runner: Task<Void, Never>?
    /// The runner ended without a session, and only `open()` starts another.
    private var halted = false
    /// The runner is between tries.
    private var waitingToRetry = false
    private var live: Live?
    /// Reads the open connection's queue stream into `queueStates`.
    private var queueReader: Task<Void, Never>?
    private var updateRequired = false
    /// Players the server refused for good (ADR 0010's first claimant keeps the `gamePlayerID`).
    private var conflicted: Set<String> = []
    private var waiters: [CheckedContinuation<SessionPhase, Never>] = []
    private var watch: Task<Void, Never>?
    public private(set) var phase = SessionPhase.idle

    public init(_ dependencies: Dependencies, settings: Settings = Settings(), isOnline: Bool = true, isActive: Bool = true) {
        self.dependencies = dependencies
        self.settings = settings
        self.isOnline = isOnline
        self.isActive = isActive
    }

    // MARK: - What the session is told

    /// Starts following the device's player. Until then the session is idle.
    public func start() {
        guard watch == nil else { return }
        let updates = dependencies.device.playerUpdates()
        watch = Task { for await player in updates { self.deviceChanged(player) } }
    }

    /// Closes the session's connection and stops following the device. The session on the server stays, with its token.
    public func shutdown() {
        watch?.cancel()
        watch = nil
        device = nil
        stop()
        show(.idle)
        settle()
    }

    /// The device's path came or went. Offline: no tries; back online: one at once.
    public func setOnline(_ online: Bool) {
        isOnline = online
        reconcile()
    }

    /// The app became active or went to the background. In the background the socket is closed.
    public func setActive(_ active: Bool) {
        isActive = active
        reconcile()
    }

    /// The device has `player` now (`start()` feeds this from the device's stream).
    public func deviceChanged(_ player: DevicePlayer?) {
        let old = device
        device = player
        if let old, old.teamPlayerID != player?.teamPlayerID { forget(old) }
        // A token kept for anyone else is a leftover (an account switched while the app wasn't running).
        if let player { try? dependencies.tokens.removeAll(except: player.teamPlayerID) }
        reconcile()
    }

    /// "Get a session open" (a Race online tap, the lobby's Try again): starts over if the tries had run out, and
    /// returns where the next try leaves it: `.open`, a refusal, or `.unreachable` when that try failed (the
    /// session keeps trying behind it). `.idle` when there is nothing to connect for.
    @discardableResult public func open() async -> SessionPhase {
        if case .open = phase { return phase }
        if serving == nil { reconcile() }
        guard let serving else { return phase }
        if halted {
            if phase == .refused(.gamePlayerIDConflict) || phase == .updateRequired { return phase }
            run(for: serving)
        } else if waitingToRetry {
            // She asked: no sitting out the rest of a back-off.
            run(for: serving)
        }
        return await withCheckedContinuation { waiters.append($0) }
    }

    // MARK: - What the session gives

    /// The phase now, then each change.
    public nonisolated func phaseUpdates() -> AsyncStream<SessionPhase> { phases.subscribe() }

    /// The open session's connection, for the services that need one (#162–#166). Nil while none is open. The
    /// server closes the connection on a gated call (race session, profile, analytics, deletion) from a player
    /// who isn't through the gate: check the terms first.
    public func connection() -> ServiceConnection? { live?.connection }

    /// The app's identity service: signed in only while this session is open.
    public nonisolated var identity: any IdentityService { SessionIdentityService(session: self) }
    /// The terms as the server keeps them.
    public nonisolated var terms: any TermsService { SessionTermsService(session: self) }
    /// The queue (#162): its state stream through reconnects, `join` and `leave` on whichever connection is open.
    /// The server answers a player who isn't through the gate in the stream and in `join`'s refusal.
    public nonisolated var queue: any QueueService { SessionQueueService(session: self, states: queueStates) }
    /// The player's race around the race transport (#162). The server closes the connection on these from a player who
    /// isn't through the gate: ask only for one who has accepted the terms and may race online.
    public nonisolated var raceSession: any RaceSessionService { SessionRaceSessionService(session: self) }
    /// The profile and the stored livery (#162). Gated like `raceSession`.
    public nonisolated var profile: any ProfileService { SessionProfileService(session: self) }

    /// Whether the device has a Game Center player: with none there is no session to wait for, and the services answer
    /// as the server would a signed-out caller.
    fileprivate var hasPlayer: Bool { device != nil }

    /// `body` on the open connection, waiting up to `openWait` for one (`notConnected`) and `limit`, or `callTimeout`,
    /// for its answer (`timedOut`).
    fileprivate nonisolated func call<Answer: Sendable>(
        within limit: Duration? = nil, _ body: @escaping @Sendable (ServiceConnection) async throws -> Answer
    ) async throws -> Answer {
        let connection = try await openConnection()
        return try await withDeadline(limit ?? settings.callTimeout, sleep: dependencies.sleep) { try await body(connection) }
    }

    /// As `call`, but with no wait for a connection: with none open the server has let her place go already, and she is
    /// not queued.
    fileprivate func leaveQueue() async throws {
        guard let connection = live?.connection else { throw QueueError.notQueued }
        try await withDeadline(settings.leaveTimeout, sleep: dependencies.sleep) { try await RemoteQueueService(connection).leave() }
    }

    private nonisolated func openConnection() async throws -> ServiceConnection {
        if let connection = await connection() { return connection }
        let (session, opens) = (self, opens)
        do {
            return try await withDeadline(settings.openWait, sleep: dependencies.sleep) {
                for await _ in opens.subscribe() {
                    if let connection = await session.connection() { return connection }
                }
                throw OnlineSessionError.notConnected
            }
        } catch OnlineSessionError.timedOut {
            throw OnlineSessionError.notConnected
        }
    }

    /// A stream that outlives connections: `open` is opened again on each new one while the reader holds it (the
    /// server primes it), and it finishes after an item `isLast` (#162).
    fileprivate nonisolated func resilient<Element: Sendable>(
        _ open: @escaping @Sendable (ServiceConnection) -> AsyncStream<Element>,
        isLast: @escaping @Sendable (Element) -> Bool = { _ in false }
    ) -> AsyncStream<Element> {
        let (session, opens) = (self, opens)
        return AsyncStream { continuation in
            let reader = Task {
                for await _ in opens.subscribe() {
                    guard let connection = await session.connection() else { continue }
                    for await element in open(connection) {
                        continuation.yield(element)
                        if isLast(element) { return continuation.finish() }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in reader.cancel() }
        }
    }

    fileprivate func identityState() async -> GameCenterState {
        guard let live else { return .signedOut }
        return await RemoteIdentityService(live.connection).state()
    }

    fileprivate nonisolated func identityUpdates() -> AsyncStream<GameCenterState> { identityStates.subscribe() }

    fileprivate func signature() async throws -> IdentitySignature { try await dependencies.device.identitySignature() }

    fileprivate func signIn() async -> GameCenterState {
        if device == nil, let player = await dependencies.device.signIn() { deviceChanged(player) }
        await open()
        return await identityState()
    }

    fileprivate func remoteTerms() throws -> RemoteTermsService {
        guard let live else { throw OnlineSessionError.notConnected }
        return RemoteTermsService(live.connection)
    }

    /// Accepts the terms on the open connection. To a player who hadn't, the server's queue stream said so and ended
    /// (its gate, #34): once she has, it is read again, or a join would never hear where it stands (#162).
    fileprivate func acceptTerms(_ version: TermsVersion) async throws -> TermsStatus {
        let connection = try remoteTerms().connection
        let status = try await RemoteTermsService(connection).accept(version)
        if status.isAccepted, live?.connection === connection { readQueue(on: connection) }
        return status
    }

    /// Feeds the queue's state on `connection` to `queueStates`, in place of whichever stream was read before.
    private func readQueue(on connection: ServiceConnection) {
        queueReader?.cancel()
        let states = queueStates
        queueReader = Task {
            for await state in RemoteQueueService(connection).stateUpdates() {
                guard !Task.isCancelled else { return }
                states.send(state)
            }
        }
    }

    // MARK: - Running

    private var target: DevicePlayer? {
        guard isActive, isOnline, let device, device.canUseOnline else { return nil }
        return device
    }

    /// Brings the runner in line with who there is to connect for.
    private func reconcile() {
        let target = target
        // Already so: running or halted for her, or idle with nobody to connect for.
        let settled = target == nil ? (phase == .idle || updateRequired) : (runner != nil || halted)
        if serving == target, settled {
            // Nobody signed in on the device from the start: the queue's stream says so, as after a sign-out.
            if device == nil { queueStates.send(.unavailable(.notSignedIn)) }
            return
        }
        stop()
        guard let target else {
            if !updateRequired { show(.idle) }
            // Signed out: the queue's last state was another player's.
            if device == nil { queueStates.send(.unavailable(.notSignedIn)) }
            settle()
            return
        }
        serving = target
        if updateRequired {
            halted = true
            show(.updateRequired)
            settle()
        } else if conflicted.contains(target.teamPlayerID) {
            halted = true
            show(.refused(.gamePlayerIDConflict))
            settle()
        } else {
            run(for: target)
        }
    }

    private func run(for player: DevicePlayer) {
        epoch += 1
        runner?.cancel()
        halted = false
        waitingToRetry = false
        show(.connecting)
        let epoch = epoch
        runner = Task { await self.run(player, epoch: epoch) }
    }

    /// Stops the runner and closes the connection. The token stays.
    private func stop() {
        epoch += 1
        runner?.cancel()
        runner = nil
        serving = nil
        halted = false
        waitingToRetry = false
        live?.link.close()
        live = nil
    }

    /// `old` is no longer the device's player (signed out, or another account): her session is revoked and her
    /// token deleted.
    private func forget(_ old: DevicePlayer) {
        if let live, live.player.teamPlayerID == old.teamPlayerID {
            // Off the session's books first, so `stop()` leaves the link open for the sign-out's answer.
            self.live = nil
            dependencies.log(.signedOut)
            Task {
                try? await RemoteSession(live.connection).signOut()
                live.link.close()
            }
        }
        stop()
        try? dependencies.tokens.removeToken(for: old.teamPlayerID)
    }

    private func run(_ player: DevicePlayer, epoch: Int) async {
        var failures = 0
        var retried: [SessionRefusal] = []
        while epoch == self.epoch, !Task.isCancelled {
            var outcome = await attempt(player, epoch: epoch)
            guard epoch == self.epoch, !Task.isCancelled else {
                if case .open(let live, _) = outcome { live.link.close() }
                return
            }
            if case .again(let refusal) = outcome {
                if !retried.contains(refusal) {
                    retried.append(refusal)
                    continue
                }
                // The fresh try was refused the same way.
                switch refusal {
                case .invalidSignature: outcome = .ended(.refused(.invalidSignature))
                case .staleSignature: outcome = .failed(.staleSignature)
                default: outcome = .failed(.sessionExpired)
                }
            }
            switch outcome {
            case .open(let live, let resumed):
                failures = 0
                retried = []
                self.live = live
                dependencies.log(.opened(resumed: resumed))
                show(.open(live.session.player))
                settle()
                opened += 1
                opens.send(opened)
                readQueue(on: live.connection)
                await untilDead(live.link)
                queueReader?.cancel()
                guard epoch == self.epoch, !Task.isCancelled else { return }
                self.live = nil
                live.link.close()
                dependencies.log(.linkLost)
                show(.connecting)
            case .ended(let phase):
                halted = true
                runner = nil
                show(phase)
                settle()
                return
            case .failed(let failure):
                failures += 1
                dependencies.log(.failed(failure))
                settle(with: .unreachable)
                if settings.backoff.stops(afterFailures: failures) {
                    halted = true
                    runner = nil
                    dependencies.log(.gaveUp)
                    show(.unreachable)
                    return
                }
                let delay = settings.backoff.delay(afterFailures: failures, jitter: dependencies.jitter())
                waitingToRetry = true
                do { try await dependencies.sleep(delay) } catch { return }
                guard epoch == self.epoch else { return }
                waitingToRetry = false
            case .again:
                break
            }
        }
    }

    /// One try: the token or a signature, the socket, `Hello`, then resume or sign in.
    private func attempt(_ player: DevicePlayer, epoch: Int) async -> Outcome {
        let team = player.teamPlayerID
        // Always resume when there is a token: a sign-in per launch would use up the player's five sessions.
        let token = (try? dependencies.tokens.token(for: team)) ?? nil
        var signature: IdentitySignature?
        if token == nil {
            // Before the socket opens: the server's sign-in deadline runs from `Hello`, and Game Center can be slow.
            guard let fetched = await fetchSignature() else { return .failed(.noSignature) }
            signature = fetched
        }
        guard epoch == self.epoch else { return .failed(.connect) }
        dependencies.log(.connecting(resuming: token != nil))
        guard let link = try? await dependencies.connect() else { return .failed(.connect) }
        guard epoch == self.epoch else {
            link.close()
            return .failed(.connect)
        }
        let (sleep, limit) = (dependencies.sleep, settings.openDeadline)
        let deadline = Task {
            do {
                try await sleep(limit)
                link.close()
            } catch {}
        }
        defer { deadline.cancel() }

        let handshaken: HandshakenLink
        switch await ServiceHandshake.open(link, clientBuild: dependencies.clientBuild) {
        case .accepted(let link): handshaken = link
        case .failed: return .failed(.handshake)
        case .updateRequired:
            updateRequired = true
            dependencies.log(.updateRequired)
            queueStates.send(.unavailable(.updateRequired))
            return .ended(.updateRequired)
        }
        let connection = ServiceConnection(handshaken)
        let remote = RemoteSession(connection)
        do {
            let session: OpenSession
            if let token {
                session = try await remote.resume(token: token, as: player.player)
            } else if let signature {
                session = try await remote.signIn(signature, as: player.player)
            } else {
                return .failed(.noSignature)
            }
            // Superseded while it was opening (another account, the background): nothing is kept.
            guard epoch == self.epoch else {
                link.close()
                return .failed(.connect)
            }
            // Kept before anyone hears the session is open.
            try? dependencies.tokens.setToken(session.token, for: team)
            return .open(Live(player: player, link: handshaken, connection: connection, session: session), resumed: token != nil)
        } catch SessionError.refused(let refusal) {
            link.close()
            dependencies.log(.refused(refusal))
            switch refusal {
            case .sessionExpired:
                // Idle 30 days, 90 days old, or trimmed by a sixth session: sign in afresh, on a new connection.
                try? dependencies.tokens.removeToken(for: team)
                return .again(.sessionExpired)
            case .staleSignature: return .again(.staleSignature)
            case .invalidSignature: return .again(.invalidSignature)
            case .gamePlayerIDConflict:
                conflicted.insert(team)
                return .ended(.refused(.gamePlayerIDConflict))
            case .unavailable: return .failed(.unavailable)
            }
        } catch {
            link.close()
            return .failed(.sessionCall)
        }
    }

    /// The device's signature, or nil when it has none or takes longer than `signatureDeadline`.
    private func fetchSignature() async -> IdentitySignature? {
        let (device, sleep, limit) = (dependencies.device, dependencies.sleep, settings.signatureDeadline)
        return await withCheckedContinuation { continuation in
            let answer = Once(continuation)
            let timer = Task {
                do { try await sleep(limit) } catch { return }
                answer.resume(nil)
            }
            Task {
                let signature = try? await device.identitySignature()
                timer.cancel()
                answer.resume(signature)
            }
        }
    }

    /// Returns when the link has closed, or a ping went unanswered.
    private func untilDead(_ link: HandshakenLink) async {
        let (sleep, settings) = (dependencies.sleep, settings)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for await _ in link.closed {} }
            group.addTask {
                while !Task.isCancelled {
                    do { try await sleep(settings.pingInterval) } catch { return }
                    let answered = await withTaskGroup(of: Bool.self) { round in
                        round.addTask { (try? await link.ping()) != nil }
                        round.addTask {
                            do { try await sleep(settings.pongDeadline) } catch { return true }
                            // Late: closing the link ends the ping that is still waiting.
                            link.close()
                            return false
                        }
                        let first = await round.next() ?? false
                        round.cancelAll()
                        return first
                    }
                    if !answered { return }
                }
            }
            await group.next()
            group.cancelAll()
        }
    }

    private func show(_ phase: SessionPhase) {
        self.phase = phase
        phases.send(phase)
        if case .open(let player) = phase { identityStates.send(.signedIn(player)) } else { identityStates.send(.signedOut) }
    }

    /// Answers everyone waiting in `open()`.
    private func settle(with answer: SessionPhase? = nil) {
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume(returning: answer ?? phase) }
    }
}

// MARK: - The services on the session

/// Game Center as the server sees it, through the session (#161).
struct SessionIdentityService: IdentityService {
    let session: OnlineSession

    func state() async -> GameCenterState { await session.identityState() }
    func stateUpdates() -> AsyncStream<GameCenterState> { session.identityUpdates() }
    func gamePlayerID() async -> GamePlayerID? { await session.identityState().player?.gamePlayerID }
    func identitySignature() async throws -> IdentitySignature { try await session.signature() }
    func signIn() async -> GameCenterState { await session.signIn() }
}

/// The terms on whichever connection the session has open. Throws `OnlineSessionError.notConnected` with none.
struct SessionTermsService: TermsService {
    let session: OnlineSession

    func status() async throws -> TermsStatus { try await session.remoteTerms().status() }
    func accept(_ version: TermsVersion) async throws -> TermsStatus { try await session.acceptTerms(version) }
}

/// The queue on the session (#162): one state stream through every reconnect, and its calls on the open connection.
struct SessionQueueService: QueueService {
    let session: OnlineSession
    let states: Broadcast<QueueState>

    func stateUpdates() -> AsyncStream<QueueState> { states.subscribe() }
    func join() async throws {
        guard await session.hasPlayer else { throw QueueError.refused(.notSignedIn) }
        try await session.call { try await RemoteQueueService($0).join() }
    }
    func leave() async throws { try await session.leaveQueue() }
}

/// The race session on the session (#162). `results()` and `ratingChanges()` are opened again on each new connection:
/// the server primes the first with the current report and replays rating changes she hasn't read.
struct SessionRaceSessionService: RaceSessionService {
    let session: OnlineSession

    func handOff() async throws -> HandOff { try await session.call { try await RemoteRaceSessionService($0).handOff() } }
    func rejoin() async throws -> RejoinOffer { try await session.call { try await RemoteRaceSessionService($0).rejoin() } }
    func lastRace() async throws -> LastRace? { try await session.call { try await RemoteRaceSessionService($0).lastRace() } }

    func results() -> AsyncStream<RaceUpdate> {
        session.resilient({ RemoteRaceSessionService($0).results() }, isLast: { update in
            switch update {
            case .report(let report): report.isClosed
            case .cancelled: true
            }
        })
    }

    func ratingChanges() -> AsyncStream<RatingChange> { session.resilient { RemoteRaceSessionService($0).ratingChanges() } }
}

/// The profile on the session (#162): what the livery sync needs of it.
struct SessionProfileService: ProfileService {
    let session: OnlineSession

    func profile() async throws -> Profile {
        guard await session.hasPlayer else { throw ProfileError.notSignedIn }
        return try await session.call { try await RemoteProfileService($0).profile() }
    }

    func saveLivery(_ livery: Livery) async throws -> Livery {
        guard await session.hasPlayer else { throw ProfileError.notSignedIn }
        return try await session.call { try await RemoteProfileService($0).saveLivery(livery) }
    }
}

private enum Raced<Answer: Sendable>: Sendable {
    case answer(Answer)
    case late
}

/// `body`'s answer, or `OnlineSessionError.timedOut` when it takes longer than `limit`. `body` is cancelled then.
func withDeadline<Answer: Sendable>(
    _ limit: Duration, sleep: @escaping @Sendable (Duration) async throws -> Void, _ body: @escaping @Sendable () async throws -> Answer
) async throws -> Answer {
    try await withThrowingTaskGroup(of: Raced<Answer>.self) { group in
        group.addTask { .answer(try await body()) }
        group.addTask {
            try await sleep(limit)
            return .late
        }
        defer { group.cancelAll() }
        guard case .answer(let answer)? = try await group.next() else { throw OnlineSessionError.timedOut }
        return answer
    }
}

/// The latest value to every subscriber, each change once. A stream from here never finishes on its own: it
/// outlives the connections its values came over.
final class Broadcast<Element: Equatable & Sendable>: Sendable {
    private struct State {
        var last: Element?
        var listeners: [Int: AsyncStream<Element>.Continuation] = [:]
        var nextListener = 0
    }

    private let state: Mutex<State>

    init(_ initial: Element?) { state = Mutex(State(last: initial)) }

    func send(_ element: Element) {
        state.withLock { state in
            guard state.last != element else { return }
            state.last = element
            for listener in state.listeners.values { listener.yield(element) }
        }
    }

    func subscribe() -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self)
        let id = state.withLock { state in
            state.nextListener += 1
            state.listeners[state.nextListener] = continuation
            if let last = state.last { continuation.yield(last) }
            return state.nextListener
        }
        continuation.onTermination = { [weak self] _ in self?.state.withLock { $0.listeners[id] = nil } }
        return stream
    }
}

/// A continuation only the first answer resumes.
private final class Once<Value: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<Value, Never>?>

    init(_ continuation: CheckedContinuation<Value, Never>) { self.continuation = Mutex(continuation) }

    func resume(_ value: Value) {
        let continuation = continuation.withLock { slot in
            defer { slot = nil }
            return slot
        }
        continuation?.resume(returning: value)
    }
}
