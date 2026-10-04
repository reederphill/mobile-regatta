// Rule 18, mark-room (#91; RRS Part 2 Section C in 2025 numbering, as #9 resolved it). Mark-room is not right
// of way (Case 25): Section A (`Rules.rightOfWay`) still decides which boat keeps clear, and a record here says
// only which boat must give the other room to sail to the mark, round it and leave it astern (18.2). The umpire
// keeps the records (`UmpireState`, the authoritative race's alone). An incident between the pair reads the
// record (`EscapeSimulation.verdict`, #93): the owing boat breaks 18.2 (or 18.3) when Section A names the entitled
// boat to keep clear, who is exonerated (43.1(b)), unless the owing boat has been unable to give room since an
// inside overlap gained from clear astern or by tacking began (18.2(d)).

/// The mark whose zone rule 18 tests a boat against on one tick, and how near it her hull is
/// (`CourseLayout.markZone(of:hull:)`, #91).
public struct MarkZone: Sendable, Equatable {
    public let mark: CourseLayout.Mark
    /// The side she leaves it on: as she rounds it, or as she finishes (downwind across the line, the pin to
    /// starboard and the committee boat to port).
    public let side: RoundingSide
    /// Metres from the mark's centre to the nearest point of her hull, 0 when it is inside her hull.
    public let distance: Double
    /// Whether any part of her hull is in the zone (#9): within the course's `zoneRadius` of the mark.
    public let isIn: Bool
}

extension CourseLayout {
    /// The mark whose zone rule 18 tests `boat` against (#91), with her hull `hull` (world coordinates): the
    /// mark of the leg she is racing, the nearer of a gate's two, or on the finish leg the nearer end of the
    /// finish line (Section C's preamble: rule 18 is on at a finishing mark). Nil unless she is racing: before
    /// she has started, or OCS, she is approaching the starting marks to start, where Section C is off, and a
    /// ghost has no rights or obligations. The nearer mark is by centres; an exact tie takes the first.
    public func markZone(of boat: Boat, hull: [Vec2]) -> MarkZone? {
        guard boat.status == .racing, legs.indices.contains(boat.legIndex) else { return nil }
        let leg = legs[boat.legIndex]
        let marks = marksOfLeg(leg)
        var nearest = marks[0]
        for mark in marks.dropFirst()
        where (mark.position - boat.position).lengthSquared < (nearest.position - boat.position).lengthSquared {
            nearest = mark
        }
        let distance = Collision.distance(convex: hull, to: nearest.position)
        return MarkZone(mark: nearest, side: roundingSide(of: nearest, on: leg), distance: distance,
                        isIn: distance <= zoneRadius)
    }

    /// The side a boat sailing `leg` leaves `mark`, one of its marks, on: a single mark's side, a gate's left
    /// mark to port and its right to starboard, and finishing (downwind across the line) the pin to starboard
    /// and the committee boat to port.
    func roundingSide(of mark: Mark, on leg: Leg) -> RoundingSide {
        guard case .round(let index) = leg else { return mark == finishLine.pin ? .starboard : .port }
        switch elements[index] {
        case .mark(_, let side): return side
        case .gate(let left, _): return mark == left ? .port : .starboard
        }
    }
}

extension RulesConfig.OnABeat {
    /// Whether `boat` is on a beat to windward (18.1(a)), the rules configuration's builder test: her true
    /// wind angle is at most `maxTrueWindAngle` and, if `windwardLegOnly`, she is racing to the windward mark.
    public func holds(for boat: Boat, in course: CourseLayout) -> Bool {
        guard boat.twa <= maxTrueWindAngle else { return false }
        guard windwardLegOnly else { return true }
        return course.legs.indices.contains(boat.legIndex) && course.legs[boat.legIndex] == .round(CourseLayout.windwardIndex)
    }
}

