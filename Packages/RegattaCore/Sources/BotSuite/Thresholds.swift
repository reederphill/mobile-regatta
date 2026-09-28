import Foundation
import RegattaBots

/// What one tier must meet over a run (#19): "the share of bots that finish; time stuck in irons;
/// contact with marks; the share of contacts ending in fouls (near zero at National); getting stuck
/// against the edge of the race area". Since every contact ends in a call, the fouls are gated as a share of
/// encounters too (#101, the owner, 2026-09-27: `maxEncountersToFoulsShare`).
public struct TierLimits: Codable, Hashable, Sendable {
    public var minFinishShare: Double
    public var maxMeanIronsSeconds: Double
    public var maxMeanMarkContacts: Double
    public var maxContactsToFoulsShare: Double
    public var maxMeanEdgeSeconds: Double
    /// The most of the tier's encounters that may end in a rule call (`TierSummary.encountersToFoulsShare`, #101);
    /// nil gates none, as in a thresholds file from before #101.
    public var maxEncountersToFoulsShare: Double?

    public init(minFinishShare: Double, maxMeanIronsSeconds: Double, maxMeanMarkContacts: Double,
                maxContactsToFoulsShare: Double, maxMeanEdgeSeconds: Double, maxEncountersToFoulsShare: Double? = nil) {
        self.minFinishShare = minFinishShare
        self.maxMeanIronsSeconds = maxMeanIronsSeconds
        self.maxMeanMarkContacts = maxMeanMarkContacts
        self.maxContactsToFoulsShare = maxContactsToFoulsShare
        self.maxMeanEdgeSeconds = maxMeanEdgeSeconds
        self.maxEncountersToFoulsShare = maxEncountersToFoulsShare
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
        if let maximum = maxEncountersToFoulsShare, summary.encountersToFoulsShare > maximum {
            breaches.append("\(tier): encounters to fouls \(fixed(summary.encountersToFoulsShare, 3)) > \(fixed(maximum, 3))")
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

/// What the start must show over a run (#99), over its all-National live ten-boat fleets (`StartSummary`). Every
/// limit is optional; they gate only a run that sailed such a fleet.
public struct StartLimits: Codable, Hashable, Sendable {
    /// The most of their seats that may be OCS at the gun.
    public var maxOCSShare: Double?
    /// The least of them that must start within `StartSummary.onTimeSeconds` of the gun.
    public var minOnTimeShare: Double?
    /// The most seconds in irons before the gun per seat, on average (`SeatMetrics.preGunIronsSeconds`).
    public var maxMeanPreGunIronsSeconds: Double?
    /// The least share of their pin-style seats from committee slots that must start in the line's pin third.
    public var minPinThirdShare: Double?

    public init(maxOCSShare: Double? = nil, minOnTimeShare: Double? = nil, maxMeanPreGunIronsSeconds: Double? = nil,
                minPinThirdShare: Double? = nil) {
        self.maxOCSShare = maxOCSShare
        self.minOnTimeShare = minOnTimeShare
        self.maxMeanPreGunIronsSeconds = maxMeanPreGunIronsSeconds
        self.minPinThirdShare = minPinThirdShare
    }

    /// Why `summary` misses these limits, each line starting with `start`; none without a summary, and no
    /// pin-third breach without a pin-style seat from a committee slot.
    func breaches(_ summary: StartSummary?) -> [String] {
        guard let summary else { return [] }
        var breaches: [String] = []
        if let maximum = maxOCSShare, summary.ocsShare > maximum {
            breaches.append("start: OCS \(fixed(summary.ocsShare)) > \(fixed(maximum))")
        }
        if let minimum = minOnTimeShare, summary.onTimeShare < minimum {
            breaches.append("start: on time \(fixed(summary.onTimeShare)) < \(fixed(minimum))")
        }
        if let maximum = maxMeanPreGunIronsSeconds, summary.meanPreGunIronsSeconds > maximum {
            breaches.append("start: pre-gun irons \(fixed(summary.meanPreGunIronsSeconds)) s/boat > \(fixed(maximum))")
        }
        if let minimum = minPinThirdShare, let share = summary.pinThirdShare, share < minimum {
            breaches.append("start: pin third \(fixed(share)) < \(fixed(minimum))")
        }
        return breaches
    }
}

/// What navigation must show over a run (#100), over its all-National live fleets (`NavigationSummary`): #100's
/// acceptance, in the units the summary counts. Every limit is optional; they gate only a run that sailed such a fleet.
public struct NavigationLimits: Codable, Hashable, Sendable {
    /// The least share of their seats that must finish.
    public var minFinishShare: Double?
    /// The most disqualifications for a missed penalty deadline, all seats together.
    public var maxDSQMissedPenalty: Int?
    /// The most of their time on the water they may spend at the race area's edge.
    public var maxEdgeShare: Double?
    /// The most mark contacts per boat per race.
    public var maxMarkContactsPerBoat: Double?

    public init(minFinishShare: Double? = nil, maxDSQMissedPenalty: Int? = nil, maxEdgeShare: Double? = nil,
                maxMarkContactsPerBoat: Double? = nil) {
        self.minFinishShare = minFinishShare
        self.maxDSQMissedPenalty = maxDSQMissedPenalty
        self.maxEdgeShare = maxEdgeShare
        self.maxMarkContactsPerBoat = maxMarkContactsPerBoat
    }

    /// Why `summary` misses these limits, each line starting with `navigation`; none without a summary.
    func breaches(_ summary: NavigationSummary?) -> [String] {
        guard let summary else { return [] }
        var breaches: [String] = []
        if let minimum = minFinishShare, summary.finishShare < minimum {
            breaches.append("navigation: finish share \(fixed(summary.finishShare, 3)) < \(fixed(minimum, 3))")
        }
        if let maximum = maxDSQMissedPenalty, summary.dsqMissedPenalty > maximum {
            breaches.append("navigation: dsq for a missed penalty \(summary.dsqMissedPenalty) > \(maximum)")
        }
        if let maximum = maxEdgeShare, summary.edgeShare > maximum {
            breaches.append("navigation: edge \(fixed(summary.edgeShare, 4)) of the time > \(fixed(maximum, 4))")
        }
        if let maximum = maxMarkContactsPerBoat, summary.markContactsPerBoat > maximum {
            breaches.append("navigation: mark contacts \(fixed(summary.markContactsPerBoat, 3))/boat/race > \(fixed(maximum, 3))")
        }
        return breaches
    }
}

/// The suite's gate (#19, #27): limits per tier, keyed by `BotTier.rawValue`, per scripted profile, keyed by
/// `BotProfile.rawValue` (#231, #238), the start's (#99), navigation's (#100), and the worst race's p99 tick. A tier or
/// profile with no limits isn't gated, and a profile's, the start's or navigation's limits gate only a run that sailed it. "The exact limits are
/// set at build time" (#19): the bundled `thresholds.json` starts loose, and tightens as the brains (#102) do.
public struct BotThresholds: Codable, Hashable, Sendable {
    public var tiers: [String: TierLimits]
    /// Empty when a thresholds file has none.
    public var profiles: [String: ProfileLimits]
    /// The start's limits (#99); nil when a thresholds file has none.
    public var start: StartLimits?
    /// Navigation's limits (#100); nil when a thresholds file has none.
    public var navigation: NavigationLimits?
    public var maxP99TickMs: Double

    public init(tiers: [String: TierLimits], profiles: [String: ProfileLimits] = [:], start: StartLimits? = nil,
                navigation: NavigationLimits? = nil, maxP99TickMs: Double) {
        self.tiers = tiers
        self.profiles = profiles
        self.start = start
        self.navigation = navigation
        self.maxP99TickMs = maxP99TickMs
    }

    private enum CodingKeys: String, CodingKey {
        case tiers, profiles, start, navigation, maxP99TickMs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(tiers: try c.decode([String: TierLimits].self, forKey: .tiers),
                  profiles: try c.decodeIfPresent([String: ProfileLimits].self, forKey: .profiles) ?? [:],
                  start: try c.decodeIfPresent(StartLimits.self, forKey: .start),
                  navigation: try c.decodeIfPresent(NavigationLimits.self, forKey: .navigation),
                  maxP99TickMs: try c.decode(Double.self, forKey: .maxP99TickMs))
    }

    /// Why a run with these tier summaries, timings, skill gap, fun pass, start and navigation misses the thresholds;
    /// empty when it meets them.
    public func breaches(tiers summaries: [String: TierSummary], timings: BotSuiteReport.RunTimings,
                         skillGap: SkillGapSummary? = nil, funPass: FunPassSummary? = nil,
                         start: StartSummary? = nil, navigation: NavigationSummary? = nil) -> [String] {
        var breaches = BotTier.allCases.flatMap { tier -> [String] in
            guard let summary = summaries[tier.rawValue], let limits = tiers[tier.rawValue] else { return [] }
            return limits.breaches(tier.rawValue, summary)
        }
        for profile in BotProfile.allCases {
            breaches += profiles[profile.rawValue]?.breaches(profile.rawValue, skillGap: skillGap, funPass: funPass) ?? []
        }
        breaches += self.start?.breaches(start) ?? []
        breaches += self.navigation?.breaches(navigation) ?? []
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
