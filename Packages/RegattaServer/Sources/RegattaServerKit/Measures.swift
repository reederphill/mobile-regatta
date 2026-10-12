import Foundation
import Persistence
import Ratings
import RegattaBots
import RegattaCore
import RegattaServices

// Server-side measures and balance queries (#157; #28, #24, #31, #229). The server records what the measures need as
// its own analytics events (#156), keyed to the player: each queue join, each wait in the queue and how it ended, each
// fleet locked, each briefing leave and the cooldown it cost, and each seat's round trips (the server pings every
// seated race connection). The measures read those and the window's race logs: queue wait, humans per fleet, briefing
// leaves and cooldowns, drops, rejoins and RET, the round-trip distribution and the time over the 250 ms warning, and
// the Race again rate with the time from finish to re-queue. The balance queries read race logs alone: rule calls and
// protests per rule, start and leg splits by venue and conditions, results by tier, and the ratings' calibration and
// each player's finish variance. A race sailed on tuned files is never in them (#229). Both are admin routes (#154).

extension AnalyticsEventName {
    /// A player joined the queue.
    public static let queueJoined = AnalyticsEventName("queue_joined")
    /// A fleet locked: its humans and boats. About nobody.
    public static let fleetLocked = AnalyticsEventName("fleet_locked")
}

/// One seat's round trips, from the server's pings (#157, #31): each the time from the ping to its pong.
public struct RoundTrips: Sendable, Equatable {
    /// Milliseconds, in the order they came back.
    public private(set) var milliseconds: [Double] = []

    public init(milliseconds: [Double] = []) { self.milliseconds = milliseconds }

    /// A pong for the ping stamped `sentAt`, arriving `now` (nanoseconds, monotonic). A stamp from the future or over a
    /// minute old isn't ours.
    public mutating func add(sentAt: UInt64, now: UInt64) {
        guard now >= sentAt else { return }
        let ms = Double(now - sentAt) / 1_000_000
        guard ms < 60_000 else { return }
        milliseconds.append(ms)
    }

    public var isEmpty: Bool { milliseconds.isEmpty }
}

/// A distribution's summary: its count, mean, median, 90th and 95th percentiles and range. Nearest-rank percentiles.
public struct Distribution: Encodable, Sendable, Equatable {
    public var count: Int
    public var mean: Double?
    public var median: Double?
    public var p90: Double?
    public var p95: Double?
    public var min: Double?
    public var max: Double?

    public init(_ values: [Double]) {
        let sorted = values.sorted()
        count = sorted.count
        guard !sorted.isEmpty else { return }
        func rank(_ p: Double) -> Double { sorted[Swift.max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1)] }
        mean = sorted.reduce(0, +) / Double(sorted.count)
        median = rank(0.5)
        p90 = rank(0.9)
        p95 = rank(0.95)
        min = sorted.first
        max = sorted.last
    }
}

/// The windows and thresholds the measures and balance queries use.
public struct MeasuresSettings: Sendable, Equatable {
    /// The round-trip warning (#31): the time spent over it is measured.
    public var roundTripWarningMs = 250.0
    /// A finisher who queues again within this long of her finish tapped Race again (#24).
    public var raceAgainWindow: TimeInterval = 10 * 60
    /// The ratings' calibration buckets pairs by rating gap, this wide.
    public var calibrationBucket = 100.0
    /// A player's finish variance is over her last this many races...
    public var varianceRaces = 10
    /// ...and needs at least this many.
    public var minVarianceRaces = 3
    /// The most races one balance query reads.
    public var maxRaces = 2_000

    public init() {}
}

/// Records what the measures need (#157) as the server's analytics events. Each write is the analytics store's: one
/// that fails is logged, and never stops the queue or a race.
public final class ServerMeasures: Sendable {
    public let analytics: AnalyticsIngest
    public let queries: MeasureQueries
    /// How often a seat is pinged: each round trip stands for this long.
    public let pingInterval: Duration
    let settings: MeasuresSettings

