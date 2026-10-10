import RegattaCore

// The race session on the wire (#109, #24): the hand-off token, rejoin and the race clock, the results stream with
// each seat's incident list, cancellation, the rating push and the last race.

/// The seat in a fleet that has locked: the race, the token `JoinRace` sends unread, and the briefing (#147; a rejoin's
/// hand-off has none).
public struct WireHandOff: Equatable, Sendable {
    public var raceID: String
    public var token: [UInt8]
    public var briefing: WireBriefing?

    public init(raceID: String, token: [UInt8], briefing: WireBriefing? = nil) {
        self.raceID = raceID
        self.token = token
        self.briefing = briefing
    }

    func encode(to w: inout WireWriter) throws {
        try w.text(raceID, "raceID")
        try w.blob(token, limit: WireLimit.token, "token")
        try w.optional(briefing) { try $1.encode(to: &$0) }
    }

    init(from r: inout WireReader) throws {
        self.init(raceID: try r.text("raceID"), token: try r.blob(limit: WireLimit.token, "token"),
                  briefing: try r.optional("briefing") { try WireBriefing(from: &$0) })
    }
}

/// One boat in the briefing's fleet (#15, #21): name, bot or not, livery, rating (nil for a bot).
public struct WireBriefingSeat: Equatable, Sendable {
    public var name: String
    public var isBot: Bool
    public var livery: Livery
    public var rating: Int?

    public init(name: String, isBot: Bool, livery: Livery, rating: Int?) {
        self.name = name
        self.isBot = isBot
        self.livery = livery
        self.rating = rating
    }
}

/// The 15 s briefing's data, sent with the hand-off at fleet lock (#147, #130): the public race setup (its seat kinds as
/// the fleet's bot flags, as in `RaceStart`), the tide state, the fleet, her seat, and the server's timings. Never the
/// wind seed or keys: the client derives the wind, shifts, puffs, current and course words from the setup's files.
/// Schema-versioned: a decoder refuses a schema it doesn't know.
public struct WireBriefing: Equatable, Sendable {
    public static let schema: UInt8 = 1

    public var setup: RaceSetup
    public var tide: VersionedPayload
    /// By seat, as many as `setup.seats`; each `isBot` is that seat's kind.
    public var fleet: [WireBriefingSeat]
    public var yourSeat: Int
    public var briefingSeconds: Int
    public var gunInSeconds: Int

    public init(setup: RaceSetup, tide: VersionedPayload, fleet: [WireBriefingSeat], yourSeat: Int, briefingSeconds: Int, gunInSeconds: Int) {
        self.setup = setup
        self.tide = tide
        self.fleet = fleet
        self.yourSeat = yourSeat
        self.briefingSeconds = briefingSeconds
        self.gunInSeconds = gunInSeconds
    }

    func encode(to w: inout WireWriter) throws {
        guard setup.seats.count == fleet.count,
              zip(setup.seats, fleet).allSatisfy({ ($0 == .bot) == $1.isBot }) else { throw WireError.outOfRange("fleet") }
        guard setup.seats.indices.contains(yourSeat) else { throw WireError.outOfRange("yourSeat") }
        w.u8(Self.schema)
        try w.index(yourSeat, "yourSeat")
        try w.string(setup.simulationVersion, limit: WireLimit.string, "simulationVersion")
        w.u64(setup.raceSeed.value)
        try w.count(setup.laps, limit: RaceStart.maxLaps, "laps")
        try w.count(setup.startSequenceTicks, limit: RaceStart.maxStartSequenceTicks, "startSequenceTicks")
        for file in [setup.boatClass, setup.venue, setup.conditions, setup.rulesConfiguration] { try file.encode(to: &w) }
        try w.list(fleet, limit: WireLimit.seats, "fleet") { w, seat in
            w.bool(seat.isBot)
            try w.text(seat.name, "fleet.name")
            try seat.livery.encode(to: &w)
            w.optional(seat.rating) { $0.int($1) }
        }
        try tide.encode(to: &w, "tide")
        try w.count(briefingSeconds, limit: Self.maxSeconds, "briefingSeconds")
        try w.count(gunInSeconds, limit: Self.maxSeconds, "gunInSeconds")
    }

    /// Far beyond a briefing or a start sequence.
    static let maxSeconds = 3600

