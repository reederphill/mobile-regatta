import Foundation
import Testing
@testable import RegattaCore

/// #82 acceptance: the race area's boundary and the land in it. A boat driven into an edge loses her
/// speed into it, keeps `edgeSpeedRetention` of her speed along it as the touch begins, and can always
/// steer away; a touch is recorded and costs no penalty. The autohelm has no special case there (#219).
///
/// The races sail the default class, skiff@3, in still water and a steady scripted wind, so one tick of a
/// boat's own dynamics is the same wherever she is on the water.
@Suite struct RaceAreaContactTests {
    static let boatClass = RaceFiles.defaults.boatClass.ref
    static let outline = RaceFiles.defaults.boatClass.content.hull.outline
    static let still = CurrentField(current: nil, tideStateAtGun: 0)
    static let seed: UInt64 = 82
    /// Metres per second: a sailing breeze for the skiff.
    static let windSpeed = 5.0

    static func hull(at position: Vec2, heading: Double) -> [Vec2] {
        Boat(id: 0, isPlayer: true, colorIndex: 0, position: position, heading: heading, speed: 0).hull(outline: outline)
    }

    /// The course every race here sails: the seed, fleet and class draw it, whatever the wind.
    static func course() throws -> CourseLayout {
        try placedRace(current: still, seed: seed, boatClass: boatClass) { _, _ in }.course
    }

    /// A two-boat race with seat 0 at the race area's starboard side (looking upwind), level with its
    /// centre, heading `angle` off straight into it (positive: towards the leeward end) at `speed`, her
    /// hull reaching `reach` metres past the side (negative: inside it). Her rudder is centred, so her
    /// autohelm takes her sailing angle on the first step. The wind blows abeam from her port side (a
    /// beam reach, clear of both grooves' snaps), turned by `shift(tick)`. Seat 1 is out of the way on
    /// the line. The race is at `venue` if one is given (`venue(land:)`).
    static func raceAtTheSide(angle: Double, speed: Double = 3, reach: Double = 0.05, venue: VenueFile? = nil,
                              shift: @escaping (_ tick: Int) -> Double = { _ in 0 }) throws -> Race {
        let course = try course()
        let heading = course.axis + .pi / 2 + angle
        let wind = { (tick: Int) in GroundWind(direction: wrapAngle(heading - .pi / 2 + shift(tick)), speed: windSpeed) }
        return try placedRace(current: still, seed: seed, wind: wind, boatClass: boatClass, venue: venue) { snapshot, race in
            let area = race.course.raceArea
            let right = race.course.right
            let side = area.centre + right * area.halfWidth
            var boat = snapshot.seats[0].boat
            boat.heading = heading
            boat.speed = speed
            boat.rudder = 0
            boat.desiredRudder = 0
            boat.boomSide = .leeward(ofRelativeWind: -.pi / 2)
            boat.position = area.centre
            let past = boat.hull(outline: outline).map { ($0 - side).dot(right) }.max()!
            boat.position += right * (reach - past)
            snapshot.seats[0].boat = boat
            snapshot.seats[0].heldInput = .neutral
            snapshot.seats[1].boat.position = race.course.startLine.centre
        }
    }

    /// How far `race`'s seat 0 reaches past the race area's sides: negative when she is inside.
    static func reachPastTheSides(_ race: Race) -> Double {
        -race.boats[0].hull(outline: outline).map(race.course.raceArea.inset).min()!
    }

    static func isTouching(_ race: Race, _ kind: ObstructionKind = .boundary) -> Bool {
        race.exportSnapshot().touchingEdges.contains(.init(seat: 0, kind: kind))
    }

    /// The default venue (dev-venue@2), as `edge-venue@1`, with `land` for its land: each polygon's
    /// corners in order, in the venue's frame (the course's).
    static func venue(land: [[Vec2]]) throws -> VenueFile {
        let bytes = try #require(try VenueFile.bundledData(id: "dev-venue", version: 2))
        var json = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        json["id"] = "edge-venue"
        json["version"] = 1
        json["land"] = land.map { corners in ["outlineMetres": (corners + [corners[0]]).map { [$0.x, $0.y] }] }
        return try VenueFile(data: JSONSerialization.data(withJSONObject: json, options: .sortedKeys))
    }

