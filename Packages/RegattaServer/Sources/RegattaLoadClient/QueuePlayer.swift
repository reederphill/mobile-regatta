import Foundation
import NIOHTTP1
import RegattaClient
import RegattaDevAPI
import RegattaProtocol
import RegattaServiceClient
import RegattaServices

/// A headless player who goes through the queue (#162): the second human of an e2e run, a local demo and the package's
/// two-human test. The dev player `number` (the app's `-devIdentity <n>`: "Dev n") signs in on the client's own
/// `OnlineSession` over the real `/service` WebSocket, joins the queue, takes the hand-off at fleet lock and sails her
/// seat on the scripted helm to the close. Dev servers only: her terms are accepted by `POST /dev/situation`.
public enum QueuePlayer {
    public struct Options: Sendable {
        /// Waits this long, signed in, before joining.
        public var joinAfter = Duration.zero
        /// Fleet lock must come within this long of the join.
        public var lockTimeout = Duration.seconds(900)
        /// Joins her seat and says `LeaveRace` at once, before the gun, instead of sailing.
        public var leavesInBriefing = false
        public var load = LoadClientOptions()

        public init() {}
    }

    public struct Outcome: Sendable {
        public var alias: String
        public var handOff: HandOff
        /// The race as she sailed it; nil when she left in the briefing.
        public var load: LoadReport?
        /// The closed race's report from the service's results stream; nil when she left, or it was cancelled.
        public var closed: RaceReport?
    }

    public static func devPlayer(_ number: Int) -> DevicePlayer {
        DevicePlayer(teamPlayerID: "T:dev-\(number)", player: GameCenterPlayer(gamePlayerID: GamePlayerID("G:dev-\(number)"), alias: "Dev \(number)"))
    }

    /// The client's online session to the dev server at `host:port` as `player`, open, with her terms accepted.
    public static func session(_ player: DevicePlayer, host: String, port: Int) async throws -> OnlineSession {
        let request = DevSituationRequest(service: "QueueService", situation: "joinable", teamPlayerID: player.teamPlayerID,
                                          gamePlayerID: player.player.gamePlayerID.rawValue)
        let (status, body) = try await DevClient.request(.POST, "\(ServerPath.devSituation)?\(request.query)", host: host, port: port)
        guard status == 200 else { throw LoadClientError.http(status: status, body: String(decoding: body, as: UTF8.self)) }
        let nonce = UUID().uuidString
        let device = ScriptedDeviceIdentity(player: player) { player in
            IdentitySignature(gamePlayerID: player.player.gamePlayerID, teamPlayerID: player.teamPlayerID, publicKeyURL: "https://dev.invalid/gc-dev.cer",
                              signature: Array(nonce.utf8), salt: [1, 2, 3, 4], timestamp: UInt64(Date().timeIntervalSince1970 * 1000))
        }
        let session = OnlineSession(OnlineSession.Dependencies(
            connect: {
                let link = try await WebSocketServiceLink.connect(host: host, port: port)
                // The session does the handshake itself.
                link.handOver()
                return link
            },
            device: device, tokens: InMemorySessionTokenStore(), sleep: { try await Task.sleep(for: $0) }, jitter: { 0 },
            clientBuild: "queue-player"))
        await session.deviceChanged(player)
        let phase = await session.open()
        guard case .open = phase else { throw ServiceEndpointError.session("the online session didn't open: \(phase)") }
        return session
    }

    /// Queues the dev player `number`, and sails (or leaves) the race her fleet locks into.
    public static func play(number: Int, options: Options = Options()) async throws -> Outcome {
        let player = devPlayer(number)
        let session = try await session(player, host: options.load.host, port: options.load.port)
        do {
            let outcome = try await play(session, alias: player.player.alias, options: options)
            await session.shutdown()
            return outcome
        } catch {
            await session.shutdown()
            throw error
        }
    }

    private static func play(_ session: OnlineSession, alias: String, options: Options) async throws -> Outcome {
        if options.joinAfter > .zero { try await Task.sleep(for: options.joinAfter) }
        let queue = session.queue
        let states = queue.stateUpdates()
        try await queue.join()
        try await withDeadline(options.lockTimeout, "fleet lock") {
            for await state in states {
                if state == .fleetLocked { return }
                if case .unavailable(let refusal) = state { throw ServiceEndpointError.session("the queue refused \(alias): \(refusal)") }
            }
            throw ServiceEndpointError.session("the queue's stream ended")
        }
        let raceSession = session.raceSession
        let handOff = try await raceSession.handOff()
        if options.leavesInBriefing {
            try await LoadClient.leave(token: handOff.token.bytes, options: options.load)
            return Outcome(alias: alias, handOff: handOff, load: nil, closed: nil)
        }
        // Held from before the race, through whatever the service connection does meanwhile.
        let results = raceSession.results()
        let load = try await LoadClient.sail(token: handOff.token.bytes, options: options.load)
        let closed = try? await withDeadline(.seconds(15), "the closed report") { () -> RaceReport? in
            for await update in results {
                if case .report(let report) = update, report.isClosed { return report }
            }
            return nil
        }
        return Outcome(alias: alias, handOff: handOff, load: load, closed: closed ?? nil)
    }

    private static func withDeadline<Answer: Sendable>(
        _ limit: Duration, _ what: String, _ body: @escaping @Sendable () async throws -> Answer
    ) async throws -> Answer {
        try await withThrowingTaskGroup(of: Answer?.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: limit)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let answer = first else {
                throw ServiceEndpointError.session("no \(what) within \(limit)")
            }
            return answer
        }
    }
}
