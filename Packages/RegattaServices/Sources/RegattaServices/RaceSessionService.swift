import RegattaCore
import RegattaProtocol

// The player's race, from fleet lock to the rating (#16, #24). The race itself is sailed over the race
// transport (`RegattaClient`); this is everything around it that goes through the service.

/// A race the service knows, opaque here.
public struct RaceID: Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// What hands the player one seat in one online race: the client sends it, unread, to join (`JoinRace`).
public struct RaceToken: Hashable, Sendable {
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) { self.bytes = bytes }

    /// The message that takes the seat.
    public var joinRace: JoinRace { JoinRace(token: bytes) }
}

/// The player's seat in a fleet that has locked, and what its briefing shows (#147; nil on a rejoin's hand-off).
public struct HandOff: Equatable, Sendable {
    public var raceID: RaceID
    public var token: RaceToken
    public var briefing: BriefingPayload?

    public init(raceID: RaceID, token: RaceToken, briefing: BriefingPayload? = nil) {
        self.raceID = raceID
        self.token = token
        self.briefing = briefing
    }
}

/// One boat in the briefing's fleet (#15, #16, #21).
public struct BriefingSeat: Equatable, Sendable {
    public var name: String
    public var isBot: Bool
    /// Locked at fleet lock: the player's stored livery, a bot's drawn one (#21). Sail numbers as the fleet shows them.
    public var livery: Livery
    /// Nil for a bot; 1500 for every human until ratings exist (#151).
    public var rating: Int?

    public init(name: String, isBot: Bool, livery: Livery, rating: Int?) {
        self.name = name
        self.isBot = isBot
        self.livery = livery
        self.rating = rating
    }
}

/// What the 15 s online briefing shows (#130's `BriefingModel`, #15, #16), from fleet lock: the public setup (venue,
/// conditions, class, laps, sequence: the client words the wind, shifts, puffs, current and course from its files), the
/// tide state, the fleet, her seat and the server's timings. Never the wind seed or keys (ADR 0001), a tide graph, a
/// course map or a numeric forecast.
public struct BriefingPayload: Equatable, Sendable {
    public var setup: RaceSetup
    /// The tide state, as `RaceStart.tide` (`.none` until #78's schema 1).
    public var tide: VersionedPayload
    /// By seat.
    public var fleet: [BriefingSeat]
    public var yourSeat: Int
    /// How long the briefing shows (15 s), then the sequence to the gun.
    public var briefingSeconds: Int
    /// From fleet lock to the gun (75 s).
    public var gunInSeconds: Int

    public init(setup: RaceSetup, tide: VersionedPayload = .none, fleet: [BriefingSeat], yourSeat: Int, briefingSeconds: Int, gunInSeconds: Int) {
        self.setup = setup
        self.tide = tide
        self.fleet = fleet
        self.yourSeat = yourSeat
        self.briefingSeconds = briefingSeconds
        self.gunInSeconds = gunInSeconds
    }

    /// Whether `seat` is hers.
    public func isMe(_ seat: Int) -> Bool { seat == yourSeat }
}

/// The server's race clock, in race ticks (`Race.tickRate` a second), when the service last read it.
public struct RaceClockReading: Equatable, Sendable {
    /// The race's tick then. Negative during the start sequence, as in `Race.tick`.
    public var tick: Int
    /// The tick the race is expected to close at, if the server has said.
    public var expectedCloseTick: Int?

    public init(tick: Int, expectedCloseTick: Int? = nil) {
        self.tick = tick
        self.expectedCloseTick = expectedCloseTick
    }
}

/// A race in progress the player can take back control of (#16): the server kept sailing the boat.
public struct RejoinOffer: Equatable, Sendable {
    public var handOff: HandOff
    public var seat: Int
    public var clock: RaceClockReading

    public init(handOff: HandOff, seat: Int, clock: RaceClockReading) {
        self.handOff = handOff
        self.seat = seat
        self.clock = clock
    }
}

/// The incidents one seat was a party to, from the results stream (#24: "your race" lists only incidents
/// involving you, so the server sends a player her own; calls between other boats aren't listed).
public struct SeatIncidents: Equatable, Sendable {
    public var seat: Int
    /// In id order. Each has `seat` as a party.
    public var incidents: [Incident]
    /// Her penalised mark touches (rule 31), in tick order. Each is `seat`'s.
    public var markTouches: [MarkTouch]
    /// Her protests, in tick order. Each has `seat` as the protester (#24 lists only your own).
    public var protests: [Protest]
    /// How many penalty turns she has completed so far (`penaltyServed`): which of the turns her calls and touches
    /// owed were done, oldest first (#133).
    public var turnsServed: Int

