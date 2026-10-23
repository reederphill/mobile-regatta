import Foundation
import RegattaBots
import RegattaCore

// `regatta-timetrial --start` (#584, stage 1): the start oracle and the loss table. One boat, no fleet, from her place
// in the opening at the start of the sequence (T−60) to a minute after the gun: the start oracle (`StartOracle`, the
// #583 oracle's helm, actions and beam over the whole seeded wind) and every tier and profile on the same seeds, each
// alone. A start is scored by what it is worth at T+60 (`StartGeometry.worth`), and a bot's gap to the oracle splits
// into timing, speed and bias at the gun and the first minute's sailing after it (`StartLoss`). Measurement only:
// nothing here is read by a live bot or the race.

/// One seed of the start trial's pool (#584): a race's seeds and files, and the seat whose place in the fleet's opening
/// she sails from.
public struct StartTrialSeed: Codable, Hashable, Sendable {
    public var trial: TimeTrialSeed
    /// The fleet the race seats, so the line and the opening are that fleet's; every seat but hers is a ghost.
    public var fleetSize: Int
    /// The seat whose place she takes at the start of the sequence.
    public var seat: Int

    public var name: String { trial.name }

    /// The start suite's conditions, a seed's by turns (`BotStartSuiteTests.conditions`).
    public static let conditions = ["classic-oscillating@3", "gusty-offshore@3", "light-and-patchy@3", "sea-breeze@3"]
    /// The start suite's fleet: ten boats (`BotStartSuiteTests.cells`).
    public static let fleetSize = 10

    /// The start suite's 200 seeds (#99, `BotStartSuiteTests.cells`): race seed n on dev-venue@3 in the bundled
    /// conditions by turns, one lap, on the default class and rules, as the harness seeds them. Her seat goes round the
    /// fleet once every four seeds, so each conditions file sees every place of the opening as often.
    public static var pool: [StartTrialSeed] {
        (1...200).map { n in seed(name: "S\(n)", raceSeed: UInt64(n), index: n) }
    }

    /// Hold-out seeds (#584): the pool's files and seats on new race seeds, literals of a fixed rule.
    public static var holdOut: [StartTrialSeed] {
        (1...40).map { n in seed(name: "SH\(n)", raceSeed: 0x0584_0000_0000_0000 &+ UInt64(n) &* 0x9E37_79B9, index: n) }
    }

    private static func seed(name: String, raceSeed: UInt64, index n: Int) -> StartTrialSeed {
        let defaults = RaceFiles.defaults
        let trial = TimeTrialSeed(name: name, raceSeed: raceSeed, windSeed: BotRaceHarness.windSeed(for: raceSeed).value,
                                  venue: "dev-venue@3", conditions: conditions[n % conditions.count],
                                  boatClass: "\(defaults.boatClass.ref.id)@\(defaults.boatClass.ref.version)",
                                  rules: "\(defaults.rulesConfiguration.ref.id)@\(defaults.rulesConfiguration.ref.version)",
                                  laps: 1)
        return StartTrialSeed(trial: trial, fleetSize: fleetSize, seat: ((n - 1) / conditions.count) % fleetSize)
    }

    /// The pools of seeds the start trial sails.
    public enum Pool: String, CaseIterable, Sendable {
        case start, holdout

        public var seeds: [StartTrialSeed] {
            switch self {
            case .start: StartTrialSeed.pool
            case .holdout: StartTrialSeed.holdOut
            }
        }
    }
}

/// The line's frame a start is measured in (#584): metres up the course axis from the line's centre (`made`), and
/// spots along the line from the pin (0) to the committee boat (1), as the suite reads them (`lineSpot`).
struct StartGeometry {
    let course: TimeTrialCourse
    let line: CourseLayout.Line
    let upwind: Vec2

    /// The minute after the gun a start is scored at.
    static let horizonSeconds = 60.0
    static var horizonTick: Int { Int(horizonSeconds) * Race.tickRate }

    init(_ course: TimeTrialCourse) {
        self.course = course
        line = course.course.startLine
        upwind = course.course.upwind
    }

    /// Metres up the course axis from the line's centre: the first beat's ladder (#267) made good.
    func made(_ p: Vec2) -> Double { (p - line.centre).dot(upwind) }

    func spot(_ p: Vec2) -> Double { lineSpot(p, on: line) }

    /// The line's point at `spot`, kept to the line.
    func linePoint(_ spot: Double) -> Vec2 {
        line.pin.position + (line.committee.position - line.pin.position) * spot.clamped(to: 0...1)
    }

    /// Metres `p` is up `windward` (a unit vector into the wind) from the line's centre.
    func made(_ p: Vec2, into windward: Vec2) -> Double { (p - line.centre).dot(windward) }

