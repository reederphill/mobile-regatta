import BotSuite
import Foundation
import RegattaBots
import RegattaCore
import Testing

/// The oracle time trial (#583, stage 1): one boat, no fleet, the fastest lap a search finds on a seed's course, and the
/// ledger of where a bot's time behind it goes. Sailed on one lap of the first reference race of each conditions file,
/// with a narrower, shorter search than the tool's (`options`) so the suite stays quick; the tool's own settings only
/// search harder.
@Suite struct OracleTimeTrialTests {
    /// The search the tests run: a beam of 3 (two places of it the bots' own laps), children sailed on 6 s before they
    /// are scored; any wider costs the package's tests their CI time limit.
    static let options = Oracle.Options(checkpointSeconds: 2, horizonSeconds: 6, beamWidth: 3)

    /// The first reference race of each conditions file, one lap.
    static let seeds: [TimeTrialSeed] = {
        var seen = Set<String>()
        return TimeTrialSeed.reference.filter { seen.insert($0.conditions).inserted }.map { seed in
            var seed = seed
            seed.laps = 1
            return seed
        }
    }()

    /// Each seed sailed by the oracle, the executor and National, once for the whole suite.
    static let trials: [TimeTrialSeedResult] = {
        do {
            return try TimeTrial.run(seeds, sailors: [.profile(.executor), .tier(.national)], oracle: options)
        } catch {
            preconditionFailure("the time trial failed: \(error)")
        }
    }()

    /// #583: the oracle's run on a seed is the same twice (the time trial's and this one): the same search, node for node and
    /// tick for tick, and its lap re-sailed from its inputs is the lap the search found: the same finish, the same race to
    /// the bit.
    @Test func oracleIsDeterministicOnASeed() throws {
        let seed = Self.seeds[0]
        let course = try TimeTrialCourse(seed)
        let plan = try Oracle(course: course, options: Self.options).search()
        let trial = Self.trials[0]
        #expect(plan.finishSeconds != nil, "the oracle finishes")
        #expect(plan.finishSeconds == trial.oracleSeconds, "the search the time trial ran finished when this one did")
        #expect(plan.nodes == trial.oracleNodes)
        #expect(plan.ticks == trial.oracleTicks)
        let lap = try course.replay(plan.inputs)
        #expect(lap.finishSeconds == plan.finishSeconds, "the re-sailed lap finishes when the search's did")
        #expect(lap.digest == trial.oracleDigest, "and is the time trial's lap, to the bit")
    }

    /// #583: the executor is perfect handling with groove-only tactics; a search that loses to her is broken.
    @Test func oracleBeatsTheExecutorOnEverySeed() {
        #expect(Self.trials.count == 4)
        for trial in Self.trials {
            guard let oracle = trial.oracleSeconds else {
                Issue.record("\(trial.seed.name): the oracle didn't finish")
                continue
            }
            let executor = trial.losses[0]
            #expect(executor.sailor == "executor")
            #expect(executor.finishSeconds.map { $0 > oracle } ?? true,
                    "\(trial.seed.name) \(trial.seed.conditions): the oracle \(oracle) s, the executor \(executor.finishSeconds ?? .nan) s")
        }
    }

    /// #583: the ledger's columns sum to the gap: by cause, and by segment of the lap, each sailor's seconds behind the
    /// oracle add up to her time less the oracle's (each tick is in one segment and one cause, and a cause's seconds
    /// with the ideal seconds are the tick's).
    @Test func lossTableSumsToTheGap() {
        for trial in Self.trials {
            #expect(abs(trial.oracleCauses.reduce(0, +) - (trial.oracleSeconds ?? .nan)) < 1e-6,
                    "the oracle's own causes sum to its time")
            #expect(abs(trial.oracleSegments.reduce(0, +) - (trial.oracleSeconds ?? .nan)) < 1e-6)
            for loss in trial.losses {
                #expect(abs(loss.causes.reduce(0, +) - loss.gapSeconds) < 1e-6, "\(trial.seed.name) \(loss.sailor) by cause")
                #expect(abs(loss.segments.reduce(0, +) - loss.gapSeconds) < 1e-6, "\(trial.seed.name) \(loss.sailor) by segment")
                #expect(loss.finishSeconds.map { abs($0 - (trial.oracleSeconds ?? .nan) - loss.gapSeconds) < 1e-6 } ?? true)
            }
        }
    }

    /// The report's mean table is the mean of the seeds', and its text names every sailor.
    @Test func reportMeansTheSeeds() {
        let report = TimeTrialReport(oracle: Self.options, segments: [], seeds: Self.trials)
        let means = report.means
        #expect(means.map(\.sailor) == ["executor", "national"])
        let gaps = Self.trials.map { $0.losses[0].gapSeconds }
        #expect(abs(means[0].gapSeconds - gaps.reduce(0, +) / Double(gaps.count)) < 1e-9)
        #expect(report.lines.contains { $0.hasPrefix("executor") })
    }

    @Test func optionsParse() throws {
        let options = try TimeTrialOptions(arguments: ["--seeds", "3", "--holdout", "--tier-mix", "national", "--profile-mix",
                                                       "executor", "--beam", "8", "--horizon", "0", "--laps", "1"])
        #expect(options.sailors == [.tier(.national), .profile(.executor)])
        #expect(options.oracle.beamWidth == 8)
        #expect(options.oracle.horizonSeconds == 0)
        let seeds = try options.seeds()
        #expect(seeds.map(\.name) == ["H1", "H2", "H3"])
        #expect(seeds.allSatisfy { $0.laps == 1 })
        #expect(TimeTrialOptions().sailors == TimeTrialSailor.standard)
        #expect(throws: BotSuiteError.self) { try TimeTrialOptions(arguments: ["--tier-mix", "mixed"]) }
        #expect(throws: BotSuiteError.self) { try TimeTrialOptions(arguments: ["--seeds", "17"]).seeds() }
    }
}
