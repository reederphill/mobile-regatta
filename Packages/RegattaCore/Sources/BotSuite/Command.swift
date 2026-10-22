import Foundation

/// `regatta-botsuite`'s arguments (#97).
public struct BotSuiteOptions: Hashable, Sendable {
    /// A matrix JSON file instead of the bundled `matrix.json`.
    public var matrixPath: String?
    /// A thresholds JSON file instead of the bundled `thresholds.json`.
    public var thresholdsPath: String?
    /// Seeds 1…n instead of the matrix's.
    public var seedCount: Int?
    /// Only these fleet sizes, instead of the matrix's; all when empty.
    public var fleetSizes: [Int] = []
    /// Only these tier mixes, instead of the matrix's; all when empty.
    public var tierMixes: [TierMix] = []
    /// Only these profile mixes (#231), instead of the matrix's; all when empty.
    public var profileMixes: [ProfileMix] = []
    public var laps: Int?
    /// `--autohelm off` (#435): sail every race on a copy of its class with the autohelm off a centred rudder, so the
    /// bots steer by hand; nil or `on` sails the matrix's setting.
    public var autohelmOff: Bool?
    /// `--boat-class id@version` (#462): sail every race on that bundled class instead of the default.
    public var boatClass: String?
    /// `--rules id@version` (#477): sail every race on those bundled rules instead of the default.
    public var rules: String?
    /// Races sailed at once; nil for `BotSuite.defaultJobs`. 1 sails them one after another.
    public var jobs: Int?
    /// Where to write the JSON report; `-` for stdout (the text report then goes to stderr).
    public var jsonPath: String?
    /// `--diagnose` (#471): also watch every race for why boats start late, what their penalty turns cost, why they
    /// don't finish and how wide they round the marks (`RaceObserver`), and add the tables to the report
    /// (`BotSuiteReport.diagnose`). The races, and the rest of the report, are the same with it or without.
    public var diagnose = false
    /// `--scenario pack` (#525) or `overtake` (#530): sail that scenario (`PackScenario`, `OvertakeScenario`) instead of
    /// the matrix. `--fleet-size` (the pack
    /// size), `--tier-mix`, `--seeds`, `--jobs`, `--json`, `--autohelm`, `--boat-class` and `--rules` apply to it as they do to the
    /// matrix; `--matrix`, `--thresholds`, `--profile-mix`, `--laps` and `--diagnose` do not.
    public var scenario: String?
    /// `--pack-current with|without|both`: the venues the pack scenario sails; nil for both.
    public var packCurrent: PackCurrent?
    /// `--pack-offset <hull lengths>`: where the bunch lies across the gate; all of `PackScenario.defaultOffsets` when empty.
    public var packOffsets: [Double] = []
    /// `--pack-above <metres>`: how far above the gate's line the bunch lies; nil for `PackScenario.defaultAbove`.
    public var packAbove: Double?
    /// `--overtake-phase prestart|beat|both`: the overtake scenario's phases (`OvertakeScenario`, #530); all when empty.
    public var overtakePhases: [OvertakePhase] = []
    /// `--overtake-tack port|starboard|both`: the scripted boat's tacks; both when empty.
    public var overtakeTacks: [OvertakeTack] = []
    /// `--overtake-current with|without|both`: the venues the overtake scenario sails; nil for both.
    public var overtakeCurrent: PackCurrent?
    /// `--overtake-astern <hull lengths>`: the first bot's distances astern; all of `OvertakeScenario.defaultAstern`
    /// when empty.
    public var overtakeAstern: [Double] = []
    /// `--overtake-control`: also sail each layout with the scripted boat far abeam to leeward, nobody ahead of the bots.
    public var overtakeControl = false
    public var help = false

    public init() {}

