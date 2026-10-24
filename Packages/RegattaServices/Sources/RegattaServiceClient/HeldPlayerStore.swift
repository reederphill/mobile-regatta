import Synchronization

// The players whose online data was deleted on this device (#166, O1): the session opens nothing for a held player,
// across relaunches, until she signs in again herself. The server dropped her session, her terms and her profile; a
// session the app opened on its own would make a fresh profile row with her Game Center id seconds after "deleted".
// The app keeps the hold in its defaults; nothing but the `teamPlayerID` is kept.

public protocol HeldPlayerStore: Sendable {
    func isHeld(_ teamPlayerID: String) -> Bool
    /// Holds `teamPlayerID`: kept before the call returns, so a relaunch straight after still holds her.
    func hold(_ teamPlayerID: String)
    func release(_ teamPlayerID: String)
}

/// Holds in memory: tests, and the package's own fakes. A new session over the same store is a relaunch.
public final class InMemoryHeldPlayerStore: HeldPlayerStore {
    private let held: Mutex<Set<String>>

    public init(_ held: Set<String> = []) { self.held = Mutex(held) }

    public var all: Set<String> { held.withLock { $0 } }

    public func isHeld(_ teamPlayerID: String) -> Bool { held.withLock { $0.contains(teamPlayerID) } }
    public func hold(_ teamPlayerID: String) { _ = held.withLock { $0.insert(teamPlayerID) } }
    public func release(_ teamPlayerID: String) { _ = held.withLock { $0.remove(teamPlayerID) } }
}