    /// The line's bias in a wind blowing from `windward` (#584): metres the committee end is up it from the pin, so
    /// positive with the committee end favoured, as the suite reads a bias (`StartStrategySummary`).
    func bias(into windward: Vec2) -> Double {
        made(line.committee.position, into: windward) - made(line.pin.position, into: windward)
    }

    /// Metres the line's point at `spot` gives up to the favoured end in a wind blowing from `windward`.
    func biasLoss(spot: Double, into windward: Vec2) -> Double {
        max(made(line.pin.position, into: windward), made(line.committee.position, into: windward))
            - made(linePoint(spot), into: windward)
    }

    /// The polar's best speed made good to windward in her wind, m/s.
    func upwindVMG(_ boat: Boat) -> Double {
        let up = course.steady(tws: boat.polarWindSpeed(in: course.boatClass)).up
        return up.speed * cos(up.twa)
    }

    /// Seconds her speed below the polar's at her angle costs to make up (`momentum.speedingUp` of the shortfall), as the
    /// lap oracle's estimate reckons it.
    func deficitSeconds(_ boat: Boat) -> Double {
        let target = BoatDynamics.polarTarget(relativeWind: boat.relativeWind, boomSide: boat.boomSide,
                                              tws: boat.polarWindSpeed(in: course.boatClass), isPlaning: boat.isPlaning,
                                              spinnaker: boat.spinnaker, boatClass: course.boatClass)
        guard target > 0.1 else { return 0 }
        return max(0, target - boat.speed) / target * course.boatClass.momentum.speedingUp
    }

    /// Her speed's shortfall in metres: the deficit's seconds at the polar's best upwind.
    func deficitMetres(_ boat: Boat) -> Double { deficitSeconds(boat) * upwindVMG(boat) }

    /// What her start is worth at T+60 (#584): metres made up the course axis, less what her speed below the polar's
    /// costs to make up, in metres at its best upwind. A boat not yet started has at best the line to come back to.
    func worth(_ boat: Boat) -> Double {
        var made = made(boat.position)
        if boat.status != .racing && boat.status != .finished {
            made = min(made, self.made(linePoint(spot(boat.position))))
        }
        return made - deficitMetres(boat)
    }
}

/// Where she is at a moment of the start (#584): her spot along the line, metres below it up the axis (the line's own
/// point at her spot less hers; negative over it), and her speed.
public struct StartFix: Codable, Hashable, Sendable {
    public var spot: Double
    public var depth: Double
    public var speed: Double
}

/// One sailor's start on one seed (#584), as she sailed it.
public struct StartEntry: Codable, Hashable, Sendable {
    public var sailor: String
    /// What it was worth at T+60, metres (`StartGeometry.worth`).
    public var worth: Double
    /// Seconds after the gun she crossed the line to start; nil if she hadn't by T+60.
    public var startSeconds: Double?
    /// Over the line at the gun.
    public var ocs: Bool
    /// Where she was at T−30, T−10 and the gun.
    public var atT30: StartFix
    public var atT10: StartFix
    public var atGun: StartFix
    /// Metres her end gave up to the favoured end at the gun, up the wind at the line's centre then: by her spot at it,
    /// kept to the line.
    public var bias: Double
    /// Metres below the line at her spot at the gun (`atGun.depth`).
    public var timing: Double
    /// Metres her speed at the gun below the polar's at her angle costs (`StartGeometry.deficitMetres`).
    public var speed: Double
    /// Metres she made from the gun to T+60, as the score counts them: the worth less what she had at the gun, her
    /// end's bias given back (so a start's worth is `firstMinute − bias − timing − speed`, from the line's centre).
    public var firstMinute: Double
}

/// A sailor's start against the oracle's on one seed (#584): metres behind it at T+60, and why. Every column is hers
/// less the oracle's but the first minute's, which is the oracle's less hers: so they sum to the gap.
public struct StartLoss: Codable, Hashable, Sendable {
    public var sailor: String
    public var gap: Double
    public var timing: Double
    public var speed: Double
    public var bias: Double
    /// Seconds in another boat's air, and forced moves, in the first minute: zero with nobody else on the water, by
    /// construction (stage 2's columns).
    public var air: Double
    public var forced: Double
    public var firstMinute: Double

    public static let columns = ["gap", "timing", "speed", "bias", "air", "forced", "first minute"]

    public var values: [Double] { [gap, timing, speed, bias, air, forced, firstMinute] }

