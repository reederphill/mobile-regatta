import Foundation
import Ratings
import Testing

// #151. The expected numbers come from an independent throwaway implementation of the same formulas (the brief's
// prototype), not from this code; the first is Glickman's published example.

private func near(_ a: Double, _ b: Double, _ tolerance: Double = 0.05) -> Bool { abs(a - b) <= tolerance }

@Suite struct Glicko2Tests {
    /// "Example of the Glicko-2 system" (Glickman, 2012): 1500/200/0.06 beats 1400/30, loses to 1550/100 and
    /// 1700/300, τ 0.5. The paper prints 1464.06, 151.52, 0.05999 from intermediate values rounded to 4 places.
    @Test func glickmanWorkedExample() throws {
        let after = try Glicko2(rating: 1500, deviation: 200, volatility: 0.06).updated([
            Glicko2.Game(opponentRating: 1400, opponentDeviation: 30, score: 1),
            Glicko2.Game(opponentRating: 1550, opponentDeviation: 100, score: 0),
            Glicko2.Game(opponentRating: 1700, opponentDeviation: 300, score: 0),
        ])
        #expect(near(after.rating, 1464.06, 0.02))
        #expect(near(after.deviation, 151.52, 0.01))
        #expect(near(after.volatility, 0.05999, 0.00001))
    }

    @Test func noGamesGrowsDeviationOnly() throws {
        let a = try Glicko2(rating: 1612, deviation: 80, volatility: 0.06).updated([], periods: 16)
        #expect(a.rating == 1612 && a.volatility == 0.06 && near(a.deviation, 90.21, 0.01))
        let b = try Glicko2(rating: 1500, deviation: 60, volatility: 0.06).updated([], periods: 41)
        #expect(near(b.deviation, 89.75, 0.01))
        // Never over the top of the range, however long.
        #expect(try Glicko2(rating: 1500, deviation: 300, volatility: 0.1).updated([], periods: 365).deviation == 350)
        #expect(try Glicko2(rating: 1500, deviation: 80, volatility: 0.06).updated([], periods: 0).deviation == 80)
    }

    /// Two established players, a duel: a day apart the deviation ends at 78.71; back to back at 78.08, and a run of
    /// races back to back only ever shrinks it.
    @Test func backToBackRacesAddNoDeviation() throws {
        let player = Glicko2(rating: 1500, deviation: 80, volatility: 0.06)
        let game = [Glicko2.Game(opponentRating: 1500, opponentDeviation: 80, score: 1)]
        let dayLater = try player.updated(game, periods: 1), atOnce = try player.updated(game, periods: 0)
        #expect(near(dayLater.rating, 1517.27) && near(dayLater.deviation, 78.71, 0.01))
        #expect(near(atOnce.rating, 1517.01) && near(atOnce.deviation, 78.08, 0.01))
        var running = player, last = player.deviation
        for round in 0..<30 {
            running = try running.updated([Glicko2.Game(opponentRating: 1500, opponentDeviation: 80, score: round % 2 == 0 ? 1 : 0)], periods: 0)
            #expect(running.deviation < last)
            last = running.deviation
        }
    }

    @Test func clampsHold() throws {
        let config = RatingConfig()
        let top = try Glicko2(rating: 3990, deviation: 350, volatility: 0.1)
            .updated([Glicko2.Game(opponentRating: 100, opponentDeviation: 350, score: 1)])
        #expect(config.ratingRange.contains(top.rating) && config.deviationRange.contains(top.deviation) && top.volatility <= 0.1)
        // A long winning run against the weakest can't leave the ranges, and the deviation stops at 50.
        var player = Glicko2(rating: 3900, deviation: 60, volatility: 0.09)
        var loser = Glicko2(rating: 200, deviation: 60, volatility: 0.09)
        for _ in 0..<400 {
            let next = try player.updated([Glicko2.Game(opponentRating: loser.rating, opponentDeviation: 350, score: 1)], periods: 0)
            loser = try loser.updated([Glicko2.Game(opponentRating: player.rating, opponentDeviation: 350, score: 0)], periods: 0)
            player = next
            for state in [player, loser] {
                #expect(config.ratingRange.contains(state.rating) && config.deviationRange.contains(state.deviation)
                    && config.volatilityRange.contains(state.volatility))
            }
        }
        #expect(player.rating <= 4000 && loser.rating >= 100)
        // Many even races back to back: the deviation stops at the floor.
        var even = Glicko2(rating: 1500, deviation: 60, volatility: 0.06)
        for round in 0..<200 {
            even = try even.updated([Glicko2.Game(opponentRating: 1500, opponentDeviation: 50, score: round % 2 == 0 ? 1 : 0)], periods: 0)
        }
        #expect(even.deviation == 50)
    }

    @Test func numbersThatArentFiniteAreRefused() {
        #expect(throws: RatingError.self) { try Glicko2(rating: .nan, deviation: 80, volatility: 0.06).updated([]) }
        #expect(throws: RatingError.self) {
            try Glicko2().updated([Glicko2.Game(opponentRating: .infinity, opponentDeviation: 80, score: 1)])
        }
        var config = RatingConfig()
        config.tau = .nan
        #expect(throws: RatingError.self) { try Glicko2().updated([Glicko2.Game(opponentRating: 1500, opponentDeviation: 80, score: 1)], config: config) }
    }
}