    /// Metres from `p` to `polygon`: 0 on it.
    static func clearance(_ p: Vec2, from polygon: [Vec2]) -> Double {
        if Collision.contains(simplePolygon: polygon, p) { return 0 }
        return polygon.indices.map { i in
            (Collision.closestPoint(on: Segment(polygon[i], polygon[(i + 1) % polygon.count]), to: p) - p).length
        }.min()!
    }

    // MARK: Acceptance

    @Test func perpendicularIntoBoundaryStops() throws {
        let race = try Self.raceAtTheSide(angle: 0)
        #expect(Self.reachPastTheSides(race) > 0)
        race.step()
        #expect(race.boats[0].speed < 1e-9)
        #expect(Self.reachPastTheSides(race) < 1e-9)
        #expect(Self.isTouching(race))
        // Held bow on by her autohelm, she stays stopped at the edge: never through it.
        for _ in 0..<(2 * Race.tickRate) {
            race.step()
            #expect(Self.reachPastTheSides(race) < 1e-9)
            #expect(race.boats[0].speed < 1e-9)
        }
        #expect(race.boats[0].autohelm != nil)
    }

    @Test func glancingHitKeepsEdgeRetentionAlongEdge() throws {
        // 45° off the side, towards the leeward end of the area; and her twin, the same boat 40 m inside
        // it, whose step is hers without the edge.
        let race = try Self.raceAtTheSide(angle: .pi / 4)
        let twin = try Self.raceAtTheSide(angle: .pi / 4, reach: -40)
        let retention = race.course.edgeSpeedRetention
        let before = race.boats[0].position
        race.step()
        twin.step()
        #expect(Self.isTouching(race) && !Self.isTouching(twin))
        let boat = race.boats[0], free = twin.boats[0]
        #expect(boat.heading == free.heading)
        // Her speed along the edge (her twin's speed, times her heading's share of it), and the course's
        // retention of that: exactly, and 45° off the side to within one tick's steering.
        let along = abs(boat.forward.dot(race.course.upwind))
        #expect(abs(boat.speed - retention * along * free.speed) < 1e-9)
        #expect(abs(boat.speed / (0.5.squareRoot() * free.speed) - retention) < 0.01)
        #expect(Self.reachPastTheSides(race) < 1e-9)
        // She keeps sliding along the edge, towards its leeward end.
        race.step()
        #expect((race.boats[0].position - before).dot(-race.course.upwind) > 0)
        #expect(race.boats[0].speed > 0)

        // The rule itself, exactly: bow on, at 45° as the touch begins and held there, and heading off.
        let normal = Vec2(0, 1)
        let speed = { (heading: Double, begins: Bool) in
            RaceEdges.speed(3, forward: .heading(heading), normal: normal, begins: begins, retention: retention)
        }
        let cos45 = 0.5.squareRoot()
        #expect(speed(.pi, true) < 1e-12)
        #expect(abs(speed(.pi * 3 / 4, true) - retention * cos45 * 3) < 1e-12)
        #expect(abs(speed(.pi * 3 / 4, false) - cos45 * 3) < 1e-12)
        #expect(speed(.pi / 4, true) == 3)
        #expect(speed(.pi / 2, true) == 3)
    }

    @Test func canSteerAwayNextTick() throws {
        let race = try Self.raceAtTheSide(angle: 0)
        race.step()
        #expect(race.boats[0].speed < 1e-9)
        let stopped = race.boats[0].heading
        // Hard to starboard: she bears away, stopped or not, and her heading is hers the very next tick.
        _ = race.apply(BoatInput(rudder: 127 as Int8), seat: 0, atTick: race.tick + 1)
        race.step()
        #expect(race.boats[0].autohelm == nil)
        #expect(wrapAngle(race.boats[0].heading - stopped) > 0)
        // Round through a gybe until she points back into the area (from a standstill she turns at the
        // class's slowest rate), then let go: her autohelm sails her clear.
        let inward = -race.course.right
        var clearFor = 0
        for _ in 0..<(40 * Race.tickRate) where clearFor < 5 * Race.tickRate {
            if clearFor == 0 && race.boats[0].forward.dot(inward) > 0.7 {
                _ = race.apply(.neutral, seat: 0, atTick: race.tick + 1)
                clearFor = 1
            } else if clearFor > 0 {
                clearFor += 1
            }
            race.step()
        }
        #expect(clearFor == 5 * Race.tickRate)
        #expect(race.boats[0].autohelm != nil)
        #expect(race.boats[0].forward.dot(inward) > 0)
        #expect(race.boats[0].speed > 0.5)
        #expect(Self.reachPastTheSides(race) < -1)
        #expect(race.exportSnapshot().touchingEdges.isEmpty)
        // Turning off it from a standstill, pinned there a while, was one touch, and her stern brushes it once
        // more as she pivots through the gybe: skiff@2 and @3 turn at their full rate from 1.5 kn (#89), so at a crawl
        // she turns inside her own length.
        #expect(race.incidents.obstructionContacts.count == 2)
    }

