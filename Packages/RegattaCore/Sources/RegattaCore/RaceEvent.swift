public enum RaceEvent: Sendable, Equatable {
    case gun
    case ocs(boat: Int)
    case cleared(boat: Int)
    case started(boat: Int)
    case foul(RuleCall)
    case markTouch(boat: Int, mark: String)
    case penaltyServed(boat: Int)
    case rounded(boat: Int, mark: String)
    case finished(boat: Int, place: Int)
    case disqualified(boat: Int, reason: String)
    case raceOver
}
