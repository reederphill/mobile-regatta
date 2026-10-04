/// What a boat hit that isn't another boat and costs her no penalty (#82, #90).
public enum ObstructionKind: String, Sendable, CaseIterable, Codable {
    case land
    /// The race area's drawn boundary.
    case boundary
    /// A mark that isn't a mark of her leg (rule 31, #90: `CourseLayout.isRule31Mark`), or one of her leg
    /// touched in an incident whose call already carries her turn (44.1(a)), or touched exonerated: put on it by
    /// another boat's breach (43.1(a)), or by the boat owing her mark-room failing to give it (43.1(b), #93).
    case mark

    /// The race area's edges (#82), in the order an edge touch lists them: the kinds `RaceEdges` resolves.
    public static let edges: [ObstructionKind] = [.land, .boundary]
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
        /// Touching a mark of her leg (rule 31, #90), which costs her a penalty turn. A touch that costs none
        /// is an `obstructionContact` of kind `.mark`.
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
        /// Seat `seat`'s protest of `target`, recorded (`IncidentIndex.protests`) and acknowledged to her alone
        /// (#94): linked to the pair's incident of the protest window before it (`matchedIncidentId`), or to none.
        /// Never changes a result in v1.0.
        case protestRecorded(seat: Int, target: Int, matchedIncidentId: Int?)
        /// The seat let go of the rudder within a snap width of the groove, and her autohelm took it (#230, #124).
        case grooveSnap(seat: Int)
        /// The seat's roll tap hit, within the class's window of the boom crossing (#263, `RollTack.hit`): for the
        /// roll's cues (#117, #121, #124).
        case rollHit(seat: Int)
        /// The seat's roll tap missed, outside the window (#263, `RollTack.missed`): her speed took the miss factor.
        case rollMissed(seat: Int)

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
