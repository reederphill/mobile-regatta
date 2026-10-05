import BotSuite
import Foundation
import RegattaBots
import RegattaCore
import Testing

/// #235 acceptance (owner ruling, 2026-10-04): a practice rival keeps the player close on average. Seat 0 stands in
/// for the player, a bot at skill s; the race's rivals (`Rivals.seats`) sail at the same s, as the app sets them from
/// the player's results; the rest are a Mixed fleet. At each s ∈ {0.45, 0.7, 0.9}, seat 0's mean place and its
/// rivals' mean place (both rival seats pooled) must be within 2 places. The per-race share of (race, rival) pairs
/// within 2 places is printed for information only: race-to-race scatter is bot work (#105/#177), not this check.
@Suite struct BotRivalSuiteTests {
    static let skills = [0.45, 0.7, 0.9]
    /// Seeds sailed per skill: races of ten.
    static let seeds = 100
    static let fleetSize = 10
    static let laps = 1
    /// Places seat 0's mean place and its rivals' mean place may be apart and still pass.
    static let maxMeanPlaceGap = 2.0
    /// Places either way a single (race, rival) pair counts as close, for the printed share only.
    static let maxPlaceGap = 2

    @Test func seatFinishesNearItsRivalsOnAverage() throws {
        let matrix = BotMatrix(seeds: (1...UInt64(Self.seeds)).map { $0 }, fleetSizes: [Self.fleetSize],
                               tierMixes: [.mixed], laps: Self.laps)
        var closePairs = 0, allPairs = 0
        for skill in Self.skills {
            var closeAt = 0, pairsAt = 0, seatPlaces = 0.0, rivalPlaces = 0.0
            for cell in matrix.cells {
                let rivals = Rivals.seats(raceSeed: RaceSeed(cell.seed), botSeats: Array(1..<cell.fleetSize))
                var seatSkills = [0: skill]
                for rival in rivals { seatSkills[rival] = skill }
                let result = try BotRaceHarness.run(cell, cautiousSeats: [], seatSkills: seatSkills)
                // A boat that didn't finish is placed last, as BotTierSuiteTests places her.
                let place = { (seat: Int) in result.seats[seat].place ?? Self.fleetSize }
                seatPlaces += Double(place(0))
                for rival in rivals {
                    pairsAt += 1
                    rivalPlaces += Double(place(rival))
                    if abs(place(0) - place(rival)) <= Self.maxPlaceGap { closeAt += 1 }
                }
            }
            let seatMean = seatPlaces / Double(matrix.cells.count)
            let rivalMean = rivalPlaces / Double(pairsAt)
            let q = Rivals.skillEquivalent(of: PracticeFinish(place: Int(seatMean.rounded()),
                                                              fleetSize: Self.fleetSize, tier: nil)) ?? .nan
            print("BotRivalSuiteTests skill \(skill): seat 0 mean place \(seatMean), rivals' mean place \(rivalMean) "
                  + "(gap \(abs(seatMean - rivalMean))); info: \(closeAt)/\(pairsAt) pairs within "
                  + "\(Self.maxPlaceGap) places (\(Double(closeAt) / Double(pairsAt))); the linear map reads seat 0 "
                  + "back as skill \(q)")
            #expect(abs(seatMean - rivalMean) <= Self.maxMeanPlaceGap,
                    "skill \(skill): seat 0 mean place \(seatMean) vs rivals' \(rivalMean)")
            closePairs += closeAt
            allPairs += pairsAt
        }
        print("BotRivalSuiteTests info overall: \(closePairs)/\(allPairs) pairs within \(Self.maxPlaceGap) places "
              + "(\(Double(closePairs) / Double(allPairs))), \(Self.laps) lap(s)")
    }
}