    init(sailor: String, gap: Double, timing: Double, speed: Double, bias: Double, air: Double, forced: Double,
         firstMinute: Double) {
        self.sailor = sailor
        self.gap = gap
        self.timing = timing
        self.speed = speed
        self.bias = bias
        self.air = air
        self.forced = forced
        self.firstMinute = firstMinute
    }

    init(_ entry: StartEntry, oracle: StartEntry) {
        self.init(sailor: entry.sailor, gap: oracle.worth - entry.worth, timing: entry.timing - oracle.timing,
                  speed: entry.speed - oracle.speed, bias: entry.bias - oracle.bias, air: 0, forced: 0,
                  firstMinute: oracle.firstMinute - entry.firstMinute)
    }

    /// The columns but the gap, summed: the gap, to rounding.
    public var sum: Double { timing + speed + bias + air + forced + firstMinute }
}

/// One seed of the start trial's report.
public struct StartTrialSeedResult: Codable, Hashable, Sendable {
    public var seed: StartTrialSeed
    /// The line's bias at the gun (`StartGeometry.bias`): metres the committee end is up the wind at the line's centre
    /// from the pin.
    public var lineBias: Double
    public var oracle: StartEntry
    /// The search's cost: nodes sailed, race ticks stepped.
    public var oracleNodes: Int
    public var oracleTicks: Int
    /// The re-sailed start's digest at T+60: the same every run on one platform (`StartOracleTests`).
    public var oracleDigest: UInt64
    public var sailors: [StartEntry]

    public var losses: [StartLoss] { sailors.map { StartLoss($0, oracle: oracle) } }
}

/// The start trial's report (#584): per seed, then the mean over the pool for each sailor.
public struct StartTrialReport: Codable, Hashable, Sendable {
    public var oracle: TimeTrialReport.OracleSettings
    public var seeds: [StartTrialSeedResult]

    public init(oracle: Oracle.Options, seeds: [StartTrialSeedResult]) {
        self.oracle = TimeTrialReport.OracleSettings(oracle)
        self.seeds = seeds
    }

