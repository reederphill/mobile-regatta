import Testing
@testable import RegattaCore

@Suite struct GeometryTests {
    @Test func wrapAngleStaysInRange() {
        #expect(abs(wrapAngle(3 * .pi) - (-.pi)) < 1e-9)
        #expect(abs(wrapAngle(-deg2rad(190)) - deg2rad(170)) < 1e-9)
        #expect(abs(wrapAngle(deg2rad(45)) - deg2rad(45)) < 1e-9)
    }

    @Test func crossingIsDirected() {
        let line = Segment(Vec2(-10, 0), Vec2(10, 0))
        #expect(crossing(from: Vec2(0, -1), to: Vec2(0, 1), over: line) == 1)
        #expect(crossing(from: Vec2(0, 1), to: Vec2(0, -1), over: line) == -1)
        #expect(crossing(from: Vec2(20, -1), to: Vec2(20, 1), over: line) == 0)
        // Landing exactly on the line then leaving counts once.
        #expect(crossing(from: Vec2(0, -1), to: Vec2(0, 0), over: line) == 0)
        #expect(crossing(from: Vec2(0, 0), to: Vec2(0, 1), over: line) == 1)
    }

    @Test func separatingAxisFindsOverlap() {
        let outline = Race.defaultBoatClass.hull.outline
        let a = Boat(id: 0, isPlayer: false, colorIndex: 0, position: .zero, heading: 0, speed: 0)
        var b = a
        b.position = Vec2(1, 0)
        #expect(Collision.penetration(a.hull(outline: outline), b.hull(outline: outline)) != nil)
        b.position = Vec2(5, 0)
        #expect(Collision.penetration(a.hull(outline: outline), b.hull(outline: outline)) == nil)
    }
}

@Suite struct RulesTests {
    let course = try! CourseLayoutTests.layout()

    func boat(_ id: Int, at p: Vec2, heading degrees: Double, wind: Double = 0) -> Boat {
        var b = Boat(id: id, isPlayer: false, colorIndex: id, position: p, heading: deg2rad(degrees), speed: 3)
        b.windDirection = deg2rad(wind)
        b.boomSide = .leeward(ofRelativeWind: b.relativeWind)
        b.status = .racing
        return b
    }

    let hull = Race.defaultBoatClass.hull

    @Test func portKeepsClearOfStarboard() {
        let starboard = boat(1, at: .zero, heading: -45)  // wind over the starboard side
        let port = boat(2, at: Vec2(1, 0), heading: 45)
        #expect(starboard.tack == .starboard)
        #expect(port.tack == .port)
        #expect(Rules.rightOfWay(starboard, port, overlapped: true, hull: hull) == RightOfWay(keepClear: 2, rule: .portStarboard))
    }

    /// Rule 11: overlapped on the same tack, the boat on the other's windward side keeps clear, whichever
    /// way round the pair is asked (#3 bug 1's case, further upwind but to leeward, is in `RightOfWayTests`).
    @Test func windwardKeepsClearOfLeeward() {
        let leeward = boat(1, at: .zero, heading: 90)
        let windward = boat(2, at: Vec2(0, 1.4), heading: 90)
        let expected = RightOfWay(keepClear: 2, rule: .windwardLeeward)
        #expect(Rules.rightOfWay(leeward, windward, overlapped: true, hull: hull) == expected)
        #expect(Rules.rightOfWay(windward, leeward, overlapped: true, hull: hull) == expected)
    }

    @Test func clearAsternKeepsClear() {
        let ahead = boat(1, at: .zero, heading: 90)
        let astern = boat(2, at: Vec2(-4.5, 0), heading: 90)
        #expect(Rules.rightOfWay(ahead, astern, overlapped: false, hull: hull) == RightOfWay(keepClear: 2, rule: .clearAstern))
    }

