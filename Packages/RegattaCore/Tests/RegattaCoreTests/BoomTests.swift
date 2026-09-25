import Testing
@testable import RegattaCore

/// #71 acceptance: the boom, sailing by the lee, and what tacks and gybes cost. The dynamics tests
/// sail in a constant wind from the north with no current; the race tests sail a seeded race.
@Suite struct BoomTests {
    let dinghy: BoatClass
    let dt = Race.dt
    /// The wind blows from the north.
    let windFrom = 0.0

    init() throws {
        dinghy = try Fixtures.boatClass()
    }

    func env(knots: Double) -> BoatDynamics.Environment {
        .constant(windDirection: windFrom, windSpeed: metresPerSecond(knots: knots))
    }

    /// Steady on starboard tack (boom to port) at `twa`, at the polar speed.
    func starboardTack(twa: Double, knots: Double) -> BoatDynamics.State {
        let speed = dinghy.polar.speed(twa: twa, tws: metresPerSecond(knots: knots))
        return .init(heading: wrapAngle(windFrom - twa), speed: speed, boomSide: .port)
    }

    /// `angle` radians by the lee with the boom to port: past dead downwind, the wind over the port quarter.
    func byTheLee(_ angle: Double, speed: Double) -> BoatDynamics.State {
        .init(heading: wrapAngle(windFrom + .pi - angle), speed: speed, boomSide: .port)
    }

    func step(_ s: BoatDynamics.State, rudder: Double, knots: Double) -> BoatDynamics.State {
        BoatDynamics.advance(s, control: .init(rudder: rudder), env: env(knots: knots), boatClass: dinghy, dt: dt)
    }

    struct Tap {
        /// Every tick's state, the first before the tap.
        var states: [BoatDynamics.State]
        /// Seconds after the tap when the autopilot let go.
        var letGo: Double?
        var crossings: Int { zip(states, states.dropFirst()).filter { $0.boomSide != $1.boomSide }.count }
    }

    /// One tack/gybe tap from `state`, steered as `Race` steers it: the autopilot until it lets go, then
    /// a helm holding the autopilot's heading, for `seconds` in all.
    func tap(_ state: BoatDynamics.State, knots: Double, seconds: Double = 20) -> Tap {
        var s = state
        var pilot: Autopilot? = .tackOrGybe(heading: s.heading, boomSide: s.boomSide, windDirection: windFrom)
        let target = pilot!.heading
        var result = Tap(states: [s])
        for n in 0..<Int((seconds / dt).rounded()) {
            var rudder = (wrapAngle(target - s.heading) / deg2rad(20)).clamped(to: -1...1)
            if let p = pilot {
                if let r = p.rudder(heading: s.heading, boomSide: s.boomSide, windDirection: windFrom) {
                    rudder = r
                } else {
                    pilot = nil
                    result.letGo = Double(n) * dt
                }
            }
            s = step(s, rudder: rudder, knots: knots)
            result.states.append(s)
        }
        return result
    }

    /// Hull lengths lost over the tap against holding the entry heading and speed for as long,
    /// made good along `direction`.
    func hullLengthsLost(_ run: Tap, along direction: Vec2) -> Double {
        let start = run.states[0]
        let seconds = Double(run.states.count - 1) * dt
        let straight = Vec2.heading(start.heading).dot(direction) * start.speed * seconds
        let made = (run.states.last!.position - start.position).dot(direction)
        return (straight - made) / dinghy.hull.length
    }

    func crossingKinds(_ events: [RaceEvent]) -> [RaceEvent] {
        events.filter {
            switch $0.kind {
            case .tacked, .gybed: true
            default: false
            }
        }
    }

    // MARK: - The boom

    @Test func boomCrossesOnTheTickTheSailingWindChangesSignForwardOfTheBeam() {
        let beat = dinghy.polar.bestUpwind(tws: metresPerSecond(knots: 10))
        var s = starboardTack(twa: beat.twa, knots: 10)
        var signChange: Int?
        var crossing: Int?
        for tick in 1...Int(4 / dt) {
            let next = step(s, rudder: 1, knots: 10) // luffing
            let sailingAngle = BoomSide.port.sailingAngle(relativeWind: wrapAngle(windFrom - next.heading))
            if signChange == nil && sailingAngle < 0 {
                signChange = tick
                #expect(abs(sailingAngle) < .pi / 2)
            }
            if crossing == nil && next.boomSide != s.boomSide { crossing = tick }
            s = next
        }
        #expect(signChange != nil)
        #expect(crossing == signChange)
        #expect(s.boomSide == .starboard)
    }

    @Test(arguments: [(6.0, 29.0, false), (6, 31, true), (16, 14, false), (16, 16, true)])
    func byTheLeePastTheClassLimitGybes(knots: Double, degreesByTheLee: Double, gybes: Bool) {
        let s = byTheLee(deg2rad(degreesByTheLee), speed: metresPerSecond(knots: 4))
        let next = step(s, rudder: 0, knots: knots)
        #expect(next.heading == s.heading)
        #expect((next.boomSide == .starboard) == gybes)
        let sailingAngle = BoomSide.port.sailingAngle(relativeWind: wrapAngle(windFrom - s.heading))
        let crossing = BoatDynamics.boomCrosses(sailingAngle: sailingAngle, tws: metresPerSecond(knots: knots), polar: dinghy.polar)
        #expect(crossing == (gybes ? .gybe : nil))
    }

