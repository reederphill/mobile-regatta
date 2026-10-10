@testable import BotSuite
import RegattaBots
import Foundation
import RegattaCore
import Testing

/// #234: close encounters, the racing a mid-fleet boat sees (#223: "the bot suite counts close encounters per race for a
/// mid-fleet boat (crossings within 3 hull lengths, time in or giving shadow, covers), floor ~8 per race
/// (placeholder)"). Counted per seat by the harness (`SeatMetrics.closeEncounters`), averaged over each race's middle
/// third by rank, and gated over the all-National live fleets (`CloseEncounterSummary`, `EncounterLimits`), as conduct
/// is. The fleets are the CLI's full navigation run,
///
///     scripts/heavy.sh swift run -c release --package-path Packages/RegattaCore regatta-botsuite \
///         --tier-mix national --profile-mix live
///
/// which exits 1 when a mid-fleet boat meets fewer than the floor.
@Suite struct BotEncounterSuiteTests {
    /// Two boats after the gun, nobody at the helm, each racing at `speed` with her autohelm holding her wind angle.
    private func race(_ placements: [(position: Vec2, heading: Double)], speed: Double = 4) throws -> Race {
        let setup = try RaceSetup(raceSeed: RaceSeed(5), seats: [.human, .human], laps: 1,
                                  startSequenceTicks: 30 * Race.tickRate)
        let race = Race(setup: setup, windSeed: BotRaceHarness.windSeed(for: 5))
        for _ in 0..<(setup.startSequenceTicks + Race.tickRate) { race.step() }
        try place(race, placements, speed: speed)
        return race
    }