    @Test func tackingBoatKeepsClear() {
        let steady = boat(1, at: .zero, heading: -45)
        var tacking = boat(2, at: Vec2(1, 0), heading: -45)
        tacking.isTacking = true
        #expect(Rules.rightOfWay(steady, tacking, overlapped: true, hull: hull) == RightOfWay(keepClear: 2, rule: .whileTacking))
    }

    @Test func outsideBoatGivesMarkRoom() {
        let mark = course.elements[CourseLayout.windwardIndex].marks[0].position
        let inside = boat(1, at: mark + Vec2(3, -2), heading: -45)
        let outside = boat(2, at: mark + Vec2(5, -3), heading: -45)
        let call = Rules.judge(inside, outside, overlapped: true, course: course, hull: hull)
        #expect(call?.rule == .givingMarkRoom)
        #expect(call?.offender == 2)
    }
}

/// A two-human race with a 1 s start sequence, stepped to `tick` (by default the tick before the gun),
/// then with seat 0 edited by `place`; seat 1 stays in her slot in the start row, sailing on.
func raceEdited(atTick tick: Int = -1, seed: UInt64 = 5, _ place: (inout Boat, Race) -> Void) throws -> Race {
    let race = testRace(seats: [.human, .human], prestartSeconds: 1, seed: seed)
    while race.tick < tick { race.step() }
    var snapshot = race.exportSnapshot()
    place(&snapshot.seats[0].boat, race)
    try race.importSnapshot(snapshot)
    return race
}

@Suite struct RaceTests {
    /// Steers seat 0 toward `heading` with a simple proportional helm.
    func sail(_ race: Race, heading: Double, seconds: Double) -> [RaceEvent.Kind] {
        var events: [RaceEvent.Kind] = []
        for _ in 0..<Int(seconds * Double(Race.tickRate)) {
            let rudder = wrapAngle(heading - race.boats[0].heading) / deg2rad(20)
            race.apply(BoatInput(rudder: rudder), seat: 0, atTick: race.tick + 1)
            race.step()
            events += race.drainEvents().map(\.kind)
        }
        return events
    }

    /// Over at the gun (#85): recalled alone, cleared once her whole hull is back on the pre-start side,
    /// then started by crossing the line.
    @Test func boatOverTheLineAtTheGunIsOCSAndMustReturn() {
        // Both start in the row (#35). Seat 1 is a second human who sends no inputs, so she reaches on
        // below the line, out of the way; seat 0 luffs from her slot and sails up over it before the gun.
        let race = testRace(seats: [.human, .human], prestartSeconds: 44, seed: 1)
        let early = sail(race, heading: deg2rad(-45), seconds: 45)
        #expect(early.contains(.ocsNotice(recipient: 0)))
        #expect(!early.contains(.ocsNotice(recipient: 1)))
        #expect(race.boats[0].status == .ocs)
        #expect(race.boats[1].status == .prestart)

        var back: [RaceEvent.Kind] = []
        for _ in 0..<40 where race.boats[0].status == .ocs { back += sail(race, heading: .pi, seconds: 1) }
        #expect(back.contains(.cleared(seat: 0)))
        #expect(furthestOver(race) <= 0, "cleared with her whole hull on the pre-start side")

        // She may be off an end of the line: run deeper, as far below it as she is out to the side but
        // no closer than 10 m to the race area's edge (#82), then sail up at the line's centre, never closer
        // than 45° to the axis, to cross between its ends.
        let line = race.course.startLine
        func across() -> Double { (race.boats[0].position - line.centre).dot(race.course.right) }
        while -line.side(race.boats[0].position) < abs(across()) + 10,
              race.course.raceArea.inset(race.boats[0].position) > 10 {
            _ = sail(race, heading: race.course.axis + .pi, seconds: 1)
        }
        var start: [RaceEvent.Kind] = []
        for _ in 0..<90 where race.boats[0].status == .prestart {
            let toCentre = wrapAngle((line.centre - race.boats[0].position).bearing - race.course.axis)
            let offAxis = toCentre < 0 ? min(toCentre, -deg2rad(45)) : max(toCentre, deg2rad(45))
            start += sail(race, heading: race.course.axis + offAxis, seconds: 1)
        }
        #expect(start.contains(.started(seat: 0)))
        #expect(race.boats[0].status == .racing)
    }