extension Rules {
    /// Whether rule 18 applies between `a` and `b` now, as the world shows it (18.1, #91), given each one's
    /// `MarkZone`: both racing to the same mark, some of at least one's hull in its zone, and not on opposite
    /// tacks on a beat (`onOppositeTacksOnABeat`). Boats bound for different marks, or on different legs (one
    /// approaching the mark and one leaving it), are never both at one: rule 18 doesn't apply between them.
    ///
    /// World state alone, so a prediction works it out as the server does: it is what extends the overlap
    /// terms to opposite tacks (`overlapTermsApply`). Who is entitled to mark-room is the umpire's
    /// (`UmpireState.markRoom(_:)`).
    public static func markRoomApplies(_ a: Boat, _ b: Boat, zones za: MarkZone?, _ zb: MarkZone?, course: CourseLayout,
                                       onABeat: RulesConfig.OnABeat) -> Bool {
        guard let za, let zb, za.mark == zb.mark, za.isIn || zb.isIn else { return false }
        return !onOppositeTacksOnABeat(a, b, course: course, onABeat: onABeat)
    }

    /// Rule 18.1(a): on opposite tacks with both on a beat to windward (`RulesConfig.OnABeat`), rule 18 doesn't
    /// apply between them.
    static func onOppositeTacksOnABeat(_ a: Boat, _ b: Boat, course: CourseLayout, onABeat: RulesConfig.OnABeat) -> Bool {
        a.tack != b.tack && onABeat.holds(for: a, in: course) && onABeat.holds(for: b, in: course)
    }

    /// Of two overlapped boats at a mark they leave to `side`, the inside one (18.2), by id: the one on the
    /// other's side towards the mark, across their mean heading (as `rightOfWay` tells port from starboard).
    /// With headings too far apart to agree on a side (more than about 150°), or exactly abreast across it, the
    /// one whose hull is nearer the mark (`aDistance`, `bDistance`); a tie, `a`.
    static func insideBoat(_ a: Boat, _ b: Boat, side: RoundingSide, aDistance: Double, bDistance: Double) -> Int {
        let mean = a.forward + b.forward
        if mean.lengthSquared >= 0.25 {
            let across = (b.position - a.position).dot(mean.rightPerp)
            if across != 0 { return (across < 0) == (side == .port) ? b.id : a.id }
        }
        return aDistance <= bDistance ? a.id : b.id
    }

    /// Whether `boat` is fetching the mark at `mark` on starboard tack (18.3): sailing the groove, her class's
    /// derived best upwind angle (`Autohelm.grooveAngle`, at the wind strength her grooves read), she would
    /// pass to windward of it, leaving it to port. Her own heading doesn't matter: fetching is where she is
    /// against the starboard layline through her position, not how she is steering.
    static func isFetchingOnStarboard(_ boat: Boat, mark: Vec2, boatClass: BoatClass) -> Bool {
        let groove = Autohelm.grooveAngle(.upwind, tws: boat.grooveWindSpeed(in: boatClass), boatClass: boatClass)
        let course = Vec2.heading(boat.windDirection - groove)
        let toMark = mark - boat.position
        return toMark.dot(course) > 0 && toMark.dot(course.rightPerp) <= 0
    }
}

/// A rule 18 record between two boats at one mark (#91): which of them is entitled to mark-room from the
/// other, and under which rule. Rule 18.2(a) fixes it when the first of them reaches the mark's zone; an
/// overlap afterwards gives it to the inside boat when 18.2(a) no longer does (18.2(c)); a tack from port to
/// starboard in the zone moves it (18.3). The umpire holds it (`UmpireState.markRoom(_:)`) until mark-room
/// has been given, the entitled boat passes head to wind or leaves the zone, or both boats have left the mark
/// astern. Each new record is announced to its two boats (`RaceEvent.Kind.markRoomNotice`).
public struct MarkRoomRecord: Sendable, Equatable {
    /// The mark's name (`CourseLayout.Mark.name`).
    public let mark: String
    /// The boat entitled to mark-room.
    public let entitled: Int
    /// The boat that must give it to her.
    public let owing: Int
    /// `.givingMarkRoom` (18.2) or `.tackingInTheZone` (18.3).
    public let rule: RacingRule
    /// The boat any part of whose hull reached the zone first (18.2(a)): the nearer the mark when both did
    /// on one tick.
    public let firstInZone: Int
    /// Whether the pair were overlapped as of the last point of certainty when she did (18.2(a), (e)): an
    /// overlap that had held less than that margin is presumed not to have been gained in time.
    public let overlappedAtZoneEntry: Bool
}
