import Foundation
import RegattaBots
import RegattaCore

/// What one seat did in one race (#97). Every key is always encoded, `place` and `profile` as null when
/// there is none.
public struct SeatMetrics: Codable, Hashable, Sendable {
    public var seat: Int
    public var tier: BotTier
    /// The scripted profile she sailed (#231), or nil for a live bot.
    public var profile: BotProfile? = nil
    public var skill: Double
    /// The boat's status at the end: prestart, ocs, racing, finished, dsq or dnf.
    public var status: String
    public var finished: Bool
    public var place: Int?
    /// Seconds racing, not taking a penalty, inside the no-go zone and slower than `BotRaceHarness.ironsSpeed`.
    public var ironsSeconds: Double
    public var markContacts: Int
    public var boatContacts: Int
    /// Of `boatContacts`, those whose incident ended in a rule call, on either boat.
    public var contactsEndingInFouls: Int
    public var contactsToFoulsShare: Double
    public var foulsAsOffender: Int
    /// Disqualified for not taking a penalty.
    public var dsqMissedPenalty: Int
    public var ocsCount: Int
    /// Seconds on the water within `BotRaceHarness.edgeMargin` of the race area's edge, or outside it.
    public var edgeSeconds: Double
    /// Obstruction contacts: none until #82 draws land and the boundary.
    public var landContacts: Int
    public var boundaryContacts: Int
    /// Each beat she sailed, in order (#231): from her start or rounding into it until she rounds out of it.
    public var beats: [BeatSplit] = []

    public static let metricKeys = [
        "finished", "place", "ironsSeconds", "markContacts", "boatContacts", "contactsEndingInFouls",
        "contactsToFoulsShare", "foulsAsOffender", "dsqMissedPenalty", "ocsCount", "edgeSeconds",
        "landContacts", "boundaryContacts", "beats",
    ]

    private enum CodingKeys: String, CodingKey {
        case seat, tier, profile, skill, status, finished, place, ironsSeconds, markContacts, boatContacts
        case contactsEndingInFouls, contactsToFoulsShare, foulsAsOffender, dsqMissedPenalty, ocsCount
        case edgeSeconds, landContacts, boundaryContacts, beats
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(seat, forKey: .seat)
        try c.encode(tier, forKey: .tier)
        try c.encode(profile, forKey: .profile)
        try c.encode(skill, forKey: .skill)
        try c.encode(status, forKey: .status)
        try c.encode(finished, forKey: .finished)
        try c.encode(place, forKey: .place)
        try c.encode(ironsSeconds, forKey: .ironsSeconds)
        try c.encode(markContacts, forKey: .markContacts)
        try c.encode(boatContacts, forKey: .boatContacts)
        try c.encode(contactsEndingInFouls, forKey: .contactsEndingInFouls)
        try c.encode(contactsToFoulsShare, forKey: .contactsToFoulsShare)
        try c.encode(foulsAsOffender, forKey: .foulsAsOffender)
        try c.encode(dsqMissedPenalty, forKey: .dsqMissedPenalty)
        try c.encode(ocsCount, forKey: .ocsCount)
        try c.encode(edgeSeconds, forKey: .edgeSeconds)
        try c.encode(landContacts, forKey: .landContacts)
        try c.encode(boundaryContacts, forKey: .boundaryContacts)
        try c.encode(beats, forKey: .beats)
    }

    static func name(_ status: BoatStatus) -> String {
        switch status {
        case .prestart: "prestart"
        case .ocs: "ocs"
        case .racing: "racing"
        case .finished: "finished"
        case .dsq: "dsq"
        case .dnf: "dnf"
        }
    }
}

/// One beat a seat sailed (#231): how long it took her, and how far she made good up the course over it.
public struct BeatSplit: Codable, Hashable, Sendable {
    public var seconds: Double
    /// Metres along the course axis from where she began the beat to where she rounded out of it.
    public var metres: Double
}

/// Tick times over one race, milliseconds: the bots' decisions and the race step together; and the race's
/// CPU time. Kept apart from everything else in the report, since they're the only numbers that differ
/// between two runs.
public struct TickTimings: Codable, Hashable, Sendable {
    public var ticks: Int
    public var p50Ms: Double
    public var p99Ms: Double
    public var maxMs: Double
    /// CPU time the race took on its thread: the bots, the steps and the tally.
    public var cpuSeconds: Double

