@testable import BotSuite
import RegattaBots
import RegattaCore
import Foundation
import Testing

/// #484: the parity mix (#426 Q1, ADR 0007's 2×2) and its report, on seats built by hand.
@Suite struct BotSuiteParityTests {
    private func cell(seed: UInt64 = 1, conditions: String = "classic-oscillating@7") -> BotRaceCell {
        BotRaceCell(seed: seed, venue: "dev-venue@7", conditions: conditions, tideStateDegrees: 0, fleetSize: 2,
                    tierMix: .national, profileMix: .parity, laps: 1, capSecondsAfterGun: 60)
    }

    /// A seat of `profile` that sailed one beat and one run in `beat` and `run` seconds, 400 m each, and finished in
    /// `place` after `onCourse` seconds; unfinished with `metresToGo` to go when `place` is nil.
    private func seat(_ seat: Int, _ profile: BotProfile, place: Int?, metresToGo: Double? = nil, onCourse: Double = 600,
                      beat: Double = 100, run: Double = 80) -> SeatMetrics {
        var metrics = SeatMetrics(seat: seat, tier: .national, profile: profile, skill: 0.9,
                                  status: place == nil ? "racing" : "finished", finished: place != nil, place: place,
                                  ironsSeconds: 0, markContacts: 0, boatContacts: 0, contactsEndingInFouls: 0,
                                  contactsToFoulsShare: 0, foulsAsOffender: 0, dsqMissedPenalty: 0, ocsCount: 0,
                                  edgeSeconds: 0, landContacts: 0, boundaryContacts: 0)
        metrics.beats = [BeatSplit(seconds: beat, metres: 400)]
        metrics.runs = [RunSplit(seconds: run, metres: 400)]
        metrics.onCourseSeconds = onCourse
        metrics.metresToFinish = metresToGo
        return metrics
    }

    /// A parity race: seat 0 `first`, seat 1 `second`, seat 0 ahead by `lead` seconds a leg and at the finish.
    private func race(_ first: BotProfile, _ second: BotProfile, firstWins: Bool = true, lead: Double = 4,
                      conditions: String = "classic-oscillating@7", seed: UInt64 = 1) -> RaceResult {
        let a = seat(0, first, place: firstWins ? 1 : 2, onCourse: 600, beat: 100, run: 80)
        let b = seat(1, second, place: firstWins ? 2 : 1, onCourse: 600 + lead, beat: 100 + lead, run: 80 + lead)
        return raceResult(cell: cell(seed: seed, conditions: conditions), seats: [a, b])
    }

