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
        let a = Boat(id: 0, name: "a", isPlayer: false, colorIndex: 0, position: .zero, heading: 0, speed: 0)
        var b = a
        b.position = Vec2(1, 0)
        #expect(Collision.penetration(a.hull(), b.hull()) != nil)
        b.position = Vec2(5, 0)
        #expect(Collision.penetration(a.hull(), b.hull()) == nil)
    }
}

@Suite struct PolarTests {
    @Test func noGoZoneIsDead() {
        #expect(Polar.dinghy.ratio(twa: deg2rad(20)) == 0)
    }

    @Test func reachingIsFastest() {
        let p = Polar.dinghy
        #expect(p.ratio(twa: deg2rad(95)) > p.ratio(twa: deg2rad(45)))
        #expect(p.ratio(twa: deg2rad(95)) > p.ratio(twa: .pi))
    }
}

@Suite struct RulesTests {
    let course = Course.standard()

    func boat(_ id: Int, at p: Vec2, heading degrees: Double, wind: Double = 0) -> Boat {
        var b = Boat(id: id, name: "\(id)", isPlayer: false, colorIndex: id, position: p, heading: deg2rad(degrees), speed: 3)
        b.windDirection = deg2rad(wind)
        b.status = .racing
        return b
    }

    @Test func portKeepsClearOfStarboard() {
        let starboard = boat(1, at: .zero, heading: -45)  // wind over the starboard side
        let port = boat(2, at: Vec2(1, 0), heading: 45)
        #expect(starboard.tack == .starboard)
        #expect(port.tack == .port)
        #expect(Rules.judge(starboard, port, course: course) == RuleCall(rule: .portStarboard, offender: 2, victim: 1))
    }

    @Test func windwardKeepsClearOfLeeward() {
        let leeward = boat(1, at: .zero, heading: 90)
        let windward = boat(2, at: Vec2(0, 1.4), heading: 90)
        #expect(Rules.judge(leeward, windward, course: course).offender == 2)
        #expect(Rules.judge(leeward, windward, course: course).rule == .windwardLeeward)
    }

    @Test func clearAsternKeepsClear() {
        let ahead = boat(1, at: .zero, heading: 90)
        let astern = boat(2, at: Vec2(-4.5, 0), heading: 90)
        #expect(Rules.judge(ahead, astern, course: course) == RuleCall(rule: .clearAstern, offender: 2, victim: 1))
    }

    @Test func tackingBoatKeepsClear() {
        let steady = boat(1, at: .zero, heading: -45)
        var tacking = boat(2, at: Vec2(1, 0), heading: -45)
        tacking.isTacking = true
        #expect(Rules.judge(steady, tacking, course: course).rule == .whileTacking)
        #expect(Rules.judge(steady, tacking, course: course).offender == 2)
    }

    @Test func outsideBoatGivesMarkRoom() {
        let mark = course.marks[0].position
        let inside = boat(1, at: mark + Vec2(3, -2), heading: -45)
        let outside = boat(2, at: mark + Vec2(5, -3), heading: -45)
        let call = Rules.judge(inside, outside, course: course)
        #expect(call.rule == .markRoom)
        #expect(call.offender == 2)
    }
}

@Suite struct RaceTests {
    @Test func windwardMarkIsRoundedToPort() {
        let course = Course.standard()
        let m = course.marks[0].position
        let path = [m + Vec2(6, -10), m + Vec2(6, 5), m + Vec2(-8, 6)]
        var stage = 0
        let gates = course.gates(forMark: 0)
        for k in 0..<(path.count - 1) where stage < gates.count {
            if crossing(from: path[k], to: path[k + 1], over: gates[stage]) == 1 { stage += 1 }
        }
        #expect(stage == 2)
    }

    /// Steers the player toward `heading` with a simple proportional helm.
    func sail(_ race: Race, heading: Double, seconds: Double) -> [RaceEvent] {
        var events: [RaceEvent] = []
        for _ in 0..<Int(seconds * 60) {
            race.setPlayerRudder(wrapAngle(heading - race.player.heading) / deg2rad(20))
            race.step(1.0 / 60)
            events += race.drainEvents()
        }
        return events
    }

    @Test func boatOverTheLineAtTheGunIsOCSAndMustReturn() {
        let race = Race(config: .init(opponents: 0, prestartSeconds: 40, seed: 1))
        let early = sail(race, heading: deg2rad(-45), seconds: 41)
        #expect(early.contains(.ocs(boat: 0)))
        #expect(race.player.status == .ocs)

        let back = sail(race, heading: .pi, seconds: 15)
        #expect(back.contains(.cleared(boat: 0)))

        // The boat is now off the pin end: run deeper, then port tack brings it
        // back up between the ends of the line.
        _ = sail(race, heading: .pi, seconds: 10)
        let start = sail(race, heading: deg2rad(45), seconds: 40)
        #expect(start.contains(.started(boat: 0)))
        #expect(race.player.status == .racing)
    }

    @Test func autopilotTackMirrorsHeading() {
        let race = Race(config: .init(opponents: 0, seed: 3))
        let before = race.player
        race.playerTackOrGybe()
        for _ in 0..<(60 * 5) { race.step(1.0 / 60) }
        #expect(race.player.tack != before.tack || race.player.twa > deg2rad(80))
    }

    @Test func botFleetCompletesARace() {
        let race = Race(config: .init(opponents: 7, laps: 2, prestartSeconds: 45, seed: 42, autopilotPlayer: true))
        let dt = 1.0 / 30
        var steps = 0
        while !race.isOver && steps < Int(1_500 / dt) {
            race.step(dt)
            steps += 1
        }
        let finishers = race.boats.filter { $0.status == .finished }
        #expect(race.isOver)
        #expect(finishers.count >= 5, "finished: \(finishers.map(\.name)), statuses: \(race.boats.map(\.status))")
    }
}
