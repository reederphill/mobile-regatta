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

/// Something that happened between two boats that the rules must decide: a contact or a near miss (`trigger`).
/// Its outcome links to the rule call that decided it, which carries the incident's id back.
public struct Incident: Sendable, Hashable, Codable {
    /// Its index in `IncidentIndex.incidents`: ids count up from 0 in the order incidents open.
    public let id: Int
    /// The tick it happened on.
    public let tick: Int
    /// The leg it happened on: the leg index of the boat the call names, or the parties' leg.
    public let leg: Int
    public let parties: SeatPair
    /// What opened it: the pair touching, or a near miss (#9).
    public let trigger: Trigger
    /// Seats exonerated (rule 43.1), in ascending order.
    public private(set) var exonerated: [Int]
    public var outcome: Outcome

    /// What opens an incident (#9, #88).
    public enum Trigger: String, Sendable, Hashable, Codable {
        /// The boats touched (`RaceEvent.Kind.contact`).
        case contact
        /// A near miss (`RulesConfig.NearMissSweep`): no contact, but the right-of-way boat's sweep would hit.
        case nearMiss
    }

    public enum Outcome: Sendable, Hashable, Codable {
        /// Not decided yet.
        case pending
        /// Decided: no rule was broken.
        case noCall
        /// Decided by this call (`call.incidentId` is the incident's id).
        case called(RuleCall)
    }

    public init(id: Int, tick: Int, leg: Int, parties: SeatPair, trigger: Trigger = .contact, exonerated: [Int] = [],
                outcome: Outcome = .pending) {
        self.id = id
        self.tick = tick
        self.leg = leg
        self.parties = parties
        self.trigger = trigger
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

    private enum CodingKeys: String, CodingKey { case id, tick, leg, parties, trigger, exonerated, outcome }

    /// Throws for exonerated seats that aren't parties or aren't ascending, and for a call that names
    /// another incident.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        tick = try c.decode(Int.self, forKey: .tick)
        leg = try c.decode(Int.self, forKey: .leg)
        parties = try c.decode(SeatPair.self, forKey: .parties)
        trigger = try c.decode(Trigger.self, forKey: .trigger)
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
        try c.encode(trigger, forKey: .trigger)
        try c.encode(exonerated, forKey: .exonerated)
        try c.encode(outcome, forKey: .outcome)
    }
}

/// A boat touching land or the race area's boundary (#82), or a mark that costs her no turn (#90): recorded,
/// never a foul or a penalty.
public struct ObstructionContact: Sendable, Hashable, Codable {
    /// The tick the touch began on.
    public let tick: Int
    /// The boat's leg index then.
    public let leg: Int
    public let seat: Int
    public let kind: ObstructionKind

    public init(tick: Int, leg: Int, seat: Int, kind: ObstructionKind) {
        self.tick = tick
        self.leg = leg
        self.seat = seat
        self.kind = kind
    }
}

/// Two boats touching (#94): recorded on the tick the contact begins, whether or not it opened an incident.
public struct BoatContact: Sendable, Hashable, Codable {
    /// The tick the contact began on.
    public let tick: Int
    /// The leg of the boat further round the course then: the higher of the pair's leg indexes.
    public let leg: Int
    public let parties: SeatPair
    /// The incident the contact is part of: the one it opened, or the pair's open one. Nil when it opened none.
    public let incidentId: Int?

    public init(tick: Int, leg: Int, parties: SeatPair, incidentId: Int?) {
        self.tick = tick
        self.leg = leg
        self.parties = parties
        self.incidentId = incidentId
    }
}

/// A boat's touch of a mark of her leg that cost her a penalty turn (rule 31, #90, `RaceEvent.Kind.markTouch`).
/// A touch that costs none is an `ObstructionContact` of kind `.mark`.
public struct MarkTouch: Sendable, Hashable, Codable {
    /// The tick the touch began on.
    public let tick: Int
    /// Her leg index then.
    public let leg: Int
    public let seat: Int
    /// The mark's name (`Obstacle.name`).
    public let mark: String

