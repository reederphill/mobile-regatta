import Foundation
import Persistence
import Ratings
import Synchronization

// Where ratings are read (#151, ADR 0012): Postgres in production (`RatingStore`), memory for a dev server without a
// database and for tests. Ratings are written only by a race's close (`RaceArchive.close`, in the closing transaction)
// and by an admin's reset; everything on a player's path here is a read, and a read never makes a row.

/// The ratings the briefing, the profile and the leaderboard mirror read, and the admin's reset.
public protocol RatingBook: Sendable {
    /// The stored rating of each of `playerIDs` that has one, in one read. A player without one is new: 1500, provisional.
    func ratings(of playerIDs: [String]) async throws -> [String: PlayerRating]
    /// Her rating and counts in one read; nil if she isn't stored.
    func standing(of playerID: String) async throws -> PlayerStanding?
    /// An admin puts her back to a new player's rating (#154 calls this). False if she isn't stored.
    @discardableResult
    func reset(_ playerID: String, reason: String, at time: Date, config: RatingConfig) async throws -> Bool
    /// Established players whose rounded rating the leaderboard doesn't show yet (`LeaderboardMirror`): of
    /// `playerIDs`, or of everyone.
    func mirrorPending(_ playerIDs: [String]?, maxFailures: Int, limit: Int) async throws -> [MirrorEntry]
    func mirrored(_ playerID: String, rating: Int) async throws
    func mirrorFailed(_ playerID: String) async throws
}

extension RatingStore: RatingBook {}

extension RatingBook {
    /// Each player's rating as shown, new players included: the number and the provisional badge.
    public func shown(_ playerIDs: [String], config: RatingConfig = RatingConfig()) async throws -> [String: PlayerRating] {
        let stored = try await ratings(of: playerIDs)
        return Dictionary(playerIDs.map { ($0, stored[$0] ?? PlayerRating(config)) }, uniquingKeysWith: { first, _ in first })
    }
}

/// The ratings in memory: what `InMemoryRaceArchive` writes at each close, with the same pure functions the Postgres
/// close runs (`RatingOutcome.changes`), so a dev server rates as production does. Lost on restart.
public final class InMemoryRatingBook: RatingBook {
    private struct State {
        var ratings: [String: PlayerRating] = [:]
        var stats: [String: (completed: Int, wins: Int)] = [:]
        var history: [UUID: [StoredRatingChange]] = [:]
        var states: [UUID: RatingState] = [:]
        var resets: [(player: String, reason: String, at: Date)] = []
        var mirrored: [String: Int] = [:]
        var mirrorFailures: [String: Int] = [:]
        var gamePlayerIDs: [String: String] = [:]
        /// Players whose account is gone (#160): nothing of theirs is kept, and a close no longer rates them.
        var deleted: Set<String> = []
    }

    private let state = Mutex(State())

    public init() {}

    public func ratings(of playerIDs: [String]) async throws -> [String: PlayerRating] {
        state.withLock { state in
            Dictionary(playerIDs.compactMap { id in state.ratings[id].map { (id, $0) } }, uniquingKeysWith: { first, _ in first })
        }
    }

    public func standing(of playerID: String) async throws -> PlayerStanding? {
        state.withLock { state in
            guard !state.deleted.contains(playerID) else { return nil }
            let stats = state.stats[playerID] ?? (0, 0)
            return PlayerStanding(rating: state.ratings[playerID], completedRaces: stats.completed, wins: stats.wins)
        }
    }

    @discardableResult
    public func reset(_ playerID: String, reason: String, at time: Date, config: RatingConfig = RatingConfig()) async throws -> Bool {
        state.withLock { state in
            guard !state.deleted.contains(playerID) else { return false }
            state.ratings[playerID] = PlayerRating(config)
            state.resets.append((playerID, reason, time))
            return true
        }
    }

    public func mirrorPending(_ playerIDs: [String]?, maxFailures: Int, limit: Int) async throws -> [MirrorEntry] {
        state.withLock { state in
            let ids = playerIDs ?? state.ratings.keys.sorted()
            return Array(ids.compactMap { id -> MirrorEntry? in
                guard let rating = state.ratings[id], rating.established, let game = state.gamePlayerIDs[id],
                      state.mirrored[id] != rating.displayed, state.mirrorFailures[id, default: 0] < maxFailures else { return nil }
                return MirrorEntry(playerID: id, gamePlayerID: game, rating: rating.displayed)
            }.prefix(limit))
        }
    }

