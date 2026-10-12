import Foundation
import PostgresNIO

// Analytics in Postgres (#156, #28, migration 0012): the raw events for 90 days, and the daily aggregates kept after
// them. A device's events are keyed to its random install id, never to a player; the server's own events are keyed to
// the player they are about. The roll-up counts each raw event once into the aggregates; the purge then deletes raw
// events received before the cut, only once they are counted.

/// Who recorded an event: a device (keyed to its install id) or the server (keyed to a player, or to nobody).
public enum AnalyticsSource: String, Sendable, Equatable, Hashable, CaseIterable {
    case device, server
}

/// A property's value as stored. A number reads back as `int` when it is whole and fits.
public enum StoredAnalyticsValue: Sendable, Equatable, Hashable {
    case int(Int64)
    case double(Double)
    case string(String)
    case bool(Bool)
}

/// One raw event.
public struct StoredAnalyticsEvent: Sendable, Equatable {
    public var source: AnalyticsSource
    /// A device's install id and its count of events: unique together, so a resend is recorded once.
    public var installID: String?
    public var sequence: Int64?
    /// The player a server event is about (teamPlayerID); always nil on a device's event.
    public var playerID: String?
    public var name: String
    /// The day it counts on, days since the epoch (UTC).
    public var day: Int32
    /// What its aggregates are split by: "" or `key=value` pairs (`AnalyticsSegments`).
    public var segment: String
    public var occurredAt: Date
    public var receivedAt: Date
    public var properties: [String: StoredAnalyticsValue]

    public init(source: AnalyticsSource, installID: String? = nil, sequence: Int64? = nil, playerID: String? = nil, name: String,
                day: Int32, segment: String = "", occurredAt: Date, receivedAt: Date, properties: [String: StoredAnalyticsValue] = [:]) {
        self.source = source
        self.installID = installID
        self.sequence = sequence
        self.playerID = playerID
        self.name = name
        self.day = day
        self.segment = segment
        self.occurredAt = occurredAt
        self.receivedAt = receivedAt
        self.properties = properties
    }

    /// The day `date` falls on, days since the epoch (UTC).
    public static func day(of date: Date) -> Int32 { Int32((date.timeIntervalSince1970 / 86_400).rounded(.down)) }
}

/// What recording a device's batch did.
public struct AnalyticsRecordResult: Sendable, Equatable {
    /// Events stored for the first time.
    public var accepted: Int
    /// Events already stored (same install and sequence), left as they were.
    public var duplicates: Int

    public init(accepted: Int, duplicates: Int) {
        self.accepted = accepted
        self.duplicates = duplicates
    }
}

/// One day's count of one event, kept after the purge.
public struct AnalyticsDaily: Sendable, Equatable {
    public var day: Int32
    public var source: AnalyticsSource
    public var name: String
    public var segment: String
    public var events: Int64
    /// Distinct installs (a device's events) or players (the server's) that day; a server event about nobody isn't one.
    public var actors: Int64

    public init(day: Int32, source: AnalyticsSource, name: String, segment: String, events: Int64, actors: Int64) {
        self.day = day
        self.source = source
        self.name = name
        self.segment = segment
        self.events = events
        self.actors = actors
    }
}

/// One day's figures for one property of one event, kept after the purge. A number's are in one row (`value` empty);
/// a flag or a short text gets a row per value, with its count alone.
public struct AnalyticsPropertyStats: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable, Hashable { case number, category }

    public var day: Int32
    public var source: AnalyticsSource
    public var name: String
    public var segment: String
    public var key: String
    public var kind: Kind
    public var value: String
    public var count: Int64
    public var sum: Double?
    public var sumSquares: Double?
    public var min: Double?
    public var max: Double?

    public init(day: Int32, source: AnalyticsSource, name: String, segment: String, key: String, kind: Kind, value: String,
                count: Int64, sum: Double? = nil, sumSquares: Double? = nil, min: Double? = nil, max: Double? = nil) {
        self.day = day
        self.source = source
        self.name = name
        self.segment = segment
        self.key = key
        self.kind = kind
        self.value = value
        self.count = count
        self.sum = sum
        self.sumSquares = sumSquares
        self.min = min
        self.max = max
    }

    public var mean: Double? { sum.map { $0 / Double(count) } }
}

