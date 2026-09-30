import RegattaServices

/// What `ConnectivityService` promises (#25).
public struct ConnectivityServiceContract: ContractSuite {
    public enum Situation: Hashable, Sendable {
        case online
        case offline
        /// Online, then the network drops, then comes back.
        case dropsAndRecovers
    }

    public let name = "ConnectivityService"

    public init() {}

    public func run(_ makeService: (Situation) async throws -> any ConnectivityService) async throws {
        for (situation, expected) in [(Situation.online, ConnectivityStatus.online), (.offline, .offline)] {
            let service = try await makeService(situation)
            let status = await service.status()
            try await require(status == expected, "\(situation) reads \(status)")
            try await require(await StreamReader.first(of: service.statusUpdates()) == expected, "the stream doesn't open with the status now")
        }

        let service = try await makeService(.dropsAndRecovers)
        var reader = StreamReader(service.statusUpdates())
        try await require(await reader.next() == .online, "a network about to drop doesn't start online")
        let (dropped, wentOffline) = await reader.read { $0 == .offline }
        try await require(wentOffline && dropped == [.offline], "the drop read \(dropped), not straight to .offline")
        try await require(await service.status() == .offline, "status() doesn't show the drop")
        let (recovered, cameBack) = await reader.read { $0 == .online }
        try await require(cameBack && recovered == [.online], "the recovery read \(recovered), not straight to .online")
    }
}