    // MARK: - The start row (#35) and OCS by hull (#85)

    /// `boat`'s slot in the start row, 0 at the pin end, from how far along the line she is.
    func rowSlot(_ boat: Boat, in race: Race) -> Int {
        let span = race.course.placement.spreadLineLengths * race.course.startLine.length
        let along = (boat.position - race.course.startLine.centre).dot(race.course.right) + span / 2
        return Int((along / span * Double(race.boats.count) - 0.5).rounded())
    }

    /// How far the bow and the stern reach from the centre along the boat, metres (the stern's negative).
    let bow = Race.defaultBoatClass.hull.outline.map(\.y).max()!
    let stern = Race.defaultBoatClass.hull.outline.map(\.y).min()!

    /// The largest start-line side of any point of seat 0's hull: positive when some of it is over.
    func furthestOver(_ race: Race, seat: Int = 0) -> Double {
        race.boats[seat].hull(outline: race.boatClass.hull.outline).map(race.course.startLine.side).max()!
    }

    @Test func startRowPlacementMatchesFormula() {
        let race = testRace(opponents: 9, seed: 7)
        let n = race.boats.count, line = race.course.startLine, row = race.course.placement
        #expect(n == 10)
        #expect(race.time == -60)
        let span = 1.5 * line.length
        let polarSpeed = race.boatClass.polar.speed(twa: deg2rad(90), tws: race.windSetup.baseStrength)
        #expect(row.trueWindAngle == deg2rad(90) && row.polarSpeedFraction == 1)
        var along: [Double] = []
        for b in race.boats {
            #expect(abs(line.side(b.position) - (-0.5 * line.length)) < 1e-9)
            along.append((b.position - line.centre).dot(race.course.right))
            #expect(b.tack == .starboard)
            // Reaching towards the pin: 90° off the mean wind, the axis less a right angle.
            #expect(abs(wrapAngle(b.heading - (race.course.axis - .pi / 2))) < 1e-9)
            #expect(abs(wrapAngle(race.windSetup.meanDirection - b.heading) - deg2rad(90)) < 1e-9)
            #expect(abs(b.speed - polarSpeed) < 1e-9)
        }
        let slots = (0..<n).map { -span / 2 + span * (Double($0) + 0.5) / Double(n) }
        for (a, s) in zip(along.sorted(), slots) { #expect(abs(a - s) < 1e-9) }
    }

    @Test func startRowOrderIsSeededShuffle() {
        func order(_ seed: UInt64) -> [Int] {
            let race = testRace(opponents: 9, seed: seed)
            return race.boats.map { rowSlot($0, in: race) }
        }
        #expect(order(11) == order(11))
        #expect(order(11) != order(12))
        #expect(order(11).sorted() == Array(0..<10))
        // Our own Fisher–Yates on the race seed's start-row stream, seat s in slot order[s] (ADR 0002).
        var expected = Array(0..<10)
        var rng = SplitMix64(seed: 11, stream: CourseLayout.startRowStream)
        rng.shuffle(&expected)
        #expect(order(11) == expected)
    }

    /// #35 "clear ahead and clear astern": every pair in the row is clear of the other, at every fleet size.
    @Test func startRowSlotsNeverOverlap() {
        let hull = Race.defaultBoatClass.hull
        for n in RaceSetup.fleetSizes {
            let race = testRace(opponents: n - 1, seed: UInt64(n))
            #expect(race.time == -60)
            for a in 0..<n {
                for b in (a + 1)..<n {
                    let (p, q) = (race.boats[a], race.boats[b])
                    #expect(Collision.penetration(p.hull(outline: hull.outline), q.hull(outline: hull.outline)) == nil)
                    #expect(Rules.isClearAstern(p, of: q, hull: hull) || Rules.isClearAstern(q, of: p, hull: hull),
                            "\(n) boats: seats \(a) and \(b) overlap")
                }
            }
        }
    }

