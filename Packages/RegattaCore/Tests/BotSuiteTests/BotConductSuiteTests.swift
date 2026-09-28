@testable import BotSuite
import Foundation
import RegattaCore
import Testing

/// #101: the bots' conduct under the rules over the suite's all-National live fleets, gated on encounters ending in
/// fouls (the owner, 2026-09-27). Every contact ends in a rule call (#100's run: contacts 1.00 fouls), so the share of
/// contacts ending in fouls can't show conduct; the share of encounters can. An encounter is a pair coming within 2 hull
/// lengths of each other while rules 10–13 name one of them to keep clear, counted once until they separate past that
/// again (the separation that closes #88's incidents); it ends in a foul when a rule call is made between the pair
/// during it. The gate holds it over the same fleets as navigation (#100), not in a tier's limits (the owner,
/// 2026-09-28): the smoke's three mixed-tier races are too few to decide it.
///
/// The fleets are too many full races for `swift test`: the numbers are the CLI's full navigation run,
///
///     scripts/heavy.sh swift run -c release --package-path Packages/RegattaCore regatta-botsuite \
///         --tier-mix national --profile-mix live
///
/// which exits 1 when their share is over the limit. These tests hold that gate and the counting to the acceptance.
@Suite struct BotConductSuiteTests {
    private func seat(_ seat: Int, encounters: Int, fouls: Int) -> SeatMetrics {
        SeatMetrics(seat: seat, tier: .national, skill: 0.9, status: "finished", finished: true, place: seat + 1,
                    ironsSeconds: 0, markContacts: 0, boatContacts: fouls, contactsEndingInFouls: fouls,
                    contactsToFoulsShare: share(fouls, of: fouls), foulsAsOffender: 0, dsqMissedPenalty: 0, ocsCount: 0,
                    edgeSeconds: 0, landContacts: 0, boundaryContacts: 0, encounters: encounters,
                    encountersEndingInFouls: fouls, encountersToFoulsShare: share(fouls, of: encounters))
    }

    /// A race's result with `seats`, of an all-National live fleet unless `mix` or `profiles` says otherwise.
    private func result(_ seats: [SeatMetrics], mix: TierMix = .national, profiles: ProfileMix = .live) -> RaceResult {
        let cell = BotRaceCell(seed: 1, venue: "dev-venue@3", conditions: "classic-oscillating@3", tideStateDegrees: 0,
                               fleetSize: seats.count, tierMix: mix, profileMix: profiles, laps: 2,
                               capSecondsAfterGun: BotMatrix.defaultCapSecondsAfterGun)
        return RaceResult(cell: cell, finalTick: 0, capped: false, tideStateAtGun: nil, seats: seats,
                          ranks: seats.indices.map { $0 + 1 }, hullLength: 5, timings: TickTimings(samples: [], cpuSeconds: 0))
    }