    @Test func edgeContactIsNotAPenaltyAndIsIndexed() throws {
        let race = try Self.raceAtTheSide(angle: .pi / 4)
        _ = race.drainEvents()
        #expect(race.incidents.obstructionContacts.isEmpty)
        race.step()
        let events = race.drainEvents().map(\.kind)
        #expect(events.contains(.obstructionContact(seat: 0, kind: .boundary)))
        #expect(!events.contains {
            switch $0 {
            case .ruleCall, .markTouch, .contact, .penaltyStarted: true
            default: false
            }
        })
        #expect(race.boats[0].penaltyTurnsOwed == 0)
        #expect(!race.boats[0].isTakingPenalty)
        // An entry in the incident index: an obstruction contact, not a boat-pair incident.
        #expect(race.incidents.count == 0)
        let recorded = [ObstructionContact(tick: race.tick, leg: race.boats[0].legIndex, seat: 0, kind: .boundary)]
        #expect(race.incidents.obstructionContacts == recorded)
        #expect(race.exportSnapshot().touchingEdges == [.init(seat: 0, kind: .boundary)])

        // Still touching: announced and recorded once.
        race.step()
        #expect(Self.reachPastTheSides(race) < 1e-9)
        #expect(Self.isTouching(race))
        #expect(!race.drainEvents().contains { $0.kind == .obstructionContact(seat: 0, kind: .boundary) })
        #expect(race.incidents.obstructionContacts == recorded)
        #expect(race.boats[0].penaltyTurnsOwed == 0)
    }

    /// test-venue@1's land 0: a notch in its east face, its apex at (−500, 150) between (−400, 100) and
    /// (−400, 200), narrower than a hull near the apex. A hull wedged into it, reaching past both sides,
    /// comes straight out: clear of both in one resolve.
    @Test func concaveLandCornerHandled() throws {
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
            #expect(resolution.touches == [.land])
            // Out of the notch, the way it opens.
            #expect(resolution.normal.x > 0.8)
            #expect(abs(resolution.normal.dot(resolution.push.normalized) - 1) < 1e-12)
        }
    }

    /// Land and the boundary touched in the same tick are one edge: she loses her speed to them once,
    /// against the way her hull is pushed out of both, not once to each in turn.
    @Test func landAndBoundaryTouchedTogetherTakeHerSpeedOnce() throws {
        // 30° off straight into the side, towards the leeward end, into the corner the side makes with a
        // shore to leeward of her: her hull reaches 0.05 m past the side and past the shore's face.
        let angle = Double.pi / 6
        let open = try Self.raceAtTheSide(angle: angle)
        let area = open.course.raceArea, right = open.course.right, up = open.course.upwind
        let side = area.centre + right * area.halfWidth
        let face = open.boats[0].hull(outline: Self.outline).map { ($0 - side).dot(up) }.min()! + 0.05
        func at(_ inward: Double, _ along: Double) -> Vec2 { side - right * inward + up * along }
        let shore = [at(20, face - 60), at(-50, face - 60), at(-50, face), at(20, face)]
        let venue = try Self.venue(land: [shore])
        // Her twin, 40 m further in, is clear of both.
        let race = try Self.raceAtTheSide(angle: angle, venue: venue)
        let twin = try Self.raceAtTheSide(angle: angle, reach: -40, venue: venue)
        _ = race.drainEvents()
        race.step()
        twin.step()
        #expect(Self.isTouching(race, .land) && Self.isTouching(race, .boundary))
        #expect(twin.exportSnapshot().touchingEdges.isEmpty)
        let events = race.drainEvents().map(\.kind)
        #expect(events.contains(.obstructionContact(seat: 0, kind: .land)))
        #expect(events.contains(.obstructionContact(seat: 0, kind: .boundary)))
        #expect(race.incidents.obstructionContacts.map(\.kind) == [.land, .boundary])

        // Where her own step took her hull: her twin's, 40.05 m further out, into both.
        let boat = race.boats[0], free = twin.boats[0]
        #expect(boat.heading == free.heading)
        let stepped = free.hull(outline: Self.outline).map { $0 + right * 40.05 }
        let resolution = race.course.resolveEdges(hull: stepped)
        #expect(resolution.touches == [.land, .boundary])
        #expect((boat.position - (free.position + right * 40.05 + resolution.push)).length < 1e-9)
        // The one edge faces out of the corner, between the side and the shore.
        #expect(resolution.normal.dot(-right) > 0.1 && resolution.normal.dot(up) > 0.1)
        // Her speed along that one edge, and the course's retention of it once.
        let retention = race.course.edgeSpeedRetention
        let once = retention * abs(boat.forward.dot(resolution.normal.rightPerp)) * free.speed
        #expect(abs(boat.speed - once) < 1e-9)
        // Not the side's retention of her speed along it, and then the shore's of what was left.
        let twice = retention * abs(boat.forward.dot(right)) * retention * abs(boat.forward.dot(up)) * free.speed
        #expect(abs(boat.speed - twice) > 1e-3)
        #expect(Self.reachPastTheSides(race) < 1e-9)
        #expect(Collision.distance(convex: boat.hull(outline: Self.outline), simplePolygon: race.course.land[0].points)
                < RaceEdges.touchMargin)
        #expect(Collision.penetration(convex: boat.hull(outline: Self.outline), simplePolygon: race.course.land[0].points) == nil)
    }

    @Test func centredRudderHoldsWindAngleIntoTheEdgeAndSlows() throws {
        // 30° off straight into the side, towards the windward end, 3 m short of it; 3 s after she is
        // placed the wind veers 15°.
        let veer = deg2rad(15)
        var shiftTick = Int.max
        let race = try Self.raceAtTheSide(angle: -.pi / 6, reach: -3) { $0 >= shiftTick ? veer : 0 }
        shiftTick = race.tick + 3 * Race.tickRate
        let heading = race.boats[0].heading
        race.step()
        let autohelm = try #require(race.boats[0].autohelm)
        let held = race.boats[0].sailingAngle
        #expect(autohelm.target == .angle(held))
        #expect(!Self.isTouching(race))

        var speedGoingIn: Double?
        var touchingTicks = 0
        for _ in 0..<(10 * Race.tickRate) {
            let speed = race.boats[0].speed
            race.step()
            // Nothing lets go of her autohelm or changes what it holds: no special case at the edge.
            #expect(race.boats[0].autohelm == autohelm)
            #expect(Self.reachPastTheSides(race) < 1e-9)
            if Self.isTouching(race) {
                if speedGoingIn == nil { speedGoingIn = speed }
                touchingTicks += 1
            }
        }
        // She sailed into the edge and stayed there, touching it once.
        let goingIn = try #require(speedGoingIn)
        #expect(touchingTicks > 6 * Race.tickRate)
        #expect(Self.isTouching(race))
        #expect(race.incidents.obstructionContacts.count == 1)
        // Her wind angle held, not her heading: she turned with the shift, further into the edge.
        #expect(abs(wrapAngle(race.boats[0].sailingAngle - held)) < deg2rad(1))
        #expect(abs(wrapAngle(race.boats[0].heading - (heading + veer))) < deg2rad(1))
        // And slowed there, as any boat at the edge: now 15° off bow on, she keeps a quarter of her speed
        // along it each tick.
        #expect(race.boats[0].speed < 0.25 * goingIn)
    }

    /// A touch lasts while the hull stays within `RaceEdges.touchMargin` of the edge: some ticks' push and
    /// turn leave a boat pinned at the edge a hair clear of it, and she is still touching it.
    @Test func aTouchLastsWhileTheHullIsWithinTheMargin() throws {
        let margin = RaceEdges.touchMargin
        let area = RaceArea(centre: .zero, axis: 0, halfWidth: 100, halfLength: 100)
        // Bow on to the east side, her bow `gap` metres short of it.
        func hull(_ gap: Double) -> [Vec2] { Self.hull(at: Vec2(100 - gap - 2.45, 0), heading: .pi / 2) }
        #expect(RaceEdges.resolve(hull: hull(0.01), area: area, land: []).touches.isEmpty)
        #expect(RaceEdges.isNear(.boundary, hull: hull(0.01), area: area, land: [], within: margin))
        #expect(RaceEdges.isNear(.boundary, hull: hull(margin * 0.9), area: area, land: [], within: margin))
        #expect(!RaceEdges.isNear(.boundary, hull: hull(margin * 1.1), area: area, land: [], within: margin))

        // The same off a land's side and into its corner, and no land: nothing near.
        let land = Venue.LandPolygon(points: [Vec2(100, -50), Vec2(150, -50), Vec2(150, 50), Vec2(100, 50)])
        #expect(RaceEdges.isNear(.land, hull: hull(margin * 0.9), area: area, land: [land], within: margin))
        #expect(!RaceEdges.isNear(.land, hull: hull(margin * 1.1), area: area, land: [land], within: margin))
        #expect(!RaceEdges.isNear(.land, hull: hull(0), area: area, land: [], within: margin))
        let corner = Venue.LandPolygon(points: [Vec2(100.05, 0), Vec2(120, -10), Vec2(120, 10)])
        #expect(abs(Collision.distance(convex: hull(0), simplePolygon: corner.points) - 0.05) < 1e-9)
        #expect(Collision.distance(convex: hull(-0.2), simplePolygon: land.points) == 0)
        // A strip of land across a square, neither's corner in the other: they meet.
        let square = [Vec2(-10, -10), Vec2(10, -10), Vec2(10, 10), Vec2(-10, 10)]
        let strip = [Vec2(-20, -1), Vec2(20, -1), Vec2(20, 1), Vec2(-20, 1)]
        #expect(Collision.penetration(convex: square, simplePolygon: strip) == nil)
        #expect(Collision.distance(convex: square, simplePolygon: strip) == 0)
        #expect(Collision.distance(convex: square, simplePolygon: strip.map { $0 + Vec2(0, 13) }) == 2)
    }

    // MARK: Placement and the race area's queries

    @Test func everyBoatStartsInsideTheRaceArea() throws {
        for seats in [2, 8, 10, 11, 16] {
            for seed: UInt64 in 1...12 {
                let race = testRace(opponents: seats - 1, seed: seed)
                let hullLength = race.boatClass.hull.length
                let outline = race.boatClass.hull.outline
                for boat in race.boats {
                    #expect(race.course.raceArea.inset(boat.position) >= hullLength - 1e-9, "\(seats) seats, seed \(seed)")
                    #expect(boat.hull(outline: outline).allSatisfy(race.course.isInRaceArea))
                }
                race.step()
                #expect(race.exportSnapshot().touchingEdges.isEmpty)
            }
        }
    }

    /// Land near the line, where the start row (#35, #85) would be: a shore under the pin end's half of
    /// the row reaching to 0.3 line lengths below the line, and a rock in the row under the other half.
    /// Every boat still starts a hull length off both, as off the boundary, in a row squeezed up towards
    /// the line, still parallel to it and still clear ahead and astern; the same row without the land puts
    /// some of the fleet on it or against it.
    @Test func everyBoatStartsAHullLengthOffLandNearTheLine() throws {
        var wouldHaveTouched = 0
        for seats in [2, 8, 16] {
            for seed: UInt64 in 1...6 {
                let open = testRace(opponents: seats - 1, seed: seed)
                let c = open.course
                let length = c.startLine.length
                func at(_ across: Double, _ below: Double) -> Vec2 {
                    c.startLine.centre + c.right * (across * length) - c.upwind * (below * length)
                }
                let land = [[at(-8, 6), at(-0.1, 6), at(-0.1, 0.3), at(-8, 0.3)],
                            [at(0.2, 0.55), at(0.3, 0.55), at(0.3, 0.45), at(0.2, 0.45)]]
                var catalog = RaceFileCatalog()
                let venue = try catalog.venues.add(Self.venue(land: land))
                let setup = try RaceSetup(raceSeed: open.setup.raceSeed, seats: open.setup.seats, laps: open.setup.laps,
                                          startSequenceTicks: open.setup.startSequenceTicks, venue: venue)
                let race = try Race(setup: setup, files: RaceFiles(resolving: setup, from: catalog),
                                    mode: .authoritative(windSeed: WindSeed(seed)))
                #expect(race.course.land.count == 2)
                #expect(race.course.startLine == c.startLine)
                let hull = race.boatClass.hull
                for (boat, openBoat) in zip(race.boats, open.boats) {
                    for polygon in land {
                        #expect(Self.clearance(boat.position, from: polygon) >= hull.length - 1e-9,
                                "\(seats) seats, seed \(seed), seat \(boat.id)")
                    }
                    #expect(race.course.raceArea.inset(boat.position) >= hull.length - 1e-9)
                    if land.contains(where: { Self.clearance(openBoat.position, from: $0) < hull.length }) {
                        wouldHaveTouched += 1
                    }
                    // Still one row parallel to the line, in the same order, on the same heading.
                    #expect(abs(c.startLine.side(boat.position) - c.startLine.side(race.boats[0].position)) < 1e-9)
                    #expect(c.startLine.side(boat.position) >= c.startLine.side(openBoat.position) - 1e-9)
                    #expect(boat.heading == openBoat.heading && boat.speed == openBoat.speed)
                }
                for a in race.boats.indices {
                    for b in race.boats.indices where b > a {
                        let (p, q) = (race.boats[a], race.boats[b])
                        #expect(Rules.isClearAstern(p, of: q, hull: hull) || Rules.isClearAstern(q, of: p, hull: hull))
                        let alongP = (p.position - c.startLine.centre).dot(c.right)
                        let alongQ = (q.position - c.startLine.centre).dot(c.right)
                        let openAlongP = (open.boats[a].position - c.startLine.centre).dot(c.right)
                        let openAlongQ = (open.boats[b].position - c.startLine.centre).dot(c.right)
                        #expect((alongP < alongQ) == (openAlongP < openAlongQ))
                    }
                }
                race.step()
                #expect(race.exportSnapshot().touchingEdges.isEmpty, "\(seats) seats, seed \(seed)")
            }
        }
        #expect(wouldHaveTouched > 10)
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
        // Into the skiff's starboard quarter, 1.2 m abaft her widest point, where her side is 0.88 m out.
        let spike = [Vec2(0.5, -1.2), Vec2(5, -2.2), Vec2(5, -0.2)]
        #expect(!hull.contains { Collision.contains(simplePolygon: spike, $0) })
        let contact = Collision.penetration(convex: hull, simplePolygon: spike)
        #expect(contact != nil)
        if let contact {
            #expect(contact.normal.x < -0.99)
            #expect(contact.depth > 0.35 && contact.depth < 0.4)
            let moved = hull.map { $0 + contact.push }
            #expect((Collision.penetration(convex: moved, simplePolygon: spike)?.depth ?? 0) < 1e-9)
        }
    }

    /// A stopped boat the current carries onto the boundary is held inside it.
    @Test func currentDriftIntoTheBoundaryIsHeldAtIt() throws {
        let axis = try Self.course().axis
        // 2 kn up the course, onto the area's windward end.
        let race = try placedRace(current: steadyCurrent(knots: 2, towards: axis), seed: Self.seed,
                                  boatClass: Self.boatClass) { snapshot, race in
            let area = race.course.raceArea
            var boat = snapshot.seats[0].boat
            boat.speed = 0
            boat.heading = boat.windDirection
            boat.rudder = 0
            boat.desiredRudder = 0
            boat.position = area.centre + race.course.upwind * (area.halfLength - 3)
            snapshot.seats[0].boat = boat
            // Head to wind, a touch of rudder keeps the autohelm off, which would bear her away (ADR 0007).
            snapshot.seats[0].heldInput = BoatInput(rudder: Int8(8))
            snapshot.seats[1].boat.position = area.centre
        }
        for _ in 0..<(5 * Race.tickRate) {
            race.step()
            #expect(Self.reachPastTheSides(race) < 1e-9)
        }
        #expect(race.incidents.obstructionContacts.contains { $0.seat == 0 && $0.kind == .boundary })
    }
}
