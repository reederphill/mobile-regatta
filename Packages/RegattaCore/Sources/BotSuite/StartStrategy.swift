import Foundation
import RegattaBots
import RegattaCore

// #276 PR 1 (report-only): the start-strategy rows. Which end of the line the fleet starts at against the line's bias,
// how spread out it starts, how fast it is going at the gun, where its pre-gun calls are, which way each boat approached
// the line, and how well the bias some seconds before the gun predicts the gun's. Each row is the #276 brief's
// `startplan.py` (and its bias-predictability table), ported: samples once a second (`tick % Race.tickRate == 0`) from
// 60 s before the gun to the gun, the bias at the gun from the ground wind at the line's midpoint, and the pre-gun calls
// those up to and including the gun's tick (the scratch dump kept a later call on a boat not yet racing too, which
// `startplan.py` then dropped). Nothing here steers a boat: the harness reads the race, as the tally does.

/// How a boat approached the start line, read off her track (#276; not the bot's intent): her samples once a second
/// over the last 60 s before the gun.
public enum ApproachKind: String, Codable, CaseIterable, Hashable, Sendable {
    /// On starboard at T−10 and T−5, eased more than half the last 30 s and under 4 hull lengths below the line at
    /// T−10: the starboard hold.
    case easedHold
    /// On starboard at T−10 and T−5, deeper than 8 hull lengths in the last 30 s with a run (relative wind past 120°)
    /// between T−30 and T−10: deep, then hauled up to the line (the Vanderbilt-like approach).
    case deepRun
    /// On port at T−10 or at T−5.
    case port
    /// On starboard, neither of the above.
    case other

    public var label: String {
        switch self {
        case .easedHold: "eased hold"
        case .deepRun: "deep run then up"
        case .port: "port at T-10/T-5"
        case .other: "starboard other"
        }
    }

    /// Her approach from `track`, her samples indexed by whole seconds before the gun (0 the gun's); nil unless she
    /// was sampled at T−59, T−10 and T−5.
    static func read(_ track: [StartSample?]) -> ApproachKind? {
        func at(_ second: Int) -> StartSample? { track.indices.contains(second) ? track[second] : nil }
        guard at(59) != nil, let ten = at(10), let five = at(5) else { return nil }
        if !five.starboard || !ten.starboard { return .port }
        let lastThirty = (0...30).compactMap(at)
        let deepest = lastThirty.map(\.depth).max() ?? -.infinity
        if deepest > deepLengths, (10...30).contains(where: { at($0).map { abs($0.relativeWindDegrees) > runDegrees } ?? false }) {
            return .deepRun
        }
        if Double(lastThirty.filter(\.eased).count) / Double(lastThirty.count) > 0.5, ten.depth < holdLengths {
            return .easedHold
        }
        return .other
    }

    /// Deeper than this, hull lengths below the line, in the last 30 s ...
    static let deepLengths = 8.0
    /// ... with her relative wind past this, degrees, between T−30 and T−10: a deep run.
    static let runDegrees = 120.0
    /// Under this many hull lengths below the line at T−10: near enough the line to be holding on it.
    static let holdLengths = 4.0
}

/// One boat once a second before the gun (#276).
struct StartSample: Hashable, Sendable {
    /// Hull lengths below the start line (negative over it).
    var depth: Double
    var starboard: Bool
    /// Her speed over her close-hauled polar speed in her wind.
    var speedShare: Double
    /// Her wind off her bow, degrees either way.
    var relativeWindDegrees: Double
    /// Her held input's Ease.
    var eased: Bool
}

/// The line's bias in degrees (#276): its angle off square to the wind blowing from `windDirection`, from
/// `along`, the unit vector from the pin to the committee boat. Positive when the committee end is favoured (the
/// wind is backed towards it: it is the end further up the wind).
func lineBiasDegrees(along: Vec2, windDirection: Double) -> Double {
    rad2deg(asin(max(-1, min(1, along.dot(Vec2.heading(windDirection))))))
}

/// The harness's watch of the start for the start-strategy rows (#276): every seat's samples once a second over the
/// last 60 s before the gun, the line's bias each of those seconds, and the rule calls up to the gun.
struct StartStrategyTally {
    /// The samples reach back this far before the gun, seconds.
    static let windowSeconds = 60

