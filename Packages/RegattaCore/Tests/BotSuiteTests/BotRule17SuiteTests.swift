import BotSuite
import RegattaCore
import Testing

/// #346 acceptance: bots never breach rule 17 (#345): held to her proper course, a bot sails within it by
/// construction (`BotBrain.properCourseLimited`), and rule 17 is not one she misjudges. Over mixed and all-National
/// fleets of 10 and 16, no rule 17 call is made on any bot, and the scan isn't vacuous: bots are held to their
/// proper course (a rule 17 record names one the leeward boat) on `restrictedBotTicks` seat-ticks across it.
@Suite struct BotRule17SuiteTests {
    @Test func botsDrawNoRule17Calls() throws {
        let matrix = BotMatrix(seeds: [1, 2, 3], fleetSizes: [10, 16], tierMixes: [.mixed, .national], laps: 1)
        var calls: [String] = []
        var restricted = 0
        for cell in matrix.cells {
            _ = try BotRaceHarness.run(cell, cautiousSeats: []) { race, events in
                restricted += race.boats.indices.count { !race.properCourseRestrictions(of: $0).isEmpty }
                for event in events {
                    if case .ruleCall(let call) = event.kind, call.rule == .properCourse {
                        calls.append("seed \(cell.seed) \(cell.tierMix) \(cell.fleetSize): on \(call.offender)")
                    }
                }
            }
        }
        print("BotRule17SuiteTests: \(restricted) restricted bot seat-ticks")
        #expect(restricted > 0, "no bot was ever held to her proper course: the scan is vacuous")
        #expect(calls.isEmpty, "rule 17 called on bots: \(calls)")
    }
}