    public init(analytics: AnalyticsIngest, archive: any RaceArchive, ratings: any RatingBook, settings: MeasuresSettings = MeasuresSettings(),
                pingInterval: Duration = .seconds(2), now: @escaping @Sendable () -> Date = { Date() }) {
        self.analytics = analytics
        self.settings = settings
        self.pingInterval = pingInterval
        queries = MeasureQueries(analytics: analytics.store, archive: archive, ratings: ratings, settings: settings, now: now)
    }

    /// What the queue says, as an event: recorded in the background.
    public func queue(_ event: QueueEvent) {
        Task { await record(event) }
    }

    func record(_ event: QueueEvent) async {
        let (name, player, properties): (AnalyticsEventName, String?, [String: AnalyticsValue]) = switch event {
        case .joined(let player): (.queueJoined, player, [:])
        case .left(let player, let waited): (.queueWait, player, ["waited_s": .double(waited), "outcome": .string("left")])
        case .matched(let player, let waited, let humans):
            (.queueWait, player, ["waited_s": .double(waited), "outcome": .string("matched"), "humans": .int(humans)])
        case .fleetLocked(let humans, let boats): (.fleetLocked, nil, ["humans": .int(humans), "boats": .int(boats)])
        case .briefingLeave(let player, let cooldown): (.briefingLeave, player, ["cooldown_s": .double(cooldown)])
        }
        await record(name, about: player, properties)
    }

    /// A seat's round trips, when its connection ended: about the player who sat it, if a player did.
    public func roundTrips(race: UUID, seat: Int, _ trips: RoundTrips) async {
        guard !trips.isEmpty else { return }
        let player: String?
        do {
            player = try await queries.archive.seats(of: race)?.humans.first { $0.seat == seat }?.playerID
        } catch {
            player = nil
        }
        guard let player, !player.hasPrefix(PlayerDataStore.anonymousPrefix) else { return }
        let summary = Distribution(trips.milliseconds)
        let interval = Double(pingInterval.components.seconds) + Double(pingInterval.components.attoseconds) / 1e18
        let over = trips.milliseconds.filter { $0 > settings.roundTripWarningMs }.count
        await record(.roundTrip, about: player, [
            "median_ms": .double(summary.median ?? 0), "p95_ms": .double(summary.p95 ?? 0), "max_ms": .double(summary.max ?? 0),
            "samples": .int(summary.count), "seconds": .double(Double(summary.count) * interval), "over_warning_s": .double(Double(over) * interval),
        ])
    }

    private func record(_ name: AnalyticsEventName, about player: String?, _ properties: [String: AnalyticsValue]) async {
        do {
            try await analytics.record(name, about: player, properties: properties)
        } catch {
            FileHandle.standardError.write(Data("RegattaServer: measures: can't record \(name.rawValue): \(error)\n".utf8))
        }
    }
}

// MARK: - The measures

/// The measures over a window (#157; #28, #24, #31). Times in seconds, round trips in milliseconds.
public struct MeasuresReport: Encodable, Sendable, Equatable {
    public struct Count: Encodable, Sendable, Equatable {
        public var value: Int
        public var count: Int
    }

    public struct BriefingLeaves: Encodable, Sendable, Equatable {
        public var leaves = 0
        public var players = 0
        public var cooldowns = 0
        public var cooldownSeconds = 0.0
    }

    public struct Seats: Encodable, Sendable, Equatable {
        /// Human seats in closed races (taken over before the gun, not).
        public var humanSeats = 0
        /// Socket closes, and inputs stopping past the hold.
        public var disconnects = 0
        public var drops = 0
        public var rejoins = 0
        /// Human seats retired: gone at the close (G6).
        public var retired = 0
        /// Per human seat.
        public var dropRate: Double?
        public var retiredRate: Double?
    }

    public struct RoundTrip: Encodable, Sendable, Equatable {
        /// Seats measured.
        public var seats = 0
        /// Each seat's median, and each seat's 95th percentile.
        public var medianMs = Distribution([])
        public var p95Ms = Distribution([])
        /// Of the time measured, the share over the warning (#31).
        public var overWarningShare: Double?
        public var overWarningSeconds = 0.0
        /// Seats whose median was in each band, by its lower edge (ms).
        public var bands: [Count] = []
    }

