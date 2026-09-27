@testable import BotSuite
import Foundation
import RegattaBots
import Testing

/// #238: the fun-pass scenario (#221's proof, "bot suite, classic oscillating"): baseline, tactician and
/// blip-tacker seats in the same races in classic oscillating conditions at version 3, how often each tacks
/// per beat, and whether the tactician beats the boat that tacks on every blip.
@Suite struct BotSuiteFunPassTests {
    private func seat(_ seat: Int, _ profile: BotProfile?, tacks: [Int]) -> SeatMetrics {
        SeatMetrics(seat: seat, tier: .national, profile: profile, skill: 0.9, status: "finished", finished: true,
                    place: seat + 1, ironsSeconds: 0, markContacts: 0, boatContacts: 0, contactsEndingInFouls: 0,
                    contactsToFoulsShare: 0, foulsAsOffender: 0, dsqMissedPenalty: 0, ocsCount: 0, edgeSeconds: 0,
                    landContacts: 0, boundaryContacts: 0,
                    beats: tacks.map { BeatSplit(seconds: 150, metres: 300, tacks: $0) })
    }

    /// The fun-pass mix gives every seat one of the three profiles by turns, one seat further along for each
    /// seed; a matrix sails it only in classic oscillating conditions, whatever their version.
    @Test func funPassMixRotatesTheThreeProfiles() {
        #expect((0..<4).map { ProfileMix.funPass.profile(ofSeat: $0, seed: 3) } == [.baseline, .tactician, .blipTacker, .baseline])
        #expect((0..<4).map { ProfileMix.funPass.profile(ofSeat: $0, seed: 1) } == [.tactician, .blipTacker, .baseline, .tactician])
        #expect((0..<3).map { ProfileMix.funPass.profile(ofSeat: $0, seed: 2) } == [.blipTacker, .baseline, .tactician])

        #expect(ProfileMix.funPass.sails(in: "classic-oscillating@3") && ProfileMix.funPass.sails(in: "classic-oscillating@2"))
        #expect(!ProfileMix.funPass.sails(in: "gusty-offshore@3"))
        #expect(ProfileMix.skillGap.sails(in: "gusty-offshore@3") && ProfileMix.live.sails(in: "sea-breeze@3"))
        let matrix = BotMatrix(seeds: [1], conditions: ["classic-oscillating@3", "gusty-offshore@3"], fleetSizes: [3],
                               profileMixes: [.skillGap, .funPass])
        #expect(matrix.cells.map { "\($0.conditions) \($0.profileMix)" }
            == ["classic-oscillating@3 skillGap", "classic-oscillating@3 funPass", "gusty-offshore@3 skillGap"])
    }

    /// A race's record: the profiles in finishing order, each one's tacks per beat over the beats its seats
    /// completed, and whether the tactician beat the blip-tacker.
    @Test func raceFunPassCountsTacksAndTheBlipTackerOrder() {
        let seats = [seat(0, .tactician, tacks: [4, 5]), seat(1, .blipTacker, tacks: [7, 9]),
                     seat(2, .baseline, tacks: [5]), seat(3, .tactician, tacks: [3]), seat(4, nil, tacks: [2])]
        let race = RaceFunPass(seats: seats, ranks: [1, 3, 2, 4, 5])
        #expect(race.order == [.tactician, .baseline, .blipTacker, .tactician], "a live seat has no place in the order")
        #expect(race.tacksPerBeat == ["tactician": 4, "blipTacker": 8, "baseline": 5], "(4 + 5 + 3) / 3 for the tactician")
        #expect(race.tacticianBeatsBlipTacker == 1, "mean places 1.5 against 2")
        let tied = RaceFunPass(seats: seats, ranks: [1, 2, 4, 3, 5])
        #expect(tied.order == [.tactician, .blipTacker, .tactician, .baseline])
        #expect(tied.tacticianBeatsBlipTacker == 0.5, "mean places 1 against 1")
        #expect(RaceFunPass(seats: seats, ranks: [2, 1, 3, 4, 5]).tacticianBeatsBlipTacker == 0)
        // A two-boat fleet sails two of the three profiles: without both, there is no order between them.
        let pair = RaceFunPass(seats: [seat(0, .tactician, tacks: [4]), seat(1, .baseline, tacks: [])], ranks: [1, 2])
        #expect(pair.tacticianBeatsBlipTacker == nil)
        #expect(pair.tacksPerBeat == ["tactician": 4], "a profile with no completed beat has no tacks per beat")
    }

    /// Over a run, tacks per beat pool every fun-pass race's beats, and the blip-tacker share counts the races
    /// with both; a run without a fun-pass race has no summary.
    @Test func funPassSummaryPoolsTheRaces() throws {
        func race(_ seats: [SeatMetrics], ranks: [Int], mix: ProfileMix = .funPass) -> RaceResult {
            let cell = BotRaceCell(seed: 1, venue: "dev-venue@3", conditions: "classic-oscillating@3", tideStateDegrees: 0,
                                   fleetSize: seats.count, tierMix: .national, profileMix: mix, laps: 1, capSecondsAfterGun: 60)
            return RaceResult(cell: cell, finalTick: 0, capped: false, tideStateAtGun: nil, seats: seats, ranks: ranks,
                              hullLength: 5, timings: TickTimings(samples: [], cpuSeconds: 0))
        }
        let three = race([seat(0, .tactician, tacks: [6]), seat(1, .blipTacker, tacks: [8]), seat(2, .baseline, tacks: [5])],
                         ranks: [1, 2, 3])
        let two = race([seat(0, .tactician, tacks: [2, 4]), seat(1, .baseline, tacks: [5])], ranks: [2, 1])
        let skillGap = race([seat(0, .tactician, tacks: [9]), seat(1, .baseline, tacks: [9])], ranks: [1, 2], mix: .skillGap)
        #expect(skillGap.funPass == nil, "only the fun-pass mix's races are the fun pass's")

        let summary = try #require(FunPassSummary([three, two, skillGap]))
        #expect(summary.races == 2)
        #expect(summary.tacksPerBeat == ["tactician": 4, "blipTacker": 8, "baseline": 5], "(6 + 2 + 4) / 3 for the tactician")
        #expect(summary.beats == ["tactician": 3, "blipTacker": 1, "baseline": 2])
        #expect(summary.blipTackerRaces == 1 && summary.tacticianBeatsBlipTackerShare == 1)
        #expect(FunPassSummary([skillGap]) == nil)
        #expect(try #require(FunPassSummary([two])).tacticianBeatsBlipTackerShare == nil)
    }

    /// Each fun-pass limit breaches on its own, only for a run that sailed the numbers it holds.
    @Test func funPassLimitsBreachOnTheirOwn() throws {
        var thresholds = unmissableThresholds()
        thresholds.profiles["tactician"] = ProfileLimits(minTacticianTacksPerBeat: 4, minTacticianBeatsBlipTackerShare: 0.75)
        let calm = BotSuiteReport.RunTimings(maxP99Ms: 1, maxMs: 1)
        func pass(tacks: Double?, share: Double?) throws -> FunPassSummary {
            let cell = BotRaceCell(seed: 1, venue: "dev-venue@3", conditions: "classic-oscillating@3", tideStateDegrees: 0,
                                   fleetSize: 2, tierMix: .national, profileMix: .funPass, laps: 1, capSecondsAfterGun: 60)
            let result = RaceResult(cell: cell, finalTick: 0, capped: false, tideStateAtGun: nil,
                                    seats: [seat(0, .tactician, tacks: [4]), seat(1, .blipTacker, tacks: [8])], ranks: [1, 2],
                                    hullLength: 5, timings: TickTimings(samples: [], cpuSeconds: 0))
            var summary = try #require(FunPassSummary([result]))
            summary.tacksPerBeat["tactician"] = tacks
            summary.tacticianBeatsBlipTackerShare = share
            return summary
        }
        func breaches(_ pass: FunPassSummary?) -> [String] {
            thresholds.breaches(tiers: [:], timings: calm, funPass: pass)
        }
        #expect(try breaches(pass(tacks: 4, share: 0.75)).isEmpty, "limits are inclusive")
        #expect(try breaches(pass(tacks: 3.5, share: 0.75)) == ["tactician: tacks 3.50/beat < 4.00"])
        #expect(try breaches(pass(tacks: 4, share: 0.5)) == ["tactician: beat the blip-tacker 0.50 < 0.75"])
        #expect(try breaches(pass(tacks: nil, share: nil)).isEmpty, "no tactician beat, no race with both: nothing to gate")
        #expect(breaches(nil).isEmpty, "no fun pass sailed, nothing to gate")
        // The skill-gap limits don't gate a fun pass, nor the fun-pass limits a skill gap.
        thresholds.profiles["tactician"] = ProfileLimits(minTacticianWinShare: 1.01, minTacticianGainLengthsPerBeat: 1_000)
        #expect(try breaches(pass(tacks: 0, share: 0)).isEmpty)
    }

    /// The bundled thresholds hold the tactician to #221's placeholders: 4 tacks per beat, and beating the
    /// blip-tacker in 0.75 of races.
    @Test func bundledThresholdsGateTheFunPass() throws {
        let tactician = try #require(try BotThresholds.bundled().profiles["tactician"])
        #expect(tactician.minTacticianTacksPerBeat == 4)
        #expect(tactician.minTacticianBeatsBlipTackerShare == 0.75)
    }

    #if os(macOS) || os(Linux)
    /// A one-lap race of three boats, one of each profile, in classic oscillating conditions at version 3:
    /// one beat each.
    private func funPassMatrix() throws -> String {
        try fixture(BotMatrix(seeds: [1], venues: ["dev-venue@3"], conditions: ["classic-oscillating@3"], fleetSizes: [3],
                              tierMixes: [.national], profileMixes: [.funPass], laps: 1),
                    named: "fun-pass-matrix")
    }

    /// #238 acceptance: the classic-oscillating @3 scenario runs the tactician, baseline and blip-tacker, and
    /// the JSON report gives each profile's tacks per beat and the tactician's order against the blip-tacker,
    /// with each race's order and each beat's tacks behind them.
    @Test func classicOscillatingScenarioReportsTacksPerBeatAndBlipTackerOrder() throws {
        let run = try botsuite(["--matrix", try funPassMatrix(), "--thresholds", try fixture(unmissableThresholds(), named: "unmissable"),
                                "--json", "-"])
        #expect(run.status == 0)

        let object = try #require(JSONSerialization.jsonObject(with: Data(run.stdout.utf8)) as? [String: Any])
        let pass = try #require(object["funPass"] as? [String: Any])
        for key in ["races", "tacksPerBeat", "beats", "blipTackerRaces", "tacticianBeatsBlipTackerShare"] {
            #expect(pass[key] != nil, "funPass has no \(key)")
        }
        let tacksPerBeat = try #require(pass["tacksPerBeat"] as? [String: Any])
        #expect(Set(tacksPerBeat.keys) == ["baseline", "tactician", "blipTacker"])
        let race = try #require((object["races"] as? [[String: Any]])?.first)
        let raceCell = try #require(race["cell"] as? [String: Any])
        #expect(raceCell["conditions"] as? String == "classic-oscillating@3")
        #expect(raceCell["venue"] as? String == "dev-venue@3")
        let racePass = try #require(race["funPass"] as? [String: Any])
        for key in ["order", "tacksPerBeat", "tacticianBeatsBlipTacker"] {
            #expect(racePass[key] != nil, "the race's funPass has no \(key)")
        }
        let seats = try #require(race["seats"] as? [[String: Any]])
        #expect(Set(seats.compactMap { $0["profile"] as? String }) == ["baseline", "tactician", "blipTacker"])
        for seat in seats {
            let beats = try #require(seat["beats"] as? [[String: Any]])
            #expect(beats.allSatisfy { $0["tacks"] is Int }, "seat \(seat["seat"] ?? "?")'s beats have no tacks")
        }

        let report = try JSONDecoder().decode(BotSuiteReport.self, from: Data(run.stdout.utf8))
        let summary = try #require(report.funPass)
        #expect(summary.races == 1)
        #expect(summary.beats == ["baseline": 1, "tactician": 1, "blipTacker": 1], "a lap is one beat")
        #expect(summary.blipTackerRaces == 1)
        let result = try #require(report.races.first)
        let order = try #require(result.funPass?.order)
        #expect(order.sorted { $0.rawValue < $1.rawValue } == [.baseline, .blipTacker, .tactician])
        let tacticianFirst = try #require(order.firstIndex(of: .tactician)) < #require(order.firstIndex(of: .blipTacker))
        #expect(summary.tacticianBeatsBlipTackerShare == (tacticianFirst ? 1.0 : 0.0))
        let tactician = try #require(result.seats.first { $0.profile == .tactician })
        #expect(summary.tacksPerBeat["tactician"] == tactician.beats.first.map { Double($0.tacks) })
        #expect(result.seats.contains { ($0.beats.first?.tacks ?? 0) > 0 }, "nobody tacked on a beat in an oscillating breeze")
        // The baseline and the tactician share the race, so its skill gap counts too.
        #expect(report.skillGap?.races == 1)
        #expect(Set(report.profiles.keys) == ["baseline", "tactician", "blipTacker"])
    }

    /// #238 acceptance: a fun-pass run that misses a fixture's tactician limits exits non-zero, naming each;
    /// one that meets them exits 0.
    @Test func funPassThresholdBreachExitsNonZero() throws {
        let matrix = try funPassMatrix()
        var impossible = unmissableThresholds()
        impossible.profiles["tactician"] = ProfileLimits(minTacticianTacksPerBeat: 1_000, minTacticianBeatsBlipTackerShare: 1.01)
        let failing = try botsuite(["--matrix", matrix, "--thresholds", try fixture(impossible, named: "impossible-fun-pass")])
        #expect(failing.status == 1)
        #expect(failing.stdout.contains("gate: FAIL"))
        #expect(failing.stdout.contains("fun pass: 1 races, tacks/beat"))
        #expect(failing.stdout.contains("tactician: tacks"))
        #expect(failing.stdout.contains("tactician: beat the blip-tacker"))

        var easy = unmissableThresholds()
        easy.profiles["tactician"] = ProfileLimits(minTacticianTacksPerBeat: 0, minTacticianBeatsBlipTackerShare: 0)
        let passing = try botsuite(["--matrix", matrix, "--thresholds", try fixture(easy, named: "easy-fun-pass")])
        #expect(passing.status == 0)
        #expect(passing.stdout.contains("gate: pass"))
    }
    #endif
}
