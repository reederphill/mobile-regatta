import Foundation
import RegattaServices

// The queue and the race session as one signed-in player sees them (#146): views onto the `QueueMatchmaker`, made per
// connection by `ServiceBackends`. Rejoin, results, ratings and the last race are #148's: until then there is no race
// to rejoin, and the result and rating streams end at once.

/// The global queue for one player.
public struct ServerQueueService: QueueService, ConnectionScoped {
    public let matchmaker: QueueMatchmaker
    public let player: AccountPlayer

    public init(matchmaker: QueueMatchmaker, player: AccountPlayer) {
        self.matchmaker = matchmaker
        self.player = player
    }

    public func stateUpdates() -> AsyncStream<QueueState> { matchmaker.stateUpdates(for: player.teamPlayerID) }
    public func join() async throws { try await matchmaker.join(player) }
    public func leave() async throws { try await matchmaker.leave(player.teamPlayerID) }

    /// The connection is gone: its place in the queue goes with it (free, as leaving is).
    public func connectionEnded() async { await matchmaker.dropped(player.teamPlayerID) }
}

/// The player's race from fleet lock: the hand-off. The rest is #148's.
public struct ServerRaceSessionService: RaceSessionService {
    public let matchmaker: QueueMatchmaker
    public let player: AccountPlayer

    public init(matchmaker: QueueMatchmaker, player: AccountPlayer) {
        self.matchmaker = matchmaker
        self.player = player
    }

    public func handOff() async throws -> HandOff { try await matchmaker.handOff(for: player.teamPlayerID) }

    /// TODO(#148): rejoining a race in progress.
    public func rejoin() async throws -> RejoinOffer { throw RaceSessionError.noRace }

    /// TODO(#148): live results.
    public func results() -> AsyncStream<RaceUpdate> { AsyncStream { $0.finish() } }

    /// TODO(#148): rating changes.
    public func ratingChanges() -> AsyncStream<RatingChange> { AsyncStream { $0.finish() } }

    /// TODO(#148): the last race.
    public func lastRace() async throws -> LastRace? { nil }
}
