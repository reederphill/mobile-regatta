import Foundation
import Persistence
import RegattaServices
import Synchronization

// Usage analytics on the server (#156, #28): first-party, no third party. A device's batches arrive on `/service`
// behind the gate (ADR 0010) and are stored under the batch's random install id alone: the player the connection is
// signed in as is never stored with them. The server's own events (other tickets record them through
// `AnalyticsIngest.record(_:about:)`) are keyed to the player they are about. Raw events are kept 90 days from
// receipt; `AnalyticsRetention` counts them into daily aggregates first, which are kept.

/// What the ingest holds events to, how they are split, and the roll-up and purge's timing.
public struct AnalyticsSettings: Sendable {
    /// Raw events are deleted this long after they arrive, once counted (#28: 90 days, then aggregates only).
    public var rawRetention: TimeInterval = 90 * 86_400
    /// How often the roll-up and the purge run.
    public var rollupInterval: Duration = .seconds(3_600)
    /// The most events one roll-up transaction counts.
    public var rollupBatch = 5_000
    /// An event counts on the day the device says it happened, held to this long before it arrived and never after
    /// (a device's clock can be anything). Within the raw retention, so a day's earlier events are still there to tell
    /// whether an install has been counted on it.
    public var maxEventAge: TimeInterval = 30 * 86_400
    /// Lengths are UTF-8 bytes (a key's text must fit Postgres's index), and NUL is taken out of every text. An event
    /// name over this is cut short.
    public var maxNameLength = 64
    /// The most properties an event keeps, by key order; a key over `maxKeyLength` is dropped.
    public var maxProperties = 32
    public var maxKeyLength = 64
    /// A text value over this is cut short.
    public var maxTextLength = 256
    /// An install id over this is cut short (the device's is a UUID).
    public var maxInstallIDLength = 64
    /// Batches one player may send, over all her connections: a bucket of `batchBurst`, refilled `batchesPerMinute`.
    /// A batch the bucket can't pay for is answered `unavailable`, so the device keeps it and sends it later. Held in
    /// memory only, never with the events.
    public var batchBurst = 10.0
    public var batchesPerMinute = 6.0
    /// How much one day's aggregates hold (`AnalyticsRollup.Bounds`).
    public var bounds = AnalyticsRollup.Bounds()
    /// For each event name, the properties its aggregates are split by (`AnalyticsSegments`): performance by device
    /// model (#28), the practice → online funnel by step (and by tier, once #370 sends it), hints by hint.
    public var segments: [String: [String]] = [
        AnalyticsEventName.performance.rawValue: ["device_model"],
        AnalyticsEventName.practiceToOnline.rawValue: ["step", "tier"],
        AnalyticsEventName.hintRetired.rawValue: ["hint"],
    ]

    public init() {}
}

/// Where analytics are kept: Postgres in production (`AnalyticsEventStore`, migration 0012), memory for a dev server
/// without a database and for tests.
public protocol AnalyticsStore: Sendable {
    /// Stores a device's events, all or none: one already stored (same install and sequence) is a duplicate.
    func recordDevice(_ events: [StoredAnalyticsEvent]) async throws -> AnalyticsRecordResult
    /// Stores one of the server's events: about nobody when its player isn't stored.
    func recordServer(_ event: StoredAnalyticsEvent) async throws
    /// Counts up to `limit` raw events not yet counted into the aggregates, oldest first, held to `bounds`. Returns how
    /// many.
    func rollUp(limit: Int, bounds: AnalyticsRollup.Bounds) async throws -> Int
    /// Deletes the counted raw events received before `time`. Returns how many.
    func purge(receivedBefore time: Date) async throws -> Int
    func daily(_ source: AnalyticsSource, _ name: String) async throws -> [AnalyticsDaily]
    func dailyProperties(_ source: AnalyticsSource, _ name: String) async throws -> [AnalyticsPropertyStats]
}

extension AnalyticsEventStore: AnalyticsStore {}

/// Takes devices' batches and the server's own events into the store.
public final class AnalyticsIngest: Sendable {
    public let settings: AnalyticsSettings
    public let store: any AnalyticsStore
    let now: @Sendable () -> Date
    /// Players whose analytics the dev server answers `unavailable` (the contract's `unavailable` situation).
    private let devUnavailable = Mutex<Set<String>>([])
    /// Each player's batch budget: what is left, and when it was last refilled.
    private let budgets = Mutex<[String: (tokens: Double, at: ContinuousClock.Instant)]>([:])
    /// Past this many players with a budget, those whose bucket has refilled are forgotten.
    static let maxBudgets = 10_000