    public struct RaceAgain: Encodable, Sendable, Equatable {
        /// Players with a result in a closed race, retired players aside.
        public var finishers = 0
        /// ...who queued again within the window (#24: Race again).
        public var requeued = 0
        public var rate: Double?
        public var secondsToRequeue = Distribution([])
    }

    public var from: Int64
    public var to: Int64
    /// Wait from join to fleet lock, for those whose fleet locked; and for those who left first.
    public var queueWait = Distribution([])
    public var queueLeftAfter = Distribution([])
    public var fleets = 0
    public var humansPerFleet: [Count] = []
    public var briefingLeaves = BriefingLeaves()
    public var seats = Seats()
    public var roundTrip = RoundTrip()
    public var raceAgain = RaceAgain()
}

public enum Measures {
    /// The bands of seats' median round trips, by lower edge (ms).
    static let roundTripBands: [Double] = [0, 50, 100, 150, 250]

    /// The measures over `events` (the server's, in the window) and `races` (closed in it).
    public static func report(events: [StoredAnalyticsEvent], races: [ArchivedRace], from: Date, to: Date,
                              settings: MeasuresSettings = MeasuresSettings()) -> MeasuresReport {
        var report = MeasuresReport(from: AdminAPI.seconds(from), to: AdminAPI.seconds(to))
        func number(_ event: StoredAnalyticsEvent, _ key: String) -> Double? {
            switch event.properties[key] {
            case .int(let value): Double(value)
            case .double(let value): value
            default: nil
            }
        }
        func text(_ event: StoredAnalyticsEvent, _ key: String) -> String? {
            if case .string(let value) = event.properties[key] { value } else { nil }
        }
        let named = Dictionary(grouping: events, by: \.name)
        // The queue.
        let waits = named[AnalyticsEventName.queueWait.rawValue] ?? []
        report.queueWait = Distribution(waits.filter { text($0, "outcome") == "matched" }.compactMap { number($0, "waited_s") })
        report.queueLeftAfter = Distribution(waits.filter { text($0, "outcome") == "left" }.compactMap { number($0, "waited_s") })
        let fleets = (named[AnalyticsEventName.fleetLocked.rawValue] ?? []).compactMap { number($0, "humans").map(Int.init) }
        report.fleets = fleets.count
        report.humansPerFleet = Dictionary(grouping: fleets, by: { $0 }).map { MeasuresReport.Count(value: $0.key, count: $0.value.count) }
            .sorted { $0.value < $1.value }
        // Briefing leaves and the cooldowns they cost.
        let leaves = named[AnalyticsEventName.briefingLeave.rawValue] ?? []
        let cooldowns = leaves.compactMap { number($0, "cooldown_s") }.filter { $0 > 0 }
        report.briefingLeaves = .init(leaves: leaves.count, players: Set(leaves.compactMap(\.playerID)).count, cooldowns: cooldowns.count,
                                      cooldownSeconds: cooldowns.reduce(0, +))
        // Round trips.
        let trips = named[AnalyticsEventName.roundTrip.rawValue] ?? []
        let medians = trips.compactMap { number($0, "median_ms") }
        let seconds = trips.compactMap { number($0, "seconds") }.reduce(0, +), over = trips.compactMap { number($0, "over_warning_s") }.reduce(0, +)
        report.roundTrip = .init(seats: trips.count, medianMs: Distribution(medians), p95Ms: Distribution(trips.compactMap { number($0, "p95_ms") }),
                                 overWarningShare: seconds > 0 ? over / seconds : nil, overWarningSeconds: over,
                                 bands: roundTripBands.map { edge in
                                     let next = roundTripBands.first { $0 > edge } ?? .infinity
                                     return MeasuresReport.Count(value: Int(edge), count: medians.filter { $0 >= edge && $0 < next }.count)
                                 })
        // Seats: drops, rejoins and RET from the logs.
        var seats = MeasuresReport.Seats()
        for race in races {
            let humans = Set(race.seating.humans.map(\.seat))
            seats.humanSeats += humans.count
            for event in race.log.seatEvents where humans.contains(event.seat) {
                switch event.kind {
                case .disconnected: seats.disconnects += 1
                case .dropped: seats.drops += 1
                case .rejoined: seats.rejoins += 1
                default: break
                }
            }
            seats.retired += race.summary.rows.filter { humans.contains($0.seat) && $0.code == ResultCode.ret.rawValue }.count
        }
        if seats.humanSeats > 0 {
            seats.dropRate = Double(seats.drops + seats.disconnects) / Double(seats.humanSeats)
            seats.retiredRate = Double(seats.retired) / Double(seats.humanSeats)
        }
        report.seats = seats
        // Race again: a player with a result who queues again soon after her finish.
        let joins = Dictionary(grouping: named[AnalyticsEventName.queueJoined.rawValue] ?? [], by: { $0.playerID ?? "" })
            .mapValues { $0.map(\.occurredAt).sorted() }
        var again = MeasuresReport.RaceAgain(), requeueTimes: [Double] = []
        for race in races {
            for (seat, player) in race.players {
                guard let row = race.summary.rows.first(where: { $0.seat == seat }), row.code != ResultCode.ret.rawValue else { continue }
                again.finishers += 1
                let finishedAt = row.finishTick.map { race.endedAt - Double(race.log.finalTick - $0) / Double(Race.tickRate) } ?? race.endedAt
                if let join = joins[player]?.first(where: { $0 >= finishedAt && $0 <= finishedAt + settings.raceAgainWindow }) {
                    again.requeued += 1
                    requeueTimes.append(join.timeIntervalSince(finishedAt))
                }
            }
        }
        again.rate = again.finishers > 0 ? Double(again.requeued) / Double(again.finishers) : nil
        again.secondsToRequeue = Distribution(requeueTimes)
        report.raceAgain = again
        return report
    }
}

