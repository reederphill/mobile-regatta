import RegattaServiceClient
import RegattaServiceContracts
import RegattaServices

// The remote contract runner (#143) on #109's contract-suite seam: each #109 / #241 suite run through its client
// adapter (`Remote…Service`) over a link a caller supplies, for each situation the suite asks for. Against the
// loopback server the link serves a fake already in that situation; against `CONTRACT_ENDPOINT` a
// `ServiceEndpointConnector` arranges a test account in it. The suites read no clock: the caller times them.

/// Every #109 / #241 contract suite, and whether it runs over the wire.
public enum ContractSuiteID: String, CaseIterable, Sendable {
    case identity
    case terms
    case queue
    case raceSession
    case lobby
    case profile
    case store
    case analytics
    case connectivity
    case deletion

    /// The suite's name, as its `ContractSuite.name` says.
    public var suiteName: String {
        switch self {
        case .identity: IdentityServiceContract().name
        case .terms: TermsServiceContract().name
        case .queue: QueueServiceContract().name
        case .raceSession: RaceSessionServiceContract().name
        case .lobby: LobbyServiceContract().name
        case .profile: ProfileServiceContract().name
        case .store: StoreServiceContract().name
        case .analytics: AnalyticsTransportContract().name
        case .connectivity: ConnectivityServiceContract().name
        case .deletion: DataDeletionServiceContract().name
        }
    }

    /// Local, not wired: the store is the device's App Store (IAP, post-1.0) and connectivity the device's own path
    /// monitor, so neither has service messages. The runner runs their suites on the local implementation.
    public var isWired: Bool { self != .store && self != .connectivity }
}

/// How the runner reaches each wired service in each situation its suite asks for: a link to a service already in it.
public struct ContractLinks: Sendable {
    public typealias Factory<Situation> = @Sendable (Situation) async throws -> any ServiceLink

    public var identity: Factory<IdentityServiceContract.Situation>
    public var terms: Factory<TermsServiceContract.Situation>
    public var queue: Factory<QueueServiceContract.Situation>
    public var raceSession: Factory<RaceSessionServiceContract.Situation>
    public var lobby: Factory<LobbyServiceContract.Situation>
    public var profile: Factory<ProfileServiceContract.Situation>
    public var analytics: Factory<AnalyticsTransportContract.Situation>
    public var deletion: Factory<DataDeletionServiceContract.Situation>

    public init(
        identity: @escaping Factory<IdentityServiceContract.Situation>, terms: @escaping Factory<TermsServiceContract.Situation>,
        queue: @escaping Factory<QueueServiceContract.Situation>, raceSession: @escaping Factory<RaceSessionServiceContract.Situation>,
        lobby: @escaping Factory<LobbyServiceContract.Situation>, profile: @escaping Factory<ProfileServiceContract.Situation>,
        analytics: @escaping Factory<AnalyticsTransportContract.Situation>, deletion: @escaping Factory<DataDeletionServiceContract.Situation>
    ) {
        self.identity = identity
        self.terms = terms
        self.queue = queue
        self.raceSession = raceSession
        self.lobby = lobby
        self.profile = profile
        self.analytics = analytics
        self.deletion = deletion
    }

    /// Links to `endpoint` through `connector`, which arranges each situation by the suite's name and the
    /// situation case's name (`"IdentityService"`, `"signedOut"`).
    public static func endpoint(_ endpoint: String, connector: any ServiceEndpointConnector) -> ContractLinks {
        func factory<Situation>(_ suite: ContractSuiteID) -> Factory<Situation> {
            { situation in try await connector.connect(to: endpoint, service: suite.suiteName, situation: "\(situation)") }
        }
        return ContractLinks(identity: factory(.identity), terms: factory(.terms), queue: factory(.queue), raceSession: factory(.raceSession),
                             lobby: factory(.lobby), profile: factory(.profile), analytics: factory(.analytics), deletion: factory(.deletion))
    }
}

public enum ContractRunner {
    /// Runs the wired suite `suite` through its adapter, a fresh connection for each situation from `links`. Throws
    /// `ContractViolation` on the first check that fails, and `ContractRunnerError.notWired` for a local suite.
    public static func run(_ suite: ContractSuiteID, over links: ContractLinks) async throws {
        switch suite {
        case .identity: try await IdentityServiceContract().run { RemoteIdentityService(ServiceConnection(try await links.identity($0))) }
        case .terms: try await TermsServiceContract().run { RemoteTermsService(ServiceConnection(try await links.terms($0))) }
        case .queue: try await QueueServiceContract().run { RemoteQueueService(ServiceConnection(try await links.queue($0))) }
        case .raceSession:
            try await RaceSessionServiceContract().run { RemoteRaceSessionService(ServiceConnection(try await links.raceSession($0))) }
        case .lobby: try await LobbyServiceContract().run { RemoteLobbyService(ServiceConnection(try await links.lobby($0))) }
        case .profile: try await ProfileServiceContract().run { RemoteProfileService(ServiceConnection(try await links.profile($0))) }
        case .analytics:
            try await AnalyticsTransportContract().run { RemoteAnalyticsTransport(ServiceConnection(try await links.analytics($0))) }
        case .deletion:
            try await DataDeletionServiceContract().run { RemoteDataDeletionService(ServiceConnection(try await links.deletion($0))) }
        case .store, .connectivity: throw ContractRunnerError.notWired(suite)
        }
    }
}

/// Where the runner finds a real server: `CONTRACT_ENDPOINT` (`ws://host:port`), and which suites to run against it,
/// `CONTRACT_SUITES` (comma-separated `ContractSuiteID` names; by default the ones the caller says the server serves).
/// The caller passes its environment in (this package does no I/O); the test that runs it reads `ProcessInfo`.
public enum ContractEndpoint {
    public static let endpointVariable = "CONTRACT_ENDPOINT"
    public static let suitesVariable = "CONTRACT_SUITES"

    /// The endpoint, or nil when it isn't set.
    public static func fromEnvironment(_ environment: [String: String]) -> String? {
        guard let endpoint = environment[endpointVariable], !endpoint.isEmpty else { return nil }
        return endpoint
    }

    /// The suites `CONTRACT_SUITES` names, or `served` when it's unset. Throws on a name that isn't a wired suite.
    public static func suites(served: [ContractSuiteID], _ environment: [String: String]) throws -> [ContractSuiteID] {
        guard let names = environment[suitesVariable], !names.isEmpty else { return served }
        return try names.split(separator: ",").map { name in
            let trimmed = String(name.drop(while: \.isWhitespace).reversed().drop(while: \.isWhitespace).reversed())
            guard let suite = ContractSuiteID(rawValue: trimmed), suite.isWired else { throw ContractRunnerError.unknownSuite(trimmed) }
            return suite
        }
    }
}

public enum ContractRunnerError: Error, Equatable, Sendable {
    /// A local suite (`ContractSuiteID.isWired` false) has no adapter to run over a link.
    case notWired(ContractSuiteID)
    /// `CONTRACT_SUITES` names something that isn't a wired suite.
    case unknownSuite(String)
}
