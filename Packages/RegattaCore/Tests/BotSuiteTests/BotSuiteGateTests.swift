@testable import BotSuite
import RegattaBots
import Foundation
import Testing

@Suite struct BotSuiteGateTests {
    private func seat(_ tier: BotTier, finished: Bool = true, irons: Double = 0, marks: Int = 0, contacts: Int = 0,
                      fouls: Int = 0, edge: Double = 0) -> SeatMetrics {
        SeatMetrics(seat: 0, tier: tier, skill: 0.5, status: finished ? "finished" : "racing", finished: finished,
                    place: finished ? 1 : nil, ironsSeconds: irons, markContacts: marks, boatContacts: contacts,
                    contactsEndingInFouls: fouls, contactsToFoulsShare: share(fouls, of: contacts), foulsAsOffender: 0,
                    dsqMissedPenalty: 0, ocsCount: 0, edgeSeconds: edge, landContacts: 0, boundaryContacts: 0)
    }

    /// #19's limits, each on its own: finish share, irons, mark contact, contacts to fouls, the edge;
    /// and #27's tick.
    @Test func eachLimitBreachesOnItsOwn() {
        let limits = TierLimits(minFinishShare: 0.5, maxMeanIronsSeconds: 10, maxMeanMarkContacts: 1,
                                maxContactsToFoulsShare: 0.1, maxMeanEdgeSeconds: 5)
        let thresholds = BotThresholds(tiers: ["national": limits], maxP99TickMs: 5)
        let calm = BotSuiteReport.RunTimings(maxP99Ms: 5, maxMs: 9)
        func breaches(_ seats: [SeatMetrics], timings: BotSuiteReport.RunTimings = calm) -> [String] {
            thresholds.breaches(tiers: ["national": TierSummary(seats)], timings: timings)
        }
        #expect(breaches([seat(.national), seat(.national, finished: false)]).isEmpty, "limits are inclusive")
        #expect(breaches([seat(.national, finished: false), seat(.national, finished: false), seat(.national)]).count == 1)
        #expect(breaches([seat(.national, irons: 21)]).count == 1)
        #expect(breaches([seat(.national, marks: 2), seat(.national, marks: 1)]).count == 1)
        #expect(breaches([seat(.national, contacts: 10, fouls: 2)]).count == 1)
        #expect(breaches([seat(.national, edge: 6)]).count == 1)
        #expect(breaches([seat(.national)], timings: .init(maxP99Ms: 5.01, maxMs: 9)) == ["tick: worst p99 5.010 ms > 5.000"])
        #expect(breaches([seat(.national, finished: false, irons: 99, marks: 9, contacts: 1, fouls: 1, edge: 99)]).count == 5)
        // A tier with no limits isn't gated.
        #expect(thresholds.breaches(tiers: ["club": TierSummary([seat(.club, finished: false)])], timings: calm).isEmpty)
    }

    /// #351: a tier's summary adds up its seats' pre-start and cascade calls by rule, and buckets its unfinished seats
    /// by metres to go at the close (a boat with none recorded goes furthest), on the last leg or not, called or not.
    @Test func tierSummaryCountsCallPhasesAndDNFsByCause() {
        var a = seat(.national, finished: false), b = seat(.national, finished: false), c = seat(.national, finished: false)
        a.metresToFinish = 60; a.onLastLeg = true; a.foulsAsOffender = 2
        a.preStartCallsByRule = ["11": 1]; a.cascadeCallsByRule = ["21.2": 1]
        b.metresToFinish = 151; b.preStartCallsByRule = ["11": 2, "10": 1]
        c.metresToFinish = nil; c.cascadeCallsByRule = ["21.2": 2]
        let s = TierSummary([a, b, c, seat(.national)])
        #expect(s.preStartCallsByRule == ["11": 3, "10": 1])
        #expect(s.cascadeCallsByRule == ["21.2": 3])
        #expect(s.dnfByMetresToGo == ["<=60": 1, "<=300": 1, ">300": 1])
        #expect(s.dnfOnLastLeg == 1)
        #expect(s.dnfCalled == 1)
    }

