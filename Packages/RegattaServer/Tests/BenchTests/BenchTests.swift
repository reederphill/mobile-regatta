import Bench
import Foundation
import RegattaCore
import Testing

@Suite struct BenchTests {
    // MARK: - Pure

    /// Nearest rank: the smallest sample with at least p% of the samples at or below it.
    @Test func percentileIsNearestRank() {
        let samples = (1...100).map(Double.init)
        #expect(TickStats.percentile(50, ofSorted: samples) == 50)
        #expect(TickStats.percentile(99, ofSorted: samples) == 99)
        #expect(TickStats.percentile(100, ofSorted: samples) == 100)
        #expect(TickStats.percentile(0, ofSorted: samples) == 1)
        #expect(TickStats.percentile(99, ofSorted: [3]) == 3)
        // 99% of 10 samples is 9.9, so rank 10: the largest.
        #expect(TickStats.percentile(99, ofSorted: (1...10).map(Double.init)) == 10)
        #expect(TickStats.percentile(50, ofSorted: [1, 2, 3, 4]) == 2)
    }

    @Test func tickStatsSortTheirSamples() {
        let stats = TickStats(samples: [0.4, 0.1, 9, 0.2, 0.3])
        #expect(stats.ticks == 5)
        #expect(stats.p50Ms == 0.3)
        #expect(stats.p99Ms == 9)
        #expect(stats.maxMs == 9)
    }

    /// races/vCPU is how many race ticks fit in one 30 Hz tick on one core.
    @Test func racesPerVCPUIsTheTickBudgetOverTheRaceTick() {
        #expect(abs(Bench.tickBudgetMs - 1000.0 / 30) < 1e-9)
        #expect(abs(Bench.racesPerVCPU(meanRaceTickMs: 1000.0 / 30 / 25) - 25) < 1e-9)
    }

    /// #27: the gate fails a p99 over 5 ms or fewer than 20 races per vCPU, and passes at the limits.
    @Test func gateHoldsEachScenarioToTheBudget() {
        func result(p99: Double, racesPerVCPU: Double) -> ScenarioResult {
            var result = ScenarioResult(name: "s", boats: 16, tick: TickStats(samples: [p99]), races: 20, raceTicks: 1,
                                        meanRaceTickMs: 1)
            result.racesPerVCPU = racesPerVCPU
            return result
        }
        let budget = Thresholds.budget
        #expect(budget == Thresholds(maxP99Ms: 5, minRacesPerVCPU: 20))
        #expect(budget.failures(of: result(p99: 5, racesPerVCPU: 20)).isEmpty)
        #expect(budget.failures(of: result(p99: 1, racesPerVCPU: 100)).isEmpty)
        #expect(budget.failures(of: result(p99: 5.001, racesPerVCPU: 100)).count == 1)
        #expect(budget.failures(of: result(p99: 1, racesPerVCPU: 19.9)).count == 1)
        #expect(budget.failures(of: result(p99: 6, racesPerVCPU: 10)).count == 2)
        #expect(budget.failures(of: [result(p99: 1, racesPerVCPU: 100), result(p99: 6, racesPerVCPU: 100)]).count == 1)
        #expect(!BenchReport(results: [result(p99: 6, racesPerVCPU: 100)], thresholds: budget, gated: true).passed)
    }

    @Test func optionsParseFlagsAndDefaultToTheBudget() throws {
        let defaults = try BenchOptions(arguments: [])
        #expect(defaults.thresholds == .budget)
        #expect(defaults.races == 20)
        #expect(!defaults.gate)

        let options = try BenchOptions(arguments: ["--gate", "--ticks", "30", "--races", "2", "--max-p99-ms", "0.5",
                                                   "--min-races-per-vcpu", "40", "--json", "-", "--scenario", "a"])
        #expect(options.gate)
        #expect(options.ticks == 30)
        #expect(options.races == 2)
        #expect(options.thresholds == Thresholds(maxP99Ms: 0.5, minRacesPerVCPU: 40))
        #expect(options.jsonPath == "-")
        #expect(options.scenarioNames == ["a"])

        #expect(throws: BenchError.self) { try BenchOptions(arguments: ["--ticks"]) }
        #expect(throws: BenchError.self) { try BenchOptions(arguments: ["--ticks", "many"]) }
        #expect(throws: BenchError.self) { try BenchOptions(arguments: ["--races", "0"]) }
        #expect(throws: BenchError.self) { try BenchOptions(arguments: ["--fast"]) }
    }

    // MARK: - Scenarios and the tick loop