    private func place(_ race: Race, _ placements: [(position: Vec2, heading: Double)], speed: Double = 4) throws {
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
            snapshot.seats[seat].boat.isTacking = false
            snapshot.seats[seat].heldInput = .neutral
        }
        // Placed boats start in clean air (#377): no ribbons, headers or backwind from where they were.
        snapshot.ribbonPoints = []
        snapshot.emissionLevels = []
        snapshot.headers = []
        snapshot.backwind = BackwindSails()
        try race.importSnapshot(snapshot)
        _ = race.drainEvents()
    }

    /// Sails `race` for `seconds` with the harness's tally, tapping each seat's tack in `taps` (seconds from now). On a
    /// class whose tap sails nothing (skiff@8, #461) the seat tacks by hand instead: 60 % rudder towards the wind from
    /// the tap's tick, let go close-hauled on her new tack.
    private func tally(_ race: Race, seconds: Double, taps: [(seat: Int, at: Double)] = []) -> [SeatMetrics] {
        var tally = RaceTally(race: race)
        let start = race.tick
        let byHand = !race.boatClass.steering.autohelm.sailsTap
        var tackingFrom: [Int: Tack] = [:]
        for _ in 0..<Int(seconds * Double(Race.tickRate)) {
            for tap in taps where race.tick - start == Int(tap.at * Double(Race.tickRate)) {
                guard byHand else {
                    race.tap(.tackGybe, seat: tap.seat, atTick: race.tick + 1)
                    continue
                }
                let boat = race.boats[tap.seat]
                tackingFrom[tap.seat] = boat.tack
                race.apply(BoatInput(rudder: boat.boomSide == .port ? 0.6 : -0.6), seat: tap.seat, atTick: race.tick + 1)
            }
            for (seat, from) in tackingFrom where race.boats[seat].tack != from && race.boats[seat].twa >= deg2rad(40) {
                race.apply(.neutral, seat: seat, atTick: race.tick + 1)
                tackingFrom[seat] = nil
            }
            race.step()
            tally.record(race, events: race.drainEvents())
        }
        return race.boats.indices.map { tally.metrics(seat: $0, of: race, tier: .national, profile: nil, style: nil) }
    }

    /// The harness counts close encounters as #234 has them: a crossing of two boats on opposite tacks within 3 hull
    /// lengths, centre to centre, once; an episode of 2 s or more in a caster's shadow, for the caster and the boat in
    /// it; a tack onto the tack of a boat behind that tacked onto it 10 s before or less, for the boat that covers.
    @Test func harnessCountsCloseEncounters() throws {
        let base = try race([(.zero, 0), (.zero, 0)])
        let wind = base.seatView(for: 0).own.windDirection
        let c = base.course
        let centre = c.startLine.centre + c.upwind * (c.beat * 0.4)
        let length = base.boatClass.hull.length
        let starboard = wind - deg2rad(90), port = wind + deg2rad(90)
        let toWindward = Vec2.heading(wind)

        // Reaching past each other on opposite tacks 2 lengths apart: one crossing each, no more as they sail on apart.
        let crossing = try race([(centre - Vec2.heading(starboard) * 20, starboard),
                                 (centre + toWindward * (2 * length) - Vec2.heading(port) * 20, port)])
        let crossed = tally(crossing, seconds: 12)
        #expect(crossed.map(\.crossings) == [1, 1])
        #expect(crossed.map(\.covers) == [0, 0])
        // The same 6 lengths apart: none.
        let wide = try race([(centre - Vec2.heading(starboard) * 20, starboard),
                             (centre + toWindward * (6 * length) - Vec2.heading(port) * 20, port)])
        #expect(tally(wide, seconds: 12).map(\.crossings) == [0, 0])

        // Seat 1 two lengths down seat 0's apparent wind, sailing with her: once seat 0's ribbon has formed over her
        // (#377), one episode, given by seat 0 and received by seat 1; the same tack, so no crossing.
        let shadowed = try race([(centre, starboard), (centre, starboard)])
        let cone = try #require(shadowed.shadowCone(ofSeat: 0))
        try place(shadowed, [(centre, starboard), (centre + cone.axis * (2 * length), starboard)])
        let shade = tally(shadowed, seconds: 8)
        #expect(shade.map(\.shadowGiven) == [1, 0] && shade.map(\.shadowReceived) == [0, 1])
        #expect(shade.map(\.crossings) == [0, 0])
        #expect(shade.map(\.closeEncounters) == [1, 1])

        // Both beating on port, seat 0 four lengths ahead up the course: seat 1 tacks onto starboard, and seat 0 tacks
        // with her 3 s later, covering her. Seat 1's tack covers nobody.
        let beat = wind + deg2rad(45)
        let covering = try race([(centre + c.upwind * (4 * length), beat), (centre, beat)])
        let covered = tally(covering, seconds: 8, taps: [(1, 0), (0, 3)])
        #expect(covering.boats.map(\.tack) == [.starboard, .starboard], "both tacked")
        #expect(covered.map(\.covers) == [1, 0])
        for seat in covered + crossed + shade {
            #expect(seat.closeEncounters == seat.crossings + seat.shadowGiven + seat.shadowReceived + seat.covers)
        }
    }

    private func seat(_ seat: Int, close: Int, place: Int) -> SeatMetrics {
        SeatMetrics(seat: seat, tier: .national, skill: 0.9, status: "finished", finished: true, place: place,
                    ironsSeconds: 0, markContacts: 0, boatContacts: 0, contactsEndingInFouls: 0, contactsToFoulsShare: 0,
                    foulsAsOffender: 0, dsqMissedPenalty: 0, ocsCount: 0, edgeSeconds: 0, landContacts: 0,
                    boundaryContacts: 0, closeEncounters: close, crossings: close)
    }

    /// A race's result with `seats` finishing in seat order, of an all-National live fleet unless `mix` says otherwise.
    private func result(_ seats: [SeatMetrics], mix: TierMix = .national) -> RaceResult {
        let cell = BotRaceCell(seed: 1, venue: "dev-venue@3", conditions: "classic-oscillating@3", tideStateDegrees: 0,
                               fleetSize: seats.count, tierMix: mix, profileMix: .live, laps: 2,
                               capSecondsAfterGun: BotMatrix.defaultCapSecondsAfterGun)
        return RaceResult(cell: cell, finalTick: 0, capped: false, tideStateAtGun: nil, seats: seats,
                          ranks: seats.map { $0.place ?? seats.count }, hullLength: 5,
                          timings: TickTimings(samples: [], cpuSeconds: 0))
    }

    /// The gate: a mid-fleet boat (the middle third by rank) meets at least `minCloseEncountersPerRace` close encounters
    /// per race on average over the all-National live fleets; the bundled floor is #223's placeholder, 8. A run at the
    /// floor passes, one under it fails on that limit alone; a run with no such fleet isn't gated; a thresholds file
    /// from before #234 gates none.
    @Test func closeEncounterFloorGatesTheMidFleet() throws {
        #expect(midFleet(Array(1...10)) == [4, 5, 6])
        #expect(midFleet([2, 1]) == [0])
        #expect(midFleet([3, 1, 2]) == [2])
        let bundled = try BotThresholds.bundled()
        let limits = try #require(bundled.encounters)
        #expect(limits == EncounterLimits(minCloseEncountersPerRace: 8))

        // Ten boats finishing in seat order, the middle third (seats 4…6) meeting `middle` each, the rest far more.
        func fleet(_ middle: Int) -> RaceResult {
            result((0..<10).map { seat($0, close: (4...6).contains($0) ? middle : 50, place: $0 + 1) })
        }
        let gate = BotThresholds(tiers: [:], encounters: limits, maxP99TickMs: .greatestFiniteMagnitude)
        let matrix = BotMatrix(seeds: [1], fleetSizes: [10], tierMixes: [.national], laps: 2)
        func breaches(_ races: [RaceResult]) -> [String] {
            BotSuiteReport(matrix: matrix, thresholds: gate, races: races).breaches
        }
        let summary = try #require(CloseEncounterSummary([fleet(6), fleet(10)]))
        #expect(summary.races == 2 && summary.midFleetSeats == 6)
        #expect(summary.closeEncountersPerRace == 8 && summary.crossingsPerRace == 8)
        #expect(breaches([fleet(6), fleet(10)]).isEmpty, "the floor is inclusive")
        #expect(breaches([fleet(7)]) == ["encounters: close encounters 7.00 per mid-fleet boat per race < 8.00"])
        #expect(CloseEncounterSummary([result(fleet(0).seats, mix: .mixed)]) == nil)
        #expect(breaches([result(fleet(0).seats, mix: .mixed)]).isEmpty, "no all-National live fleet sailed")
        let report = BotSuiteReport(matrix: matrix, thresholds: gate, races: [fleet(7)])
        #expect(report.lines.contains { $0.hasPrefix("close encounters: 1 all-National races, 7.00 per mid-fleet boat per race") })

        let old = try JSONDecoder().decode(BotThresholds.self, from: Data(#"{"maxP99TickMs": 10, "tiers": {}}"#.utf8))
        #expect(old.encounters == nil)
        let calm = BotSuiteReport.RunTimings(maxP99Ms: 1, maxMs: 1)
        #expect(old.breaches(tiers: [:], timings: calm, closeEncounters: CloseEncounterSummary([fleet(0)])).isEmpty)
    }

    #if os(macOS) || os(Linux)
    /// #234 acceptance: the CLI gives close encounters in its JSON report, every seat's counts and the run's summary,
    /// and a fixture threshold the run misses (a floor no two-boat minute meets) exits non-zero on it.
    @Test func closeEncounterBreachExitsNonZero() throws {
        let matrix = BotMatrix(seeds: [1], fleetSizes: [2], tierMixes: [.national], laps: 1, capSecondsAfterGun: 60)
        var floor = unmissableThresholds()
        floor.encounters = EncounterLimits(minCloseEncountersPerRace: 1_000)
        let json = FileManager.default.temporaryDirectory.appendingPathComponent("botsuite-encounters-\(UUID().uuidString).json")
        let failing = try botsuite(["--matrix", try fixture(matrix, named: "encounter-matrix"),
                                    "--thresholds", try fixture(floor, named: "encounter-floor"), "--json", json.path])
        #expect(failing.status == 1)
        #expect(failing.stdout.contains("gate: FAIL"))
        #expect(failing.stdout.contains("encounters: close encounters "))

        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any])
        let summary = try #require(object["closeEncounters"] as? [String: Any])
        for key in ["races", "midFleetSeats", "closeEncountersPerRace", "crossingsPerRace", "shadowGivenPerRace",
                    "shadowReceivedPerRace", "coversPerRace"] {
            #expect(summary[key] != nil, "closeEncounters has no \(key)")
        }
        let races = try #require(object["races"] as? [[String: Any]])
        for seat in try #require(races.first?["seats"] as? [[String: Any]]) {
            for key in ["closeEncounters", "crossings", "shadowGiven", "shadowReceived", "covers"] {
                #expect(seat[key] != nil, "seat has no \(key)")
            }
        }
        let report = try JSONDecoder().decode(BotSuiteReport.self, from: Data(contentsOf: json))
        #expect(report.races.first?.midFleetSeats?.count == 1)

        let passing = try botsuite(["--matrix", try fixture(matrix, named: "encounter-matrix"),
                                    "--thresholds", try fixture(unmissableThresholds(), named: "unmissable")])
        #expect(passing.status == 0)
    }
    #endif
}