    @Test func bundledThresholdsGateEveryTier() throws {
        let thresholds = try BotThresholds.bundled()
        #expect(Set(thresholds.tiers.keys) == Set(BotTier.allCases.map(\.rawValue)))
        #expect(thresholds.maxP99TickMs > 0)
        var pro = unmissableThresholds()
        pro.tiers["pro"] = pro.tiers["club"]
        let unknown = try fixture(pro, named: "unknown-tier")
        #expect(throws: BotSuiteError.self) { try BotThresholds.load(from: URL(fileURLWithPath: unknown)) }
    }

    /// #105: the bundled thresholds give every key the fun-pass breach test covers, the tick budget is #27's 5 ms, and
    /// every placeholder (the keys #389 sets) names a key they hold.
    @Test func bundledThresholdsHoldEveryGateKey() throws {
        let thresholds = try BotThresholds.bundled()
        #expect(thresholds.maxP99TickMs == 5)
        let keys = ["profiles.tactician.minTacticianWinShare", "profiles.tactician.minTacticianGainLengthsPerBeat",
                    "profiles.tactician.minTacticianTacksPerBeat", "profiles.tactician.minTacticianBeatsBlipTackerShare",
                    "profiles.tactician.minTacticianGainLengthsPerRun", "profiles.tactician.minTacticianStartGainLengths",
                    "profiles.tactician.minTacticsBeatsExecutionShare", "encounters.minCloseEncountersPerRace",
                    "watchdog.maxCentredRudder161Calls", "rivals.maxMeanPlaceGap", "rank.minSkillRankCorrelation"]
        for key in keys {
            #expect(thresholds.hasKey(key), "thresholds.json has no \(key)")
            #expect(thresholds.placeholders.contains(key), "\(key) isn't marked a placeholder")
        }
        #expect(thresholds.watchdog?.maxCentredRudder161Calls == 0)
        #expect(thresholds.profiles["tactician"]?.minTacticsBeatsExecutionShare == 0.75)
        #expect(thresholds.placeholders.allSatisfy(thresholds.hasKey))
        #expect(!thresholds.hasKey("profiles.tactician"), "a block isn't a key")
        var wrong = unmissableThresholds()
        wrong.placeholders = ["watchdog.maxCentredRudder161Calls"]
        let unknown = try fixture(wrong, named: "unknown-placeholder")
        #expect(throws: BotSuiteError.self) { try BotThresholds.load(from: URL(fileURLWithPath: unknown)) }
    }