    public init(seat: Int, incidents: [Incident], markTouches: [MarkTouch] = [], protests: [Protest] = [], turnsServed: Int = 0) {
        self.seat = seat
        self.incidents = incidents
        self.markTouches = markTouches
        self.protests = protests
        self.turnsServed = turnsServed
    }
}

/// The race's results as the player has them: filling in live as boats finish, fixed when the race closes (#24).
public struct RaceReport: Equatable, Sendable {
    public var raceID: RaceID
    /// The player's own seat.
    public var seat: Int
    /// Who sails each seat, indexed by seat.
    public var roster: [RosterEntry]
    /// Rows for the boats that have a result. While `isClosed` is false these are the finishers so far; at
    /// the close, every seat has one (`RaceResults`).
    public var results: RaceResults
    /// The seats still racing, shown as "sailing". Empty once the race is closed.
    public var sailing: [Int]
    /// Per seat, in seat order.
    public var incidents: [SeatIncidents]
    /// The race has closed: nothing here changes again, and the rating follows.
    public var isClosed: Bool
    /// Every seat the rules have called a foul against so far, ascending: #24's ⚑ on any boat's row, not only on the
    /// boats in her own incidents.
    public var flaggedSeats: [Int]

    public init(
        raceID: RaceID, seat: Int, roster: [RosterEntry], results: RaceResults, sailing: [Int],
        incidents: [SeatIncidents], isClosed: Bool, flaggedSeats: [Int] = []
    ) {
        self.raceID = raceID
        self.seat = seat
        self.roster = roster
        self.results = results
        self.sailing = sailing
        self.incidents = incidents
        self.isClosed = isClosed
        self.flaggedSeats = flaggedSeats
    }
}

/// One item of the results stream.
public enum RaceUpdate: Equatable, Sendable {
    /// Results so far, or the final ones.
    case report(RaceReport)
    /// The race won't be sailed or scored (a server crash, say): no results, no rating change, and it doesn't
    /// count as a completed race (#24, CONTEXT). The stream ends.
    case cancelled(RaceCancelled.Reason)
}

/// A rating on the one ladder (#16).
public struct Rating: Equatable, Sendable {
    public var value: Int
    /// The provisional badge, until the deviation falls below the threshold (about 10 rated races).
    public var isProvisional: Bool

    public init(value: Int, isProvisional: Bool) {
        self.value = value
        self.isProvisional = isProvisional
    }
}

public enum RatingOutcome: Equatable, Sendable {
    /// A rated race: "+12 -> 1532".
    case rated(before: Rating, after: Rating)
    /// "No other humans at the gun, unrated."
    case unrated
}

/// What the race did to the player's rating, pushed when the race closes, to a client already back in the
/// queue or lobby (#24).
public struct RatingChange: Equatable, Sendable {
    public var raceID: RaceID
    public var outcome: RatingOutcome

    public init(raceID: RaceID, outcome: RatingOutcome) {
        self.raceID = raceID
        self.outcome = outcome
    }
}

/// The last race, for the home screen's entry until the next race ends (#24). No older history.
public struct LastRace: Equatable, Sendable {
    public var report: RaceReport
    /// Nil until the rating settles: the home screen then shows a rating-change badge.
    public var rating: RatingChange?

    public init(report: RaceReport, rating: RatingChange?) {
        self.report = report
        self.rating = rating
    }
}

public enum RaceSessionError: Error, Equatable, Sendable {
    /// There is no such race for the player: no fleet has locked for her, or the race she was in is over.
    case noRace
}

public protocol RaceSessionService: Sendable {
    /// The token for the seat in the fleet that has just locked (`QueueState.fleetLocked`).
    /// Throws `RaceSessionError.noRace` when no fleet has locked for the player.
    func handOff() async throws -> HandOff
    /// A fresh token for the seat in the race in progress the player left, and the race clock, to take
    /// back control until the race ends. Throws `RaceSessionError.noRace` when there's no such race.
    func rejoin() async throws -> RejoinOffer
    /// The results of the player's race, live until the close: each item is the state so far. A cancelled
    /// race ends the stream with `.cancelled`.
    func results() -> AsyncStream<RaceUpdate>
    /// Rating changes as the server pushes them, whatever the client is doing then.
    func ratingChanges() -> AsyncStream<RatingChange>
    /// The last race the player finished, nil before her first or when it was cancelled.
    func lastRace() async throws -> LastRace?
}