    init(from r: inout WireReader) throws {
        guard try r.u8() == Self.schema else { throw WireError.invalidValue("briefing.schema") }
        let yourSeat = try r.index()
        let simulationVersion = try r.string(limit: WireLimit.string, "simulationVersion")
        let raceSeed = RaceSeed(try r.u64())
        let laps = try Self.number(&r, limit: RaceStart.maxLaps, "laps")
        let startSequenceTicks = try Self.number(&r, limit: RaceStart.maxStartSequenceTicks, "startSequenceTicks")
        let files = try (0..<4).map { _ in try FileRef(from: &r) }
        let fleet = try r.list(limit: WireLimit.seats, "fleet") { r in
            let isBot = try r.bool("fleet.isBot")
            return WireBriefingSeat(name: try r.text("fleet.name"), isBot: isBot, livery: try Livery(from: &r),
                                    rating: try r.optional("fleet.rating") { try $0.int("fleet.rating") })
        }
        let setup: RaceSetup
        do {
            setup = try RaceSetup(simulationVersion: simulationVersion, raceSeed: raceSeed, seats: fleet.map { $0.isBot ? .bot : .human },
                                  laps: laps, startSequenceTicks: startSequenceTicks, boatClass: files[0], venue: files[1],
                                  conditions: files[2], rulesConfiguration: files[3])
        } catch {
            throw WireError.invalidValue("setup")
        }
        guard setup.seats.indices.contains(yourSeat) else { throw WireError.invalidValue("yourSeat") }
        self.init(setup: setup, tide: try VersionedPayload(from: &r, "tide"), fleet: fleet, yourSeat: yourSeat,
                  briefingSeconds: try Self.number(&r, limit: Self.maxSeconds, "briefingSeconds"),
                  gunInSeconds: try Self.number(&r, limit: Self.maxSeconds, "gunInSeconds"))
    }

    /// A non-negative number up to `limit` (a count's encoding, without `count`'s check against the bytes left).
    private static func number(_ r: inout WireReader, limit: Int, _ field: String) throws -> Int {
        let n = try r.varint(field)
        guard n <= UInt64(limit) else { throw WireError.invalidValue(field) }
        return Int(n)
    }
}

/// A race in progress to take back control of (#16): a fresh hand-off, the seat, and the server's race clock.
public struct WireRejoinOffer: Equatable, Sendable {
    public var handOff: WireHandOff
    public var seat: Int
    public var tick: Int
    public var expectedCloseTick: Int?

    public init(handOff: WireHandOff, seat: Int, tick: Int, expectedCloseTick: Int?) {
        self.handOff = handOff
        self.seat = seat
        self.tick = tick
        self.expectedCloseTick = expectedCloseTick
    }

    func encode(to w: inout WireWriter) throws {
        try handOff.encode(to: &w)
        try w.index(seat, "seat")
        try w.i32(tick, "tick")
        try w.optional(expectedCloseTick) { try $0.i32($1, "expectedCloseTick") }
    }

    init(from r: inout WireReader) throws {
        self.init(handOff: try WireHandOff(from: &r), seat: try r.index(), tick: try r.i32(),
                  expectedCloseTick: try r.optional("expectedCloseTick") { try $0.i32() })
    }
}

/// The incidents, penalised mark touches and protests one seat was a party to (#24), and her turns served (#133).
public struct WireSeatIncidents: Equatable, Sendable {
    public var seat: Int
    public var incidents: [Incident]
    public var markTouches: [MarkTouch]
    public var protests: [Protest]
    public var turnsServed: Int

    public init(seat: Int, incidents: [Incident], markTouches: [MarkTouch], protests: [Protest], turnsServed: Int) {
        self.seat = seat
        self.incidents = incidents
        self.markTouches = markTouches
        self.protests = protests
        self.turnsServed = turnsServed
    }

    func encode(to w: inout WireWriter) throws {
        try w.index(seat, "seat")
        try w.list(incidents, limit: WireLimit.list, "incidents") { try $1.encode(to: &$0) }
        try w.list(markTouches, limit: WireLimit.list, "markTouches") { try $1.encode(to: &$0) }
        try w.list(protests, limit: WireLimit.list, "protests") { try $1.encode(to: &$0) }
        w.int(turnsServed)
    }

    init(from r: inout WireReader) throws {
        self.init(seat: try r.index(), incidents: try r.list(limit: WireLimit.list, "incidents") { try Incident(from: &$0) },
                  markTouches: try r.list(limit: WireLimit.list, "markTouches") { try MarkTouch(from: &$0) },
                  protests: try r.list(limit: WireLimit.list, "protests") { try Protest(from: &$0) },
                  turnsServed: try r.int("turnsServed"))
    }
}

/// The race's results as the player has them, live until the close (#24).
public struct WireRaceReport: Equatable, Sendable {
    public var raceID: String
    public var seat: Int
    public var roster: [RosterEntry]
    public var results: RaceResults
    public var sailing: [Int]
    public var incidents: [WireSeatIncidents]
    public var isClosed: Bool
    public var flaggedSeats: [Int]