    public init(settings: AnalyticsSettings = AnalyticsSettings(), store: any AnalyticsStore,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.settings = settings
        self.store = store
        self.now = now
    }

    /// A device's batch: refused whole over `AnalyticsBatch.maxEvents`; otherwise each event held to the limits and
    /// stored under the install id. A store that fails is `unavailable`: the device keeps the batch and sends it again.
    public func record(_ batch: AnalyticsBatch) async throws -> AnalyticsReceipt {
        guard batch.events.count <= AnalyticsBatch.maxEvents else { throw AnalyticsError.batchTooLarge(max: AnalyticsBatch.maxEvents) }
        let received = now()
        let install = InstallID(AnalyticsText.clean(batch.installID.rawValue, maxBytes: settings.maxInstallIDLength))
        let events = batch.events.map { stored($0, installID: install, receivedAt: received) }
        do {
            let result = try await store.recordDevice(events)
            return AnalyticsReceipt(accepted: result.accepted, duplicates: result.duplicates)
        } catch {
            Self.log("can't store a batch of \(events.count): \(error)")
            throw AnalyticsError.unavailable
        }
    }

    /// One of the server's own events (#28: online events keyed to the Game Center player), for other tickets to
    /// record what they measure: `player` is the teamPlayerID it is about, or nil. Held to the same limits as a
    /// device's. Throws when the store fails; a caller doesn't let that stop what it was doing.
    public func record(_ name: AnalyticsEventName, about player: String?, properties: [String: AnalyticsValue] = [:],
                       at time: Date? = nil) async throws {
        let received = now()
        let occurred = min(max(time ?? received, received - settings.maxEventAge), received)
        let kept = held(properties)
        let eventName = AnalyticsText.clean(name.rawValue, maxBytes: settings.maxNameLength)
        try await store.recordServer(StoredAnalyticsEvent(
            source: .server, playerID: player, name: eventName, day: StoredAnalyticsEvent.day(of: occurred),
            segment: segment(eventName, kept), occurredAt: occurred, receivedAt: received, properties: kept))
    }

    /// `event` as stored: its name and properties held to the limits, its time to `maxEventAge` before `receivedAt`
    /// and no later, and its segment from `settings.segments`.
    func stored(_ event: AnalyticsEvent, installID: InstallID, receivedAt: Date) -> StoredAnalyticsEvent {
        let latest = receivedAt.timeIntervalSince1970.rounded(.down)
        let earliest = latest - settings.maxEventAge
        let occurred = Date(timeIntervalSince1970: min(max(Double(event.time), earliest), latest))
        let name = AnalyticsText.clean(event.name.rawValue, maxBytes: settings.maxNameLength)
        let kept = held(event.properties)
        return StoredAnalyticsEvent(source: .device, installID: installID.rawValue, sequence: Int64(event.sequence), name: name,
                                    day: StoredAnalyticsEvent.day(of: occurred), segment: segment(name, kept), occurredAt: occurred,
                                    receivedAt: receivedAt, properties: kept)
    }

    /// The first `maxProperties` keys in order that are short enough and not empty once NUL is taken out; texts cut to
    /// `maxTextLength`, and numbers that aren't finite left out.
    func held(_ properties: [String: AnalyticsValue]) -> [String: StoredAnalyticsValue] {
        var kept: [String: StoredAnalyticsValue] = [:]
        for (raw, value) in properties.sorted(by: { $0.key < $1.key }) {
            let key = AnalyticsText.clean(raw, maxBytes: .max)
            guard !key.isEmpty, key.utf8.count <= settings.maxKeyLength, kept[key] == nil else { continue }
            guard kept.count < settings.maxProperties else { break }
            switch value {
            case .int(let number): kept[key] = .int(Int64(number))
            case .double(let number) where number.isFinite: kept[key] = .double(number)
            case .double: continue
            case .string(let text): kept[key] = .string(AnalyticsText.clean(text, maxBytes: settings.maxTextLength))
            case .bool(let flag): kept[key] = .bool(flag)
            }
        }
        return kept
    }

    /// Takes one batch from `player`'s budget; false when it is spent.
    func payForBatch(_ player: String) -> Bool {
        let now = ContinuousClock.now, burst = settings.batchBurst, perSecond = settings.batchesPerMinute / 60
        func refilled(_ budget: (tokens: Double, at: ContinuousClock.Instant)) -> Double {
            let elapsed = now - budget.at
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            return min(burst, budget.tokens + seconds * perSecond)
        }
        return budgets.withLock { budgets in
            if budgets[player] == nil, budgets.count >= Self.maxBudgets {
                budgets = budgets.filter { refilled($0.value) < burst }
            }
            let tokens = budgets[player].map(refilled) ?? burst
            guard tokens >= 1 else {
                budgets[player] = (tokens, now)
                return false
            }
            budgets[player] = (tokens - 1, now)
            return true
        }
    }