// MARK: - The roll-up's arithmetic

/// How raw events add to the daily aggregates: shared by the Postgres store and the in-memory one.
public enum AnalyticsRollup {
    /// A text property longer than this isn't counted by value (it is kept raw for 90 days, then gone).
    public static let maxCategoryLength = 64

    /// A raw event as the roll-up reads it.
    public struct Event: Sendable, Equatable {
        public var id: Int64
        public var source: AnalyticsSource
        /// The install id or the player; nil for a server event about nobody.
        public var actor: String?
        public var day: Int32
        public var name: String
        public var segment: String
        public var properties: [String: StoredAnalyticsValue]

        public init(id: Int64, source: AnalyticsSource, actor: String?, day: Int32, name: String, segment: String,
                    properties: [String: StoredAnalyticsValue]) {
            self.id = id
            self.source = source
            self.actor = actor
            self.day = day
            self.name = name
            self.segment = segment
            self.properties = properties
        }

        var dayKey: DayKey { DayKey(day: day, source: source, name: name, segment: segment) }
    }

    public struct DayKey: Sendable, Hashable {
        public var day: Int32
        public var source: AnalyticsSource
        public var name: String
        public var segment: String

        public init(day: Int32, source: AnalyticsSource, name: String, segment: String) {
            self.day = day
            self.source = source
            self.name = name
            self.segment = segment
        }
    }

    /// An actor already counted on a day, for an event and segment.
    public struct ActorKey: Sendable, Hashable {
        public var dayKey: DayKey
        public var actor: String

        public init(dayKey: DayKey, actor: String) {
            self.dayKey = dayKey
            self.actor = actor
        }
    }

    public struct PropertyKey: Sendable, Hashable {
        public var dayKey: DayKey
        public var key: String
        public var kind: AnalyticsPropertyStats.Kind
        public var value: String

        public init(dayKey: DayKey, key: String, kind: AnalyticsPropertyStats.Kind, value: String) {
            self.dayKey = dayKey
            self.key = key
            self.kind = kind
            self.value = value
        }
    }

    public struct Stats: Sendable, Equatable {
        public var count: Int64 = 0
        public var sum: Double?
        public var sumSquares: Double?
        public var min: Double?
        public var max: Double?

        public init() {}

        mutating func add(_ number: Double) {
            count += 1
            sum = (sum ?? 0) + number
            sumSquares = (sumSquares ?? 0) + number * number
            min = Swift.min(min ?? number, number)
            max = Swift.max(max ?? number, number)
        }

        public mutating func merge(_ other: Stats) {
            count += other.count
            if let sum = other.sum { self.sum = (self.sum ?? 0) + sum }
            if let squares = other.sumSquares { sumSquares = (sumSquares ?? 0) + squares }
            if let low = other.min { min = Swift.min(min ?? low, low) }
            if let high = other.max { max = Swift.max(max ?? high, high) }
        }
    }

    /// What a set of events adds.
    public struct Delta: Sendable, Equatable {
        public var events: [DayKey: Int64] = [:]
        public var actors: [DayKey: Int64] = [:]
        public var properties: [PropertyKey: Stats] = [:]
    }

    /// What `events` add to the aggregates, given the actors already counted on their days (`alreadyCounted`): each
    /// event once, each actor once a day, each property by its kind. A number that isn't finite, a text over
    /// `maxCategoryLength`, and the segment's own keys aren't counted as properties.
    public static func delta(_ events: [Event], alreadyCounted: Set<ActorKey>) -> Delta {
        var delta = Delta()
        var counted = alreadyCounted
        for event in events {
            let dayKey = event.dayKey
            delta.events[dayKey, default: 0] += 1
            delta.actors[dayKey, default: 0] += 0
            if let actor = event.actor, counted.insert(ActorKey(dayKey: dayKey, actor: actor)).inserted {
                delta.actors[dayKey, default: 0] += 1
            }
            let segmentKeys = AnalyticsSegments.keys(in: event.segment)
            for (key, value) in event.properties where !segmentKeys.contains(key) {
                switch value {
                case .int(let number): delta.properties[PropertyKey(dayKey: dayKey, key: key, kind: .number, value: ""), default: Stats()].add(Double(number))
                case .double(let number) where number.isFinite:
                    delta.properties[PropertyKey(dayKey: dayKey, key: key, kind: .number, value: ""), default: Stats()].add(number)
                case .double: continue
                case .bool(let flag): delta.properties[PropertyKey(dayKey: dayKey, key: key, kind: .category, value: flag ? "true" : "false"), default: Stats()].count += 1
                case .string(let text) where text.count <= maxCategoryLength:
                    delta.properties[PropertyKey(dayKey: dayKey, key: key, kind: .category, value: text), default: Stats()].count += 1
                case .string: continue
                }
            }
        }
        return delta
    }