@Suite struct FleetRatingTests {
    static let time = Date(timeIntervalSince1970: 1_800_000_000)

    /// A fleet of first-race players (`periods` 1) at the ratings given, placed as given.
    static func fleet(_ players: [(Double, Double)], places: [Int], established: Bool = false) -> [FleetRating.Participant<Int>] {
        players.indices.map {
            FleetRating.Participant(id: $0, place: places[$0], rating: PlayerRating(
                glicko: Glicko2(rating: players[$0].0, deviation: players[$0].1, volatility: 0.06), established: established))
        }
    }

    static func rate(_ players: [(Double, Double)], places: [Int]) throws -> [FleetRating.Change<Int>] {
        try FleetRating.rate(fleet(players, places: places), at: time)
    }

    @Test func pairwiseExpansionByPlace() {
        let fleet = Self.fleet(Array(repeating: (1500, 350), count: 4), places: [2, 1, 4, 3])
        let games = FleetRating.games(of: 0, in: fleet, at: Self.time)
        #expect(games.map(\.score) == [0, 1, 1], "second: lost to the winner, beat the other two")
        #expect(games.count == 3 && games.allSatisfy { $0.opponentRating == 1500 })
        #expect(FleetRating.games(of: 1, in: fleet, at: Self.time).map(\.score) == [1, 1, 1])
        #expect(FleetRating.games(of: 2, in: fleet, at: Self.time).map(\.score) == [0, 0, 0])
        #expect(FleetRating.score(3, against: 3) == 0.5)
        #expect(throws: RatingError.badFleet) { try FleetRating.rate(Array(fleet.prefix(1)), at: Self.time) }
        #expect(throws: RatingError.badFleet) { try FleetRating.rate([fleet[0], fleet[0]], at: Self.time) }
    }