    /// The mean over the seeds of each sailor's loss, in the report's sailor order.
    public var means: [StartLoss] {
        guard let first = seeds.first else { return [] }
        let count = Double(seeds.count)
        return first.sailors.indices.map { k in
            let losses = seeds.map { $0.losses[k] }
            func mean(_ value: (StartLoss) -> Double) -> Double { losses.reduce(0) { $0 + value($1) } / count }
            return StartLoss(sailor: losses[0].sailor, gap: mean(\.gap), timing: mean(\.timing), speed: mean(\.speed),
                             bias: mean(\.bias), air: mean(\.air), forced: mean(\.forced), firstMinute: mean(\.firstMinute))
        }
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// The text report: the mean loss table (the owner's), where each waited, then one line per seed.
    public var lines: [String] {
        var lines: [String] = []
        lines.append("regatta-timetrial --start: \(seeds.count) seeds, oracle beam \(oracle.beamWidth), horizon "
            + "\(format(oracle.horizonSeconds)) s, checkpoint \(format(oracle.checkpointSeconds)) s"
            + (oracle.eventCheckpoints ? " and on events" : ""))
        guard !seeds.isEmpty else { return lines }
        let count = Double(seeds.count)
        func mean(_ entries: [StartEntry], _ value: (StartEntry) -> Double) -> Double {
            entries.reduce(0) { $0 + value($1) } / Double(max(entries.count, 1))
        }
        let oracles = seeds.map(\.oracle)
        lines.append("oracle mean worth at T+60: \(format(mean(oracles, \.worth))) m; started \(seeds.filter { $0.oracle.startSeconds != nil }.count)"
            + "/\(seeds.count), OCS \(oracles.filter(\.ocs).count), mean start \(format(mean(oracles) { $0.startSeconds ?? 60 })) s")
        lines.append("")
        lines.append("mean metres behind the oracle at T+60, by cause (they sum to the gap):")
        var rows = [["sailor"] + StartLoss.columns]
        for loss in means { rows.append([loss.sailor] + loss.values.map(format)) }
        lines += table(rows)
        lines.append("")
        lines.append("starts: mean worth m, mean start s (60 for none by T+60), OCS, mean spot and depth m at T-30, T-10 and the gun:")
        var starts = [["sailor", "worth", "start s", "OCS", "spot -30", "depth -30", "spot -10", "depth -10", "spot gun", "depth gun"]]
        let columns: [(String, [StartEntry])] = [("oracle", oracles)]
            + (seeds[0].sailors.indices.map { k in (seeds[0].sailors[k].sailor, seeds.map { $0.sailors[k] }) })
        for (name, entries) in columns {
            starts.append([name, format(mean(entries, \.worth)), format(mean(entries) { $0.startSeconds ?? 60 }),
                           "\(entries.filter(\.ocs).count)",
                           fixed(mean(entries, \.atT30.spot), 2), format(mean(entries, \.atT30.depth)),
                           fixed(mean(entries, \.atT10.spot), 2), format(mean(entries, \.atT10.depth)),
                           fixed(mean(entries, \.atGun.spot), 2), format(mean(entries, \.atGun.depth))])
        }
        lines += table(starts)
        lines.append("")
        lines.append("waiting, mean |spot - oracle's| and depth - oracle's m at T-30 and T-10:")
        var waits = [["sailor", "|spot| -30", "depth -30", "|spot| -10", "depth -10"]]
        for k in seeds[0].sailors.indices {
            let pairs = seeds.map { ($0.sailors[k], $0.oracle) }
            func pairMean(_ value: (StartEntry, StartEntry) -> Double) -> Double {
                pairs.reduce(0) { $0 + value($1.0, $1.1) } / count
            }
            waits.append([seeds[0].sailors[k].sailor,
                          fixed(pairMean { abs($0.atT30.spot - $1.atT30.spot) }, 2), format(pairMean { $0.atT30.depth - $1.atT30.depth }),
                          fixed(pairMean { abs($0.atT10.spot - $1.atT10.spot) }, 2), format(pairMean { $0.atT10.depth - $1.atT10.depth })])
        }
        lines += table(waits)
        lines.append("")
        lines.append("per seed, metres behind the oracle at T+60 (start s); the line's bias at the gun (+ the committee end "
            + "favoured); the oracle's spot and depth m at T-30, T-10:")
        var seedRows = [["seed", "conditions", "seat", "bias m", "oracle m", "start s", "-30", "-10"]
                        + seeds[0].sailors.map(\.sailor)]
        for seed in seeds {
            let o = seed.oracle
            seedRows.append([seed.seed.name, seed.seed.trial.conditions, "\(seed.seed.seat)", format(seed.lineBias),
                             format(o.worth), o.startSeconds.map(format) ?? "-",
                             "\(fixed(o.atT30.spot, 2))/\(format(o.atT30.depth))", "\(fixed(o.atT10.spot, 2))/\(format(o.atT10.depth))"]
                            + zip(seed.sailors, seed.losses).map { entry, loss in
                                (entry.ocs ? "OCS " : "") + format(loss.gap) + " (\(entry.startSeconds.map(format) ?? "-"))"
                            })
        }
        lines += table(seedRows)
        return lines
    }

    private func format(_ value: Double) -> String { String(format: "%.1f", value) }

    private func fixed(_ value: Double, _ places: Int) -> String { String(format: "%.\(places)f", value) }

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

/// Watches a start trial's race tick by tick (#584): where she is at T−30, T−10 and the gun, when she starts, and what
/// she is worth at T+60.
struct StartWatch {
    let geometry: StartGeometry
    private(set) var atT30: StartFix?
    private(set) var atT10: StartFix?
    private(set) var atGun: StartFix?
    private(set) var gunBoat: Boat?
    /// Into the wind at the line's centre at the gun.
    private(set) var gunWindward: Vec2?
    private(set) var startTick: Int?
    private(set) var ocs = false

    static let t30Tick = -30 * Race.tickRate
    static let t10Tick = -10 * Race.tickRate

    init(_ geometry: StartGeometry) {
        self.geometry = geometry
    }

    func fix(_ boat: Boat) -> StartFix {
        let spot = geometry.spot(boat.position)
        return StartFix(spot: spot, depth: geometry.made(geometry.linePoint(spot)) - geometry.made(boat.position),
                        speed: boat.speed)
    }

    /// Records the tick the race just stepped to.
    mutating func record(_ race: Race) {
        let boat = race.boats[0]
        switch race.tick {
        case Self.t30Tick: atT30 = fix(boat)
        case Self.t10Tick: atT10 = fix(boat)
        case 0:
            atGun = fix(boat)
            gunBoat = boat
            gunWindward = .heading(race.groundWind(at: geometry.line.centre).direction)
            if boat.status == .ocs { ocs = true }
        default: break
        }
        if startTick == nil && race.tick >= 0 && boat.status == .racing { startTick = race.tick }
    }

    /// The line's bias at the gun.
    var lineBias: Double {
        guard let gunWindward else { preconditionFailure("a start trial sails past the gun") }
        return geometry.bias(into: gunWindward)
    }

    /// Her entry, the race at T+60.
    func entry(_ sailor: String, race: Race) -> StartEntry {
        guard let atT30, let atT10, let atGun, let gunBoat, let gunWindward else {
            preconditionFailure("a start trial sails to T+60")
        }
        let worth = geometry.worth(race.boats[0])
        let bias = geometry.biasLoss(spot: atGun.spot, into: gunWindward)
        let speed = geometry.deficitMetres(gunBoat)
        return StartEntry(sailor: sailor, worth: worth, startSeconds: startTick.map { Double($0) / Double(Race.tickRate) },
                          ocs: ocs, atT30: atT30, atT10: atT10, atGun: atGun, bias: bias, timing: atGun.depth, speed: speed,
                          firstMinute: worth + bias + atGun.depth + speed)
    }
}

public enum StartTrial {
    /// The seed's course: her in her seat's place of the fleet's opening at the start of the sequence.
    public static func course(_ seed: StartTrialSeed) throws -> TimeTrialCourse {
        try TimeTrialCourse(seed.trial, start: (fleetSize: seed.fleetSize, seat: seed.seat))
    }

    /// Sails `sailor`, a bot, from the start of the sequence to T+60, alone: her driver as a race's from its first tick.
    static func sail(_ sailor: TimeTrialSailor, course: TimeTrialCourse) throws -> StartEntry {
        guard var driver = sailor.driver(raceSeed: course.setup.raceSeed) else {
            preconditionFailure("the oracle sails through `StartOracle`, not a driver")
        }
        let race = try course.race()
        var watch = StartWatch(StartGeometry(course))
        while race.tick < StartGeometry.horizonTick && !race.isOver {
            driver.drive(race)
            race.step()
            _ = race.drainEvents()
            watch.record(race)
        }
        return watch.entry(sailor.description, race: race)
    }

    /// Re-sails `inputs` from the start of the sequence to T+60: the oracle's start, and the race's digest there.
    public static func replay(_ inputs: [Oracle.Input], course: TimeTrialCourse) throws
        -> (entry: StartEntry, lineBias: Double, digest: UInt64) {
        let race = try course.race()
        var watch = StartWatch(StartGeometry(course))
        var next = 0
        while race.tick < StartGeometry.horizonTick && !race.isOver {
            while next < inputs.count && inputs[next].tick <= race.tick + 1 {
                if let held = inputs[next].held { race.apply(held, seat: 0, atTick: inputs[next].tick) }
                if let tap = inputs[next].tap { race.tap(tap, seat: 0, atTick: inputs[next].tick) }
                next += 1
            }
            race.step()
            _ = race.drainEvents()
            watch.record(race)
        }
        return (watch.entry(TimeTrialSailor.oracle.description, race: race), watch.lineBias, race.digest())
    }

    /// Sails `seed`: the oracle's search, its start re-sailed under the watch, and each of `sailors` alone.
    public static func run(_ seed: StartTrialSeed, sailors: [TimeTrialSailor], oracle options: Oracle.Options) throws
        -> StartTrialSeedResult {
        let course = try course(seed)
        let plan = try StartOracle(course: course, options: options).search()
        let oracle = try replay(plan.inputs, course: course)
        return StartTrialSeedResult(seed: seed, lineBias: oracle.lineBias, oracle: oracle.entry, oracleNodes: plan.nodes, oracleTicks: plan.ticks,
                                    oracleDigest: oracle.digest,
                                    sailors: try sailors.map { try sail($0, course: course) })
    }

    /// `run(_:sailors:oracle:)` for each of `seeds`, up to `jobs` at once, in the seeds' order.
    public static func run(_ seeds: [StartTrialSeed], sailors: [TimeTrialSailor], oracle options: Oracle.Options,
                           jobs: Int = BotSuite.defaultJobs) throws -> StartTrialReport {
        let results = try BotSuite.inParallel(seeds, jobs: jobs) { seed in try run(seed, sailors: sailors, oracle: options) }
        return StartTrialReport(oracle: options, seeds: results)
    }
}

/// The start oracle (#584 stage 1): the start a beam search finds for one boat from her place in the opening at T−60
/// that is worth most at T+60 (`StartGeometry.worth`), knowing the whole seeded wind (offline, as the lap oracle). Its
/// planner is the lap oracle's (`Oracle`): the same helm (`Oracle.Helm`) and actions, a held input every decision, the
/// bots' own decisions as actions, children sailed through the race's own step and scored after a horizon sailed as the
/// executor would, and a beam that keeps the bots' own starts unbroken from T−60. What the start adds:
///
/// - Actions: the lap's, and before the gun a reach away at `reachAngle`, an ease or a trim of the sheets, and a course
///   for a spot on the line (`lineSpots`): the ways a player waits and picks her place.
/// - Checkpoints every `checkpointSeconds`, at the gun, at her start, and when either end of the line comes to bear on or
///   off her close-hauled course on her tack (she can or no longer can fetch it).
/// - Score: before T+60, the worth she can still have there (`estimate`): she sails from here to the line at her spot at
///   the polar's best, no earlier than the gun, and on up the axis at it; from T+60, her worth. A child over the line at
///   the gun is dropped, as a lap's child that fouls a mark: so the start it finds is never OCS.
public struct StartOracle {
    public let course: TimeTrialCourse
    public let options: Oracle.Options
    let lap: Oracle
    let geometry: StartGeometry

    public init(course: TimeTrialCourse, options: Oracle.Options = Oracle.Options()) {
        precondition(course.start != nil, "the start oracle sails a start trial's course")
        self.course = course
        self.options = options
        lap = Oracle(course: course, options: options)
        geometry = StartGeometry(course)
    }

    /// What she does at a checkpoint, until the next.
    enum Action: Hashable, Sendable {
        /// The lap oracle's (`Oracle.Action`).
        case lap(Oracle.Action)
        /// Before the gun: bear away to `reachAngle` on her tack.
        case reach
        /// Before the gun: ease the sheets, or trim them.
        case ease
        /// Before the gun: steer for the line at this spot.
        case spot(Double)

        static let all: [Action] = Oracle.Action.allCases.map(Action.lap) + [.reach, .ease] + lineSpots.map(Action.spot)
    }

    static let reachAngle = deg2rad(110)
    static let lineSpots = [0.05, 0.25, 0.5, 0.75, 0.95]

    enum Pilot {
        case helm(Oracle.Helm, ease: Bool)
        case bot(BotDriver, BotProfile)
    }

    struct Node {
        var world: WorldSnapshot
        var helm: Oracle.Helm
        var ease: Bool
        var bot: (driver: BotDriver, profile: BotProfile)?
        var pure: BotProfile?
        var trail: Oracle.Trail?
        /// Her worth at T+60 as estimated (`estimate`), or her worth once there: higher is better.
        var score: Double
        var done: Bool { world.tick >= StartGeometry.horizonTick }
    }

    /// The start it found: the inputs she sends, its worth at T+60 by the plan, and the search's cost.
    public struct Plan: Sendable {
        public var inputs: [Oracle.Input]
        public var worth: Double
        public var nodes: Int
        public var ticks: Int
    }

    private func takeOver(_ profile: BotProfile) -> BotDriver {
        guard let driver = TimeTrialSailor.profile(profile).driver(raceSeed: course.setup.raceSeed) else {
            preconditionFailure("a profile always has a driver")
        }
        return driver
    }

    /// Searches from the start of the sequence to T+60.
    public func search() throws -> Plan {
        var race = try course.race()
        var nodes = 0
        var ticks = 0
        let boat = course.origin.seats[0].boat
        let root = Node(world: course.origin, helm: Oracle.Helm(course: .angle(boomSide: boat.boomSide, twa: boat.twa)),
                        ease: course.origin.seats[0].heldInput.ease, bot: nil, pure: nil, trail: nil, score: 0)
        var beam = [root]
        var best: Node?
        var levels = 0
        while !beam.isEmpty {
            levels += 1
            // A fresh copy of the race now and then: the race logs every input it applies.
            if levels.isMultiple(of: 64) { race = try course.race() }
            var children: [Node] = []
            for node in beam {
                let prestart = node.world.tick < 0
                for action in Action.all {
                    var child: Node
                    switch action {
                    case .lap(.sail(let profile)):
                        let driver = node.bot.flatMap { $0.profile == profile ? $0.driver : nil }
                            ?? (node.world.tick == course.origin.tick ? takeOver(profile) : takeOver(profile).takingOver())
                        child = try sail(from: node, pilot: .bot(driver, profile), race: race, ticks: &ticks)
                        child.pure = node.pure == profile || node.world.tick == course.origin.tick ? profile : nil
                    case .lap(let lapAction):
                        guard let helm = node.helm.after(lapAction, world: node.world, oracle: lap) else { continue }
                        child = try sail(from: node, pilot: .helm(helm, ease: node.ease), race: race, ticks: &ticks)
                    case .reach, .ease, .spot:
                        guard prestart, let pilot = startPilot(action, node: node) else { continue }
                        child = try sail(from: node, pilot: pilot, race: race, ticks: &ticks)
                    }
                    nodes += 1
                    // Over the line at the gun, or fouled: no start to have. A bot's own start that goes over is done too.
                    guard child.score.isFinite else { continue }
                    if child.done {
                        if best.map({ child.score > $0.score }) ?? true { best = child }
                        continue
                    }
                    if options.horizonSeconds > 0 {
                        child.score = try horizonScore(child, race: race, ticks: &ticks)
                        nodes += 1
                    }
                    guard child.score.isFinite else { continue }
                    children.append(child)
                }
            }
            beam = select(children)
        }
        return Plan(inputs: best?.trail?.all ?? [], worth: best?.score ?? -.infinity, nodes: nodes, ticks: ticks)
    }

    /// The helm after a start action at `node`; nil where it is the same as another, or she is through a turn.
    private func startPilot(_ action: Action, node: Node) -> Pilot? {
        let boat = node.world.seats[0].boat
        guard abs(wrapAngle(node.helm.heading(boat: boat, oracle: lap) - boat.heading)) < Oracle.Helm.settled else { return nil }
        switch action {
        case .reach:
            let helm = Oracle.Helm(course: .angle(boomSide: boat.boomSide, twa: Self.reachAngle))
            return helm == node.helm ? nil : .helm(helm, ease: node.ease)
        case .ease:
            return .helm(node.helm, ease: !node.ease)
        case .spot(let spot):
            let helm = Oracle.Helm(course: .point(geometry.linePoint(spot)))
            return helm == node.helm ? nil : .helm(helm, ease: node.ease)
        case .lap:
            return nil
        }
    }

    /// The best `beamWidth` of `children` by score: first each bot's own start, then the best child on each tack in each
    /// third of the line, before the gun or after it, then the rest by score, a child within `Oracle.spacing` hull lengths
    /// of a kept one in the same bucket dropped. Ties go to the earlier child, so the beam is the same every run.
    private func select(_ children: [Node]) -> [Node] {
        let order = children.indices.sorted { a, b in
            children[a].score != children[b].score ? children[a].score > children[b].score : a < b
        }
        func bucket(_ node: Node) -> [Int] {
            let boat = node.world.seats[0].boat
            let third = Int((geometry.spot(boat.position).clamped(to: 0...0.999)) * 3)
            return [boat.status == .racing ? 1 : 0, boat.boomSide == .port ? 0 : 1, third]
        }
        var kept = order.filter { children[$0].pure != nil }
        var buckets: [[Int]] = []
        for index in order where kept.count < options.beamWidth && !buckets.contains(bucket(children[index])) {
            buckets.append(bucket(children[index]))
            if !kept.contains(index) { kept.append(index) }
        }
        let near = Oracle.spacing * course.boatClass.hull.length
        for index in order where kept.count < options.beamWidth && !kept.contains(index) {
            let boat = children[index].world.seats[0].boat
            let crowded = kept.contains { other in
                let o = children[other].world.seats[0].boat
                return bucket(children[other]) == bucket(children[index]) && (o.position - boat.position).length < near
            }
            if !crowded { kept.append(index) }
        }
        return kept.sorted { children[$0].score != children[$1].score ? children[$0].score > children[$1].score : $0 < $1 }
            .map { children[$0] }
    }

    /// Whether she can fetch each end of the line close-hauled on her tack: the pin's, then the committee boat's.
    private func fetches(_ boat: Boat) -> [Bool] {
        let up = course.steady(tws: boat.polarWindSpeed(in: course.boatClass)).up.twa
        return [course.course.startLine.pin.position, course.course.startLine.committee.position].map { end in
            boat.boomSide.sailingAngle(relativeWind: wrapAngle(boat.sailingWind.direction - (end - boat.position).bearing)) >= up
        }
    }

    /// `node`'s child sailed by `pilot` to the next checkpoint, and scored there.
    private func sail(from node: Node, pilot: Pilot, race: Race, ticks: inout Int) throws -> Node {
        try race.importSnapshot(node.world)
        let startTick = race.tick
        var endTick = min(startTick + Int(options.checkpointSeconds * Double(Race.tickRate)), StartGeometry.horizonTick)
        if startTick < 0 { endTick = min(endTick, 0) }
        let minimumTick = startTick + Int(Oracle.minimumSegmentSeconds * Double(Race.tickRate))
        var pilot = pilot
        var sent: [Oracle.Input] = []
        var last = node.world.seats[0].heldInput
        let started = race.boats[0].status == .racing
        let fetched = fetches(race.boats[0])
        while race.tick < endTick && !race.isOver {
            steer(&pilot, race: race, last: &last, sent: &sent)
            race.step()
            ticks += 1
            _ = race.drainEvents()
            let boat = race.boats[0]
            if boat.status == .ocs || boat.status == .dsq { break }
            if boat.penaltyTurnsOwed > 0, case .helm = pilot { break }
            guard options.eventCheckpoints, race.tick >= minimumTick else { continue }
            if (boat.status == .racing) != started { break }
            if race.tick < 0 && fetches(boat) != fetched { break }
        }
        let boat = race.boats[0]
        let trail = sent.isEmpty ? node.trail : Oracle.Trail(parent: node.trail, inputs: sent)
        var fouled = boat.penaltyTurnsOwed > 0
        if case .bot = pilot { fouled = false }
        let lost = fouled || boat.status == .ocs || boat.status == .dsq || (race.isOver && race.tick < StartGeometry.horizonTick)
        var child = Node(world: race.exportSnapshot(), helm: node.helm, ease: node.ease, bot: nil, pure: nil, trail: trail,
                         score: lost ? -.infinity : estimate(race))
        switch pilot {
        case .helm(let helm, let ease):
            child.helm = helm
            child.ease = ease
        case .bot(let driver, let profile):
            child.bot = (driver, profile)
            child.helm = Oracle.Helm(course: .angle(boomSide: boat.boomSide, twa: boat.twa))
            child.ease = race.exportSnapshot().seats[0].heldInput.ease
        }
        return child
    }

    /// One tick's steering by `pilot`, as the lap oracle's: on a decision tick her helm's held input with its sheets, or
    /// her bot's decision, sent for the next tick.
    private func steer(_ pilot: inout Pilot, race: Race, last: inout BoatInput, sent: inout [Oracle.Input]) {
        let next = race.tick + 1
        switch pilot {
        case .helm(let helm, let ease):
            guard race.tick.isMultiple(of: BotDriver.decisionInterval) else { return }
            let input = BoatInput(rudder: helm.input(race: race, oracle: lap).rudder, ease: ease)
            if input != last {
                race.apply(input, seat: 0, atTick: next)
                sent.append(Oracle.Input(tick: next, held: input))
                last = input
            }
        case .bot(var driver, let profile):
            if let decision = driver.drive(race) {
                if decision.input != last {
                    sent.append(Oracle.Input(tick: next, held: decision.input))
                    last = decision.input
                }
                if let tap = decision.tap { sent.append(Oracle.Input(tick: next, tap: tap)) }
            }
            pilot = .bot(driver, profile)
        }
    }

    /// `node` sailed on `horizonSeconds` (not past T+60) as the executor would sail her, and scored there: a horizon
    /// that ends over the line at the gun scores nothing, one that fouls pays the lap oracle's turn in metres.
    private func horizonScore(_ node: Node, race: Race, ticks: inout Int) throws -> Double {
        try race.importSnapshot(node.world)
        let profile = Oracle.rolloutProfile
        var driver = node.bot.flatMap { $0.profile == profile ? $0.driver : nil } ?? takeOver(profile).takingOver()
        let endTick = min(race.tick + Int(options.horizonSeconds * Double(Race.tickRate)), StartGeometry.horizonTick)
        while race.tick < endTick && !race.isOver {
            driver.drive(race)
            race.step()
            ticks += 1
            _ = race.drainEvents()
            let boat = race.boats[0]
            if boat.status == .ocs { return -.infinity }
            if boat.penaltyTurnsOwed > 0 || boat.status == .dsq {
                return estimate(race) - Oracle.horizonFoulSeconds * geometry.upwindVMG(boat)
            }
        }
        return estimate(race)
    }

    /// Her worth at T+60 as she can still have it from here: from T+60 her worth; racing, her metres made and the
    /// polar's best up the axis for the time left less her speed's deficit; before her start, the line's metres at her
    /// spot and the polar's best from the time she can be there, no earlier than the gun: there at its best (with a turn's
    /// worth of the class's speeding up if she is sailing away), and her deficit made up on the way.
    func estimate(_ race: Race) -> Double {
        let boat = race.boats[0]
        let horizon = StartGeometry.horizonSeconds
        if race.tick >= StartGeometry.horizonTick { return geometry.worth(boat) }
        let vmg = max(geometry.upwindVMG(boat), Oracle.slowest)
        switch boat.status {
        case .racing:
            return geometry.made(boat.position) + vmg * max(0, horizon - race.time - geometry.deficitSeconds(boat))
        case .prestart:
            let point = geometry.linePoint(geometry.spot(boat.position))
            let below = geometry.made(point) - geometry.made(boat.position)
            var seconds = abs(below) / vmg + geometry.deficitSeconds(boat)
            let towards = Vec2.heading(boat.heading).dot(upwindSign(below) * geometry.upwind)
            if towards < 0 { seconds += course.boatClass.momentum.speedingUp }
            let start = max(race.time + seconds, 0)
            return geometry.made(point) + vmg * max(0, horizon - start)
        default:
            return -.infinity
        }
    }

    /// Up the axis for a boat below the line, down it for one above.
    private func upwindSign(_ below: Double) -> Double { below >= 0 ? 1 : -1 }
}
