import Foundation
import PostgresNIO
import Ratings

/// A seat a bot sailed for itself in a closed race (#149, `race_bots`): for the shadow ratings (#177).
public struct StoredRaceBot: Sendable, Equatable {
    public enum Source: String, Sendable, Equatable {
        /// A bot's seat from fleet lock.
        case fill
        /// A seat its player gave up before the gun.
        case takeover
    }

    public let seat: Int
    public let source: Source
    /// The rating it was given, and the skill and handling it sailed at.
    public let rating: Int
    public let skill: Double
    public let handling: Double
    /// The version of the rating map (`bot-ratings@n.json`) that gave the skill.
    public let mapVersion: Int
    /// The tick a takeover bot took the seat at; nil for a fill bot.
    public let takenTick: Int?

    public init(seat: Int, source: Source, rating: Int, skill: Double, handling: Double, mapVersion: Int, takenTick: Int? = nil) {
        self.seat = seat
        self.source = source
        self.rating = rating
        self.skill = skill
        self.handling = handling
        self.mapVersion = mapVersion
        self.takenTick = takenTick
    }
}

/// A race as it closed (#148): what the close writes, in one transaction.
public struct ClosedRaceRecord: Sendable, Equatable {
    public let id: UUID
    /// The host's log, verbatim (`RaceLog.jsonData`): what `regatta-replay` replays to `digest` (ADR 0002).
    public let log: Data
    public let digest: UInt64
    public let simulationVersion: String
    public let toolchain: String
    /// The results as canonical bytes (rows, roster, served turns), and the incident index's (`IncidentIndex`'s
    /// Codable form, which doesn't depend on the platform).
    public let results: Data
    public let incidents: Data
    /// At least 2 humans at the gun (#30).
    public let rated: Bool
    /// The seats bots sailed for themselves, by seat (#149).
    public let bots: [StoredRaceBot]
    /// What the close rates (#151): the humans at the gun and their places; nil for an unrated race. Read by the
    /// close only: the stored form is `ratings` and `rating_history`, and a record read back has nil here.
    public let rating: RatingInput?
    /// What the close adds to its players' profile counts (#151). Read by the close only, as `rating`.
    public let stats: [PlayerRaceStat]

    public init(id: UUID, log: Data, digest: UInt64, simulationVersion: String, toolchain: String, results: Data, incidents: Data,
                rated: Bool, bots: [StoredRaceBot] = [], rating: RatingInput? = nil, stats: [PlayerRaceStat] = []) {
        self.bots = bots
        self.rating = rating
        self.stats = stats
        self.id = id
        self.log = log
        self.digest = digest
        self.simulationVersion = simulationVersion
        self.toolchain = toolchain
        self.results = results
        self.incidents = incidents
        self.rated = rated
    }
}

/// A closed race's stored results, as one of its players reads them.
public struct StoredRaceResult: Sendable, Equatable {
    public let raceID: UUID
    /// The player's seat, when read for a player; nil when read by race.
    public let seat: Int?
    public let results: Data
    public let incidents: Data
    public let rated: Bool
    public let endedAt: Date
    /// What became of the race's ratings (#151).
    public var ratingState: RatingState = .none
    /// The player's own rating change from it, when read for a player who was rated in it.
    public var ratingChange: StoredRatingChange?

    public init(raceID: UUID, seat: Int?, results: Data, incidents: Data, rated: Bool, endedAt: Date) {
        self.raceID = raceID
        self.seat = seat
        self.results = results
        self.incidents = incidents
        self.rated = rated
        self.endedAt = endedAt
    }
}

/// Closed races' results (#148, ADR 0009): written once with the close, never for a cancelled race. A player's last
/// race is the newest closed race she sat in, so it stays hers until her next race closes (#24); a race whose seat
/// she gave up before the gun isn't one (#149: a bot sailed it, and its result is the bot's).
public struct RaceResultStore: Sendable {
    let database: Database
    public init(_ database: Database) { self.database = database }

    /// Closes a running race with its log, digest, versions and results, all or nothing.
    @discardableResult
    public func close(_ race: ClosedRaceRecord) async throws -> RaceRecord { try await closing(race).record }