    public init(samples: [Double], cpuSeconds: Double) {
        self.cpuSeconds = cpuSeconds
        let sorted = samples.sorted()
        ticks = sorted.count
        p50Ms = TickTimings.percentile(50, ofSorted: sorted)
        p99Ms = TickTimings.percentile(99, ofSorted: sorted)
        maxMs = sorted.last ?? 0
    }

    /// The nearest-rank `p`th percentile of `sorted` (ascending), as `regatta-bench` takes it (#69); 0 for none.
    public static func percentile(_ p: Double, ofSorted sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }
}

/// The fleet's totals over one race.
public struct FleetMetrics: Codable, Hashable, Sendable {
    public var finished: Int
    public var finishShare: Double
    public var ironsSeconds: Double
    public var markContacts: Int
    /// Each contact once, though both boats count it.
    public var boatContacts: Int
    public var ruleCalls: Int
    public var dsqMissedPenalty: Int
    public var ocsCount: Int
    public var edgeSeconds: Double

    init(_ seats: [SeatMetrics]) {
        finished = seats.filter(\.finished).count
        finishShare = share(finished, of: seats.count)
        ironsSeconds = seats.reduce(0) { $0 + $1.ironsSeconds }
        markContacts = seats.reduce(0) { $0 + $1.markContacts }
        boatContacts = seats.reduce(0) { $0 + $1.boatContacts } / 2
        ruleCalls = seats.reduce(0) { $0 + $1.foulsAsOffender }
        dsqMissedPenalty = seats.reduce(0) { $0 + $1.dsqMissedPenalty }
        ocsCount = seats.reduce(0) { $0 + $1.ocsCount }
        edgeSeconds = seats.reduce(0) { $0 + $1.edgeSeconds }
    }
}

/// One race of the matrix: its cell, how far it sailed, each seat, the fleet, and the tick times.
public struct RaceResult: Codable, Hashable, Sendable {
    public var cell: BotRaceCell
    /// The race clock when it ended or was stopped, seconds after the gun.
    public var raceSeconds: Double
    /// Stopped at `capSecondsAfterGun` before the race closed.
    public var capped: Bool
    /// The tide state the race drew at the gun (#78), degrees through the cycle; absent at a venue
    /// without current. The race seed draws it, so the cell's `tideStateDegrees` doesn't choose it.
    public var tideStateAtGunDegrees: Double?
    public var seats: [SeatMetrics]
    public var fleet: FleetMetrics
    /// The baseline against the tactician (#231), in a race that has both; nil otherwise.
    public var skillGap: RaceSkillGap?
    public var timings: TickTimings

    /// `ranks`: each seat's place in the race's order at the end (`Race.place(of:)`), finished or not.
    init(cell: BotRaceCell, finalTick: Int, capped: Bool, tideStateAtGun: Double?, seats: [SeatMetrics],
         ranks: [Int], hullLength: Double, timings: TickTimings) {
        self.cell = cell
        raceSeconds = Double(finalTick) / Double(Race.tickRate)
        self.capped = capped
        tideStateAtGunDegrees = tideStateAtGun.map { $0 * 180 / .pi }
        self.seats = seats
        fleet = FleetMetrics(seats)
        skillGap = RaceSkillGap(seats: seats, ranks: ranks, hullLength: hullLength)
        self.timings = timings
    }
}

/// How a race's tactician seats did against its baseline seats (#231, ADR 0007: "a tactician bot clearly
/// beats a groove-only bot, or the autohelm has flattened skill").
public struct RaceSkillGap: Codable, Hashable, Sendable {
    /// The profiles in the race's order at the end, first place first: finishers, then the rest by rank.
    public var order: [BotProfile]
    /// Whether the tactician won the race: 1 when its seats' mean place in `order` is ahead of the baseline
    /// seats', 0 when behind, ½ for a tie.
    public var tacticianWin: Double
    /// Of the race's tactician–baseline pairs of seats, the share in which the tactician ranked ahead: the
    /// seat-by-seat view of the same order, which a big fleet's spread pulls towards ½.
    public var tacticianPairShare: Double
    /// Each beat's gain of the tactician over the baseline, in beat order, hull lengths: the time the baseline
    /// seats took over it less the tactician seats' (each side's mean over the seats that sailed it), at the
    /// baseline seats' mean speed up the course. A beat either side didn't complete has none.
    public var gainLengthsPerBeat: [Double]