    private let line: CourseLayout.Line
    private let along: Vec2
    private let middle: Vec2
    private let hullLength: Double
    private var tracks: [[StartSample?]]
    private var bias: [Double?]
    private(set) var callSpots: [Double] = []
    private var callsAsOffender: [Int]

    init(race: Race) {
        line = race.course.startLine
        along = (line.committee.position - line.pin.position).normalized
        middle = (line.pin.position + line.committee.position) * 0.5
        hullLength = race.boatClass.hull.length
        tracks = Array(repeating: Array(repeating: nil, count: Self.windowSeconds + 1), count: race.boats.count)
        bias = Array(repeating: nil, count: Self.windowSeconds + 1)
        callsAsOffender = Array(repeating: 0, count: race.boats.count)
    }

    /// Call once after each `race.step()`, with the events it emitted.
    mutating func record(_ race: Race, events: [RaceEvent]) {
        let tick = race.tick
        guard tick <= 0 else { return }
        for event in events {
            guard case .ruleCall(let call) = event.kind else { continue }
            callSpots.append(lineSpot(race.boats[call.offender].position, on: line))
            callsAsOffender[call.offender] += 1
        }
        let second = -tick / Race.tickRate
        guard tick.isMultiple(of: Race.tickRate), second <= Self.windowSeconds else { return }
        bias[second] = lineBiasDegrees(along: along, windDirection: race.groundWind(at: middle).direction)
        for (seat, boat) in race.boats.enumerated() {
            let closeHauled = race.boatClass.polar.bestUpwind(tws: boat.windSpeed).speed
            tracks[seat][second] = StartSample(
                depth: -line.side(boat.position) / hullLength, starboard: boat.tack == .starboard,
                speedShare: boat.speed / max(closeHauled, 0.1), relativeWindDegrees: rad2deg(boat.relativeWind),
                eased: race.heldInputs[seat].ease)
        }
    }

    /// The line's bias each second before the gun from the gun's back, as far as the race sampled it unbroken.
    var biasBeforeGun: [Double] { Array(bias.prefix { $0 != nil }.compactMap { $0 }) }

    /// `seat`'s start rows into her metrics.
    func fill(_ metrics: inout SeatMetrics, seat: Int) {
        let track = tracks[seat]
        metrics.approachKind = ApproachKind.read(track)
        metrics.speedAtGunShare = track[0]?.speedShare
        metrics.overLineAtGun = track[0].map { $0.depth < 0 }
        metrics.preGunCalls = callsAsOffender[seat]
    }
}

/// The start-strategy rows (#276) pooled over a run's races: `--diagnose`'s "start strategies" table (the report's
/// `diagnose.startStrategies`), and the start suite's log. Every seat of every race the harness watched counts.
public struct StartStrategySummary: Codable, Hashable, Sendable {
    /// The |bias| bins, degrees: from (inclusive) and to (exclusive), and their label.
    public static let biasBins: [(label: String, from: Double, to: Double)] = [
        ("< 2", 0, 2), ("2-5", 2, 5), ("5-10", 5, 10), (">= 10", 10, .infinity), (">= 5", 5, .infinity), ("all", 0, .infinity),
    ]
    /// A start this far towards the favoured end from the line's middle, as a share of the line, is in its third.
    public static let favouredThird = 1.0 / 6
    /// The gun's favoured end is read from a bias this large or larger, degrees ...
    public static let readableBiasDegrees = 5.0
    /// ... and compared with the end favoured these many seconds before the gun.
    public static let predictabilitySeconds = [45, 30, 20, 15, 10, 5]
    /// Speed at the gun at this share of close-hauled or more is a full-speed start.
    public static let fullSpeedShare = 0.8
    /// The densest fifth: windows a fifth of the line long, stepped a twentieth along it.
    public static let fifth = 0.2
    public static let fifthSteps = 17

    public var races: Int
    /// |bias at the gun|, degrees: median, p90 and largest.
    public var biasMedian: Double
    public var biasP90: Double
    public var biasMax: Double
    public var byBias: [BiasRow]
    /// The least-squares slope of start spot (a share of the line from the pin) on the bias at the gun, a degree.
    public var spotSlopePerDegree: Double
    /// Each race's start spots (races with three starters or more): their standard deviation, and the most of the fleet
    /// in a fifth of the line.
    public var spreadRaces: Int
    public var spotSD: Quantiles?
    public var densestFifth: Quantiles?
    public var densestFifthMax: Double?
    /// On-time starters whose approach was read: speed at the gun over close-hauled.
    public var onTimeStarters: Int
    public var speedAtGun: Quantiles?
    public var fullSpeedShare: Double
    /// Rule calls up to the gun, by where the offender was along the line.
    public var preGunCalls: Int
    public var pinThirdCalls: Int
    public var middleThirdCalls: Int
    public var committeeThirdCalls: Int
    public var approaches: [ApproachRow]
    public var predictability: [PredictabilityRow]