    /// The actor keys `events` would count, to ask the store which it already has.
    public static func actorKeys(_ events: [Event]) -> Set<ActorKey> {
        Set(events.compactMap { event in event.actor.map { ActorKey(dayKey: event.dayKey, actor: $0) } })
    }
}

/// What an event's aggregates are split by (#28: performance by device model): for each event name, the properties
/// whose values make its segment, written `key=value` and joined by `;` in the order given. An event without a
/// listed property has it as `key=` in its segment; an event name not listed has the segment "".
public enum AnalyticsSegments {
    public static func segment(keys: [String], properties: [String: StoredAnalyticsValue]) -> String {
        keys.map { key in
            let value: String = switch properties[key] {
            case .string(let text)?: String(text.prefix(AnalyticsRollup.maxCategoryLength))
            case .bool(let flag)?: flag ? "true" : "false"
            case .int(let number)?: String(number)
            case .double(let number)?: number.isFinite ? String(number) : ""
            case nil: ""
            }
            return "\(key)=\(value)"
        }.joined(separator: ";")
    }

    /// The keys a segment names.
    public static func keys(in segment: String) -> Set<String> {
        guard !segment.isEmpty else { return [] }
        return Set(segment.split(separator: ";").compactMap { pair in pair.split(separator: "=", maxSplits: 1).first.map(String.init) })
    }
}

// MARK: - JSON

/// The `properties` column's JSON: an object of plain JSON values, so queries read it with `->>`. Written here (not by
/// a JSON encoder) so a double always keeps a decimal point or exponent, and a non-finite one is null.
enum AnalyticsJSON {
    static func object(_ properties: [String: StoredAnalyticsValue]) -> String {
        "{" + properties.sorted { $0.key < $1.key }.map { key, value in string(key) + ":" + encode(value) }.joined(separator: ",") + "}"
    }

    static func encode(_ value: StoredAnalyticsValue) -> String {
        switch value {
        case .int(let number): String(number)
        case .double(let number): number.isFinite ? "\(number)" : "null"
        case .string(let text): string(text)
        case .bool(let flag): flag ? "true" : "false"
        }
    }

    static func string(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            // Postgres's jsonb refuses \u0000 in text.
            case "\0": continue
            case _ where scalar.value < 0x20:
                let hex = String(scalar.value, radix: 16)
                out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// One property as `jsonb_each` and `jsonb_typeof` give it back; nil for a JSON null (a non-finite double).
    static func decode(type: String, text: String?) -> StoredAnalyticsValue? {
        guard let text else { return nil }
        switch type {
        case "string": return .string(text)
        case "boolean": return .bool(text == "true")
        case "number":
            if let whole = Int64(text) { return .int(whole) }
            return Double(text).map(StoredAnalyticsValue.double)
        default: return nil
        }
    }
}

// MARK: - The store

/// The analytics tables (#156, migration 0012).
public struct AnalyticsEventStore: Sendable {
    let database: Database
    public init(_ database: Database) { self.database = database }

    /// The advisory lock the roll-up holds for its transaction: two servers never count the same rows.
    static let rollupLock: Int64 = 156

