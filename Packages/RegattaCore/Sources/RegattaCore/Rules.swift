/// The rules the race calls or records, in 2025 Racing Rules of Sailing numbering: the raw value is
/// the rule's number as the RRS writes it ("16.1", "43.1(a)"). Rule 21 is returning and penalised
/// boats (22 in the 2013–2024 rules; no rule here has that number).
public enum RacingRule: String, Sendable, CaseIterable, Codable {
    case portStarboard = "10"
    case windwardLeeward = "11"
    case clearAstern = "12"
    case whileTacking = "13"
    case acquiringRightOfWay = "15"
    case changingCourse = "16.1"
    case markRoomApplies = "18.1"
    case givingMarkRoom = "18.2"
    case tackingInTheZone = "18.3"
    case returningToStart = "21.1"
    case takingAPenalty = "21.2"
    case sailingTheCourse = "28"
    /// The individual recall notice (#85): a notice to the boat, never a foul.
    case individualRecall = "29.1"
    case touchingMark = "31"
    /// Exoneration: compelled to break a rule by another boat's breach.
    case exoneratedCompelled = "43.1(a)"
    /// Exoneration: sailing within the room or mark-room she was entitled to.
    case exoneratedEntitledRoom = "43.1(b)"

    public var title: String {
        switch self {
        case .portStarboard: "Port keeps clear of starboard"
        case .windwardLeeward: "Windward keeps clear of leeward"
        case .clearAstern: "Clear astern keeps clear"
        case .whileTacking: "Keep clear while tacking"
        case .acquiringRightOfWay: "Acquiring right of way"
        case .changingCourse: "Changing course"
        case .markRoomApplies: "When mark-room applies"
        case .givingMarkRoom: "Giving mark-room"
        case .tackingInTheZone: "Tacking in the zone"
        case .returningToStart: "Returning boats keep clear"
        case .takingAPenalty: "Penalised boats keep clear"
        case .sailingTheCourse: "Sailing the course"
        case .individualRecall: "Individual recall"
        case .touchingMark: "Touching a mark"
        case .exoneratedCompelled: "Exonerated: compelled by another boat's breach"
        case .exoneratedEntitledRoom: "Exonerated: sailing within room or mark-room"
        }
    }
}

/// Who broke which rule against whom, as `Rules.judge` decides it.
public struct Verdict: Sendable, Equatable {
    public let rule: RacingRule
    public let offender: Int
    public let victim: Int

    public init(rule: RacingRule, offender: Int, victim: Int) {
        self.rule = rule
        self.offender = offender
        self.victim = victim
    }
}

/// A rule call: the race's decision on an incident (the `Incident` with id `incidentId`) and the
/// penalty it sets. Seats index `Race.boats`; ticks are race ticks.
public struct RuleCall: Sendable, Equatable, Codable {
    public let incidentId: Int
    public let tick: Int
    public let rule: RacingRule
    public let offender: Int
    public let victim: Int
    /// The offender's leg index at the call.
    public let leg: Int
    public let turnsOwed: Int
    /// The tick by which the offender must have started her penalty.
    public let startDeadlineTick: Int
    /// The tick by which she must have completed it.
    public let completeDeadlineTick: Int

    public init(incidentId: Int, tick: Int, rule: RacingRule, offender: Int, victim: Int, leg: Int,
                turnsOwed: Int, startDeadlineTick: Int, completeDeadlineTick: Int) {
        self.incidentId = incidentId
        self.tick = tick
        self.rule = rule
        self.offender = offender
        self.victim = victim
        self.leg = leg
        self.turnsOwed = turnsOwed
        self.startDeadlineTick = startDeadlineTick
        self.completeDeadlineTick = completeDeadlineTick
    }
}

public enum Rules {
    /// Decides which of two boats in contact was required to keep clear. `hull` is their boat class's.
    public static func judge(_ a: Boat, _ b: Boat, course: Course, hull: BoatClass.Hull) -> Verdict {
        func call(_ rule: RacingRule, _ offender: Boat, _ victim: Boat) -> Verdict {
            Verdict(rule: rule, offender: offender.id, victim: victim.id)
        }
        /// Rule 21: a boat returning to start (21.1) or taking a penalty (21.2) keeps clear.
        func rule21(_ boat: Boat) -> RacingRule { boat.status == .ocs ? .returningToStart : .takingAPenalty }

        let aMustKeepClear = a.isTakingPenalty || a.status == .ocs
        let bMustKeepClear = b.isTakingPenalty || b.status == .ocs
        if aMustKeepClear != bMustKeepClear {
            return aMustKeepClear ? call(rule21(a), a, b) : call(rule21(b), b, a)
        }

        if a.isTacking != b.isTacking {
            return a.isTacking ? call(.whileTacking, a, b) : call(.whileTacking, b, a)
        }

        if a.tack != b.tack {
            return a.tack == .port ? call(.portStarboard, a, b) : call(.portStarboard, b, a)
        }

        let aAstern = isClearAstern(a, of: b, hull: hull)
        let bAstern = isClearAstern(b, of: a, hull: hull)

        if !aAstern && !bAstern, let mark = sharedMarkInZone(a, b, course: course) {
            let aDistance = (a.position - mark).length
            let bDistance = (b.position - mark).length
            return aDistance > bDistance ? call(.givingMarkRoom, a, b) : call(.givingMarkRoom, b, a)
        }

        if aAstern { return call(.clearAstern, a, b) }
        if bAstern { return call(.clearAstern, b, a) }

        let windward = Vec2.heading(a.windDirection)
        return a.position.dot(windward) > b.position.dot(windward)
            ? call(.windwardLeeward, a, b)
            : call(.windwardLeeward, b, a)
    }

    /// `a` is clear astern of `b` when its whole hull is behind a line abeam of `b`'s stern.
    public static func isClearAstern(_ a: Boat, of b: Boat, hull: BoatClass.Hull) -> Bool {
        let stern = b.position - b.forward * hull.length / 2
        return a.hull(outline: hull.outline).allSatisfy { ($0 - stern).dot(b.forward) < 0 }
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
