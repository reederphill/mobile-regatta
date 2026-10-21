@testable import BotSuite
import Foundation
import RegattaBots
import RegattaCore
import Testing

/// #276 PR 1: the start-strategy rows (`StartStrategySummary`), each as the #276 brief's `startplan.py` defines it, on
/// records written out by hand; and the harness's watch of the start (`StartStrategyTally`) on a race it sails.
@Suite struct BotSuiteStartStrategyTests {
    private func seat(_ seat: Int, start: Double? = 1, spot: Double? = 0.5, approach: ApproachKind? = .other,
                      speed: Double? = 0.5, over: Bool = false, calls: Int = 0) -> SeatMetrics {
        var metrics = SeatMetrics(
            seat: seat, tier: .national, skill: 0.9, status: "racing", finished: false, place: nil, ironsSeconds: 0,
            markContacts: 0, boatContacts: 0, contactsEndingInFouls: 0, contactsToFoulsShare: 0, foulsAsOffender: 0,
            dsqMissedPenalty: 0, ocsCount: 0, edgeSeconds: 0, landContacts: 0, boundaryContacts: 0, preGunIronsSeconds: 0,
            startSeconds: start, startLineSpot: start == nil ? nil : spot)
        metrics.approachKind = approach
        metrics.speedAtGunShare = speed
        metrics.overLineAtGun = over
        metrics.preGunCalls = calls
        return metrics
    }

    private func race(_ seats: [SeatMetrics], bias: Double?, before: [Double]? = nil, calls: [Double] = [],
                      conditions: String = "classic-oscillating@3") -> RaceResult {
        let cell = BotRaceCell(seed: 1, venue: "dev-venue@3", conditions: conditions, tideStateDegrees: 0,
                               fleetSize: seats.count, tierMix: .national, profileMix: .live, laps: 1, capSecondsAfterGun: 30)
        var result = RaceResult(cell: cell, finalTick: 0, capped: true, tideStateAtGun: nil, seats: seats,
                                ranks: seats.indices.map { $0 + 1 }, hullLength: 5, timings: TickTimings(samples: [], cpuSeconds: 0))
        result.lineBiasAtGunDegrees = bias
        result.lineBiasBeforeGunDegrees = before ?? bias.map { [$0] }
        result.preGunCallSpots = calls
        return result
    }

    // MARK: - The line's bias

    /// The bias is the line's angle off square to the wind, positive when the wind has gone round towards the committee
    /// boat: that end is then up the wind (`BotBrain.readLineBias`'s sign).
    @Test func lineBiasIsPositiveWhenTheCommitteeEndIsFavoured() {
        let along = Vec2(1, 0) // the committee boat east of the pin; square to the line is a wind from the north
        #expect(abs(lineBiasDegrees(along: along, windDirection: 0)) < 1e-9)
        #expect(abs(lineBiasDegrees(along: along, windDirection: deg2rad(10)) - 10) < 1e-9, "veered towards the committee boat")
        #expect(abs(lineBiasDegrees(along: along, windDirection: deg2rad(-7)) + 7) < 1e-9, "backed towards the pin")
        #expect(abs(lineBiasDegrees(along: Vec2(-1, 0), windDirection: deg2rad(10)) + 10) < 1e-9, "the ends swapped")
    }

    // MARK: - Approach kinds

    /// A starboard track a second at a time from the gun's back: `depth` hull lengths down, eased or not.
    private func track(depth: Double = 2, eased: Bool = false, seconds: Int = 60) -> [StartSample?] {
        (0...StartStrategyTally.windowSeconds).map { second in
            second > seconds ? nil
                : StartSample(depth: depth, starboard: true, speedShare: 0.5, relativeWindDegrees: 40, eased: eased)
        }
    }

