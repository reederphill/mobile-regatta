import Foundation
import RegattaContractRunner
import RegattaProtocol
import RegattaServiceClient
import RegattaServiceContracts
import RegattaServiceLoopback
import RegattaServices
import Synchronization
import Testing

// The remote contract runner (#143): every #109 / #241 contract suite through its client adapter, over the service
// messages, against the in-process loopback serving the scripted fakes (`Fixtures`) in each situation. With
// `CONTRACT_ENDPOINT` set, the wired suites run against that endpoint too.

extension ContractLinks {
    /// A fresh loopback server per situation, serving the fixture fake in it.
    static let loopback = ContractLinks(
        identity: { LoopbackServer.connect(serving: LoopbackServices(identity: Fixtures.identity($0))) },
        terms: { LoopbackServer.connect(serving: LoopbackServices(terms: Fixtures.terms($0))) },
        queue: { LoopbackServer.connect(serving: LoopbackServices(queue: Fixtures.queue($0))) },
        raceSession: { LoopbackServer.connect(serving: LoopbackServices(raceSession: Fixtures.raceSession($0))) },
        lobby: { LoopbackServer.connect(serving: LoopbackServices(lobby: Fixtures.lobby($0))) },
        profile: { LoopbackServer.connect(serving: LoopbackServices(profile: Fixtures.profile($0))) },
        analytics: { LoopbackServer.connect(serving: LoopbackServices(analytics: Fixtures.analytics($0))) },
        deletion: { LoopbackServer.connect(serving: LoopbackServices(deletion: Fixtures.deletion($0))) })
}

@Suite struct ContractRunnerTests {
    /// How long one suite may take: the suites read no clock, so a stream that never ends would hang without it.
    static let suiteTimeout: Duration = .seconds(60)

    /// Runs a local suite (`isWired` false) on its fake: the store and connectivity have no service messages.
    static func runLocally(_ suite: ContractSuiteID) async throws {
        switch suite {
        case .store: try await StoreServiceContract().run { Fixtures.store($0) }
        case .connectivity: try await ConnectivityServiceContract().run { Fixtures.connectivity($0) }
        default: Issue.record("\(suite) is wired")
        }
    }

    @Test(.timeLimit(.minutes(2)), arguments: ContractSuiteID.allCases)
    func everySuitePassesAgainstLoopback(suite: ContractSuiteID) async throws {
        try await withTimeout(Self.suiteTimeout, suite.suiteName) {
            if suite.isWired {
                try await ContractRunner.run(suite, over: .loopback)
            } else {
                try await Self.runLocally(suite)
            }
        }
    }

    /// Every #109 / #241 suite is accounted for: eight over the wire, and the store and connectivity local, not wired.
    @Test func everySuiteIsAccountedFor() async throws {
        #expect(ContractSuiteID.allCases.map(\.suiteName) == [
            "IdentityService", "TermsService", "QueueService", "RaceSessionService", "LobbyService", "ProfileService",
            "StoreService", "AnalyticsTransport", "ConnectivityService", "DataDeletionService",
        ])
        #expect(ContractSuiteID.allCases.filter { !$0.isWired } == [.store, .connectivity])
        for suite in ContractSuiteID.allCases where !suite.isWired {
            await #expect(throws: ContractRunnerError.notWired(suite)) { try await ContractRunner.run(suite, over: .loopback) }
        }
    }

    /// `CONTRACT_ENDPOINT` and `CONTRACT_SUITES` are read by the runner (#145); the run against a real server is
    /// RegattaServer's `ServiceEndpointContractTests`, which has the WebSocket connector.
    @Test func theEndpointAndItsSuitesComeFromTheEnvironment() throws {
        #expect(ContractEndpoint.fromEnvironment([:]) == nil)
        #expect(ContractEndpoint.fromEnvironment(["CONTRACT_ENDPOINT": "ws://127.0.0.1:8080"]) == "ws://127.0.0.1:8080")
        #expect(try ContractEndpoint.suites(served: [.identity, .terms], [:]) == [.identity, .terms])
        #expect(try ContractEndpoint.suites(served: [.identity], ["CONTRACT_SUITES": "terms, queue"]) == [.terms, .queue])
        #expect(throws: ContractRunnerError.unknownSuite("store")) { try ContractEndpoint.suites(served: [], ["CONTRACT_SUITES": "store"]) }
    }
}

/// Runs `body`, failing the test if it hasn't finished within `limit`. A body that never finishes is left running.
func withTimeout(_ limit: Duration, _ what: String, _ body: @escaping @Sendable () async throws -> Void) async throws {
    let finished: Bool = try await withCheckedThrowingContinuation { continuation in
        let race = FirstResult(continuation)
        Task {
            do {
                try await body()
                race.settle(.success(true))
            } catch {
                race.settle(.failure(error))
            }
        }
        Task {
            try? await Task.sleep(for: limit)
            race.settle(.success(false))
        }
    }
    if !finished { Issue.record("\(what) didn't finish within \(limit)") }
}

/// Resumes a continuation with the first result it's given, and drops the rest.
private final class FirstResult: Sendable {
    private let continuation: Mutex<CheckedContinuation<Bool, any Error>?>

    init(_ continuation: CheckedContinuation<Bool, any Error>) { self.continuation = Mutex(continuation) }

    func settle(_ result: Result<Bool, any Error>) {
        continuation.withLock { $0.take() }?.resume(with: result)
    }
}
