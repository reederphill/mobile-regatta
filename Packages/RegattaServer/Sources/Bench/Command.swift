import Foundation

/// `regatta-bench`'s arguments (#69).
public struct BenchOptions: Hashable, Sendable {
    /// A scenarios JSON file instead of the bundled list.
    public var scenariosPath: String?
    /// Only these scenarios, by name; all when empty.
    public var scenarioNames: [String] = []
    /// Timed ticks per race, instead of each scenario's.
    public var ticks: Int?
    /// Races stepped together on one core for races/vCPU.
    public var races = 20
    /// Exit non-zero when a scenario misses the thresholds.
    public var gate = false
    public var thresholds = Thresholds.budget
    /// Where to write the JSON report; `-` for stdout (the text report then goes to stderr).
    public var jsonPath: String?
    public var help = false

    public init() {}

    public static let usage = """
        usage: regatta-bench [options]
          --scenarios <path>          scenarios JSON file (default: the bundled scenarios.json)
          --scenario <name>           run only this scenario (repeatable)
          --ticks <n>                 timed ticks per race, overriding each scenario's
          --races <n>                 races stepped together on one core for races/vCPU (default 20)
          --gate                      exit 1 when a scenario's p99 or races/vCPU misses the thresholds
          --max-p99-ms <ms>           p99 tick threshold (default 5)
          --min-races-per-vcpu <n>    races/vCPU threshold (default 20)
          --thresholds <path>         JSON {"maxP99Ms": ..., "minRacesPerVCPU": ...}; later flags override it
          --json <path|->             write the JSON report there (- for stdout)
        """

    /// Parses `arguments` (without the program name).
    public init(arguments: [String]) throws {
        var rest = arguments[...]
        func value(_ flag: String) throws -> String {
            guard let value = rest.popFirst() else { throw BenchError.usage("\(flag) needs a value") }
            return value
        }
        func number<T: LosslessStringConvertible>(_ flag: String, _: T.Type) throws -> T {
            let text = try value(flag)
            guard let number = T(text) else { throw BenchError.usage("\(flag): not a number: \(text)") }
            return number
        }
        while let flag = rest.popFirst() {
            switch flag {
            case "--scenarios": scenariosPath = try value(flag)
            case "--scenario": scenarioNames.append(try value(flag))
            case "--ticks": ticks = try number(flag, Int.self)
            case "--races": races = try number(flag, Int.self)
            case "--gate": gate = true
            case "--max-p99-ms": thresholds.maxP99Ms = try number(flag, Double.self)
            case "--min-races-per-vcpu": thresholds.minRacesPerVCPU = try number(flag, Double.self)
            case "--thresholds":
                let path = try value(flag)
                thresholds = try JSONDecoder().decode(Thresholds.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            case "--json": jsonPath = try value(flag)
            case "-h", "--help": help = true
            default: throw BenchError.usage("unknown argument: \(flag)")
            }
        }
        if let ticks, ticks < 1 { throw BenchError.usage("--ticks must be at least 1") }
        if races < 1 { throw BenchError.usage("--races must be at least 1") }
    }
}

/// The `regatta-bench` command: runs the scenarios, prints the report, and with `--gate` exits 1 when
/// a scenario misses the thresholds. Exit 2 is a usage or setup error.
public enum BenchCommand {
    public static func main(arguments: [String]) -> Int32 {
        do {
            let options = try BenchOptions(arguments: arguments)
            if options.help {
                print(BenchOptions.usage)
                return 0
            }
            return try run(options)
        } catch {
            printError("regatta-bench: \(error)")
            if error is BenchError { printError(BenchOptions.usage) }
            return 2
        }
    }

    static func run(_ options: BenchOptions) throws -> Int32 {
        var scenarios = try options.scenariosPath.map { try Scenario.load(from: URL(fileURLWithPath: $0)) }
            ?? Scenario.bundled()
        if !options.scenarioNames.isEmpty {
            let unknown = Set(options.scenarioNames).subtracting(scenarios.map(\.name))
            guard unknown.isEmpty else { throw BenchError.usage("unknown scenario: \(unknown.sorted().joined(separator: ", "))") }
            scenarios = scenarios.filter { options.scenarioNames.contains($0.name) }
        }
        guard !scenarios.isEmpty else { throw BenchError.usage("no scenarios to run") }

        let results = try scenarios.map { try Bench.run($0, ticks: options.ticks, races: options.races) }
        let report = BenchReport(results: results, thresholds: options.thresholds, gated: options.gate)
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
        return options.gate && !report.passed ? 1 : 0
    }

    private static func printError(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
