import Foundation
import Observation
import RegattaClient
import RegattaCore
import RegattaProtocol
import RegattaServices

/// The monotonic clock the online client runs on (#64): microseconds since it was made.
struct MonotonicClock: Sendable {
    private let origin = ContinuousClock.now
    /// `-timescale` on the fakes (#141): the fake race host and its client run on the same scaled clock.
    var timescale = 1.0

    func now() -> UInt64 {
        let (seconds, attoseconds) = (ContinuousClock.now - origin).components
        let micros = UInt64(seconds) * 1_000_000 + UInt64(attoseconds / 1_000_000_000_000)
        return timescale == 1 ? micros : UInt64(Double(micros) * timescale)
    }
}

/// A race server: `host:port`, as the menu's field and `-onlineHost` give it.
struct RaceServer: Equatable {
    /// Where a development build looks by default: the Mac the simulator runs on.
    static let defaultAddress = "127.0.0.1:8080"
    /// The menu's field, in user defaults.
    nonisolated static let addressDefaultsKey = "onlineHost"

    var address: String

    /// The race WebSocket (`/race`, #67).
    var raceURL: URL? { URL(string: "ws://\(address)/race") }

    /// A path on the server's HTTP side.
    func httpURL(_ path: String, query: String? = nil) -> URL? {
        URL(string: "http://\(address)\(path)" + (query.map { "?\($0)" } ?? ""))
    }
}

/// Joining an online race and racing it, as the UI shows it (#68): connecting, the update prompt, a
/// failure to retry, or the race.
///
/// `ticket` gets a race token from wherever the build finds races: in a development build the dev
/// server's instant race (`DevInstantRace`); matchmaking later (#158 and the queue). The handshake is
/// `RaceJoin`'s, driven on a timer here and by `OnlineDriver` for rejoins.
@Observable
final class OnlineLaunch {
    enum Phase {
        case connecting
        /// The server won't race this build: the update prompt.
        case updateRequired(UpdateRequired.Reason)
        case failed(String)
        case racing(GameSession)
    }

    private(set) var phase = Phase.connecting
    let server: RaceServer
    @ObservationIgnored private let ticket: () async throws -> [UInt8]
    @ObservationIgnored private let clock: MonotonicClock
    /// Opens a race connection: the server's WebSocket, or the hand-off's connector (#141).
    @ObservationIgnored private let connect: () -> (any RaceConnection)?
    /// The online race sequence's link (#141): the join is tried again every second until it is in, with no failure
    /// panel; the Debug dev race keeps its one try and its panel.
    let isSequence: Bool
    /// Told of the race's driver as it joins, before anything runs it.
    @ObservationIgnored var onDriver: ((OnlineDriver) -> Void)?
    @ObservationIgnored private var isStopped = false
    /// The race's haptics: the app passes `AppModel.haptics`, gated by Settings (#110).
    @ObservationIgnored private let haptics: any Haptics
    /// The race's sounds: the app passes `AppModel.sound`, gated by Settings' Effects (#126).
    @ObservationIgnored private let sound: any SoundOutput
    /// The race's steering scheme: the app passes `AppModel.controls` (#112).
    @ObservationIgnored private let controls: ControlSettings
    /// The rule numbers this device has seen called (#23): the app passes `AppModel.rulesSeen`.
    @ObservationIgnored private let rulesSeen: RuleSeenStore
    /// Makes each race's hints (#129), which show online too until they stop: the app passes `AppModel.hintEngine`,
    /// so every session gets a fresh engine.
    @ObservationIgnored private let hints: (() -> HintEngine)?
    /// Told as a hint retires: the app passes `AppModel.logsHintRetired`.
    @ObservationIgnored private let onHintRetired: ((String, HintRetirement) -> Void)?
    /// The race's results from the server's stream (#133), for a race with a hand-off (`AppModel.onlineResults`). Nil
    /// for a Debug dev-instant race, which keeps the live frame's standings and its own loop.
    @ObservationIgnored private let results: OnlineResults?
    /// The briefing's seat liveries (#163), for a race with a hand-off whose briefing this device kept; nil wears the
    /// seeded fleet (`FleetLiveries(briefing:setup:mySeat:)`).
    @ObservationIgnored private let liveries: [Livery]?

    init(server: RaceServer, haptics: any Haptics = SilentHaptics(), sound: any SoundOutput = SilentSoundOutput(),
         controls: ControlSettings = ControlSettings(), rulesSeen: RuleSeenStore = RuleSeenStore(),
         hints: (() -> HintEngine)? = nil, onHintRetired: ((String, HintRetirement) -> Void)? = nil,
         results: OnlineResults? = nil, ticket: @escaping () async throws -> [UInt8]) {
        self.server = server
        clock = MonotonicClock()
        isSequence = false
        connect = { server.raceURL.map { WebSocketTransport(url: $0) } }
        self.results = results
        liveries = nil
        self.hints = hints
        self.onHintRetired = onHintRetired
        self.haptics = haptics
        self.sound = sound
        self.rulesSeen = rulesSeen
        self.controls = controls
        self.ticket = ticket
    }

