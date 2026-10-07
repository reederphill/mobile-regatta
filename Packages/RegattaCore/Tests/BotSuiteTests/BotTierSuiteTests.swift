import BotSuite
import Foundation
import RegattaBots
import Testing

/// #102 acceptance: the bot tiers are skill bands whose weaknesses order them. In Mixed fleets (each seat's tier
/// drawn from its bot's seed, as the app's bots are), a National bot finishes ahead of a Regional one, and a
/// Regional ahead of a Club one, by at least the bot-tier file's place gap (1.0, a placeholder) on average.
@Suite struct BotTierSuiteTests {
    /// Seeds sailed: 50 mixed fleets of ten, one lap (#408: enough for the tier ordering check under CI time).
    static let seeds = 50
    static let fleetSize = 10

    @Test func meanPlaceOrdersTiersByAtLeastOnePlace() throws {
        let matrix = BotMatrix(seeds: (1...UInt64(Self.seeds)).map { $0 }, fleetSizes: [Self.fleetSize],
                               tierMixes: [.mixed], laps: 1)
        var places: [BotTier: [Double]] = [:]
        for cell in matrix.cells {
            let result = try BotRaceHarness.run(cell)
            for seat in result.seats {
                // A boat that didn't finish is placed last.
                places[seat.tier, default: []].append(Double(seat.place ?? Self.fleetSize))
            }
        }
        func mean(_ tier: BotTier) -> Double {
            let p = places[tier] ?? []
            return p.isEmpty ? .nan : p.reduce(0, +) / Double(p.count)
        }
        let gap = BotTierFile.bundled.minPlaceGap
        let national = mean(.national), regional = mean(.regional), club = mean(.club)
        print("BotTierSuiteTests mean place over \(Self.seeds) mixed fleets of \(Self.fleetSize): national \(national) "
              + "(\(places[.national]?.count ?? 0) seats), regional \(regional) (\(places[.regional]?.count ?? 0)), "
              + "club \(club) (\(places[.club]?.count ?? 0))")
        // #388's pre-gun gybe hold (takeover seed 1) reshuffles these races: regional - national 0.993 against the
        // 1.0 placeholder. Owner 2026-10-05: ship, #389 tunes the gap.
        withKnownIssue("#389: placeholder tier gap; national-regional 0.993 after #388", isIntermittent: true) {
            #expect(regional - national >= gap, "national \(national), regional \(regional)")
        }
        #expect(club - regional >= gap, "regional \(regional), club \(club)")
    }
}