    /// The deal: in two-boat races every ordered pair of the 2×2's profiles once in each 12 seeds, the pair as written on
    /// an even `seed % 12` and the other way round on the odd one after; in a bigger fleet the four by turns.
    @Test func dealSailsEveryOrderedPairOncePerTwelveSeeds() {
        let profiles = ProfileMix.parityProfiles
        #expect(profiles == [.clubSteering, .executor, .tacticianClubSteering, .tactician])
        let expected = Set(profiles.flatMap { a in profiles.filter { $0 != a }.map { [a, $0] } })
        #expect(expected.count == ProfileMix.parityDeals)
        for start in [UInt64(1), 13, 385] {
            let dealt = (start..<start + 12).map { seed in
                (0..<2).compactMap { ProfileMix.parity.profile(ofSeat: $0, seed: seed, fleetSize: 2) }
            }
            #expect(Set(dealt) == expected && dealt.count == 12, "seeds \(start)…: \(dealt)")
        }
        #expect((0..<2).compactMap { ProfileMix.parity.profile(ofSeat: $0, seed: 12, fleetSize: 2) } == [.clubSteering, .executor])
        #expect((0..<2).compactMap { ProfileMix.parity.profile(ofSeat: $0, seed: 13, fleetSize: 2) } == [.executor, .clubSteering])
        #expect((0..<2).compactMap { ProfileMix.parity.profile(ofSeat: $0, seed: 23, fleetSize: 2) }
            == [.tactician, .tacticianClubSteering])
        #expect(Set((0..<4).compactMap { ProfileMix.parity.profile(ofSeat: $0, seed: 5, fleetSize: 4) }) == Set(profiles))
        #expect(!ProfileMix.parity.gatesLiveTiers && ProfileMix.parity.tierMix == .national && ProfileMix.parity.conditionsID == nil)
    }

    /// The mix refuses a seed count that deals the ordered pairs unevenly in two-boat races, a three-boat fleet (one of the
    /// four would sit out), and a class that doesn't steer by hand.
    @Test func parityRefusesUnevenDealsSmallFleetsAndAutohelms() throws {
        for seeds in [1, 10, 13, 25] {
            #expect(throws: BotSuiteError.self, "\(seeds) seeds") {
                try BotSuiteOptions(arguments: ["--profile-mix", "parity", "--fleet-size", "2", "--seeds", "\(seeds)"]).matrix()
            }
        }
        let matrix = try BotSuiteOptions(arguments: ["--profile-mix", "parity", "--fleet-size", "2", "--seeds", "24"]).matrix()
        #expect(matrix.profileMixes == [.parity] && matrix.cells.allSatisfy { $0.tierMix == .national && $0.fleetSize == 2 })
        _ = try BotSuiteOptions(arguments: ["--profile-mix", "parity", "--fleet-size", "4", "--seeds", "5"]).matrix()
        #expect(throws: BotSuiteError.self) {
            try BotSuiteOptions(arguments: ["--profile-mix", "parity", "--fleet-size", "3", "--seeds", "12"]).matrix()
        }
        #expect(throws: BotSuiteError.self) {
            try BotMatrix(seeds: Array(1...12), fleetSizes: [2], tierMixes: [.national], profileMixes: [.parity],
                          boatClass: "skiff@6").validate()
        }
        try BotMatrix(seeds: Array(1...12), fleetSizes: [2], tierMixes: [.national], profileMixes: [.parity],
                      autohelmOff: true, boatClass: "skiff@6").validate()
    }

    /// A race's reading, both ways: the finisher ahead wins, a tie scores ½, a boat that didn't finish loses, and each
    /// seat's gain over the other is the other's seconds less hers, in lengths at the other's speed.
    @Test func raceReadsWinsTiesDNFsAndGainSigns() throws {
        let won = try #require(race(.executor, .clubSteering, lead: 4).parity)
        #expect(won.profiles == [.executor, .clubSteering] && won.firstWin == 1 && won.marginSeconds == 4)
        #expect(won.firstGain.secondsPerBeat == [4] && won.secondGain.secondsPerBeat == [-4])
        #expect(won.firstGain.secondsPerRun == [4] && won.secondGain.secondsPerRun == [-4])
        let slowerSpeed: Double = 400 / 104, fasterSpeed: Double = 400 / 100
        #expect(won.firstGain.lengthsPerBeat == [4 * slowerSpeed / 4], "at the slower seat's speed, hull 4 m")
        #expect(won.secondGain.lengthsPerBeat == [-4 * fasterSpeed / 4], "at the faster seat's speed")

        let lost = try #require(race(.executor, .clubSteering, firstWins: false).parity)
        #expect(lost.firstWin == 0)

        let tied = [seat(0, .executor, place: nil, metresToGo: 50), seat(1, .tactician, place: nil, metresToGo: 50)]
        let tie = try #require(raceResult(cell: cell(), seats: tied).parity)
        #expect(tie.firstWin == 0.5 && tie.marginSeconds == nil)

        let dnf = [seat(0, .executor, place: nil, metresToGo: 5), seat(1, .tactician, place: 2)]
        #expect(try #require(raceResult(cell: cell(), seats: dnf).parity).firstWin == 0, "a DNF loses to a finisher")
        let behind = [seat(0, .executor, place: nil, metresToGo: 80), seat(1, .tactician, place: nil, metresToGo: 20)]
        #expect(try #require(raceResult(cell: cell(), seats: behind).parity).firstWin == 0, "unfinished: metres to go")

        var other = cell()
        other.profileMix = .handling
        #expect(raceResult(cell: other, seats: tied).parity == nil, "only the parity mix's races")
        let gap = [seat(0, .tactician, place: 1), seat(1, .baseline, place: 2)]
        #expect(raceResult(cell: cell(), seats: gap).skillGap == nil, "the 2×2 is not the skill gap")
    }

    /// The summary reads each race both ways: row over column, Q1's shares, the gains over the baseline, T3 and T2, the
    /// rows per conditions file and Q1's tails.
    @Test func summaryPoolsTheTwoByTwo() throws {
        let races = [
            race(.executor, .tacticianClubSteering, lead: 10, conditions: "sea-breeze@7", seed: 3),
            race(.tacticianClubSteering, .executor, lead: 2, seed: 4),
            race(.executor, .tacticianClubSteering, lead: 40, seed: 5),
            race(.executor, .clubSteering, lead: 4), race(.clubSteering, .executor, firstWins: false, lead: -4),
            race(.tacticianClubSteering, .clubSteering, lead: 3.5),
            race(.tactician, .clubSteering, lead: 6),
        ]
        let summary = try #require(ParitySummary(races))
        #expect(summary.races == 7)
        let q1 = try #require(summary.handlerWinShare), t = try #require(summary.tacticianWinShare)
        #expect(q1.races == 3 && abs(q1.share - 2.0 / 3) < 1e-12 && abs(t.share - 1.0 / 3) < 1e-12)
        #expect(summary.pairs["clubSteering"]?["executor"]?.winShare.share == 0)
        let h = try #require(summary.pairs["executor"]?["clubSteering"]?.gains)
        #expect(h.beatSeconds?.mean == 4 && h.beatSeconds?.count == 2 && h.beatSeconds?.ci == 0 && h.runSeconds?.median == 4)
        #expect(summary.pairs["clubSteering"]?["executor"]?.gains.beatSeconds?.mean == -4)
        #expect(summary.legGainGap.beatSeconds == 0.5 / 4 && summary.legGainGap.runSeconds == 0.5 / 4)
        #expect(summary.bothOverBest.beatSeconds == 6.0 / 4)
        #expect(Set(summary.byConditions.keys) == ["classic-oscillating", "sea-breeze"])
        #expect(summary.byConditions["sea-breeze"]?.races == 1)
        #expect(summary.byConditions["sea-breeze"]?.pairs["executor"]?["tacticianClubSteering"]?.winShare.share == 1)
        let margins = try #require(summary.margins)
        #expect(margins.races == 3 && margins.decidedOver30 == 1 && margins.medianSeconds == 10)
        #expect(margins.worst.first == ParityMargin(seconds: -2, venue: "dev-venue", conditions: "classic-oscillating", seed: 4,
                                                   handlerSeat: 1))
        #expect(margins.best.first?.seconds == 40 && margins.best.first?.handlerSeat == 0)
        #expect(summary.lines.first?.hasPrefix("parity: 7 two-boat races") == true)
        #expect(summary.lines.contains { $0.hasPrefix("  Q1: the handler won 0.667±") })
        #expect(ParitySummary([raceResult()]) == nil, "no parity race, no summary")

        let data = try JSONEncoder().encode(summary)
        #expect(try JSONDecoder().decode(ParitySummary.self, from: data) == summary)
    }

    /// #484 (the owner's D2): the band gates the tactician's Q1 share on both sides and T3's gap on beats and on runs, in
    /// seconds; inclusive, and only in a run that sailed the mix.
    @Test func parityBandBreachesOnItsOwn() throws {
        let limits = ParityLimits(minTacticianWinShare: 0.4, maxTacticianWinShare: 0.6, maxLegGainGap: 0.25)
        func summary(tacticianWins: Int, of races: Int, tacticianGain: Double) throws -> ParitySummary {
            let q1 = (0..<races).map { race(.tacticianClubSteering, .executor, firstWins: $0 < tacticianWins, seed: UInt64($0)) }
            return try #require(ParitySummary(q1 + [race(.executor, .clubSteering, lead: 4),
                                                    race(.tacticianClubSteering, .clubSteering, lead: tacticianGain)]))
        }
        #expect(limits.breaches(nil).isEmpty, "nothing sailed, nothing gated")
        #expect(limits.breaches(try summary(tacticianWins: 1, of: 2, tacticianGain: 3)).isEmpty, "gap 0.25 is inside")
        #expect(limits.breaches(try summary(tacticianWins: 0, of: 2, tacticianGain: 3)) == ["parity: tactician win share 0.000 < 0.400"])
        #expect(limits.breaches(try summary(tacticianWins: 2, of: 2, tacticianGain: 3)) == ["parity: tactician win share 1.000 > 0.600"])
        #expect(limits.breaches(try summary(tacticianWins: 1, of: 2, tacticianGain: 1))
            == ["parity: leg gain gap on beats 0.75 > 0.25", "parity: leg gain gap on runs 0.75 > 0.25"])
        var thresholds = unmissableThresholds()
        thresholds.parity = limits
        let calm = BotSuiteReport.RunTimings(maxP99Ms: 0, maxMs: 0)
        #expect(thresholds.breaches(tiers: [:], timings: calm, parity: try summary(tacticianWins: 0, of: 2, tacticianGain: 3)).count == 1)
    }
}
