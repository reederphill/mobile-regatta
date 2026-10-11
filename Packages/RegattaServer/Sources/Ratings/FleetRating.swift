import Foundation

// One race as Glicko-2 games (#151, ADR 0012). The participants are the humans at the gun; each plays every other
// once, won, drawn or lost by their places, every game weighing 1/√(opponents). One race is one update for everyone at
// once: each sees the others as they stood before the race.

/// A player's rating as kept: Glicko's three numbers, how many rated races made it, whether she is established and
/// when she was last rated.
public struct PlayerRating: Sendable, Equatable {
    public var glicko: Glicko2
    public var ratedRaces: Int
    /// Not provisional. Set the first time a rated race leaves the deviation at or under
    /// `RatingConfig.establishedDeviation`, and kept: time away grows the deviation again but never brings the
    /// provisional badge back (owner 2026-10-10).
    public var established: Bool
    /// Nil before her first rated race.
    public var lastRatedAt: Date?

    public init(glicko: Glicko2, ratedRaces: Int = 0, established: Bool = false, lastRatedAt: Date? = nil) {
        self.glicko = glicko
        self.ratedRaces = ratedRaces
        self.established = established
        self.lastRatedAt = lastRatedAt
    }

    /// A player nobody has rated yet: 1500, provisional.
    public init(_ config: RatingConfig = RatingConfig()) { self.init(glicko: Glicko2(config)) }

    /// The number shown: the rating rounded to a whole number. A change's delta is the difference of two of these.
    public var displayed: Int { Int(glicko.rating.rounded()) }
    public var isProvisional: Bool { !established }

    /// Rating periods from her last rated race to `time` (`RatingConfig.period`): 1 for her first race, never
    /// negative (a clock that stepped back), at most `maxPeriods`.
    public func periods(to time: Date, config: RatingConfig) -> Double {
        guard let lastRatedAt else { return 1 }
        return min(max(time.timeIntervalSince(lastRatedAt) / config.period, 0), config.maxPeriods)
    }
}

public enum FleetRating {
    public struct Participant<ID: Hashable & Sendable>: Sendable {
        public var id: ID
        /// The stored `SeatResult.place`: lower is better, equal is a draw (DSQs, OCSs and, at a normal close, RETs
        /// share one).
        public var place: Int
        public var rating: PlayerRating

        public init(id: ID, place: Int, rating: PlayerRating) {
            self.id = id
            self.place = place
            self.rating = rating
        }
    }

    public struct Change<ID: Hashable & Sendable>: Sendable {
        public var id: ID
        public var place: Int
        public var opponents: Int
        public var before: PlayerRating
        public var after: PlayerRating
    }

    /// What each game of a race with `opponents` opponents weighs: a duel is 1.
    public static func weight(opponents: Int, config: RatingConfig = RatingConfig()) -> Double {
        pow(Double(max(1, opponents)), -config.weightExponent)
    }

    /// 1 if `place` beats `other`, 0.5 if they are equal, 0 if it is worse.
    public static func score(_ place: Int, against other: Int) -> Double { place < other ? 1 : (place == other ? 0.5 : 0) }

    /// The games `participants[index]` played: one against each other participant as she stood before the race,
    /// her deviation grown to `time`.
    public static func games<ID>(of index: Int, in participants: [Participant<ID>], at time: Date,
                                 config: RatingConfig = RatingConfig()) -> [Glicko2.Game] {
        let weight = weight(opponents: participants.count - 1, config: config)
        return participants.indices.filter { $0 != index }.map { other in
            let opponent = participants[other].rating
            return Glicko2.Game(opponentRating: opponent.glicko.rating,
                                opponentDeviation: opponent.glicko.deviation(after: opponent.periods(to: time, config: config), config: config),
                                score: score(participants[index].place, against: participants[other].place), weight: weight)
        }
    }

    /// Everyone's rating after the race closed at `time`, in the order given. Throws, changing nobody, with fewer than
    /// 2 participants, one named twice, or a number that isn't finite.
    public static func rate<ID>(_ participants: [Participant<ID>], at time: Date,
                                config: RatingConfig = RatingConfig()) throws(RatingError) -> [Change<ID>] {
        guard participants.count >= 2, Set(participants.map(\.id)).count == participants.count else { throw .badFleet }
        var changes: [Change<ID>] = []
        for (index, participant) in participants.enumerated() {
            let before = participant.rating
            let glicko = try before.glicko.updated(games(of: index, in: participants, at: time, config: config),
                                                   periods: before.periods(to: time, config: config), config: config)
            let after = PlayerRating(glicko: glicko, ratedRaces: before.ratedRaces + 1,
                                     established: before.established || glicko.deviation <= config.establishedDeviation,
                                     lastRatedAt: time)
            changes.append(Change(id: participant.id, place: participant.place, opponents: participants.count - 1, before: before, after: after))
        }
        return changes
    }
}