    func segment(_ name: String, _ properties: [String: StoredAnalyticsValue]) -> String {
        guard let keys = settings.segments[name] else { return "" }
        return AnalyticsSegments.segment(keys: keys, properties: properties)
    }

    /// The analytics service for one signed-in connection. `player` is only for the batch budget and the dev switch:
    /// nothing stores it.
    func service(for player: AccountPlayer) -> any AnalyticsTransport {
        ServerAnalyticsTransport(ingest: self, player: player.teamPlayerID)
    }

    /// Dev only (`POST /dev/situation`): the player's analytics are answered `unavailable` from now on.
    func devSetUnavailable(_ player: String) { devUnavailable.withLock { _ = $0.insert(player) } }

    func isDevUnavailable(_ player: String) -> Bool { devUnavailable.withLock { $0.contains(player) } }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("RegattaServer: analytics: \(message)\n".utf8))
    }
}

/// A signed-in connection's analytics: the device's batches, stored under their install id, at most as often as the
/// player's budget allows.
struct ServerAnalyticsTransport: AnalyticsTransport {
    let ingest: AnalyticsIngest
    let player: String

    func send(_ batch: AnalyticsBatch) async throws -> AnalyticsReceipt {
        guard !ingest.isDevUnavailable(player), ingest.payForBatch(player) else { throw AnalyticsError.unavailable }
        return try await ingest.record(batch)
    }
}