// MARK: - Balance

/// Each seat's start, roundings and finish, by tick, from a replay of the race's log.
public struct RaceSplits: Sendable, Equatable {
    public var started: [Int: Int] = [:]
    public var rounded: [Int: [Int]] = [:]
    public var finished: [Int: Int] = [:]

    public init(started: [Int: Int] = [:], rounded: [Int: [Int]] = [:], finished: [Int: Int] = [:]) {
        self.started = started
        self.rounded = rounded
        self.finished = finished
    }

    /// A finisher's legs, in ticks: start to the first rounding, each rounding to the next, the last to the finish.
    public func legs(of seat: Int) -> [Int]? {
        guard let start = started[seat], let finish = finished[seat] else { return nil }
        let marks = [start] + (rounded[seat] ?? []) + [finish]
        return zip(marks, marks.dropFirst()).map { $1 - $0 }
    }

    /// The race replayed from its log (the same simulation version only), its events read tick by tick.
    public static func replaying(_ log: RaceLog) throws -> RaceSplits {
        var splits = RaceSplits()
        let race = try Replayer.replay(log) { race in
            for event in race.drainEvents() { splits.add(event) }
        }
        for event in race.drainEvents() { splits.add(event) }
        return splits
    }

    mutating func add(_ event: RaceEvent) {
        switch event.kind {
        case .started(let seat): started[seat] = event.tick
        case .rounded(let seat, _): rounded[seat, default: []].append(event.tick)
        case .finished(let seat, _): finished[seat] = event.tick
        default: break
        }
    }
}

/// The balance queries over a window's races (#157, #28). Times in seconds.
public struct BalanceReport: Encodable, Sendable, Equatable {
    public struct Rule: Encodable, Sendable, Equatable {
        /// The rule's number, or "none" for protests that matched no call.
        public var rule: String
        public var calls = 0
        /// Of the calls, those a contact opened.
        public var contactCalls = 0
        /// Protests matched to an incident called under it.
        public var protests = 0
    }

    public struct Splits: Encodable, Sendable, Equatable {
        public var venue: String
        public var conditions: String
        public var races = 0
        /// From the gun to crossing the start, every starter.
        public var start = Distribution([])
        /// Each leg, every finisher.
        public var legs: [Distribution] = []
        /// From the gun to the finish, every finisher.
        public var finish = Distribution([])
    }

