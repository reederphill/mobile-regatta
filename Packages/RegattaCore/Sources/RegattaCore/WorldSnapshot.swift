/// The whole predictable world at one tick (ADR 0005): every stored field of every boat, each seat's
/// held input, and the race-level memory the step reads. `Race.importSnapshot(_:)` of
/// `Race.exportSnapshot()` continues bit for bit like the race it came from, given the same inputs,
/// while neither race's umpire holds an incident open.
///
/// It is lossless and in memory only: the wire carries a quantised subset (`RegattaProtocol`), which
/// a receiver merges into its own snapshot. The wind is in it only as the keys held (`windKeys`): the
/// wind is a function of the race clock and the keys (ADR 0001), and keys are public once revealed.
/// Three things are never in it:
/// - the wind seed, which never leaves the race's key generator (ADR 0001);
/// - anything about who sails a seat: bot brains run only where the race is hosted, and a boat's
///   future is its held input, bot or human (#18, #19);
/// - the umpire's memory (`UmpireState`), the authoritative race's own (#88): which incidents are open.
///
/// Later core tickets that add state to `Boat` or to a seat extend this and the wire field list;
/// the coverage tests in both packages fail until they do.
public struct WorldSnapshot: Sendable {
    /// One seat: its boat and the input it holds.
    public struct Seat: Sendable {
        public var boat: Boat
        public var heldInput: BoatInput

        public init(boat: Boat, heldInput: BoatInput) {
            self.boat = boat
            self.heldInput = heldInput
        }
    }

    /// Two seats, `a < b`.
    public struct SeatPair: Hashable, Sendable {
        public let a: Int
        public let b: Int

        public init(_ a: Int, _ b: Int) {
            self.a = a
            self.b = b
        }
    }

    /// A seat touching an obstacle (`CourseLayout.obstacles[obstacle]`).
    public struct ObstacleContact: Hashable, Sendable {
        public let seat: Int
        public let obstacle: Int

        public init(seat: Int, obstacle: Int) {
            self.seat = seat
            self.obstacle = obstacle
        }
    }

    /// A seat touching an edge of the race area: land or the boundary (#82).
    public struct EdgeContact: Hashable, Sendable {
        public let seat: Int
        public let kind: ObstructionKind

        public init(seat: Int, kind: ObstructionKind) {
            self.seat = seat
            self.kind = kind
        }
    }

    /// A pair's overlap as of the last point of certainty, and the ticks in a row its hulls have shown
    /// otherwise (`OverlapTracker`, #87). Never sent to clients: a receiver keeps its own.
    public struct OverlapMemory: Hashable, Sendable {
        public let pair: SeatPair
        public let isOverlapped: Bool
        /// 0 ..< the last point of certainty in ticks.
        public let changeTicks: Int

        public init(pair: SeatPair, isOverlapped: Bool, changeTicks: Int) {
            self.pair = pair
            self.isOverlapped = isOverlapped
            self.changeTicks = changeTicks
        }
    }

    public var tick: Int
    /// Indexed by seat.
    public var seats: [Seat]
    /// Boat pairs in contact at this tick, by `a` then `b`: a contact costs speed once, when it begins.
    public var touchingBoats: [SeatPair]
    /// Seats touching an obstacle at this tick, by seat then obstacle.
    public var touchingObstacles: [ObstacleContact]
    /// Seats touching an edge at this tick, by seat then `ObstructionKind.edges`: a touch slows a boat
    /// most, and is recorded, when it begins.
    public var touchingEdges: [EdgeContact]
    /// Every incident so far: never sent to clients (#18, #96), and a receiver keeps its own. Rule calls
    /// carry their incident's id, so a race that imports goes on numbering from here, and the rules read
    /// past incidents. The whole incident index (#94), protests and contacts too. Which incidents are still open is the umpire's memory (`UmpireState`, #88),
    /// never the world's.
    public var incidents: IncidentIndex
    public var firstFinishTime: Double?
    public var isOver: Bool
    /// The results, once the race has closed (`Race.results`): one row for each seat. A closed race can't
    /// score itself again, since the seat events it reads are the log's, not the world's. Not on the wire:
    /// a client's come in the `raceClosed` event, and its own prediction's are never the result.
    public var results: RaceResults?
    /// The wind keys held (ADR 0001): a race holds every key through the window of `tick`. Importing
    /// needs every key from the window before `tick`'s through the last one held, without a gap, and
    /// they must be this race's.
    public var windKeys: WindKeyChain
    /// The pairs overlapped or changing, by `a` then `b`; every pair not listed is neither.
    public var overlaps: [OverlapMemory]