    public static let usage = """
        usage: regatta-botsuite [options]
          --matrix <path>        matrix JSON file (default: the bundled matrix.json)
          --thresholds <path>    thresholds JSON file (default: the bundled thresholds.json)
          --seeds <n>            sail seeds 1...n instead of the matrix's
          --fleet-size <n>       sail only this fleet size (repeatable)
          --tier-mix <mix>       sail only this tier mix: club, regional, national, mixed (repeatable)
          --profile-mix <mix>    sail only this profile mix: live, skillGap, funPass, hunters, execution,
                                 cautious, rivals, rankStability, handling, parity (repeatable). Read parity
                                 (handling against tactics, #426 Q1) in two-boat races: --profile-mix parity
                                 --fleet-size 2 --seeds 384 (a multiple of 12, so every seat order sails as often)
          --autohelm <on|off>    off: sail each race on a copy of its class with the autohelm off a centred
                                 rudder, so the bots steer by hand (default: the matrix's, the class as bundled)
          --boat-class <id@v>    sail every race on that bundled class (e.g. skiff@8) instead of the default
          --rules <id@v>         sail every race on those bundled rules (e.g. fleet-rules@8) instead of the default
          --laps <n>             laps per race instead of the matrix's
          --json <path|->        write the JSON report there (- for stdout)
          --diagnose             also print, and write under the JSON's "diagnose" key, why boats start late,
                                 what their penalty turns cost, why they don't finish and how wide they round
                                 the marks; the races and the rest of the report are the same with it or without
          --jobs <n>             races sailed at once (default: the performance cores; 1 = one after another).
                                 The report is the same for any n but for the tick times
          --scenario <name>      sail a scenario instead of the matrix. pack: 4-6 boats in a bunch above the leeward
                                 gate, sailed through it, and measured (no thresholds; exits 0 on a sailed run).
                                 Uses --fleet-size (pack size, default 4, 5 and 6), --tier-mix (default national),
                                 --seeds (default 16), --jobs, --json, --autohelm, --boat-class and --rules; takes none of
                                 --matrix, --thresholds, --profile-mix, --laps or --diagnose.
                                 overtake: a scripted boat at 60-70% of the polar on the first beat, or eased below
                                 the line before the gun, with live bots placed astern of her on her tack (no
                                 thresholds; exits 0 on a sailed run). Uses --fleet-size (her and the bots, default
                                 2), --tier-mix (default national), --seeds (default 16), --jobs, --json, --autohelm,
                                 --boat-class and --rules; takes none of the pack's or the matrix's own flags
          --pack-current <c>     with the pack scenario: with, without or both (default) a current
          --pack-offset <n>      with the pack scenario: the bunch's centre this many hull lengths across the gate from
                                 its middle (repeatable; default -6, 0 and 6; the gate is 10 hull lengths wide)
          --pack-above <m>       with the pack scenario: metres above the gate's line the bunch's centre lies (default 100)
          --overtake-phase <p>   with the overtake scenario: prestart, beat or both (default)
          --overtake-tack <t>    with the overtake scenario: her tack, port, starboard or both (default)
          --overtake-current <c> with the overtake scenario: with, without or both (default) a current
          --overtake-astern <n>  with the overtake scenario: the first bot this many hull lengths astern of her,
                                 centre to centre (repeatable; default 2, 4 and 6; each further bot 2 more)
          --overtake-control     with the overtake scenario: also sail each layout with her 30 hull lengths straight
                                 across the course, the bots read against a phantom of her (the false-fire and
                                 tack-away rates)
        Exits 1 when the run misses the thresholds, 2 on a usage or setup error.
        """

