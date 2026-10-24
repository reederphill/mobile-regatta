import Foundation
import RegattaBots
import RegattaCore

// `regatta-timetrial --start --hold-one-out <seat|all>` (#584 stage 2): the gap-finding gap. The start suite's fleet
// sails a seed to T+60 and its log is kept; then each held-out seat's start is planned again by the start oracle
// (`StartOracle`) against the other nine sailing their logged inputs (ADR 0002: a replay runs no brain), the real rules
// on, so she is penalised as racing. The others don't answer her: an open-loop fleet, wrong for a luffing match and right
// for "was there a better hole, and did she see it?". The oracle and the seat's own bot, as she sailed it, are scored at
// T+60 as stage 1, and the ledger's air and forced-move columns (`LapLedger.Cause.air`, `.forced`) split into what the
// oracle paid too (the fleet made it unavoidable) and what the bot paid on top (the gap-finding gap). Measurement only.

/// A start's situation at T−60 (#584 stage 2): the features stage 3's chooser conditions on, defined here once.
public struct StartSituation: Codable, Hashable, Sendable {
    /// The line's bias in the wind at its centre, degrees: the angle the line is off square to it, + the committee end
    /// favoured.
    public var biasDegrees: Double
    /// Boats per 10 m of line in the favoured end's third (a boat beyond that end counts in it), the whole fleet: how
    /// crowded the end everyone wants is.
    public var crowding: Double
    /// Where the opening put her (`lineSpot`: 0 the pin, 1 the committee boat, beyond the ends outside 0...1).
    public var rowSpot: Double
    /// The wind's speed at the line's centre, m/s.
    public var windSpeed: Double

    /// The bands each feature is binned in (owner placeholders, #584 stage 3's coarse cells): bias in three, crowding in
    /// three, her row spot in three, the wind in two.
    public static let biasCuts = [-2.0, 2.0]
    public static let crowdingCuts = [1.0, 2.0]
    public static let rowCuts = [1.0 / 3, 2.0 / 3]
    public static let windCuts = [5.0]

    public static let biasBands = ["pin favoured", "square", "committee favoured"]
    public static let crowdingBands = ["open", "busy", "crowded"]
    public static let rowBands = ["pin third", "middle third", "committee third"]
    public static let windBands = ["light", "breeze"]

    static func band(_ value: Double, _ cuts: [Double]) -> Int { cuts.filter { value >= $0 }.count }

    public var biasBand: Int { Self.band(biasDegrees, Self.biasCuts) }
    public var crowdingBand: Int { Self.band(crowding, Self.crowdingCuts) }
    public var rowBand: Int { Self.band(rowSpot, Self.rowCuts) }
    public var windBand: Int { Self.band(windSpeed, Self.windCuts) }

    /// The situation of `seat` in `world`, a race's at T−60 (the start of the sequence).
    static func of(_ world: WorldSnapshot, seat: Int, race: Race) -> StartSituation {
        let line = race.course.startLine
        let wind = race.groundWind(at: line.centre)
        let windward = Vec2.heading(wind.direction)
        // The committee end's lead up the wind over the pin's, as a share of the line: the sine of the bias.
        let lead = ((line.committee.position - line.pin.position).dot(windward) / line.length).clamped(to: -1...1)
        let biasDegrees = asin(lead) * 180 / .pi
        let spots = world.seats.map { lineSpot($0.boat.position, on: line) }
        let favoured = biasDegrees >= 0
        let atEnd = spots.filter { favoured ? $0 >= 2.0 / 3 : $0 <= 1.0 / 3 }.count
        return StartSituation(biasDegrees: biasDegrees, crowding: Double(atEnd) / (line.length / 3 / 10),
                              rowSpot: spots[seat], windSpeed: wind.speed)
    }
}