    public init(raceID: String, seat: Int, roster: [RosterEntry], results: RaceResults, sailing: [Int],
                incidents: [WireSeatIncidents], isClosed: Bool, flaggedSeats: [Int]) {
        self.raceID = raceID
        self.seat = seat
        self.roster = roster
        self.results = results
        self.sailing = sailing
        self.incidents = incidents
        self.isClosed = isClosed
        self.flaggedSeats = flaggedSeats
    }

    func encode(to w: inout WireWriter) throws {
        try w.text(raceID, "raceID")
        try w.index(seat, "seat")
        try w.list(roster, limit: WireLimit.seats, "roster") { w, entry in
            try w.string(entry.name, limit: WireLimit.string, "roster.name")
            try w.index(entry.colorIndex, "roster.colorIndex")
        }
        try results.encode(to: &w)
        try w.seats(sailing, "sailing")
        try w.list(incidents, limit: WireLimit.seats, "incidents") { try $1.encode(to: &$0) }
        w.bool(isClosed)
        try w.seats(flaggedSeats, "flaggedSeats")
    }

    init(from r: inout WireReader) throws {
        self.init(
            raceID: try r.text("raceID"), seat: try r.index(),
            roster: try r.list(limit: WireLimit.seats, "roster") {
                RosterEntry(name: try $0.string(limit: WireLimit.string, "roster.name"), colorIndex: try $0.index())
            },
            results: try RaceResults(from: &r), sailing: try r.seats("sailing"),
            incidents: try r.list(limit: WireLimit.seats, "incidents") { try WireSeatIncidents(from: &$0) },
            isClosed: try r.bool("isClosed"), flaggedSeats: try r.seats("flaggedSeats"))
    }
}

/// One item of the results stream.
public enum WireRaceUpdate: Equatable, Sendable {
    case report(WireRaceReport)
    /// The race won't be sailed or scored. The reason decodes codes it doesn't know as `.unknown`, as in `RaceCancelled`.
    case cancelled(RaceCancelled.Reason)
}

public enum WireRatingOutcome: Equatable, Sendable {
    case rated(before: WireRating, after: WireRating)
    case unrated
}

/// What a race did to the player's rating, pushed when it closes (#24).
public struct WireRatingChange: Equatable, Sendable {
    public var raceID: String
    public var outcome: WireRatingOutcome

    public init(raceID: String, outcome: WireRatingOutcome) {
        self.raceID = raceID
        self.outcome = outcome
    }

    func encode(to w: inout WireWriter) throws {
        try w.text(raceID, "raceID")
        switch outcome {
        case .rated(let before, let after):
            w.u8(0)
            before.encode(to: &w)
            after.encode(to: &w)
        case .unrated: w.u8(1)
        }
    }

    init(from r: inout WireReader) throws {
        let raceID = try r.text("raceID")
        switch try r.u8() {
        case 0: self.init(raceID: raceID, outcome: .rated(before: try WireRating(from: &r), after: try WireRating(from: &r)))
        case 1: self.init(raceID: raceID, outcome: .unrated)
        default: throw WireError.invalidValue("ratingOutcome")
        }
    }
}

public enum RaceSessionCall: UInt8, Equatable, Sendable, CaseIterable {
    case handOff
    case rejoin
    /// Opens the results stream: no reply; `StreamNext` reads it.
    case openResults
    /// Opens the rating-change stream: no reply; `StreamNext` reads it.
    case openRatingChanges
    case lastRace

    func encode(to w: inout WireWriter) { w.u8(rawValue) }
    init(from r: inout WireReader) throws { self = try r.code("raceSessionCall") }
}

public enum RaceSessionResult: Equatable, Sendable {
    case handOff(WireHandOff)
    case rejoin(WireRejoinOffer)
    /// An item of the results stream.
    case update(WireRaceUpdate)
    /// An item of the rating-change stream.
    case ratingChange(WireRatingChange)
    /// The last race and its rating change, if settled; nil before the first or after a cancelled one.
    case lastRace(report: WireRaceReport, rating: WireRatingChange?)
    case noLastRace
    case noRace

    func encode(to w: inout WireWriter) throws {
        switch self {
        case .handOff(let handOff):
            w.u8(0)
            try handOff.encode(to: &w)
        case .rejoin(let offer):
            w.u8(1)
            try offer.encode(to: &w)
        case .update(.report(let report)):
            w.u8(2)
            try report.encode(to: &w)
        case .update(.cancelled(let reason)):
            w.u8(3)
            w.u8(try reason.canonicalCode())
        case .ratingChange(let change):
            w.u8(4)
            try change.encode(to: &w)
        case .lastRace(let report, let rating):
            w.u8(5)
            try report.encode(to: &w)
            try w.optional(rating) { try $1.encode(to: &$0) }
        case .noLastRace: w.u8(6)
        case .noRace: w.u8(7)
        }
    }

