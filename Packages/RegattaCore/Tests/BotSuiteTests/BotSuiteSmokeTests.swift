import BotSuite
import Foundation
import Testing

@Suite struct BotSuiteSmokeTests {
    /// #97 acceptance: the smoke run, three seeds of ten bots over one lap, costs `swift test` under 30 s
    /// and meets the bundled tier limits. The cost is the CPU time of the thread sailing the races, which
    /// holds however many other suites share the machine; wall clock under a parallel `swift test` does
    /// not. The tick limit is for a release build on its own (#27, `regatta-bench`), so it's lifted here.
    @Test func threeSeedsTenBoatsUnderThirtySeconds() throws {
        let matrix = BotMatrix(seeds: [1, 2, 3], fleetSizes: [10], tierMixes: [.mixed], laps: 1)
        var thresholds = try BotThresholds.bundled()
        thresholds.maxP99TickMs = .greatestFiniteMagnitude
        let report = try BotSuite.run(matrix, thresholds: thresholds)
        let cpuSeconds = report.races.reduce(0) { $0 + $1.timings.cpuSeconds }

        #expect(cpuSeconds < 30, "smoke took \(cpuSeconds) s of CPU")
        #expect(report.races.count == 3)
        #expect(report.races.allSatisfy { !$0.capped && $0.seats.count == 10 })
        #expect(report.passed, "\(report.breaches)")
    }
}
