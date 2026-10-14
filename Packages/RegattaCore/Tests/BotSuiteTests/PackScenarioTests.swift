@testable import BotSuite
import Foundation
import RegattaBots
import RegattaCore
import Testing

/// `regatta-botsuite --scenario pack` (#525, step 0): a bunch of boats above the leeward gate, sailed by the live bots.
@Suite struct PackScenarioTests {
    /// The options for a small run: `arguments` on `--scenario pack`.
    private func options(_ arguments: [String]) throws -> BotSuiteOptions {
        try BotSuiteOptions(arguments: ["--scenario", "pack"] + arguments)
    }

    private func cell(seed: UInt64 = 1, current: Bool = false, size: Int = 5, offset: Double = 0, gybes: PackGybes = .same,
                      above: Double = PackScenario.defaultAbove) -> PackCell {
        PackCell(seed: seed, layout: PackLayout(current: current, size: size, offset: offset, gybes: gybes), tierMix: .national,
                 above: above)
    }

    // MARK: 1. deterministic

    /// The same options sail the same races: two runs give equal per-race results, one job or four.
    @Test func sameOptionsSailTheSameRaces() throws {
        let small = try options(["--seeds", "2", "--fleet-size", "4", "--pack-offset", "0"])
        let serial = try PackScenario.run(small.with(jobs: 1))
        let again = try PackScenario.run(small.with(jobs: 1))
        let parallel = try PackScenario.run(small.with(jobs: 4))
        #expect(serial.races.count == 2 * 2 * 2, "two seeds, with and without a current, both gybes")
        #expect(serial.races == again.races)
        #expect(serial.races == parallel.races)
        #expect(try serial.jsonData() == parallel.jsonData())
    }

    // MARK: 2. nothing changes without --scenario

    /// Without `--scenario` the options are the matrix's: no scenario, none of its flags, and the help text is the one
    /// output that gains the new flags. (The rest, the plain and the `--diagnose` report, is compared with main's by the
    /// tester: no source of the matrix's run changes.)
    @Test func withoutAScenarioNothingChanges() throws {
        let plain = try BotSuiteOptions(arguments: ["--seeds", "2", "--fleet-size", "5", "--diagnose"])
        #expect(plain.scenario == nil && plain.packCurrent == nil && plain.packOffsets.isEmpty && plain.packAbove == nil)
        for flag in ["--scenario", "--pack-current", "--pack-offset", "--pack-above"] {
            #expect(BotSuiteOptions.usage.contains(flag), "\(flag) is in --help")
        }
        for flag in ["--pack-current", "--pack-offset", "--pack-above"] {
            #expect(throws: BotSuiteError.self) { try BotSuiteOptions(arguments: [flag, "0"]) }
        }
        // The matrix is what it was: the pack scenario's venues and layouts add nothing to it.
        let matrix = try plain.matrix()
        #expect(matrix.fleetSizes == [5] && matrix.seeds == [1, 2])
    }

    // MARK: 3. placement

