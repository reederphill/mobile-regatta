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
    public var laps: Int?
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
          --tier-mix <mix>       sail only this tier mix: seeded, club, regional, national, mixed (repeatable)
          --laps <n>             laps per race instead of the matrix's
          --json <path|->        write the JSON report there (- for stdout)
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
            case "--laps": laps = try number(flag)
            case "--json": jsonPath = try value(flag)
            case "-h", "--help": help = true
            default: throw BotSuiteError.usage("unknown argument: \(flag)")
            }
        }
        if let seedCount, seedCount < 1 { throw BotSuiteError.usage("--seeds must be at least 1") }
    }

    /// The matrix to sail: the file's or the bundled one, with this command line's overrides.
    public func matrix() throws -> BotMatrix {
        var matrix = try matrixPath.map { try BotMatrix.load(from: URL(fileURLWithPath: $0)) } ?? BotMatrix.bundled()
        if let seedCount { matrix.seeds = (1...seedCount).map(UInt64.init) }
        if !fleetSizes.isEmpty { matrix.fleetSizes = fleetSizes }
        if !tierMixes.isEmpty { matrix.tierMixes = tierMixes }
        if let laps { matrix.laps = laps }
        try matrix.validate()
        return matrix
    }

    public func thresholds() throws -> BotThresholds {
        try thresholdsPath.map { try BotThresholds.load(from: URL(fileURLWithPath: $0)) } ?? BotThresholds.bundled()
    }
}

/// The suite's runner: sails every race of a matrix, one after another so the tick times aren't shared.
public enum BotSuite {
    public static func run(_ matrix: BotMatrix, thresholds: BotThresholds) throws -> BotSuiteReport {
        let races = try matrix.cells.map(BotRaceHarness.run)
        return BotSuiteReport(matrix: matrix, thresholds: thresholds, races: races)
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
        let report = try BotSuite.run(options.matrix(), thresholds: options.thresholds())
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
