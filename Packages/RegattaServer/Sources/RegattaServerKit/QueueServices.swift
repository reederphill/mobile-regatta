import Foundation
import RegattaServices

// The queue and the race session as one signed-in player sees them (#146): views onto the `QueueMatchmaker`, made per
// connection by `ServiceBackends`. Rejoin, results, ratings and the last race are views onto the `RaceLifecycle` (#148);
// without one there is no race to rejoin, and the result and rating streams end at once.

/// The global queue for one player.
public struct ServerQueueService: QueueService, ConnectionScoped {
    public let matchmaker: QueueMatchmaker
    public let player: AccountPlayer
    /// Her races (#148): the queue refuses her while she has one to rejoin.
    public let lifecycle: (any RaceLifecycleProviding)?

    public init(matchmaker: QueueMatchmaker, player: AccountPlayer, lifecycle: (any RaceLifecycleProviding)? = nil) {
        self.matchmaker = matchmaker
        self.player = player
        self.lifecycle = lifecycle
    }

    public func stateUpdates() -> AsyncStream<QueueState> { matchmaker.stateUpdates(for: player.teamPlayerID) }

    /// Refused while she has a race to rejoin (#148): `alreadyQueued`, the wire's "locked into a fleet" (no refusal
    /// reason of its own; the queue shows her fleet as locked until the race closes).
    public func join() async throws {
        if let lifecycle, await lifecycle.rejoinable(player.teamPlayerID) { throw QueueError.alreadyQueued }
        try await matchmaker.join(player)
    }
    public func leave() async throws { try await matchmaker.leave(player.teamPlayerID) }

    /// The connection is gone: its place in the queue goes with it (free, as leaving is).
    public func connectionEnded() async { await matchmaker.dropped(player.teamPlayerID) }
}

/// The player's race from fleet lock: the hand-off (the matchmaker's), then rejoin, results, ratings and the last race
/// (the lifecycle's, #148).
public struct ServerRaceSessionService: RaceSessionService {
    public let matchmaker: QueueMatchmaker
    public let player: AccountPlayer
    public let lifecycle: (any RaceLifecycleProviding)?

    public init(matchmaker: QueueMatchmaker, player: AccountPlayer, lifecycle: (any RaceLifecycleProviding)? = nil) {
        self.matchmaker = matchmaker
        self.player = player
        self.lifecycle = lifecycle
    }

    public func handOff() async throws -> HandOff { try await matchmaker.handOff(for: player.teamPlayerID) }

    /// After the gun, until the close, unless she left (#16, #66).
    public func rejoin() async throws -> RejoinOffer {
        guard let lifecycle else { throw RaceSessionError.noRace }
        return try await lifecycle.rejoin(player.teamPlayerID)
    }

    public func results() -> AsyncStream<RaceUpdate> {
        lifecycle?.results(for: player.teamPlayerID) ?? AsyncStream { $0.finish() }
    }

    public func ratingChanges() -> AsyncStream<RatingChange> {
        lifecycle?.ratingChanges(for: player.teamPlayerID) ?? AsyncStream { $0.finish() }
    }

    public func lastRace() async throws -> LastRace? { try await lifecycle?.lastRace(of: player.teamPlayerID) }
}
