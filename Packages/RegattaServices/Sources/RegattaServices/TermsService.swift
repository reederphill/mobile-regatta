// The Terms of Use (#34): accepted once per Game Center player, recorded on the server with the terms version.
// One acceptance covers the lobby and online racing; practice races never need it.

/// A version of the terms. A material change to them bumps it and asks again (#34).
public struct TermsVersion: Hashable, Comparable, Sendable {
    public let rawValue: Int

    public init(_ rawValue: Int) { self.rawValue = rawValue }

    public static func < (l: TermsVersion, r: TermsVersion) -> Bool { l.rawValue < r.rawValue }
}

public enum TermsStatus: Equatable, Sendable {
    /// The player has accepted this version, which is the current one.
    case accepted(TermsVersion)
    /// The terms sheet is due: the player never accepted (`lastAccepted` nil) or accepted an older version.
    /// The lobby and the queue stay unavailable until they accept `current`.
    case needsAcceptance(current: TermsVersion, lastAccepted: TermsVersion?)

    public var current: TermsVersion {
        switch self {
        case .accepted(let version): version
        case .needsAcceptance(let current, _): current
        }
    }

    public var isAccepted: Bool {
        if case .accepted = self { true } else { false }
    }
}

public enum TermsError: Error, Equatable, Sendable {
    /// The player accepted a version that isn't the current one.
    case staleVersion(current: TermsVersion)
}

public protocol TermsService: Sendable {
    /// Where the signed-in player stands with the current terms.
    func status() async throws -> TermsStatus
    /// Records the player's explicit "I agree" to `version` and returns the status afterwards. Accepting a
    /// version that isn't the current one throws `TermsError.staleVersion`, and records nothing. Accepting
    /// the current version again changes nothing. Declining is not calling this.
    func accept(_ version: TermsVersion) async throws -> TermsStatus
}