    /// `close`, also saying what became of the ratings (#151). The profile counts and the ratings are written in this
    /// transaction, so a race is closed and rated at once or not at all, and exactly once: a second close finds the
    /// race no longer `running`. The rating step runs in a savepoint: if it fails the race still closes, with
    /// `rating_state = 'failed'` and nobody's rating moved.
    public func closing(_ race: ClosedRaceRecord) async throws -> (record: RaceRecord, rating: RatingOutcome) {
        try await database.transaction { connection in
            let logger = database.logger
            let current = try await RaceRegistryStore.state(race.id, on: connection, logger: logger, lock: true)
            guard current == .running else { throw PersistenceError.raceNotInState(race.id, expected: .running, actual: current) }
            let digest = Int64(bitPattern: race.digest)
            try await connection.query("""
                UPDATE races SET state = 'closed', ended_at = now(), digest = \(digest), sim_version = \(race.simulationVersion),
                    toolchain = \(race.toolchain) WHERE id = \(race.id)
                """, logger: logger)
            let logged = try await connection.query("""
                INSERT INTO race_logs (race_id, log) VALUES (\(race.id), \(race.log)) ON CONFLICT (race_id) DO NOTHING RETURNING race_id
                """, logger: logger)
            guard try await logged.collect().count == 1 else { throw PersistenceError.raceLogExists(race.id) }
            let rating = try await RatingStore.score(race, on: connection, logger: logger)
            try await connection.query("""
                INSERT INTO race_results (race_id, results, incidents, rated, rating_state)
                VALUES (\(race.id), \(race.results), \(race.incidents), \(race.rated), \(rating.state.rawValue))
                """, logger: logger)
            for bot in race.bots {
                try await connection.query("""
                    INSERT INTO race_bots (race_id, seat, source, rating, skill, handling, map_version, taken_tick)
                    VALUES (\(race.id), \(bot.seat), \(bot.source.rawValue), \(bot.rating), \(bot.skill), \(bot.handling), \(bot.mapVersion),
                            \(bot.takenTick))
                    """, logger: logger)
            }
            return (try await RaceRegistryStore.record(race.id, on: connection, logger: logger)!, rating)
        }
    }

    /// The race's results, nil unless it closed.
    public func results(for race: UUID) async throws -> StoredRaceResult? {
        let rows = try await database.client.query("""
            SELECT rr.results, rr.incidents, rr.rated, r.ended_at, rr.rating_state FROM race_results rr JOIN races r ON r.id = rr.race_id
            WHERE rr.race_id = \(race)
            """, logger: database.logger)
        for try await (results, incidents, rated, ended, state) in rows.decode((Data, Data, Bool, Date, String).self) {
            var stored = StoredRaceResult(raceID: race, seat: nil, results: results, incidents: incidents, rated: rated, endedAt: ended)
            stored.ratingState = RatingState(rawValue: state) ?? .none
            return stored
        }
        return nil
    }

    /// The race's bots by seat (#149); none unless it closed.
    public func bots(of race: UUID) async throws -> [StoredRaceBot] {
        let rows = try await database.client.query("""
            SELECT seat, source, rating, skill, handling, map_version, taken_tick FROM race_bots WHERE race_id = \(race) ORDER BY seat
            """, logger: database.logger)
        var bots: [StoredRaceBot] = []
        for try await (seat, source, rating, skill, handling, version, taken) in rows.decode((Int, String, Int, Double, Double, Int, Int?).self) {
            guard let source = StoredRaceBot.Source(rawValue: source) else { continue }
            bots.append(StoredRaceBot(seat: seat, source: source, rating: rating, skill: skill, handling: handling, mapVersion: version,
                                      takenTick: taken))
        }
        return bots
    }

    /// The newest closed race `playerID` sat in, with her seat; nil before her first (#24). A cancelled race isn't one,
    /// nor is one whose seat a bot took from her before the gun (#149).
    public func lastRace(of playerID: String) async throws -> StoredRaceResult? {
        let rows = try await database.client.query("""
            SELECT r.id, p.seat, rr.results, rr.incidents, rr.rated, r.ended_at, rr.rating_state,
                   h.before_rating, h.before_established, h.after_rating, h.after_established, h.place, h.opponents
            FROM race_players p JOIN races r ON r.id = p.race_id JOIN race_results rr ON rr.race_id = r.id
                LEFT JOIN rating_history h ON h.race_id = r.id AND h.player_id = p.player_id AND h.kind = 'race'
            WHERE p.player_id = \(playerID) AND r.state = 'closed'
                AND NOT EXISTS (SELECT 1 FROM race_bots b WHERE b.race_id = p.race_id AND b.seat = p.seat AND b.source = 'takeover')
            ORDER BY r.ended_at DESC, r.created_at DESC, r.id DESC LIMIT 1
            """, logger: database.logger)
        for try await (id, seat, results, incidents, rated, ended, state, before, wasEstablished, after, isEstablished, place, opponents)
            in rows.decode((UUID, Int, Data, Data, Bool, Date, String, Double?, Bool?, Double?, Bool?, Int?, Int?).self) {
            var stored = StoredRaceResult(raceID: id, seat: seat, results: results, incidents: incidents, rated: rated, endedAt: ended)
            stored.ratingState = RatingState(rawValue: state) ?? .none
            if let before, let after {
                // The numbers shown: the rating and the badge. The deviations stay in the history.
                stored.ratingChange = StoredRatingChange(
                    playerID: playerID,
                    before: PlayerRating(glicko: Glicko2(rating: before, deviation: 0, volatility: 0), established: wasEstablished ?? false),
                    after: PlayerRating(glicko: Glicko2(rating: after, deviation: 0, volatility: 0), established: isEstablished ?? false),
                    place: place ?? 0, opponents: opponents ?? 0)
            }
            return stored
        }
        return nil
    }

    /// The race's players by seat.
    public func players(of race: UUID) async throws -> [RaceSeatHolder] {
        let rows = try await database.client.query(
            "SELECT player_id, seat FROM race_players WHERE race_id = \(race) ORDER BY seat", logger: database.logger)
        var players: [RaceSeatHolder] = []
        for try await (player, seat) in rows.decode((String, Int).self) { players.append(RaceSeatHolder(playerID: player, seat: seat)) }
        return players
    }
}