    @Test func bowOverLineAtGunIsOCS() throws {
        for over in [0.3, -0.3] {
            // Pointing up the course at the line's centre, her bow `over` metres over it and her centre below.
            let race = try raceEdited { boat, race in
                boat.heading = race.course.axis
                boat.position = race.course.startLine.centre + race.course.upwind * (over - bow)
            }
            #expect(abs(furthestOver(race) - over) < 1e-9)
            #expect(race.course.startLine.side(race.boats[0].position) < 0)
            race.step()
            #expect(race.tick == 0)
            let events = race.drainEvents().map(\.kind)
            #expect(events.contains(.ocsNotice(recipient: 0)) == (over > 0))
            #expect(!events.contains(.ocsNotice(recipient: 1)))
            #expect(race.boats[0].status == (over > 0 ? .ocs : .prestart))
            #expect(race.boats[1].status == .prestart)
        }
    }

    /// Stern over and centre below, at the gun and on the way back: OCS until her whole hull is back.
    @Test func sternOverLineAtGunIsOCS() throws {
        // Running straight back down the axis at the line's centre, her stern 0.3 m over it.
        let race = try raceEdited { boat, race in
            boat.heading = race.course.axis + .pi
            boat.speed = 2
            boat.position = race.course.startLine.centre + race.course.upwind * (0.3 + stern)
        }
        #expect(abs(furthestOver(race) - 0.3) < 1e-9)
        #expect(race.course.startLine.side(race.boats[0].position) < 0)
        race.step()
        #expect(race.drainEvents().map(\.kind).contains(.ocsNotice(recipient: 0)))
        #expect(race.boats[0].status == .ocs)

        var clearedAt: Int?
        for _ in 0..<60 where clearedAt == nil {
            #expect(race.course.isReturning(race.boats[0]))
            race.step()
            let events = race.drainEvents().map(\.kind)
            if furthestOver(race) > 0 {
                #expect(race.boats[0].status == .ocs, "centre below, stern still over at tick \(race.tick)")
                #expect(!events.contains(.cleared(seat: 0)))
            } else {
                #expect(events.contains(.cleared(seat: 0)))
                clearedAt = race.tick
            }
        }
        #expect(clearedAt != nil)
        #expect(race.boats[0].status == .prestart)
        #expect(!race.course.isReturning(race.boats[0]))
    }

    @Test func bowCrossingLineStartsThatTick() throws {
        // After the gun, sailing up the course with her bow 1 cm below the line: at its centre, and off
        // the committee boat's end, where she crosses only the line's extension.
        for across in [0.0, 1.0] {
            let race = try raceEdited(atTick: 2) { boat, race in
                let line = race.course.startLine
                boat.heading = race.course.axis
                boat.speed = 3
                boat.position = line.centre + race.course.right * (across * (line.length / 2 + 5))
                    + race.course.upwind * (-0.01 - bow)
            }
            #expect(race.boats[0].status == .prestart)
            race.step()
            let events = race.drainEvents().map(\.kind)
            #expect(furthestOver(race) > 0)
            #expect(race.course.startLine.side(race.boats[0].position) < 0)
            #expect(events.contains(.started(seat: 0)) == (across == 0))
            #expect(race.boats[0].status == (across == 0 ? .racing : .prestart))
        }
    }

    @Test func autopilotTackMirrorsHeading() {
        let race = testRace(seats: [.human, .human], seed: 3)
        let before = race.boats[0]
        race.tap(.tackGybe, seat: 0, atTick: race.tick + 1)
        for _ in 0..<(Race.tickRate * 5) { race.step() }
        #expect(race.boats[0].tack != before.tack || race.boats[0].twa > deg2rad(80))
    }
}