    /// Nil for a race without both profiles.
    init?(seats: [SeatMetrics], ranks: [Int], hullLength: Double) {
        let tacticians = seats.filter { $0.profile == .tactician }
        let baselines = seats.filter { $0.profile == .baseline }
        guard !tacticians.isEmpty, !baselines.isEmpty else { return nil }
        let order = seats.indices.filter { seats[$0].profile != nil }.sorted { ranks[$0] < ranks[$1] }.compactMap { seats[$0].profile }
        self.order = order
        let meanPlace = { (profile: BotProfile) -> Double in
            let places = order.indices.filter { order[$0] == profile }
            return Double(places.reduce(0, +)) / Double(places.count)
        }
        let (t, b) = (meanPlace(.tactician), meanPlace(.baseline))
        tacticianWin = t < b ? 1 : t > b ? 0 : 0.5
        let wins = tacticians.reduce(0) { total, t in total + baselines.filter { ranks[t.seat] < ranks[$0.seat] }.count }
        tacticianPairShare = share(wins, of: tacticians.count * baselines.count)
        let beatCount = seats.map(\.beats.count).max() ?? 0
        gainLengthsPerBeat = (0..<beatCount).compactMap { beat in
            let t = tacticians.compactMap { $0.beats.indices.contains(beat) ? $0.beats[beat] : nil }
            let b = baselines.compactMap { $0.beats.indices.contains(beat) ? $0.beats[beat] : nil }
            guard !t.isEmpty, !b.isEmpty else { return nil }
            let seconds = { (splits: [BeatSplit]) in splits.reduce(0) { $0 + $1.seconds } / Double(splits.count) }
            let baselineSeconds = seconds(b)
            let baselineSpeed = b.reduce(0) { $0 + $1.metres } / Double(b.count) / max(baselineSeconds, 1)
            return (baselineSeconds - seconds(t)) * baselineSpeed / hullLength
        }
    }
}

/// The skill gap over a run (#231): what `minTacticianWinShare` and `minTacticianGainLengthsPerBeat` hold.
public struct SkillGapSummary: Codable, Hashable, Sendable {
    /// Races with both profiles.
    public var races: Int
    /// The share of those races the tactician won (`RaceSkillGap.tacticianWin`).
    public var tacticianWinShare: Double
    /// The mean over those races of each one's `RaceSkillGap.tacticianPairShare`.
    public var tacticianPairShare: Double
    /// Beats with a gain: every race's, together.
    public var beats: Int
    /// The median of those gains, hull lengths.
    public var medianGainLengthsPerBeat: Double

    /// Nil when no race had both profiles.
    init?(_ races: [RaceSkillGap]) {
        guard !races.isEmpty else { return nil }
        self.races = races.count
        tacticianWinShare = races.reduce(0) { $0 + $1.tacticianWin } / Double(races.count)
        tacticianPairShare = races.reduce(0) { $0 + $1.tacticianPairShare } / Double(races.count)
        let gains = races.flatMap(\.gainLengthsPerBeat).sorted()
        beats = gains.count
        medianGainLengthsPerBeat = gains.isEmpty ? 0 : (gains[(gains.count - 1) / 2] + gains[gains.count / 2]) / 2
    }
}

/// One tier's seats over the whole run: what the thresholds hold it to.
public struct TierSummary: Codable, Hashable, Sendable {
    public var seats: Int
    public var finished: Int
    public var finishShare: Double
    public var meanIronsSeconds: Double
    public var maxIronsSeconds: Double
    public var meanMarkContacts: Double
    /// Seat contacts: a contact between two seats of the tier counts for each.
    public var boatContacts: Int
    public var contactsEndingInFouls: Int
    public var contactsToFoulsShare: Double
    public var foulsAsOffender: Int
    public var dsqMissedPenalty: Int
    public var ocsCount: Int
    public var meanEdgeSeconds: Double
    public var maxEdgeSeconds: Double

    init(_ seats: [SeatMetrics]) {
        let n = Double(max(seats.count, 1))
        self.seats = seats.count
        finished = seats.filter(\.finished).count
        finishShare = share(finished, of: seats.count)
        meanIronsSeconds = seats.reduce(0) { $0 + $1.ironsSeconds } / n
        maxIronsSeconds = seats.map(\.ironsSeconds).max() ?? 0
        meanMarkContacts = Double(seats.reduce(0) { $0 + $1.markContacts }) / n
        boatContacts = seats.reduce(0) { $0 + $1.boatContacts }
        contactsEndingInFouls = seats.reduce(0) { $0 + $1.contactsEndingInFouls }
        contactsToFoulsShare = share(contactsEndingInFouls, of: boatContacts)
        foulsAsOffender = seats.reduce(0) { $0 + $1.foulsAsOffender }
        dsqMissedPenalty = seats.reduce(0) { $0 + $1.dsqMissedPenalty }
        ocsCount = seats.reduce(0) { $0 + $1.ocsCount }
        meanEdgeSeconds = seats.reduce(0) { $0 + $1.edgeSeconds } / n
        maxEdgeSeconds = seats.map(\.edgeSeconds).max() ?? 0
    }
}

