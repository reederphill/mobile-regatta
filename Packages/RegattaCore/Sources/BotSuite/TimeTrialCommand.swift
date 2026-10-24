import Foundation
import RegattaBots
import RegattaCore

/// `regatta-timetrial`'s arguments (#583).
public struct TimeTrialOptions: Hashable, Sendable {
    /// The first n seeds of the pool; all of it when nil.
    public var seedCount: Int?
    /// `--only <name>`: only these seeds of the pool, by name (R3, H3); all when empty.
    public var only: [String] = []
    /// The pools sailed, in order (`--pool`, `--holdout`); the reference regatta's when empty.
    public var pools: [TimeTrialSeed.Pool] = []
    /// `--boat-class id@version`: every seed on that bundled class instead of its own.
    public var boatClass: String?
    public var laps: Int?
    /// The tiers (`--tier-mix`) and profiles (`--profile-mix`) to sail against the oracle, in the order given; the
    /// standard five (`TimeTrialSailor.standard`) when both are empty. One boat sails a time trial, so a "mix" is one
    /// tier or one profile: club, regional, national; baseline, tactician, executor and the suite's other profiles.
    public var tiers: [BotTier] = []
    public var profiles: [BotProfile] = []
    public var oracle = Oracle.Options()
    /// `--oracle-from <report.json>`: the oracle's laps from an earlier report of the same seeds, not searched again.
    public var oracleFrom: [String] = []
    /// `--tunables <file>`: the bots read this tunables file (`BotTunables`) in place of the bundled one.
    public var tunablesPath: String?
    /// `--tune <out.json>` (#583 stage 2): search the tunables for the least mean time behind the oracle of the sailors,
    /// from `tunablesPath`'s or the bundled ones, and write the best as a tunables file there.
    public var tuneOut: String?
    /// `--tune-rounds <n>`: rounds of the search, each a pass over every tunable at the round's step.
    public var tuneRounds = 4
    /// `--tune-only <prefix>`: search only the tunables whose names start so (repeatable); all when empty.
    public var tuneOnly: [String] = []
    /// `--tune-skip <prefix>`: leave the tunables whose names start so as they are (repeatable).
    public var tuneSkip: [String] = []
    /// `--start` (#584): the start trial, from her place in the opening at T−60 to T+60 (`StartTrial`), on the start
    /// suite's seeds (`StartTrialSeed.pool`; `--holdout`, its hold-outs).
    public var start = false
    /// `--hold-one-out <seat|all>` (#584 stage 2): with `--start`, hold out this seat of each seed's fleet (every seat
    /// for `all`, an empty list) and plan its start again against the others' logged inputs (`HoldOneOut`).
    public var holdOut: [Int]?
    /// `--hold-one-out <tier>`: hold out only the seats of this tier in each fleet (with `holdOut` empty).
    public var holdOutTier: BotTier?
    /// `--fleet <mix>`: the hold-one-out's fleet (`TierMix`); the start suite's all-National by default.
    public var fleet = TierMix.national
    public var jobs: Int?
    /// Where to write the JSON report; `-` for stdout (the text report then goes to stderr).
    public var jsonPath: String?
    public var help = false

    public init() {}