    public func mirrored(_ playerID: String, rating: Int) async throws {
        state.withLock {
            $0.mirrored[playerID] = rating
            $0.mirrorFailures[playerID] = nil
        }
    }

    public func mirrorFailed(_ playerID: String) async throws { state.withLock { $0.mirrorFailures[playerID, default: 0] += 1 } }

    // MARK: The archive's side, and tests

    /// The close's rating step, as `RatingStore.score`: the profile counts, then the ratings, all or none. A rating
    /// failure is the outcome (`failed`), never an error: the race still closes.
    func score(_ race: ClosedRaceRecord) -> RatingOutcome {
        state.withLock { state in
            for stat in race.stats where !state.deleted.contains(stat.playerID) {
                state.stats[stat.playerID, default: (0, 0)].completed += stat.completed ? 1 : 0
                state.stats[stat.playerID, default: (0, 0)].wins += stat.won ? 1 : 0
            }
            guard let input = race.rating else { return .none }
            let outcome: RatingOutcome
            do {
                let present = Set(input.participants.map(\.playerID)).subtracting(state.deleted)
                if let changes = try RatingOutcome.changes(input, present: present, stored: state.ratings) {
                    for change in changes {
                        state.ratings[change.playerID] = change.after
                        state.mirrorFailures[change.playerID] = nil
                    }
                    state.history[race.id] = changes
                    outcome = RatingOutcome(state: .applied, changes: changes)
                } else {
                    outcome = RatingOutcome(state: .skipped)
                }
            } catch {
                outcome = RatingOutcome(state: .failed, failure: String(reflecting: error))
            }
            state.states[race.id] = outcome.state
            return outcome
        }
    }

    /// What became of a closed race's ratings, and one player's change from it.
    func rated(_ race: UUID, player: String) -> (state: RatingState, change: StoredRatingChange?) {
        state.withLock { ($0.states[race] ?? .none, $0.history[race]?.first { $0.playerID == player }) }
    }

    /// Every change a race made, by player.
    public func changes(of race: UUID) -> [StoredRatingChange] { state.withLock { $0.history[race] ?? [] } }

    /// Sets a player's rating as if races had made it (a dev arrangement, tests).
    public func set(_ rating: PlayerRating, for playerID: String) { state.withLock { $0.ratings[playerID] = rating } }

    /// Sets a player's counts (a dev arrangement, tests).
    public func setStats(completedRaces: Int, wins: Int, for playerID: String) {
        state.withLock { $0.stats[playerID] = (completedRaces, wins) }
    }

    /// The gamePlayerID the leaderboard knows her by (the account store's, in Postgres).
    public func bind(gamePlayerID: String, to playerID: String) { state.withLock { $0.gamePlayerIDs[playerID] = gamePlayerID } }

    /// Her account is deleted (#160): her rating, counts and history go with it.
    public func delete(_ playerID: String) {
        state.withLock { state in
            state.deleted.insert(playerID)
            state.ratings[playerID] = nil
            state.stats[playerID] = nil
            state.mirrored[playerID] = nil
            for race in state.history.keys { state.history[race]?.removeAll { $0.playerID == playerID } }
        }
    }

    /// Her rating, counts, history and mirror go (#160), and she may come back as a new player.
    public func forget(_ playerID: String) {
        state.withLock { state in
            state.ratings[playerID] = nil
            state.stats[playerID] = nil
            state.mirrored[playerID] = nil
            state.mirrorFailures[playerID] = nil
            state.gamePlayerIDs[playerID] = nil
            for race in state.history.keys { state.history[race]?.removeAll { $0.playerID == playerID } }
        }
    }

    public var resets: [String] { state.withLock { $0.resets.map(\.player) } }
    public func mirroredRating(of playerID: String) -> Int? { state.withLock { $0.mirrored[playerID] } }
    public func mirrorFailures(of playerID: String) -> Int { state.withLock { $0.mirrorFailures[playerID, default: 0] } }
}
