@testable import BotSuite
import Foundation
import RegattaBots
import RegattaCore
import Testing

/// #355 acceptance: in the hunters mix (`ProfileMix.hunters`) the suite's hunter (`BotProfile.hunter`) sails to the edge
/// of the rules, so she draws calls under 16.1 or 17 only when she overdoes it: the count is reported, never asserted to
/// zero. The scan isn't vacuous (#472), measured on her own turns and not on the calls the live bots draw: in most
/// races she held her hunting turn at a boat that must keep clear of her (`hunterTurnTicks`), she turned on those ticks
/// (`HunterTurns.radians`), and she turned inside rule 16.1's course-change rate on all but a few of them.
///
/// Not the calls on the live bots with a hunter the victim against the same seats of the live twins, #355's first
/// measure: hunting inside rule 16.1's rate draws next to none (the live bots keep clear), and most of those calls
/// fall before the start, where she doesn't hunt. Over 18 races on skiff@8, four disjoint seed sets: 24, 15, 21, 22
/// calls against 24, 12, 22, 16 in the twins, and 24, 15, 18, 17 with her hunting switched off.
@Suite struct BotHunterSuiteTests {
    /// Of the races, the share in which a hunter turned at a boat at least: 16 to 18 of 18 on four seed sets (a hunter
    /// alone in a fleet of five can sail a race with no boat to hunt).
    static let minRacesTurningShare = 2.0 / 3
    /// Hunting-turn ticks a race, at least, over the scan: 189 to 229 measured (3393 to 4116 over 18 races).
    static let minTurnTicksPerRace = 90
    /// Of rule 16.1's course-change rate, the least she turns at on a hunting-turn tick, on average: she turns at
    /// `BotBrain.Hunter.rateShare` (0.8) of it or her held rudder's rate; 0.75 to 0.77 measured.
    static let minMeanRateShare = 0.4
    /// Of her hunting-turn ticks, the share faster than rule 16.1's rate at most: 0.014 to 0.027 measured on skiff@8
    /// (she carries the rate of a turn by hand into a hunting turn), each a turn rule 16.1 can be called on.
    static let maxOverRateShare = 0.06

    @Test func huntersDrawRule16Or17CallsOnlyWhenTheyOverdoIt() throws {
        let scan = try Self.scan(seeds: Self.seeds)
        print("BotHunterSuiteTests: \(scan.line)")
        #expect(Double(scan.racesTurning) >= Self.minRacesTurningShare * Double(scan.races),
                "hunters turned at a boat that must keep clear of them in \(scan.racesTurning) of \(scan.races) races")
        #expect(scan.turnTicks >= Self.minTurnTicksPerRace * scan.races,
                "hunters barely turned at a boat that must keep clear of them: the scan is vacuous (\(scan.turnTicks) ticks)")
        let rate = try #require(scan.courseChangeRate)
        #expect(scan.meanRate >= Self.minMeanRateShare * rate && scan.meanRate <= rate,
                "hunting turns at \(fixed(rad2deg(scan.meanRate), 1)) deg/s on average, rule 16.1's rate \(fixed(rad2deg(rate), 1))")
        #expect(Double(scan.ticksOverRate) <= Self.maxOverRateShare * Double(scan.turnTicks),
                "\(scan.ticksOverRate) of \(scan.turnTicks) hunting-turn ticks faster than rule 16.1's rate")
    }

    static let seeds: [UInt64] = [1, 2, 3]

    /// The hunters mix over `seeds`: three fleet sizes, two tier mixes, a race each.
    struct Scan {
        var races = 0, racesTurning = 0
        var turnTicks = 0, ticksOverRate = 0
        var radians = 0.0, peakRate = 0.0
        var courseChangeRate: Double?
        var onHunters = 0
        var hunterCalls: [String: Int] = [:]
        var overdone: [String] = []

        /// Radians a second she turned at over her hunting-turn ticks.
        var meanRate: Double { turnTicks == 0 ? 0 : radians / Double(turnTicks) * Double(Race.tickRate) }

        var line: String {
            "\(races) races, \(racesTurning) with hunter turn ticks, \(turnTicks) in all at \(fixed(rad2deg(meanRate), 1)) deg/s "
                + "(\(ticksOverRate) over rule 16.1's \(courseChangeRate.map { fixed(rad2deg($0), 1) } ?? "-"), peak "
                + "\(fixed(rad2deg(peakRate), 1))); calls on hunters \(callsLine(hunterCalls)); under 16.1/17 \(overdone.count): "
                + "\(overdone); calls on live bots with a hunter the victim \(onHunters)"
        }
    }

    static func scan(seeds: [UInt64]) throws -> Scan {
        let matrix = BotMatrix(seeds: seeds, fleetSizes: [5, 10, 16], tierMixes: [.national, .mixed],
                               profileMixes: [.hunters], laps: 1)
        var scan = Scan()
        for cell in matrix.cells {
            let result = try BotRaceHarness.run(cell, cautiousSeats: [])
            let ticks = try #require(result.hunterTurnTicks)
            let turns = try #require(result.hunterTurns)
            scan.races += 1
            if ticks > 0 { scan.racesTurning += 1 }
            scan.turnTicks += ticks
            scan.ticksOverRate += turns.ticksOverCourseChangeRate
            scan.radians += turns.radians
            scan.peakRate = max(scan.peakRate, turns.peakRate)
            scan.courseChangeRate = turns.courseChangeRate
            let hunters = Set(result.seats.indices.filter { result.seats[$0].profile == .hunter })
            for call in try #require(result.ruleCalls) {
                if hunters.contains(call.victim) && !hunters.contains(call.offender) { scan.onHunters += 1 }
                guard hunters.contains(call.offender) else { continue }
                scan.hunterCalls[call.rule, default: 0] += 1
                if call.rule == RacingRule.changingCourse.rawValue || call.rule == RacingRule.properCourse.rawValue {
                    scan.overdone.append("seed \(cell.seed) \(cell.tierMix) \(cell.fleetSize) tick \(call.tick): \(call.rule) on \(call.offender)")
                }
            }
        }
        return scan
    }
}