    /// The race a hand-off seats her in (#141): `connect` opens each connection, `token` gives the token to join
    /// with now.
    init(connect: @escaping () -> any RaceConnection, token: @escaping () -> [UInt8], liveries: [Livery]? = nil, timescale: Double = 1,
         haptics: any Haptics = SilentHaptics(), sound: any SoundOutput = SilentSoundOutput(),
         controls: ControlSettings = ControlSettings(), rulesSeen: RuleSeenStore = RuleSeenStore(),
         hints: (() -> HintEngine)? = nil, onHintRetired: ((String, HintRetirement) -> Void)? = nil,
         results: OnlineResults? = nil) {
        server = RaceServer(address: "")
        clock = MonotonicClock(timescale: timescale)
        isSequence = true
        self.connect = { connect() }
        self.results = results
        self.liveries = liveries
        self.hints = hints
        self.onHintRetired = onHintRetired
        self.haptics = haptics
        self.sound = sound
        self.rulesSeen = rulesSeen
        self.controls = controls
        ticket = { token() }
    }

    /// The race's session, once joined.
    var session: GameSession? {
        if case .racing(let session) = phase { session } else { nil }
    }

    /// Gives the join up (#141): the link is closed.
    func stop() { isStopped = true }

    /// The link's clock, in microseconds.
    func now() -> UInt64 { clock.now() }

    /// The app's build, for `Hello`: "0.1 (1)".
    static var clientBuild: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
    }

    /// Gets a token, connects and joins; ends racing, at the prompt, or failed. The sequence's link (`isSequence`)
    /// never fails: it tries again every second until it is in or stopped.
    func start() async {
        phase = .connecting
        while !isStopped {
            if await join() { return }
            guard isSequence else { return }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// One try. True when it is settled: racing, the prompt, or a failure that isn't retried.
    private func join() async -> Bool {
        let token: [UInt8]
        do {
            token = try await ticket()
        } catch {
            phase = .failed("No race from \(server.address): \(error.localizedDescription)")
            return !isSequence
        }
        guard let transport = connect() else {
            phase = .failed("\(server.address) isn't a host:port")
            return true
        }
        let join = RaceJoin(connection: transport, token: token, clientBuild: Self.clientBuild, now: clock.now())
        while !join.isFinished, !isStopped {
            try? await Task.sleep(for: .milliseconds(5))
            join.poll(now: clock.now())
        }
        switch join.state {
        case .joined(let start):
            guard let joined = join.transport, !isStopped else {
                transport.close()
                return true
            }
            let clock = clock
            let connect = connect
            let underway = isSequence && (join.joinedTick ?? Int.min) > -start.setup.startSequenceTicks
            let driver = OnlineDriver(start: start, transport: joined, token: token, clientBuild: Self.clientBuild,
                                      now: clock.now, connect: { connect() ?? UnansweredRaceConnection() },
                                      joiningUnderway: underway, liveries: liveries)
            onDriver?(driver)
            let session = GameSession(online: driver, haptics: haptics, sound: sound, controls: controls,
                                      rulesSeen: rulesSeen, hints: hints?())
            session.onHintRetired = onHintRetired
            if let results {
                session.onlineResults = results
                results.start()
            }
            phase = .racing(session)
            return true
        case .updateRequired(let reason):
            transport.close()
            phase = .updateRequired(reason)
            return true
        case .failed(let reason):
            transport.close()
            let closeReason = (transport as? WebSocketTransport)?.closeReason.map { " (\($0))" } ?? ""
            if !isSequence { phase = .failed("\(reason)\(closeReason)") }
            return !isSequence
        case .awaitingAck, .awaitingStart:
            transport.close()
            return true
        }
    }
}

#if DEBUG
/// The dev server's instant race (#67, `POST /dev/instant-race`): a race now with bots, for this one client.
/// Development builds only, like the server endpoint (`ENV=dev`).
enum DevInstantRace {
    /// What the app reads of the server's `InstantRaceResponse` (RegattaDevAPI, which the app doesn't link).
    struct Response: Decodable {
        var raceID: String
        var seats: [Int]
        /// Base64 race tokens, one per seat.
        var tokens: [String]
    }

    enum Failure: LocalizedError {
        case badAddress
        case status(Int, String)
        case noToken

        var errorDescription: String? {
            switch self {
            case .badAddress: "not a host:port"
            case .status(let code, let body): "HTTP \(code) \(body)"
            case .noToken: "no race token in the answer"
            }
        }
    }

    /// A one-client race: `startSeconds` of sequence (nil: the server's 60 s) and closed `raceSeconds`
    /// after the gun (nil: it runs to its end). The race token.
    static func ticket(server: RaceServer, raceSeconds: Int?, startSeconds: Int?) async throws -> [UInt8] {
        var query = "clients=1"
        if let raceSeconds { query += "&raceSeconds=\(raceSeconds)" }
        if let startSeconds { query += "&startSeconds=\(startSeconds)" }
        guard let url = server.httpURL("/dev/instant-race", query: query) else { throw Failure.badAddress }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 201 else { throw Failure.status(status, String(decoding: data.prefix(200), as: UTF8.self)) }
        let race = try JSONDecoder().decode(Response.self, from: data)
        guard let text = race.tokens.first, let token = Data(base64Encoded: text) else { throw Failure.noToken }
        return [UInt8](token)
    }
}
#endif
