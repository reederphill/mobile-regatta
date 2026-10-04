import Foundation
import RegattaBots

/// What one tier must meet over a run (#19): "the share of bots that finish; time stuck in irons;
/// contact with marks; the share of contacts ending in fouls (near zero at National); getting stuck
/// against the edge of the race area". Since every contact ends in a call, the fouls are gated as a share of
/// encounters too, over the all-National live fleets rather than per tier (#101: `ConductLimits`).
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
    /// The tactician's least median gain over the baseline per run, hull lengths (#105: downwind, she gybes on headers,
    /// stays in the pressure and out of the shadow of the boats behind her).
    public var minTacticianGainLengthsPerRun: Double?
    /// The tactician's least mean lead over the baseline at their first cross after the gun, hull lengths (#105: she
    /// starts at the end the line's bias favours, the baseline at her style's spot).
    public var minTacticianStartGainLengths: Double?
    /// The least share of the races with both in which the tactician at Club-level execution beats the executor (#222,
    /// #105: "execution never beats tactics").
    public var minTacticsBeatsExecutionShare: Double?

    public init(minTacticianWinShare: Double? = nil, minTacticianGainLengthsPerBeat: Double? = nil,
                minTacticianTacksPerBeat: Double? = nil, minTacticianBeatsBlipTackerShare: Double? = nil,
                minTacticianGainLengthsPerRun: Double? = nil, minTacticianStartGainLengths: Double? = nil,
                minTacticsBeatsExecutionShare: Double? = nil) {
        self.minTacticianWinShare = minTacticianWinShare
        self.minTacticianGainLengthsPerBeat = minTacticianGainLengthsPerBeat
        self.minTacticianTacksPerBeat = minTacticianTacksPerBeat
        self.minTacticianBeatsBlipTackerShare = minTacticianBeatsBlipTackerShare
        self.minTacticianGainLengthsPerRun = minTacticianGainLengthsPerRun
        self.minTacticianStartGainLengths = minTacticianStartGainLengths
        self.minTacticsBeatsExecutionShare = minTacticsBeatsExecutionShare
    }

    /// Why `skillGap`, `funPass` and `execution` miss these limits, each line starting with `profile`. A limit gates only
    /// what the run sailed: none without a skill gap, a fun pass or an execution race, and none on a fun pass without its
    /// numbers, nor on a skill gap without runs or a start lead.
    func breaches(_ profile: String, skillGap: SkillGapSummary?, funPass: FunPassSummary? = nil,
                  execution: ExecutionSummary? = nil) -> [String] {
        var breaches: [String] = []
        if let gap = skillGap {
            if let minimum = minTacticianWinShare, gap.tacticianWinShare < minimum {
                breaches.append("\(profile): win share \(fixed(gap.tacticianWinShare)) < \(fixed(minimum))")
            }
            if let minimum = minTacticianGainLengthsPerBeat, gap.medianGainLengthsPerBeat < minimum {
                breaches.append("\(profile): gain \(fixed(gap.medianGainLengthsPerBeat)) lengths/beat < \(fixed(minimum))")
            }
            if let minimum = minTacticianGainLengthsPerRun, gap.runs > 0, gap.medianGainLengthsPerRun < minimum {
                breaches.append("\(profile): gain \(fixed(gap.medianGainLengthsPerRun)) lengths/run < \(fixed(minimum))")
            }
            if let minimum = minTacticianStartGainLengths, let lead = gap.meanStartGainLengths, lead < minimum {
                breaches.append("\(profile): start \(fixed(lead)) lengths ahead at the first cross < \(fixed(minimum))")
            }
        }
        if let minimum = minTacticsBeatsExecutionShare, let execution, execution.tacticsBeatsExecutionShare < minimum {
            breaches.append("\(profile): beat the executor \(fixed(execution.tacticsBeatsExecutionShare)) < \(fixed(minimum))")
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

/// What conduct under the rules must show over a run (#101), over the same all-National live fleets as navigation
/// (`ConductSummary`): #19's "the share of contacts ending in fouls (near zero at National)", taken as a share of
/// encounters since every contact ends in a call (the owner, 2026-09-27). Gated on those fleets alone, as navigation
/// is, not in a tier's limits (the owner, 2026-09-28): a run of a few mixed-tier races, like the smoke, is too small to
/// decide it. Every limit is optional; they gate only a run that sailed such a fleet.
public struct ConductLimits: Codable, Hashable, Sendable {
    /// The most of their encounters that may end in a rule call.
    public var maxEncountersToFoulsShare: Double?

    public init(maxEncountersToFoulsShare: Double? = nil) {
        self.maxEncountersToFoulsShare = maxEncountersToFoulsShare
    }

    /// Why `summary` misses these limits, each line starting with `conduct`; none without a summary.
    func breaches(_ summary: ConductSummary?) -> [String] {
        guard let summary else { return [] }
        var breaches: [String] = []
        if let maximum = maxEncountersToFoulsShare, summary.encountersToFoulsShare > maximum {
            breaches.append("conduct: encounters to fouls \(fixed(summary.encountersToFoulsShare, 3)) > \(fixed(maximum, 3))")
        }
        return breaches
    }
}

/// What close encounters must show over a run (#234), over the same all-National live fleets as conduct
/// (`CloseEncounterSummary`): #223's floor, "~8 per race (placeholder)", for a mid-fleet boat. Optional; it gates only a
/// run that sailed such a fleet.
public struct EncounterLimits: Codable, Hashable, Sendable {
    /// The fewest close encounters a mid-fleet boat may meet per race, on average.
    public var minCloseEncountersPerRace: Double?

    public init(minCloseEncountersPerRace: Double? = nil) {
        self.minCloseEncountersPerRace = minCloseEncountersPerRace
    }

    /// Why `summary` misses these limits, each line starting with `encounters`; none without a summary.
    func breaches(_ summary: CloseEncounterSummary?) -> [String] {
        guard let summary, let minimum = minCloseEncountersPerRace, summary.closeEncountersPerRace < minimum else { return [] }
        return ["encounters: close encounters \(fixed(summary.closeEncountersPerRace)) per mid-fleet boat per race < \(fixed(minimum))"]
    }
}

/// The 16.1 watchdog's limit (#228, #105) over its races (`WatchdogSummary`). Optional; it gates only a run that sailed
/// them. A new block: the pinned blocks (`ConductLimits` and the others) are compared whole in their tests.
public struct WatchdogLimits: Codable, Hashable, Sendable {
    /// The most rule 16.1 calls whose right-of-way boat held her rudder centred throughout the escape window.
    public var maxCentredRudder161Calls: Int?

    public init(maxCentredRudder161Calls: Int? = nil) {
        self.maxCentredRudder161Calls = maxCentredRudder161Calls
    }

    func breaches(_ summary: WatchdogSummary?) -> [String] {
        guard let summary, let maximum = maxCentredRudder161Calls, summary.centredRudder161Calls > maximum else { return [] }
        return ["watchdog: centred-rudder 16.1 calls \(summary.centredRudder161Calls) > \(maximum)"]
    }
}

/// The rival pace band's limit (#235, #105) over the rivals mix (`RivalPaceSummary`). Optional; it gates only a run that
/// sailed it.
public struct RivalLimits: Codable, Hashable, Sendable {
    /// The most places the player stand-in's mean place and her rivals' may be apart, at any skill.
    public var maxMeanPlaceGap: Double?

    public init(maxMeanPlaceGap: Double? = nil) {
        self.maxMeanPlaceGap = maxMeanPlaceGap
    }

    func breaches(_ summary: RivalPaceSummary?) -> [String] {
        guard let summary, let maximum = maxMeanPlaceGap, summary.maxMeanPlaceGap > maximum else { return [] }
        return ["rivals: mean place gap \(fixed(summary.maxMeanPlaceGap)) > \(fixed(maximum))"]
    }
}

/// Rank stability's limit (#105) over the rank-stability mix (`RankSummary`). Optional; it gates only a run that sailed
/// it. The luck floor (`RankSummary.sameSkillPlaceGap`) is reported, never gated.
public struct RankLimits: Codable, Hashable, Sendable {
    /// The least mean Spearman correlation of skill and finishing order.
    public var minSkillRankCorrelation: Double?

    public init(minSkillRankCorrelation: Double? = nil) {
        self.minSkillRankCorrelation = minSkillRankCorrelation
    }

    func breaches(_ summary: RankSummary?) -> [String] {
        guard let summary, summary.correlatedRaces > 0, let minimum = minSkillRankCorrelation,
              summary.meanSkillRankCorrelation < minimum else { return [] }
        return ["rank: skill vs finishing order \(fixed(summary.meanSkillRankCorrelation)) < \(fixed(minimum))"]
    }
}

/// The suite's gate (#19, #27): limits per tier, keyed by `BotTier.rawValue`, per scripted profile, keyed by
/// `BotProfile.rawValue` (#231, #238), the start's (#99), navigation's (#100), conduct's (#101), and the worst race's p99
/// tick. A tier or profile with no limits isn't gated, and a profile's, the start's, navigation's or conduct's limits gate
/// only a run that sailed it. "The exact limits are set at build time" (#19): the bundled `thresholds.json` starts
/// loose, and tightens as the brains (#102) do.
public struct BotThresholds: Codable, Hashable, Sendable {
    public var tiers: [String: TierLimits]
    /// Empty when a thresholds file has none.
    public var profiles: [String: ProfileLimits]
    /// The start's limits (#99); nil when a thresholds file has none.
    public var start: StartLimits?
    /// Navigation's limits (#100); nil when a thresholds file has none.
    public var navigation: NavigationLimits?
    /// Conduct's limits (#101); nil when a thresholds file has none.
    public var conduct: ConductLimits?
    /// Close encounters' limits (#234); nil when a thresholds file has none.
    public var encounters: EncounterLimits?
    /// The 16.1 watchdog's (#105); nil when a thresholds file has none.
    public var watchdog: WatchdogLimits?
    /// The rival pace band's (#105); nil when a thresholds file has none.
    public var rivals: RivalLimits?
    /// Rank stability's (#105); nil when a thresholds file has none.
    public var rank: RankLimits?
    /// The worst race's p99 tick, milliseconds: #27's budget, "p99 tick under 5 ms on one shared vCPU". On a CI runner
    /// the times are noisy; the authoritative budget is `regatta-bench`'s on the reference runner (#69).
    public var maxP99TickMs: Double
    /// The keys whose values are placeholders until #389 sets them (#105), as JSON paths (`profiles.tactician.
    /// minTacticianWinShare`); the report counts them. Empty when a thresholds file has none: #389 empties it.
    public var placeholders: [String]

    public init(tiers: [String: TierLimits], profiles: [String: ProfileLimits] = [:], start: StartLimits? = nil,
                navigation: NavigationLimits? = nil, conduct: ConductLimits? = nil, encounters: EncounterLimits? = nil,
                watchdog: WatchdogLimits? = nil, rivals: RivalLimits? = nil, rank: RankLimits? = nil,
                maxP99TickMs: Double, placeholders: [String] = []) {
        self.tiers = tiers
        self.profiles = profiles
        self.start = start
        self.navigation = navigation
        self.conduct = conduct
        self.encounters = encounters
        self.watchdog = watchdog
        self.rivals = rivals
        self.rank = rank
        self.maxP99TickMs = maxP99TickMs
        self.placeholders = placeholders
    }

    private enum CodingKeys: String, CodingKey {
        case tiers, profiles, start, navigation, conduct, encounters, watchdog, rivals, rank, maxP99TickMs, placeholders
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(tiers: try c.decode([String: TierLimits].self, forKey: .tiers),
                  profiles: try c.decodeIfPresent([String: ProfileLimits].self, forKey: .profiles) ?? [:],
                  start: try c.decodeIfPresent(StartLimits.self, forKey: .start),
                  navigation: try c.decodeIfPresent(NavigationLimits.self, forKey: .navigation),
                  conduct: try c.decodeIfPresent(ConductLimits.self, forKey: .conduct),
                  encounters: try c.decodeIfPresent(EncounterLimits.self, forKey: .encounters),
                  watchdog: try c.decodeIfPresent(WatchdogLimits.self, forKey: .watchdog),
                  rivals: try c.decodeIfPresent(RivalLimits.self, forKey: .rivals),
                  rank: try c.decodeIfPresent(RankLimits.self, forKey: .rank),
                  maxP99TickMs: try c.decode(Double.self, forKey: .maxP99TickMs),
                  placeholders: try c.decodeIfPresent([String].self, forKey: .placeholders) ?? [])
    }

    /// Why a run with these tier summaries, timings, skill gap, fun pass, start, navigation, conduct and close encounters misses the
    /// thresholds; empty when it meets them.
    public func breaches(tiers summaries: [String: TierSummary], timings: BotSuiteReport.RunTimings,
                         skillGap: SkillGapSummary? = nil, funPass: FunPassSummary? = nil,
                         start: StartSummary? = nil, navigation: NavigationSummary? = nil,
                         conduct: ConductSummary? = nil, closeEncounters: CloseEncounterSummary? = nil,
                         execution: ExecutionSummary? = nil, watchdog: WatchdogSummary? = nil,
                         rivals: RivalPaceSummary? = nil, rank: RankSummary? = nil) -> [String] {
        var breaches = BotTier.allCases.flatMap { tier -> [String] in
            guard let summary = summaries[tier.rawValue], let limits = tiers[tier.rawValue] else { return [] }
            return limits.breaches(tier.rawValue, summary)
        }
        for profile in BotProfile.allCases {
            breaches += profiles[profile.rawValue]?.breaches(profile.rawValue, skillGap: skillGap, funPass: funPass,
                                                             execution: execution) ?? []
        }
        breaches += self.start?.breaches(start) ?? []
        breaches += self.navigation?.breaches(navigation) ?? []
        breaches += self.conduct?.breaches(conduct) ?? []
        breaches += self.encounters?.breaches(closeEncounters) ?? []
        breaches += self.watchdog?.breaches(watchdog) ?? []
        breaches += self.rivals?.breaches(rivals) ?? []
        breaches += self.rank?.breaches(rank) ?? []
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
        let unknownPlaceholders = thresholds.placeholders.filter { !thresholds.hasKey($0) }
        guard unknownPlaceholders.isEmpty else {
            throw BotSuiteError.usage("thresholds: placeholder names no key: \(unknownPlaceholders.joined(separator: ", "))")
        }
        return thresholds
    }

    /// Whether `path` (`profiles.tactician.minTacticianWinShare`) names a key these thresholds hold a value for.
    public func hasKey(_ path: String) -> Bool {
        guard let data = try? JSONEncoder().encode(self),
              var node = try? JSONSerialization.jsonObject(with: data) else { return false }
        for key in path.split(separator: ".") {
            guard let object = node as? [String: Any], let next = object[String(key)] else { return false }
            node = next
        }
        return !(node is [String: Any])
    }

    /// The bundled thresholds (`thresholds.json`).
    public static func bundled() throws -> BotThresholds {
        guard let url = Bundle.module.url(forResource: "thresholds", withExtension: "json") else {
            throw BotSuiteError.usage("thresholds.json is not bundled")
        }
        return try load(from: url)
    }
}
