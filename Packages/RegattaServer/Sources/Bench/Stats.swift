/// Tick times over one race (#69), in milliseconds.
public struct TickStats: Codable, Hashable, Sendable {
    public var ticks: Int
    public var p50Ms: Double
    public var p99Ms: Double
    public var maxMs: Double

    /// Stats of `samples`, which must not be empty.
    public init(samples: [Double]) {
        precondition(!samples.isEmpty, "no tick samples")
        let sorted = samples.sorted()
        ticks = sorted.count
        p50Ms = TickStats.percentile(50, ofSorted: sorted)
        p99Ms = TickStats.percentile(99, ofSorted: sorted)
        maxMs = sorted[sorted.count - 1]
    }

    /// The nearest-rank `p`th percentile of `sorted` (ascending, not empty): the smallest sample with at
    /// least `p`% of the samples at or below it.
    public static func percentile(_ p: Double, ofSorted sorted: [Double]) -> Double {
        precondition(!sorted.isEmpty, "no samples")
        let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }
}
