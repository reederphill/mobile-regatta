@testable import BotSuite
import Foundation
import RegattaBots
import Testing

/// #231: the skill-gap scenario (ADR 0007, "a tactician bot clearly beats a groove-only bot, or the autohelm
/// has flattened skill"): baseline and tactician seats in the same races, how they finish, and what the
/// tactician gains on each beat.
@Suite struct BotSuiteSkillGapTests {
    private func seat(_ seat: Int, _ profile: BotProfile?, beats: [Double]) -> SeatMetrics {
        SeatMetrics(seat: seat, tier: .national, profile: profile, skill: 0.9, status: "finished", finished: true,
                    place: seat + 1, ironsSeconds: 0, markContacts: 0, boatContacts: 0, contactsEndingInFouls: 0,
                    contactsToFoulsShare: 0, foulsAsOffender: 0, dsqMissedPenalty: 0, ocsCount: 0, edgeSeconds: 0,
                    landContacts: 0, boundaryContacts: 0, beats: beats.map { BeatSplit(seconds: $0, metres: 300) })
    }

    /// A race's record: the profiles in finishing order, who won, the pairs, and each beat's gain at the
    /// baseline's speed up the course.
    @Test func raceSkillGapComparesTheProfiles() throws {
        let seats = [seat(0, .tactician, beats: [100, 100]), seat(1, .baseline, beats: [110, 104]),
                     seat(2, .tactician, beats: [104]), seat(3, .baseline, beats: [106, 110])]
        let gap = try #require(RaceSkillGap(seats: seats, ranks: [1, 2, 3, 4], hullLength: 5))
        #expect(gap.order == [.tactician, .baseline, .tactician, .baseline])
        #expect(gap.tacticianWin == 1, "mean places 1 against 2")
        #expect(gap.tacticianPairShare == 0.75, "seat 2 finished behind seat 1")
        // Beat 1: 102 s against 108 s at 300/108 m/s up the course; beat 2: seat 2 never finished it.
        #expect(gap.gainLengthsPerBeat.count == 2)
        #expect(abs(gap.gainLengthsPerBeat[0] - 6 * 300 / 108 / 5) < 1e-9)
        #expect(abs(gap.gainLengthsPerBeat[1] - 7 * 300 / 107 / 5) < 1e-9)

        let reversed = try #require(RaceSkillGap(seats: seats, ranks: [4, 3, 2, 1], hullLength: 5))
        #expect(reversed.tacticianWin == 0 && reversed.tacticianPairShare == 0.25)
        let tied = try #require(RaceSkillGap(seats: seats, ranks: [1, 2, 4, 3], hullLength: 5))
        #expect(tied.tacticianWin == 0.5)

        // A race without both profiles has no skill gap.
        #expect(RaceSkillGap(seats: [seat(0, .tactician, beats: []), seat(1, nil, beats: [])], ranks: [1, 2], hullLength: 5) == nil)
        #expect(RaceSkillGap(seats: [seat(0, nil, beats: []), seat(1, nil, beats: [])], ranks: [1, 2], hullLength: 5) == nil)

        let summary = try #require(SkillGapSummary([gap, reversed, tied]))
        #expect(summary.races == 3)
        #expect(summary.tacticianWinShare == 0.5)
        #expect(summary.beats == 6)
        #expect(SkillGapSummary([]) == nil)
    }

    /// The median gain is the middle one, or the mean of the middle two.
    @Test func medianGainIsTheMiddleBeat() throws {
        func race(_ gains: [Double]) -> RaceSkillGap {
            var gap = RaceSkillGap(seats: [seat(0, .tactician, beats: []), seat(1, .baseline, beats: [])], ranks: [1, 2], hullLength: 5)!
            gap.gainLengthsPerBeat = gains
            return gap
        }
        #expect(try #require(SkillGapSummary([race([5, -1]), race([2])])).medianGainLengthsPerBeat == 2)
        #expect(try #require(SkillGapSummary([race([5, -1]), race([2, 4])])).medianGainLengthsPerBeat == 3)
    }

    /// Each profile limit breaches on its own, only for a run that sailed the skill gap.
    @Test func profileLimitsBreachOnTheirOwn() throws {
        var thresholds = unmissableThresholds()
        thresholds.profiles["tactician"] = ProfileLimits(minTacticianWinShare: 0.75, minTacticianGainLengthsPerBeat: 3)
        let calm = BotSuiteReport.RunTimings(maxP99Ms: 1, maxMs: 1)
        func gap(win: Double, gain: Double) throws -> SkillGapSummary {
            var gap = RaceSkillGap(seats: [seat(0, .tactician, beats: []), seat(1, .baseline, beats: [])], ranks: [1, 2], hullLength: 5)!
            gap.gainLengthsPerBeat = [gain]
            var summary = try #require(SkillGapSummary([gap]))
            summary.tacticianWinShare = win
            return summary
        }
        #expect(thresholds.breaches(tiers: [:], timings: calm, skillGap: try gap(win: 0.75, gain: 3)).isEmpty, "limits are inclusive")
        #expect(thresholds.breaches(tiers: [:], timings: calm, skillGap: try gap(win: 0.7, gain: 3)) == ["tactician: win share 0.70 < 0.75"])
        #expect(thresholds.breaches(tiers: [:], timings: calm, skillGap: try gap(win: 0.8, gain: 2.5)) == ["tactician: gain 2.50 lengths/beat < 3.00"])
        #expect(thresholds.breaches(tiers: [:], timings: calm, skillGap: nil).isEmpty, "no skill gap sailed, nothing to gate")
    }