/// A suite run's report (#97): the matrix, every race, each tier's and profile's summary, the skill gap, and
/// the gate's verdict.
public struct BotSuiteReport: Codable, Hashable, Sendable {
    public var simulationVersion: String
    public var matrix: BotMatrix
    public var thresholds: BotThresholds
    public var races: [RaceResult]
    /// The live bots' seats by tier, keyed by `BotTier.rawValue`; only the tiers that sailed.
    public var tiers: [String: TierSummary]
    /// The scripted profiles' seats (#231), keyed by `BotProfile.rawValue`; only the profiles that sailed.
    public var profiles: [String: TierSummary]
    /// The tactician against the baseline over the races that had both; nil when none did.
    public var skillGap: SkillGapSummary?
    public var timings: RunTimings
    /// Why the run misses the thresholds; empty when it passes.
    public var breaches: [String]
    public var passed: Bool

    public struct RunTimings: Codable, Hashable, Sendable {
        /// The worst race's p99 tick.
        public var maxP99Ms: Double
        public var maxMs: Double
    }

    public init(matrix: BotMatrix, thresholds: BotThresholds, races: [RaceResult]) {
        simulationVersion = RegattaCore.simulationVersion
        self.matrix = matrix
        self.thresholds = thresholds
        self.races = races
        let seats = races.flatMap(\.seats)
        tiers = Dictionary(uniqueKeysWithValues: BotTier.allCases.compactMap { tier in
            let ofTier = seats.filter { $0.tier == tier && $0.profile == nil }
            return ofTier.isEmpty ? nil : (tier.rawValue, TierSummary(ofTier))
        })
        profiles = Dictionary(uniqueKeysWithValues: BotProfile.allCases.compactMap { profile in
            let ofProfile = seats.filter { $0.profile == profile }
            return ofProfile.isEmpty ? nil : (profile.rawValue, TierSummary(ofProfile))
        })
        skillGap = SkillGapSummary(races.compactMap(\.skillGap))
        timings = RunTimings(maxP99Ms: races.map(\.timings.p99Ms).max() ?? 0,
                             maxMs: races.map(\.timings.maxMs).max() ?? 0)
        breaches = thresholds.breaches(tiers: tiers, timings: timings, skillGap: skillGap)
        passed = breaches.isEmpty
    }

    /// Sorted keys, so two runs of the same matrix differ only in their timings.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(self)
    }

    /// A short text summary: one line per tier, then the gate.
    public var lines: [String] {
        var lines = ["\(races.count) races, \(races.reduce(0) { $0 + $1.seats.count }) boats, \(races.filter(\.capped).count) capped"]
        for tier in BotTier.allCases {
            guard let s = tiers[tier.rawValue] else { continue }
            lines.append("\(tier.rawValue): \(s.finished)/\(s.seats) finished, irons \(fixed(s.meanIronsSeconds)) s/boat, "
                + "marks \(fixed(s.meanMarkContacts))/boat, contacts \(s.boatContacts) (\(fixed(s.contactsToFoulsShare)) fouls), "
                + "edge \(fixed(s.meanEdgeSeconds)) s/boat, dsq \(s.dsqMissedPenalty), ocs \(s.ocsCount)")
        }
        for profile in BotProfile.allCases {
            guard let s = profiles[profile.rawValue] else { continue }
            lines.append("\(profile.rawValue): \(s.finished)/\(s.seats) finished, irons \(fixed(s.meanIronsSeconds)) s/boat, "
                + "marks \(fixed(s.meanMarkContacts))/boat")
        }
        if let gap = skillGap {
            lines.append("skill gap: tactician won \(fixed(gap.tacticianWinShare)) of \(gap.races) races "
                + "(\(fixed(gap.tacticianPairShare)) of pairs), median gain \(fixed(gap.medianGainLengthsPerBeat)) "
                + "lengths/beat over \(gap.beats) beats")
        }
        lines.append("tick: worst p99 \(fixed(timings.maxP99Ms, 3)) ms, max \(fixed(timings.maxMs, 3)) ms")
        lines.append(passed ? "gate: pass" : "gate: FAIL")
        lines += breaches.map { "  \($0)" }
        return lines
    }
}

func fixed(_ value: Double, _ places: Int = 2) -> String {
    String(format: "%.\(places)f", value)
}