    /// Parses `arguments` (without the program name).
    public init(arguments: [String]) throws {
        var rest = arguments[...]
        func value(_ flag: String) throws -> String {
            guard let value = rest.popFirst() else { throw BotSuiteError.usage("\(flag) needs a value") }
            return value
        }
        func number(_ flag: String) throws -> Int {
            let text = try value(flag)
            guard let number = Int(text) else { throw BotSuiteError.usage("\(flag): not a number: \(text)") }
            return number
        }
        while let flag = rest.popFirst() {
            switch flag {
            case "--matrix": matrixPath = try value(flag)
            case "--thresholds": thresholdsPath = try value(flag)
            case "--seeds": seedCount = try number(flag)
            case "--fleet-size": fleetSizes.append(try number(flag))
            case "--tier-mix":
                let text = try value(flag)
                guard let mix = TierMix(rawValue: text) else { throw BotSuiteError.usage("--tier-mix: unknown mix \(text)") }
                tierMixes.append(mix)
            case "--profile-mix":
                let text = try value(flag)
                guard let mix = ProfileMix(rawValue: text) else { throw BotSuiteError.usage("--profile-mix: unknown mix \(text)") }
                profileMixes.append(mix)
            case "--laps": laps = try number(flag)
            case "--autohelm":
                switch try value(flag) {
                case "on": autohelmOff = false
                case "off": autohelmOff = true
                case let text: throw BotSuiteError.usage("--autohelm: on or off, not \(text)")
                }
            case "--boat-class": boatClass = try value(flag)
            case "--rules": rules = try value(flag)
            case "--json": jsonPath = try value(flag)
            case "--jobs": jobs = try number(flag)
            case "--diagnose": diagnose = true
            case "--scenario": scenario = try value(flag)
            case "--pack-current":
                let text = try value(flag)
                guard let current = PackCurrent(rawValue: text) else {
                    throw BotSuiteError.usage("--pack-current: with, without or both, not \(text)")
                }
                packCurrent = current
            case "--pack-offset":
                let text = try value(flag)
                guard let offset = Double(text), offset.isFinite else { throw BotSuiteError.usage("--pack-offset: not a number: \(text)") }
                packOffsets.append(offset)
            case "--pack-above":
                let text = try value(flag)
                guard let above = Double(text), above.isFinite, above > 0 else {
                    throw BotSuiteError.usage("--pack-above: not a positive number: \(text)")
                }
                packAbove = above
            case "--overtake-phase":
                let text = try value(flag)
                if text == "both" { overtakePhases = OvertakePhase.allCases; continue }
                guard let phase = OvertakePhase(rawValue: text) else {
                    throw BotSuiteError.usage("--overtake-phase: prestart, beat or both, not \(text)")
                }
                overtakePhases = [phase]
            case "--overtake-tack":
                let text = try value(flag)
                if text == "both" { overtakeTacks = OvertakeTack.allCases; continue }
                guard let tack = OvertakeTack(rawValue: text) else {
                    throw BotSuiteError.usage("--overtake-tack: port, starboard or both, not \(text)")
                }
                overtakeTacks = [tack]
            case "--overtake-current":
                let text = try value(flag)
                guard let current = PackCurrent(rawValue: text) else {
                    throw BotSuiteError.usage("--overtake-current: with, without or both, not \(text)")
                }
                overtakeCurrent = current
            case "--overtake-astern":
                let text = try value(flag)
                guard let astern = Double(text), astern.isFinite, astern > 0 else {
                    throw BotSuiteError.usage("--overtake-astern: not a positive number: \(text)")
                }
                overtakeAstern.append(astern)
            case "--overtake-control": overtakeControl = true
            case "-h", "--help": help = true
            default: throw BotSuiteError.usage("unknown argument: \(flag)")
            }
        }
        if let seedCount, seedCount < 1 { throw BotSuiteError.usage("--seeds must be at least 1") }
        if let jobs, jobs < 1 { throw BotSuiteError.usage("--jobs must be at least 1") }
        try validateScenario()
    }

    /// `--scenario`'s own checks: a scenario it knows, with none of the matrix's flags it has no use for, and the
    /// scenario's flags only with it.
    private func validateScenario() throws {
        let packFlags = packCurrent != nil || !packOffsets.isEmpty || packAbove != nil
        let overtakeFlags = !overtakePhases.isEmpty || !overtakeTacks.isEmpty || overtakeCurrent != nil
            || !overtakeAstern.isEmpty || overtakeControl
        if packFlags, scenario != "pack" {
            throw BotSuiteError.usage("--pack-current, --pack-offset and --pack-above need --scenario pack")
        }
        if overtakeFlags, scenario != "overtake" {
            throw BotSuiteError.usage("--overtake-phase, --overtake-tack, --overtake-current, --overtake-astern and "
                + "--overtake-control need --scenario overtake")
        }
        guard let scenario else { return }
        guard ["pack", "overtake"].contains(scenario) else {
            throw BotSuiteError.usage("--scenario: unknown scenario \(scenario) (pack, overtake)")
        }
        let refused = [("--matrix", matrixPath != nil), ("--thresholds", thresholdsPath != nil),
                       ("--profile-mix", !profileMixes.isEmpty), ("--laps", laps != nil), ("--diagnose", diagnose)]
            .filter(\.1).map(\.0)
        if !refused.isEmpty {
            throw BotSuiteError.usage("--scenario \(scenario) takes none of \(refused.joined(separator: ", ")): it sails no matrix")
        }
        if scenario == "pack", let size = fleetSizes.first(where: { $0 < PackScenario.packNeighbours + 1 }) {
            throw BotSuiteError.usage("--fleet-size \(size): a pack needs at least \(PackScenario.packNeighbours + 1) boats")
        }
        if scenario == "overtake", let size = fleetSizes.first(where: { $0 < 2 }) {
            throw BotSuiteError.usage("--fleet-size \(size): the overtake scenario needs her and at least one bot")
        }
    }