    /// Each kind by its own rule, in `startplan.py`'s order: port at T−10 or T−5 first, then a deep run, then the eased
    /// hold near the line; none for a boat not sampled from T−59.
    @Test func approachKindIsReadInItsOrder() {
        #expect(ApproachKind.read(track(seconds: 58)) == nil, "not on the water at T-59")
        #expect(ApproachKind.read(track()) == .other)

        var port = track(eased: true)
        port[5]?.starboard = false
        #expect(ApproachKind.read(port) == .port)
        port = track()
        port[10]?.starboard = false
        port[25]?.depth = 9
        port[20]?.relativeWindDegrees = -150
        #expect(ApproachKind.read(port) == .port, "port at T-10 before a deep run")

        var deep = track(eased: true)
        deep[25]?.depth = 8.5
        deep[20]?.relativeWindDegrees = -150
        #expect(ApproachKind.read(deep) == .deepRun)
        var shallow = deep
        shallow[25]?.depth = 8
        #expect(ApproachKind.read(shallow) == .easedHold, "8 L is not deeper than 8 L")
        var lateRun = deep
        lateRun[20]?.relativeWindDegrees = 40
        lateRun[9]?.relativeWindDegrees = 150
        #expect(ApproachKind.read(lateRun) == .easedHold, "a run only after T-10 isn't the deep run's")
        var earlyDeep = track(eased: true)
        earlyDeep[31]?.depth = 12
        earlyDeep[31]?.relativeWindDegrees = 150
        #expect(ApproachKind.read(earlyDeep) == .easedHold, "deep before T-30 isn't counted")

        // Eased more than half the last 31 samples (T-30 to the gun), and under 4 L down at T-10.
        var hold = track()
        for second in 0...15 { hold[second]?.eased = true }
        #expect(ApproachKind.read(hold) == .easedHold, "16 of 31 eased")
        hold[15]?.eased = false
        #expect(ApproachKind.read(hold) == .other, "15 of 31 eased")
        var deepAtTen = track(eased: true)
        deepAtTen[10]?.depth = 4
        #expect(ApproachKind.read(deepAtTen) == .other, "4 L down at T-10")
    }

    // MARK: - The summary's rows