    public static let usage = """
        usage: regatta-timetrial [options]
          --seeds <n>            the first n seeds of the pool (default: all 16)
          --only <seed>          only this seed of the pool, by name: R3, or H3 with --holdout (repeatable)
          --holdout              the hold-out seeds (the reference races' files on new seeds) instead of the
                                 reference regatta's races: --pool holdout
          --pool <name>          sail this pool of seeds: reference (R1-R16), holdout (H1-H16) or validation
                                 (V1-V16); repeatable, in the order given (default: reference)
          --boat-class <id@v>    every seed on that bundled class instead of its own
          --laps <n>             laps instead of each seed's own
          --tier-mix <tier>      sail this tier against the oracle: club, regional or national (repeatable)
          --profile-mix <p>      sail this profile at skill 1 against the oracle: executor, tactician, baseline, ...
                                 (repeatable). With neither flag: club, regional, national, executor and tactician
          --beam <n>             the oracle's beam width (default 16)
          --horizon <s>          seconds each child is sailed on before it is scored (default 20; 0 scores it at
                                 its checkpoint)
          --checkpoint <s>       seconds between the oracle's checkpoints (default 2)
          --no-event-checkpoints checkpoint on the clock only, not on marks, laylines, shifts and puffs
          --oracle-from <json>   take the oracle's laps from an earlier --json report of the same seeds
                                 (repeatable: one report a pool)
          --tunables <file>      the bots read this tunables file (bot-tunables@n.json's form) in place of the bundled
          --tune <out.json>      search the bots' tunables for the least mean time behind the oracle of the sailors
                                 (coordinate descent; needs --oracle-from) and write the best set there
          --tune-rounds <n>      rounds of the search, each step half the last (default 4)
          --tune-only <prefix>   search only the tunables whose names start so, e.g. planner (repeatable)
          --tune-skip <prefix>   leave the tunables whose names start so as they are (repeatable)
          --json <path|->        write the JSON report there (- for stdout)
          --jobs <n>             seeds sailed at once (default: the performance cores)
          --start                the start trial (#584): from her place in a ten-boat opening at T-60 to T+60, on the
                                 start suite's 200 seeds (--holdout: its 40 hold-outs; --seeds and --only as above,
                                 S3 or SH3); the oracle's start against each sailor's, by its worth at T+60.
                                 Not with --laps, --tune, --tunables or --oracle-from
          --hold-one-out <s>     with --start (#584 stage 2): sail each seed's ten-boat fleet to T+60, then plan seat s's
                                 start again (all: every seat; club, regional or national: that tier's seats) against
                                 the other nine sailing their logged inputs, the rules on; the gap-finding gap by tier
                                 and by situation at T-60
          --fleet <mix>          the hold-one-out's fleet: national (default), mixed, club, regional
        One boat, no fleet: from a fixed start at the gun, the oracle searches for the fastest lap of each seed's
        course and each bot sails it alone; the table is where each loses her time behind the oracle.
        Exits 2 on a usage or setup error.
        """

