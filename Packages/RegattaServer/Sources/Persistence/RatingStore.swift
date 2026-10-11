import Foundation
import PostgresNIO
import Ratings

/// What became of a closed race's ratings (`race_results.rating_state`, #151).
public enum RatingState: String, Sendable, Equatable {
    /// An unrated race: fewer than 2 humans at the gun.
    case none
    case applied
    /// A rated race with fewer than 2 participants left to rate (accounts deleted meanwhile, #160).
    case skipped
    /// The rating step failed; the race closed without it. Nobody's rating moved.
    case failed
}

/// A rated race's participants (#151): the humans at the gun, each with her stored place. Bots are never among them.
public struct RatingInput: Sendable, Equatable {
    public struct Participant: Sendable, Equatable {
        public var playerID: String
        /// `SeatResult.place`: equal places are a draw.
        public var place: Int

        public init(playerID: String, place: Int) {
            self.playerID = playerID
            self.place = place
        }
    }

    public var participants: [Participant]
    /// When the race closed, on the server's clock (the lifecycle's, never the database's): time away is counted to here.
    public var ratedAt: Date
    public var config: RatingConfig

    public init(participants: [Participant], ratedAt: Date, config: RatingConfig = RatingConfig()) {
        self.participants = participants
        self.ratedAt = ratedAt
        self.config = config
    }
}

/// What a closed race adds to a player's profile counts (#25): one per human seat that was still its player's.
public struct PlayerRaceStat: Sendable, Equatable {
    public var playerID: String
    /// Her result counts as a completed race (G6: finished, by distance, DSQ or OCS).
    public var completed: Bool
    /// First, and finished.
    public var won: Bool

    public init(playerID: String, completed: Bool, won: Bool) {
        self.playerID = playerID
        self.completed = completed
        self.won = won
    }
}

/// One player's rating change from one race, as stored in `rating_history`.
public struct StoredRatingChange: Sendable, Equatable {
    public var playerID: String
    public var before: PlayerRating
    public var after: PlayerRating
    public var place: Int
    public var opponents: Int

    public init(playerID: String, before: PlayerRating, after: PlayerRating, place: Int, opponents: Int) {
        self.playerID = playerID
        self.before = before
        self.after = after
        self.place = place
        self.opponents = opponents
    }
}

/// What the close did about ratings.
public struct RatingOutcome: Sendable, Equatable {
    public var state: RatingState
    /// One per participant when `applied`; none otherwise.
    public var changes: [StoredRatingChange]
    /// Why, when `failed`.
    public var failure: String?

    public init(state: RatingState, changes: [StoredRatingChange] = [], failure: String? = nil) {
        self.state = state
        self.changes = changes
        self.failure = failure
    }

    public static let none = RatingOutcome(state: .none)

    /// The pure step both archives run: the participants (those of `input` still `present`) with the ratings `stored`
    /// has for them, rated at `input.ratedAt`. Nil with fewer than 2 left: skipped.
    public static func changes(_ input: RatingInput, present: Set<String>, stored: [String: PlayerRating]) throws -> [StoredRatingChange]? {
        let participants = input.participants.filter { present.contains($0.playerID) }.map {
            FleetRating.Participant(id: $0.playerID, place: $0.place, rating: stored[$0.playerID] ?? PlayerRating(input.config))
        }
        guard participants.count >= 2 else { return nil }
        return try FleetRating.rate(participants, at: input.ratedAt, config: input.config).map {
            StoredRatingChange(playerID: $0.id, before: $0.before, after: $0.after, place: $0.place, opponents: $0.opponents)
        }
    }
}

/// A player's rating and counts for her profile (#25), in one read.
public struct PlayerStanding: Sendable, Equatable {
    /// Nil where the store keeps no names (the in-memory one).
    public var displayName: String?
    /// Nil before her first rated race: a new player.
    public var rating: PlayerRating?
    public var completedRaces: Int
    public var wins: Int

    public init(displayName: String? = nil, rating: PlayerRating? = nil, completedRaces: Int = 0, wins: Int = 0) {
        self.displayName = displayName
        self.rating = rating
        self.completedRaces = completedRaces
        self.wins = wins
    }
}

