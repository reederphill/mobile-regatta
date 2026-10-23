import BotSuite
import Foundation
import RegattaBots
import RegattaCore
import Testing

/// The hold-one-out (#584, stage 2): the start suite's fleet sails a seed to T+60, then a held-out seat's start is planned
/// again against the other nine sailing their logged inputs, the rules on. Sailed on two seeds of the start pool, two
/// seats each, mixed fleets, at the start oracle tests' search (`StartOracleTests.options`).
@Suite struct StartHoldOneOutTests {
    static let options = StartOracleTests.options

    /// S1 and S6: gusty-offshore and light-and-patchy.
    static let seeds = ["S1", "S6"].map { name in StartTrialSeed.pool.first { $0.name == name }! }
    static let seats = [0, 7]

    /// Each seed's fleet, sailed once for the whole suite.
    static let fleets: [(log: RaceLog, tiers: [BotTier])] = {
        do {
            return try seeds.map { try HoldOneOut.fleet($0, tierMix: .mixed) }
        } catch {
            preconditionFailure("the fleet failed: \(error)")
        }
    }()

    static let report: HoldOneOutReport = {
        do {
            return try HoldOneOut.run(seeds, seats: seats, tierMix: .mixed, oracle: options)
        } catch {
            preconditionFailure("the hold-one-out failed: \(error)")
        }
    }()

    /// #584 stage 2: the frozen fleet is the logged one. A held-out seat sailing her own logged inputs again, every other
    /// seat its own, is the logged race to the bit at T+60, as `Replayer.replay` sails it: the nine replay as they raced.
    @Test func theRecordedFleetReplaysBitForBit() throws {
        for (seed, fleet) in zip(Self.seeds, Self.fleets) {
            #expect(fleet.log.finalTick == 60 * Race.tickRate, "the fleet sails to T+60")
            #expect(fleet.log.seatEvents.isEmpty, "no seat leaves a bots' race")
            let logged = try Replayer.digest(of: fleet.log)
            for seat in Self.seats {
                let course = try TimeTrialCourse(holdOut: fleet.log, seat: seat, seed: seed.trial)
                let replay = try StartTrial.replay(HoldOneOut.inputs(of: seat, in: fleet.log), course: course)
                #expect(replay.digest == logged, "\(seed.name) seat \(seat): the frozen fleet and her logged start are the log")
            }
        }
        #expect(Self.report.seeds.map(\.fleetDigest) == (try Self.fleets.map { try Replayer.digest(of: $0.log) }))
    }

    /// #584 stage 2: a hole she can only barge into is no hole. The oracle's start against the frozen fleet is never
    /// over the line at the gun and has no penalty called on her. (At this narrow search it may find no start at all
    /// against a fleet: S1 seat 0 doesn't by T+60 at a beam of 3, and starts on the gun at the tool's beam of 8.)
    @Test func theOracleNeverFoulsInAHole() {
        #expect(Self.report.seats.count == Self.seeds.count * Self.seats.count)
        for seed in Self.report.seeds {
            for seat in seed.seats {
                #expect(seat.oracle.penalties == 0, "\(seed.seed.name) seat \(seat.seat): \(seat.oracle.penalties) penalties")
                #expect(!seat.oracle.ocs, "\(seed.seed.name) seat \(seat.seat): over at the gun")
            }
        }
    }

    /// The loss table sums to the gap against the fleet too: the bot's and the oracle's columns, air and forced moves
    /// with them, each make its worth, and her metres behind the oracle are their difference.
    @Test func holdOneOutLossSumsToTheGap() {
        for seat in Self.report.seats {
            #expect(abs(seat.oracle.sum - seat.oracle.worth) < 1e-6)
            #expect(abs(seat.bot.sum - seat.bot.worth) < 1e-6)
            #expect(abs(seat.loss.sum - seat.loss.gap) < 1e-6, "seat \(seat.seat): \(seat.loss.values)")
            #expect(seat.oracle.air >= -1e-9 && seat.bot.air >= -1e-9, "the fleet's air only takes")
        }
        #expect(Self.report.lines.contains { $0.contains("gap-finding") })
    }

    @Test func holdOneOutOptionsParse() throws {
        let options = try TimeTrialOptions(arguments: ["--start", "--hold-one-out", "all", "--fleet", "mixed", "--seeds", "2"])
        #expect(options.holdOut == [] && options.fleet == .mixed)
        #expect(try TimeTrialOptions(arguments: ["--start", "--hold-one-out", "3", "--hold-one-out", "5"]).holdOut == [3, 5])
        #expect(throws: BotSuiteError.self) { try TimeTrialOptions(arguments: ["--hold-one-out", "3"]) }
        #expect(throws: BotSuiteError.self) { try TimeTrialOptions(arguments: ["--start", "--hold-one-out", "10"]) }
    }
}
