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
    let course = Course.standard(zoneRadius: Race.defaultRulesConfiguration.content.zoneRadius(hullLength: Race.defaultBoatClass.hull.length))

    func boat(_ id: Int, at p: Vec2, heading degrees: Double, wind: Double = 0) -> Boat {
        var b = Boat(id: id, isPlayer: false, colorIndex: id, position: p, heading: deg2rad(degrees), speed: 3)
        b.windDirection = deg2rad(wind)
        b.boomSide = .leeward(ofRelativeWind: b.relativeWind)
        b.status = .racing
        return b
    }

    @Test func portKeepsClearOfStarboard() {
        let starboard = boat(1, at: .zero, heading: -45)  // wind over the starboard side
        let port = boat(2, at: Vec2(1, 0), heading: 45)
        #expect(starboard.tack == .starboard)
        #expect(port.tack == .port)
        #expect(Rules.judge(starboard, port, course: course, hull: Race.defaultBoatClass.hull) == Verdict(rule: .portStarboard, offender: 2, victim: 1))
    }

    @Test func windwardKeepsClearOfLeeward() {
        let leeward = boat(1, at: .zero, heading: 90)
        let windward = boat(2, at: Vec2(0, 1.4), heading: 90)
        #expect(Rules.judge(leeward, windward, course: course, hull: Race.defaultBoatClass.hull).offender == 2)
        #expect(Rules.judge(leeward, windward, course: course, hull: Race.defaultBoatClass.hull).rule == .windwardLeeward)
    }

    @Test func clearAsternKeepsClear() {
        let ahead = boat(1, at: .zero, heading: 90)
        let astern = boat(2, at: Vec2(-4.5, 0), heading: 90)
        #expect(Rules.judge(ahead, astern, course: course, hull: Race.defaultBoatClass.hull) == Verdict(rule: .clearAstern, offender: 2, victim: 1))
    }

    @Test func tackingBoatKeepsClear() {
        let steady = boat(1, at: .zero, heading: -45)
        var tacking = boat(2, at: Vec2(1, 0), heading: -45)
        tacking.isTacking = true
        #expect(Rules.judge(steady, tacking, course: course, hull: Race.defaultBoatClass.hull).rule == .whileTacking)
        #expect(Rules.judge(steady, tacking, course: course, hull: Race.defaultBoatClass.hull).offender == 2)
    }

    @Test func outsideBoatGivesMarkRoom() {
        let mark = course.marks[0].position
        let inside = boat(1, at: mark + Vec2(3, -2), heading: -45)
        let outside = boat(2, at: mark + Vec2(5, -3), heading: -45)
        let call = Rules.judge(inside, outside, course: course, hull: Race.defaultBoatClass.hull)
        #expect(call.rule == .givingMarkRoom)
        #expect(call.offender == 2)
    }
}

@Suite struct RaceTests {
    @Test func windwardMarkIsRoundedToPort() {
        let course = Course.standard(zoneRadius: Race.defaultRulesConfiguration.content.zoneRadius(hullLength: Race.defaultBoatClass.hull.length))
        let m = course.marks[0].position
        let path = [m + Vec2(6, -10), m + Vec2(6, 5), m + Vec2(-8, 6)]
        var stage = 0
        let gates = course.gates(forMark: 0)
        for k in 0..<(path.count - 1) where stage < gates.count {
            if crossing(from: path[k], to: path[k + 1], over: gates[stage]) == 1 { stage += 1 }
        }
        #expect(stage == 2)
    }

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

    @Test func boatOverTheLineAtTheGunIsOCSAndMustReturn() {
        // Seat 1 is a second human who sends no inputs, so she sails straight on out of the way.
        // 44 s: the class's turn rate costs a few seconds tacking onto port at the start of the run.
        let race = testRace(seats: [.human, .human], prestartSeconds: 44, seed: 1)
        let early = sail(race, heading: deg2rad(-45), seconds: 45)
        #expect(early.contains(.ocsNotice(recipient: 0)))
        #expect(race.boats[0].status == .ocs)

        let back = sail(race, heading: .pi, seconds: 15)
        #expect(back.contains(.cleared(seat: 0)))

        // The boat is now off the pin end: run deeper, then port tack brings it
        // back up between the ends of the line.
        _ = sail(race, heading: .pi, seconds: 10)
        let start = sail(race, heading: deg2rad(45), seconds: 40)
        #expect(start.contains(.started(seat: 0)))
        #expect(race.boats[0].status == .racing)
    }

    @Test func autopilotTackMirrorsHeading() {
        let race = testRace(seats: [.human, .human], seed: 3)
        let before = race.boats[0]
        race.tap(.tackGybe, seat: 0, atTick: race.tick + 1)
        for _ in 0..<(Race.tickRate * 5) { race.step() }
        #expect(race.boats[0].tack != before.tack || race.boats[0].twa > deg2rad(80))
    }
}