    /// Median, p10 and p90, each the nearest-rank sample (`startplan.py`'s `q`).
    public struct Quantiles: Codable, Hashable, Sendable {
        public var median: Double
        public var p10: Double
        public var p90: Double

        init?(_ values: [Double]) {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            median = nearestRank(sorted, 0.5)
            p10 = nearestRank(sorted, 0.1)
            p90 = nearestRank(sorted, 0.9)
        }
    }

    /// The seats of the races whose |bias at the gun| is in a bin: starters' shares at the favoured end's half and
    /// third, and on time over every seat.
    public struct BiasRow: Codable, Hashable, Sendable {
        public var bin: String
        public var races: Int
        public var seats: Int
        public var starters: Int
        public var favouredHalfShare: Double
        public var favouredThirdShare: Double
        public var onTimeShare: Double
    }

    /// The seats whose approach read as `kind`: their share of those read, on time, mean start (a seat that never
    /// started as 60 s), over the line at the gun, rule calls up to the gun a seat, and the on-time starters' speed at
    /// the gun over close-hauled (median).
    public struct ApproachRow: Codable, Hashable, Sendable {
        public var kind: String
        public var seats: Int
        public var share: Double
        public var onTimeShare: Double
        public var meanStartSeconds: Double
        public var overAtGunShare: Double
        public var callsPerSeat: Double
        public var speedAtGunMedian: Double?
    }

    /// One conditions file's races: of those with |bias at the gun| ≥ `readableBiasDegrees`, the share whose favoured
    /// end `predictabilitySeconds` before the gun is the gun's; and the bias's swing over the last 60 s (largest less
    /// smallest), median over all its races.
    public struct PredictabilityRow: Codable, Hashable, Sendable {
        public var conditions: String
        public var readableRaces: Int
        public var agreement: [Double?]
        public var swingMedian: Double
    }

