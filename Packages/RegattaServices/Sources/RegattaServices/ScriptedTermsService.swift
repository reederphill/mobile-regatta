/// What a `ScriptedTermsService` plays.
public struct TermsScenario: Sendable {
    /// The version of the terms in force.
    public var current: TermsVersion
    /// The version the player has accepted, if any.
    public var accepted: TermsVersion?

    public init(current: TermsVersion, accepted: TermsVersion? = nil) {
        self.current = current
        self.accepted = accepted
    }
}

/// A `TermsService` that keeps the acceptance in memory.
public actor ScriptedTermsService: TermsService {
    private let current: TermsVersion
    private var accepted: TermsVersion?

    public init(_ scenario: TermsScenario) {
        current = scenario.current
        accepted = scenario.accepted
    }

    public func status() -> TermsStatus {
        if let accepted, accepted == current { .accepted(current) } else { .needsAcceptance(current: current, lastAccepted: accepted) }
    }

    public func accept(_ version: TermsVersion) throws -> TermsStatus {
        guard version == current else { throw TermsError.staleVersion(current: current) }
        accepted = version
        return status()
    }
}
