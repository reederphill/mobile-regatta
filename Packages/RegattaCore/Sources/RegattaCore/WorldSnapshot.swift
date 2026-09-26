/// The whole predictable world at one tick (ADR 0005): every stored field of every boat, each seat's
/// held input, and the race-level memory the step reads. `Race.importSnapshot(_:)` of
/// `Race.exportSnapshot()` continues bit for bit like the race it came from, given the same inputs.
///
/// It is lossless and in memory only: the wire carries a quantised subset (`RegattaProtocol`), which
/// a receiver merges into its own snapshot. The wind is in it only as the keys held (`windKeys`): the
/// wind is a function of the race clock and the keys (ADR 0001), and keys are public once revealed.
/// Two things are never in it:
/// - the wind seed, which never leaves the race's key generator (ADR 0001);
/// - anything about who sails a seat: bot brains run only where the race is hosted, and a boat's
///   future is its held input, bot or human (#18, #19).
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

    /// When a pair was last called for a foul, in race seconds. Umpire memory: it stays where the race
    /// is judged and is never sent to clients (#18); a receiver keeps its own.
    public struct FoulMemory: Hashable, Sendable {
        public let pair: SeatPair
        public let time: Double

        public init(pair: SeatPair, time: Double) {
            self.pair = pair
            self.time = time
        }
    }

    /// A pair's overlap as of the last point of certainty, and the ticks in a row its hulls have shown
    /// otherwise (`OverlapTracker`, #87). Like foul memory, never sent to clients: a receiver keeps its own.
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
    /// By pair.
    public var foulMemory: [FoulMemory]
    /// Every incident so far. Umpire memory like `foulMemory`: never sent to clients (#18, #96), and a
    /// receiver keeps its own. Rule calls carry their incident's id, so a race that imports goes on
    /// numbering from here, and the rules read past incidents (#88, #94).
    public var incidents: IncidentIndex
    public var firstFinishTime: Double?
    public var isOver: Bool
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
        foulMemory: [FoulMemory] = [], incidents: IncidentIndex = IncidentIndex(), firstFinishTime: Double? = nil,
        isOver: Bool = false, windKeys: WindKeyChain = WindKeyChain(),
        overlaps: [OverlapMemory] = []
    ) {
        self.tick = tick
        self.seats = seats
        self.touchingBoats = touchingBoats
        self.touchingObstacles = touchingObstacles
        self.foulMemory = foulMemory
        self.incidents = incidents
        self.firstFinishTime = firstFinishTime
        self.isOver = isOver
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
    /// A pair or contact naming a seat or obstacle the race doesn't have, or a pair with `a >= b`.
    case invalidContact
    /// Incident `id` names a seat or leg the race doesn't have, or happened after the snapshot's tick.
    case invalidIncident(id: Int)
    /// An overlap naming a seat the race doesn't have, a pair with `a >= b` or out of order, or a
    /// change count outside 0 ..< the last point of certainty.
    case invalidOverlap
}