    /// Over the races the harness watched the start of (`RaceResult.lineBiasAtGunDegrees`); nil if none.
    public init?(_ results: [RaceResult]) {
        let watched = results.filter { $0.lineBiasAtGunDegrees != nil }
        guard !watched.isEmpty else { return nil }
        races = watched.count
        let gunBias = watched.map { $0.lineBiasAtGunDegrees ?? 0 }
        let magnitudes = gunBias.map(abs).sorted()
        biasMedian = nearestRank(magnitudes, 0.5)
        biasP90 = nearestRank(magnitudes, 0.9)
        biasMax = magnitudes.last ?? 0

        let onTime = StartSummary.onTimeSeconds
        func started(_ seat: SeatMetrics) -> Bool { seat.startSeconds != nil && seat.startLineSpot != nil }
        func isOnTime(_ seat: SeatMetrics) -> Bool { (seat.startSeconds ?? .infinity) <= onTime }
        /// How far towards the favoured end from the line's middle she started.
        func toward(_ seat: SeatMetrics, bias: Double) -> Double { ((seat.startLineSpot ?? 0.5) - 0.5) * (bias >= 0 ? 1 : -1) }

        byBias = Self.biasBins.map { bin in
            let binned = watched.filter { (bin.from..<bin.to).contains(abs($0.lineBiasAtGunDegrees ?? 0)) }
            let seats = binned.flatMap { race in race.seats.map { (seat: $0, bias: race.lineBiasAtGunDegrees ?? 0) } }
            let starters = seats.filter { started($0.seat) }
            return BiasRow(bin: bin.label, races: binned.count, seats: seats.count, starters: starters.count,
                           favouredHalfShare: share(starters.filter { toward($0.seat, bias: $0.bias) > 0 }.count, of: starters.count),
                           favouredThirdShare: share(starters.filter { toward($0.seat, bias: $0.bias) > Self.favouredThird }.count,
                                                     of: starters.count),
                           onTimeShare: share(starters.filter { isOnTime($0.seat) }.count, of: seats.count))
        }

        let points = watched.flatMap { race in
            race.seats.filter(started).map { (x: race.lineBiasAtGunDegrees ?? 0, y: $0.startLineSpot ?? 0) }
        }
        spotSlopePerDegree = leastSquaresSlope(points)

        var deviations: [Double] = [], densest: [Double] = []
        for race in watched {
            let spots = race.seats.compactMap { started($0) ? $0.startLineSpot : nil }
            guard spots.count >= 3 else { continue }
            let mean = spots.reduce(0, +) / Double(spots.count)
            deviations.append((spots.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(spots.count)).squareRoot())
            let most = (0..<Self.fifthSteps).map { step in
                let from = Double(step) / 20
                return spots.filter { from <= $0 && $0 < from + Self.fifth }.count
            }.max() ?? 0
            densest.append(Double(most) / Double(race.seats.count))
        }
        spreadRaces = deviations.count
        spotSD = Quantiles(deviations)
        densestFifth = Quantiles(densest)
        densestFifthMax = densest.max()

        let read = watched.flatMap(\.seats).filter { $0.approachKind != nil }
        let speeds = read.filter(isOnTime).compactMap(\.speedAtGunShare).filter { !$0.isNaN }
        onTimeStarters = speeds.count
        speedAtGun = Quantiles(speeds)
        fullSpeedShare = share(speeds.filter { $0 >= Self.fullSpeedShare }.count, of: speeds.count)

        let spots = watched.flatMap { $0.preGunCallSpots ?? [] }
        preGunCalls = spots.count
        pinThirdCalls = spots.filter { $0 < 1.0 / 3 }.count
        middleThirdCalls = spots.filter { 1.0 / 3 <= $0 && $0 < 2.0 / 3 }.count
        committeeThirdCalls = spots.filter { $0 >= 2.0 / 3 }.count

        approaches = ApproachKind.allCases.map { kind in
            let seats = read.filter { $0.approachKind == kind }
            let speeds = seats.filter(isOnTime).compactMap(\.speedAtGunShare).filter { !$0.isNaN }
            return ApproachRow(
                kind: kind.rawValue, seats: seats.count, share: share(seats.count, of: read.count),
                onTimeShare: share(seats.filter(isOnTime).count, of: seats.count),
                meanStartSeconds: seats.isEmpty ? 0
                    : seats.reduce(0) { $0 + min($1.startSeconds ?? 99, 60) } / Double(seats.count),
                overAtGunShare: share(seats.filter { $0.overLineAtGun == true }.count, of: seats.count),
                callsPerSeat: seats.isEmpty ? 0 : Double(seats.reduce(0) { $0 + ($1.preGunCalls ?? 0) }) / Double(seats.count),
                speedAtGunMedian: speeds.isEmpty ? nil : nearestRank(speeds.sorted(), 0.5))
        }

        predictability = Set(watched.map(\.cell.conditions)).sorted().map { conditions in
            let races = watched.filter { $0.cell.conditions == conditions }
            let readable = races.filter { abs($0.lineBiasAtGunDegrees ?? 0) >= Self.readableBiasDegrees }
            let agreement = Self.predictabilitySeconds.map { second -> Double? in
                let sampled = readable.compactMap { race -> Bool? in
                    guard let before = race.lineBiasBeforeGunDegrees, before.indices.contains(second) else { return nil }
                    return (before[second] >= 0) == ((race.lineBiasAtGunDegrees ?? 0) >= 0)
                }
                return sampled.isEmpty ? nil : share(sampled.filter { $0 }.count, of: sampled.count)
            }
            let swings = races.compactMap { race -> Double? in
                guard let before = race.lineBiasBeforeGunDegrees, let high = before.max(), let low = before.min() else { return nil }
                return high - low
            }
            return PredictabilityRow(conditions: conditions, readableRaces: readable.count, agreement: agreement,
                                     swingMedian: middleValue(swings))
        }
    }

