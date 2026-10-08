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
    /// Races sailed at once; nil for `BotSuite.defaultJobs`. 1 sails them one after another.
    public var jobs: Int?
    /// Where to write the JSON report; `-` for stdout (the text report then goes to stderr).
    public var jsonPath: String?
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
                                 cautious, rivals, rankStability (repeatable)
          --laps <n>             laps per race instead of the matrix's
          --json <path|->        write the JSON report there (- for stdout)
          --jobs <n>             races sailed at once (default: the performance cores; 1 = one after another).
                                 The report is the same for any n but for the tick times
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
            case "--json": jsonPath = try value(flag)
            case "--jobs": jobs = try number(flag)
            case "-h", "--help": help = true
            default: throw BotSuiteError.usage("unknown argument: \(flag)")
            }
        }
        if let seedCount, seedCount < 1 { throw BotSuiteError.usage("--seeds must be at least 1") }
        if let jobs, jobs < 1 { throw BotSuiteError.usage("--jobs must be at least 1") }
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
    public static func run(_ matrix: BotMatrix, thresholds: BotThresholds, jobs: Int = 1) throws -> BotSuiteReport {
        let races = try inParallel(matrix.cells, jobs: jobs, BotRaceHarness.run)
        return BotSuiteReport(matrix: matrix, thresholds: thresholds, races: races)
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
        let report = try BotSuite.run(options.matrix(), thresholds: options.thresholds(),
                                      jobs: options.jobs ?? BotSuite.defaultJobs)
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

    private static func printError(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
