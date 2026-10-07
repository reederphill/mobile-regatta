@testable import BotSuite
import Foundation
import RegattaBots
import RegattaCore
import Testing

/// #104 acceptance: the cautious bot (CONTEXT.md **Cautious bot**, `BotDriver.cautious`) sailing a dropped player's
/// boat in a fleet of Club bots always gives way (#19): she is never the offender in a rule call, before the gun or
/// after it. And dropping never helps: her mean place is no better than the Club bots' (a place number at least as
/// high as theirs). The 16.1 watchdog and the cautious gate in the bot matrix are #105's.
@Suite struct CautiousBotSuiteTests {
    /// Seeds sailed: races of ten, one lap, all Club, one cautious seat each, rotated through the seats (#408).
    static let seeds = 32
    static let fleetSize = 10

    @Test func cautiousSeatNeverFoulsAndPlacesAtOrBelowClub() throws {
        let matrix = BotMatrix(seeds: (1...UInt64(Self.seeds)).map { $0 }, fleetSizes: [Self.fleetSize],
                               tierMixes: [.club], laps: 1)
        var cautiousPlaces: [Double] = [], clubPlaces: [Double] = []
        var fouls: [String] = []
        for cell in matrix.cells {
            let cautious = Int(cell.seed % UInt64(Self.fleetSize))
            let result = try BotRaceHarness.run(cell, cautiousSeats: [cautious])
            for seat in result.seats {
                // A boat that didn't finish is placed last.
                let place = Double(seat.place ?? Self.fleetSize)
                if seat.seat == cautious {
                    cautiousPlaces.append(place)
                    if seat.foulsAsOffender > 0 { fouls.append("seed \(cell.seed) seat \(cautious): \(seat.foulsAsOffender)") }
                } else {
                    clubPlaces.append(place)
                }
            }
        }
        func mean(_ p: [Double]) -> Double { p.reduce(0, +) / Double(p.count) }
        let cautious = mean(cautiousPlaces), club = mean(clubPlaces)
        print("CautiousBotSuiteTests over \(Self.seeds) Club fleets of \(Self.fleetSize): cautious mean place \(cautious), "
              + "club \(club); cautious fouls as offender in \(fouls.count) races")
        #expect(fouls.isEmpty, "\(fouls.joined(separator: "\n"))")
        #expect(cautious >= club, "cautious \(cautious), club \(club): dropping helped")
    }
}
