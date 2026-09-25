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

/// Which of two boats must keep clear, and the rule of Part 2 Section A (or rule 13) that says so.
/// Bots read `rule` to pick their manoeuvre, glyphs (#15) to show it.
public struct RightOfWay: Sendable, Equatable {
    /// The seat (boat id) that must keep clear.
    public let keepClear: Int
    public let rule: RacingRule

    public init(keepClear: Int, rule: RacingRule) {
        self.keepClear = keepClear
        self.rule = rule
    }
}

public enum Rules {
    /// Decides which of two boats in contact was required to keep clear. `overlapped` is the pair's
    /// overlap as of the last point of certainty (`OverlapTracker`); `hull` is their boat class's.
    /// Nil if either is a ghost.
    public static func judge(_ a: Boat, _ b: Boat, overlapped: Bool, course: Course, hull: BoatClass.Hull) -> Verdict? {
        guard !a.isGhost, !b.isGhost else { return nil }
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

        guard let right = rightOfWay(a, b, overlapped: overlapped, hull: hull) else { return nil }

        if right.rule == .windwardLeeward || right.rule == .clearAstern,
           !isClearAstern(a, of: b, hull: hull), !isClearAstern(b, of: a, hull: hull),
           let mark = sharedMarkInZone(a, b, course: course) {
            let aDistance = (a.position - mark).length
            let bDistance = (b.position - mark).length
            return aDistance > bDistance ? call(.givingMarkRoom, a, b) : call(.givingMarkRoom, b, a)
        }

        return right.keepClear == a.id ? call(right.rule, a, b) : call(right.rule, b, a)
    }

    /// Which of `a` and `b` must keep clear under rules 10–13, from the world state alone (no rule 18
    /// state yet, #91). `overlapped` is the pair's overlap as of the last point of certainty
    /// (`OverlapTracker`), so a flickering overlap never changes the answer; `hull` is their class's.
    /// Nil if either is a ghost: a ghost has no rights or obligations.
    ///
    /// - 13: a boat tacking keeps clear. If both are, the one astern keeps clear, else the one on the
    ///   other's port side.
    /// - 10: on opposite tacks (by the boom, so never changed by sailing by the lee) port keeps clear.
    /// - 11: overlapped on the same tack, the windward boat keeps clear: the one not on the other's
    ///   leeward side, which is her boom side.
    /// - 12: not overlapped on the same tack, the boat clear astern keeps clear.
    ///
    /// The side tests (leeward side, port side) use the line through both boats along their mean
    /// heading, which agrees with each boat's own centreline whenever those two agree, and decides when
    /// differing headings make them disagree. "Astern" is the boat whose hull reaches least far past a
    /// line abeam of the other's stern (`aftness`): clear astern if she is behind it, and when both or
    /// neither are (headings apart, or an overlap not yet certain), the one further back. An exact tie
    /// makes the higher seat keep clear.
    public static func rightOfWay(_ a: Boat, _ b: Boat, overlapped: Bool, hull: BoatClass.Hull) -> RightOfWay? {
        guard !a.isGhost, !b.isGhost, a.id != b.id else { return nil }
        func keepClear(_ aKeepsClear: Bool?, _ rule: RacingRule) -> RightOfWay {
            let aKeeps = aKeepsClear ?? (a.id > b.id)
            return RightOfWay(keepClear: aKeeps ? a.id : b.id, rule: rule)
        }
        /// Whether `a` is further astern of `b` than `b` of `a`; nil for a tie.
        func aIsAstern() -> Bool? {
            let aAft = aftness(a.hull(outline: hull.outline), of: b, hullLength: hull.length)
            let bAft = aftness(b.hull(outline: hull.outline), of: a, hullLength: hull.length)
            return aAft == bAft ? nil : aAft < bAft
        }
        /// > 0 when `b` is to starboard of `a` across their mean heading, < 0 to port.
        let side = (b.position - a.position).dot((a.forward + b.forward).rightPerp)
        let bToPort: Bool? = side == 0 ? nil : side < 0

        switch (a.isTacking, b.isTacking) {
        case (true, false): return keepClear(true, .whileTacking)
        case (false, true): return keepClear(false, .whileTacking)
        case (true, true):
            // "The one on the other's port side, or the one astern": astern as for rule 12 when the
            // overlap terms apply between them, otherwise in the ordinary sense, when either hull is
            // behind a line abeam of the other's stern.
            let byAstern = !overlapped && (overlapTermsApply(a, b)
                || isClearAstern(a, of: b, hull: hull) || isClearAstern(b, of: a, hull: hull))
            if byAstern, let astern = aIsAstern() { return keepClear(astern, .whileTacking) }
            return keepClear(bToPort.map { !$0 }, .whileTacking)
        case (false, false): break
        }

        if a.tack != b.tack { return keepClear(a.tack == .port, .portStarboard) }

        guard overlapped else { return keepClear(aIsAstern(), .clearAstern) }
        // The same tack, so the same boom side: her leeward side.
        let bToLeeward = bToPort.map { a.boomSide == .port ? $0 : !$0 }
        return keepClear(bToLeeward, .windwardLeeward)
    }

    /// `a` is clear astern of `b` when its whole hull is behind a line abeam of `b`'s stern.
    public static func isClearAstern(_ a: Boat, of b: Boat, hull: BoatClass.Hull) -> Bool {
        aftness(a.hull(outline: hull.outline), of: b, hullLength: hull.length) < 0
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
