import Foundation
import RegattaCore

/// What one seat did in one race (#97). Every key is always encoded, `place` as null when there is none.
public struct SeatMetrics: Codable, Hashable, Sendable {
    public var seat: Int
    public var tier: BotTier
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

    public static let metricKeys = [
        "finished", "place", "ironsSeconds", "markContacts", "boatContacts", "contactsEndingInFouls",
        "contactsToFoulsShare", "foulsAsOffender", "dsqMissedPenalty", "ocsCount", "edgeSeconds",
        "landContacts", "boundaryContacts",
    ]

    private enum CodingKeys: String, CodingKey {
        case seat, tier, skill, status, finished, place, ironsSeconds, markContacts, boatContacts
        case contactsEndingInFouls, contactsToFoulsShare, foulsAsOffender, dsqMissedPenalty, ocsCount
        case edgeSeconds, landContacts, boundaryContacts
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(seat, forKey: .seat)
        try c.encode(tier, forKey: .tier)
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
    public var timings: TickTimings

    init(cell: BotRaceCell, finalTick: Int, capped: Bool, tideStateAtGun: Double?, seats: [SeatMetrics],
         timings: TickTimings) {
        self.cell = cell
        raceSeconds = Double(finalTick) / Double(Race.tickRate)
        self.capped = capped
        tideStateAtGunDegrees = tideStateAtGun.map { $0 * 180 / .pi }
        self.seats = seats
        fleet = FleetMetrics(seats)
        self.timings = timings
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

/// A suite run's report (#97): the matrix, every race, each tier's summary, and the gate's verdict.
public struct BotSuiteReport: Codable, Hashable, Sendable {
    public var simulationVersion: String
    public var matrix: BotMatrix
    public var thresholds: BotThresholds
    public var races: [RaceResult]
    /// Keyed by `BotTier.rawValue`; only the tiers that sailed.
    public var tiers: [String: TierSummary]
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
            let ofTier = seats.filter { $0.tier == tier }
            return ofTier.isEmpty ? nil : (tier.rawValue, TierSummary(ofTier))
        })
        timings = RunTimings(maxP99Ms: races.map(\.timings.p99Ms).max() ?? 0,
                             maxMs: races.map(\.timings.maxMs).max() ?? 0)
        breaches = thresholds.breaches(tiers: tiers, timings: timings)
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
        lines.append("tick: worst p99 \(fixed(timings.maxP99Ms, 3)) ms, max \(fixed(timings.maxMs, 3)) ms")
        lines.append(passed ? "gate: pass" : "gate: FAIL")
        lines += breaches.map { "  \($0)" }
        return lines
    }
}

func fixed(_ value: Double, _ places: Int = 2) -> String {
    String(format: "%.\(places)f", value)
}