    /// Starters at the favoured end's half and third (a sixth of the line or more from the middle), by |bias| bin with
    /// the bins' edges in the higher bin; on time over every seat; a boat that never started not a starter.
    @Test func favouredEndSharesAreBinnedByBias() throws {
        let committee = race([seat(0, spot: 0.9), seat(1, spot: 0.6), seat(2, start: 4, spot: 0.4), seat(3, start: nil)], bias: 5)
        let pin = race([seat(0, spot: 0.2), seat(1, spot: 0.5)], bias: -2)
        let summary = try #require(StartStrategySummary([committee, pin, race([seat(0)], bias: nil)]))
        #expect(summary.races == 2, "a race the harness didn't watch isn't counted")
        func row(_ bin: String) throws -> StartStrategySummary.BiasRow { try #require(summary.byBias.first { $0.bin == bin }) }
        #expect(summary.byBias.map(\.bin) == ["< 2", "2-5", "5-10", ">= 10", ">= 5", "all"])
        let five = try row("5-10")
        #expect(five.races == 1 && five.seats == 4 && five.starters == 3)
        #expect(five.favouredHalfShare == 2.0 / 3 && five.favouredThirdShare == 1.0 / 3)
        #expect(five.onTimeShare == 2.0 / 4, "a start 4 s after the gun is late; one never started")
        #expect(try row(">= 5") == StartStrategySummary.BiasRow(bin: ">= 5", races: 1, seats: 4, starters: 3,
                                                                  favouredHalfShare: five.favouredHalfShare,
                                                                  favouredThirdShare: five.favouredThirdShare,
                                                                  onTimeShare: five.onTimeShare))
        let two = try row("2-5")
        #expect(two.races == 1 && two.favouredHalfShare == 0.5 && two.favouredThirdShare == 0.5,
                "the pin end favoured: 0.2 is in its third, the middle in neither half")
        #expect(try row("< 2").races == 0 && row("all").starters == 5)
        #expect(summary.biasMax == 5)
    }

    /// The slope of start spot on the bias at the gun, every starter a point.
    @Test func spotSlopeIsTheLeastSquaresFit() throws {
        let summary = try #require(StartStrategySummary([
            race([seat(0, spot: 0.5), seat(1, spot: 0.7)], bias: 10),
            race([seat(0, spot: 0.4), seat(1, spot: 0.4), seat(2, start: nil)], bias: 0),
        ]))
        // x: 10, 10, 0, 0; y: 0.5, 0.7, 0.4, 0.4. Means 5 and 0.5; Σ(dx dy) = 5 × 0 + 5 × 0.2 + 5 × 0.1 + 5 × 0.1 = 2,
        // Σ dx² = 100.
        #expect(abs(summary.spotSlopePerDegree - 0.02) < 1e-12)
        #expect(leastSquaresSlope([(1, 1), (1, 2)]) == 0, "no spread in the bias")
    }

    /// Each race's start spots: their population SD, and the most of the fleet (every seat, starter or not) in a fifth
    /// of the line, its windows a twentieth apart from the pin to 0.8, each closed at its pin end; races with fewer
    /// than three starters left out.
    @Test func startSpreadIsPerRace() throws {
        let spread = race([seat(0, spot: 0.2), seat(1, spot: 0.3), seat(2, spot: 0.4), seat(3, spot: 0.9), seat(4, start: nil)],
                          bias: 0)
        let thin = race([seat(0, spot: 0.1), seat(1, spot: 0.9)], bias: 0)
        let summary = try #require(StartStrategySummary([spread, thin]))
        #expect(summary.spreadRaces == 1)
        let spots = [0.2, 0.3, 0.4, 0.9], mean = spots.reduce(0, +) / 4
        let sd = (spots.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / 4).squareRoot()
        #expect(summary.spotSD?.median == sd)
        #expect(summary.densestFifth?.median == 2.0 / 5, "0.2 and 0.3 in [0.2, 0.4); 0.4 is not")
        #expect(summary.densestFifthMax == 2.0 / 5)
    }

    /// Speed at the gun over close-hauled: the on-time starters whose approach was read; the share at 0.8 or more.
    @Test func speedAtTheGunIsTheOnTimeStarters() throws {
        let summary = try #require(StartStrategySummary([race([
            seat(0, speed: 0.9), seat(1, speed: 0.8), seat(2, speed: 0.5), seat(3, speed: 0.4),
            seat(4, start: 3.1, speed: 1), seat(5, approach: nil, speed: 1), seat(6, start: nil, speed: 1),
        ], bias: 0)]))
        #expect(summary.onTimeStarters == 4)
        #expect(summary.speedAtGun?.median == 0.8, "the nearest rank, 1.5 rounded half to even: index 2 of 4")
        #expect(summary.speedAtGun?.p10 == 0.4 && summary.speedAtGun?.p90 == 0.9)
        #expect(summary.fullSpeedShare == 0.5)
    }

    /// Pre-gun calls by the offender's third of the line, a third's edge in the third towards the committee boat, and
    /// past the ends in the end thirds.
    @Test func preGunCallsAreCountedByThird() throws {
        let summary = try #require(StartStrategySummary([
            race([seat(0)], bias: 0, calls: [-0.2, 0.1, 1.0 / 3, 0.5, 2.0 / 3, 0.9, 1.3]),
        ]))
        #expect(summary.preGunCalls == 7)
        #expect(summary.pinThirdCalls == 2 && summary.middleThirdCalls == 2 && summary.committeeThirdCalls == 3)
    }

    /// Each approach kind's seats: share of those read, on time, mean start (never as 60 s, later starts capped at it),
    /// over the line at the gun, calls a seat and the on-time starters' speed at the gun.
    @Test func approachRowsAreEachKindsSeats() throws {
        let summary = try #require(StartStrategySummary([race([
            seat(0, approach: .port, speed: 0.7, calls: 2), seat(1, start: nil, approach: .port, calls: 1),
            seat(2, start: 70, approach: .port, over: true), seat(3, approach: .easedHold, speed: 0.6), seat(4, approach: nil),
        ], bias: 0)]))
        #expect(summary.approaches.map(\.kind) == ApproachKind.allCases.map(\.rawValue))
        let port = try #require(summary.approaches.first { $0.kind == ApproachKind.port.rawValue })
        #expect(port.seats == 3 && port.share == 3.0 / 4)
        #expect(port.onTimeShare == 1.0 / 3 && port.meanStartSeconds == (1 + 60 + 60) / 3.0)
        #expect(port.overAtGunShare == 1.0 / 3 && port.callsPerSeat == 1 && port.speedAtGunMedian == 0.7)
        let deep = try #require(summary.approaches.first { $0.kind == ApproachKind.deepRun.rawValue })
        #expect(deep.seats == 0 && deep.speedAtGunMedian == nil)
    }

    /// By conditions: of the races with |bias at the gun| ≥ 5°, the share whose bias some seconds before had the gun's
    /// sign (0 counted with the committee end); the swing (largest less smallest over the 60 s) a median of every race.
    @Test func biasPredictabilityIsByConditions() throws {
        func before(gun: Double, at: [Int: Double]) -> [Double] {
            (0...60).map { at[$0] ?? gun }
        }
        let agrees = race([seat(0)], bias: 6, before: before(gun: 6, at: [30: -4, 10: 0, 59: 20]))
        let disagrees = race([seat(0)], bias: -8, before: before(gun: -8, at: [30: -1, 10: 2, 45: 3]))
        let small = race([seat(0)], bias: 1, before: before(gun: 1, at: [20: 12]))
        let short = race([seat(0)], bias: 7, before: [7, 7, 7, 7, 7, 7, 7], conditions: "sea-breeze@3")
        let summary = try #require(StartStrategySummary([agrees, disagrees, small, short]))
        #expect(summary.predictability.map(\.conditions) == ["classic-oscillating@3", "sea-breeze@3"])
        let classic = summary.predictability[0]
        #expect(classic.readableRaces == 2)
        // T-45, T-30, T-20, T-15, T-10, T-5.
        #expect(classic.agreement == [0.5, 0.5, 1, 1, 0.5, 1])
        #expect(classic.swingMedian == 11, "swings 24, 11 and 11")
        let seaBreeze = summary.predictability[1]
        #expect(seaBreeze.agreement == [nil, nil, nil, nil, nil, 1], "sampled only to T-6")
        #expect(middleValue([1, 4, 2, 3]) == 2.5 && middleValue([]) == 0)
        #expect(nearestRank([1, 2, 3, 4, 5, 6], 0.5) == 3, "2.5 rounds to 2")
        #expect(nearestRank([1, 2, 3, 4], 0.5) == 3, "1.5 rounds to 2")
    }

    // MARK: - The harness

    /// The harness watches every race's start: each seat sampled from T−59 to the gun reads an approach and a speed at
    /// the gun, the bias is sampled each second to the gun (index 0 the gun's), and the pre-gun calls' spots are the
    /// seats' calls. The text prints the rows.
    @Test func harnessWatchesTheStart() throws {
        let cell = BotRaceCell(seed: 3, venue: "dev-venue@3", conditions: "classic-oscillating@3", tideStateDegrees: 0,
                               fleetSize: 6, tierMix: .national, profileMix: .live, laps: 1, capSecondsAfterGun: 5)
        let result = try BotRaceHarness.run(cell)
        let before = try #require(result.lineBiasBeforeGunDegrees)
        #expect(before.count >= 60, "every second from T-59 to the gun")
        #expect(result.lineBiasAtGunDegrees == before.first)
        #expect(before.allSatisfy { abs($0) <= 90 })
        #expect(result.seats.allSatisfy { $0.approachKind != nil && $0.speedAtGunShare != nil && $0.overLineAtGun != nil })
        #expect(result.preGunCallSpots?.count == result.seats.reduce(0) { $0 + ($1.preGunCalls ?? 0) })
        let summary = try #require(StartStrategySummary([result]))
        #expect(summary.races == 1 && summary.approaches.reduce(0) { $0 + $1.seats } == 6)
        #expect(summary.lines.first?.hasPrefix("start strategies (#276): 1 races") == true)
        // Report-only: the decoded report gives back what the harness wrote.
        let decoded = try JSONDecoder().decode(RaceResult.self, from: JSONEncoder().encode(result))
        #expect(decoded.lineBiasBeforeGunDegrees == before && decoded.seats.map(\.approachKind) == result.seats.map(\.approachKind))
    }
}
