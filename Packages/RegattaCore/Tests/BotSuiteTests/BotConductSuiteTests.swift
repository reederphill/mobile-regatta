@testable import BotSuite
import Foundation
import RegattaCore
import Testing

/// #101: the bots' conduct under the rules over the suite's fleets, gated on encounters ending in fouls (the owner,
/// 2026-09-27). Every contact ends in a rule call (#100's run: contacts 1.00 fouls), so the share of contacts ending
/// in fouls can't show conduct; the share of encounters can. An encounter is a pair coming within 2 hull lengths of
/// each other while rules 10–13 name one of them to keep clear, counted once until they separate past that again (the
/// separation that closes #88's incidents); it ends in a foul when a rule call is made between the pair during it.
///
/// The fleets are too many full races for `swift test`: the numbers are the CLI's full run over the bundled matrix,
///
///     scripts/heavy.sh swift run -c release --package-path Packages/RegattaCore regatta-botsuite
///
/// (or `--tier-mix national` for the National fleets alone), which exits 1 when the National tier's share is over its
/// limit. These tests hold that gate and the counting to the acceptance.
@Suite struct BotConductSuiteTests {
    private func seat(_ tier: BotTier, encounters: Int, fouls: Int) -> SeatMetrics {
        SeatMetrics(seat: 0, tier: tier, skill: 0.9, status: "finished", finished: true, place: 1, ironsSeconds: 0,
                    markContacts: 0, boatContacts: fouls, contactsEndingInFouls: fouls, contactsToFoulsShare: share(fouls, of: fouls),
                    foulsAsOffender: 0, dsqMissedPenalty: 0, ocsCount: 0, edgeSeconds: 0, landContacts: 0, boundaryContacts: 0,
                    encounters: encounters, encountersEndingInFouls: fouls,
                    encountersToFoulsShare: share(fouls, of: encounters))
    }

    /// #101 acceptance: at most 2 % of National bots' encounters end in a rule call. The bundled thresholds gate the
    /// National tier on it (a new limit; its contacts-to-fouls limit stays as it was, never loosened), the full run
    /// sails National bots, and the gate counts every National seat's encounters together: a run at 2 % passes, one
    /// over it fails on that limit alone.
    @Test func nationalEncountersToFoulsAtMost2Percent() throws {
        let thresholds = try BotThresholds.bundled()
        let national = try #require(thresholds.tiers[BotTier.national.rawValue])
        #expect(national.maxEncountersToFoulsShare == 0.02)
        #expect(national.maxContactsToFoulsShare == 1, "contacts to fouls: as it was")
        for tier in BotTier.allCases where tier != .national {
            #expect(thresholds.tiers[tier.rawValue]?.maxEncountersToFoulsShare == nil, "\(tier): #102's to set")
        }
        let matrix = try BotMatrix.bundled()
        #expect(matrix.tierMixes.contains(.national), "the full run sails National fleets")

        // The National limit alone, every other one out of reach.
        var gate = unmissableThresholds()
        gate.tiers[BotTier.national.rawValue]?.maxEncountersToFoulsShare = national.maxEncountersToFoulsShare
        let calm = BotSuiteReport.RunTimings(maxP99Ms: 1, maxMs: 1)
        func breaches(_ seats: [SeatMetrics]) -> [String] {
            let tiers = Dictionary(grouping: seats, by: { $0.tier.rawValue }).mapValues(TierSummary.init)
            return gate.breaches(tiers: tiers, timings: calm)
        }
        // 1 in 50 of the tier's encounters, over several seats.
        let atTheLimit = [seat(.national, encounters: 20, fouls: 1), seat(.national, encounters: 30, fouls: 0)]
        #expect(TierSummary(atTheLimit).encounters == 50 && TierSummary(atTheLimit).encountersEndingInFouls == 1)
        #expect(TierSummary(atTheLimit).encountersToFoulsShare == 0.02)
        #expect(breaches(atTheLimit).isEmpty, "the limit is inclusive")
        let over = [seat(.national, encounters: 500, fouls: 11), seat(.national, encounters: 500, fouls: 10)]
        #expect(breaches(over) == ["national: encounters to fouls 0.021 > 0.020"])
        // Another tier's fouls are its own.
        #expect(breaches(atTheLimit + [seat(.club, encounters: 10, fouls: 5)]).isEmpty)
        #expect(breaches([seat(.national, encounters: 0, fouls: 0)]).isEmpty, "no encounters, no share")

        // A thresholds file from before #101 gates none.
        let old = try JSONDecoder().decode(TierLimits.self, from: Data(#"""
            {"minFinishShare": 0.75, "maxMeanIronsSeconds": 10, "maxMeanMarkContacts": 2, "maxContactsToFoulsShare": 1,
             "maxMeanEdgeSeconds": 30}
            """#.utf8))
        #expect(old.maxEncountersToFoulsShare == nil)
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
    }
}
