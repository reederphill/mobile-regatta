import Foundation

/// What one tier must meet over a run (#19): "the share of bots that finish; time stuck in irons;
/// contact with marks; the share of contacts ending in fouls (near zero at National); getting stuck
/// against the edge of the race area".
public struct TierLimits: Codable, Hashable, Sendable {
    public var minFinishShare: Double
    public var maxMeanIronsSeconds: Double
    public var maxMeanMarkContacts: Double
    public var maxContactsToFoulsShare: Double
    public var maxMeanEdgeSeconds: Double

    public init(minFinishShare: Double, maxMeanIronsSeconds: Double, maxMeanMarkContacts: Double,
                maxContactsToFoulsShare: Double, maxMeanEdgeSeconds: Double) {
        self.minFinishShare = minFinishShare
        self.maxMeanIronsSeconds = maxMeanIronsSeconds
        self.maxMeanMarkContacts = maxMeanMarkContacts
        self.maxContactsToFoulsShare = maxContactsToFoulsShare
        self.maxMeanEdgeSeconds = maxMeanEdgeSeconds
    }

    /// Why `summary` misses these limits, each line starting with `tier`.
    func breaches(_ tier: String, _ summary: TierSummary) -> [String] {
        var breaches: [String] = []
        if summary.finishShare < minFinishShare {
            breaches.append("\(tier): finish share \(fixed(summary.finishShare)) < \(fixed(minFinishShare))")
        }
        if summary.meanIronsSeconds > maxMeanIronsSeconds {
            breaches.append("\(tier): irons \(fixed(summary.meanIronsSeconds)) s/boat > \(fixed(maxMeanIronsSeconds))")
        }
        if summary.meanMarkContacts > maxMeanMarkContacts {
            breaches.append("\(tier): mark contacts \(fixed(summary.meanMarkContacts))/boat > \(fixed(maxMeanMarkContacts))")
        }
        if summary.contactsToFoulsShare > maxContactsToFoulsShare {
            breaches.append("\(tier): contacts to fouls \(fixed(summary.contactsToFoulsShare)) > \(fixed(maxContactsToFoulsShare))")
        }
        if summary.meanEdgeSeconds > maxMeanEdgeSeconds {
            breaches.append("\(tier): edge \(fixed(summary.meanEdgeSeconds)) s/boat > \(fixed(maxMeanEdgeSeconds))")
        }
        return breaches
    }
}

/// The suite's gate (#19, #27): limits per tier, keyed by `BotTier.rawValue`, and the worst race's p99
/// tick. A tier with no limits isn't gated. "The exact limits are set at build time" (#19): the bundled
/// `thresholds.json` starts loose, and tightens as the brains (#102) do.
public struct BotThresholds: Codable, Hashable, Sendable {
    public var tiers: [String: TierLimits]
    public var maxP99TickMs: Double

    public init(tiers: [String: TierLimits], maxP99TickMs: Double) {
        self.tiers = tiers
        self.maxP99TickMs = maxP99TickMs
    }

    /// Why a run with these tier summaries and timings misses the thresholds; empty when it meets them.
    public func breaches(tiers summaries: [String: TierSummary], timings: BotSuiteReport.RunTimings) -> [String] {
        var breaches = BotTier.allCases.flatMap { tier -> [String] in
            guard let summary = summaries[tier.rawValue], let limits = tiers[tier.rawValue] else { return [] }
            return limits.breaches(tier.rawValue, summary)
        }
        if timings.maxP99Ms > maxP99TickMs {
            breaches.append("tick: worst p99 \(fixed(timings.maxP99Ms, 3)) ms > \(fixed(maxP99TickMs, 3))")
        }
        return breaches
    }

    public static func load(from url: URL) throws -> BotThresholds {
        let thresholds = try JSONDecoder().decode(BotThresholds.self, from: Data(contentsOf: url))
        let unknown = thresholds.tiers.keys.filter { BotTier(rawValue: $0) == nil }.sorted()
        guard unknown.isEmpty else { throw BotSuiteError.usage("thresholds: unknown tier \(unknown.joined(separator: ", "))") }
        return thresholds
    }

    /// The bundled thresholds (`thresholds.json`).
    public static func bundled() throws -> BotThresholds {
        guard let url = Bundle.module.url(forResource: "thresholds", withExtension: "json") else {
            throw BotSuiteError.usage("thresholds.json is not bundled")
        }
        return try load(from: url)
    }
}