    public struct Tier: Encodable, Sendable, Equatable {
        /// "human", a bot tier ("club", "regional", "national"), or "bot" for a bot with no stored skill.
        public var tier: String
        public var seats = 0
        public var finished = 0
        public var finishShare: Double?
        /// Place as a share of the fleet: 0 first, 1 last.
        public var meanPlace: Double?
    }

    public struct Calibration: Encodable, Sendable, Equatable {
        /// The rating gap, the higher-rated player's over the other's: at least `gapFrom`, under `gapTo`.
        public var gapFrom: Double
        public var gapTo: Double
        public var pairs = 0
        /// Glicko's expected score for the higher-rated player, and her actual: 1 ahead, ½ level, 0 behind.
        public var expected: Double?
        public var actual: Double?
    }

    public struct Variance: Encodable, Sendable, Equatable {
        public var playerID: String
        public var races: Int
        /// Place as a share of the fleet (0 first, 1 last) over her last races: its mean and variance.
        public var meanPlace: Double
        public var variance: Double
    }

    public var from: Int64
    public var to: Int64
    /// Races read, and those left out for sailing tuned files (#229).
    public var races = 0
    public var tunedExcluded = 0
    /// Races whose splits couldn't be replayed (another simulation version, a file this build lacks).
    public var unreplayed = 0
    public var rules: [Rule] = []
    public var splits: [Splits] = []
    public var tiers: [Tier] = []
    public var calibration: [Calibration] = []
    public var finishVariance: [Variance] = []
}

public enum BalanceQueries {
    /// Whether the race sailed a tuned copy of any file (#229): a debug practice race's, never an online one's, but a
    /// balance query keeps them out wherever they come from.
    public static func isTuned(_ race: ArchivedRace) -> Bool {
        let setup = race.log.header.setup
        return [setup.boatClass, setup.venue, setup.conditions, setup.rulesConfiguration].contains { $0.tune != nil }
    }