    /// The matrix to sail: the file's or the bundled one, with this command line's overrides.
    public func matrix() throws -> BotMatrix {
        var matrix = try matrixPath.map { try BotMatrix.load(from: URL(fileURLWithPath: $0)) } ?? BotMatrix.bundled()
        if let seedCount { matrix.seeds = (1...seedCount).map(UInt64.init) }
        if !fleetSizes.isEmpty { matrix.fleetSizes = fleetSizes }
        if !tierMixes.isEmpty { matrix.tierMixes = tierMixes }
        if !profileMixes.isEmpty {
            matrix.profileMixes = profileMixes
        } else if !fleetSizes.isEmpty || !tierMixes.isEmpty {
            // Narrowed to fleets or tiers some of the matrix's mixes aren't sailed in (`ProfileMix.tierMix`,
            // `BotMatrix.mixFleetSizes`): those mixes weren't asked for by name, so leave them out. A mix named with
            // `--profile-mix` that sails nothing is refused (`validate`).
            let narrowed = matrix
            matrix.profileMixes = matrix.profileMixes.filter(narrowed.sailsAny)
        }
        if let laps { matrix.laps = laps }
        if let autohelmOff { matrix.autohelmOff = autohelmOff }
        if let boatClass {
            _ = try BotRaceHarness.bundledClass(boatClass)
            matrix.boatClass = boatClass
        }
        if let rules {
            _ = try BotRaceHarness.bundledRules(rules)
            matrix.rules = rules
        }
        try matrix.validate()
        return matrix
    }

    public func thresholds() throws -> BotThresholds {
        try thresholdsPath.map { try BotThresholds.load(from: URL(fileURLWithPath: $0)) } ?? BotThresholds.bundled()
    }
}

/// The suite's runner: sails every race of a matrix, `jobs` at a time.
///
/// Each race is its own: built from its cell's seeds, sailed on one thread, and reduced to its `RaceResult` there (the
/// harness keeps no state between races, and RegattaCore and RegattaBots hold no shared mutable state, which Swift 6's
/// strict concurrency checks). The results are put back in the matrix's order before the report pools them, so the report
/// is the same for any `jobs` but for the tick times, which a busy machine stretches.
public enum BotSuite {
    /// With `diagnose` (#471) a `RaceObserver` watches each race too, and the report carries its tables
    /// (`BotSuiteReport.diagnose`); everything else in the report is the same.
    public static func run(_ matrix: BotMatrix, thresholds: BotThresholds, jobs: Int = 1,
                           diagnose: Bool = false) throws -> BotSuiteReport {
        guard diagnose else {
            let races = try inParallel(matrix.cells, jobs: jobs, BotRaceHarness.run)
            return BotSuiteReport(matrix: matrix, thresholds: thresholds, races: races)
        }
        let sailed = try inParallel(matrix.cells, jobs: jobs, BotRaceHarness.runDiagnosed)
        var report = BotSuiteReport(matrix: matrix, thresholds: thresholds, races: sailed.map(\.result))
        report.diagnose = DiagnoseSummary(sailed.map(\.diagnosis), seats: report.races.flatMap(\.seats))
        report.diagnose?.startStrategies = StartStrategySummary(report.races)
        report.diagnose?.lanes = LanesSummary(report.races)
        return report
    }

