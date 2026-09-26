import Foundation
import Testing
@testable import RegattaCore

/// #82 acceptance: the race area's boundary and land. A boat driven into an edge loses her speed into it,
/// keeps some along it and can steer away; a touch is recorded and costs no penalty.
@Suite struct EdgeContactTests {
    static let outline = Race.defaultBoatClass.hull.outline
    static let still = CurrentField(current: nil, tideStateAtGun: 0)

    static func hull(at position: Vec2, heading: Double) -> [Vec2] {
        Boat(id: 0, isPlayer: true, colorIndex: 0, position: position, heading: heading, speed: 0).hull(outline: outline)
    }

    /// A two-boat race in still water with seat 0 at the race area's starboard side (looking upwind),
    /// level with its centre, heading `angle` off straight into it, at `speed`, her hull reaching 5 cm past
    /// it; seat 1 is out of the way on the line.
    static func raceAtTheSide(angle: Double, speed: Double = 3) throws -> Race {
        try placedRace(current: still, seed: 82) { snapshot, race in
            let course = race.course
            let area = course.raceArea
            let side = area.centre + course.right * area.halfWidth
            var boat = snapshot.seats[0].boat
            boat.heading = course.axis + .pi / 2 + angle
            boat.speed = speed
            boat.rudder = 0
            boat.autopilot = nil
            boat.position = area.centre
            let reach = boat.hull(outline: outline).map { ($0 - side).dot(course.right) }.max()!
            boat.position += course.right * (0.05 - reach)
            snapshot.seats[0].boat = boat
            snapshot.seats[1].boat.position = course.startLine.centre
        }
    }

    /// How far `race`'s seat 0 reaches past the race area's sides: negative when she is inside.
    static func reachPastTheSides(_ race: Race) -> Double {
        -race.boats[0].hull(outline: outline).map(race.course.raceArea.inset).min()!
    }

    // MARK: Acceptance

    @Test func boatDrivenPerpendicularIntoTheBoundaryStops() throws {
        let race = try Self.raceAtTheSide(angle: 0)
        #expect(Self.reachPastTheSides(race) > 0)
        race.step()
        #expect(race.boats[0].speed < 1e-9)
        #expect(Self.reachPastTheSides(race) < 1e-9)
        // Held bow on, she stays stopped at the edge: never through it.
        for _ in 0..<Race.tickRate {
            race.step()
            #expect(Self.reachPastTheSides(race) < 1e-9)
            #expect(race.boats[0].speed < 1e-9)
        }
    }

    @Test func at45DegreesKeepsThirtyPercentOfItsSpeedAlongTheEdge() throws {
        // Heading 45° off the side, towards the leeward end of the area.
        let race = try Self.raceAtTheSide(angle: .pi / 4, speed: 3)
        let retention = race.course.edgeSpeedRetention
        let along = 0.5.squareRoot() // cos 45°
        let before = race.boats[0].position
        race.step()
        // One tick of the boat's own dynamics moves her speed by far less than the tolerance.
        #expect(abs(race.boats[0].speed / (3 * along) - retention) < 0.01)
        #expect(Self.reachPastTheSides(race) < 1e-9)
        // She keeps sliding along the edge.
        race.step()
        let slid = (race.boats[0].position - before).dot(-race.course.upwind)
        #expect(slid > 0)

        // The rule itself, exactly: bow on, at 45°, held there, and heading off.
        let normal = Vec2(0, 1)
        let speed = { (heading: Double, begins: Bool) in
            RaceEdges.speed(3, forward: .heading(heading), normal: normal, begins: begins, retention: retention)
        }
        #expect(speed(.pi, true) < 1e-12)
        #expect(abs(speed(.pi * 3 / 4, true) - retention * along * 3) < 1e-12)
        #expect(abs(speed(.pi * 3 / 4, false) - along * 3) < 1e-12)
        #expect(speed(.pi / 4, true) == 3)
        #expect(speed(.pi / 2, true) == 3)
    }

