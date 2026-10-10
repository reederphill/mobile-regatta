import Foundation
import RegattaContractRunner
import RegattaDevAPI
import RegattaLoadClient
import RegattaServerKit
import RegattaServiceClient
import Testing

/// #109's Identity, Terms (#145) and Queue (#146) contract suites through #143's runner against the real server: a `RegattaServer`
/// started in process on a free port, reached over its `/service` WebSocket by `WebSocketServiceConnector`, which
/// arranges each situation with `POST /dev/situation`. `CONTRACT_ENDPOINT` runs them against a server started elsewhere.
@Suite(.timeLimit(.minutes(2))) struct ServiceEndpointContractTests {
    /// The suites the server serves as of #146.
    static let served: [ContractSuiteID] = [.identity, .terms, .queue]

    /// A dev config the suites can run on: the Terms suite's `versionBumped` situation needs an older version to have
    /// accepted; the Queue suite's `joinable` waits for fleet lock, so it locks 3 s after the oldest join (long enough
    /// to see the queued state and leave before it).
    static func config() -> ServerConfig {
        var config = ServerConfig.dev()
        config.identity.termsVersion = 2
        config.queue.lockAfter = 3
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
