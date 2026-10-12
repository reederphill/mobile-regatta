import Synchronization

// Where the client keeps its session tokens (#161): one per Game Center player, by `teamPlayerID` (the id the
// server keys the player by). The app's store is the Keychain; nothing but the token's bytes is ever kept.

public protocol SessionTokenStore: Sendable {
    /// The token kept for `teamPlayerID`, or nil.
    func token(for teamPlayerID: String) throws -> [UInt8]?
    func setToken(_ token: [UInt8], for teamPlayerID: String) throws
    /// Forgets `teamPlayerID`'s token. Nothing kept is not an error.
    func removeToken(for teamPlayerID: String) throws
    /// Forgets every token but `teamPlayerID`'s (nil: every token).
    func removeAll(except teamPlayerID: String?) throws
}

/// Tokens in memory: tests, and the package's own fakes.
public final class InMemorySessionTokenStore: SessionTokenStore {
    private let tokens: Mutex<[String: [UInt8]]>

    public init(_ tokens: [String: [UInt8]] = [:]) { self.tokens = Mutex(tokens) }

    /// Everything kept, by `teamPlayerID`.
    public var all: [String: [UInt8]] { tokens.withLock { $0 } }

    public func token(for teamPlayerID: String) -> [UInt8]? { tokens.withLock { $0[teamPlayerID] } }
    public func setToken(_ token: [UInt8], for teamPlayerID: String) { tokens.withLock { $0[teamPlayerID] = token } }
    public func removeToken(for teamPlayerID: String) { tokens.withLock { $0[teamPlayerID] = nil } }

    public func removeAll(except teamPlayerID: String?) {
        tokens.withLock { tokens in tokens = tokens.filter { $0.key == teamPlayerID } }
    }
}
