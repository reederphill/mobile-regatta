/// A boat's proper course (#345, rule 17), defined by fiat from where she is, the wind at her and the leg she is
/// sailing (#343): what rule 17 holds a leeward boat that came up from astern to, what bots aim within (#346) and
/// what the client draws (#347). A pure function of primitives, so each of them computes the same heading.
///
/// - Beat (a leg to the windward mark): the upwind groove on her tack (`Autohelm.grooveAngle`), including past
///   the layline.
/// - Reach (a leg to a single mark that isn't the windward one): the bearing to the mark.
/// - Run (a leg through a gate, or to the finish line): the bearing to the further of its marks or line ends,
///   by distance across the course (`CourseLayout.right`) from her, the first on a tie, kept no lower than the
///   downwind groove on her tack. From her position, so a boat that went wide already points back.
/// - A bearing is read as a sailing angle on her tack (`BoomSide.sailingAngle`), so she never needs to tack or gybe
///   to sail it: one in the no-go zone, or past head to wind on the other tack, is the upwind groove; one by the lee
///   is the deepest she sails (the downwind groove on a run, the autohelm's dead-run limit on a reach).
/// - The wind is hers: her sailing wind's direction and the wind speed her grooves read, which the wind field gives
///   where she is.
/// - None unless she is racing (`BoatStatus.racing`): there is no proper course before her start.
public struct ProperCourse: Sendable, Equatable {
    /// What kind of leg she is on, which picks rule 17's tolerance (`RulesConfig.ProperCourseLimits.tolerance`).
    public enum Kind: Sendable, Equatable {
        case beat
        case reach
        case run
    }

    public let kind: Kind
    /// Her proper course as a sailing angle on her tack (`BoomSide.sailingAngle`), radians, 0 ..< π: positive, with
    /// the wind on the side away from her boom.
    public let sailingAngle: Double
    /// Her proper course as a compass heading, radians, −π ..< π.
    public let heading: Double
    /// Where the wind she sails in blows from, radians, and her boom's side: what turns a sailing angle into a heading.
    public let windDirection: Double
    public let boomSide: BoomSide

    /// The proper course of a boat at `position` with her boom on `boomSide`, `status`, sailing leg `legIndex` of
    /// `course`, in a wind from `windDirection` (radians, her sailing wind's) whose speed her grooves read as
    /// `grooveTWS` (m/s, `Boat.grooveWindSpeed(in:)`), in `boatClass`. Nil unless she is racing on a leg of the course.
    public static func of(position: Vec2, boomSide: BoomSide, status: BoatStatus, legIndex: Int, windDirection: Double,
                          grooveTWS: Double, course: CourseLayout, boatClass: BoatClass) -> ProperCourse? {
        guard status == .racing, course.legs.indices.contains(legIndex) else { return nil }
        let leg = course.legs[legIndex]
        let upwind = Autohelm.grooveAngle(.upwind, tws: grooveTWS, boatClass: boatClass)
        if leg == .round(CourseLayout.windwardIndex) {
            return ProperCourse(kind: .beat, sailingAngle: upwind, windDirection: windDirection, boomSide: boomSide)
        }
        let marks = course.marksOfLeg(leg)
        let kind: Kind = marks.count > 1 ? .run : .reach
        let deepest = kind == .run
            ? Autohelm.grooveAngle(.downwind, tws: grooveTWS, boatClass: boatClass)
            : .pi - boatClass.steering.autohelm.deadRunMargin
        let angle = bearingAngle(to: further(of: marks, from: position, course: course), from: position,
                                 boomSide: boomSide, windDirection: windDirection, upwind: upwind, deepest: deepest)
        return ProperCourse(kind: kind, sailingAngle: angle, windDirection: windDirection, boomSide: boomSide)
    }

    init(kind: Kind, sailingAngle: Double, windDirection: Double, boomSide: BoomSide) {
        self.kind = kind
        self.sailingAngle = sailingAngle
        self.windDirection = windDirection
        self.boomSide = boomSide
        heading = Self.heading(sailingAngle: sailingAngle, windDirection: windDirection, boomSide: boomSide)
    }

    /// The compass heading of `sailingAngle` on `boomSide`'s tack in a wind from `windDirection`: the heading whose
    /// `Boat.sailingAngle` it is.
    static func heading(sailingAngle: Double, windDirection: Double, boomSide: BoomSide) -> Double {
        wrapAngle(windDirection - boomSide.windSign * sailingAngle)
    }

    /// The highest she may sail under rule 17 with `tolerance` (radians, `RulesConfig.ProperCourseLimits.tolerance`):
    /// proper course less the tolerance, as a sailing angle, never below 0.
    public func edgeSailingAngle(tolerance: Double) -> Double { max(0, sailingAngle - tolerance) }

    /// `edgeSailingAngle(tolerance:)` as a compass heading: the line #347 draws.
    public func edgeHeading(tolerance: Double) -> Double {
        Self.heading(sailingAngle: edgeSailingAngle(tolerance: tolerance), windDirection: windDirection, boomSide: boomSide)
    }

    /// Whether a boat at sailing angle `angle` on this tack (`Boat.sailingAngle`) is above this proper course by more
    /// than `tolerance`: closer to the wind than proper course less it. Past head to wind with her boom not yet
    /// across counts as above; by the lee does not.
    public func isAbove(sailingAngle angle: Double, tolerance: Double) -> Bool {
        angle > -.pi / 2 && angle < sailingAngle - tolerance
    }

    /// Of `marks`, the further from `position` across the course (`CourseLayout.right`); the first on a tie.
    static func further(of marks: [CourseLayout.Mark], from position: Vec2, course: CourseLayout) -> Vec2 {
        var best = marks[0].position
        var bestDistance = abs((best - position).dot(course.right))
        for mark in marks.dropFirst() {
            let distance = abs((mark.position - position).dot(course.right))
            if distance > bestDistance {
                best = mark.position
                bestDistance = distance
            }
        }
        return best
    }

    /// The sailing angle on `boomSide`'s tack of the bearing from `position` to `target`, kept between the upwind
    /// groove (`upwind`) and `deepest`: a bearing in the no-go zone or across head to wind is the groove, one by
    /// the lee is `deepest`.
    static func bearingAngle(to target: Vec2, from position: Vec2, boomSide: BoomSide, windDirection: Double,
                             upwind: Double, deepest: Double) -> Double {
        let bearing = (target - position).bearing
        let angle = boomSide.sailingAngle(relativeWind: wrapAngle(windDirection - bearing))
        if angle < 0 { return angle > -.pi / 2 ? upwind : deepest }
        return min(max(angle, upwind), deepest)
    }
}

extension Boat {
    /// Her proper course (`ProperCourse.of`) on `course` in `boatClass`, in the wind at her now; nil unless she is
    /// racing.
    public func properCourse(on course: CourseLayout, boatClass: BoatClass) -> ProperCourse? {
        ProperCourse.of(position: position, boomSide: boomSide, status: status, legIndex: legIndex,
                        windDirection: sailingWind.direction, grooveTWS: grooveWindSpeed(in: boatClass), course: course,
                        boatClass: boatClass)
    }
}