    /// Stores a device's events. An event whose install and sequence are stored already (or come earlier in the same
    /// call) is left as it was and counted a duplicate. One statement: all of it is stored or none.
    public func recordDevice(_ events: [StoredAnalyticsEvent]) async throws -> AnalyticsRecordResult {
        guard !events.isEmpty else { return AnalyticsRecordResult(accepted: 0, duplicates: 0) }
        precondition(events.allSatisfy { $0.source == .device && $0.installID != nil && $0.sequence != nil && $0.playerID == nil })
        let installs = events.map { $0.installID! }, sequences = events.map { $0.sequence! }
        let names = events.map(\.name), days = events.map(\.day), segments = events.map(\.segment)
        let occurred = events.map(\.occurredAt.timeIntervalSince1970), received = events.map(\.receivedAt.timeIntervalSince1970)
        let properties = events.map { AnalyticsJSON.object($0.properties) }
        let rows = try await database.client.query("""
            INSERT INTO analytics_events (source, install_id, sequence, name, day, segment, occurred_at, received_at, properties)
            SELECT 'device', i, s, n, d, g, to_timestamp(o), to_timestamp(r), p::jsonb
            FROM unnest(\(installs)::text[], \(sequences)::bigint[], \(names)::text[], \(days)::integer[], \(segments)::text[],
                        \(occurred)::double precision[], \(received)::double precision[], \(properties)::text[])
                AS u(i, s, n, d, g, o, r, p)
            ON CONFLICT (install_id, sequence) DO NOTHING
            RETURNING id
            """, logger: database.logger)
        var accepted = 0
        for try await _ in rows.decode(Int64.self) { accepted += 1 }
        return AnalyticsRecordResult(accepted: accepted, duplicates: events.count - accepted)
    }

    /// Stores one of the server's own events. One about a player who isn't stored is stored about nobody.
    public func recordServer(_ event: StoredAnalyticsEvent) async throws {
        precondition(event.source == .server && event.installID == nil && event.sequence == nil)
        let properties = AnalyticsJSON.object(event.properties)
        try await database.client.query("""
            INSERT INTO analytics_events (source, player_id, name, day, segment, occurred_at, received_at, properties)
            SELECT 'server', (SELECT team_player_id FROM players WHERE team_player_id = \(event.playerID)), \(event.name),
                \(event.day), \(event.segment), \(event.occurredAt), \(event.receivedAt), \(properties)::jsonb
            """, logger: database.logger)
    }