    public init(tick: Int, leg: Int, seat: Int, mark: String) {
        self.tick = tick
        self.leg = leg
        self.seat = seat
        self.mark = mark
    }
}

/// A protest (#9, #94): one boat's claim against another, recorded and never changing a result. Linked to the
/// pair's incident whose last activity (it opening, or a contact in it) was within the protest window before
/// it, or to none.
public struct Protest: Sendable, Hashable, Codable {
    /// The tick the protest tap applied on.
    public let tick: Int
    /// The protester's leg index then.
    public let leg: Int
    public let protester: Int
    public let protested: Int
    /// The incident the protest is about (`UmpireState.matchProtest`), or nil: "no call".
    public let matchedIncidentId: Int?

    public init(tick: Int, leg: Int, protester: Int, protested: Int, matchedIncidentId: Int?) {
        precondition(protester != protested, "a boat can't protest herself")
        self.tick = tick
        self.leg = leg
        self.protester = protester
        self.protested = protested
        self.matchedIncidentId = matchedIncidentId
    }
}

/// A race's incident index (#94): every incident (rule calls, contacts and near misses), by id and by the pair
/// of boats in it, every boat contact, every obstruction contact (land, boundary, unpenalised mark touches),
/// every penalised mark touch and every protest. The authoritative race's record, kept with its log
/// (`RaceLog.incidentIndex`); a prediction records only the incidents and obstruction contacts it predicts.
/// Arrays only (ADR 0002): the incidents in id order, the other records in tick order, and one entry per pair
/// kept sorted by `SeatPair`, looked up by binary search, so nothing depends on hash order. Codable as its
/// records, integers and strings only, so the bytes don't depend on the platform; the pair entries are
/// rebuilt on decoding.
public struct IncidentIndex: Sendable, Hashable, Codable {
    /// All incidents, `incidents[id]` being the one with that id.
    public private(set) var incidents: [Incident] = []
    /// Every touch of land or the boundary, in the order they began: one boat each, so not an `Incident`.
    public private(set) var obstructionContacts: [ObstructionContact] = []
    /// Every contact between two boats, in the order they began (#94).
    public private(set) var contacts: [BoatContact] = []
    /// Every mark touch that cost a turn (rule 31), in the order they began (#94).
    public private(set) var markTouches: [MarkTouch] = []
    /// Every protest, in the order they were made (#94).
    public private(set) var protests: [Protest] = []
    /// Sorted by `key`, one per pair that has had an incident.
    private var entries: [Entry] = []

    private struct Entry: Sendable, Hashable {
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
    public mutating func open(between a: Int, and b: Int, tick: Int, leg: Int, trigger: Incident.Trigger = .contact) -> Incident {
        let incident = Incident(id: incidents.count, tick: tick, leg: leg, parties: SeatPair(a, b), trigger: trigger)
        add(incident)
        return incident
    }

    /// Replaces the incident with `incident.id`. Its parties, tick and leg can't change.
    public mutating func update(_ incident: Incident) {
        precondition(incidents.indices.contains(incident.id), "no incident \(incident.id)")
        let old = incidents[incident.id]
        precondition(old.parties == incident.parties && old.tick == incident.tick && old.leg == incident.leg
                        && old.trigger == incident.trigger,
                     "incident \(incident.id) changed its parties, tick, leg or trigger")
        if case .called(let call) = incident.outcome {
            precondition(call.incidentId == incident.id, "incident \(incident.id)'s call names incident \(call.incidentId)")
        }
        incidents[incident.id] = incident
    }

    /// Records a boat's touch of land or the boundary, after every one before it.
    public mutating func recordObstructionContact(_ contact: ObstructionContact) {
        obstructionContacts.append(contact)
    }