    /// #69: the bench starts with 16 bot boats at the current brains; the list is data for #105.
    @Test func bundledScenariosSailSixteenBots() throws {
        let scenarios = try Scenario.bundled()
        #expect(!scenarios.isEmpty)
        #expect(Set(scenarios.map(\.name)).count == scenarios.count)
        let fleet = try #require(scenarios.first)
        #expect(fleet.boats == 16)
        let race = try fleet.race()
        #expect(race.boats.count == 16)
        #expect(race.setup.seats.allSatisfy { $0 == .bot })
    }

    @Test func runTimesTicksAndEncodesSnapshots() throws {
        let scenario = Scenario(name: "short", raceSeed: 1, windSeed: 2, startSequenceTicks: 300, warmupTicks: 3, ticks: 12)
        let result = try Bench.run(scenario, races: 3)
        #expect(result.tick.ticks == 12)
        #expect(result.races == 3)
        #expect(result.raceTicks == 36)
        #expect(result.tick.p50Ms <= result.tick.p99Ms)
        #expect(result.tick.p99Ms <= result.tick.maxMs)
        #expect(result.meanRaceTickMs > 0)
        #expect(result.racesPerVCPU > 0)
        // A snapshot every third tick, one frame per seat.
        #expect(result.encodedBytesPerRaceTick > 0)
    }

    // MARK: - The executable

    #if os(macOS) || os(Linux)
    /// #69 acceptance: the bench prints p99 and races/vCPU.
    @Test func reportPrintsP99AndRacesPerVCPU() throws {
        let run = try bench(["--ticks", "30", "--races", "2"])
        #expect(run.status == 0)
        #expect(run.stdout.contains("p99 "))
        #expect(run.stdout.contains("races/vCPU "))
        #expect(run.stdout.contains("fleet-16-bots: 16 boats"))
    }

    /// #69 acceptance: `--gate` exits non-zero with a p99 threshold below the measured p99.
    @Test func gateFailsWithThresholdBelowMeasuredP99() throws {
        let run = try bench(["--gate", "--ticks", "30", "--races", "2", "--thresholds", try fixture(maxP99Ms: 0.000_001)])
        #expect(run.status == 1)
        #expect(run.stdout.contains("gate: FAIL"))
    }

    /// #69 acceptance: `--gate` exits zero with a p99 threshold above the measured p99.
    @Test func gatePassesWithThresholdAboveMeasuredP99() throws {
        let run = try bench(["--gate", "--ticks", "30", "--races", "2", "--thresholds", try fixture(maxP99Ms: 1_000_000)])
        #expect(run.status == 0)
        #expect(run.stdout.contains("gate: pass"))
    }

    /// #69: the numbers are exported as JSON for #105.
    @Test func jsonReportCarriesTheNumbers() throws {
        let run = try bench(["--ticks", "30", "--races", "2", "--json", "-"])
        #expect(run.status == 0)
        let report = try JSONDecoder().decode(BenchReport.self, from: Data(run.stdout.utf8))
        let fleet = try #require(report.scenarios.first)
        #expect(fleet.boats == 16)
        #expect(fleet.tick.ticks == 30)
        #expect(fleet.races == 2)
        #expect(fleet.racesPerVCPU > 0)
        #expect(report.thresholds == .budget)
        #expect(!report.gated)
    }

    @Test func unknownArgumentIsAUsageError() throws {
        let run = try bench(["--nope"])
        #expect(run.status == 2)
    }
    #endif
}

#if os(macOS) || os(Linux)
private final class BundleMarker {}

/// A thresholds fixture: `maxP99Ms` and no races/vCPU floor, so only the p99 decides the gate.
private func fixture(maxP99Ms: Double) throws -> String {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("bench-thresholds-\(UUID().uuidString).json")
    try JSONEncoder().encode(Thresholds(maxP99Ms: maxP99Ms, minRacesPerVCPU: 0)).write(to: file)
    return file.path
}

/// Runs the built `regatta-bench` with `arguments` in its own process.
private func bench(_ arguments: [String]) throws -> (status: Int32, stdout: String) {
    let executable = try #require(benchExecutable(), "regatta-bench not found next to the test bundle")
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return (process.terminationStatus, printed)
}

/// SwiftPM builds `regatta-bench` into the same products directory as the test bundle.
private func benchExecutable() -> URL? {
    var directories: [URL] = []
    for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
        directories.append(bundle.bundleURL.deletingLastPathComponent())
    }
    let marker = Bundle(for: BundleMarker.self).bundleURL
    directories.append(marker.pathExtension == "xctest" ? marker.deletingLastPathComponent() : marker)
    directories.append(Bundle.main.bundleURL)
    directories.append(URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent())
    return directories.lazy
        .map { $0.appendingPathComponent("regatta-bench") }
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }
}
#endif