    public init(arguments: [String]) throws {
        var rest = arguments[...]
        func value(_ flag: String) throws -> String {
            guard let value = rest.popFirst() else { throw BotSuiteError.usage("\(flag) needs a value") }
            return value
        }
        func number(_ flag: String) throws -> Int {
            let text = try value(flag)
            guard let number = Int(text), number >= 1 else { throw BotSuiteError.usage("\(flag): not a positive whole number: \(text)") }
            return number
        }
        func seconds(_ flag: String, allowingZero: Bool = false) throws -> Double {
            let text = try value(flag)
            guard let seconds = Double(text), seconds.isFinite, seconds > 0 || (allowingZero && seconds == 0) else {
                throw BotSuiteError.usage("\(flag): not a \(allowingZero ? "non-negative" : "positive") number: \(text)")
            }
            return seconds
        }
        while let flag = rest.popFirst() {
            switch flag {
            case "--seeds": seedCount = try number(flag)
            case "--holdout": pools.append(.holdout)
            case "--pool":
                let text = try value(flag)
                guard let pool = TimeTrialSeed.Pool(rawValue: text) else {
                    throw BotSuiteError.usage("--pool: reference, holdout or validation, not \(text)")
                }
                pools.append(pool)
            case "--only": only.append(try value(flag))
            case "--boat-class": boatClass = try value(flag)
            case "--laps": laps = try number(flag)
            case "--tier-mix":
                let text = try value(flag)
                guard let tier = BotTier(rawValue: text) else {
                    throw BotSuiteError.usage("--tier-mix: club, regional or national, not \(text)")
                }
                tiers.append(tier)
            case "--profile-mix":
                let text = try value(flag)
                guard let profile = BotProfile(rawValue: text) else { throw BotSuiteError.usage("--profile-mix: unknown profile \(text)") }
                profiles.append(profile)
            case "--beam": oracle.beamWidth = try number(flag)
            case "--horizon": oracle.horizonSeconds = try seconds(flag, allowingZero: true)
            case "--checkpoint": oracle.checkpointSeconds = try seconds(flag)
            case "--no-event-checkpoints": oracle.eventCheckpoints = false
            case "--json": jsonPath = try value(flag)
            case "--oracle-from": oracleFrom.append(try value(flag))
            case "--tunables": tunablesPath = try value(flag)
            case "--tune": tuneOut = try value(flag)
            case "--tune-rounds": tuneRounds = try number(flag)
            case "--tune-only": tuneOnly.append(try value(flag))
            case "--tune-skip": tuneSkip.append(try value(flag))
            case "--jobs": jobs = try number(flag)
            case "--start": start = true
            case "--hold-one-out":
                let text = try value(flag)
                if text == "all" {
                    holdOut = []
                } else if let tier = BotTier(rawValue: text) {
                    holdOut = []
                    holdOutTier = tier
                } else {
                    guard let seat = Int(text), (0..<StartTrialSeed.fleetSize).contains(seat) else {
                        throw BotSuiteError.usage("--hold-one-out: a seat 0-\(StartTrialSeed.fleetSize - 1), all or a tier, not \(text)")
                    }
                    holdOut = (holdOut ?? []) + [seat]
                }
            case "--fleet":
                let text = try value(flag)
                guard let mix = TierMix(rawValue: text) else { throw BotSuiteError.usage("--fleet: no tier mix \(text)") }
                fleet = mix
            case "-h", "--help": help = true
            default: throw BotSuiteError.usage("unknown argument: \(flag)")
            }
        }
        if tuneOut != nil && oracleFrom.isEmpty { throw BotSuiteError.usage("--tune needs --oracle-from") }
        if start {
            if laps != nil || tuneOut != nil || tunablesPath != nil || !oracleFrom.isEmpty {
                throw BotSuiteError.usage("--start: not with --laps, --tune, --tunables or --oracle-from")
            }
            if pools.contains(.validation) { throw BotSuiteError.usage("--start: the pools are reference and holdout") }
        }
        if holdOut != nil && !start { throw BotSuiteError.usage("--hold-one-out needs --start") }
        if oracle.checkpointSeconds < Oracle.minimumSegmentSeconds {
            throw BotSuiteError.usage("--checkpoint: at least \(Oracle.minimumSegmentSeconds) s")
        }
    }

    /// The tunables `--tune` searches: `--tune-only`'s, less `--tune-skip`'s.
    public func tuneParameters() throws -> [BotTunables.Parameter] {
        let chosen = BotTunables.parameters.filter { parameter in
            (tuneOnly.isEmpty || tuneOnly.contains { parameter.name.hasPrefix($0) })
                && !tuneSkip.contains { parameter.name.hasPrefix($0) }
        }
        guard !chosen.isEmpty else { throw BotSuiteError.usage("--tune-only/--tune-skip leave nothing to tune") }
        return chosen
    }

    /// The tunables file `--tunables` names, if any.
    public func tunables() throws -> BotTunables? {
        try tunablesPath.map { try BotTunables.decode(Data(contentsOf: URL(fileURLWithPath: $0))) }
    }

    /// The oracle's laps `--oracle-from` names: every seed of the run must be in it.
    public func knownOracle() throws -> [TimeTrialSeedResult] {
        guard !oracleFrom.isEmpty else { return [] }
        let known = try oracleFrom.flatMap { path in
            try JSONDecoder().decode(TimeTrialReport.self, from: Data(contentsOf: URL(fileURLWithPath: path))).seeds
        }
        let seeds = try seeds()
        if let missing = seeds.first(where: { seed in !known.contains { $0.seed == seed } }) {
            throw BotSuiteError.usage("--oracle-from: no lap of \(missing.name) (\(missing.laps) laps) in \(oracleFrom)")
        }
        return known
    }