/// One held-out seat (#584 stage 2): her bot's start as the fleet sailed it, and the oracle's against the frozen nine.
public struct HoldOneOutSeat: Codable, Hashable, Sendable {
    public var seat: Int
    /// Her tier in the fleet.
    public var tier: String
    public var situation: StartSituation
    public var oracle: StartEntry
    /// Her bot's start, as logged.
    public var bot: StartEntry
    public var oracleNodes: Int
    public var oracleTicks: Int
    /// The re-sailed oracle start's digest at T+60.
    public var oracleDigest: UInt64

    public var loss: StartLoss { StartLoss(bot, oracle: oracle) }
    /// What the bot paid on top of the oracle in the fleet's air and in forced moves: the gap-finding gap.
    public var gapFinding: Double { loss.air + loss.forced }
}

/// One seed of the hold-one-out.
public struct HoldOneOutSeedResult: Codable, Hashable, Sendable {
    public var seed: StartTrialSeed
    /// The fleet's tier mix.
    public var fleet: String
    /// The logged fleet race's digest at T+60.
    public var fleetDigest: UInt64
    public var seats: [HoldOneOutSeat]
}

/// The hold-one-out's report (#584 stage 2).
public struct HoldOneOutReport: Codable, Hashable, Sendable {
    public var oracle: TimeTrialReport.OracleSettings
    public var seeds: [HoldOneOutSeedResult]

    public init(oracle: Oracle.Options, seeds: [HoldOneOutSeedResult]) {
        self.oracle = TimeTrialReport.OracleSettings(oracle)
        self.seeds = seeds
    }

    public var seats: [HoldOneOutSeat] { seeds.flatMap(\.seats) }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// The mean loss of `seats`, as a row named `name`.
    static func mean(_ name: String, _ seats: [HoldOneOutSeat]) -> StartLoss {
        let count = Double(max(seats.count, 1))
        return StartLoss(sailor: name, values: StartLoss.columns.indices.map { i in
            seats.reduce(0) { $0 + $1.loss.values[i] } / count
        })
    }