    /// `regatta-botsuite`'s default `--jobs`: the performance cores on Apple silicon (`hw.perflevel0.physicalcpu`), so the
    /// races keep off the efficiency cores; the active processors elsewhere (the Linux CI container).
    public static var defaultJobs: Int {
        #if canImport(Darwin)
        var cores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &cores, &size, nil, 0) == 0, cores > 0 { return Int(cores) }
        #endif
        return max(ProcessInfo.processInfo.activeProcessorCount, 1)
    }

    /// `transform` over `items`, up to `jobs` at once, the results in `items`' order. Each worker takes the next index
    /// in turn; the first error by index is thrown, as a serial map would throw it.
    static func inParallel<Item: Sendable, Result: Sendable>(_ items: [Item], jobs: Int,
                                                             _ transform: @Sendable (Item) throws -> Result) throws -> [Result] {
        let workers = min(max(jobs, 1), items.count)
        guard workers > 1 else { return try items.map(transform) }
        let slots = ResultSlots<Result>(count: items.count)
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            while let index = slots.claim() {
                let outcome = Swift.Result { try transform(items[index]) }
                slots.store(outcome, at: index)
            }
        }
        return try slots.results()
    }
}

/// The parallel map's shared state: the next index to claim and each index's outcome, behind one lock.
private final class ResultSlots<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var next = 0
    private var failed = false
    private var outcomes: [Result<Value, any Error>?]

    init(count: Int) { outcomes = Array(repeating: nil, count: count) }

    /// The next index to sail, or nil when none is left or a race has failed (the indices before it still finish).
    func claim() -> Int? {
        lock.withLock {
            guard !failed, next < outcomes.count else { return nil }
            defer { next += 1 }
            return next
        }
    }

    func store(_ outcome: Result<Value, any Error>, at index: Int) {
        lock.withLock {
            outcomes[index] = outcome
            if case .failure = outcome { failed = true }
        }
    }

    /// Every result in order, or the lowest index's error.
    func results() throws -> [Value] {
        try lock.withLock {
            var values: [Value] = []
            values.reserveCapacity(outcomes.count)
            for outcome in outcomes {
                guard let outcome else { break }  // unclaimed after a failure: the failure comes first
                values.append(try outcome.get())
            }
            return values
        }
    }
}

/// The `regatta-botsuite` command: sails the matrix, prints the report, and exits 1 when the run misses
/// the thresholds. Exit 2 is a usage or setup error.
public enum BotSuiteCommand {
    public static func main(arguments: [String]) -> Int32 {
        do {
            let options = try BotSuiteOptions(arguments: arguments)
            if options.help {
                print(BotSuiteOptions.usage)
                return 0
            }
            return try run(options)
        } catch {
            printError("regatta-botsuite: \(error)")
            if case BotSuiteError.usage = error { printError(BotSuiteOptions.usage) }
            return 2
        }
    }

    static func run(_ options: BotSuiteOptions) throws -> Int32 {
        if options.scenario != nil { return try runScenario(options) }
        let report = try BotSuite.run(options.matrix(), thresholds: options.thresholds(),
                                      jobs: options.jobs ?? BotSuite.defaultJobs, diagnose: options.diagnose)
        let toStdout = options.jsonPath == "-"
        for line in report.lines {
            if toStdout { printError(line) } else { print(line) }
        }
        if let path = options.jsonPath {
            let data = try report.jsonData()
            if toStdout {
                print(String(decoding: data, as: UTF8.self))
            } else {
                try data.write(to: URL(fileURLWithPath: path))
            }
        }
        return report.passed ? 0 : 1
    }

    /// `--scenario pack` or `overtake`: sails the scenario, prints its table and writes its JSON; no thresholds, so
    /// exit 0.
    private static func runScenario(_ options: BotSuiteOptions) throws -> Int32 {
        if options.scenario == "overtake" {
            let report = try OvertakeScenario.run(options)
            try emit(lines: report.lines, json: report.jsonData, options: options)
        } else {
            let report = try PackScenario.run(options)
            try emit(lines: report.lines, json: report.jsonData, options: options)
        }
        return 0
    }

    /// A scenario's table, to stdout (stderr when the JSON goes there), and its JSON where `--json` says.
    private static func emit(lines: [String], json: () throws -> Data, options: BotSuiteOptions) throws {
        let toStdout = options.jsonPath == "-"
        for line in lines {
            if toStdout { printError(line) } else { print(line) }
        }
        if let path = options.jsonPath {
            let data = try json()
            if toStdout {
                print(String(decoding: data, as: UTF8.self))
            } else {
                try data.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    private static func printError(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