    /// The sailors, oracle aside.
    public var sailors: [TimeTrialSailor] {
        guard !tiers.isEmpty || !profiles.isEmpty else { return TimeTrialSailor.standard }
        return tiers.map(TimeTrialSailor.tier) + profiles.map(TimeTrialSailor.profile)
    }

    /// The start trial's seeds to sail (`--start`): the start suite's, or its hold-outs for `--holdout`, in the order
    /// given.
    public func startSeeds() throws -> [StartTrialSeed] {
        let pool = (pools.isEmpty ? [.reference] : pools).flatMap { pool -> [StartTrialSeed] in
            pool == .holdout ? StartTrialSeed.holdOut : StartTrialSeed.pool
        }
        if let seedCount, seedCount > pool.count {
            throw BotSuiteError.usage("--seeds: the pool has \(pool.count) seeds")
        }
        if let unknown = only.first(where: { name in !pool.contains { $0.name == name } }) {
            throw BotSuiteError.usage("--only: no seed \(unknown) in the pool")
        }
        let chosen = only.isEmpty ? Array(pool.prefix(seedCount ?? pool.count)) : pool.filter { only.contains($0.name) }
        return chosen.map { seed in
            var seed = seed
            if let boatClass { seed.trial.boatClass = boatClass }
            return seed
        }
    }

    /// The seeds to sail.
    public func seeds() throws -> [TimeTrialSeed] {
        let pool = (pools.isEmpty ? [.reference] : pools).flatMap(\.seeds)
        if let seedCount, seedCount > pool.count {
            throw BotSuiteError.usage("--seeds: the pool has \(pool.count) seeds")
        }
        if let unknown = only.first(where: { name in !pool.contains { $0.name == name } }) {
            throw BotSuiteError.usage("--only: no seed \(unknown) in the pool")
        }
        let chosen = only.isEmpty ? Array(pool.prefix(seedCount ?? pool.count)) : pool.filter { only.contains($0.name) }
        return chosen.map { seed in
            var seed = seed
            if let boatClass { seed.boatClass = boatClass }
            if let laps { seed.laps = laps }
            return seed
        }
    }
}

/// One sailor's lap on one seed against the oracle's (#583): her time and where she lost it. Every gap is her seconds
/// less the oracle's.
public struct TimeTrialLoss: Codable, Hashable, Sendable {
    public var sailor: String
    /// Her finish, seconds after the gun; nil if she didn't finish by the close.
    public var finishSeconds: Double?
    /// Her seconds sailed (to her finish or the close) less the oracle's.
    public var gapSeconds: Double
    /// The gap by segment of the lap, in course order (`TimeTrialReport.segments`).
    public var segments: [Double]
    /// The gap by cause, in `LapLedger.Cause`'s order. They sum to `gapSeconds`.
    public var causes: [Double]
    /// Her tacks and gybes.
    public var manoeuvres: Int
}

/// One seed of the report.
public struct TimeTrialSeedResult: Codable, Hashable, Sendable {
    public var seed: TimeTrialSeed
    /// The oracle's finish, seconds after the gun; nil if its search found no finish.
    public var oracleSeconds: Double?
    /// The oracle's seconds by segment and by cause, as a sailor's gap is measured.
    public var oracleSegments: [Double]
    public var oracleCauses: [Double]
    public var oracleManoeuvres: Int
    /// The search's cost: nodes sailed, race ticks stepped.
    public var oracleNodes: Int
    public var oracleTicks: Int
    /// The re-sailed lap's digest: the same every run on one platform (`OracleTimeTrialTests`).
    public var oracleDigest: UInt64
    public var losses: [TimeTrialLoss]
}