/// An established player's rounded rating the Game Center leaderboard doesn't show yet (`LeaderboardMirror`).
public struct MirrorEntry: Sendable, Equatable {
    public var playerID: String
    public var gamePlayerID: String
    public var rating: Int

    public init(playerID: String, gamePlayerID: String, rating: Int) {
        self.playerID = playerID
        self.gamePlayerID = gamePlayerID
        self.rating = rating
    }
}

/// Ratings in Postgres (#151, ADR 0012; migration 0010). Written by the race close (`RaceResultStore.close`, in its
/// transaction) and by `reset`; everything else here reads, and a read never makes a row.
public struct RatingStore: Sendable {
    let database: Database
    public init(_ database: Database) { self.database = database }

    /// The stored rating of each of `playerIDs` that has one, in one query. A player without a row is new.
    public func ratings(of playerIDs: [String]) async throws -> [String: PlayerRating] {
        guard !playerIDs.isEmpty else { return [:] }
        let rows = try await database.client.query(Self.select(playerIDs), logger: database.logger)
        return try await Self.decode(rows)
    }

    static func select(_ playerIDs: [String]) -> PostgresQuery {
        """
        SELECT player_id, rating, deviation, volatility, rated_races, established, last_rated_at
        FROM ratings WHERE player_id = ANY(\(playerIDs))
        """
    }

    static func decode(_ rows: PostgresRowSequence) async throws -> [String: PlayerRating] {
        var read: [String: PlayerRating] = [:]
        for try await (id, rating, deviation, volatility, races, established, last)
            in rows.decode((String, Double, Double, Double, Int, Bool, Date?).self) {
            read[id] = PlayerRating(glicko: Glicko2(rating: rating, deviation: deviation, volatility: volatility), ratedRaces: races,
                                    established: established, lastRatedAt: last)
        }
        return read
    }

    /// The player's name, rating and counts, in one query; nil if she isn't stored.
    public func standing(of playerID: String) async throws -> PlayerStanding? {
        let rows = try await database.client.query("""
            SELECT p.display_name, r.rating, r.deviation, r.volatility, r.rated_races, r.established, r.last_rated_at,
                   COALESCE(s.completed_races, 0), COALESCE(s.wins, 0)
            FROM players p LEFT JOIN ratings r ON r.player_id = p.team_player_id LEFT JOIN player_stats s ON s.player_id = p.team_player_id
            WHERE p.team_player_id = \(playerID)
            """, logger: database.logger)
        for try await (name, rating, deviation, volatility, races, established, last, completed, wins)
            in rows.decode((String, Double?, Double?, Double?, Int?, Bool?, Date?, Int, Int).self) {
            var stored: PlayerRating?
            if let rating, let deviation, let volatility {
                stored = PlayerRating(glicko: Glicko2(rating: rating, deviation: deviation, volatility: volatility), ratedRaces: races ?? 0,
                                      established: established ?? false, lastRatedAt: last)
            }
            return PlayerStanding(displayName: name, rating: stored, completedRaces: completed, wins: wins)
        }
        return nil
    }

    /// An admin puts the player back to a new player's rating (#154 calls this; no route here): 1500 / 350 / 0.06,
    /// provisional, with a `reset` row in her history saying why. Her counts and what the leaderboard shows are
    /// untouched (taking a posted score down is #160's call). False if she isn't stored.
    @discardableResult
    public func reset(_ playerID: String, reason: String, at time: Date, config: RatingConfig = RatingConfig()) async throws -> Bool {
        try await database.transaction { connection in
            let logger = database.logger
            let locked = try await connection.query(
                "SELECT team_player_id FROM players WHERE team_player_id = \(playerID) FOR NO KEY UPDATE", logger: logger)
            guard try await locked.collect().count == 1 else { return false }
            let before = try await Self.decode(connection.query(Self.select([playerID]), logger: logger))[playerID] ?? PlayerRating(config)
            let fresh = Glicko2(config)
            try await connection.query("""
                INSERT INTO ratings (player_id, rating, deviation, volatility, rated_races, established, last_rated_at)
                VALUES (\(playerID), \(fresh.rating), \(fresh.deviation), \(fresh.volatility), 0, false, NULL)
                ON CONFLICT (player_id) DO UPDATE SET rating = EXCLUDED.rating, deviation = EXCLUDED.deviation,
                    volatility = EXCLUDED.volatility, rated_races = 0, established = false, last_rated_at = NULL, updated_at = now()
                """, logger: logger)
            try await connection.query("""
                INSERT INTO rating_history (player_id, race_id, kind, at, before_rating, before_deviation, before_volatility,
                    before_established, after_rating, after_deviation, after_volatility, after_established, note)
                VALUES (\(playerID), NULL, 'reset', \(time), \(before.glicko.rating), \(before.glicko.deviation), \(before.glicko.volatility),
                    \(before.established), \(fresh.rating), \(fresh.deviation), \(fresh.volatility), false, \(reason))
                """, logger: logger)
            return true
        }
    }