    public var lines: [String] {
        var lines: [String] = []
        let seats = self.seats
        lines.append("regatta-timetrial --start --hold-one-out: \(seeds.count) seeds, \(seats.count) seats, oracle beam "
            + "\(oracle.beamWidth), horizon \(format(oracle.horizonSeconds)) s, checkpoint \(format(oracle.checkpointSeconds)) s"
            + (oracle.eventCheckpoints ? " and on events" : "") + "; fleets \(Set(seeds.map(\.fleet)).sorted().joined(separator: ", "))")
        guard !seats.isEmpty else { return lines }
        let oracles = seats.map(\.oracle)
        func mean(_ values: [Double]) -> Double { values.reduce(0, +) / Double(max(values.count, 1)) }
        lines.append("oracle: mean worth at T+60 \(format(mean(oracles.map(\.worth)))) m, started "
            + "\(oracles.filter { $0.startSeconds != nil }.count)/\(oracles.count), OCS \(oracles.filter(\.ocs).count), "
            + "penalties \(oracles.map(\.penalties).reduce(0, +)), mean start \(format(mean(oracles.map { $0.startSeconds ?? 60 }))) s")
        let tiers = ["club", "regional", "national"].filter { tier in seats.contains { $0.tier == tier } }
        lines.append("")
        lines.append("mean metres behind the oracle at T+60 against the frozen fleet, by tier (they sum to the gap; air and "
            + "forced are the bot's on top of the oracle's):")
        var rows = [["tier", "seats"] + StartLoss.columns]
        for tier in tiers + ["all"] {
            let group = tier == "all" ? seats : seats.filter { $0.tier == tier }
            rows.append([tier, "\(group.count)"] + Self.mean(tier, group).values.map(format))
        }
        lines += table(rows)
        lines.append("")
        lines.append("the fleet's air and forced moves, metres: what the oracle paid too (unavoidable) and the bot on top, "
            + "the gap-finding gap; starts and penalties:")
        var fleet = [["tier", "oracle air", "oracle forced", "bot air", "bot forced", "gap-finding", "bot start s", "bot OCS",
                      "bot penalties", "oracle start s"]]
        for tier in tiers + ["all"] {
            let group = tier == "all" ? seats : seats.filter { $0.tier == tier }
            fleet.append([tier, format(mean(group.map(\.oracle.air))), format(mean(group.map(\.oracle.forced))),
                          format(mean(group.map(\.loss.air))), format(mean(group.map(\.loss.forced))),
                          format(mean(group.map(\.gapFinding))), format(mean(group.map { $0.bot.startSeconds ?? 60 })),
                          "\(group.filter(\.bot.ocs).count)", "\(group.map(\.bot.penalties).reduce(0, +))",
                          format(mean(group.map { $0.oracle.startSeconds ?? 60 }))])
        }
        lines += table(fleet)
        lines.append("")
        lines.append("by situation at T-60 (stage 3's features): seats, mean gap and gap-finding gap, metres:")
        var situations = [["feature", "band", "seats", "gap", "gap-finding"]]
        let features: [(String, [String], (StartSituation) -> Int)] = [
            ("bias", StartSituation.biasBands, \.biasBand), ("crowding", StartSituation.crowdingBands, \.crowdingBand),
            ("row", StartSituation.rowBands, \.rowBand), ("wind", StartSituation.windBands, \.windBand),
        ]
        for (feature, bands, band) in features {
            for (k, name) in bands.enumerated() {
                let group = seats.filter { band($0.situation) == k }
                situations.append([feature, name, "\(group.count)", format(mean(group.map(\.loss.gap))),
                                   format(mean(group.map(\.gapFinding)))])
            }
        }
        lines += table(situations)
        lines.append("")
        lines.append("per seed and seat, metres behind the oracle (gap-finding gap); the oracle's start s:")
        var seedRows = [["seed", "fleet", "seat", "tier", "bias deg", "crowding", "row", "wind", "gap", "gap-finding", "oracle s",
                         "bot s"]]
        for seed in seeds {
            for seat in seed.seats {
                seedRows.append([seed.seed.name, seed.fleet, "\(seat.seat)", seat.tier, format(seat.situation.biasDegrees),
                                 format(seat.situation.crowding), String(format: "%.2f", seat.situation.rowSpot),
                                 format(seat.situation.windSpeed), format(seat.loss.gap), format(seat.gapFinding),
                                 seat.oracle.startSeconds.map(format) ?? "-",
                                 (seat.bot.ocs ? "OCS " : "") + (seat.bot.startSeconds.map(format) ?? "-")])
            }
        }
        lines += table(seedRows)
        return lines
    }

    private func format(_ value: Double) -> String { String(format: "%.1f", value) }

    private func table(_ rows: [[String]]) -> [String] {
        let widths = (0..<(rows.map(\.count).max() ?? 0)).map { column in
            rows.map { column < $0.count ? $0[column].count : 0 }.max() ?? 0
        }
        return rows.map { row in
            row.enumerated().map { column, cell in
                column == 0 ? cell.padding(toLength: widths[column], withPad: " ", startingAt: 0)
                    : String(repeating: " ", count: widths[column] - cell.count) + cell
            }.joined(separator: "  ")
        }
    }
}

public enum HoldOneOut {
    /// The start suite's cell for `seed` (`BotStartSuiteTests.cells`) with the fleet `tierMix`, stopped at T+60.
    static func cell(_ seed: StartTrialSeed, tierMix: TierMix) -> BotRaceCell {
        BotRaceCell(seed: seed.trial.raceSeed, venue: seed.trial.venue, conditions: seed.trial.conditions, tideStateDegrees: 0,
                    fleetSize: seed.fleetSize, tierMix: tierMix, profileMix: .live, laps: seed.trial.laps,
                    capSecondsAfterGun: Int(StartGeometry.horizonSeconds))
    }

