import BotSuite
import Foundation
import RegattaBots
import RegattaCore
import Testing

/// #583 stage 2: `regatta-timetrial --tune`'s search over the bots' tunables (`TimeTrialTuner`).
@Suite struct TimeTrialTunerTests {
    /// On a bowl whose bottom is inside every range, the search walks each tunable to it from the original set, keeps
    /// only moves that gain, and gives the same set every run.
    @Test func searchFindsTheBottomOfABowl() {
        let parameters = BotTunables.parameters
        // The bottom: a third of the way up each range.
        let bottom = parameters.map { $0.range.lowerBound + ($0.range.upperBound - $0.range.lowerBound) / 3 }
        func bowl(_ tunables: BotTunables) -> Double {
            zip(parameters, bottom).reduce(0) { sum, pair in
                let width = pair.0.range.upperBound - pair.0.range.lowerBound
                let off = (pair.0.value(in: tunables) - pair.1) / width
                return sum + 10_000 * off * off
            }
        }
        let outcome = TimeTrialTuner.search(from: .original, rounds: 6, objective: bowl) { _ in }
        #expect(outcome.startSeconds == bowl(.original))
        #expect(outcome.seconds == bowl(outcome.tunables))
        #expect(outcome.seconds < outcome.startSeconds / 100, "\(outcome.startSeconds) -> \(outcome.seconds)")
        for (parameter, target) in zip(parameters, bottom) {
            let width = parameter.range.upperBound - parameter.range.lowerBound
            #expect(abs(parameter.value(in: outcome.tunables) - target) <= width / 64, "\(parameter.name)")
        }
        let again = TimeTrialTuner.search(from: .original, rounds: 6, objective: bowl)
        #expect(again.tunables == outcome.tunables, "deterministic")
        #expect(outcome.evaluations > 2 * BotTunables.parameters.count)
    }

    /// A flat objective moves nothing: no move gains `leastGain`.
    @Test func aFlatObjectiveKeepsTheStart() {
        let outcome = TimeTrialTuner.search(from: .original, rounds: 2, objective: { _ in 10 })
        #expect(outcome.tunables == .original)
        #expect(outcome.seconds == 10)
    }

    @Test func optionsParseTheTuningFlags() throws {
        let options = try TimeTrialOptions(arguments: ["--oracle-from", "r.json", "--tune", "out.json", "--tune-rounds", "2",
                                                       "--tunables", "t.json"])
        #expect(options.oracleFrom == ["r.json"] && options.tuneOut == "out.json" && options.tuneRounds == 2)
        #expect(options.tunablesPath == "t.json")
        #expect(throws: BotSuiteError.self) { try TimeTrialOptions(arguments: ["--tune", "out.json"]) }
    }
}