    /// Counts up to `limit` raw events not yet counted into the aggregates, oldest first, and marks them. One
    /// transaction under the roll-up lock. Returns how many it counted: fewer than `limit` when it caught up.
    @discardableResult
    public func rollUp(limit: Int) async throws -> Int {
        let logger = database.logger
        return try await database.transaction { connection in
            try await connection.query("SELECT pg_advisory_xact_lock(\(Self.rollupLock))", logger: logger)
            let rows = try await connection.query("""
                SELECT e.id, e.source, COALESCE(e.install_id, e.player_id), e.day, e.name, e.segment, p.key, jsonb_typeof(p.value),
                    p.value #>> '{}'
                FROM (SELECT * FROM analytics_events WHERE NOT rolled_up ORDER BY id LIMIT \(Int64(limit))) e
                LEFT JOIN LATERAL jsonb_each(e.properties) p ON true
                ORDER BY e.id
                """, logger: logger)
            var events: [AnalyticsRollup.Event] = []
            for try await (id, source, actor, day, name, segment, key, type, text)
                in rows.decode((Int64, String, String?, Int32, String, String, String?, String?, String?).self) {
                if events.last?.id != id {
                    events.append(AnalyticsRollup.Event(id: id, source: AnalyticsSource(rawValue: source) ?? .server, actor: actor, day: day,
                                                        name: name, segment: segment, properties: [:]))
                }
                if let key, let type, let value = AnalyticsJSON.decode(type: type, text: text) { events[events.count - 1].properties[key] = value }
            }
            guard !events.isEmpty else { return 0 }

            let wanted = AnalyticsRollup.actorKeys(events)
            var counted: Set<AnalyticsRollup.ActorKey> = []
            if !wanted.isEmpty {
                let keys = Array(wanted)
                let found = try await connection.query("""
                    SELECT DISTINCT source, day, name, segment, COALESCE(install_id, player_id) FROM analytics_events
                    WHERE rolled_up AND (source, day, name, segment, COALESCE(install_id, player_id)) IN (
                        SELECT * FROM unnest(\(keys.map(\.dayKey.source.rawValue))::text[], \(keys.map(\.dayKey.day))::integer[],
                                             \(keys.map(\.dayKey.name))::text[], \(keys.map(\.dayKey.segment))::text[],
                                             \(keys.map(\.actor))::text[]))
                    """, logger: logger)
                for try await (source, day, name, segment, actor) in found.decode((String, Int32, String, String, String).self) {
                    guard let source = AnalyticsSource(rawValue: source) else { continue }
                    counted.insert(AnalyticsRollup.ActorKey(dayKey: AnalyticsRollup.DayKey(day: day, source: source, name: name, segment: segment),
                                                            actor: actor))
                }
            }

            let delta = AnalyticsRollup.delta(events, alreadyCounted: counted)
            let days = Array(delta.events.keys)
            try await connection.query("""
                INSERT INTO analytics_daily (day, source, name, segment, events, actors)
                SELECT * FROM unnest(\(days.map(\.day))::integer[], \(days.map(\.source.rawValue))::text[], \(days.map(\.name))::text[],
                                     \(days.map(\.segment))::text[], \(days.map { delta.events[$0] ?? 0 })::bigint[],
                                     \(days.map { delta.actors[$0] ?? 0 })::bigint[])
                ON CONFLICT (day, source, name, segment) DO UPDATE
                SET events = analytics_daily.events + EXCLUDED.events, actors = analytics_daily.actors + EXCLUDED.actors
                """, logger: logger)

            let numbers = delta.properties.filter { $0.key.kind == .number }.map { ($0.key, $0.value) }
            if !numbers.isEmpty {
                try await connection.query("""
                    INSERT INTO analytics_daily_properties (day, source, name, segment, key, kind, value, count, sum, sum_squares, min, max)
                    SELECT d, s, n, g, k, 'number', '', c, t, q, lo, hi
                    FROM unnest(\(numbers.map(\.0.dayKey.day))::integer[], \(numbers.map(\.0.dayKey.source.rawValue))::text[],
                                \(numbers.map(\.0.dayKey.name))::text[], \(numbers.map(\.0.dayKey.segment))::text[], \(numbers.map(\.0.key))::text[],
                                \(numbers.map(\.1.count))::bigint[], \(numbers.map { $0.1.sum ?? 0 })::double precision[],
                                \(numbers.map { $0.1.sumSquares ?? 0 })::double precision[], \(numbers.map { $0.1.min ?? 0 })::double precision[],
                                \(numbers.map { $0.1.max ?? 0 })::double precision[])
                        AS u(d, s, n, g, k, c, t, q, lo, hi)
                    ON CONFLICT (day, source, name, segment, key, kind, value) DO UPDATE
                    SET count = analytics_daily_properties.count + EXCLUDED.count,
                        sum = analytics_daily_properties.sum + EXCLUDED.sum,
                        sum_squares = analytics_daily_properties.sum_squares + EXCLUDED.sum_squares,
                        min = LEAST(analytics_daily_properties.min, EXCLUDED.min),
                        max = GREATEST(analytics_daily_properties.max, EXCLUDED.max)
                    """, logger: logger)
            }
            let categories = delta.properties.filter { $0.key.kind == .category }.map { ($0.key, $0.value) }
            if !categories.isEmpty {
                try await connection.query("""
                    INSERT INTO analytics_daily_properties (day, source, name, segment, key, kind, value, count)
                    SELECT d, s, n, g, k, 'category', v, c
                    FROM unnest(\(categories.map(\.0.dayKey.day))::integer[], \(categories.map(\.0.dayKey.source.rawValue))::text[],
                                \(categories.map(\.0.dayKey.name))::text[], \(categories.map(\.0.dayKey.segment))::text[],
                                \(categories.map(\.0.key))::text[], \(categories.map(\.0.value))::text[], \(categories.map(\.1.count))::bigint[])
                        AS u(d, s, n, g, k, v, c)
                    ON CONFLICT (day, source, name, segment, key, kind, value) DO UPDATE
                    SET count = analytics_daily_properties.count + EXCLUDED.count
                    """, logger: logger)
            }
            try await connection.query("UPDATE analytics_events SET rolled_up = true WHERE id = ANY(\(events.map(\.id)))", logger: logger)
            return events.count
        }
    }

    /// Deletes the raw events received before `time` that the aggregates have counted (retention: 90 days, #28).
    /// Returns how many.
    @discardableResult
    public func purge(receivedBefore time: Date) async throws -> Int {
        let rows = try await database.client.query("""
            WITH gone AS (DELETE FROM analytics_events WHERE rolled_up AND received_at < \(time) RETURNING 1)
            SELECT count(*) FROM gone
            """, logger: database.logger)
        for try await count in rows.decode(Int64.self) { return Int(count) }
        return 0
    }