    /// The fleet's race for `seed`: every seat its tier's live bot, as the suite seats them, from the start of the
    /// sequence to T+60; its log and each seat's tier.
    public static func fleet(_ seed: StartTrialSeed, tierMix: TierMix) throws -> (log: RaceLog, tiers: [BotTier]) {
        let cell = cell(seed, tierMix: tierMix)
        let setup = try BotRaceHarness.raceSetup(for: cell)
        let race = try Race(setup: setup, files: BotRaceHarness.raceFiles(for: cell, setup: setup),
                            mode: .authoritative(windSeed: BotRaceHarness.windSeed(for: cell.seed)))
        var drivers = setup.seats.indices.map { tierMix.driver(seat: $0, raceSeed: setup.raceSeed) }
        while race.tick < StartGeometry.horizonTick && !race.isOver {
            for k in drivers.indices { drivers[k].drive(race) }
            race.step()
            _ = race.drainEvents()
        }
        guard let log = race.log else { preconditionFailure("a seeded race logs") }
        return (log, setup.seats.indices.map { tierMix.tier(ofSeat: $0, raceSeed: setup.raceSeed) })
    }

    /// `seat`'s own logged inputs, as the oracle's inputs are sent.
    public static func inputs(of seat: Int, in log: RaceLog) -> [Oracle.Input] {
        log.inputs.filter { $0.seat == seat }.map { record in
            switch record.kind {
            case .held(let input): Oracle.Input(tick: record.tick, held: input)
            case .tap(let tap): Oracle.Input(tick: record.tick, tap: tap)
            }
        }
    }

    /// Holds out `seat` of `log`'s fleet: her bot's start as logged, and the oracle's against the frozen others.
    public static func run(_ log: RaceLog, seat: Int, tier: BotTier, seed: StartTrialSeed, oracle options: Oracle.Options)
        throws -> HoldOneOutSeat {
        let course = try TimeTrialCourse(holdOut: log, seat: seat, seed: seed.trial)
        let race = try course.race()
        let situation = StartSituation.of(course.origin, seat: seat, race: race)
        var bot = try StartTrial.replay(inputs(of: seat, in: log), course: course).entry
        bot.sailor = tier.rawValue
        let plan = try StartOracle(course: course, options: options).search()
        let oracle = try StartTrial.replay(plan.inputs, course: course)
        return HoldOneOutSeat(seat: seat, tier: tier.rawValue, situation: situation, oracle: oracle.entry, bot: bot,
                              oracleNodes: plan.nodes, oracleTicks: plan.ticks, oracleDigest: oracle.digest)
    }

    /// The hold-one-out over `seeds`, each `seats` held out in turn (every seat when nil; of those, only `tier`'s if given:
    /// the confirmation run holds out a mixed fleet's National seats), up to `jobs` at once.
    public static func run(_ seeds: [StartTrialSeed], seats: [Int]?, tier: BotTier? = nil, tierMix: TierMix,
                           oracle options: Oracle.Options, jobs: Int = BotSuite.defaultJobs) throws -> HoldOneOutReport {
        let fleets = try BotSuite.inParallel(seeds, jobs: jobs) { seed in try fleet(seed, tierMix: tierMix) }
        struct Job: Sendable {
            let seed: Int
            let seat: Int
        }
        let jobsList = seeds.indices.flatMap { k in
            (seats ?? Array(0..<seeds[k].fleetSize)).filter { tier == nil || fleets[k].tiers[$0] == tier }.map { Job(seed: k, seat: $0) }
        }
        let results = try BotSuite.inParallel(jobsList, jobs: jobs) { job in
            try run(fleets[job.seed].log, seat: job.seat, tier: fleets[job.seed].tiers[job.seat], seed: seeds[job.seed],
                    oracle: options)
        }
        let digests = try fleets.map { try Replayer.digest(of: $0.log) }
        return HoldOneOutReport(oracle: options, seeds: seeds.indices.map { k in
            HoldOneOutSeedResult(seed: seeds[k], fleet: tierMix.rawValue, fleetDigest: digests[k],
                                 seats: zip(jobsList, results).filter { $0.0.seed == k }.map(\.1))
        })
    }
}