    @Test func bundledThresholdsGateTheTactician() throws {
        let thresholds = try BotThresholds.bundled()
        #expect(thresholds.profiles["tactician"]?.minTacticianWinShare == 0.75)
        #expect(thresholds.profiles["tactician"]?.minTacticianGainLengthsPerBeat == 3)
        var unknown = unmissableThresholds()
        unknown.profiles["coverer"] = ProfileLimits()
        let path = try fixture(unknown, named: "unknown-profile")
        #expect(throws: BotSuiteError.self) { try BotThresholds.load(from: URL(fileURLWithPath: path)) }
        // A thresholds file from before #231 has no profiles, and gates none.
        let old = try JSONDecoder().decode(BotThresholds.self, from: Data(#"{"maxP99TickMs": 10, "tiers": {}}"#.utf8))
        #expect(old.profiles.isEmpty)
    }

    /// The skill-gap mix gives every seat a profile, the tactician on the odd seats for an even seed; the
    /// live mix gives none.
    @Test func skillGapMixAlternatesTheProfiles() throws {
        #expect((0..<4).map { ProfileMix.skillGap.profile(ofSeat: $0, seed: 2) } == [.baseline, .tactician, .baseline, .tactician])
        #expect((0..<4).map { ProfileMix.skillGap.profile(ofSeat: $0, seed: 3) } == [.tactician, .baseline, .tactician, .baseline])
        #expect((0..<4).allSatisfy { ProfileMix.live.profile(ofSeat: $0, seed: 2) == nil })
        let cells = BotMatrix(seeds: [1], fleetSizes: [2], profileMixes: [.live, .skillGap]).cells
        #expect(cells.map(\.profileMix) == [.live, .skillGap])
        // A matrix file from before #231 sails live bots only.
        let old = #"{"seeds": [1], "venues": ["dev-venue@2"], "conditions": ["classic-oscillating@2"], "tideStatesDegrees": [0], "fleetSizes": [2], "tierMixes": ["club"], "laps": 1, "capSecondsAfterGun": 60}"#
        #expect(try JSONDecoder().decode(BotMatrix.self, from: Data(old.utf8)).profileMixes == [.live])
    }

    #if os(macOS) || os(Linux)
    /// A one-lap skill-gap race of a baseline and a tactician: one beat.
    private func skillGapMatrix() throws -> String {
        try fixture(BotMatrix(seeds: [2], fleetSizes: [2], tierMixes: [.national], profileMixes: [.skillGap], laps: 1),
                    named: "skill-gap-matrix")
    }

    /// #231 acceptance: the skill-gap scenario runs its matrix, and the JSON report gives both metrics, the
    /// tactician's win share and its median gain per beat, with each race's finishing order behind them.
    @Test func skillGapScenarioReportsBothMetrics() throws {
        let run = try botsuite(["--matrix", try skillGapMatrix(), "--thresholds", try fixture(unmissableThresholds(), named: "unmissable"),
                                "--json", "-"])
        #expect(run.status == 0)

        let object = try #require(JSONSerialization.jsonObject(with: Data(run.stdout.utf8)) as? [String: Any])
        let gap = try #require(object["skillGap"] as? [String: Any])
        for key in ["races", "tacticianWinShare", "tacticianPairShare", "beats", "medianGainLengthsPerBeat"] {
            #expect(gap[key] != nil, "skillGap has no \(key)")
        }
        let race = try #require((object["races"] as? [[String: Any]])?.first)
        let raceGap = try #require(race["skillGap"] as? [String: Any])
        for key in ["order", "tacticianWin", "tacticianPairShare", "gainLengthsPerBeat"] {
            #expect(raceGap[key] != nil, "the race's skillGap has no \(key)")
        }
        let seats = try #require(race["seats"] as? [[String: Any]])
        #expect(Set(seats.compactMap { $0["profile"] as? String }) == ["baseline", "tactician"])

        let report = try JSONDecoder().decode(BotSuiteReport.self, from: Data(run.stdout.utf8))
        let summary = try #require(report.skillGap)
        #expect(summary.races == 1)
        #expect(summary.beats == 1, "a lap is one beat")
        #expect(Set(report.profiles.keys) == ["baseline", "tactician"])
        #expect(report.tiers.isEmpty, "no live bot sailed")
        let result = try #require(report.races.first)
        #expect(result.seats.map(\.profile) == [.baseline, .tactician])
        #expect(result.seats.allSatisfy { $0.beats.count == 1 && $0.beats[0].seconds > 0 && $0.beats[0].metres > 0 })
    }

    /// #231 acceptance: a skill-gap run that misses a fixture's tactician limits exits non-zero, naming each;
    /// one that meets them exits 0.
    @Test func skillGapThresholdBreachExitsNonZero() throws {
        let matrix = try skillGapMatrix()
        var impossible = unmissableThresholds()
        impossible.profiles["tactician"] = ProfileLimits(minTacticianWinShare: 1.01, minTacticianGainLengthsPerBeat: 1_000)
        let failing = try botsuite(["--matrix", matrix, "--thresholds", try fixture(impossible, named: "impossible-tactician")])
        #expect(failing.status == 1)
        #expect(failing.stdout.contains("gate: FAIL"))
        #expect(failing.stdout.contains("tactician: win share"))
        #expect(failing.stdout.contains("tactician: gain"))

        var easy = unmissableThresholds()
        easy.profiles["tactician"] = ProfileLimits(minTacticianWinShare: 0, minTacticianGainLengthsPerBeat: -1_000)
        let passing = try botsuite(["--matrix", matrix, "--thresholds", try fixture(easy, named: "easy-tactician")])
        #expect(passing.status == 0)
        #expect(passing.stdout.contains("gate: pass"))
    }
    #endif
}
