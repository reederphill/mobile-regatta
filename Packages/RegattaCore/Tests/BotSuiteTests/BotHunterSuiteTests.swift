@testable import BotSuite
import Foundation
import RegattaBots
import RegattaCore
import Testing

/// #355 acceptance: in the hunters mix (`ProfileMix.hunters`) the suite's hunter (`BotProfile.hunter`) sails to the edge
/// of the rules, so she draws calls under 16.1 or 17 only when she overdoes it: the count is reported, never asserted to
/// zero. The scan isn't vacuous: she held her hunting turn at a boat that must keep clear of her on `hunterTurnTicks`
/// ticks, and her hunting tells: the live bots draw more calls with a hunter the victim than with the same seats the
/// victim in the race's live twin (every seat a live bot).
@Suite struct BotHunterSuiteTests {
    @Test func huntersDrawRule16Or17CallsOnlyWhenTheyOverdoIt() throws {
        let matrix = BotMatrix(seeds: [1, 2, 3], fleetSizes: [5, 10, 16], tierMixes: [.national, .mixed],
                               profileMixes: [.hunters], laps: 1)
        var turnTicks = 0
        var overdone: [String] = []
        var byRule: [String: Int] = [:]
        var onHunters = 0, onSameSeatsInTwins = 0
        for cell in matrix.cells {
            let result = try BotRaceHarness.run(cell, cautiousSeats: [])
            var twinCell = cell
            twinCell.profileMix = .live
            turnTicks += try #require(result.hunterTurnTicks)
            let hunters = Set(result.seats.indices.filter { result.seats[$0].profile == .hunter })
            for call in try #require(result.ruleCalls) {
                if hunters.contains(call.victim) && !hunters.contains(call.offender) { onHunters += 1 }
                guard hunters.contains(call.offender) else { continue }
                byRule[call.rule, default: 0] += 1
                if call.rule == RacingRule.changingCourse.rawValue || call.rule == RacingRule.properCourse.rawValue {
                    overdone.append("seed \(cell.seed) \(cell.tierMix) \(cell.fleetSize) tick \(call.tick): \(call.rule) on \(call.offender)")
                }
            }
            // The twin's calls on the other seats, against the hunters' seats sailed by live bots.
            onSameSeatsInTwins += try Self.calls(in: twinCell, against: hunters)
        }
        print("BotHunterSuiteTests: \(matrix.cells.count) races, \(turnTicks) hunter turn ticks, calls on hunters "
            + "\(callsLine(byRule)); under 16.1/17 \(overdone.count): \(overdone); calls on live bots with a hunter the victim "
            + "\(onHunters), with the same seats the victim in the live twins \(onSameSeatsInTwins)")
        #expect(turnTicks > 0, "no hunter ever turned at a boat that must keep clear of her: the scan is vacuous")
        #expect(onHunters > onSameSeatsInTwins,
                "hunting changed nothing: \(onHunters) calls with a hunter the victim, \(onSameSeatsInTwins) with the same seats live")
    }

    /// Rule calls in `cell`'s race with a seat of `victims` the victim and none of them the offender.
    static func calls(in cell: BotRaceCell, against victims: Set<Int>) throws -> Int {
        var count = 0
        _ = try BotRaceHarness.run(cell, cautiousSeats: []) { _, events in
            for event in events {
                guard case .ruleCall(let call) = event.kind else { continue }
                if victims.contains(call.victim) && !victims.contains(call.offender) { count += 1 }
            }
        }
        return count
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