    /// #105: each new limit breaches on its own, and gates only what the run sailed.
    @Test func newLimitsBreachOnTheirOwn() {
        var thresholds = unmissableThresholds()
        thresholds.watchdog = WatchdogLimits(maxCentredRudder161Calls: 0)
        thresholds.rivals = RivalLimits(maxMeanPlaceGap: 2)
        thresholds.rank = RankLimits(minSkillRankCorrelation: 0.5)
        thresholds.profiles["tactician"] = ProfileLimits(minTacticsBeatsExecutionShare: 0.75)
        let calm = BotSuiteReport.RunTimings(maxP99Ms: 0, maxMs: 0)
        func breaches(rivals: RivalPaceSummary? = nil, rank: RankSummary? = nil) -> [String] {
            thresholds.breaches(tiers: [:], timings: calm, rivals: rivals, rank: rank)
        }
        #expect(breaches().isEmpty, "nothing sailed, nothing gated")
        let close = RivalPaceSummary(races: 3, seatMeanPlace: ["0.45": 5, "0.70": 4], rivalMeanPlace: ["0.45": 3, "0.70": 4.5])
        #expect(close.maxMeanPlaceGap == 2)
        #expect(breaches(rivals: close).isEmpty, "limits are inclusive")
        let wide = RivalPaceSummary(races: 3, seatMeanPlace: ["0.90": 2], rivalMeanPlace: ["0.90": 4.5])
        #expect(breaches(rivals: wide) == ["rivals: mean place gap 2.50 > 2.00"])
        #expect(breaches(rank: RankSummary(races: 4, correlatedRaces: 4, meanSkillRankCorrelation: 0.5)).isEmpty)
        #expect(breaches(rank: RankSummary(races: 4, correlatedRaces: 4, meanSkillRankCorrelation: 0.49))
            == ["rank: skill vs finishing order 0.49 < 0.50"])
        #expect(breaches(rank: RankSummary(races: 4, correlatedRaces: 0, meanSkillRankCorrelation: 0)).isEmpty,
                "no race with a correlation, nothing to gate")
    }

    /// Spearman's rank correlation: 1 for the same order, −1 for the reverse, ties at their mean rank, none without
    /// a spread.
    @Test func spearmanCorrelationRanksWithTies() throws {
        #expect(spearmanCorrelation([0.4, 0.7, 0.9], [1, 2, 3]) == 1)
        #expect(spearmanCorrelation([0.4, 0.7, 0.9], [3, 2, 1]) == -1)
        let tied = try #require(spearmanCorrelation([0.4, 0.4, 0.9, 0.9], [1, 2, 3, 4]))
        #expect(abs(tied - 0.894_427) < 1e-6)
        #expect(spearmanCorrelation([0.5, 0.5], [1, 2]) == nil)
        #expect(spearmanCorrelation([0.5], [1]) == nil)
    }

    /// #105: a rank-stability race's correlation is of skill against finishing order, and the luck floor is the gap in
    /// places between seats of one skill.
    @Test func rankSummaryCorrelatesSkillWithPlaceAndReportsTheLuckFloor() throws {
        func seat(_ seat: Int, skill: Double) -> SeatMetrics {
            SeatMetrics(seat: seat, tier: .club, skill: skill, status: "finished", finished: true, place: nil,
                        ironsSeconds: 0, markContacts: 0, boatContacts: 0, contactsEndingInFouls: 0, contactsToFoulsShare: 0,
                        foulsAsOffender: 0, dsqMissedPenalty: 0, ocsCount: 0, edgeSeconds: 0, landContacts: 0,
                        boundaryContacts: 0)
        }
        let seats = [seat(0, skill: 0.9), seat(1, skill: 0.5), seat(2, skill: 0.9), seat(3, skill: 0.5)]
        let race = RaceRank(seats: seats, ranks: [1, 2, 3, 4])
        let summary = try #require(RankSummary([raceResult(rank: race, seats: seats)]))
        #expect(summary.races == 1 && summary.correlatedRaces == 1)
        #expect(abs(summary.meanSkillRankCorrelation - 0.447_214) < 1e-6)
        #expect(summary.sameSkillPlaceGap == ["0.90": 2, "0.50": 2])
        #expect(summary.meanSameSkillPlaceGap == 2)
    }

    /// #105: the watchdog counts the all-National live races in its two conditions, by id whatever the version, lists
    /// both even at 0, and sums the centred-rudder calls it gates.
    @Test func watchdogCountsItsConditionsAlone() throws {
        func race(_ conditions: String, tier: TierMix = .national, calls: Rule161Calls) -> RaceResult {
            let cell = BotRaceCell(seed: 1, venue: "dev-venue@7", conditions: conditions, tideStateDegrees: 0, fleetSize: 2,
                                   tierMix: tier, profileMix: .live, laps: 1, capSecondsAfterGun: 60)
            var result = raceResult(cell: cell)
            result.rule161 = calls
            return result
        }
        #expect(WatchdogSummary([race("sea-breeze@7", calls: Rule161Calls(calls: 3, centredRudder: 3))]) == nil)
        let summary = try #require(WatchdogSummary([
            race("classic-oscillating@7", calls: Rule161Calls(calls: 4, centredRudder: 2, centredRudderWithTap: 1)),
            race("classic-oscillating@3", calls: Rule161Calls(calls: 1, centredRudder: 1)),
            race("sea-breeze@7", calls: Rule161Calls(calls: 9, centredRudder: 9)),
            race("gusty-offshore@7", tier: .club, calls: Rule161Calls(calls: 9, centredRudder: 9)),
        ]))
        #expect(summary.races == 2)
        #expect(summary.rule161CallsByConditions == ["classic-oscillating": 5, "gusty-offshore": 0])
        #expect(summary.centredRudder161CallsByConditions == ["classic-oscillating": 3, "gusty-offshore": 0])
        #expect(summary.centredRudderWithTap161CallsByConditions == ["classic-oscillating": 1, "gusty-offshore": 0])
        #expect(summary.centredRudder161Calls == 3)
        #expect(WatchdogLimits(maxCentredRudder161Calls: 3).breaches(summary).isEmpty)
        #expect(WatchdogLimits(maxCentredRudder161Calls: 2).breaches(summary) == ["watchdog: centred-rudder 16.1 calls 3 > 2"])
    }

    /// #105: the new mixes' seats. Execution alternates its two profiles; the cautious mix puts the cautious bot in seat
    /// `seed % fleetSize`; the rivals mix sets seat 0 and her rivals to one skill; rank stability sets every seat to a
    /// tier's centre by turns. None but the live, skill-gap, fun-pass and execution mixes feed the live tiers.
    @Test func newMixesSeatTheirBots() {
        #expect((0..<4).map { ProfileMix.execution.profile(ofSeat: $0, seed: 2, fleetSize: 4) }
            == [.executor, .tacticianClubExecution, .executor, .tacticianClubExecution])
        #expect(ProfileMix.cautious.cautiousSeats(seed: 7, fleetSize: 5) == [2])
        #expect(ProfileMix.live.cautiousSeats(seed: 7, fleetSize: 5).isEmpty)
        let rivals = ProfileMix.rivals.seatSkills(seed: 4, fleetSize: 10)
        #expect(rivals.count == 3 && rivals[0] == 0.7 && Set(rivals.values) == [0.7])
        let rank = ProfileMix.rankStability.seatSkills(seed: 1, fleetSize: 6)
        #expect(rank.count == 6 && Set(rank.values) == Set(ProfileMix.rankSkills))
        #expect(ProfileMix.allCases.filter(\.gatesLiveTiers) == [.live, .skillGap, .funPass, .execution])
        let matrix = BotMatrix(seeds: [1], fleetSizes: [2], tierMixes: TierMix.allCases,
                               profileMixes: [.live, .execution, .rivals, .rankStability])
        #expect(matrix.cells.filter { $0.profileMix == .execution }.map(\.tierMix) == [.national])
        #expect(matrix.cells.filter { $0.profileMix == .rivals }.map(\.tierMix) == [.mixed])
        #expect(matrix.cells.filter { $0.profileMix == .live }.count == 4)
    }

    #if os(macOS) || os(Linux)
    /// #97 acceptance: a run that misses the thresholds exits non-zero, and one that meets them exits 0.
    @Test func thresholdBreachExitsNonZero() throws {
        let matrix = try fixture(BotMatrix(seeds: [3], fleetSizes: [2], tierMixes: [.club], laps: 1, capSecondsAfterGun: 60), named: "matrix")

        let failing = try botsuite(["--matrix", matrix, "--thresholds", try fixture(impossibleThresholds(), named: "impossible")])
        #expect(failing.status == 1)
        #expect(failing.stdout.contains("gate: FAIL"))
        #expect(failing.stdout.contains("club: finish share"))

        let passing = try botsuite(["--matrix", matrix, "--thresholds", try fixture(unmissableThresholds(), named: "unmissable")])
        #expect(passing.status == 0)
        #expect(passing.stdout.contains("gate: pass"))
    }

    /// #105 acceptance (#27): a run whose worst p99 tick misses the budget exits non-zero, and the report gives the
    /// budget beside the measured tick.
    @Test func tickBudgetBreachExitsNonZero() throws {
        let matrix = try fixture(BotMatrix(seeds: [3], fleetSizes: [2], tierMixes: [.club], laps: 1, capSecondsAfterGun: 60), named: "matrix")
        var tight = unmissableThresholds()
        tight.maxP99TickMs = 0
        let failing = try botsuite(["--matrix", matrix, "--thresholds", try fixture(tight, named: "tick-budget")])
        #expect(failing.status == 1)
        #expect(failing.stdout.contains("gate: FAIL"))
        #expect(failing.stdout.contains("tick: worst p99"))
        #expect(failing.stdout.contains("(budget 0.000 ms)"))
        #expect(failing.stdout.components(separatedBy: "\n").filter { $0.hasPrefix("  ") && $0.contains("tick:") }.count == 1)
    }

    /// #105 acceptance (#228): the JSON report gives the 16.1 watchdog's centred-rudder calls per conditions, both its
    /// conditions listed, over the all-National live fleets; and each race its 16.1 calls.
    @Test func centredRudder161CallsReportedPerConditions() throws {
        let matrix = BotMatrix(seeds: [1], venues: ["dev-venue@7"], conditions: ["classic-oscillating@7"], fleetSizes: [4],
                               tierMixes: [.national], laps: 1)
        let run = try botsuite(["--matrix", try fixture(matrix, named: "watchdog-matrix"),
                                "--thresholds", try fixture(unmissableThresholds(), named: "unmissable"), "--json", "-"])
        #expect(run.status == 0)
        let object = try #require(JSONSerialization.jsonObject(with: Data(run.stdout.utf8)) as? [String: Any])
        let watchdog = try #require(object["watchdog"] as? [String: Any])
        let byConditions = try #require(watchdog["centredRudder161CallsByConditions"] as? [String: Int])
        #expect(Set(byConditions.keys) == ["classic-oscillating", "gusty-offshore"])
        #expect(byConditions["gusty-offshore"] == 0)
        for key in ["races", "rule161CallsByConditions", "centredRudderWithTap161CallsByConditions", "centredRudder161Calls"] {
            #expect(watchdog[key] != nil, "watchdog has no \(key)")
        }
        let race = try #require((object["races"] as? [[String: Any]])?.first)
        let calls = try #require(race["rule161"] as? [String: Int])
        #expect(Set(calls.keys) == ["calls", "centredRudder", "centredRudderWithTap"])
        let report = try JSONDecoder().decode(BotSuiteReport.self, from: Data(run.stdout.utf8))
        let summary = try #require(report.watchdog)
        #expect(summary.races == 1)
        #expect(summary.centredRudder161Calls == report.races[0].rule161?.centredRudder)
        let counts = try #require(report.races[0].rule161)
        #expect(counts.centredRudderWithTap <= counts.centredRudder && counts.centredRudder <= counts.calls)
        #expect(counts.calls == report.races[0].seats.reduce(0) { $0 + ($1.callsByRule["16.1"] ?? 0) })
    }

    /// One race of each scripted mix the fun-pass keys read, short: the fun pass (three boats), all-National live (the
    /// close encounters and the watchdog), the skill gap, execution, rivals and rank stability; one lap.
    private func gateMatrix() throws -> String {
        try fixture(BotMatrix(seeds: [1], venues: ["dev-venue@7"], conditions: ["classic-oscillating@7"], fleetSizes: [3],
                              tierMixes: [.national, .mixed],
                              profileMixes: [.live, .funPass, .execution, .rivals, .rankStability], laps: 1),
                    named: "gate-matrix")
    }

    /// #105 acceptance (#238's, extended): a run that misses a fixture's fun-pass keys exits non-zero, naming each: the
    /// skill gap (win share, gain per beat), tacks per beat, the blip-tacker, close encounters, the rival pace band, the
    /// 16.1 watchdog; and #105's own: gain per run, start gain, execution against tactics, skill against rank. One that
    /// meets them exits 0.
    @Test func funPassThresholdBreachExitsNonZero() throws {
        let matrix = try gateMatrix()
        var impossible = unmissableThresholds()
        impossible.profiles["tactician"] = ProfileLimits(
            minTacticianWinShare: 1.01, minTacticianGainLengthsPerBeat: 1_000, minTacticianTacksPerBeat: 1_000,
            minTacticianBeatsBlipTackerShare: 1.01, minTacticianGainLengthsPerRun: 1_000, minTacticianStartGainLengths: 1_000,
            minTacticsBeatsExecutionShare: 1.01)
        impossible.encounters = EncounterLimits(minCloseEncountersPerRace: 1_000)
        impossible.watchdog = WatchdogLimits(maxCentredRudder161Calls: -1)
        impossible.rivals = RivalLimits(maxMeanPlaceGap: -1)
        impossible.rank = RankLimits(minSkillRankCorrelation: 1.01)
        let failing = try botsuite(["--matrix", matrix, "--thresholds", try fixture(impossible, named: "impossible-fun-pass")])
        #expect(failing.status == 1)
        #expect(failing.stdout.contains("gate: FAIL"))
        #expect(failing.stdout.contains("fun pass: 2 races, tacks/beat"))
        for breach in ["tactician: win share", "tactician: gain", "lengths/beat <", "tactician: tacks",
                       "tactician: beat the blip-tacker", "encounters: close encounters", "rivals: mean place gap",
                       "watchdog: centred-rudder 16.1 calls", "lengths/run <", "tactician: start",
                       "tactician: beat the executor", "rank: skill vs finishing order"] {
            #expect(failing.stdout.contains("  " + breach) || failing.stdout.contains(breach), "no breach: \(breach)")
        }
        let lines = failing.stdout.components(separatedBy: "\n")
        let gate = try #require(lines.firstIndex(of: "gate: FAIL"))
        let breaches = lines[(gate + 1)...].filter { $0.hasPrefix("  ") }
        #expect(breaches.count == 11, "one breach a key: \(breaches)")

        var easy = unmissableThresholds()
        easy.profiles["tactician"] = ProfileLimits(
            minTacticianWinShare: 0, minTacticianGainLengthsPerBeat: -1_000, minTacticianTacksPerBeat: 0,
            minTacticianBeatsBlipTackerShare: 0, minTacticianGainLengthsPerRun: -1_000, minTacticianStartGainLengths: -1_000,
            minTacticsBeatsExecutionShare: 0)
        easy.encounters = EncounterLimits(minCloseEncountersPerRace: 0)
        easy.watchdog = WatchdogLimits(maxCentredRudder161Calls: 1_000)
        easy.rivals = RivalLimits(maxMeanPlaceGap: 1_000)
        easy.rank = RankLimits(minSkillRankCorrelation: -1)
        let passing = try botsuite(["--matrix", matrix, "--thresholds", try fixture(easy, named: "easy-fun-pass")])
        #expect(passing.status == 0)
        #expect(passing.stdout.contains("gate: pass"))
    }

    /// #105 acceptance (#222): the execution mix races the executor against the tactician at Club-level execution, and
    /// the report gives the share of races tactics won, each race's order behind it.
    @Test func executorLosesToTacticianReported() throws {
        let matrix = BotMatrix(seeds: [1, 2], venues: ["dev-venue@7"], conditions: ["classic-oscillating@7"], fleetSizes: [2],
                               tierMixes: [.national], profileMixes: [.execution], laps: 1)
        let run = try botsuite(["--matrix", try fixture(matrix, named: "execution-matrix"),
                                "--thresholds", try fixture(unmissableThresholds(), named: "unmissable"), "--json", "-"])
        #expect(run.status == 0)
        let object = try #require(JSONSerialization.jsonObject(with: Data(run.stdout.utf8)) as? [String: Any])
        let execution = try #require(object["execution"] as? [String: Any])
        #expect(execution["races"] as? Int == 2)
        #expect(execution["tacticsBeatsExecutionShare"] is Double)
        let report = try JSONDecoder().decode(BotSuiteReport.self, from: Data(run.stdout.utf8))
        let wins = report.races.compactMap(\.execution?.tacticsWin)
        #expect(wins.count == 2)
        #expect(report.execution?.tacticsBeatsExecutionShare == wins.reduce(0, +) / 2)
        for race in report.races {
            #expect(Set(race.seats.compactMap(\.profile)) == [.executor, .tacticianClubExecution])
            #expect(race.execution?.order.count == 2)
        }
        #expect(Set(report.profiles.keys) == ["executor", "tacticianClubExecution"])
        #expect(report.tiers.isEmpty, "profile seats aren't live tiers'")
    }

    /// #105 acceptance: the skill gap reports the tactician's gain per run (median, hull lengths) and her lead over the
    /// baseline at their first cross after the gun; each race its runs' gains and its start lead; each seat its runs.
    @Test func downwindAndStartGainsReported() throws {
        let matrix = BotMatrix(seeds: [1], venues: ["dev-venue@7"], conditions: ["classic-oscillating@7"], fleetSizes: [2],
                               tierMixes: [.national], profileMixes: [.skillGap], laps: 1)
        let run = try botsuite(["--matrix", try fixture(matrix, named: "skill-gap-matrix"),
                                "--thresholds", try fixture(unmissableThresholds(), named: "unmissable"), "--json", "-"])
        #expect(run.status == 0)
        let object = try #require(JSONSerialization.jsonObject(with: Data(run.stdout.utf8)) as? [String: Any])
        let gap = try #require(object["skillGap"] as? [String: Any])
        for key in ["runs", "medianGainLengthsPerRun", "startRaces", "meanStartGainLengths"] {
            #expect(gap[key] != nil, "skillGap has no \(key)")
        }
        let report = try JSONDecoder().decode(BotSuiteReport.self, from: Data(run.stdout.utf8))
        let summary = try #require(report.skillGap)
        let race = try #require(report.races.first?.skillGap)
        #expect(summary.runs == race.gainLengthsPerRun.count && summary.runs == 1, "a lap is one run, to the finish")
        #expect(summary.medianGainLengthsPerRun == race.gainLengthsPerRun[0])
        #expect(summary.startRaces == 1)
        #expect(summary.meanStartGainLengths == race.startGainLengths)
        let seats = try #require(report.races.first?.seats)
        for seat in seats where seat.finished {
            #expect(seat.runs.count == 1, "seat \(seat.seat) ran once")
            #expect(seat.runs.allSatisfy { $0.seconds > 0 && $0.metres > 0 })
        }
    }

    /// #105 acceptance: the rank-stability mix sails every seat at a tier's centre, and the report gives skill against
    /// finishing order (Spearman) and the luck floor: the place gap between seats of one skill.
    @Test func skillRankCorrelationReported() throws {
        let matrix = BotMatrix(seeds: [1, 2], venues: ["dev-venue@7"], conditions: ["classic-oscillating@7"], fleetSizes: [4],
                               tierMixes: [.mixed], profileMixes: [.rankStability], laps: 1)
        let run = try botsuite(["--matrix", try fixture(matrix, named: "rank-matrix"),
                                "--thresholds", try fixture(unmissableThresholds(), named: "unmissable"), "--json", "-"])
        #expect(run.status == 0)
        let object = try #require(JSONSerialization.jsonObject(with: Data(run.stdout.utf8)) as? [String: Any])
        let rank = try #require(object["rank"] as? [String: Any])
        for key in ["races", "correlatedRaces", "meanSkillRankCorrelation", "sameSkillPlaceGap", "meanSameSkillPlaceGap"] {
            #expect(rank[key] != nil, "rank has no \(key)")
        }
        let report = try JSONDecoder().decode(BotSuiteReport.self, from: Data(run.stdout.utf8))
        let summary = try #require(report.rank)
        #expect(summary.races == 2 && summary.correlatedRaces == 2)
        for race in report.races {
            let rank = try #require(race.rank)
            #expect(Set(rank.skills).isSubset(of: Set(ProfileMix.rankSkills)))
            #expect(rank.skills == race.seats.map(\.skill))
            #expect(Set(rank.places) == [1, 2, 3, 4])
        }
        // Four seats over three skills: each race one pair shares a skill, the luck floor's.
        #expect((1...2).contains(summary.sameSkillPlaceGap.count))
        #expect(summary.meanSameSkillPlaceGap != nil)
        #expect(report.tiers.isEmpty, "seats at a set skill aren't the live tiers'")
    }
    #endif
}

