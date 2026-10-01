import Foundation
import RegattaCore

/// Which marks are drawn as the active leg's and which way round each is rounded (#115, #15): pure, no SpriteKit.
///
/// The marks of the leg you are sailing (`CourseLayout.legSailed`, `marksOfLeg`) are orange, with a dashed zone and
/// a rounding-side arrow; every other mark, the next one included, is grey with neither. A leeward gate's two marks
/// are both active on the gate leg; the offset mark only on its own leg; on the last lap the gate isn't a mark of
/// any leg, so it stays grey. The start and finish line's ends are marks too: active (with the line and the
/// committee boat) in the start sequence, while OCS and on the finish leg, the same rule as the HUD's minimap.
nonisolated enum ChartMarks {
    /// The tone a mark is drawn in: the active leg's orange or the inactive grey.
    static func tone(isActive: Bool) -> PaletteToken {
        isActive ? CuePalette.orange : CuePalette.inactiveGrey
    }

    /// The leg a boat with `status` on leg `legIndex` is drawn as sailing for.
    static func leg(in course: CourseLayout, status: BoatStatus, legIndex: Int) -> CourseLayout.Leg {
        course.legSailed(status: status, legIndex: legIndex)
    }

    /// Whether the start and finish line (its pin, committee boat and the line between) is active: before the start
    /// (in the sequence, or OCS) and on the finish leg.
    static func isLineActive(status: BoatStatus, leg: CourseLayout.Leg) -> Bool {
        status == .prestart || status == .ocs || leg == .finish
    }

    /// Whether `mark` is drawn active for a boat with `status` on leg `legIndex`: a mark of the leg she's sailing,
    /// or an end of the line while the line is active.
    static func isActive(_ mark: CourseLayout.Mark, in course: CourseLayout, status: BoatStatus, legIndex: Int) -> Bool {
        let leg = course.legSailed(status: status, legIndex: legIndex)
        if course.marksOfLeg(leg).contains(mark) { return true }
        let lineEnds = [course.startLine.pin, course.startLine.committee, course.finishLine.pin, course.finishLine.committee]
        return isLineActive(status: status, leg: leg) && lineEnds.contains(mark)
    }

    /// The tone `mark` is drawn in: orange for the marks of the boat's current leg, grey otherwise.
    static func tone(of mark: CourseLayout.Mark, in course: CourseLayout, status: BoatStatus, legIndex: Int) -> PaletteToken {
        tone(isActive: isActive(mark, in: course, status: status, legIndex: legIndex))
    }

    /// A buoy of the course (not a line end) and how it's rounded.
    struct Buoy: Equatable, Sendable {
        var mark: CourseLayout.Mark
        /// Which `CourseLayout.elements` it belongs to.
        var element: Int
        var side: RoundingSide
        /// The direction a boat comes to it from, a unit vector: upwind to the windward mark, from the windward
        /// mark to the offset mark, downwind to the gate (as `CourseLayout.roundingStages` has it).
        var approach: Vec2
    }

    /// Every buoy of `course`, in element order: a gate's left mark (rounded to port) before its right (starboard).
    static func buoys(of course: CourseLayout) -> [Buoy] {
        let windward = course.elements[CourseLayout.windwardIndex].marks[0].position
        return course.elements.enumerated().flatMap { index, element -> [Buoy] in
            switch element {
            case .mark(let mark, let side):
                let approach = index == CourseLayout.windwardIndex ? course.upwind : (mark.position - windward).normalized
                return [Buoy(mark: mark, element: index, side: side, approach: approach)]
            case .gate(let left, let right):
                return [Buoy(mark: left, element: index, side: .port, approach: -course.upwind),
                        Buoy(mark: right, element: index, side: .starboard, approach: -course.upwind)]
            }
        }
    }
}

/// The rounding-side arrow round an active mark (#15): an arc about the mark that starts on the side a boat comes
/// from and sweeps the way she rounds it, anticlockwise leaving it to port and clockwise to starboard, with a head
/// at its end. Angles are mathematical (radians anticlockwise from east), positions metres.
nonisolated struct RoundingArrow: Equatable, Sendable {
    var center: Vec2
    var radius: Double
    /// Where the arc starts: straight back towards the approach.
    var startAngle: Double
    /// Signed: positive anticlockwise (port), negative clockwise (starboard).
    var sweep: Double

    init(center: Vec2, radius: Double, startAngle: Double, sweep: Double) {
        self.center = center
        self.radius = radius
        self.startAngle = startAngle
        self.sweep = sweep
    }

    /// The arrow round a mark at `center` approached along `approach`, left to `side`.
    init(around center: Vec2, approach: Vec2, side: RoundingSide, radius: Double, sweep: Double) {
        let back = -approach
        self.init(center: center, radius: radius, startAngle: atan2(back.y, back.x),
                  sweep: side == .port ? abs(sweep) : -abs(sweep))
    }

    var endAngle: Double { startAngle + sweep }

    func point(at angle: Double) -> Vec2 {
        center + Vec2(cos(angle), sin(angle)) * radius
    }

    /// The arc as `count + 1` points, start to end.
    func arc(count: Int = 24) -> [Vec2] {
        (0...count).map { point(at: startAngle + sweep * Double($0) / Double(count)) }
    }

    /// The direction the arc runs at its end: where the head points.
    var endTangent: Vec2 {
        let a = endAngle
        let anticlockwise = Vec2(-sin(a), cos(a))
        return sweep >= 0 ? anticlockwise : -anticlockwise
    }

    /// The head's two barbs, each `length` back from the tip at 30° either side of the tangent.
    func barbs(length: Double) -> [Vec2] {
        let tip = point(at: endAngle)
        let back = -endTangent
        return [-1.0, 1.0].map { s in
            let angle = atan2(back.y, back.x) + s * .pi / 6
            return tip + Vec2(cos(angle), sin(angle)) * length
        }
    }
}
