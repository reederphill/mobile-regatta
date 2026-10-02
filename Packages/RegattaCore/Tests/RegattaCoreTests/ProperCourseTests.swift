import Foundation
import Testing
@testable import RegattaCore

/// #345 acceptance: proper course by fiat (#343), on `IncidentFixture`'s course (ilca-dinghy@3) in 10 kn from the
/// course's axis: the upwind groove on a beat, the bearing to the mark on a reach, the bearing to the further gate
/// mark or finish line end on a run, kept to the downwind groove, and none before the start.
@Suite struct ProperCourseTests {
    typealias F = IncidentFixture

    struct Setup {
        let course: CourseLayout
        let boatClass: BoatClass
        let tws = metresPerSecond(knots: F.knots)
        var wind: Double { course.axis }
        var upwind: Double { Autohelm.grooveAngle(.upwind, tws: tws, boatClass: boatClass) }
        var downwind: Double { Autohelm.grooveAngle(.downwind, tws: tws, boatClass: boatClass) }

        func of(_ position: Vec2, leg: Int, boomSide: BoomSide = .port, status: BoatStatus = .racing) -> ProperCourse? {
            ProperCourse.of(position: position, boomSide: boomSide, status: status, legIndex: leg, windDirection: wind,
                            grooveTWS: tws, course: course, boatClass: boatClass)
        }

        /// The leg index of the first leg rounding `elements[index]`.
        func leg(rounding index: Int) throws -> Int {
            try #require(course.legs.firstIndex(of: .round(index)))
        }
    }

    func setup() throws -> Setup {
        let race = try F.race()
        return Setup(course: race.course, boatClass: race.boatClass)
    }

    /// The sailing angle of `heading` on `boomSide`'s tack in the setup's wind.
    func angle(_ heading: Double, _ boomSide: BoomSide, _ s: Setup) -> Double {
        boomSide.sailingAngle(relativeWind: wrapAngle(s.wind - heading))
    }

    func near(_ a: Double, _ b: Double) -> Bool { abs(wrapAngle(a - b)) < 1e-9 }

    @Test func beatIsTheUpwindGrooveOnHerTack() throws {
        let s = try setup()
        let at = s.course.startLine.centre + s.course.upwind * (s.course.beat / 2)
        for side in [BoomSide.port, .starboard] {
            let proper = try #require(s.of(at, leg: 0, boomSide: side))
            #expect(proper.kind == .beat && proper.sailingAngle == s.upwind)
            #expect(near(angle(proper.heading, side, s), s.upwind))
        }
        // Starboard tack (boom to port) heads to port of the wind; port tack to starboard of it.
        #expect(near(try #require(s.of(at, leg: 0, boomSide: .port)).heading, s.wind - s.upwind))
        #expect(near(try #require(s.of(at, leg: 0, boomSide: .starboard)).heading, s.wind + s.upwind))
        // Past the layline it is still the groove.
        let wide = at + s.course.right * (s.course.beat * 0.7)
        #expect(try #require(s.of(wide, leg: 0)).sailingAngle == s.upwind)
    }

    @Test func reachIsTheBearingToTheMark() throws {
        let s = try setup()
        let leg = try s.leg(rounding: CourseLayout.offsetIndex)
        let mark = s.course.elements[CourseLayout.offsetIndex].marks[0].position
        // Just below the windward mark, on starboard: the offset mark is to port, across the wind.
        let at = s.course.elements[CourseLayout.windwardIndex].marks[0].position - s.course.upwind * 6
        let proper = try #require(s.of(at, leg: leg))
        #expect(proper.kind == .reach)
        #expect(near(proper.heading, (mark - at).bearing))
        #expect(proper.sailingAngle > s.upwind && proper.sailingAngle < .pi / 2 + 0.3)
        // Higher than the groove (the mark nearly upwind), the groove: never into the no-go zone.
        let below = mark - s.course.upwind * 40 + s.course.right * 2
        #expect(try #require(s.of(below, leg: leg)).sailingAngle == s.upwind)
    }