/// The time trial's report (#583): per seed, then the mean over the pool for each sailor.
public struct TimeTrialReport: Codable, Hashable, Sendable {
    public var oracle: OracleSettings
    /// The segments' names, in course order: the start, each leg and each rounding.
    public var segments: [String]
    public var causes: [String]
    public var seeds: [TimeTrialSeedResult]

    /// The oracle's settings, as run.
    public struct OracleSettings: Codable, Hashable, Sendable {
        public var beamWidth: Int
        public var horizonSeconds: Double
        public var checkpointSeconds: Double
        public var eventCheckpoints: Bool

        public init(_ options: Oracle.Options) {
            beamWidth = options.beamWidth
            horizonSeconds = options.horizonSeconds
            checkpointSeconds = options.checkpointSeconds
            eventCheckpoints = options.eventCheckpoints
        }
    }

    public init(oracle: Oracle.Options, segments: [String], seeds: [TimeTrialSeedResult]) {
        self.oracle = OracleSettings(oracle)
        self.segments = segments
        causes = LapLedger.Cause.lap.map(\.rawValue)
        self.seeds = seeds
    }

    /// The mean over the seeds of each sailor's loss, in the report's sailor order; a sailor that didn't finish a seed
    /// counts her seconds to the close.
    public var means: [TimeTrialLoss] {
        guard let first = seeds.first else { return [] }
        let count = Double(seeds.count)
        return first.losses.indices.map { k in
            let losses = seeds.map { $0.losses[k] }
            func mean(_ values: [[Double]]) -> [Double] {
                let width = values.map(\.count).max() ?? 0
                return (0..<width).map { i in values.reduce(0) { $0 + ($1.indices.contains(i) ? $1[i] : 0) } / count }
            }
            let finishes = losses.compactMap(\.finishSeconds)
            return TimeTrialLoss(sailor: losses[0].sailor,
                                 finishSeconds: finishes.count == losses.count ? finishes.reduce(0, +) / count : nil,
                                 gapSeconds: losses.reduce(0) { $0 + $1.gapSeconds } / count,
                                 segments: mean(losses.map(\.segments)), causes: mean(losses.map(\.causes)),
                                 manoeuvres: Int((Double(losses.reduce(0) { $0 + $1.manoeuvres }) / count).rounded()))
        }
    }