    /// 4 established players, two RETs tied last (a normal close): the two draw with each other and lose to the rest.
    @Test func tiedRETsDrawAndLoseToEveryoneElse() throws {
        let fleet = Self.fleet(Array(repeating: (1500, 80), count: 4), places: [1, 2, 3, 3])
        #expect(FleetRating.games(of: 2, in: fleet, at: Self.time).map(\.score) == [0, 0, 0.5])
        let after = try FleetRating.rate(fleet, at: Self.time).map(\.after.glicko)
        for (got, want) in zip(after.map(\.rating), [1528.90, 1509.63, 1480.73, 1480.73]) { #expect(near(got, want)) }
        #expect(after[2] == after[3])
        #expect(after.allSatisfy { near($0.deviation, 77.36, 0.01) })
    }

    /// A boat placed by distance is rated at her place like any other: places 1 (finished), 2 (by distance), 3 (DSQ).
    @Test func byDistanceCountsAtItsPlace() throws {
        let after = try Self.rate([(1700, 60), (1500, 80), (1300, 100)], places: [1, 2, 3]).map(\.after.glicko)
        #expect(near(after[0].rating, 1704.94) && near(after[1].rating, 1499.97) && near(after[2].rating, 1287.13))
        #expect(after[0].rating > 1700 && after[2].rating < 1300)
    }

    /// An all-gone close places its RETs one by one (the latest leaver best): no draws, the order decides.
    @Test func allGoneLeaveOrderIsDecisive() throws {
        let allGone = try Self.rate(Array(repeating: (1500, 80), count: 3), places: [3, 4, 5]).map(\.after.glicko.rating)
        #expect(allGone[0] > 1500 && near(allGone[1], 1500, 0.01) && allGone[2] < 1500)
        let tied = try Self.rate(Array(repeating: (1500, 80), count: 3), places: [3, 3, 3]).map(\.after.glicko.rating)
        #expect(tied.allSatisfy { near($0, 1500, 0.01) })
    }

    @Test func weightIsOneOverRootOpponents() throws {
        #expect(FleetRating.weight(opponents: 1) == 1)
        #expect(near(FleetRating.weight(opponents: 3), 0.57735, 0.00001))
        #expect(near(FleetRating.weight(opponents: 15), 0.25820, 0.00001))
        let fleet = Self.fleet(Array(repeating: (1500, 350), count: 16), places: Array(1...16))
        #expect(FleetRating.games(of: 0, in: fleet, at: Self.time).allSatisfy { near($0.weight, 0.2582, 0.0001) })
        // A first race won: +162 in a duel, +229 of 4, +331 of 16: more, never the 9x an unweighted 16 would be.
        let wins = try [2, 4, 16].map { n in
            try Self.rate(Array(repeating: (1500, 350), count: n), places: Array(1...n))[0].after.glicko.rating - 1500
        }
        #expect(near(wins[0], 162.21) && near(wins[1], 228.67) && near(wins[2], 331.10))
        var unweighted = RatingConfig()
        unweighted.weightExponent = 0
        let all = try FleetRating.rate(Self.fleet(Array(repeating: (1500, 350), count: 4), places: [1, 2, 3, 4]), at: Self.time, config: unweighted)
        #expect(near(all[0].after.glicko.rating, 1799.51))
    }

    @Test func workedVectors() throws {
        let duel = try Self.rate([(1500, 350), (1500, 350)], places: [1, 2]).map(\.after.glicko)
        #expect(near(duel[0].rating, 1662.21) && near(duel[1].rating, 1337.79))
        #expect(duel.allSatisfy { near($0.deviation, 290.23, 0.01) && near($0.volatility, 0.06, 1e-4) })

        let four = try Self.rate(Array(repeating: (1500, 350), count: 4), places: [1, 2, 3, 4]).map(\.after.glicko)
        for (got, want) in zip(four.map(\.rating), [1728.67, 1576.22, 1423.78, 1271.33]) { #expect(near(got, want)) }
        #expect(four.allSatisfy { near($0.deviation, 261.83, 0.01) })

        let favourite = try Self.rate([(1700, 60), (1500, 80)], places: [1, 2]).map(\.after.glicko)
        #expect(near(favourite[0].rating, 1705.00) && near(favourite[0].deviation, 60.26, 0.01))
        #expect(near(favourite[1].rating, 1491.35) && near(favourite[1].deviation, 79.17, 0.01))

        let upset = try Self.rate([(1700, 60), (1500, 80), (1300, 100)], places: [3, 2, 1]).map(\.after.glicko)
        for (got, want) in zip(upset.map(\.rating), [1676.57, 1500.70, 1362.78]) { #expect(near(got, want)) }

        let sixteen = try Self.rate(Array(repeating: (1500, 350), count: 16), places: Array(1...16)).map(\.after.glicko)
        #expect(near(sixteen[0].rating, 1831.10) && near(sixteen[1].rating, 1787.0, 0.1) && near(sixteen[15].rating, 1168.90))
        #expect(near(sixteen[0].deviation, 210.70, 0.01))
    }

    /// Structural: the winner scores 1 against everyone and expects less than 1, so her rating never falls.
    @Test func winnerNeverLoses() throws {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            let n = Int.random(in: 2...16, using: &generator)
            let players = (0..<n).map { _ in (Double.random(in: 100...4000, using: &generator), Double.random(in: 50...350, using: &generator)) }
            var places = (0..<n).map { _ in Int.random(in: 2...n + 1, using: &generator) }
            let winner = Int.random(in: 0..<n, using: &generator)
            places[winner] = 1
            let changes = try Self.rate(players, places: places)
            #expect(changes[winner].after.glicko.rating >= changes[winner].before.glicko.rating, "\(players) \(places)")
            #expect(changes[winner].after.displayed >= changes[winner].before.displayed)
            // And whoever is last alone never gains.
            if let worst = places.max(), places.filter({ $0 == worst }).count == 1, let last = places.firstIndex(of: worst) {
                #expect(changes[last].after.glicko.rating <= changes[last].before.glicko.rating)
            }
        }
    }

    /// Provisional until a rated race leaves the deviation at or under 90: 16 duels a day apart against established
    /// opponents (deviation 60). Then established for good: a year away grows the deviation, not the badge.
    @Test func provisionalUntilRDAtOrBelow90AndStaysEstablished() throws {
        var player = PlayerRating()
        #expect(player.isProvisional && player.displayed == 1500)
        var time = Self.time, races = 0
        while player.isProvisional {
            let opponent = PlayerRating(glicko: Glicko2(rating: 1500, deviation: 60, volatility: 0.06), established: true, lastRatedAt: time)
            let fleet = [FleetRating.Participant(id: 0, place: races % 2 + 1, rating: player),
                         FleetRating.Participant(id: 1, place: 2 - races % 2, rating: opponent)]
            let before = player
            player = try FleetRating.rate(fleet, at: time)[0].after
            races += 1
            #expect(player.established == (player.glicko.deviation <= 90), "race \(races): \(player.glicko.deviation)")
            #expect(before.glicko.deviation > 90)
            time += 86_400
            #expect(races <= 40)
        }
        #expect(races == 16 && player.ratedRaces == 16)
        // A year away: the deviation is far over 90 at her next race, and she is still established after it.
        let back = time + 365 * 86_400
        #expect(player.glicko.deviation(after: player.periods(to: back, config: RatingConfig())) > 200)
        let rusty = try FleetRating.rate([FleetRating.Participant(id: 0, place: 2, rating: player),
                                          FleetRating.Participant(id: 1, place: 1, rating: PlayerRating())], at: back)[0].after
        #expect(rusty.glicko.deviation > 90 && rusty.established && !rusty.isProvisional)
        // Time away is counted in days, from her last rated race; a clock that stepped back counts as none.
        #expect(player.periods(to: time - 86_400 + 43_200, config: RatingConfig()) == 0.5)
        #expect(player.periods(to: time - 10 * 86_400, config: RatingConfig()) == 0)
        #expect(PlayerRating().periods(to: time, config: RatingConfig()) == 1)
    }
}