    /// On a run the bearing to the further gate mark, by distance across the course, from where she is; deeper than
    /// the downwind groove (or by the lee), the groove.
    @Test func runIsTheBearingToTheFurtherGateMarkKeptToTheDownwindGroove() throws {
        let s = try setup()
        let leg = try s.leg(rounding: CourseLayout.gateIndex)
        guard case .gate(let left, let right) = s.course.elements[CourseLayout.gateIndex] else {
            Issue.record("the gate")
            return
        }
        let centre = (left.position + right.position) / 2
        // Up and well out to the upwind right: the gate's left mark (towards the upwind right) is nearer across, so
        // the further is the right mark, a broad reach away on starboard tack (boom to port).
        let wide = centre + s.course.upwind * 30 + s.course.right * 60
        let proper = try #require(s.of(wide, leg: leg, boomSide: .port))
        #expect(proper.kind == .run)
        let bearing = (right.position - wide).bearing
        #expect(angle(bearing, .port, s) < s.downwind && angle(bearing, .port, s) > s.upwind)
        #expect(near(proper.heading, bearing))
        // Out to the upwind left instead, the further is the left mark, on port tack.
        let other = centre + s.course.upwind * 30 - s.course.right * 60
        #expect(near(try #require(s.of(other, leg: leg, boomSide: .starboard)).heading, (left.position - other).bearing))
        // On the other gybe from the wide boat the mark is by the lee: the downwind groove on her gybe.
        let byTheLee = try #require(s.of(wide, leg: leg, boomSide: .starboard))
        #expect(byTheLee.sailingAngle == s.downwind && near(angle(byTheLee.heading, .starboard, s), s.downwind))
        // Far upwind of the gate, both marks nearly dead downwind: deeper than the groove on either gybe, the groove.
        let above = centre + s.course.upwind * 1000
        for side in [BoomSide.port, .starboard] {
            #expect(try #require(s.of(above, leg: leg, boomSide: side)).sailingAngle == s.downwind)
        }
    }

    @Test func finishIsTheBearingToTheFurtherLineEnd() throws {
        let s = try setup()
        let leg = s.course.legs.count - 1
        #expect(s.course.legs[leg] == .finish)
        let line = s.course.finishLine
        // Up and out to the upwind right: the pin (upwind left end) is further across.
        let at = line.centre + s.course.upwind * 25 + s.course.right * 40
        let proper = try #require(s.of(at, leg: leg, boomSide: .port))
        #expect(proper.kind == .run)
        let bearing = (line.pin.position - at).bearing
        #expect(angle(bearing, .port, s) < s.downwind && angle(bearing, .port, s) > s.upwind)
        #expect(near(proper.heading, bearing))
        let left = line.centre + s.course.upwind * 25 - s.course.right * 40
        #expect(near(try #require(s.of(left, leg: leg, boomSide: .starboard)).heading, (line.committee.position - left).bearing))
    }

    /// No proper course before her start, nor once she has finished or is disqualified, nor off the course's legs.
    @Test func noProperCourseBeforeTheStart() throws {
        let s = try setup()
        let at = s.course.startLine.centre + s.course.upwind * 20
        for status in [BoatStatus.prestart, .ocs, .finished, .dsq] {
            #expect(s.of(at, leg: 0, status: status) == nil)
        }
        #expect(s.of(at, leg: s.course.legs.count) == nil)
        #expect(s.of(at, leg: 0) != nil)
        // A boat before the gun has none either.
        let race = try F.race()
        #expect(race.boats.allSatisfy { $0.status != .racing || $0.properCourse(on: race.course, boatClass: race.boatClass) != nil })
        var boat = race.boats[0]
        boat.status = .prestart
        #expect(boat.properCourse(on: race.course, boatClass: race.boatClass) == nil)
    }

    /// "Above" is closer to the wind than proper course less the tolerance; the edge heading is that line.
    @Test func aboveIsCloserToTheWindThanProperCourseLessTheTolerance() throws {
        let s = try setup()
        let proper = try #require(s.of(s.course.startLine.centre + s.course.upwind * (s.course.beat / 2), leg: 0))
        let tolerance = deg2rad(5)
        #expect(!proper.isAbove(sailingAngle: s.upwind, tolerance: tolerance))
        #expect(!proper.isAbove(sailingAngle: s.upwind - deg2rad(4.9), tolerance: tolerance))
        #expect(proper.isAbove(sailingAngle: s.upwind - deg2rad(5.1), tolerance: tolerance))
        #expect(proper.isAbove(sailingAngle: -0.1, tolerance: tolerance), "past head to wind, boom not across")
        #expect(!proper.isAbove(sailingAngle: -2.5, tolerance: tolerance), "by the lee")
        #expect(near(angle(proper.edgeHeading(tolerance: tolerance), .port, s), s.upwind - tolerance))
        #expect(proper.edgeSailingAngle(tolerance: 2 * .pi) == 0)
    }
}
