/// What a `ScriptedTermsService` plays.
public struct TermsScenario: Sendable {
    /// The version of the terms in force.
    public var current: TermsVersion
    /// The version the player has accepted, if any.
    public var accepted: TermsVersion?
    /// Whether `accept` records anything: false plays a server that can't be reached for it, and every accept throws.
    public var saves: Bool

    public init(current: TermsVersion, accepted: TermsVersion? = nil, saves: Bool = true) {
        self.current = current
        self.accepted = accepted
        self.saves = saves
    }
}

/// What a `ScriptedTermsService` throws when its scenario doesn't save: a real one throws its transport's error.
public enum ScriptedTermsError: Error, Equatable, Sendable {
    case notSaved
}

/// A `TermsService` that keeps the acceptance in memory.
public actor ScriptedTermsService: TermsService {
    private let current: TermsVersion
    private var accepted: TermsVersion?
    private let saves: Bool

    public init(_ scenario: TermsScenario) {
        current = scenario.current
        accepted = scenario.accepted
        saves = scenario.saves
    }

    public func status() -> TermsStatus {
        if let accepted, accepted == current { .accepted(current) } else { .needsAcceptance(current: current, lastAccepted: accepted) }
    }

    public func accept(_ version: TermsVersion) throws -> TermsStatus {
        guard version == current else { throw TermsError.staleVersion(current: current) }
        guard saves else { throw ScriptedTermsError.notSaved }
        accepted = version
        return status()
    }
}