/// #355: the hunters mix's seats, and its summary over a run (`HuntersSummary`).
@Suite struct BotSuiteHuntersTests {
    /// One hunter in a fleet under ten (two-boat races included), two in a fleet of ten or more, half the fleet apart,
    /// rotating with the seed; every other seat a live bot.
    @Test func huntersMixSeatsOneOrTwoHunters() {
        for (fleet, hunters) in [(2, 1), (5, 1), (10, 2), (16, 2)] {
            for seed: UInt64 in 1...6 {
                let seats = (0..<fleet).filter { ProfileMix.hunters.profile(ofSeat: $0, seed: seed, fleetSize: fleet) == .hunter }
                #expect(seats.count == hunters, "fleet \(fleet) seed \(seed): \(seats)")
                #expect((0..<fleet).allSatisfy { [nil, .hunter].contains(ProfileMix.hunters.profile(ofSeat: $0, seed: seed, fleetSize: fleet)) })
                if hunters == 2 { #expect(seats[1] - seats[0] == fleet / 2) }
            }
            let first = { (seed: UInt64) in
                (0..<fleet).first { ProfileMix.hunters.profile(ofSeat: $0, seed: seed, fleetSize: fleet) == .hunter }
            }
            #expect(first(1) != first(2), "fleet \(fleet): the hunter's seat rotates with the seed")
        }
        // A cell gives its seats the mix's profiles for its fleet.
        let cell = BotRaceCell(seed: 3, venue: "dev-venue@7", conditions: "sea-breeze@7", tideStateDegrees: 0, fleetSize: 10,
                               tierMix: .national, profileMix: .hunters, laps: 1, capSecondsAfterGun: 60)
        #expect((0..<10).filter { cell.profile(ofSeat: $0) == .hunter }.count == 2)
        #expect(ProfileMix.hunters.conditionsID == nil)
    }

    private func seat(_ seat: Int, _ profile: BotProfile?, place: Int?, calls: [String: Int] = [:]) -> SeatMetrics {
        var metrics = SeatMetrics(seat: seat, tier: .national, profile: profile, skill: 0.9,
                                  status: place == nil ? "racing" : "finished", finished: place != nil, place: place,
                                  ironsSeconds: 0, markContacts: 0, boatContacts: 0, contactsEndingInFouls: 0,
                                  contactsToFoulsShare: 0, foulsAsOffender: calls.values.reduce(0, +), dsqMissedPenalty: 0,
                                  ocsCount: 0, edgeSeconds: 0, landContacts: 0, boundaryContacts: 0, beats: [])
        metrics.callsByRule = calls
        return metrics
    }

    private func race(_ seats: [SeatMetrics], mix: ProfileMix, calls: [RuleCallRecord]? = nil, turnTicks: Int? = nil) -> RaceResult {
        let cell = BotRaceCell(seed: 1, venue: "dev-venue@7", conditions: "sea-breeze@7", tideStateDegrees: 0,
                               fleetSize: seats.count, tierMix: .national, profileMix: mix, laps: 1, capSecondsAfterGun: 60)
        var result = RaceResult(cell: cell, finalTick: 0, capped: false, tideStateAtGun: nil, seats: seats,
                                ranks: seats.indices.map { $0 + 1 }, hullLength: 5, timings: TickTimings(samples: [], cpuSeconds: 0))
        result.ruleCalls = calls
        result.hunterTurnTicks = turnTicks
        return result
    }

    /// Calls split by who called on whom, the overdone count (16.1 and 17 on hunters), and the live seats against the
    /// same seats of the live twin; the hunters races stay out of the gated tiers. No hunters race, no summary.
    @Test func huntersSummarySplitsCallsAndComparesTheLiveTwin() throws {
        let calls = [
            RuleCallRecord(rule: "11", offender: 1, victim: 0, tick: 10),
            RuleCallRecord(rule: "11", offender: 1, victim: 0, tick: 20),
            RuleCallRecord(rule: "17", offender: 0, victim: 1, tick: 30),
            RuleCallRecord(rule: "16.1", offender: 0, victim: 2, tick: 40),
            RuleCallRecord(rule: "10", offender: 2, victim: 1, tick: 50),
        ]
        let hunted = race([seat(0, .hunter, place: 1, calls: ["17": 1, "16.1": 1]), seat(1, nil, place: 3, calls: ["11": 2]),
                           seat(2, nil, place: 2, calls: ["10": 1])], mix: .hunters, calls: calls, turnTicks: 42)
        let twin = race([seat(0, nil, place: 3), seat(1, nil, place: 1), seat(2, nil, place: nil)], mix: .live)
        let summary = try #require(HuntersSummary([hunted, twin]))
        #expect(summary.races == 1 && summary.twinRaces == 1)
        #expect(summary.liveOnHunter == ["11": 2])
        #expect(summary.hunterOnLive == ["17": 1, "16.1": 1])
        #expect(summary.liveOnLive == ["10": 1] && summary.hunterOnHunter.isEmpty)
        #expect(summary.overdoneCalls == 2)
        #expect(summary.hunterTurnTicks == 42)
        #expect(summary.live.seats == 2 && summary.live.finished == 2)
        #expect(summary.twinLive?.seats == 2 && summary.twinLive?.finished == 1, "seats 1 and 2 of the twin")
        // Places ranked among the live seats only, by order of finish: seats 2 then 1 home (ranks 1, 2); in the twin
        // seat 1 home, seat 2 not (rank 1, one DNF).
        #expect(summary.liveMeanPlace == 1.5 && summary.twinLiveMeanPlace == 1)
        #expect(summary.liveDNFs == 0 && summary.twinLiveDNFs == 1)
        #expect(HuntersSummary([twin]) == nil)

        // The gated tiers are the live seats of the races without hunters only.
        let report = BotSuiteReport(matrix: BotMatrix(seeds: [1], fleetSizes: [3], profileMixes: [.live, .hunters]),
                                    thresholds: BotThresholds(tiers: [:], maxP99TickMs: .greatestFiniteMagnitude), races: [hunted, twin])
        #expect(report.tiers["national"]?.seats == 3)
        #expect(report.profiles["hunter"]?.seats == 1)
        #expect(report.hunters != nil)
        #expect(report.lines.contains { $0.hasPrefix("hunters: 1 races") })
    }
}