    /// The oracle's mean finish over the seeds it finished.
    public var oracleMeanSeconds: Double? {
        let finishes = seeds.compactMap(\.oracleSeconds)
        return finishes.isEmpty ? nil : finishes.reduce(0, +) / Double(finishes.count)
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// The text report: the mean loss table (the owner's), then one line per seed.
    public var lines: [String] {
        var lines: [String] = []
        lines.append("regatta-timetrial: \(seeds.count) seeds, oracle beam \(oracle.beamWidth), horizon "
            + "\(format(oracle.horizonSeconds)) s, checkpoint \(format(oracle.checkpointSeconds)) s"
            + (oracle.eventCheckpoints ? " and on events" : ""))
        lines.append("oracle mean finish: \(oracleMeanSeconds.map { format($0) + " s" } ?? "none")")
        lines.append("")
        lines.append("mean seconds behind the oracle, by cause (they sum to the total):")
        let causeHeader = ["sailor", "total"] + causes
        var causeRows = [causeHeader]
        for mean in means {
            causeRows.append([mean.sailor, format(mean.gapSeconds)] + mean.causes.map(format))
        }
        lines += table(causeRows)
        lines.append("")
        lines.append("mean seconds behind the oracle, by leg (they sum to the total):")
        var segmentRows = [["sailor"] + segments]
        for mean in means { segmentRows.append([mean.sailor] + mean.segments.map(format)) }
        if !seeds.isEmpty {
            let count = Double(seeds.count)
            let oracleSegments = segments.indices.map { i in
                seeds.reduce(0) { $0 + ($1.oracleSegments.indices.contains(i) ? $1.oracleSegments[i] : 0) } / count
            }
            segmentRows.append(["(oracle s)"] + oracleSegments.map(format))
        }
        lines += table(segmentRows)
        lines.append("")
        lines.append("per seed, seconds behind the oracle (tacks and gybes):")
        var seedRows = [["seed", "conditions", "oracle s"] + (means.map(\.sailor))]
        for seed in seeds {
            seedRows.append([seed.seed.name, seed.seed.conditions,
                             seed.oracleSeconds.map(format) ?? "-"]
                            + seed.losses.map { loss in
                                (loss.finishSeconds == nil ? "DNF " : "") + format(loss.gapSeconds) + " (\(loss.manoeuvres))"
                            })
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

public enum TimeTrial {
    /// Sails `seed`: the oracle's search, its lap re-sailed under the ledger, and each of `sailors` alone.
    /// Sails `seed`: the oracle's search, its lap re-sailed under the ledger, and each of `sailors` alone, reading
    /// `tunables` if given. `known`, an earlier run of the seed, gives the oracle's lap instead of searching again
    /// (`--oracle-from`): its search doesn't read the tunables' bots but through its actions, so a tuning run keeps one.
    public static func run(_ seed: TimeTrialSeed, sailors: [TimeTrialSailor], oracle options: Oracle.Options,
                           tunables: BotTunables? = nil, known: TimeTrialSeedResult? = nil) throws -> TimeTrialSeedResult {
        let course = try TimeTrialCourse(seed)
        let segments = segmentKeys(course)
        func seconds(_ ledger: LapLedger) -> (segments: [Double], causes: [Double]) {
            let bySegment = ledger.bySegment
            let byCause = ledger.byCause
            return (segments.map { bySegment[$0] ?? 0 }, LapLedger.Cause.lap.map { byCause[$0] ?? 0 })
        }
        var result: TimeTrialSeedResult
        if let known {
            result = known
            result.losses = []
        } else {
            let plan = try Oracle(course: course, options: options).search()
            let lap = try course.replay(plan.inputs)
            let oracle = seconds(lap.ledger)
            result = TimeTrialSeedResult(seed: seed, oracleSeconds: lap.finishSeconds, oracleSegments: oracle.segments,
                                         oracleCauses: oracle.causes, oracleManoeuvres: lap.ledger.manoeuvres,
                                         oracleNodes: plan.nodes, oracleTicks: plan.ticks, oracleDigest: lap.digest, losses: [])
        }
        let oracleSailed = result.oracleSegments.reduce(0, +)
        result.losses = try sailors.map { sailor -> TimeTrialLoss in
            let run = try course.sail(sailor, tunables: tunables)
            let mine = seconds(run.ledger)
            return TimeTrialLoss(sailor: sailor.description, finishSeconds: run.finishSeconds,
                                 gapSeconds: run.sailedSeconds - oracleSailed,
                                 segments: zip(mine.segments, result.oracleSegments).map(-),
                                 causes: zip(mine.causes, result.oracleCauses).map(-), manoeuvres: run.ledger.manoeuvres)
        }
        return result
    }

    /// The ledger's segments in course order: the start, then each leg's sailing and its rounding.
    static func segmentKeys(_ course: TimeTrialCourse) -> [LapLedger.Segment] {
        [.start] + course.course.legs.indices.flatMap { k -> [LapLedger.Segment] in
            if case .round = course.course.legs[k] { return [.leg(k), .rounding(k)] }
            return [.leg(k)]
        }
    }

    /// The segments' names: "beat 1", "W 1" for its rounding, and so on.
    static func segmentNames(_ course: TimeTrialCourse) -> [String] {
        var seen: [String: Int] = [:]
        return segmentKeys(course).map { segment in
            switch segment {
            case .start: return "start"
            case .leg(let k):
                let leg = course.course.legs[k]
                let kind: String
                if case .finish = leg {
                    kind = "finish"
                } else if course.isReach[k] {
                    kind = "reach"
                } else {
                    let from = k == 0 ? course.course.startLine.centre : course.legTarget(k - 1)
                    kind = (course.legTarget(k) - from).dot(course.course.upwind) >= 0 ? "beat" : "run"
                }
                seen[kind, default: 0] += 1
                return "\(kind) \(seen[kind]!)"
            case .rounding(let k):
                let name = course.course.name(of: course.course.legs[k])
                let short = name == "leeward gate" ? "gate" : name
                seen[short, default: 0] += 1
                return "\(short) \(seen[short]!)"
            }
        }
    }

    /// `run(_:sailors:oracle:)` for each of `seeds`, up to `jobs` at once, in the seeds' order.
    public static func run(_ seeds: [TimeTrialSeed], sailors: [TimeTrialSailor], oracle options: Oracle.Options,
                           tunables: BotTunables? = nil, known: [TimeTrialSeedResult] = [],
                           jobs: Int = BotSuite.defaultJobs) throws -> [TimeTrialSeedResult] {
        try BotSuite.inParallel(seeds, jobs: jobs) { seed in
            try run(seed, sailors: sailors, oracle: options, tunables: tunables, known: known.first { $0.seed == seed })
        }
    }

    /// The whole time trial for `options`.
    public static func run(_ options: TimeTrialOptions) throws -> TimeTrialReport {
        let seeds = try options.seeds()
        let sailors = options.sailors
        let settings = options.oracle
        let results = try run(seeds, sailors: sailors, oracle: settings, tunables: options.tunables(),
                              known: options.knownOracle(), jobs: options.jobs ?? BotSuite.defaultJobs)
        let names = try seeds.first.map { segmentNames(try TimeTrialCourse($0)) } ?? []
        return TimeTrialReport(oracle: settings, segments: names, seeds: results)
    }

    public static func main(arguments: [String]) -> Int32 {
        do {
            let options = try TimeTrialOptions(arguments: arguments)
            if options.help {
                print(TimeTrialOptions.usage)
                return 0
            }
            if options.start, let seats = options.holdOut {
                let report = try HoldOneOut.run(options.startSeeds(), seats: seats.isEmpty ? nil : seats, tier: options.holdOutTier,
                                                tierMix: options.fleet, oracle: options.oracle,
                                                jobs: options.jobs ?? BotSuite.defaultJobs)
                try emit(report.lines, json: report.jsonData, to: options.jsonPath)
                return 0
            }
            if options.start {
                let report = try StartTrial.run(options.startSeeds(), sailors: options.sailors, oracle: options.oracle,
                                                jobs: options.jobs ?? BotSuite.defaultJobs)
                try emit(report.lines, json: report.jsonData, to: options.jsonPath)
                return 0
            }
            if let out = options.tuneOut {
                try TimeTrialTuner.run(options, out: out) { print($0) }
                return 0
            }
            let report = try run(options)
            try emit(report.lines, json: report.jsonData, to: options.jsonPath)
            return 0
        } catch {
            printError("regatta-timetrial: \(error)")
            if case BotSuiteError.usage = error { printError(TimeTrialOptions.usage) }
            return 2
        }
    }
}

/// Prints a report's `lines`, and writes its JSON to `path` if given: to stdout for `-`, the lines then to stderr.
private func emit(_ lines: [String], json: () throws -> Data, to path: String?) throws {
    let toStdout = path == "-"
    for line in lines {
        if toStdout { printError(line) } else { print(line) }
    }
    guard let path else { return }
    let data = try json()
    if toStdout {
        print(String(decoding: data, as: UTF8.self))
    } else {
        try data.write(to: URL(fileURLWithPath: path))
    }
}

private func printError(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}
