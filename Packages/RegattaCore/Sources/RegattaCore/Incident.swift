/// Two different seats, lower first, so a pair has one spelling whichever way round it was met.
/// Orders by the lower seat, then the higher: the order `IncidentIndex` keeps its keys in.
public struct SeatPair: Sendable, Hashable, Comparable, Codable {
    public let low: Int
    public let high: Int

    public init(_ a: Int, _ b: Int) {
        precondition(a != b, "a seat pair needs two different seats")
        low = min(a, b)
        high = max(a, b)
    }

    public func contains(_ seat: Int) -> Bool { seat == low || seat == high }

    public static func < (l: SeatPair, r: SeatPair) -> Bool {
        l.low != r.low ? l.low < r.low : l.high < r.high
    }

    private enum CodingKeys: String, CodingKey { case low, high }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let low = try c.decode(Int.self, forKey: .low)
        let high = try c.decode(Int.self, forKey: .high)
        guard low < high else {
            throw DecodingError.dataCorruptedError(forKey: .high, in: c, debugDescription: "seat pair \(low), \(high) isn't lower first")
        }
        self.init(low, high)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(low, forKey: .low)
        try c.encode(high, forKey: .high)
    }
}

/// Something that happened between two boats that the rules must decide: a contact or a near miss.
/// Its outcome links to the rule call that decided it, which carries the incident's id back.
public struct Incident: Sendable, Equatable, Codable {
    /// Its index in `IncidentIndex.incidents`: ids count up from 0 in the order incidents open.
    public let id: Int
    /// The tick it happened on.
    public let tick: Int
    /// The leg it happened on: the leg index of the boat the call names, or the parties' leg.
    public let leg: Int
    public let parties: SeatPair
    /// Seats exonerated (rule 43.1), in ascending order.
    public private(set) var exonerated: [Int]
    public var outcome: Outcome

    public enum Outcome: Sendable, Equatable, Codable {
        /// Not decided yet.
        case pending
        /// Decided: no rule was broken.
        case noCall
        /// Decided by this call (`call.incidentId` is the incident's id).
        case called(RuleCall)
    }

    public init(id: Int, tick: Int, leg: Int, parties: SeatPair, exonerated: [Int] = [], outcome: Outcome = .pending) {
        self.id = id
        self.tick = tick
        self.leg = leg
        self.parties = parties
        self.exonerated = []
        self.outcome = outcome
        for seat in exonerated { exonerate(seat) }
    }

    /// Exonerates one of the parties. Keeps `exonerated` sorted and free of repeats.
    public mutating func exonerate(_ seat: Int) {
        precondition(parties.contains(seat), "seat \(seat) isn't a party to incident \(id)")
        guard !exonerated.contains(seat) else { return }
        exonerated.append(seat)
        exonerated.sort()
    }

    private enum CodingKeys: String, CodingKey { case id, tick, leg, parties, exonerated, outcome }

    /// Throws for exonerated seats that aren't parties or aren't ascending, and for a call that names
    /// another incident.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        tick = try c.decode(Int.self, forKey: .tick)
        leg = try c.decode(Int.self, forKey: .leg)
        parties = try c.decode(SeatPair.self, forKey: .parties)
        exonerated = try c.decode([Int].self, forKey: .exonerated)
        outcome = try c.decode(Outcome.self, forKey: .outcome)
        guard exonerated.allSatisfy(parties.contains), zip(exonerated, exonerated.dropFirst()).allSatisfy({ $0 < $1 }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .exonerated, in: c, debugDescription: "incident \(id): exonerated seats must be parties, ascending")
        }
        if case .called(let call) = outcome, call.incidentId != id {
            throw DecodingError.dataCorruptedError(
                forKey: .outcome, in: c, debugDescription: "incident \(id)'s call names incident \(call.incidentId)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(tick, forKey: .tick)
        try c.encode(leg, forKey: .leg)
        try c.encode(parties, forKey: .parties)
        try c.encode(exonerated, forKey: .exonerated)
        try c.encode(outcome, forKey: .outcome)
    }
}

