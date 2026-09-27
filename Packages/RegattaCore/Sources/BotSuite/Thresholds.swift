import Foundation
import RegattaBots

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

/// What a scripted profile must show over a run (#231), keyed in the thresholds by `BotProfile.rawValue`.
/// Every limit is optional: a profile's tickets (#238, #234, #105) add theirs as keys here.
public struct ProfileLimits: Codable, Hashable, Sendable {
    /// The tactician's least mean win share over the baseline, across the races with both (ADR 0007).
    public var minTacticianWinShare: Double?
    /// The tactician's least median gain over the baseline per beat, hull lengths.
    public var minTacticianGainLengthsPerBeat: Double?
    /// The tactician's least tacks per beat in the fun-pass scenario (#221: "the tactician averages ≥ 4
    /// tacks per beat"), over the beats her seats completed.
    public var minTacticianTacksPerBeat: Double?
    /// The least share of the fun-pass races with both in which the tactician beats the blip-tacker (#221).
    public var minTacticianBeatsBlipTackerShare: Double?

    public init(minTacticianWinShare: Double? = nil, minTacticianGainLengthsPerBeat: Double? = nil,
                minTacticianTacksPerBeat: Double? = nil, minTacticianBeatsBlipTackerShare: Double? = nil) {
        self.minTacticianWinShare = minTacticianWinShare
        self.minTacticianGainLengthsPerBeat = minTacticianGainLengthsPerBeat
        self.minTacticianTacksPerBeat = minTacticianTacksPerBeat
        self.minTacticianBeatsBlipTackerShare = minTacticianBeatsBlipTackerShare
    }

    /// Why `skillGap` and `funPass` miss these limits, each line starting with `profile`. A limit gates only
    /// what the run sailed: none without a skill gap or a fun pass, and none on a fun pass without its numbers.
    func breaches(_ profile: String, skillGap: SkillGapSummary?, funPass: FunPassSummary? = nil) -> [String] {
        var breaches: [String] = []
        if let gap = skillGap {
            if let minimum = minTacticianWinShare, gap.tacticianWinShare < minimum {
                breaches.append("\(profile): win share \(fixed(gap.tacticianWinShare)) < \(fixed(minimum))")
            }
            if let minimum = minTacticianGainLengthsPerBeat, gap.medianGainLengthsPerBeat < minimum {
                breaches.append("\(profile): gain \(fixed(gap.medianGainLengthsPerBeat)) lengths/beat < \(fixed(minimum))")
            }
        }
        if let minimum = minTacticianTacksPerBeat, let tacks = funPass?.tacksPerBeat[BotProfile.tactician.rawValue],
           tacks < minimum {
            breaches.append("\(profile): tacks \(fixed(tacks))/beat < \(fixed(minimum))")
        }
        if let minimum = minTacticianBeatsBlipTackerShare, let share = funPass?.tacticianBeatsBlipTackerShare,
           share < minimum {
            breaches.append("\(profile): beat the blip-tacker \(fixed(share)) < \(fixed(minimum))")
        }
        return breaches
    }
}

/// The suite's gate (#19, #27): limits per tier, keyed by `BotTier.rawValue`, per scripted profile, keyed by
/// `BotProfile.rawValue` (#231, #238), and the worst race's p99 tick. A tier or profile with no limits isn't
/// gated, and a profile's limits gate only a run that sailed it. "The exact limits are set at build time" (#19):
/// the bundled `thresholds.json` starts loose, and tightens as the brains (#102) do.
public struct BotThresholds: Codable, Hashable, Sendable {
    public var tiers: [String: TierLimits]
    /// Empty when a thresholds file has none.
    public var profiles: [String: ProfileLimits]
    public var maxP99TickMs: Double

    public init(tiers: [String: TierLimits], profiles: [String: ProfileLimits] = [:], maxP99TickMs: Double) {
        self.tiers = tiers
        self.profiles = profiles
        self.maxP99TickMs = maxP99TickMs
    }

    private enum CodingKeys: String, CodingKey {
        case tiers, profiles, maxP99TickMs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(tiers: try c.decode([String: TierLimits].self, forKey: .tiers),
                  profiles: try c.decodeIfPresent([String: ProfileLimits].self, forKey: .profiles) ?? [:],
                  maxP99TickMs: try c.decode(Double.self, forKey: .maxP99TickMs))
    }

    /// Why a run with these tier summaries, timings, skill gap and fun pass misses the thresholds; empty when
    /// it meets them.
    public func breaches(tiers summaries: [String: TierSummary], timings: BotSuiteReport.RunTimings,
                         skillGap: SkillGapSummary? = nil, funPass: FunPassSummary? = nil) -> [String] {
        var breaches = BotTier.allCases.flatMap { tier -> [String] in
            guard let summary = summaries[tier.rawValue], let limits = tiers[tier.rawValue] else { return [] }
            return limits.breaches(tier.rawValue, summary)
        }
        for profile in BotProfile.allCases {
            breaches += profiles[profile.rawValue]?.breaches(profile.rawValue, skillGap: skillGap, funPass: funPass) ?? []
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
        let unknownProfiles = thresholds.profiles.keys.filter { BotProfile(rawValue: $0) == nil }.sorted()
        guard unknownProfiles.isEmpty else {
            throw BotSuiteError.usage("thresholds: unknown profile \(unknownProfiles.joined(separator: ", "))")
        }
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
