import Foundation
import Observation
import RegattaClient
import RegattaProtocol

/// The monotonic clock the online client runs on (#64): microseconds since it was made.
struct MonotonicClock: Sendable {
    private let origin = ContinuousClock.now

    func now() -> UInt64 {
        let (seconds, attoseconds) = (ContinuousClock.now - origin).components
        return UInt64(seconds) * 1_000_000 + UInt64(attoseconds / 1_000_000_000_000)
    }
}

/// A race server: `host:port`, as the menu's field and `-onlineHost` give it.
struct RaceServer: Equatable {
    /// Where a development build looks by default: the Mac the simulator runs on.
    static let defaultAddress = "127.0.0.1:8080"
    /// The menu's field, in user defaults.
    static let addressDefaultsKey = "onlineHost"

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
    @ObservationIgnored private let clock = MonotonicClock()

    init(server: RaceServer, ticket: @escaping () async throws -> [UInt8]) {
        self.server = server
        self.ticket = ticket
    }

    /// The app's build, for `Hello`: "0.1 (1)".
    static var clientBuild: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
    }

    /// Gets a token, connects and joins; ends racing, at the prompt, or failed.
    func start() async {
        phase = .connecting
        guard let url = server.raceURL else {
            phase = .failed("\(server.address) isn't a host:port")
            return
        }
        let token: [UInt8]
        do {
            token = try await ticket()
        } catch {
            phase = .failed("No race from \(server.address): \(error.localizedDescription)")
            return
        }
        let transport = WebSocketTransport(url: url)
        let join = RaceJoin(connection: transport, token: token, clientBuild: Self.clientBuild, now: clock.now())
        while !join.isFinished {
            try? await Task.sleep(for: .milliseconds(5))
            join.poll(now: clock.now())
        }
        switch join.state {
        case .joined(let start):
            guard let joined = join.transport else { return }
            let clock = clock
            let driver = OnlineDriver(start: start, transport: joined, token: token, clientBuild: Self.clientBuild,
                                      now: clock.now, connect: { WebSocketTransport(url: url) })
            phase = .racing(GameSession(online: driver))
        case .updateRequired(let reason):
            transport.close()
            phase = .updateRequired(reason)
        case .failed(let reason):
            transport.close()
            phase = .failed("\(reason)\(transport.closeReason.map { " (\($0))" } ?? "")")
        case .awaitingAck, .awaitingStart:
            break
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
