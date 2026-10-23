import BotSuite
import Foundation
import RegattaBots
import RegattaCore
import Testing

/// The start oracle (#584, stage 1): one boat, no fleet, from her place in a ten-boat opening at T−60, the start a search
/// finds worth most at T+60, and the loss table of where a bot's metres behind it go. Sailed on four seeds of the start
/// pool, one of each conditions file and each in another seat's place, with a narrower, shorter search than the tool's
/// (`options`) so the suite stays quick; the tool's own settings only search harder.
@Suite struct StartOracleTests {
    /// The search the tests run, the lap oracle's tests' (`OracleTimeTrialTests.options`): a beam of 3 (two places of it
    /// the bots' own starts), children sailed on 6 s before they are scored; any wider costs the package's tests their CI
    /// time limit.
    static let options = Oracle.Options(checkpointSeconds: 2, horizonSeconds: 6, beamWidth: 3)

    /// S1, S6, S11 and S16: gusty-offshore, light-and-patchy, sea-breeze and classic-oscillating, seats 0 to 3.
    static let seeds = ["S1", "S6", "S11", "S16"].map { name in StartTrialSeed.pool.first { $0.name == name }! }

    /// Each seed sailed by the oracle, the executor and National, once for the whole suite.
    static let report: StartTrialReport = {
        do {
            return try StartTrial.run(seeds, sailors: [.profile(.executor), .tier(.national)], oracle: options)
        } catch {
            preconditionFailure("the start trial failed: \(error)")
        }
    }()

    /// #584: the oracle's run on a seed is the same twice (the trial's and this one): the same search, node for node and
    /// tick for tick, and its start re-sailed from its inputs is the start the search found: the same worth at T+60, the
    /// same race to the bit.
    @Test func oracleIsDeterministicOnASeed() throws {
        let trial = Self.report.seeds[0]
        let course = try StartTrial.course(trial.seed)
        let plan = try StartOracle(course: course, options: Self.options).search()
        #expect(plan.worth.isFinite, "the oracle starts")
        #expect(plan.worth == trial.oracle.worth, "the search the trial ran is worth what this one is")
        #expect(plan.nodes == trial.oracleNodes)
        #expect(plan.ticks == trial.oracleTicks)
        let replay = try StartTrial.replay(plan.inputs, course: course)
        #expect(replay.entry.worth == plan.worth, "the re-sailed start is worth what the search's was")
        #expect(replay.digest == trial.oracleDigest, "and is the trial's start, to the bit")
    }

    /// The latest after the gun the oracle may start. The T+60 score may rank a start a little late in better air above
    /// one on time, and the owner keeps those (#584, 2026-10-23): the full search crossed later than a second on 22 of the
    /// pool's 200 seeds and 4 of the 40 hold-outs, 3.4 s at the latest. Later than this is a search gone wrong.
    static let latestStartSeconds = 5.0

    /// #584: the oracle's start is never over the line at the gun, and it crosses soon after it.
    @Test func oracleIsNeverOCSAndStartsSoonAfterTheGun() {
        #expect(Self.report.seeds.count == 4)
        for trial in Self.report.seeds {
            let oracle = trial.oracle
            #expect(!oracle.ocs, "\(trial.seed.name): the oracle was over at the gun")
            let start = oracle.startSeconds ?? .infinity
            #expect(start >= 0 && start <= Self.latestStartSeconds, "\(trial.seed.name) \(trial.seed.trial.conditions): the oracle started at \(start) s")
        }
    }

    /// #584: the loss table's columns sum to the gap: each sailor's worth at T+60 is her metres below the line at the gun
    /// and her first minute by the ledger (the polar's best progress in her wind, less what she lost of it by cause, less
    /// her speed's shortfall at T+60), so her metres behind the oracle are those columns less the oracle's (air and forced
    /// moves zero with nobody else on the water); on every seed and in the mean over them.
    @Test func lossTableSumsToTheGap() {
        for trial in Self.report.seeds {
            let oracle = trial.oracle
            #expect(abs(oracle.sum - oracle.worth) < 1e-6, "the oracle's own columns make its worth: \(oracle)")
            #expect(oracle.late >= -1e-6, "nothing is late of a start on time")
            for (entry, loss) in zip(trial.rows, trial.losses) {
                #expect(abs(entry.sum - entry.worth) < 1e-6, "\(trial.seed.name) \(entry.sailor)'s own columns")
                #expect(abs(loss.gap - (oracle.worth - entry.worth)) < 1e-9)
                #expect(abs(loss.sum - loss.gap) < 1e-6, "\(trial.seed.name) \(loss.sailor): \(loss.values)")
                #expect(loss.air == 0 && loss.forced == 0, "no fleet, no air or forced moves")
            }
        }
        let means = Self.report.means
        #expect(means.map(\.sailor) == ["executor", "national"])
        for loss in means { #expect(abs(loss.sum - loss.gap) < 1e-6, "the mean \(loss.sailor)") }
        #expect(Self.report.lines.contains { $0.hasPrefix("national") })
    }

    /// The pool is the start suite's: 200 seeds, the bundled conditions by turns, every seat of the opening as often in
    /// each; the hold-outs are other seeds on the same rule.
    @Test func poolIsTheStartSuites() {
        let pool = StartTrialSeed.pool
        #expect(pool.count == 200 && StartTrialSeed.holdOut.count == 40)
        #expect(pool.map(\.trial.raceSeed) == (1...200).map(UInt64.init))
        for conditions in StartTrialSeed.conditions {
            let seats = pool.filter { $0.trial.conditions == conditions }.map(\.seat)
            #expect((0..<StartTrialSeed.fleetSize).allSatisfy { seat in seats.filter { $0 == seat }.count == 5 }, "\(conditions)")
        }
        #expect(Set(StartTrialSeed.holdOut.map(\.trial.raceSeed)).isDisjoint(with: pool.map(\.trial.raceSeed)))
    }

    /// She starts in her seat's place of the opening, every other seat a ghost.
    @Test func courseSeatsHerInTheOpening() throws {
        let seed = Self.seeds[1]
        let course = try StartTrial.course(seed)
        let race = try Race(setup: course.setup, files: course.files, mode: .authoritative(windSeed: course.windSeed))
        let place = race.exportSnapshot().seats[seed.seat].boat
        let her = course.origin.seats[0].boat
        #expect(course.origin.tick == -course.setup.startSequenceTicks)
        #expect(her.position == place.position && her.heading == place.heading && her.speed == place.speed)
        #expect(her.status == .prestart)
        #expect(course.origin.seats.dropFirst().allSatisfy { $0.boat.status == .dsq })
    }

    @Test func startOptionsParse() throws {
        let options = try TimeTrialOptions(arguments: ["--start", "--seeds", "3", "--holdout", "--tier-mix", "club"])
        #expect(options.start)
        #expect(try options.startSeeds().map(\.name) == ["SH1", "SH2", "SH3"])
        #expect(try TimeTrialOptions(arguments: ["--start", "--only", "S7"]).startSeeds().map(\.name) == ["S7"])
        #expect(throws: BotSuiteError.self) { try TimeTrialOptions(arguments: ["--start", "--laps", "2"]) }
        #expect(throws: BotSuiteError.self) { try TimeTrialOptions(arguments: ["--start", "--seeds", "201"]).startSeeds() }
    }
}
