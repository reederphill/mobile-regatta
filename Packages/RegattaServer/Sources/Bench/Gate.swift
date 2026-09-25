/// The server budget (#27) the gate holds each scenario to.
public struct Thresholds: Codable, Hashable, Sendable {
    /// A scenario fails when its p99 tick is above this.
    public var maxP99Ms: Double
    /// A scenario fails when fewer races than this fit on one vCPU.
    public var minRacesPerVCPU: Double

    /// #27: p99 tick under 5 ms, at least 20 races per vCPU.
    public static let budget = Thresholds(maxP99Ms: 5, minRacesPerVCPU: 20)

    public init(maxP99Ms: Double, minRacesPerVCPU: Double) {
        self.maxP99Ms = maxP99Ms
        self.minRacesPerVCPU = minRacesPerVCPU
    }

    /// Why `result` misses these thresholds; empty when it meets them.
    public func failures(of result: ScenarioResult) -> [String] {
        var failures: [String] = []
        if result.tick.p99Ms > maxP99Ms {
            failures.append("\(result.name): p99 \(ms(result.tick.p99Ms)) > \(ms(maxP99Ms))")
        }
        if result.racesPerVCPU < minRacesPerVCPU {
            failures.append("\(result.name): races/vCPU \(fixed(result.racesPerVCPU, 1)) < \(fixed(minRacesPerVCPU, 1))")
        }
        return failures
    }

    /// Why `results` miss these thresholds; empty when every one meets them.
    public func failures(of results: [ScenarioResult]) -> [String] {
        results.flatMap { failures(of: $0) }
    }
}