    // MARK: Reading

    /// The raw events from `installID`, in sequence order.
    public func deviceEvents(installID: String) async throws -> [StoredAnalyticsEvent] {
        try await events(where: "install_id = \(installID) ORDER BY sequence")
    }

    /// The raw events of the server's that name `name`, oldest first.
    public func serverEvents(named name: String) async throws -> [StoredAnalyticsEvent] {
        try await events(where: "source = 'server' AND name = \(name) ORDER BY id")
    }

    /// How many raw events are stored, counted or not.
    public func rawCount() async throws -> Int {
        let rows = try await database.client.query("SELECT count(*) FROM analytics_events", logger: database.logger)
        for try await count in rows.decode(Int64.self) { return Int(count) }
        return 0
    }

    private func events(where condition: PostgresQuery) async throws -> [StoredAnalyticsEvent] {
        var query = PostgresQuery(unsafeSQL: """
            SELECT id, source, install_id, sequence, player_id, name, day, segment, occurred_at, received_at, properties::text
            FROM analytics_events WHERE
            """)
        query.sql += " " + condition.sql
        query.binds = condition.binds
        let rows = try await database.client.query(query, logger: database.logger)
        var events: [StoredAnalyticsEvent] = []
        for try await row in rows {
            let cells = row.makeRandomAccess()
            func read<T: PostgresDecodable>(_ column: String, _ type: T.Type = T.self) throws -> T { try cells[column].decode(T.self, context: .default) }
            events.append(StoredAnalyticsEvent(
                source: AnalyticsSource(rawValue: try read("source", String.self)) ?? .server, installID: try read("install_id"),
                sequence: try read("sequence"), playerID: try read("player_id"), name: try read("name"), day: try read("day"),
                segment: try read("segment"), occurredAt: try read("occurred_at"), receivedAt: try read("received_at"),
                properties: try await properties(of: try read("id", Int64.self))))
        }
        return events
    }

    private func properties(of id: Int64) async throws -> [String: StoredAnalyticsValue] {
        let rows = try await database.client.query("""
            SELECT p.key, jsonb_typeof(p.value), p.value #>> '{}' FROM analytics_events e, jsonb_each(e.properties) p WHERE e.id = \(id)
            """, logger: database.logger)
        var properties: [String: StoredAnalyticsValue] = [:]
        for try await (key, type, text) in rows.decode((String, String, String?).self) {
            if let value = AnalyticsJSON.decode(type: type, text: text) { properties[key] = value }
        }
        return properties
    }

    /// The daily counts of `name` from `source`, by day then segment.
    public func daily(_ source: AnalyticsSource, _ name: String) async throws -> [AnalyticsDaily] {
        let rows = try await database.client.query("""
            SELECT day, segment, events, actors FROM analytics_daily WHERE source = \(source.rawValue) AND name = \(name) ORDER BY day, segment
            """, logger: database.logger)
        var days: [AnalyticsDaily] = []
        for try await (day, segment, events, actors) in rows.decode((Int32, String, Int64, Int64).self) {
            days.append(AnalyticsDaily(day: day, source: source, name: name, segment: segment, events: events, actors: actors))
        }
        return days
    }

    /// The daily property figures of `name` from `source`, by day, segment, key, kind and value.
    public func dailyProperties(_ source: AnalyticsSource, _ name: String) async throws -> [AnalyticsPropertyStats] {
        let rows = try await database.client.query("""
            SELECT day, segment, key, kind, value, count, sum, sum_squares, min, max FROM analytics_daily_properties
            WHERE source = \(source.rawValue) AND name = \(name) ORDER BY day, segment, key, kind, value
            """, logger: database.logger)
        var stats: [AnalyticsPropertyStats] = []
        for try await (day, segment, key, kind, value, count, sum, squares, low, high)
            in rows.decode((Int32, String, String, String, String, Int64, Double?, Double?, Double?, Double?).self) {
            stats.append(AnalyticsPropertyStats(day: day, source: source, name: name, segment: segment, key: key,
                                                kind: AnalyticsPropertyStats.Kind(rawValue: kind) ?? .category, value: value, count: count,
                                                sum: sum, sumSquares: squares, min: low, max: high))
        }
        return stats
    }
}