    /// #101 acceptance: at most 2 % of the National bots' encounters end in a rule call, over the all-National live
    /// fleets. The bundled thresholds' `conduct` block holds it (a new limit; the tiers' contacts-to-fouls limits stay as
    /// they were, never loosened), the full navigation run sails those fleets, and the gate counts every one of their
    /// seats' encounters together: a run at 2 % passes, one over it fails on that limit alone, and a run that sailed no
    /// such fleet, like the smoke, isn't gated on it at all. A thresholds file from before #101 has no `conduct` block,
    /// and gates none.
    @Test func nationalEncountersToFoulsAtMost2Percent() throws {
        var bundled = try BotThresholds.bundled()
        let limits = try #require(bundled.conduct)
        #expect(limits == ConductLimits(maxEncountersToFoulsShare: 0.02))
        for tier in BotTier.allCases {
            #expect(bundled.tiers[tier.rawValue]?.maxContactsToFoulsShare == 1, "\(tier): contacts to fouls as it was")
        }
        let fullRun = try BotSuiteOptions(arguments: BotNavigationSuiteTests.fullRun).matrix()
        #expect(!fullRun.cells.isEmpty && fullRun.cells.allSatisfy(\.isAllNationalLive), "the full run sails the fleets")

        // The conduct limit alone.
        let gate = BotThresholds(tiers: [:], conduct: limits, maxP99TickMs: .greatestFiniteMagnitude)
        func breaches(_ races: [RaceResult]) -> [String] {
            BotSuiteReport(matrix: fullRun, thresholds: gate, races: races).breaches
        }
        // 1 in 50 of their encounters, over several seats and races.
        let atTheLimit = [result([seat(0, encounters: 20, fouls: 1), seat(1, encounters: 10, fouls: 0)]),
                          result([seat(0, encounters: 20, fouls: 0)])]
        let summary = try #require(ConductSummary(atTheLimit))
        #expect(summary.races == 2 && summary.seats == 3)
        #expect(summary.encounters == 50 && summary.encountersEndingInFouls == 1)
        #expect(summary.encountersToFoulsShare == 0.02)
        #expect(breaches(atTheLimit).isEmpty, "the limit is inclusive")
        let over = [result([seat(0, encounters: 500, fouls: 11)]), result([seat(0, encounters: 500, fouls: 10)])]
        #expect(breaches(over) == ["conduct: encounters to fouls 0.021 > 0.020"])
        #expect(breaches([result([seat(0, encounters: 0, fouls: 0)])]).isEmpty, "no encounters, no share")
        // Only the all-National live fleets count.
        let fouled = [seat(0, encounters: 10, fouls: 5), seat(1, encounters: 10, fouls: 5)]
        let others = [result(fouled, mix: .mixed), result(fouled, mix: .seeded), result(fouled, profiles: .skillGap)]
        #expect(ConductSummary(others) == nil)
        #expect(breaches(others).isEmpty, "no all-National live fleet sailed")
        #expect(ConductSummary(atTheLimit + others) == summary)

        // The bundled thresholds: the smoke's run (`BotSuiteSmokeTests`, three mixed-tier races) passes however its
        // National seats' encounters end, since no tier's limits hold them; the same seats in an all-National live
        // fleet breach the conduct limit, and only that.
        bundled.maxP99TickMs = .greatestFiniteMagnitude
        let smoke = BotMatrix(seeds: [1, 2, 3], fleetSizes: [10], tierMixes: [.mixed], laps: 1)
        #expect(smoke.cells.allSatisfy { !$0.isAllNationalLive })
        let smokeReport = BotSuiteReport(matrix: smoke, thresholds: bundled, races: [result(fouled, mix: .mixed)])
        #expect(smokeReport.tiers[BotTier.national.rawValue]?.encountersToFoulsShare == 0.5)
        #expect(smokeReport.conduct == nil)
        #expect(smokeReport.passed, "\(smokeReport.breaches)")
        let fleetReport = BotSuiteReport(matrix: fullRun, thresholds: bundled, races: [result(fouled)])
        #expect(fleetReport.breaches == ["conduct: encounters to fouls 0.500 > 0.020"])
        #expect(fleetReport.lines.contains("conduct: 1 all-National races, 2 boats, encounters 20, 10 ending in fouls (0.500)"))

        // A thresholds file from before #101, as main shipped it: no conduct limits, so none gated.
        let old = try JSONDecoder().decode(BotThresholds.self, from: Data(#"""
            {
              "maxP99TickMs": 10,
              "tiers": {
                "national": { "minFinishShare": 0.75, "maxMeanIronsSeconds": 10, "maxMeanMarkContacts": 2,
                              "maxContactsToFoulsShare": 1, "maxMeanEdgeSeconds": 30 }
              },
              "navigation": { "minFinishShare": 0.98, "maxDSQMissedPenalty": 0, "maxEdgeShare": 0.02,
                              "maxMarkContactsPerBoat": 0.2 }
            }
            """#.utf8))
        #expect(old.conduct == nil)
        #expect(old.tiers[BotTier.national.rawValue] == bundled.tiers[BotTier.national.rawValue])
        #expect(old.navigation == bundled.navigation)
        let calm = BotSuiteReport.RunTimings(maxP99Ms: 1, maxMs: 1)
        #expect(old.breaches(tiers: [:], timings: calm, conduct: ConductSummary(over)).isEmpty)
    }

    /// Two boats sailing on, nobody at the helm (seat 0 at `position0`, seat 1 at `position1`), after the gun: each
    /// racing, at `speed`, her autohelm holding her wind angle.
    private func race(_ placements: [(position: Vec2, heading: Double)], speed: Double = 4) throws -> Race {
        let setup = try RaceSetup(raceSeed: RaceSeed(5), seats: [.human, .human], laps: 1,
                                  startSequenceTicks: 30 * Race.tickRate)
        let race = Race(setup: setup, windSeed: BotRaceHarness.windSeed(for: 5))
        for _ in 0..<(setup.startSequenceTicks + Race.tickRate) { race.step() }
        let wind = race.seatView(for: 0).own.windDirection
        var snapshot = race.exportSnapshot()
        for (seat, placement) in placements.enumerated() {
            let relative = wrapAngle(wind - placement.heading)
            snapshot.seats[seat].boat.status = .racing
            snapshot.seats[seat].boat.position = placement.position
            snapshot.seats[seat].boat.heading = placement.heading
            snapshot.seats[seat].boat.speed = speed
            snapshot.seats[seat].boat.boomSide = relative >= 0 ? .port : .starboard
            snapshot.seats[seat].boat.autohelm = Autohelm(target: .angle(abs(relative)))
            snapshot.seats[seat].boat.rudder = 0
            snapshot.seats[seat].heldInput = .neutral
        }
        try race.importSnapshot(snapshot)
        _ = race.drainEvents()
        return race
    }

    /// Sails `race` for `seconds`, tallying: each seat's encounters, those ending in fouls, and the rule calls made.
    private func tally(_ race: Race, seconds: Double) -> (metrics: [SeatMetrics], calls: Int) {
        var tally = RaceTally(race: race)
        var calls = 0
        for _ in 0..<Int(seconds * Double(Race.tickRate)) {
            race.step()
            let events = race.drainEvents()
            calls += events.filter { if case .ruleCall = $0.kind { true } else { false } }.count
            tally.record(race, events: events)
        }
        let metrics = race.boats.indices.map {
            tally.metrics(seat: $0, of: race, tier: .national, profile: nil, style: nil)
        }
        return (metrics, calls)
    }

    /// The harness counts encounters as the owner defined them: a pair within 2 hull lengths, hull to hull, while one
    /// must keep clear, once until they separate; ending in a foul when a rule call is made between them during it.
    @Test func harnessCountsEncountersAndTheFoulsTheyEndIn() throws {
        let base = try race([(.zero, 0), (.zero, 0)])
        let wind = base.seatView(for: 0).own.windDirection
        let c = base.course
        let centre = c.startLine.centre + c.upwind * (c.beat * 0.4)
        let length = base.boatClass.hull.length
        let starboard = wind - deg2rad(90), port = wind + deg2rad(90)

        // Port and starboard reaching into each other, nobody at the helm: they touch, rule 10 is called, and that
        // one encounter ends in a foul, for each of them.
        let collide = try race([(centre - Vec2.heading(starboard) * 12, starboard), (centre - Vec2.heading(port) * 12, port)])
        let fouled = tally(collide, seconds: 6)
        #expect(fouled.calls >= 1)
        for seat in fouled.metrics {
            #expect(seat.encounters >= 1 && seat.encountersEndingInFouls >= 1, "seat \(seat.seat): \(seat.encounters)")
            #expect(seat.encountersEndingInFouls <= seat.encounters)
            #expect(seat.encountersToFoulsShare == share(seat.encountersEndingInFouls, of: seat.encounters))
        }

        // Side by side on starboard a hull length and a half apart, hull to hull less than 2 lengths, never touching:
        // one encounter each, held open while they sail on together, no foul.
        let abeam = Vec2.heading(starboard).rightPerp * (length * 1.5)
        let together = try race([(centre, starboard), (centre + abeam, starboard)])
        let clean = tally(together, seconds: 6)
        #expect(clean.calls == 0)
        #expect(clean.metrics.map(\.encounters) == [1, 1] && clean.metrics.map(\.encountersEndingInFouls) == [0, 0])
        #expect(clean.metrics.map(\.encountersToFoulsShare) == [0, 0])

        // Far apart: none.
        let apart = try race([(centre, starboard), (centre + abeam * 20, starboard)])
        #expect(tally(apart, seconds: 3).metrics.map(\.encounters) == [0, 0])

        // The gate's summary takes the counts as the harness made them, both races' seats together.
        let seats = fouled.metrics + clean.metrics
        let summary = try #require(ConductSummary([result(fouled.metrics), result(clean.metrics)]))
        #expect(summary.races == 2 && summary.seats == 4)
        #expect(summary.encounters == seats.reduce(0) { $0 + $1.encounters })
        #expect(summary.encountersEndingInFouls == seats.reduce(0) { $0 + $1.encountersEndingInFouls })
        #expect(summary.encountersEndingInFouls >= 2 && summary.encountersEndingInFouls < summary.encounters)
        #expect(summary.encountersToFoulsShare == share(summary.encountersEndingInFouls, of: summary.encounters))
    }

    #if os(macOS) || os(Linux)
    /// The CLI gives conduct for an all-National live fleet: in its JSON report, and as a line of its text one.
    @Test func reportGivesConduct() throws {
        let matrix = BotMatrix(seeds: [1], fleetSizes: [2], tierMixes: [.national], laps: 1, capSecondsAfterGun: 60)
        let json = FileManager.default.temporaryDirectory.appendingPathComponent("botsuite-conduct-\(UUID().uuidString).json")
        let run = try botsuite(["--matrix", try fixture(matrix, named: "conduct-matrix"),
                                "--thresholds", try fixture(unmissableThresholds(), named: "unmissable"), "--json", json.path])
        #expect(run.status == 0)
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any])
        let conduct = try #require(object["conduct"] as? [String: Any])
        for key in ["races", "seats", "encounters", "encountersEndingInFouls", "encountersToFoulsShare"] {
            #expect(conduct[key] != nil, "conduct has no \(key)")
        }
        let report = try JSONDecoder().decode(BotSuiteReport.self, from: Data(contentsOf: json))
        let summary = try #require(report.conduct)
        #expect(summary.races == 1 && summary.seats == 2)
        let race = try #require(report.races.first)
        #expect(summary.encounters == race.seats.reduce(0) { $0 + $1.encounters })
        #expect(run.stdout.contains("conduct: 1 all-National races, 2 boats, encounters \(summary.encounters), "))
    }
    #endif
}