    /// The latest tick an import accepts: three hours after the gun, far past any race's time limit.
    /// It bounds the work of bringing the wind to the snapshot's tick.
    public static let maxTick = 3 * 60 * 60 * Race.tickRate

    public init(
        tick: Int, seats: [Seat], touchingBoats: [SeatPair] = [], touchingObstacles: [ObstacleContact] = [],
        touchingEdges: [EdgeContact] = [], incidents: IncidentIndex = IncidentIndex(),
        firstFinishTime: Double? = nil, isOver: Bool = false, results: RaceResults? = nil,
        windKeys: WindKeyChain = WindKeyChain(), overlaps: [OverlapMemory] = []
    ) {
        self.tick = tick
        self.seats = seats
        self.touchingBoats = touchingBoats
        self.touchingObstacles = touchingObstacles
        self.touchingEdges = touchingEdges
        self.incidents = incidents
        self.firstFinishTime = firstFinishTime
        self.isOver = isOver
        self.results = results
        self.windKeys = windKeys
        self.overlaps = overlaps
    }
}

public enum WorldSnapshotError: Error, Equatable, Sendable {
    /// The snapshot is for a fleet of another size.
    case seatCount(expected: Int, found: Int)
    /// `seats[seat].boat.id` isn't `seat`.
    case boatID(seat: Int, found: Int)
    /// Before the start of the sequence, `-setup.startSequenceTicks`.
    case tickBeforeStart(Int)
    /// After `WorldSnapshot.maxTick`.
    case tickTooLate(Int)
    /// A boat field the race can't sail from: not finite, or a leg, rounding stage or penalty count
    /// the course doesn't have. Names the seat and the field.
    case invalidBoat(seat: Int, field: String)
    /// A race-level time that isn't finite.
    case invalidTime
    /// Key `window` is missing: the wind at the snapshot's tick needs it, or it is a gap between that
    /// and the last key the snapshot holds.
    case missingWindKey(Int)
    /// A pair or contact naming a seat or obstacle the race doesn't have, a pair with `a >= b`, or edge
    /// contacts out of order or repeated.
    case invalidContact
    /// Incident `id` names a seat or leg the race doesn't have, or happened after the snapshot's tick.
    case invalidIncident(id: Int)
    /// `incidents.obstructionContacts[index]` names a seat or leg the race doesn't have, or happened
    /// after the snapshot's tick.
    case invalidObstructionContact(index: Int)
    /// `incidents.contacts[index]` names a seat, leg or incident the race doesn't have, or happened after
    /// the snapshot's tick (#94).
    case invalidBoatContact(index: Int)
    /// `incidents.markTouches[index]` names a seat or leg the race doesn't have, or happened after the
    /// snapshot's tick (#94).
    case invalidMarkTouch(index: Int)
    /// `incidents.protests[index]` names a seat or leg the race doesn't have, or happened after the snapshot's
    /// tick (#94).
    case invalidProtest(index: Int)
    /// An overlap naming a seat the race doesn't have, a pair with `a >= b` or out of order, or a
    /// change count outside 0 ..< the last point of certainty.
    case invalidOverlap
    /// Results for a race that isn't over, or that aren't exactly one row for each seat.
    case invalidResults
}
