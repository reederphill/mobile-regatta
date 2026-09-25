/// What a boat hit that isn't a mark or another boat (#82).
public enum ObstructionKind: String, Sendable, CaseIterable, Codable {
    case land
    /// The race area's drawn boundary.
    case boundary
}

/// Something the race decided, stamped with the tick it happened on. Seat ids index `Race.boats`.
public struct RaceEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case gun
        /// The individual recall notice (rule 29.1), to the boat that was over at the gun.
        case ocsNotice(recipient: Int)
        /// An OCS boat is back on the pre-start side.
        case cleared(seat: Int)
        case started(seat: Int)
        /// A rule call on an incident, with the penalty and its deadlines.
        case ruleCall(RuleCall)
        /// Touching a mark (rule 31).
        case markTouch(seat: Int, mark: String)
        case obstructionContact(seat: Int, kind: ObstructionKind)
        /// Two boats touched. Contact is not itself a foul.
        case contact(SeatPair)
        case penaltyStarted(seat: Int)
        /// A penalty turn given up part way, to be started again.
        case penaltyReset(seat: Int)
        case penaltyServed(seat: Int)
        /// The boom crossed as the bow passed head to wind.
        case tacked(seat: Int)
        /// The boom crossed downwind.
        case gybed(seat: Int)
        case disqualified(seat: Int, reason: String)
        /// The boats that must be told about mark-room at a rounding (#96).
        case markRoomNotice(recipients: [Int])
        /// The boat has stopped racing and is now a ghost.
        case becameGhost(seat: Int)
        case rounded(seat: Int, mark: String)
        case finished(seat: Int, place: Int)
        /// The first boat finished; the finish window closes at `closeTick`.
        case firstFinish(closeTick: Int)
        case raceClosed
        /// A protest tap, acknowledged. Recorded, never changes a result in v1.0.
        case protestRecorded(seat: Int, target: Int)
    }

    public let tick: Int
    public let kind: Kind

    public init(tick: Int, kind: Kind) {
        self.tick = tick
        self.kind = kind
    }
}