    /// The balance report over `races`, with each race's `splits` where it was replayed and the rating changes of the
    /// rated ones (`ratingChanges`, by race).
    public static func report(races all: [ArchivedRace], splits: [UUID: RaceSplits], ratingChanges: [UUID: [StoredRatingChange]], unreplayed: Int = 0,
                              from: Date, to: Date, settings: MeasuresSettings = MeasuresSettings()) -> BalanceReport {
        let races = all.filter { !isTuned($0) }
        var report = BalanceReport(from: AdminAPI.seconds(from), to: AdminAPI.seconds(to), races: races.count, tunedExcluded: all.count - races.count,
                                   unreplayed: unreplayed)
        // Rule calls and protests per rule.
        var rules: [String: BalanceReport.Rule] = [:]
        for race in races {
            let incidents = race.incidents
            for incident in incidents.incidents {
                guard case .called(let call) = incident.outcome else { continue }
                rules[call.rule.rawValue, default: .init(rule: call.rule.rawValue)].calls += 1
                if incident.trigger == .contact { rules[call.rule.rawValue]?.contactCalls += 1 }
            }
            for protest in incidents.protests {
                var rule = "none"
                if let id = protest.matchedIncidentId, case .called(let call)? = incidents[id]?.outcome { rule = call.rule.rawValue }
                rules[rule, default: .init(rule: rule)].protests += 1
            }
        }
        report.rules = rules.values.sorted { order($0.rule) < order($1.rule) }
        // Splits by venue and conditions.
        var grouped: [String: (venue: String, conditions: String, races: Int, start: [Double], legs: [[Double]], finish: [Double])] = [:]
        for race in races {
            guard let split = splits[race.id] else { continue }
            let setup = race.log.header.setup
            let venue = "\(setup.venue.id)@\(setup.venue.version)", conditions = "\(setup.conditions.id)@\(setup.conditions.version)"
            var group = grouped["\(venue) \(conditions)"] ?? (venue, conditions, 0, [], [], [])
            group.races += 1
            let seconds = { (ticks: Int) in Double(ticks) / Double(Race.tickRate) }
            group.start += split.started.values.map(seconds)
            for seat in split.finished.keys.sorted() {
                guard let legs = split.legs(of: seat), let finish = split.finished[seat] else { continue }
                while group.legs.count < legs.count { group.legs.append([]) }
                for (leg, ticks) in legs.enumerated() { group.legs[leg].append(seconds(ticks)) }
                group.finish.append(seconds(finish))
            }
            grouped["\(venue) \(conditions)"] = group
        }
        report.splits = grouped.sorted { $0.key < $1.key }.map { _, group in
            BalanceReport.Splits(venue: group.venue, conditions: group.conditions, races: group.races, start: Distribution(group.start),
                                 legs: group.legs.map(Distribution.init), finish: Distribution(group.finish))
        }
        // Results by tier.
        var tiers: [String: (seats: Int, finished: Int, places: [Double])] = [:]
        for race in races {
            let fleet = race.summary.rows.count
            let humans = Set(race.players.keys)
            for row in race.summary.rows {
                let tier = humans.contains(row.seat) ? "human" : race.bots.first { $0.seat == row.seat }.map { BotTier.holding(skill: $0.skill).rawValue } ?? "bot"
                var entry = tiers[tier] ?? (0, 0, [])
                entry.seats += 1
                if row.code == ResultCode.finished.rawValue { entry.finished += 1 }
                if fleet > 1 { entry.places.append(Double(row.place - 1) / Double(fleet - 1)) }
                tiers[tier] = entry
            }
        }
        let tierOrder = ["human"] + BotTier.allCases.map(\.rawValue) + ["bot"]
        report.tiers = tiers.sorted { (tierOrder.firstIndex(of: $0.key) ?? .max) < (tierOrder.firstIndex(of: $1.key) ?? .max) }.map { tier, entry in
            BalanceReport.Tier(tier: tier, seats: entry.seats, finished: entry.finished,
                               finishShare: entry.seats > 0 ? Double(entry.finished) / Double(entry.seats) : nil,
                               meanPlace: entry.places.isEmpty ? nil : entry.places.reduce(0, +) / Double(entry.places.count))
        }
        report.calibration = calibration(races.compactMap { ratingChanges[$0.id] }, bucket: settings.calibrationBucket)
        report.finishVariance = finishVariance(races, settings: settings)
        return report
    }

    /// Rules in the rule book's order, then "none".
    private static func order(_ rule: String) -> Int {
        RacingRule.allCases.firstIndex { $0.rawValue == rule } ?? RacingRule.allCases.count
    }

    /// Glicko's expected score against the actual, pair by pair within each rated race, by rating gap: whether a gap of
    /// so much wins as often as the ratings say.
    static func calibration(_ races: [[StoredRatingChange]], bucket: Double) -> [BalanceReport.Calibration] {
        var buckets: [Int: (pairs: Int, expected: Double, actual: Double)] = [:]
        for changes in races {
            for (i, a) in changes.enumerated() {
                for b in changes[(i + 1)...] {
                    let (high, low) = a.before.glicko.rating >= b.before.glicko.rating ? (a, b) : (b, a)
                    let gap = high.before.glicko.rating - low.before.glicko.rating
                    let index = Int((gap / bucket).rounded(.down))
                    var entry = buckets[index] ?? (0, 0, 0)
                    entry.pairs += 1
                    entry.expected += expectedScore(high.before.glicko, against: low.before.glicko)
                    entry.actual += high.place < low.place ? 1 : high.place == low.place ? 0.5 : 0
                    buckets[index] = entry
                }
            }
        }
        return buckets.sorted { $0.key < $1.key }.map { index, entry in
            BalanceReport.Calibration(gapFrom: Double(index) * bucket, gapTo: Double(index + 1) * bucket, pairs: entry.pairs,
                                      expected: entry.expected / Double(entry.pairs), actual: entry.actual / Double(entry.pairs))
        }
    }