/// The roll-up and the purge (#156, #28): every `rollupInterval`, every raw event not yet counted is counted into the
/// daily aggregates, then the counted ones received more than `rawRetention` ago are deleted.
public actor AnalyticsRetention {
    public struct Pass: Sendable, Equatable {
        public var rolledUp: Int
        public var purged: Int

        public init(rolledUp: Int, purged: Int) {
            self.rolledUp = rolledUp
            self.purged = purged
        }
    }

    public nonisolated let settings: AnalyticsSettings
    let store: any AnalyticsStore
    let now: @Sendable () -> Date
    private var task: Task<Void, Never>?

    public init(settings: AnalyticsSettings = AnalyticsSettings(), store: any AnalyticsStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.settings = settings
        self.store = store
        self.now = now
    }

    /// One pass: counts everything not yet counted, then purges what is past the retention. A roll-up that fails
    /// doesn't hold the purge up (it takes only counted rows); the pass then throws the roll-up's error.
    @discardableResult
    public func run() async throws -> Pass {
        var rolledUp = 0
        let batch = max(1, settings.rollupBatch)
        var failure: (any Error)?
        do {
            while true {
                let counted = try await store.rollUp(limit: batch, bounds: settings.bounds)
                rolledUp += counted
                if counted < batch { break }
            }
        } catch {
            failure = error
        }
        let purged = try await store.purge(receivedBefore: now() - settings.rawRetention)
        if let failure { throw failure }
        return Pass(rolledUp: rolledUp, purged: purged)
    }

    /// Runs a pass every `rollupInterval` until `stop()`.
    public func start() {
        guard task == nil else { return }
        let interval = settings.rollupInterval
        task = Task {
            repeat {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                do {
                    try await self.run()
                } catch {
                    AnalyticsIngest.log("the roll-up failed: \(error)")
                }
            } while true
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }
}

/// Analytics in memory: a dev server without a database, and tests. Lost on restart.
public final class InMemoryAnalyticsStore: AnalyticsStore {
    private struct Row {
        var id: Int64
        var event: StoredAnalyticsEvent
        var rolledUp = false

        var actor: String? { event.installID ?? event.playerID }
    }

    private struct State {
        var nextID: Int64 = 1
        var rows: [Row] = []
        var seen: Set<String> = []
        var daily: [AnalyticsRollup.DayKey: (events: Int64, actors: Int64)] = [:]
        var properties: [AnalyticsRollup.PropertyKey: AnalyticsRollup.Stats] = [:]
    }

    private let state = Mutex(State())
    /// Players the store knows: a server event about anyone else is stored about nobody. Nil: every player.
    private let knownPlayers: (@Sendable (String) -> Bool)?

    public init(knownPlayers: (@Sendable (String) -> Bool)? = nil) { self.knownPlayers = knownPlayers }

    public func recordDevice(_ events: [StoredAnalyticsEvent]) async throws -> AnalyticsRecordResult {
        state.withLock { state in
            var result = AnalyticsRecordResult(accepted: 0, duplicates: 0)
            for event in events {
                guard let install = event.installID, let sequence = event.sequence,
                      state.seen.insert("\(install)#\(sequence)").inserted else {
                    result.duplicates += 1
                    continue
                }
                state.rows.append(Row(id: state.nextID, event: event))
                state.nextID += 1
                result.accepted += 1
            }
            return result
        }
    }

    public func recordServer(_ event: StoredAnalyticsEvent) async throws {
        var event = event
        if let player = event.playerID, let knownPlayers, !knownPlayers(player) { event.playerID = nil }
        state.withLock { state in
            state.rows.append(Row(id: state.nextID, event: event))
            state.nextID += 1
        }
    }

    public func rollUp(limit: Int, bounds: AnalyticsRollup.Bounds) async throws -> Int {
        state.withLock { state in
            let pending = state.rows.indices.filter { !state.rows[$0].rolledUp }.prefix(limit)
            guard !pending.isEmpty else { return 0 }
            var existing = AnalyticsRollup.Existing()
            for key in state.daily.keys { existing.add(key) }
            for key in state.properties.keys { existing.add(key) }
            let raw = pending.map { index in
                let row = state.rows[index]
                return AnalyticsRollup.Event(id: row.id, source: row.event.source, actor: row.actor, day: row.event.day,
                                             name: row.event.name, segment: row.event.segment, properties: row.event.properties)
            }
            let events = AnalyticsRollup.bounded(raw, existing: existing, bounds: bounds)
            let counted = Set(state.rows.filter(\.rolledUp).compactMap { row in
                row.actor.map {
                    AnalyticsRollup.ActorKey(dayKey: AnalyticsRollup.DayKey(day: row.event.day, source: row.event.source, name: row.event.name,
                                                                            segment: row.event.segment), actor: $0)
                }
            })
            let delta = AnalyticsRollup.delta(events, alreadyCounted: counted)
            for (key, events) in delta.events {
                let previous = state.daily[key] ?? (0, 0)
                state.daily[key] = (previous.events + events, previous.actors + (delta.actors[key] ?? 0))
            }
            for (key, stats) in delta.properties { state.properties[key, default: AnalyticsRollup.Stats()].merge(stats) }
            for index in pending { state.rows[index].rolledUp = true }
            return pending.count
        }
    }

    /// The server's events about the player become `anonymousID`'s (#160).
    public func anonymise(_ playerID: String, as anonymousID: String) {
        state.withLock { state in
            for index in state.rows.indices where state.rows[index].event.playerID == playerID { state.rows[index].event.playerID = anonymousID }
        }
    }

    public func purge(receivedBefore time: Date) async throws -> Int {
        state.withLock { state in
            let gone = state.rows.filter { $0.rolledUp && $0.event.receivedAt < time }
            state.rows.removeAll { $0.rolledUp && $0.event.receivedAt < time }
            // As in Postgres, a purged event's install and sequence are free again.
            for row in gone { if let install = row.event.installID, let sequence = row.event.sequence { state.seen.remove("\(install)#\(sequence)") } }
            return gone.count
        }
    }

    public func daily(_ source: AnalyticsSource, _ name: String) async throws -> [AnalyticsDaily] {
        state.withLock { state in
            state.daily.filter { $0.key.source == source && $0.key.name == name }
                .map { AnalyticsDaily(day: $0.key.day, source: source, name: name, segment: $0.key.segment, events: $0.value.events, actors: $0.value.actors) }
                .sorted { ($0.day, $0.segment) < ($1.day, $1.segment) }
        }
    }

    public func dailyProperties(_ source: AnalyticsSource, _ name: String) async throws -> [AnalyticsPropertyStats] {
        state.withLock { state in
            state.properties.filter { $0.key.dayKey.source == source && $0.key.dayKey.name == name }
                .map { key, stats in
                    AnalyticsPropertyStats(day: key.dayKey.day, source: source, name: name, segment: key.dayKey.segment, key: key.key,
                                           kind: key.kind, value: key.value, count: stats.count, sum: stats.sum, sumSquares: stats.sumSquares,
                                           min: stats.min, max: stats.max)
                }
                .sorted { ($0.day, $0.segment, $0.key, $0.kind.rawValue, $0.value) < ($1.day, $1.segment, $1.key, $1.kind.rawValue, $1.value) }
        }
    }

    /// Every raw event still kept, oldest first: for tests.
    public func raw() -> [StoredAnalyticsEvent] { state.withLock { $0.rows.map(\.event) } }
}