    /// n boats, all racing the gate leg, the bunch's centre `above` the gate and `offset` hull lengths across it, inside
    /// the race area, apart at placement and a pack, on the downwind groove.
    @Test(arguments: [4, 5, 6])
    func boatsAreBunchedAboveTheGate(size: Int) throws {
        for offset in [-6.0, 0.0, 6.0] {
          for gybes in PackGybes.allCases {
            for seed in UInt64(1)...3 {
              for current in [true, false] {
                let cell = cell(seed: seed, current: current, size: size, offset: offset, gybes: gybes)
                let (race, _, poses) = try PackScenario.placedRace(cell)
                let geometry = try PackScenario.Geometry(race)
                let length = geometry.hullLength
                let centre = geometry.gate + geometry.up * cell.above + geometry.right * (offset * length)
                let boats = race.boats
                #expect(boats.count == size && poses.count == size)
                for boat in boats {
                    #expect(boat.status == .racing && boat.legIndex == 2 && boat.roundingStage == 0)
                    #expect((boat.position - centre).length <= PackScenario.discLengths * length + 1e-9)
                    #expect(race.course.raceArea.inset(boat.position) > 0)
                    // On the downwind groove: the best downwind angle on one gybe or the other, at its speed.
                    let wind = race.groundWind(at: centre)
                    let down = race.boatClass.polar.bestDownwind(tws: wind.speed)
                    #expect(abs(abs(wrapAngle(wind.direction - boat.heading)) - down.twa) < 1e-9)
                    #expect(abs(boat.speed - down.speed) < 1e-9)
                    // Her autohelm holds the wind angle, her boom is on the side the wind is not.
                    #expect(boat.autohelm != nil)
                }
                for (i, a) in boats.enumerated() {
                    let others = boats.indices.filter { $0 != i }
                    #expect(others.allSatisfy { (boats[$0].position - a.position).length >= PackScenario.spacingLengths * length })
                    #expect(others.filter { (boats[$0].position - a.position).length <= PackScenario.packRange }.count
                        >= PackScenario.packNeighbours, "a pack at placement")
                }
                let sides = Set(boats.map(\.boomSide))
                #expect(gybes == .same ? sides.count == 1 : sides.count == 2, "\(gybes): \(sides)")
                // The gate leg, as the roundings read it.
                #expect(race.course.legs[2] == .round(CourseLayout.gateIndex))
              }
            }
          }
        }
    }

    /// A positive offset is over the gate's left mark (mark 0 in the report), a negative one over the right.
    @Test func offsetsLieOverTheirMarks() throws {
        for (offset, mark) in [(-6.0, 1), (6.0, 0)] {
            let (race, _, poses) = try PackScenario.placedRace(cell(offset: offset))
            let geometry = try PackScenario.Geometry(race)
            let mean = poses.map(\.position).reduce(Vec2.zero, +) / Double(poses.count)
            let side = (mean - geometry.gate).dot(geometry.along) < 0 ? 0 : 1
            #expect(side == mark, "offset \(offset)")
        }
    }

    /// The bunch is drawn from the seed and the layout: the same ones twice, and a race with a current draws the bunch a
    /// race without one does.
    @Test func theBunchIsSeeded() throws {
        let a = try PackScenario.placedRace(cell(seed: 3, current: false)).poses
        let b = try PackScenario.placedRace(cell(seed: 3, current: false)).poses
        let c = try PackScenario.placedRace(cell(seed: 4, current: false)).poses
        #expect(a == b && a != c)
        let wet = try PackScenario.placedRace(cell(seed: 3, current: true)).poses
        #expect(wet.map(\.seat) == a.map(\.seat))
    }

    /// A bunch that can't be placed, here one outside the race area, throws after its draws.
    @Test func anImpossibleBunchThrows() throws {
        #expect(throws: PackScenarioError.self) { try PackScenario.placedRace(cell(offset: 500)) }
    }

    // MARK: 4. the pack definition

    /// In a pack at her entry: at least two other boats racing the gate leg, not yet round the mark, within 20 m. A race
    /// holds its pack if a boat is in one.
    @Test func aBoatIsInAPackWithTwoOthersWithin20Metres() throws {
        let cell = cell(size: 4, above: 60)
        let (race, _, poses) = try PackScenario.placedRace(cell)
        let geometry = try PackScenario.Geometry(race)
        // Three boats within 20 m of each other, the fourth 32 m across the course from them.
        let base = geometry.gate + geometry.up * 60
        let spots = [base, base + geometry.right * 8, base - geometry.right * 8 + geometry.up * 5, base + geometry.right * 40]
        var placed = poses
        for index in placed.indices { placed[index].position = spots[index] }
        try PackScenario.place(placed, in: race)
        var probe = PackProbe(race: race, geometry: geometry)
        probe.record(race)
        #expect(probe.neighbours == [2, 2, 2, 0])
        #expect(probe.inPack == [true, true, true, false])
        // Two neighbours are a pack, one is not.
        placed[2].position = base + geometry.right * 40 - geometry.up * 10
        try PackScenario.place(placed, in: race)
        var pair = PackProbe(race: race, geometry: geometry)
        pair.record(race)
        #expect(pair.neighbours == [1, 1, 1, 1])
        #expect(pair.inPack == [false, false, false, false])
        let spread = PackRaceResult(seed: 1, layout: cell.layout, tierMix: .national, tideStateAtGun: nil, ticks: 0, capped: false,
                                    maxCurrent: 0, boats: [boat(inPack: false), boat(inPack: true)])
        #expect(spread.holdsPack)
        #expect(!PackRaceResult(seed: 1, layout: cell.layout, tierMix: .national, tideStateAtGun: nil, ticks: 0, capped: false,
                                maxCurrent: 0, boats: [boat(inPack: false)]).holdsPack)
    }

    /// A boat is judged on the tick she enters: 80 m from the gate's centre and more than 3 m above it. One placed 100 m
    /// above has not entered, so she has no neighbours counted yet.
    @Test func entryIsWithin80MetresAndAboveTheGate() throws {
        let (race, _, _) = try PackScenario.placedRace(cell(size: 4))
        var probe = PackProbe(race: race, geometry: try PackScenario.Geometry(race))
        probe.record(race)
        #expect(probe.neighbours.allSatisfy { $0 == nil } && probe.inPack.allSatisfy { !$0 })
    }

    private func boat(inPack: Bool) -> PackBoatResult {
        PackBoatResult(seat: 0, tier: "national", inPack: inPack, dirtySeconds: 0, boatContacts: 0, markTouches: 0, calls: 0,
                       callsByRule: [:])
    }

    // MARK: 5. with and without a current

    /// A boat's current is non-zero somewhere in a race with a current, and zero throughout one without.
    @Test func currentIsInTheWithRacesAlone() throws {
        let with = try PackScenario.sail(cell(current: true, size: 4))
        let without = try PackScenario.sail(cell(current: false, size: 4))
        #expect(with.maxCurrent > 0)
        #expect(without.maxCurrent == 0)
        #expect(with.layout.venue == "saltings-reach@1" && without.layout.venue == "dev-venue@7")
        #expect(with.tideStateAtGun != nil, "the JSON gives the tide state at the gun")
    }

    // MARK: sailing

    /// The bots sail the bunch to the gate and round it, and the race ends on its own rule, not the cap.
    @Test func theBunchRoundsTheGate() throws {
        let race = try PackScenario.sail(cell(size: 4))
        #expect(!race.capped)
        #expect(race.boats.count == 4 && race.boats.allSatisfy { $0.markUsed != nil && $0.completed })
        #expect(race.boats.allSatisfy { ($0.extraMetres ?? 0) > -50 && ($0.dirtySeconds) >= 0 })
        #expect(race.ticks > 0 && race.ticks < PackScenario.capSeconds * Race.tickRate)
    }

    // MARK: 6. the report

    /// A small run's report has the columns, and a row for all the races and for each group of them.
    @Test func reportHasTheColumnsAndOneRowPerGroup() throws {
        let report = try PackScenario.run(options(["--seeds", "1", "--fleet-size", "4", "--pack-offset", "0", "--jobs", "1"]))
        let groups = ["all", "current with", "current without", "size 4", "offset 0", "gybes same", "gybes mixed", "tier national"]
        #expect(report.rows.map(\.group) == groups)
        let lines = report.lines
        #expect(lines.count == 1 + 1 + groups.count)
        let header = lines[1]
        for column in ["group", "races", "boats", "pack held", "both marks", "less-used mark", "gate done", "extra m mean",
                       "extra m median", "extra m p90", "extra s mean", "pack extra m", "contacts/race", "touches/race",
                       "calls/race", "calls by rule", "below s mean", "below s p90", "deepest m mean", "deepest m p90",
                       "overshoot", "still below", "dirty s/boat"] {
            #expect(header.contains(column), "\(column) is a column")
        }
        for (line, group) in zip(lines.dropFirst(2), groups) { #expect(line.hasPrefix(group)) }
        // The counts: four races, with and without a current, both gybes.
        let rows = Dictionary(uniqueKeysWithValues: report.rows.map { ($0.group, $0) })
        #expect(rows["all"]?.races == 4 && rows["all"]?.boats == 16)
        #expect(rows["current with"]?.races == 2 && rows["current without"]?.races == 2)
        #expect(rows["tier national"]?.boats == 16)
        // The JSON holds the same rows and, per race, the tide state at the gun.
        let decoded = try JSONDecoder().decode(PackReport.self, from: report.jsonData())
        #expect(decoded == report)
        let json = try #require(try JSONSerialization.jsonObject(with: report.jsonData()) as? [String: Any])
        let raceObjects = try #require(json["races"] as? [[String: Any]])
        #expect(raceObjects.contains { $0["tideStateAtGun"] != nil })
        #expect((json["rows"] as? [[String: Any]])?.count == groups.count)
    }

    /// The columns' arithmetic, on races built by hand.
    @Test func columnsPoolTheBoatsAndRaces() throws {
        func boat(_ seat: Int, mark: Int?, extra: Double?, below: Double = 0, calls: [String: Int] = [:], inPack: Bool = false,
                  contacts: Int = 0, overshoot: Bool = false) -> PackBoatResult {
            PackBoatResult(seat: seat, tier: "national", inPack: inPack, neighbours: 0, markUsed: mark, extraMetres: extra,
                           extraSeconds: extra.map { $0 / 4 }, belowSeconds: extra == nil ? nil : below,
                           deepest: extra == nil ? nil : below * 2, overshoot: extra == nil ? nil : overshoot,
                           stillBelow: extra == nil ? nil : false, dirtySeconds: 2, boatContacts: contacts, markTouches: 0,
                           calls: calls.values.reduce(0, +), callsByRule: calls)
        }
        let layout = PackLayout(current: false, size: 3, offset: 0, gybes: .same)
        let one = PackRaceResult(seed: 1, layout: layout, tierMix: .national, tideStateAtGun: nil, ticks: 10, capped: false,
                                 maxCurrent: 0, boats: [boat(0, mark: 0, extra: 10, below: 4, calls: ["10": 1], inPack: true, contacts: 1),
                                                         boat(1, mark: 0, extra: 30, below: 6, inPack: true, contacts: 1, overshoot: true),
                                                         boat(2, mark: 1, extra: nil)])
        let two = PackRaceResult(seed: 2, layout: layout, tierMix: .national, tideStateAtGun: nil, ticks: 10, capped: false,
                                 maxCurrent: 0, boats: [boat(0, mark: 0, extra: 20), boat(1, mark: 0, extra: 20), boat(2, mark: 0, extra: 20)])
        let report = PackReport(races: [one, two], above: 100)
        let all = try #require(report.rows.first)
        #expect(all.races == 2 && all.boats == 6)
        #expect(all.packHeldShare == 0.5 && all.bothMarksShare == 0.5)
        #expect(all.lessUsedMarkBoats == 0.5, "one boat on the other mark in one race of two")
        #expect(abs(all.gateCompletedShare - 5.0 / 6) < 1e-12)
        #expect(all.extraMetresMean == 20 && all.extraMetresMedian == 20 && all.extraMetresP90 == 30)
        #expect(all.extraSecondsMean == 5)
        #expect(all.packExtraMetresMean == 40, "the two pack members' 10 + 30, in the one race that held a pack")
        #expect(all.boatContactsPerRace == 0.5 && all.callsPerRace == 0.5 && all.callsByRulePerRace == ["10": 0.5])
        #expect(all.belowSecondsMean == 2 && all.belowSecondsP90 == 6)
        #expect(all.deepestMean == 4 && all.deepestP90 == 12)
        #expect(abs(all.overshootShare - 0.2) < 1e-12 && all.stillBelowShare == 0)
        #expect(all.dirtySecondsPerBoat == 2)
    }

    // MARK: 7. bad usage

    @Test func badUsageExitsTwo() throws {
        #expect(throws: BotSuiteError.self) { try BotSuiteOptions(arguments: ["--scenario", "nope"]) }
        for refused in [["--matrix", "m.json"], ["--thresholds", "t.json"], ["--profile-mix", "live"], ["--laps", "1"], ["--diagnose"]] {
            #expect(throws: BotSuiteError.self, "\(refused)") { try options(refused) }
            #expect(BotSuiteCommand.main(arguments: ["--scenario", "pack"] + refused) == 2, "\(refused)")
        }
        #expect(BotSuiteCommand.main(arguments: ["--scenario", "nope"]) == 2)
        #expect(BotSuiteCommand.main(arguments: ["--scenario", "pack", "--pack-current", "sometimes"]) == 2)
        #expect(BotSuiteCommand.main(arguments: ["--scenario", "pack", "--fleet-size", "2"]) == 2)
        #expect(BotSuiteCommand.main(arguments: ["--pack-offset", "3"]) == 2)
    }

    /// No thresholds: a sailed run exits 0, and writes its JSON.
    @Test func aSailedRunExitsZero() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pack-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let status = BotSuiteCommand.main(arguments: ["--scenario", "pack", "--seeds", "1", "--fleet-size", "4", "--pack-offset", "0",
                                                      "--pack-current", "without", "--jobs", "1", "--json", file.path])
        #expect(status == 0)
        let report = try JSONDecoder().decode(PackReport.self, from: Data(contentsOf: file))
        #expect(report.races.count == 2 && report.rows.first?.group == "all")
    }
}

extension BotSuiteOptions {
    /// These options sailed with `jobs` races at once.
    fileprivate func with(jobs: Int) -> BotSuiteOptions {
        var copy = self
        copy.jobs = jobs
        return copy
    }
}