    init(from r: inout WireReader) throws {
        switch try r.u8() {
        case 0: self = .handOff(try WireHandOff(from: &r))
        case 1: self = .rejoin(try WireRejoinOffer(from: &r))
        case 2: self = .update(.report(try WireRaceReport(from: &r)))
        case 3: self = .update(.cancelled(RaceCancelled.Reason(code: try r.u8())))
        case 4: self = .ratingChange(try WireRatingChange(from: &r))
        case 5: self = .lastRace(report: try WireRaceReport(from: &r), rating: try r.optional("rating") { try WireRatingChange(from: &$0) })
        case 6: self = .noLastRace
        case 7: self = .noRace
        default: throw WireError.invalidValue("raceSessionResult")
        }
    }
}

// MARK: - The incident index's records (#94), as a results stream lists them

// An incident: id (u16, as a rule call carries it), tick, leg, the pair low seat first, its trigger (contact 0,
// near miss 1), then one byte of exonerated parties (bit 0 the low seat, bit 1 the high; the rest 0), and its
// outcome: 0 pending, 1 no call, 2 called and the rule call, which names this incident.
extension Incident {
    func encode(to w: inout WireWriter) throws {
        guard let id = UInt16(exactly: id) else { throw WireError.outOfRange("incidentId") }
        w.u16(id)
        try w.i32(tick, "tick")
        try w.index(leg, "leg")
        try w.index(parties.low, "parties")
        try w.index(parties.high, "parties")
        w.u8(trigger == .contact ? 0 : 1)
        w.u8((exonerated.contains(parties.low) ? 1 : 0) | (exonerated.contains(parties.high) ? 2 : 0))
        switch outcome {
        case .pending: w.u8(0)
        case .noCall: w.u8(1)
        case .called(let call):
            guard call.incidentId == Int(id) else { throw WireError.outOfRange("call.incidentId") }
            w.u8(2)
            try call.encode(to: &w)
        }
    }

    init(from r: inout WireReader) throws {
        let id = Int(try r.u16()), tick = try r.i32(), leg = try r.index()
        let low = try r.index(), high = try r.index()
        guard low < high else { throw WireError.invalidValue("parties") }
        let trigger: Trigger
        switch try r.u8() {
        case 0: trigger = .contact
        case 1: trigger = .nearMiss
        default: throw WireError.invalidValue("trigger")
        }
        let exonerated = try r.u8()
        guard exonerated & ~0b11 == 0 else { throw WireError.invalidValue("exonerated") }
        let outcome: Outcome
        switch try r.u8() {
        case 0: outcome = .pending
        case 1: outcome = .noCall
        case 2:
            let call = try RuleCall(from: &r)
            guard call.incidentId == id else { throw WireError.invalidValue("call.incidentId") }
            outcome = .called(call)
        default: throw WireError.invalidValue("outcome")
        }
        self.init(id: id, tick: tick, leg: leg, parties: SeatPair(low, high), trigger: trigger,
                  exonerated: (exonerated & 1 != 0 ? [low] : []) + (exonerated & 2 != 0 ? [high] : []), outcome: outcome)
    }
}

extension MarkTouch {
    func encode(to w: inout WireWriter) throws {
        try w.i32(tick, "tick")
        try w.index(leg, "leg")
        try w.index(seat, "seat")
        try w.text(mark, "mark")
    }

    init(from r: inout WireReader) throws {
        self.init(tick: try r.i32(), leg: try r.index(), seat: try r.index(), mark: try r.text("mark"))
    }
}

// A protest: tick, leg, protester, protested (another seat), then the matched incident as in `protestRecorded`.
extension Protest {
    func encode(to w: inout WireWriter) throws {
        try w.i32(tick, "tick")
        try w.index(leg, "leg")
        try w.index(protester, "protester")
        try w.index(protested, "protested")
        try w.optional(matchedIncidentId) { w, id in
            guard let id = UInt16(exactly: id) else { throw WireError.outOfRange("matchedIncidentId") }
            w.u16(id)
        }
    }

    init(from r: inout WireReader) throws {
        let tick = try r.i32(), leg = try r.index(), protester = try r.index(), protested = try r.index()
        guard protester != protested else { throw WireError.invalidValue("protested") }
        self.init(tick: tick, leg: leg, protester: protester, protested: protested,
                  matchedIncidentId: try r.optional("matchedIncidentId") { Int(try $0.u16()) })
    }
}
