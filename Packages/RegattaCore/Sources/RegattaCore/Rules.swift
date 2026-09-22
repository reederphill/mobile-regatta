/// The subset of the Racing Rules of Sailing the simulation enforces.
public enum RacingRule: Int, Sendable, CaseIterable {
    case portStarboard = 10
    case windwardLeeward = 11
    case clearAstern = 12
    case whileTacking = 13
    case markRoom = 18
    case startingAndPenalties = 22
    case touchingMark = 31

    public var title: String {
        switch self {
        case .portStarboard: "Port keeps clear of starboard"
        case .windwardLeeward: "Windward keeps clear of leeward"
        case .clearAstern: "Clear astern keeps clear"
        case .whileTacking: "Keep clear while tacking"
        case .markRoom: "Mark room at the rounding"
        case .startingAndPenalties: "Returning or penalised boats keep clear"
        case .touchingMark: "Touching a mark"
        }
    }
}

public struct RuleCall: Sendable, Equatable {
    public let rule: RacingRule
    public let offender: Int
    public let victim: Int
}

public enum Rules {
    /// Decides which of two boats in contact was required to keep clear.
    public static func judge(_ a: Boat, _ b: Boat, course: Course) -> RuleCall {
        func call(_ rule: RacingRule, _ offender: Boat, _ victim: Boat) -> RuleCall {
            RuleCall(rule: rule, offender: offender.id, victim: victim.id)
        }

        let aMustKeepClear = a.isTakingPenalty || a.status == .ocs
        let bMustKeepClear = b.isTakingPenalty || b.status == .ocs
        if aMustKeepClear != bMustKeepClear {
            return aMustKeepClear ? call(.startingAndPenalties, a, b) : call(.startingAndPenalties, b, a)
        }

        if a.isTacking != b.isTacking {
            return a.isTacking ? call(.whileTacking, a, b) : call(.whileTacking, b, a)
        }

        if a.tack != b.tack {
            return a.tack == .port ? call(.portStarboard, a, b) : call(.portStarboard, b, a)
        }

        let aAstern = isClearAstern(a, of: b)
        let bAstern = isClearAstern(b, of: a)

        if !aAstern && !bAstern, let mark = sharedMarkInZone(a, b, course: course) {
            let aDistance = (a.position - mark).length
            let bDistance = (b.position - mark).length
            return aDistance > bDistance ? call(.markRoom, a, b) : call(.markRoom, b, a)
        }

        if aAstern { return call(.clearAstern, a, b) }
        if bAstern { return call(.clearAstern, b, a) }

        let windward = Vec2.heading(a.windDirection)
        return a.position.dot(windward) > b.position.dot(windward)
            ? call(.windwardLeeward, a, b)
            : call(.windwardLeeward, b, a)
    }

    /// `a` is clear astern of `b` when its whole hull is behind a line abeam of `b`'s stern.
    public static func isClearAstern(_ a: Boat, of b: Boat) -> Bool {
        let stern = b.position - b.forward * Boat.length / 2
        return a.hull().allSatisfy { ($0 - stern).dot(b.forward) < 0 }
    }

    /// The mark both boats are rounding, if both are inside its zone.
    static func sharedMarkInZone(_ a: Boat, _ b: Boat, course: Course) -> Vec2? {
        guard a.status == .racing, b.status == .racing,
              a.legIndex < course.legs.count, b.legIndex < course.legs.count,
              case .round(let ma) = course.legs[a.legIndex],
              case .round(let mb) = course.legs[b.legIndex],
              ma == mb
        else { return nil }
        let mark = course.marks[ma].position
        guard (a.position - mark).length < course.zoneRadius,
              (b.position - mark).length < course.zoneRadius
        else { return nil }
        return mark
    }
}