    /// The rating changes a race made, by player (`rating_history`).
    public func changes(of race: UUID) async throws -> [StoredRatingChange] {
        let rows = try await database.client.query("""
            SELECT player_id, before_rating, before_deviation, before_volatility, before_established,
                   after_rating, after_deviation, after_volatility, after_established, COALESCE(place, 0), COALESCE(opponents, 0), at
            FROM rating_history WHERE race_id = \(race) AND kind = 'race' ORDER BY player_id
            """, logger: database.logger)
        var changes: [StoredRatingChange] = []
        for try await (id, br, bd, bv, be, ar, ad, av, ae, place, opponents, at)
            in rows.decode((String, Double, Double, Double, Bool, Double, Double, Double, Bool, Int, Int, Date).self) {
            changes.append(StoredRatingChange(
                playerID: id, before: PlayerRating(glicko: Glicko2(rating: br, deviation: bd, volatility: bv), established: be),
                after: PlayerRating(glicko: Glicko2(rating: ar, deviation: ad, volatility: av), established: ae, lastRatedAt: at),
                place: place, opponents: opponents))
        }
        return changes
    }

    // MARK: The leaderboard mirror

    /// Established players whose rounded rating isn't the one last sent, and hasn't failed `maxFailures` times since it
    /// last changed: of `playerIDs`, or (nil) of everyone, longest waiting first. Provisional players are never here.
    /// Rounded half up, as `PlayerRating.displayed` (Postgres' own `round` goes half to even).
    public func mirrorPending(_ playerIDs: [String]? = nil, maxFailures: Int, limit: Int) async throws -> [MirrorEntry] {
        let all = playerIDs == nil
        let rows = try await database.client.query("""
            SELECT r.player_id, p.game_player_id, floor(r.rating + 0.5)::integer
            FROM ratings r JOIN players p ON p.team_player_id = r.player_id
            WHERE r.established AND p.game_player_id IS NOT NULL AND r.mirror_failures < \(maxFailures)
                AND r.mirrored_rating IS DISTINCT FROM floor(r.rating + 0.5)::integer
                AND (\(all) OR r.player_id = ANY(\(playerIDs ?? [])))
            ORDER BY r.updated_at, r.player_id LIMIT \(limit)
            """, logger: database.logger)
        var entries: [MirrorEntry] = []
        for try await (id, game, rating) in rows.decode((String, String, Int).self) {
            entries.append(MirrorEntry(playerID: id, gamePlayerID: game, rating: rating))
        }
        return entries
    }

    /// The leaderboard took `rating` for the player.
    public func mirrored(_ playerID: String, rating: Int) async throws {
        try await database.client.query(
            "UPDATE ratings SET mirrored_rating = \(rating), mirror_failures = 0 WHERE player_id = \(playerID)", logger: database.logger)
    }

    /// A submission for the player failed.
    public func mirrorFailed(_ playerID: String) async throws {
        try await database.client.query(
            "UPDATE ratings SET mirror_failures = mirror_failures + 1 WHERE player_id = \(playerID)", logger: database.logger)
    }

    // MARK: The close's part (`RaceResultStore.close`)