    @Test func speedTenDegreesByTheLeeIsThePolarAt170LessTwoPercent() {
        let expected = dinghy.polar.speed(twa: deg2rad(170), tws: metresPerSecond(knots: 10)) * 0.98
        #expect(dinghy.polar.byTheLeePenalty == 0.02)
        // From rest she settles on the by-the-lee target, and holding it she keeps it exactly.
        var s = byTheLee(deg2rad(10), speed: 0)
        for _ in 0..<Int(60 / dt) { s = step(s, rudder: 0, knots: 10) }
        #expect(abs(s.speed - expected) < 1e-6, "\(s.speed) vs \(expected)")
        s.speed = expected
        s = step(s, rudder: 0, knots: 10)
        #expect(abs(s.speed - expected) < 1e-12)
        #expect(s.boomSide == .port)
        var boat = Boat(id: 0, isPlayer: false, colorIndex: 0, position: .zero, heading: s.heading, speed: s.speed, boomSide: s.boomSide)
        boat.windDirection = windFrom
        #expect(boat.isByTheLee && boat.tack == .starboard)
    }

    @Test func luffingThroughHeadToWindAndBearingBackCrossesTheBoomTwice() {
        let beat = dinghy.polar.bestUpwind(tws: metresPerSecond(knots: 10))
        var s = starboardTack(twa: beat.twa, knots: 10)
        var states = [s]
        // Luff until the wind is 10° on the other bow, then bear back to close-hauled on starboard.
        while wrapAngle(windFrom - s.heading) > -deg2rad(10), states.count < Int(20 / dt) {
            s = step(s, rudder: 1, knots: 10)
            states.append(s)
        }
        while wrapAngle(windFrom - s.heading) < beat.twa, states.count < Int(40 / dt) {
            s = step(s, rudder: -1, knots: 10)
            states.append(s)
        }
        let crossings = zip(states, states.dropFirst()).filter { $0.boomSide != $1.boomSide }.map(\.1.boomSide)
        #expect(crossings == [.starboard, .port])
    }

    // MARK: - The tap

    @Test func tackTapAtTenKnotsTakesThreeSecondsHalvesTheSpeedAndLosesAHullLength() throws {
        let beat = dinghy.polar.bestUpwind(tws: metresPerSecond(knots: 10))
        let start = starboardTack(twa: beat.twa, knots: 10)
        let run = tap(start, knots: 10)
        #expect(run.crossings == 1)
        #expect(run.states.last!.boomSide == .starboard)
        let letGo = try #require(run.letGo)
        #expect(letGo >= 2.5 && letGo <= 4, "let go after \(letGo) s")
        let bottom = run.states.map(\.speed).min()! / start.speed
        #expect(bottom >= 0.4 && bottom <= 0.6, "bottomed out at \(bottom) of entry speed")
        let lost = hullLengthsLost(run, along: .heading(windFrom))
        #expect(lost >= 0.7 && lost <= 1.3, "lost \(lost) hull lengths")
    }

    /// A gybe from a broad reach, 150°: at 16 kn she is planing (the polar gives 9.5 kn), at 10 kn not.
    @Test func gybeTapLosesAQuarterToHalfAHullLengthAndMoreOffThePlane() {
        let downwind = -Vec2.heading(windFrom)
        let medium = tap(starboardTack(twa: deg2rad(150), knots: 10), knots: 10)
        let planing = tap(starboardTack(twa: deg2rad(150), knots: 16), knots: 16)
        for run in [medium, planing] {
            #expect(run.crossings == 1)
            #expect(run.states.last!.boomSide == .starboard)
        }
        let lostMedium = hullLengthsLost(medium, along: downwind)
        let lostPlaning = hullLengthsLost(planing, along: downwind)
        #expect(lostMedium >= 0.25 && lostMedium <= 0.5, "10 kn gybe lost \(lostMedium) hull lengths")
        #expect(lostPlaning > lostMedium, "16 kn gybe lost \(lostPlaning) hull lengths, 10 kn \(lostMedium)")
    }

    @Test func tapTargetsTheSameWindAngleWithTheBoomOnTheOtherSide() {
        let beat = Autopilot.tackOrGybe(heading: deg2rad(-45), boomSide: .port, windDirection: windFrom)
        #expect(abs(beat.heading - deg2rad(45)) < 1e-12 && beat.boomSide == .starboard)
        let reach = Autopilot.tackOrGybe(heading: deg2rad(150), boomSide: .starboard, windDirection: windFrom)
        #expect(abs(reach.heading - deg2rad(-150)) < 1e-12 && reach.boomSide == .port)
        // 10° by the lee with the boom to port: the wind is already at 170° on the port side.
        let lee = byTheLee(deg2rad(10), speed: 0)
        let fromLee = Autopilot.tackOrGybe(heading: lee.heading, boomSide: .port, windDirection: windFrom)
        #expect(abs(wrapAngle(fromLee.heading - lee.heading)) < 1e-12 && fromLee.boomSide == .starboard)
    }

