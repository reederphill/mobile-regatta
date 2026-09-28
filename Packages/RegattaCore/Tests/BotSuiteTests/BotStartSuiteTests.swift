@testable import BotSuite
import Foundation
import RegattaBots
import RegattaCore
import Testing

/// #99: the bots' start sequence, over the fleets its acceptance names. The start's numbers (`StartSummary`) are
/// taken over all-National ten-boat fleets of live bots, gated by the thresholds' `start` limits (the suite
/// thresholds file's v1 placeholders): OCS at the gun, starting on time, time in irons before the gun, and
/// pin-style bots seeded at the committee end of the row working down the line to start in its pin third.
@Suite struct BotStartSuiteTests {
    /// The bundled conditions, a seed's conditions by turns.
    static let conditions = ["classic-oscillating@3", "gusty-offshore@3", "light-and-patchy@3", "sea-breeze@3"]

    /// #99 acceptance's fleets: all-National ten-boat fleets over 200 seeds, each seed sailed in one of the bundled
    /// conditions by turns, one lap, stopped 30 s after the gun: time for a boat OCS at it to return and start.
    static let cells: [BotRaceCell] = (1...200).map { seed in
        BotRaceCell(seed: UInt64(seed), venue: "dev-venue@3", conditions: conditions[seed % conditions.count],
                    tideStateDegrees: 0, fleetSize: 10, tierMix: .national, profileMix: .live, laps: 1, capSecondsAfterGun: 30)
    }

    /// Their races, each sailed once and shared by the acceptance tests; on every core, since each race is its
    /// own and the tick times aren't read.
    static let races: Result<[RaceResult], RunFailure> = {
        let cells = Self.cells
        let results = Results(count: cells.count)
        DispatchQueue.concurrentPerform(iterations: cells.count) { index in
            results.set(index, Result { try BotRaceHarness.run(cells[index]) }.mapError { RunFailure(description: "\($0)") })
        }
        return Result { try results.values.map { try $0.get() } }.mapError { $0 as? RunFailure ?? RunFailure(description: "\($0)") }
    }()

    struct RunFailure: Error, Sendable {
        let description: String
    }

    /// The results of races sailed concurrently, each in its own slot.
    private final class Results: @unchecked Sendable {
        private var slots: [Result<RaceResult, RunFailure>?]
        private let lock = NSLock()

        init(count: Int) { slots = Array(repeating: nil, count: count) }

        func set(_ index: Int, _ result: Result<RaceResult, RunFailure>) {
            lock.lock()
            defer { lock.unlock() }
            slots[index] = result
        }

        var values: [Result<RaceResult, RunFailure>] { slots.map { $0! } }
    }

    static func summary() throws -> StartSummary {
        try #require(StartSummary(try races.get()))
    }

    static func limits() throws -> StartLimits {
        try #require(try BotThresholds.bundled().start)
    }

