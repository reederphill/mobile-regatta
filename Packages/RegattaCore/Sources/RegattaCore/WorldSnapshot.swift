/// The whole predictable world at one tick (ADR 0005): every stored field of every boat, each seat's
/// held input, and the race-level memory the step reads. `Race.importSnapshot(_:)` of
/// `Race.exportSnapshot()` continues bit for bit like the race it came from, given the same inputs.
///
/// It is lossless and in memory only: the wire carries a quantised subset (`RegattaProtocol`), which
/// a receiver merges into its own snapshot. Two things are never in it:
/// - the wind, which is a function of the race clock and the wind's keys (ADR 0001), never state
///   that travels; an importing race brings its own wind to the snapshot's tick;
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

    /// A seat touching an obstacle (`Course.obstacles[obstacle]`).
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

    public var tick: Int
    /// Indexed by seat.
    public var seats: [Seat]
    /// Boat pairs in contact at this tick, by `a` then `b`: a contact costs speed once, when it begins.
    public var boatContacts: [SeatPair]
    /// Seats touching an obstacle at this tick, by seat then obstacle.
    public var obstacleContacts: [ObstacleContact]
    /// By pair.
    public var foulMemory: [FoulMemory]
    public var firstFinishTime: Double?
    public var isOver: Bool

    public init(
        tick: Int, seats: [Seat], boatContacts: [SeatPair] = [], obstacleContacts: [ObstacleContact] = [],
        foulMemory: [FoulMemory] = [], firstFinishTime: Double? = nil, isOver: Bool = false
    ) {
        self.tick = tick
        self.seats = seats
        self.boatContacts = boatContacts
        self.obstacleContacts = obstacleContacts
        self.foulMemory = foulMemory
        self.firstFinishTime = firstFinishTime
        self.isOver = isOver
    }
}

public enum WorldSnapshotError: Error, Equatable, Sendable {
    /// The snapshot is for a fleet of another size.
    case seatCount(expected: Int, found: Int)
    /// `seats[seat].boat.id` isn't `seat`.
    case boatID(seat: Int, found: Int)
    /// Before the start of the sequence, `-setup.startSequenceTicks`.
    case tickBeforeStart(Int)
    /// A pair or contact naming a seat or obstacle the race doesn't have, or a pair with `a >= b`.
    case invalidContact
}
