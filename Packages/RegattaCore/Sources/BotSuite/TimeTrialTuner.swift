import Foundation
import RegattaBots
import RegattaCore

/// `regatta-timetrial --tune` (#583 stage 2): a search over the bots' tunables (`BotTunables`) for the least mean time
/// behind the oracle, in place of tuning by hand. The oracle's laps are fixed (`--oracle-from`: they read no tunable),
/// so each candidate costs only the bots' laps.
///
/// Coordinate descent: from the starting set, each round tries every tunable a step up and a step down, in the file's
/// order, and keeps a move that lowers the mean (going on the same way while it does); each round's step is half the
/// last, the first an eighth of the tunable's range. Deterministic: the same seeds, sailors and start give the same set.
/// The objective is the mean over seeds and sailors of each sailor's seconds behind the oracle; a run on the hold-out
/// seeds with the result (`--holdout --tunables`) checks it for overfitting.
public enum TimeTrialTuner {
    /// What a move must gain to be kept, seconds: less is a tie, and the set doesn't wander on it.
    public static let leastGain = 0.05

    /// The search's result: the best set, its objective, and the starting set's.
    public struct Outcome: Sendable {
        public var tunables: BotTunables
        public var seconds: Double
        public var startSeconds: Double
        public var evaluations: Int
    }

    /// Searches `parameters` from `start` for the set with the least `objective`, `rounds` rounds; `log` sees every kept
    /// move.
    public static func search(from start: BotTunables, rounds: Int,
                              parameters: [BotTunables.Parameter] = BotTunables.parameters,
                              objective: (BotTunables) throws -> Double,
                              log: (String) -> Void = { _ in }) rethrows -> Outcome {
        var best = start
        var bestSeconds = try objective(start)
        let startSeconds = bestSeconds
        var evaluations = 1
        log(String(format: "start: %.2f s", bestSeconds))
        var steps = parameters.map { ($0.range.upperBound - $0.range.lowerBound) / 8 }
        for round in 1...max(rounds, 1) {
            for (index, parameter) in parameters.enumerated() {
                for sign in [1.0, -1.0] {
                    var moved = false
                    while true {
                        let candidate = parameter.set(parameter.value(in: best) + sign * steps[index], in: best)
                        guard candidate != best else { break }
                        let seconds = try objective(candidate)
                        evaluations += 1
                        guard seconds < bestSeconds - leastGain else { break }
                        log(String(format: "round %d: %@ %.4g -> %.4g: %.2f s", round, parameter.name,
                                   parameter.value(in: best), parameter.value(in: candidate), seconds))
                        best = candidate
                        bestSeconds = seconds
                        moved = true
                    }
                    if moved { break }
                }
            }
            steps = steps.map { $0 / 2 }
        }
        return Outcome(tunables: best, seconds: bestSeconds, startSeconds: startSeconds, evaluations: evaluations)
    }

    /// The mean over `results`' seeds and sailors of the seconds behind the oracle.
    public static func meanGap(_ results: [TimeTrialSeedResult]) -> Double {
        let gaps = results.flatMap { $0.losses.map(\.gapSeconds) }
        return gaps.isEmpty ? .infinity : gaps.reduce(0, +) / Double(gaps.count)
    }

    /// `--tune`: the search on `options`' seeds and sailors, written to `out` as the next tunables file.
    static func run(_ options: TimeTrialOptions, out: String, log: (String) -> Void) throws {
        let seeds = try options.seeds()
        let sailors = options.sailors
        let known = try options.knownOracle()
        let jobs = options.jobs ?? BotSuite.defaultJobs
        log("regatta-timetrial --tune: \(seeds.count) seeds, sailors \(sailors.map(\.description).joined(separator: ", "))")
        let start = try options.tunables() ?? .bundled
        let outcome = try search(from: start, rounds: options.tuneRounds, parameters: options.tuneParameters(), objective: { tunables in
            meanGap(try TimeTrial.run(seeds, sailors: sailors, oracle: options.oracle, tunables: tunables, known: known,
                                      jobs: jobs))
        }, log: log)
        log(String(format: "best: %.2f s behind the oracle (from %.2f), %d evaluations", outcome.seconds,
                   outcome.startSeconds, outcome.evaluations))
        let notes = String(format: "Tuned by regatta-timetrial --tune (#583 stage 2) on %@ for %@: %.2f s behind the oracle, from %.2f.",
                           seeds.map(\.name).joined(separator: " "), sailors.map(\.description).joined(separator: " and "),
                           outcome.seconds, outcome.startSeconds)
        try outcome.tunables.encoded(version: BotTunables.currentVersion + 1, notes: notes)
            .write(to: URL(fileURLWithPath: out))
        for parameter in BotTunables.parameters {
            let from = parameter.value(in: start)
            let to = parameter.value(in: outcome.tunables)
            if from != to { log(String(format: "  %@: %.4g -> %.4g", parameter.name, from, to)) }
        }
    }
}