    /// Inside the closing transaction: locks the race's players (ascending, so two closes sharing players never
    /// deadlock, and a second close of the same player waits for the first), adds the profile counts, and rates the
    /// race in a savepoint. A rating failure rolls back to the savepoint and is the outcome, not an error: the close
    /// goes on. Only a failure of the connection itself throws.
    static func score(_ race: ClosedRaceRecord, on connection: PostgresConnection, logger: Logger) async throws -> RatingOutcome {
        let ids = Array(Set(race.stats.map(\.playerID) + (race.rating?.participants.map(\.playerID) ?? []))).sorted()
        guard !ids.isEmpty else { return race.rating == nil ? .none : RatingOutcome(state: .skipped) }
        var present: Set<String> = []
        let locked = try await connection.query(
            "SELECT team_player_id FROM players WHERE team_player_id = ANY(\(ids)) ORDER BY team_player_id FOR NO KEY UPDATE", logger: logger)
        for try await id in locked.decode(String.self) { present.insert(id) }

        let stats = race.stats.filter { present.contains($0.playerID) }.sorted { $0.playerID < $1.playerID }
        if !stats.isEmpty {
            try await connection.query("""
                INSERT INTO player_stats (player_id, completed_races, wins)
                SELECT u.id, u.completed, u.wins
                FROM unnest(\(stats.map(\.playerID)), \(stats.map { $0.completed ? 1 : 0 }), \(stats.map { $0.won ? 1 : 0 })) AS u(id, completed, wins)
                ORDER BY u.id
                ON CONFLICT (player_id) DO UPDATE SET completed_races = player_stats.completed_races + EXCLUDED.completed_races,
                    wins = player_stats.wins + EXCLUDED.wins, updated_at = now()
                """, logger: logger)
        }

        guard let input = race.rating else { return .none }
        try await connection.query("SAVEPOINT rating", logger: logger)
        do {
            let stored = try await decode(connection.query(select(ids), logger: logger))
            guard let changes = try RatingOutcome.changes(input, present: present, stored: stored) else {
                try await connection.query("RELEASE SAVEPOINT rating", logger: logger)
                return RatingOutcome(state: .skipped)
            }
            let after = changes.map(\.after), before = changes.map(\.before), players = changes.map(\.playerID)
            try await connection.query("""
                INSERT INTO ratings (player_id, rating, deviation, volatility, rated_races, established, last_rated_at, updated_at)
                SELECT u.id, u.rating, u.deviation, u.volatility, u.races, u.established, \(input.ratedAt), now()
                FROM unnest(\(players), \(after.map(\.glicko.rating)), \(after.map(\.glicko.deviation)), \(after.map(\.glicko.volatility)),
                            \(after.map(\.ratedRaces)), \(after.map(\.established))) AS u(id, rating, deviation, volatility, races, established)
                ON CONFLICT (player_id) DO UPDATE SET rating = EXCLUDED.rating, deviation = EXCLUDED.deviation,
                    volatility = EXCLUDED.volatility, rated_races = EXCLUDED.rated_races, established = EXCLUDED.established,
                    last_rated_at = EXCLUDED.last_rated_at, mirror_failures = 0, updated_at = now()
                """, logger: logger)
            try await connection.query("""
                INSERT INTO rating_history (player_id, race_id, kind, at, before_rating, before_deviation, before_volatility,
                    before_established, after_rating, after_deviation, after_volatility, after_established, place, opponents)
                SELECT u.id, \(race.id), 'race', \(input.ratedAt), u.br, u.bd, u.bv, u.be, u.ar, u.ad, u.av, u.ae, u.place, u.opponents
                FROM unnest(\(players), \(before.map(\.glicko.rating)), \(before.map(\.glicko.deviation)), \(before.map(\.glicko.volatility)),
                            \(before.map(\.established)), \(after.map(\.glicko.rating)), \(after.map(\.glicko.deviation)),
                            \(after.map(\.glicko.volatility)), \(after.map(\.established)), \(changes.map(\.place)), \(changes.map(\.opponents)))
                    AS u(id, br, bd, bv, be, ar, ad, av, ae, place, opponents)
                """, logger: logger)
            try await connection.query("RELEASE SAVEPOINT rating", logger: logger)
            return RatingOutcome(state: .applied, changes: changes)
        } catch {
            // The transaction is unusable until it is back at the savepoint; if that fails too, so does the close.
            try await connection.query("ROLLBACK TO SAVEPOINT rating", logger: logger)
            return RatingOutcome(state: .failed, failure: String(reflecting: error))
        }
    }
}
