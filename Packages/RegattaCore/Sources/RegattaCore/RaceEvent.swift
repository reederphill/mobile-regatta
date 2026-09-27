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
        /// A new rule 18 record (#91, `MarkRoomRecord`): `boat` is entitled to mark-room at `mark` (its name)
        /// from `entitledOver`, who must give it. Told to those two boats only (#15), and never right of way.
        case markRoomNotice(boat: Int, entitledOver: Int, mark: String)
        /// The boat has stopped racing and is now a ghost (#30, `Race.isGhost(seat:)`): as she finishes, at the
        /// DSQ call, or, still OCS or never started, at the close, just before `raceClosed`.
        case becameGhost(seat: Int)
        case rounded(seat: Int, mark: String)
        case finished(seat: Int, place: Int)
        /// The first boat finished; the finish window closes at `closeTick` (`Race.closeTick`, #8).
        case firstFinish(closeTick: Int)
        /// The race closed and is scored (`Race.results`).
        case raceClosed(results: RaceResults)
        /// A protest tap, acknowledged. Recorded, never changes a result in v1.0.
        case protestRecorded(seat: Int, target: Int)
        /// The seat let go of the rudder within a snap width of the groove, and her autohelm took it (#230, #124).
        case grooveSnap(seat: Int)

        /// A decision of the umpire or race committee under the rules: a rule call, a recall, a
        /// disqualification, a mark-room notice, a protest recorded. Only the authoritative race emits
        /// them; a prediction never does (`Race.Mode`).
        public var isRuleEvent: Bool {
            switch self {
            case .ruleCall, .ocsNotice, .disqualified, .markRoomNotice, .protestRecorded: true
            default: false
            }
        }
    }

    public let tick: Int
    public let kind: Kind

    public init(tick: Int, kind: Kind) {
        self.tick = tick
        self.kind = kind
    }
}
