import RegattaServices

/// What `TermsService` promises (#34).
public struct TermsServiceContract: ContractSuite {
    public enum Situation: Hashable, Sendable {
        /// The player never accepted any version.
        case neverAccepted
        /// The player accepted the current version.
        case accepted
        /// The player accepted an older version; the terms have changed since.
        case versionBumped
    }

    public let name = "TermsService"

    public init() {}

    public func run(_ makeService: (Situation) async throws -> any TermsService) async throws {
        // The sheet is due, and accepting the current version dismisses it.
        let fresh = try await makeService(.neverAccepted)
        let status = try await fresh.status()
        guard case .needsAcceptance(let current, let last) = status else { try fail("a player who never accepted isn't asked to") }
        try await require(last == nil, "a player who never accepted has a lastAccepted (\(String(describing: last)))")
        try await acceptFlow(fresh, current: current)

        let bumped = try await makeService(.versionBumped)
        guard case .needsAcceptance(let newer, let older) = try await bumped.status() else {
            try fail("a player who accepted an older version isn't asked again")
        }
        try await require(older != nil && older! < newer, "lastAccepted (\(String(describing: older))) isn't older than the current version")
        try await acceptFlow(bumped, current: newer)

        let accepted = try await makeService(.accepted)
        let acceptedStatus = try await accepted.status()
        try await require(acceptedStatus.isAccepted, "a player who accepted the current version is asked again")
        try await require(try await accepted.accept(acceptedStatus.current) == acceptedStatus, "accepting again changed the status")
    }

    /// Accepting a wrong version fails and records nothing; accepting `current` records it, idempotently.
    private func acceptFlow(_ service: any TermsService, current: TermsVersion) async throws {
        let before = try await service.status()
        let stale = TermsVersion(current.rawValue + 1)
        try await requireThrows(TermsError.staleVersion(current: current), "accept(\(stale.rawValue)), not the current version") {
            try await service.accept(stale)
        }
        try await require(try await service.status() == before, "a refused acceptance changed the status")

        let after = try await service.accept(current)
        try await require(after == .accepted(current), "accept(current) gave \(after), not .accepted(\(current.rawValue))")
        try await require(try await service.status() == after, "status() doesn't show the acceptance")
        try await require(try await service.accept(current) == after, "accepting twice changed the status")
    }
}
