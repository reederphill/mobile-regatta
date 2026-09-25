import Foundation
import RegattaCore

public enum BenchError: Error, Equatable, CustomStringConvertible {
    case usage(String)
    case noTicks(String)

    public var description: String {
        switch self {
        case .usage(let message): message
        case .noTicks(let scenario): "\(scenario): the race was over before a tick was timed"
        }
    }
}

/// One scenario's numbers (#69), exported as JSON for #105.
public struct ScenarioResult: Codable, Hashable, Sendable {
    public var name: String
    public var boats: Int
    /// Tick times of one race on its own.
    public var tick: TickStats
    /// Races stepped together, interleaved on one thread.
    public var races: Int
    /// Race ticks stepped across those races.
    public var raceTicks: Int
    /// Wall time of those race ticks over their count: one race's share of a tick on one core.
    public var meanRaceTickMs: Double
    /// `tickBudgetMs / meanRaceTickMs`: how many races one core keeps at 30 Hz.
    public var racesPerVCPU: Double
    /// Frame bytes encoded per timed race tick: every seat's snapshots and events.
    public var encodedBytesPerRaceTick: Double

    public init(name: String, boats: Int, tick: TickStats, races: Int, raceTicks: Int, meanRaceTickMs: Double,
                encodedBytesPerRaceTick: Double = 0) {
        self.name = name
        self.boats = boats
        self.tick = tick
        self.races = races
        self.raceTicks = raceTicks
        self.meanRaceTickMs = meanRaceTickMs
        racesPerVCPU = Bench.racesPerVCPU(meanRaceTickMs: meanRaceTickMs)
        self.encodedBytesPerRaceTick = encodedBytesPerRaceTick
    }
}

/// The tick benchmark (#69; #18 Linux benchmark, #27 budget).
public enum Bench {
    /// One tick at 30 Hz: every race on a core must step within it.
    public static let tickBudgetMs = 1000 / Double(Race.tickRate)

    /// How many races one core keeps at 30 Hz when a race tick costs `meanRaceTickMs` on it.
    public static func racesPerVCPU(meanRaceTickMs: Double) -> Double {
        tickBudgetMs / meanRaceTickMs
    }

    /// Times `scenario`: first one race alone, tick by tick, for p50/p99/max; then `races` races stepped
    /// round-robin on this thread (one core) for the mean cost of a race tick, from which
    /// races/vCPU = `tickBudgetMs / meanRaceTickMs`. Both include snapshot encoding. `ticks` overrides the
    /// scenario's.
    public static func run(_ scenario: Scenario, ticks: Int? = nil, races: Int) throws -> ScenarioResult {
        let ticks = ticks ?? scenario.ticks
        let clock = ContinuousClock()

        let alone = try BenchRace(scenario, index: 0)
        warmUp(alone, scenario)
        var samples: [Double] = []
        samples.reserveCapacity(ticks)
        for _ in 0..<ticks where !alone.isOver {
            let start = clock.now
            alone.step()
            samples.append(milliseconds(clock.now - start))
        }
        guard !samples.isEmpty else { throw BenchError.noTicks(scenario.name) }

        let fleet = try (0..<races).map { try BenchRace(scenario, index: $0) }
        for race in fleet { warmUp(race, scenario) }
        let warmUpBytes = fleet.reduce(0) { $0 &+ $1.bytesSent }
        var raceTicks = 0
        let start = clock.now
        for _ in 0..<ticks {
            var stepped = false
            for race in fleet where !race.isOver {
                race.step()
                raceTicks += 1
                stepped = true
            }
            if !stepped { break }
        }
        let elapsed = milliseconds(clock.now - start)
        guard raceTicks > 0 else { throw BenchError.noTicks(scenario.name) }
        let bytes = fleet.reduce(0) { $0 &+ $1.bytesSent } &- warmUpBytes
        return ScenarioResult(name: scenario.name, boats: scenario.boats, tick: TickStats(samples: samples),
                              races: races, raceTicks: raceTicks, meanRaceTickMs: elapsed / Double(raceTicks),
                              encodedBytesPerRaceTick: Double(bytes) / Double(raceTicks))
    }

    private static func warmUp(_ race: BenchRace, _ scenario: Scenario) {
        for _ in 0..<scenario.warmupTicks where !race.isOver { race.step() }
    }

    static func milliseconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1000 + Double(attoseconds) / 1e15
    }
}

/// What `--json` writes (#69): the numbers for #105.
public struct BenchReport: Codable, Hashable, Sendable {
    public var tickBudgetMs: Double
    public var thresholds: Thresholds
    /// Whether the run was `--gate`d: only then does a miss exit non-zero.
    public var gated: Bool
    /// Whether every scenario meets the thresholds, gated or not.
    public var passed: Bool
    public var failures: [String]
    public var cpuCount: Int
    public var scenarios: [ScenarioResult]

    public init(results: [ScenarioResult], thresholds: Thresholds, gated: Bool) {
        tickBudgetMs = Bench.tickBudgetMs
        self.thresholds = thresholds
        self.gated = gated
        failures = thresholds.failures(of: results)
        passed = failures.isEmpty
        cpuCount = ProcessInfo.processInfo.activeProcessorCount
        scenarios = results
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// The report for a person: one line per scenario, then the thresholds' verdict.
    public var lines: [String] {
        var lines = scenarios.map { result in
            "\(result.name): \(result.boats) boats, \(result.tick.ticks) ticks: p50 \(ms(result.tick.p50Ms)), "
                + "p99 \(ms(result.tick.p99Ms)), max \(ms(result.tick.maxMs)); \(result.races) races on one core: "
                + "\(ms(result.meanRaceTickMs)) per race tick, races/vCPU \(fixed(result.racesPerVCPU, 1))"
        }
        let budget = "p99 <= \(ms(thresholds.maxP99Ms)), races/vCPU >= \(fixed(thresholds.minRacesPerVCPU, 1))"
        lines.append("\(gated ? "gate" : "budget"): \(passed ? "pass" : "FAIL") (\(budget))")
        lines += failures.map { "  \($0)" }
        return lines
    }
}

func ms(_ value: Double) -> String { "\(fixed(value, 3)) ms" }

func fixed(_ value: Double, _ digits: Int) -> String { String(format: "%.\(digits)f", value) }