    /// Records two boats' contact, after every one before it. Its incident, when it has one, must be the pair's.
    public mutating func recordBoatContact(_ contact: BoatContact) {
        precondition(contacts.last.map { $0.tick <= contact.tick } ?? true, "boat contacts are recorded in tick order")
        if let id = contact.incidentId {
            precondition(self[id]?.parties == contact.parties, "contact names another pair's incident \(id)")
        }
        contacts.append(contact)
    }

    /// Records a penalised mark touch, after every one before it.
    public mutating func recordMarkTouch(_ touch: MarkTouch) {
        precondition(markTouches.last.map { $0.tick <= touch.tick } ?? true, "mark touches are recorded in tick order")
        markTouches.append(touch)
    }

    /// Records a protest, after every one before it. Its incident, when it has one, must be the pair's and
    /// no later than it.
    public mutating func recordProtest(_ protest: Protest) {
        precondition(protests.last.map { $0.tick <= protest.tick } ?? true, "protests are recorded in tick order")
        if let id = protest.matchedIncidentId {
            precondition(self[id].map { $0.parties == SeatPair(protest.protester, protest.protested) && $0.tick <= protest.tick } ?? false,
                         "protest names incident \(id), not one of its pair's before it")
        }
        protests.append(protest)
    }

    /// The tick of the last boat contact recorded in the incident with `id`, or nil when none was (a near
    /// miss). Searches back from the newest contact.
    public func lastContactTick(inIncident id: Int) -> Int? {
        contacts.last(where: { $0.incidentId == id })?.tick
    }

    /// The protests seat `seat` made, oldest first.
    public func protests(by seat: Int) -> [Protest] { protests.filter { $0.protester == seat } }

    /// The incidents seat `seat` was a party to, in id order.
    public func incidents(involving seat: Int) -> [Incident] { incidents.filter { $0.parties.contains(seat) } }

    /// Forgets the obstruction contacts that began after `tick`: a predicting client's own, on ticks it
    /// sails again from the server's snapshot at `tick`, where they would be recorded twice.
    public mutating func forgetObstructionContacts(after tick: Int) {
        obstructionContacts.removeAll { $0.tick > tick }
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

    private enum CodingKeys: String, CodingKey { case incidents, obstructionContacts, contacts, markTouches, protests }

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
        obstructionContacts = try c.decode([ObstructionContact].self, forKey: .obstructionContacts)
        contacts = try c.decode([BoatContact].self, forKey: .contacts)
        markTouches = try c.decode([MarkTouch].self, forKey: .markTouches)
        protests = try c.decode([Protest].self, forKey: .protests)
        func corrupt(_ key: CodingKeys, _ why: String) -> DecodingError {
            .dataCorruptedError(forKey: key, in: c, debugDescription: why)
        }
        let incidents = self.incidents
        guard zip(contacts, contacts.dropFirst()).allSatisfy({ $0.tick <= $1.tick }),
              contacts.allSatisfy({ contact in
                  contact.incidentId.map { incidents.indices.contains($0) && incidents[$0].parties == contact.parties } ?? true
              })
        else { throw corrupt(.contacts, "boat contacts must be in tick order and name their own pair's incidents") }
        guard zip(markTouches, markTouches.dropFirst()).allSatisfy({ $0.tick <= $1.tick }) else {
            throw corrupt(.markTouches, "mark touches must be in tick order")
        }
        guard zip(protests, protests.dropFirst()).allSatisfy({ $0.tick <= $1.tick }),
              protests.allSatisfy({ protest in
                  protest.protester != protest.protested && (protest.matchedIncidentId.map {
                      incidents.indices.contains($0) && incidents[$0].parties == SeatPair(protest.protester, protest.protested)
                          && incidents[$0].tick <= protest.tick
                  } ?? true)
              })
        else { throw corrupt(.protests, "protests must be in tick order, of another boat, and name their pair's earlier incidents") }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(incidents, forKey: .incidents)
        try c.encode(obstructionContacts, forKey: .obstructionContacts)
        try c.encode(contacts, forKey: .contacts)
        try c.encode(markTouches, forKey: .markTouches)
        try c.encode(protests, forKey: .protests)
    }
}
