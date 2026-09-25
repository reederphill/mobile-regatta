/// Something the race decided, stamped with the tick it happened on. Seat ids index `Race.boats`.
public struct RaceEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case gun
        case ocs(seat: Int)
        case cleared(seat: Int)
        case started(seat: Int)
        case foul(RuleCall)
        case markTouch(seat: Int, mark: String)
        case penaltyServed(seat: Int)
        /// The boom crossed as the bow passed head to wind.
        case tacked(seat: Int)
        /// The boom crossed downwind.
        case gybed(seat: Int)
        case rounded(seat: Int, mark: String)
        case finished(seat: Int, place: Int)
        case disqualified(seat: Int, reason: String)
        /// A protest tap, acknowledged. Recorded, never changes a result in v1.0.
        case protest(seat: Int, target: Int)
        case raceOver
    }

    public let tick: Int
    public let kind: Kind

    public init(tick: Int, kind: Kind) {
        self.tick = tick
        self.kind = kind
    }
}