/// Every incident of a race, by id and by the pair of boats in it. Arrays only (ADR 0002): the
/// incidents in id order, and one entry per pair kept sorted by `SeatPair`, looked up by binary
/// search, so nothing depends on hash order. Codable as its incidents alone; the pair entries are
/// rebuilt on decoding.
public struct IncidentIndex: Sendable, Equatable, Codable {
    /// All incidents, `incidents[id]` being the one with that id.
    public private(set) var incidents: [Incident] = []
    /// Sorted by `key`, one per pair that has had an incident.
    private var entries: [Entry] = []

    private struct Entry: Sendable, Equatable {
        let key: SeatPair
        /// Ids of this pair's incidents, ascending.
        var ids: [Int]
    }

    public init() {}

    public var count: Int { incidents.count }

    public subscript(id: Int) -> Incident? {
        incidents.indices.contains(id) ? incidents[id] : nil
    }

    /// Opens a new incident between `a` and `b` with the next id, and returns it.
    @discardableResult
    public mutating func open(between a: Int, and b: Int, tick: Int, leg: Int) -> Incident {
        let incident = Incident(id: incidents.count, tick: tick, leg: leg, parties: SeatPair(a, b))
        add(incident)
        return incident
    }

    /// Replaces the incident with `incident.id`. Its parties, tick and leg can't change.
    public mutating func update(_ incident: Incident) {
        precondition(incidents.indices.contains(incident.id), "no incident \(incident.id)")
        let old = incidents[incident.id]
        precondition(old.parties == incident.parties && old.tick == incident.tick && old.leg == incident.leg,
                     "incident \(incident.id) changed its parties, tick or leg")
        if case .called(let call) = incident.outcome {
            precondition(call.incidentId == incident.id, "incident \(incident.id)'s call names incident \(call.incidentId)")
        }
        incidents[incident.id] = incident
    }

    /// The incidents between `a` and `b`, oldest first.
    public func incidents(between a: Int, and b: Int) -> [Incident] {
        guard a != b, let k = entryIndex(SeatPair(a, b)) else { return [] }
        return entries[k].ids.map { incidents[$0] }
    }

    /// The most recent incident between `a` and `b`, if any.
    public func latest(between a: Int, and b: Int) -> Incident? {
        guard a != b, let k = entryIndex(SeatPair(a, b)), let id = entries[k].ids.last else { return nil }
        return incidents[id]
    }

    /// The pairs that have had an incident, in `SeatPair` order.
    public var pairs: [SeatPair] { entries.map(\.key) }

    private mutating func add(_ incident: Incident) {
        precondition(incident.id == incidents.count, "incident ids count up from 0")
        incidents.append(incident)
        let key = incident.parties
        let at = insertionIndex(key)
        if at < entries.count, entries[at].key == key {
            entries[at].ids.append(incident.id)
        } else {
            entries.insert(Entry(key: key, ids: [incident.id]), at: at)
        }
    }

    /// The first entry whose key isn't below `key`.
    private func insertionIndex(_ key: SeatPair) -> Int {
        var lo = 0, hi = entries.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if entries[mid].key < key { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private func entryIndex(_ key: SeatPair) -> Int? {
        let at = insertionIndex(key)
        return at < entries.count && entries[at].key == key ? at : nil
    }

    private enum CodingKeys: String, CodingKey { case incidents }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try c.decode([Incident].self, forKey: .incidents)
        for (k, incident) in decoded.enumerated() {
            guard incident.id == k else {
                throw DecodingError.dataCorruptedError(
                    forKey: .incidents, in: c, debugDescription: "incident \(k) has id \(incident.id)")
            }
            add(incident)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(incidents, forKey: .incidents)
    }
}