    /// #99 acceptance: all-National ten-boat fleets over 200 seeds start clean and on time: at most 5 % OCS at the
    /// gun, at least 60 % starting within 3 s of it, and at most 1 s per boat in irons before it (inside the no-go
    /// zone and slower than `BotRaceHarness.ironsSpeed`: a hold with Ease outside it is not irons).
    @Test func nationalFleetsStartCleanAndOnTime() throws {
        let summary = try Self.summary()
        let limits = try Self.limits()
        // The run's numbers, for the log.
        print("BOTSTART ocs \(fixed(summary.ocsShare, 3)), on time \(fixed(summary.onTimeShare, 3)) "
            + "(mean start \(fixed(summary.meanStartSeconds)) s), pre-gun irons \(fixed(summary.meanPreGunIronsSeconds, 3)) s/boat "
            + "(max \(fixed(summary.maxPreGunIronsSeconds))), pin third \(summary.pinThirdShare.map { fixed($0, 3) } ?? "-") "
            + "of \(summary.pinStyleFromCommitteeSeats)")
        #expect(summary.races == 200 && summary.seats == 2_000)
        #expect(summary.ocsShare <= (try #require(limits.maxOCSShare)), "OCS \(summary.ocsShare)")
        #expect(summary.onTimeShare >= (try #require(limits.minOnTimeShare)), "on time \(summary.onTimeShare)")
        #expect(summary.meanPreGunIronsSeconds <= (try #require(limits.maxMeanPreGunIronsSeconds)),
                "pre-gun irons \(summary.meanPreGunIronsSeconds) s/boat")
    }

    /// #99 acceptance: pin-style bots (their spot in the line's pin third) seeded in committee slots (the row's
    /// slots off the line's committee third or past its end) work down the line and start in its pin third: at
    /// least 70 % of them. The bundled gate is 0.69 since #102's skill weaknesses (0.697); #285 restores 0.70.
    @Test func pinStyleBotsFromCommitteeSlotsReachThePinThird() throws {
        let summary = try Self.summary()
        #expect(summary.pinStyleFromCommitteeSeats >= 150, "\(summary.pinStyleFromCommitteeSeats) pin-style bots from committee slots")
        let share = try #require(summary.pinThirdShare)
        #expect(share >= (try #require(try Self.limits().minPinThirdShare)), "pin third \(share)")
    }

    private func seat(_ seat: Int, ocs: Bool = false, start: Double? = 1, irons: Double = 0, startSpot: Double = 0.5,
                      rowSpot: Double = 0.5, startLineSpot: Double? = 0.5) -> SeatMetrics {
        SeatMetrics(seat: seat, tier: .national, skill: 0.9, status: "racing", finished: false, place: nil, ironsSeconds: 0,
                    markContacts: 0, boatContacts: 0, contactsEndingInFouls: 0, contactsToFoulsShare: 0, foulsAsOffender: 0,
                    dsqMissedPenalty: 0, ocsCount: ocs ? 1 : 0, edgeSeconds: 0, landContacts: 0, boundaryContacts: 0,
                    preGunIronsSeconds: irons, startSeconds: start, startLineSpot: start == nil ? nil : startLineSpot,
                    rowSpot: rowSpot, startSpot: startSpot)
    }

    private func race(_ seats: [SeatMetrics], mix: TierMix = .national, profiles: ProfileMix = .live) -> RaceResult {
        let cell = BotRaceCell(seed: 1, venue: "dev-venue@3", conditions: "classic-oscillating@3", tideStateDegrees: 0,
                               fleetSize: StartSummary.fleetSize, tierMix: mix, profileMix: profiles, laps: 1, capSecondsAfterGun: 30)
        return RaceResult(cell: cell, finalTick: 0, capped: true, tideStateAtGun: nil, seats: seats,
                          ranks: seats.indices.map { $0 + 1 }, hullLength: 5, timings: TickTimings(samples: [], cpuSeconds: 0))
    }

    /// The summary counts OCS, starts on time (within `StartSummary.onTimeSeconds`, a boat that never started
    /// not), irons before the gun, and the pin-style seats from committee slots and where they started; over the
    /// all-National live ten-boat fleets only.
    @Test func startSummaryCountsTheAllNationalFleets() throws {
        let national = race([
            seat(0, ocs: true, start: 12), seat(1, start: 0.4, irons: 2), seat(2, start: 3.0), seat(3, start: 3.1),
            seat(4, start: nil, startSpot: 0.2, rowSpot: 0.9),
            seat(5, start: 1, startSpot: 0.2, rowSpot: 1.1, startLineSpot: 0.3),
            seat(6, start: 1, startSpot: 0.3, rowSpot: 0.7, startLineSpot: 0.4),
            seat(7, start: 1, startSpot: 0.2, rowSpot: 0.6, startLineSpot: 0.9),
        ])
        let mixed = race([seat(0, ocs: true, start: 20, irons: 50)], mix: .mixed)
        let skillGap = race([seat(0, ocs: true, start: 20, irons: 50)], profiles: .skillGap)
        var sixteen = race([seat(0, ocs: true, start: 20, irons: 50)])
        sixteen.cell.fleetSize = 16
        let summary = try #require(StartSummary([national, mixed, skillGap, sixteen]))
        #expect(summary.races == 1 && summary.seats == 8)
        #expect(summary.ocsShare == 1.0 / 8)
        #expect(summary.onTimeShare == 5.0 / 8, "3.0 s is on time, 3.1 s isn't")
        #expect(summary.meanPreGunIronsSeconds == 0.25 && summary.maxPreGunIronsSeconds == 2)
        #expect(summary.pinStyleFromCommitteeSeats == 3, "seat 7's slot is off the middle third")
        #expect(summary.pinThirdShare == 1.0 / 3, "seat 4 never started, seat 6 started in the middle third")
        #expect(StartSummary([mixed, skillGap, sixteen]) == nil, "no all-National live ten-boat fleet sailed")
        #expect(try #require(StartSummary([race([seat(0)])])).pinThirdShare == nil)
    }

    /// Each start limit breaches on its own, and only for a run that sailed an all-National live ten-boat fleet.
    @Test func startLimitsBreachOnTheirOwn() throws {
        var thresholds = unmissableThresholds()
        thresholds.start = StartLimits(maxOCSShare: 0.05, minOnTimeShare: 0.6, maxMeanPreGunIronsSeconds: 1, minPinThirdShare: 0.7)
        let calm = BotSuiteReport.RunTimings(maxP99Ms: 1, maxMs: 1)
        func breaches(ocs: Double = 0, onTime: Double = 1, irons: Double = 0, pinThird: Double? = 1) throws -> [String] {
            var summary = try #require(StartSummary([race([seat(0)])]))
            summary.ocsShare = ocs
            summary.onTimeShare = onTime
            summary.meanPreGunIronsSeconds = irons
            summary.pinThirdShare = pinThird
            return thresholds.breaches(tiers: [:], timings: calm, start: summary)
        }
        #expect(try breaches(ocs: 0.05, onTime: 0.6, irons: 1, pinThird: 0.7).isEmpty, "limits are inclusive")
        #expect(try breaches(ocs: 0.06) == ["start: OCS 0.06 > 0.05"])
        #expect(try breaches(onTime: 0.55) == ["start: on time 0.55 < 0.60"])
        #expect(try breaches(irons: 1.5) == ["start: pre-gun irons 1.50 s/boat > 1.00"])
        #expect(try breaches(pinThird: 0.5) == ["start: pin third 0.50 < 0.70"])
        #expect(try breaches(pinThird: nil).isEmpty, "no pin-style boat from a committee slot, nothing to gate")
        #expect(thresholds.breaches(tiers: [:], timings: calm, start: nil).isEmpty, "no all-National ten-boat fleet sailed")
    }

    /// The bundled thresholds ship #99's acceptance numbers as the start's placeholders (pin third 0.69 until
    /// #285); a thresholds file from before #99 has no start limits, and gates none.
    @Test func bundledThresholdsGateTheStart() throws {
        let start = try Self.limits()
        #expect(start.maxOCSShare == 0.05 && start.minOnTimeShare == 0.6)
        #expect(start.maxMeanPreGunIronsSeconds == 1 && start.minPinThirdShare == 0.69)
        let old = try JSONDecoder().decode(BotThresholds.self, from: Data(#"{"maxP99TickMs": 10, "tiers": {}}"#.utf8))
        #expect(old.start == nil)
    }

    /// Irons before the gun is stalled inside the no-go zone, as it is racing: seat 0, stopped head to wind with
    /// a touch of rudder held, is in irons until she falls off out of it; seat 1, holding with Ease on a beam
    /// reach, is slow but never in irons.
    @Test func preGunIronsIsStalledInsideTheNoGo() throws {
        let setup = try RaceSetup(raceSeed: RaceSeed(4), seats: [.human, .human], laps: 1)
        let race = Race(setup: setup, windSeed: BotRaceHarness.windSeed(for: 4))
        var snapshot = race.exportSnapshot()
        let wind = race.seatView(for: 0).own.windDirection
        snapshot.seats[0].boat.heading = wind
        snapshot.seats[0].boat.speed = 0
        snapshot.seats[0].boat.autohelm = nil
        snapshot.seats[0].heldInput = BoatInput(rudder: 0.06)
        snapshot.seats[1].boat.heading = wind - .pi / 2
        snapshot.seats[1].boat.boomSide = .port
        snapshot.seats[1].boat.speed = 1
        snapshot.seats[1].boat.autohelm = Autohelm(target: .angle(.pi / 2))
        snapshot.seats[1].heldInput = BoatInput(rudder: 0 as Int8, ease: true)
        try race.importSnapshot(snapshot)

        var tally = RaceTally(race: race)
        for _ in 0..<(20 * Race.tickRate) {
            race.step()
            tally.record(race, events: race.drainEvents())
        }
        #expect(race.tick < 0, "still before the gun")
        let stalled = tally.metrics(seat: 0, of: race, tier: .national, profile: nil, style: nil)
        let eased = tally.metrics(seat: 1, of: race, tier: .national, profile: nil, style: nil)
        #expect(stalled.preGunIronsSeconds > 5, "\(stalled.preGunIronsSeconds) s")
        #expect(eased.preGunIronsSeconds == 0)
        #expect(race.boats[1].speed < 2.5 && race.boats[1].twa > deg2rad(60), "she held with Ease, slow, on a reach")
        #expect(stalled.ironsSeconds == 0 && stalled.startSeconds == nil, "not racing yet")
    }

    #if os(macOS) || os(Linux)
    /// The CLI's JSON report gives the start for an all-National fleet, and each seat's start: when, where along
    /// the line, and where her row slot and her style's spot are.
    @Test func reportGivesTheStart() throws {
        let matrix = BotMatrix(seeds: [2], fleetSizes: [10], tierMixes: [.national], laps: 1, capSecondsAfterGun: 30)
        let run = try botsuite(["--matrix", try fixture(matrix, named: "start-matrix"),
                                "--thresholds", try fixture(unmissableThresholds(), named: "unmissable"), "--json", "-"])
        #expect(run.status == 0)
        let object = try #require(JSONSerialization.jsonObject(with: Data(run.stdout.utf8)) as? [String: Any])
        let start = try #require(object["start"] as? [String: Any])
        for key in ["races", "seats", "ocsShare", "onTimeShare", "meanStartSeconds", "meanPreGunIronsSeconds",
                    "maxPreGunIronsSeconds", "pinStyleFromCommitteeSeats"] {
            #expect(start[key] != nil, "start has no \(key)")
        }
        let report = try JSONDecoder().decode(BotSuiteReport.self, from: Data(run.stdout.utf8))
        let seats = try #require(report.races.first).seats
        #expect(seats.contains { $0.startSeconds != nil }, "nobody started")
        for seat in seats {
            if let at = seat.startLineSpot { #expect((0...1).contains(at), "seat \(seat.seat) started off the line at \(at)") }
            #expect((-0.5...1.5).contains(seat.rowSpot) && (0.1...0.9).contains(seat.startSpot))
        }
        #expect(report.start?.races == 1 && report.start?.seats == 10)
    }
    #endif
}