/// A race result for summaries built by hand: `cell`'s, with `seats` (two finished seats by default).
func raceResult(cell: BotRaceCell? = nil, rank: RaceRank? = nil, seats: [SeatMetrics]? = nil) -> RaceResult {
    let cell = cell ?? BotRaceCell(seed: 1, venue: "dev-venue@7", conditions: "classic-oscillating@7", tideStateDegrees: 0,
                                   fleetSize: 2, tierMix: .mixed, profileMix: .rankStability, laps: 1, capSecondsAfterGun: 60)
    let seats = seats ?? (0..<2).map {
        SeatMetrics(seat: $0, tier: .national, skill: 0.9, status: "finished", finished: true, place: $0 + 1, ironsSeconds: 0,
                    markContacts: 0, boatContacts: 0, contactsEndingInFouls: 0, contactsToFoulsShare: 0, foulsAsOffender: 0,
                    dsqMissedPenalty: 0, ocsCount: 0, edgeSeconds: 0, landContacts: 0, boundaryContacts: 0)
    }
    var result = RaceResult(cell: cell, finalTick: 0, capped: false, tideStateAtGun: nil, seats: seats,
                            ranks: seats.indices.map { $0 + 1 }, hullLength: 4,
                            timings: TickTimings(samples: [], cpuSeconds: 0))
    if let rank { result.rank = rank }
    return result
}