    @Test func tapFromByTheLeeGybesAndSettlesOnTheSameWindAngle() {
        let start = byTheLee(deg2rad(10), speed: dinghy.polar.speed(twa: deg2rad(170), tws: metresPerSecond(knots: 10)) * 0.98)
        let run = tap(start, knots: 10)
        #expect(run.crossings == 1)
        #expect(run.letGo != nil)
        let end = run.states.last!
        #expect(end.boomSide == .starboard)
        let relativeWind = wrapAngle(windFrom - end.heading)
        #expect(abs(abs(relativeWind) - deg2rad(170)) < deg2rad(3), "settled at \(rad2deg(abs(relativeWind)))°")
        #expect(!BoomSide.isByTheLee(end.boomSide.sailingAngle(relativeWind: relativeWind)))
    }

    // MARK: - In a race

    /// Seat 0 close-hauled on starboard in the race's wind, seat 1 well out of her way.
    func closeHauledRace() throws -> Race {
        let race = testRace(seats: [.human, .human], seed: 3)
        for _ in 0..<10 { race.step() }
        var snapshot = race.exportSnapshot()
        var boat = snapshot.seats[0].boat
        let best = race.boatClass.polar.bestUpwind(tws: boat.windSpeed * boat.shadow)
        boat.heading = wrapAngle(boat.windDirection - best.twa)
        boat.speed = best.speed
        boat.boomSide = .port
        snapshot.seats[0].boat = boat
        snapshot.seats[1].boat.position = boat.position + Vec2(300, 0)
        try race.importSnapshot(snapshot)
        return race
    }

    func closeHauledTWA(_ b: Boat, _ race: Race) -> Double {
        race.boatClass.polar.bestUpwind(tws: b.windSpeed * b.shadow).twa - deg2rad(5)
    }

    @Test func rule13PeriodStartsAtTheBoomCrossingAndEndsAtCloseHauled() throws {
        let race = try closeHauledRace()
        race.tap(.tackGybe, seat: 0, atTick: race.tick + 1)
        var crossedAt: Int?
        var endedAt: Int?
        for _ in 0..<(Race.tickRate * 10) {
            let before = race.boats[0]
            race.step()
            let b = race.boats[0]
            if b.boomSide != before.boomSide {
                #expect(crossedAt == nil)
                crossedAt = race.tick
            }
            if before.isTacking && !b.isTacking {
                endedAt = race.tick
                #expect(before.twa < closeHauledTWA(before, race))
                #expect(b.twa >= closeHauledTWA(b, race))
            }
            // Tacking exactly from the crossing until close-hauled.
            #expect(b.isTacking == (crossedAt != nil && endedAt == nil))
        }
        #expect(crossedAt != nil && endedAt != nil)
        if let crossedAt, let endedAt { #expect(endedAt > crossedAt) }
    }

    @Test func tackAndGybeAreEventsOnTheCrossingTick() throws {
        let race = try closeHauledRace()
        race.tap(.tackGybe, seat: 0, atTick: race.tick + 1)
        var crossings: [RaceEvent] = []
        var events: [RaceEvent] = []
        for _ in 0..<(Race.tickRate * 8) {
            let before = race.boats[0].boomSide
            race.step()
            if race.boats[0].boomSide != before { crossings.append(RaceEvent(tick: race.tick, kind: .tacked(seat: 0))) }
            events += crossingKinds(race.drainEvents())
        }
        #expect(crossings.count == 1)
        #expect(events == crossings)

        // Bear away to a broad reach on the new tack, then tap again: a gybe.
        let windSign: Double = race.boats[0].boomSide == .port ? 1 : -1
        for _ in 0..<(Race.tickRate * 10) {
            let b = race.boats[0]
            let reach = wrapAngle(b.windDirection - windSign * deg2rad(150))
            race.apply(BoatInput(rudder: wrapAngle(reach - b.heading) / deg2rad(20)), seat: 0, atTick: race.tick + 1)
            race.step()
        }
        #expect(crossingKinds(race.drainEvents()) == [])
        race.apply(.neutral, seat: 0, atTick: race.tick + 1)
        race.tap(.tackGybe, seat: 0, atTick: race.tick + 1)
        crossings = []
        events = []
        for _ in 0..<(Race.tickRate * 8) {
            let before = race.boats[0].boomSide
            race.step()
            if race.boats[0].boomSide != before { crossings.append(RaceEvent(tick: race.tick, kind: .gybed(seat: 0))) }
            events += crossingKinds(race.drainEvents())
        }
        #expect(crossings.count == 1)
        #expect(events == crossings)
    }
}
