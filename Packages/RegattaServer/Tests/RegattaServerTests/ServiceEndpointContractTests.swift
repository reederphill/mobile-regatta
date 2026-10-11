import Foundation
import RegattaContractRunner
import RegattaDevAPI
import RegattaLoadClient
import RegattaServerKit
import RegattaServiceClient
import RegattaServices
import Synchronization
import Testing

/// #109's Identity, Terms (#145) and Queue (#146) contract suites through #143's runner against the real server: a `RegattaServer`
/// started in process on a free port, reached over its `/service` WebSocket by `WebSocketServiceConnector`, which
/// arranges each situation with `POST /dev/situation`. `CONTRACT_ENDPOINT` runs them against a server started elsewhere.
@Suite(.timeLimit(.minutes(2))) struct ServiceEndpointContractTests {
    /// The suites the server serves as of #148.
    static let served: [ContractSuiteID] = [.identity, .terms, .queue, .raceSession]

    /// A dev config the suites can run on: the Terms suite's `versionBumped` situation needs an older version to have
    /// accepted; the Queue suite's `joinable` waits for fleet lock, so it locks 3 s after the oldest join (long enough
    /// to see the queued state and leave before it), and never holds for the RaceSession suite's races' finishers (#147).
    static func config() -> ServerConfig {
        var config = ServerConfig.dev()
        config.identity.termsVersion = 2
        config.queue.lockAfter = 3
        config.queue.catchFinishers = nil
        return config
    }

    static func run(_ suites: [ContractSuiteID], against endpoint: String) async throws {
        for suite in suites {
            try await ContractRunner.run(suite, over: .endpoint(endpoint, connector: WebSocketServiceConnector()))
        }
    }

    /// Acceptance (#145, #146): the Identity, Terms and Queue suites pass against the real server through the runner.
    @Test func servedSuitesPassAgainstTheServer() async throws {
        let server = try await RegattaHTTPServer.start(config: Self.config())
        do {
            try await Self.run(Self.served, against: "ws://127.0.0.1:\(server.port)")
        } catch {
            await server.shutdown()
            throw error
        }
        await server.shutdown()
    }

    /// A client's online session (#161) to the server at `port`, for a fresh test account `POST /dev/situation` put in
    /// `situation`: its own connection over the real WebSocket, `Hello`, then a dev sign-in when the situation has a player.
    static func onlineSession(port: Int, service: String, situation: String) async throws -> OnlineSession {
        let id = UUID().uuidString.lowercased()
        let request = DevSituationRequest(service: service, situation: situation, teamPlayerID: "T:session-\(id)", gamePlayerID: "G:session-\(id)")
        let (status, body) = try await DevClient.request(.POST, "\(ServerPath.devSituation)?\(request.query)", host: "127.0.0.1", port: port)
        guard status == 200 else { throw LoadClientError.http(status: status, body: String(decoding: body, as: UTF8.self)) }
        let arranged = try JSONDecoder().decode(DevSituationResponse.self, from: Data(body))
        let player = DevicePlayer(teamPlayerID: request.teamPlayerID, player: GameCenterPlayer(
            gamePlayerID: GamePlayerID(request.gamePlayerID), alias: "Contract", isUnderage: arranged.isUnderage,
            isPersonalizedCommunicationRestricted: arranged.isPersonalizedCommunicationRestricted,
            isMultiplayerGamingRestricted: arranged.isMultiplayerGamingRestricted))
        let device = ScriptedDeviceIdentity(player: arranged.signIn ? player : nil) { player in
            IdentitySignature(gamePlayerID: player.player.gamePlayerID, teamPlayerID: player.teamPlayerID, publicKeyURL: "https://dev.invalid/gc-dev.cer",
                              signature: Array(id.utf8), salt: [1, 2, 3, 4], timestamp: UInt64(Date().timeIntervalSince1970 * 1000))
        }
        let session = OnlineSession(OnlineSession.Dependencies(
            connect: {
                let link = try await WebSocketServiceLink.connect(host: "127.0.0.1", port: port)
                // The session does the handshake itself.
                link.handOver()
                return link
            },
            device: device, tokens: InMemorySessionTokenStore(), sleep: { try await Task.sleep(for: $0) }, jitter: { 0 },
            clientBuild: "contract-session"))
        if arranged.signIn {
            await session.deviceChanged(player)
            let phase = await session.open()
            guard case .open = phase else { throw ServiceEndpointError.session("the online session didn't open: \(phase)") }
        } else {
            await session.start()
        }
        return session
    }

    /// Acceptance (#161): the Identity and Terms suites pass on the client's online session (its `identity` and
    /// `terms`, as the app holds them) against the real server over the real WebSocket.
    @Test func identityAndTermsPassThroughTheOnlineSession() async throws {
        let server = try await RegattaHTTPServer.start(config: Self.config())
        let port = server.port
        let sessions = Mutex<[OnlineSession]>([])
        @Sendable func session(_ suite: ContractSuiteID, _ situation: String) async throws -> OnlineSession {
            let session = try await Self.onlineSession(port: port, service: suite.suiteName, situation: situation)
            sessions.withLock { $0.append(session) }
            return session
        }
        let services = ContractServices(
            identity: { try await session(.identity, "\($0)").identity },
            terms: { try await session(.terms, "\($0)").terms })
        do {
            for suite in [ContractSuiteID.identity, .terms] {
                try await ContractRunner.run(suite, services: services)
                // The server allows an address 8 service connections.
                let opened = sessions.withLock { sessions in
                    defer { sessions = [] }
                    return sessions
                }
                for session in opened { await session.shutdown() }
            }
            await #expect(throws: ContractRunnerError.notProvided(.queue)) { try await ContractRunner.run(.queue, services: services) }
        } catch {
            await server.shutdown()
            throw error
        }
        await server.shutdown()
    }

    /// The keep-alive (#161): the server answers a WebSocket ping on `/service`, before any sign-in.
    @Test func theServerAnswersAServicePing() async throws {
        let server = try await RegattaHTTPServer.start(config: Self.config())
        let link = try await WebSocketServiceLink.connect(host: "127.0.0.1", port: server.port)
        try await link.ping()
        link.close()
        await #expect(throws: ServiceLinkError.closed) { try await link.ping() }
        await server.shutdown()
    }

    @Test(.enabled(if: ContractEndpoint.fromEnvironment(ProcessInfo.processInfo.environment) != nil, "CONTRACT_ENDPOINT is unset"))
    func servedSuitesPassAgainstContractEndpoint() async throws {
        let endpoint = try #require(ContractEndpoint.fromEnvironment(ProcessInfo.processInfo.environment))
        try await Self.run(try ContractEndpoint.suites(served: Self.served, ProcessInfo.processInfo.environment), against: endpoint)
    }

    @Test func situationsTheServerDoesntServeAre404AndTheHookIsDevOnly() async throws {
        let server = try await RegattaHTTPServer.start(config: Self.config())
        let request = DevSituationRequest(service: "QueueService", situation: "idle", teamPlayerID: "T:x", gamePlayerID: "G:x")
        let (status, _) = try await DevClient.request(.POST, "\(ServerPath.devSituation)?\(request.query)", host: "127.0.0.1", port: server.port)
        #expect(status == 404)
        await server.shutdown()
        #expect(Route.resolve(method: .POST, path: ServerPath.devSituation, environment: .other("prod")) == .notFound)
        #expect(Route.resolve(method: .POST, path: ServerPath.devSituation, environment: .dev) == .devSituation)
        #expect(Route.resolve(method: .GET, path: ServerPath.service, environment: .dev) == .upgradeRequired)
    }

    @Test func endpointsParseAsHostAndPort() throws {
        #expect(try WebSocketServiceConnector.hostAndPort("ws://127.0.0.1:8080") == ("127.0.0.1", 8080))
        #expect(try WebSocketServiceConnector.hostAndPort("localhost:9") == ("localhost", 9))
        #expect(try WebSocketServiceConnector.hostAndPort("http://example.test:80/service") == ("example.test", 80))
        #expect(throws: ServiceEndpointError.badEndpoint("nope")) { try WebSocketServiceConnector.hostAndPort("nope") }
    }
}
