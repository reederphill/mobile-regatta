import BotSuite
import RegattaCore
import Testing

/// #346 acceptance: bots never breach rule 17 (#345): held to her proper course, a bot sails within it by
/// construction (`BotBrain.properCourseLimited`), and rule 17 is not one she misjudges. Over the smoke run's seeds
/// (`BotSuiteSmokeTests`), mixed and all-National fleets, no rule 17 call is made on any bot.
@Suite struct BotRule17SuiteTests {
    @Test func botsDrawNoRule17Calls() throws {
        let matrix = BotMatrix(seeds: [1, 2, 3], fleetSizes: [10], tierMixes: [.mixed, .national], laps: 1)
        var calls: [String] = []
        for cell in matrix.cells {
            _ = try BotRaceHarness.run(cell, cautiousSeats: []) { events in
                for event in events {
                    if case .ruleCall(let call) = event.kind, call.rule == .properCourse {
                        calls.append("seed \(cell.seed) \(cell.tierMix): on \(call.offender)")
                    }
                }
            }
        }
        #expect(calls.isEmpty, "rule 17 called on bots: \(calls)")
    }
}
