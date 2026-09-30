// The one global queue for online races (#16): join and leave, the countdown to fleet lock, how many are queued.

/// Why the player can't be in the queue now. The queue bar shows it (#16, #26, #34).
public enum QueueRefusal: Hashable, Sendable {
    /// Game Center has no player (`IdentityService`).
    case notSignedIn
    /// The current terms aren't accepted (`TermsService`).
    case termsNotAccepted
    /// Game Center's `isMultiplayerGamingRestricted`: practice races only (#34).
    case multiplayerRestricted
    /// Leaving at the briefing 3 times within an hour costs a 5-minute cooldown, shown as a countdown (#26).
    case cooldown(secondsRemaining: Int)
    /// An online racing suspension (#26): `until` is when it ends as seconds since the epoch, nil for a permanent ban.
    case suspended(until: Int64?)
    /// App Attest failed: a failed attestation can't join the queue (#26).
    case attestationFailed
    /// The version handshake rejected this build.
    case updateRequired
}

/// A queued player's view of the wait.
public struct QueuedStatus: Equatable, Sendable {
    /// Players in the queue, the player included.
    public var queuedPlayers: Int
    /// Seconds until fleet lock, as the server last timed it. A running race closing soon can move it (#16, G2).
    public var secondsToLock: Int

    public init(queuedPlayers: Int, secondsToLock: Int) {
        self.queuedPlayers = queuedPlayers
        self.secondsToLock = secondsToLock
    }

    /// Fleet lock is this close, in seconds: the #25 banner and haptic come about 10 s before it.
    public static let lockImminentSeconds = 10

    /// The fleet is about to lock: time for the lock banner and haptic (#25).
    public var isLockImminent: Bool { secondsToLock <= Self.lockImminentSeconds }
}

public enum QueueState: Equatable, Sendable {
    /// Not in the queue, and free to join.
    case idle
    /// Not in the queue, and can't join.
    case unavailable(QueueRefusal)
    /// Waiting for fleet lock.
    case queued(QueuedStatus)
    /// The race's boats are fixed and the briefing begins. `RaceSessionService` hands the player off to the race (#16).
    case fleetLocked
}

public enum QueueError: Error, Equatable, Sendable {
    /// `join` while the queue is unavailable to the player.
    case refused(QueueRefusal)
    /// `join` while already queued, or locked into a fleet.
    case alreadyQueued
    /// `leave` while not queued. Leaving is free until fleet lock; after it, leaving means dropping the race
    /// transport, and the server derives the #26 cooldown from that.
    case notQueued
}

public protocol QueueService: Sendable {
    /// The queue as the player sees it: the state now, then each change, for as long as the stream is held.
    /// Cooldown and suspension arrive here, as `.unavailable`, before the player tries to join.
    func stateUpdates() -> AsyncStream<QueueState>
    /// Joins the queue. Throws `QueueError.refused` with the reason when the state is `.unavailable`.
    func join() async throws
    /// Leaves the queue. Free.
    func leave() async throws
}