    @Test func canSteerAwayTheNextTick() throws {
        let race = try Self.raceAtTheSide(angle: 0)
        race.step()
        #expect(race.boats[0].speed < 1e-9)
        let stopped = race.boats[0].heading
        // Hard to starboard: she bears away, stopped or not, and her heading is hers the very next tick.
        race.apply(BoatInput(rudder: 127 as Int8), seat: 0, atTick: race.tick + 1)
        race.step()
        #expect(wrapAngle(race.boats[0].heading - stopped) > 0)
        // Round through a gybe until she points back into the area (from a standstill she turns at the
        // class's slowest rate), then straight: she sails clear.
        let inward = -race.course.right
        var turning = true
        for _ in 0..<(30 * Race.tickRate) {
            if turning && race.boats[0].forward.dot(inward) > 0.7 {
                race.apply(.neutral, seat: 0, atTick: race.tick + 1)
                turning = false
            }
            race.step()
        }
        #expect(!turning)
        #expect(race.boats[0].forward.dot(inward) > 0)
        #expect(race.boats[0].speed > 0.5)
        #expect(Self.reachPastTheSides(race) < -1)
        #expect(race.exportSnapshot().touchingEdges.isEmpty)
    }

    @Test func contactRecordsAnIncidentAndNoPenalty() throws {
        let race = try Self.raceAtTheSide(angle: .pi / 4)
        _ = race.drainEvents()
        race.step()
        let events = race.drainEvents().map(\.kind)
        #expect(events.contains(.obstructionContact(seat: 0, kind: .boundary)))
        #expect(!events.contains {
            switch $0 {
            case .ruleCall, .markTouch, .penaltyStarted: true
            default: false
            }
        })
        #expect(race.boats[0].penaltyTurnsOwed == 0)
        #expect(race.incidents.count == 0)
        let recorded = [ObstructionContact(tick: race.tick, leg: race.boats[0].legIndex, seat: 0, kind: .boundary)]
        #expect(race.incidents.obstructionContacts == recorded)
        #expect(race.exportSnapshot().touchingEdges == [.init(seat: 0, kind: .boundary)])

        // Still touching: announced and recorded once.
        race.step()
        #expect(Self.reachPastTheSides(race) < 1e-9)
        #expect(race.exportSnapshot().touchingEdges == [.init(seat: 0, kind: .boundary)])
        #expect(!race.drainEvents().contains { $0.kind == .obstructionContact(seat: 0, kind: .boundary) })
        #expect(race.incidents.obstructionContacts == recorded)
    }

    /// test-venue@1's land 0: a notch in its east face, its apex at (−500, 150) between (−400, 100) and
    /// (−400, 200), narrower than a hull near the apex. A hull wedged into it, reaching past both sides, comes
    /// straight out: clear of both in one resolve.
    @Test func concaveLandCornerPushesTheHullClearOfBothEdges() throws {
        let land = try VenueFixtures.testVenue().land[0]
        #expect(land.points.contains(Vec2(-500, 150)))
        let upper = Segment(Vec2(-500, 150), Vec2(-400, 200)), lower = Segment(Vec2(-400, 100), Vec2(-500, 150))
        /// How far the hull's furthest corner reaches past `side`'s line, into the land.
        func reach(_ hull: [Vec2], past side: Segment) -> Double {
            let outward = (side.b - side.a).rightPerp.normalized
            return hull.map { -($0 - side.a).dot(outward) }.max()!
        }
        let area = RaceArea(centre: Vec2(0, 150), axis: 0, halfWidth: 1000, halfLength: 1000)
        for heading in [260.0, 270, 280] {
            let hull = Self.hull(at: Vec2(-499, 150), heading: deg2rad(heading))
            #expect(reach(hull, past: upper) > 0.3 && reach(hull, past: lower) > 0.3)

            let resolution = RaceEdges.resolve(hull: hull, area: area, land: [land])
            let moved = hull.map { $0 + resolution.push }
            #expect(reach(moved, past: upper) < 1e-9 && reach(moved, past: lower) < 1e-9, "heading \(heading)")
            #expect((Collision.penetration(convex: moved, simplePolygon: land.points)?.depth ?? 0) < 1e-9)
            #expect(resolution.touches.map(\.kind) == [.land])
            // Out of the notch, the way it opens.
            #expect(resolution.touches[0].normal.x > 0.8)
        }
    }

    // MARK: Placement and the race area's queries

    @Test func everyBoatStartsInsideTheRaceArea() throws {
        for seats in [2, 8, 10, 11, 16] {
            for seed: UInt64 in 1...12 {
                let race = testRace(opponents: seats - 1, seed: seed)
                let hullLength = race.boatClass.hull.length
                for boat in race.boats {
                    #expect(race.course.raceArea.inset(boat.position) >= hullLength - 1e-9, "\(seats) seats, seed \(seed)")
                    #expect(boat.hull(outline: Self.outline).allSatisfy(race.course.isInRaceArea))
                }
                race.step()
                #expect(race.exportSnapshot().touchingEdges.isEmpty)
            }
        }
    }

    @Test func raceAreaIsTheRectangleLessTheLandInIt() throws {
        let venue = try VenueFixtures.testVenue()
        // The line 300 m west of the venue's origin, the course about north: the area, at least 150 m either
        // side of the line, reaches test-venue's west land (x ≤ −400) and not its east (x ≥ 400).
        let setup = try CourseLayoutTests.windSetup(meanDirection: 0, startLineCentre: Vec2(-300, 0))
        let course = CourseLayout.derive(windSetup: setup, land: venue.land, fleetSize: 10, laps: 2,
                                         boatClass: CourseLayoutTests.boatClass, rules: CourseLayoutTests.rules)
        #expect(course.land == [venue.land[0]])
        let area = course.raceArea
        let onLand = course.startLine.centre - course.right * (area.halfWidth - 1)
        #expect(area.contains(onLand) && venue.isLand(onLand) && !course.isInRaceArea(onLand))
        #expect(course.isInRaceArea(course.startLine.centre))
        #expect(!course.isInRaceArea(area.centre + course.upwind * (area.halfLength + 1)))

        // Corners anticlockwise; inset positive inside, negative outside.
        let corners = area.corners
        #expect(Collision.signedArea(corners) > 0)
        #expect(corners.allSatisfy { abs(area.inset($0)) < 1e-9 })
        #expect(abs(area.inset(area.centre) - min(area.halfWidth, area.halfLength)) < 1e-9)
        #expect(abs(area.inset(area.centre + course.right * (area.halfWidth + 3)) + 3) < 1e-9)

        // A strip crossing the rectangle with no corner in it, or it in the strip, still overlaps.
        let square = RaceArea(centre: .zero, axis: 0, halfWidth: 10, halfLength: 10)
        let strip = Venue.LandPolygon(points: [Vec2(-20, -1), Vec2(20, -1), Vec2(20, 1), Vec2(-20, 1)])
        #expect(square.overlaps(strip))
        let away = Venue.LandPolygon(points: [Vec2(30, -1), Vec2(40, -1), Vec2(40, 1), Vec2(30, 1)])
        #expect(!square.overlaps(away))
    }

    /// A land corner poking into the side of a hull, with no hull corner in the land: the hull moves off it,
    /// square to its side.
    @Test func landCornerInsideTheHullPushesItOffItsSide() {
        let hull = Self.hull(at: .zero, heading: 0)
        let spike = [Vec2(0.5, 0), Vec2(5, -1), Vec2(5, 1)]
        #expect(!hull.contains { Collision.contains(simplePolygon: spike, $0) })
        let contact = Collision.penetration(convex: hull, simplePolygon: spike)
        #expect(contact != nil)
        if let contact {
            #expect(contact.normal.x < -0.99)
            #expect(contact.depth > 0.2 && contact.depth < 0.25)
            let moved = hull.map { $0 + contact.push }
            #expect((Collision.penetration(convex: moved, simplePolygon: spike)?.depth ?? 0) < 1e-9)
        }
    }

    /// A stopped boat the current carries onto the boundary is held inside it.
    @Test func currentDriftIntoTheBoundaryIsHeldAtIt() throws {
        let axis = try placedRace(current: Self.still, seed: 82) { _, _ in }.course.axis
        // 2 kn up the course, onto the area's windward end.
        let race = try placedRace(current: steadyCurrent(knots: 2, towards: axis), seed: 82) { snapshot, race in
            let area = race.course.raceArea
            var boat = snapshot.seats[0].boat
            boat.speed = 0
            boat.heading = boat.windDirection
            boat.rudder = 0
            boat.desiredRudder = 0
            boat.autopilot = nil
            boat.position = area.centre + race.course.upwind * (area.halfLength - 3)
            snapshot.seats[0].boat = boat
            snapshot.seats[1].boat.position = area.centre
        }
        for _ in 0..<(5 * Race.tickRate) {
            race.step()
            #expect(Self.reachPastTheSides(race) < 1e-9)
        }
        #expect(race.incidents.obstructionContacts.contains { $0.seat == 0 && $0.kind == .boundary })
    }
}