    /// Glicko-2's expected score of `player` against `opponent` (ADR 0012): on the Glicko-2 scale, the opponent's
    /// deviation discounting the gap.
    static func expectedScore(_ player: Glicko2, against opponent: Glicko2) -> Double {
        let scale = 173.7178
        let mu = (player.rating - 1500) / scale, muJ = (opponent.rating - 1500) / scale, phiJ = opponent.deviation / scale
        let g = 1 / (1 + 3 * phiJ * phiJ / (Double.pi * Double.pi)).squareRoot()
        return 1 / (1 + exp(-g * (mu - muJ)))
    }

    /// Each player's place, as a share of the fleet, over her last `varianceRaces` races: how much of a result is luck.
    static func finishVariance(_ races: [ArchivedRace], settings: MeasuresSettings) -> [BalanceReport.Variance] {
        var places: [String: [(at: Date, place: Double)]] = [:]
        for race in races {
            let fleet = race.summary.rows.count
            guard fleet > 1 else { continue }
            for (seat, player) in race.players {
                guard let row = race.summary.rows.first(where: { $0.seat == seat }) else { continue }
                places[player, default: []].append((race.endedAt, Double(row.place - 1) / Double(fleet - 1)))
            }
        }
        return places.compactMap { player, all -> BalanceReport.Variance? in
            let last = all.sorted { $0.at > $1.at }.prefix(settings.varianceRaces).map(\.place)
            guard last.count >= settings.minVarianceRaces else { return nil }
            let mean = last.reduce(0, +) / Double(last.count)
            let variance = last.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(last.count)
            return BalanceReport.Variance(playerID: player, races: last.count, meanPlace: mean, variance: variance)
        }.sorted { $0.playerID < $1.playerID }
    }
}

// MARK: - Reading

/// The measures and the balance queries over the stores: what the admin routes answer.
public struct MeasureQueries: Sendable {
    let analytics: any AnalyticsStore
    let archive: any RaceArchive
    let ratings: any RatingBook
    let settings: MeasuresSettings
    let now: @Sendable () -> Date

    /// The measures over the last `days` days: at most 90, the raw events' retention (#28).
    public func measures(days: Int) async throws -> MeasuresReport {
        let to = now(), from = to - TimeInterval(min(max(days, 1), 90)) * 86_400
        let names = [AnalyticsEventName.queueJoined, .queueWait, .fleetLocked, .briefingLeave, .roundTrip].map(\.rawValue)
        return Measures.report(events: try await analytics.serverEvents(named: names, since: from), races: try await races(from: from, to: to).races,
                               from: from, to: to, settings: settings)
    }

    /// The balance queries over the last `days` days (at most a year, the race logs' retention). `splits`: each race is
    /// replayed for its start and leg splits, which takes a while.
    public func balance(days: Int, splits replaying: Bool) async throws -> BalanceReport {
        let to = now(), from = to - TimeInterval(min(max(days, 1), 365)) * 86_400
        let (races, _) = try await races(from: from, to: to)
        var splits: [UUID: RaceSplits] = [:], changes: [UUID: [StoredRatingChange]] = [:], unreplayed = 0
        for race in races where !BalanceQueries.isTuned(race) {
            if replaying {
                do {
                    splits[race.id] = try RaceSplits.replaying(race.log)
                } catch {
                    unreplayed += 1
                }
            }
            if race.summary.rated { changes[race.id] = try await ratings.changes(of: race.id) }
        }
        return BalanceQueries.report(races: races, splits: splits, ratingChanges: changes, unreplayed: unreplayed, from: from, to: to,
                                     settings: settings)
    }

    /// The races closed in the window, the latest `maxRaces` of them; one that can't be read is left out and counted.
    private func races(from: Date, to: Date) async throws -> (races: [ArchivedRace], unread: Int) {
        var races: [ArchivedRace] = [], unread = 0
        for (id, ended) in try await archive.closedRaces(endedFrom: from, to: to).suffix(settings.maxRaces) {
            do {
                if let race = try await archive.archivedRace(id, endedAt: ended) { races.append(race) }
            } catch {
                unread += 1
            }
        }
        return (races, unread)
    }
}