    public var lines: [String] {
        var lines = ["start strategies (#276): \(races) races; line bias at the gun (+ the committee end favoured), |bias| "
            + "median \(fixed(biasMedian, 1)), p90 \(fixed(biasP90, 1)), max \(fixed(biasMax, 1)) deg; by |bias|: starters at the "
            + "favoured end's half and third of the line, and on time of all seats"]
        lines += table([["|bias| deg", "races", "seats", "starters", "fav half", "fav third", "on time"]] + byBias.map {
            [$0.bin, "\($0.races)", "\($0.seats)", "\($0.starters)", fixed($0.favouredHalfShare, 3), fixed($0.favouredThirdShare, 3),
             fixed($0.onTimeShare, 3)]
        })
        lines.append("start spot on bias: slope \(fixed(spotSlopePerDegree, 4)) of the line a degree")
        lines.append("start spread (\(spreadRaces) races with 3+ starters): SD of start spots median \(quantiles(spotSD, 3)); "
            + "densest fifth of the line, share of the fleet: median \(text(densestFifth?.median, 2)), p90 "
            + "\(text(densestFifth?.p90, 2)), max \(text(densestFifthMax, 2))")
        lines.append("speed at the gun, on-time starters (\(onTimeStarters)), of close-hauled: median \(text(speedAtGun?.median, 2)), "
            + "p10 \(text(speedAtGun?.p10, 2)), share >= \(fixed(Self.fullSpeedShare, 1)): \(fixed(fullSpeedShare, 3))")
        lines.append("pre-gun calls \(preGunCalls) by the offender's third of the line: pin \(pinThirdCalls), middle "
            + "\(middleThirdCalls), committee \(committeeThirdCalls)")
        lines.append("approach kinds, read off each seat's track (not the bot's intent): share, on time, mean start s, over at the "
            + "gun, pre-gun calls a seat, on-time starters' speed at the gun of close-hauled (median)")
        lines += table([["approach", "seats", "share", "on time", "mean start s", "over at gun", "calls/seat", "speed at gun"]]
            + approaches.map {
                [ApproachKind(rawValue: $0.kind)?.label ?? $0.kind, "\($0.seats)", fixed($0.share, 3), fixed($0.onTimeShare, 3),
                 fixed($0.meanStartSeconds, 2), fixed($0.overAtGunShare, 3), fixed($0.callsPerSeat, 3), text($0.speedAtGunMedian, 2)]
            })
        lines.append("bias predictability: of the races with |bias at the gun| >= \(fixed(Self.readableBiasDegrees, 0)) deg, the "
            + "share whose favoured end some seconds before the gun is the gun's; the bias's swing over the last "
            + "\(StartStrategyTally.windowSeconds) s, median of all races, deg")
        lines += table([["conditions", "races"] + Self.predictabilitySeconds.map { "T-\($0)" } + ["swing"]]
            + predictability.map { row in
                [row.conditions, "\(row.readableRaces)"] + row.agreement.map { text($0, 2) } + [fixed(row.swingMedian, 1)]
            })
        return lines
    }

    private func quantiles(_ q: Quantiles?, _ places: Int) -> String {
        q.map { "\(fixed($0.median, places)) (p10 \(fixed($0.p10, places)) / p90 \(fixed($0.p90, places)))" } ?? "-"
    }

    private func text(_ value: Double?, _ places: Int) -> String { value.map { fixed($0, places) } ?? "-" }
}

/// The sample at rank `p` of `sorted` (ascending): the nearest rank, `p × (n − 1)` rounded half to even, as Python's
/// `round` rounds (`startplan.py`'s `q`). 0 for none.
func nearestRank(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let index = Int((p * Double(sorted.count - 1)).rounded(.toNearestOrEven))
    return sorted[min(sorted.count - 1, max(0, index))]
}

/// The middle value of `values`: the mean of the middle two of an even count (Python's `statistics.median`). 0 for none.
func middleValue(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted(), half = sorted.count / 2
    return sorted.count.isMultiple(of: 2) ? (sorted[half - 1] + sorted[half]) / 2 : sorted[half]
}

/// The least-squares slope of `y` on `x`; 0 when every `x` is the same.
func leastSquaresSlope(_ points: [(x: Double, y: Double)]) -> Double {
    guard !points.isEmpty else { return 0 }
    let n = Double(points.count)
    let meanX = points.reduce(0) { $0 + $1.x } / n, meanY = points.reduce(0) { $0 + $1.y } / n
    let across = points.reduce(0) { $0 + ($1.x - meanX) * ($1.y - meanY) }
    let spread = points.reduce(0) { $0 + ($1.x - meanX) * ($1.x - meanX) }
    return spread == 0 ? 0 : across / spread
}
