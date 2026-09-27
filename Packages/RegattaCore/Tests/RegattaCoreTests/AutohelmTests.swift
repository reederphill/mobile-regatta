import Foundation
import Testing
@testable import RegattaCore

/// fleet-rules@1 with a race area kilometres across (#82): open water, for races sailed far from every
/// mark and every edge of the race area.
let openWaterRules: RulesConfigFile = {
    var text = String(decoding: try! RulesConfigFile.bundledData(id: "fleet-rules", version: 1)!, as: UTF8.self)
    for (key, bundled, open) in [("acrossAxisBeatFraction", "0.75", "20"), ("belowLineLineLengths", "1", "30"),
                                 ("aboveWindwardBeatFraction", "0.25", "5")] {
        let old = #""\#(key)": \#(bundled)"#
        precondition(text.components(separatedBy: old).count == 2, "fleet-rules@1's \(key) has moved")
        text = text.replacingOccurrences(of: old, with: #""\#(key)": \#(open)"#)
    }
    return try! RulesConfigFile(data: Data(text.utf8))
}()

/// A race of two humans in a wind a test scripts (`Race.init(setup:files:mode:current:wind:)`): the same
/// everywhere on the water, from `wind(seconds)` since the sequence began, with no current, and in open
/// water (`openWaterRules`, or `rules`). Seat 0 is far from every mark and every edge, seat 1 far from her;
/// `place` sets seat 0 up in the first tick's wind, with the rudder centred and no autohelm yet, so the next
/// step engages it on her placed angle, as a player letting go. The boats sail `boatClass`: by default
/// ilca-dinghy@3, the schema-2 class #230's tests were written for.
func scriptedWindRace(boatClass: FileRef? = nil, rules: RulesConfigFile = openWaterRules,
                      wind: @escaping (_ seconds: Double) -> Wind,
                      place: (inout Boat, BoatClass) -> Void) throws -> Race {
    let sequence = 600 * Race.tickRate
    let boatClass = try boatClass ?? BoatClassFile.bundled(id: Fixtures.classID, version: Fixtures.version).ref
    var catalog = RaceFileCatalog()
    try catalog.rulesConfigurations.add(rules)
    let setup = try RaceSetup(raceSeed: RaceSeed(3), seats: [.human, .human], laps: 1, startSequenceTicks: sequence,
                              boatClass: boatClass, rulesConfiguration: rules.ref)
    let race = try Race(setup: setup, files: RaceFiles(resolving: setup, from: catalog),
                        mode: .authoritative(windSeed: WindSeed(3)),
                        current: CurrentField(current: nil, tideStateAtGun: 0),
                        wind: { tick in
                            let w = wind(Double(tick + sequence) / Double(Race.tickRate))
                            return GroundWind(direction: wrapAngle(w.direction), speed: w.speed)
                        })
    race.step()
    var snapshot = race.exportSnapshot()
    let away = race.course.startLine.centre + race.course.right * 1_500
    var boat = snapshot.seats[0].boat
    boat.position = away
    boat.rudder = 0
    boat.desiredRudder = 0
    boat.autohelm = nil
    place(&boat, race.boatClass)
    snapshot.seats[0].boat = boat
    snapshot.seats[0].heldInput = .neutral
    snapshot.seats[1].boat.position = away + race.course.right * 1_500
    try race.importSnapshot(snapshot)
    return race
}

/// A steady wind from `direction` at `knots`.
func steadyWind(knots: Double, from direction: Double = 0) -> (Double) -> Wind {
    { _ in Wind(direction: direction, speed: metresPerSecond(knots: knots)) }
}

/// #230 acceptance: a centred rudder holds the wind angle (ADR 0007).
@Suite struct AutohelmTests {
    let dinghy: BoatClass

    init() throws {
        dinghy = try Fixtures.boatClass()
    }

    /// Her boom to `boom`, the wind at `sailingAngle` (`BoomSide.sailingAngle`) in her wind, at the polar's speed.
    func sailing(_ sailingAngle: Double, boom: BoomSide = .port) -> (inout Boat, BoatClass) -> Void {
        { boat, boatClass in
            boat.boomSide = boom
            boat.heading = wrapAngle(boat.windDirection - boom.windSign * sailingAngle)
            boat.speed = boatClass.polar.speed(twa: sailingAngle, tws: boat.windSpeed)
        }
    }

    func upwindGroove(knots: Double) -> Double { dinghy.polar.bestUpwind(tws: metresPerSecond(knots: knots)).twa }

    /// Whether `boat`'s autohelm holds `angle` (to a rounding of it), not sailing the tap.
    func holds(_ boat: Boat, _ angle: Double) -> Bool {
        guard let helm = boat.autohelm, !helm.isTapping, let held = helm.target.angle else { return false }
        return abs(wrapAngle(held - angle)) < 1e-9
    }

    func steps(_ race: Race, seconds: Double, each: (Boat) -> Void = { _ in }) {
        for _ in 0..<Int((seconds * Double(Race.tickRate)).rounded()) {
            race.step()
            each(race.boats[0])
        }
    }

    func degrees(_ radians: Double) -> Double { rad2deg(radians) }

    // MARK: - Holding the angle

    @Test func centredRudderHoldsTrueWindAngleThroughAShift() throws {
        let angle = deg2rad(70)
        // 10 kn from the north, veering 10° at 20 s.
        let race = try scriptedWindRace(wind: { t in Wind(direction: t < 20 ? 0 : deg2rad(10), speed: metresPerSecond(knots: 10)) },
                                        place: sailing(angle))
        steps(race, seconds: 1)
        #expect(holds(race.boats[0], angle))
        steps(race, seconds: 18)
        let before = race.boats[0]
        #expect(abs(degrees(before.sailingAngle - angle)) < 0.01)
        steps(race, seconds: 20)
        let after = race.boats[0]
        let error = degrees(wrapAngle(after.sailingAngle - angle))
        #expect(abs(error) <= 1, "TWA \(degrees(after.sailingAngle))° after the shift")
        let turned = degrees(wrapAngle(after.heading - before.heading))
        #expect(abs(turned - 10) <= 1, "turned \(turned)° with a 10° veer")
        #expect(after.boomSide == before.boomSide)
        #expect(holds(after, angle), "the target is the angle, not a heading")
    }

    @Test func releaseWithinSnapWidthTakesTheGroove() throws {
        let groove = upwindGroove(knots: 10)
        for (offset, takesGroove) in [(2.0, true), (-2.0, true), (5.0, false), (-5.0, false)] {
            let angle = groove + deg2rad(offset)
            let race = try scriptedWindRace(wind: steadyWind(knots: 10), place: sailing(angle))
            steps(race, seconds: 20)
            let boat = race.boats[0]
            #expect(takesGroove ? boat.autohelm == Autohelm(target: .groove(.upwind)) : holds(boat, angle),
                    "let go \(offset)° off the groove")
            let settled = takesGroove ? groove : angle
            #expect(abs(degrees(boat.sailingAngle - settled)) <= 0.1, "let go \(offset)° off: sailing \(degrees(boat.sailingAngle))°")
        }
        // Downwind the snap is 5°, reaching by the lee as far as not, and the groove at 180° is sailed
        // the dead-run margin short of it.
        let deadRun = Double.pi - dinghy.steering.autohelm.deadRunMargin
        for (angle, takesGroove) in [(deg2rad(176), true), (deg2rad(-176), true), (deg2rad(172), false)] {
            let race = try scriptedWindRace(wind: steadyWind(knots: 12), place: sailing(angle))
            steps(race, seconds: 20)
            let boat = race.boats[0]
            #expect(takesGroove ? boat.autohelm == Autohelm(target: .groove(.downwind)) : holds(boat, angle))
            let settled = takesGroove ? deadRun : angle
            #expect(abs(degrees(wrapAngle(boat.sailingAngle - settled))) <= 0.1, "let go at \(degrees(angle))°")
            #expect(boat.boomSide == .port)
        }
    }

    @Test func grooveFollowsWindStrength() throws {
        // 4 kn building to 14 kn over the minute after 10 s.
        let knots = { (t: Double) in 4 + 10 * ((t - 10) / 60).clamped(to: 0...1) }
        let race = try scriptedWindRace(wind: { t in Wind(direction: 0, speed: metresPerSecond(knots: knots(t))) },
                                        place: sailing(upwindGroove(knots: 4)))
        steps(race, seconds: 10)
        #expect(race.boats[0].autohelm == Autohelm(target: .groove(.upwind)))
        var worst = 0.0
        steps(race, seconds: 80) { boat in
            let best = self.dinghy.polar.bestUpwind(tws: boat.polarWindSpeed).twa
            worst = max(worst, abs(self.degrees(boat.sailingAngle - best)))
        }
        #expect(worst <= 1, "strayed \(worst)° from the best upwind angle as the wind built")
        let boat = race.boats[0]
        #expect(abs(degrees(boat.sailingAngle - upwindGroove(knots: 14))) <= 0.1)
        #expect(boat.autohelm == Autohelm(target: .groove(.upwind)))
    }

    /// #248 (#245, overriding part of #219): the skiff's grooves follow a ~30 s average of the wind
    /// strength at the boat, not the wind right now. A 10 s puff barely moves the downwind groove, so
    /// bearing away in it stays the player's call; a build that lasts a minute moves it all the way.
    @Test func skiffGrooveFollowsAveragedWindStrength() throws {
        let skiff = try SkiffFixtures.boatClass()
        let ref = try BoatClassFile.bundled(id: SkiffFixtures.classID, version: SkiffFixtures.version).ref
        #expect(skiff.steering.autohelm.grooveWindAverage == 30)
        func groove(_ knots: Double) -> Double {
            Autohelm.grooveAngle(.downwind, tws: metresPerSecond(knots: knots), boatClass: skiff)
        }
        // 10 kn, a 13 kn puff from 30 s to 40 s, then 10 kn until it builds to 14 kn at 100 s and holds.
        let knots = { (t: Double) -> Double in (30..<40).contains(t) ? 13 : t < 100 ? 10 : 14 }
        let race = try scriptedWindRace(boatClass: ref, wind: { t in Wind(direction: 0, speed: metresPerSecond(knots: knots(t))) },
                                        place: sailing(groove(10)))
        #expect(race.boatClass.name == "Skiff")
        steps(race, seconds: 25)
        #expect(race.boats[0].autohelm == Autohelm(target: .groove(.downwind)))
        let instantMove = abs(groove(13) - groove(10))
        #expect(instantMove >= deg2rad(3.5), "the wind right now would move the groove \(degrees(instantMove))°")

        // The puff, and the minute after it.
        var worst = 0.0
        steps(race, seconds: 70) { boat in
            let reading = boat.autohelmReading(in: skiff)!
            worst = max(worst, abs(reading.grooveAngle - groove(10)))
        }
        #expect(worst < instantMove / 3 && worst < deg2rad(1.5), "a 10 s puff moved the groove \(degrees(worst))°")

        // A minute into the build the groove has followed it, and she sails it.
        steps(race, seconds: 65)
        let boat = race.boats[0]
        let reading = try #require(boat.autohelmReading(in: skiff))
        #expect(abs(degrees(reading.grooveAngle - groove(14))) < 1, "groove \(degrees(reading.grooveAngle))° in 14 kn")
        #expect(abs(degrees(boat.sailingAngle - reading.grooveAngle)) < 1)
        let followed = (boat.grooveWindSpeed - metresPerSecond(knots: 10)) / metresPerSecond(knots: 4)
        #expect(followed > 0.85 && followed < 1, "the groove's wind followed \(followed) of the build")
    }

    /// A schema-2 class has no average: its grooves read the wind right now, exactly (#230's behaviour).
    @Test func schemaTwoGroovesReadTheWindRightNow() throws {
        #expect(dinghy.steering.autohelm.grooveWindAverage == 0)
        let race = try scriptedWindRace(wind: { t in Wind(direction: 0, speed: metresPerSecond(knots: 6 + t / 10)) },
                                        place: sailing(upwindGroove(knots: 6)))
        steps(race, seconds: 20) { boat in
            #expect(boat.averagedWindSpeed == boat.polarWindSpeed)
            #expect(boat.grooveWindSpeed == boat.polarWindSpeed)
        }
    }

    @Test func pinchHoldsUntilRudderMoves() throws {
        let pinch = upwindGroove(knots: 10) - deg2rad(5)
        let race = try scriptedWindRace(wind: steadyWind(knots: 10), place: sailing(pinch))
        steps(race, seconds: 5)
        let start = race.boats[0].heading
        var drift = 0.0
        steps(race, seconds: 60) { boat in
            drift = max(drift, abs(self.degrees(wrapAngle(boat.sailingAngle - pinch))))
        }
        #expect(drift < 0.01, "drifted \(drift)° off the pinch")
        #expect(abs(wrapAngle(race.boats[0].heading - start)) < 1e-9)
        #expect(holds(race.boats[0], pinch))

        // Bearing away on the rudder lets go; centring it captures the new angle.
        race.apply(BoatInput(rudder: -0.5), seat: 0, atTick: race.tick + 1)
        steps(race, seconds: 1)
        #expect(race.boats[0].autohelm == nil)
        race.apply(.neutral, seat: 0, atTick: race.tick + 1)
        race.step()
        let recaptured = try #require(race.boats[0].autohelm?.target.angle)
        #expect(recaptured > pinch + deg2rad(10), "bore away to \(degrees(recaptured))°")
    }

    @Test func releaseInsideNoGoBearsAwayToGroove() throws {
        for boom in [BoomSide.port, .starboard] {
            let race = try scriptedWindRace(wind: steadyWind(knots: 10)) { boat, boatClass in
                self.sailing(deg2rad(15), boom: boom)(&boat, boatClass)
                boat.speed = 2
            }
            var events: [RaceEvent.Kind] = []
            steps(race, seconds: 15) { _ in events += race.drainEvents().map(\.kind) }
            let boat = race.boats[0]
            #expect(boat.autohelm == Autohelm(target: .groove(.upwind)))
            #expect(boat.boomSide == boom, "she bore away on her own tack")
            #expect(abs(degrees(boat.sailingAngle - upwindGroove(knots: 10))) <= 0.5, "sailing \(degrees(boat.sailingAngle))°")
            #expect(events.isEmpty, "no snap and no tack: \(events)")
        }
    }

    @Test func neverGybesByTheLee() throws {
        // 10° by the lee in 10 kn (limit 22.5°); the wind veers 20° over 4 s, which would carry her heading
        // 30° by the lee. She follows it: heads up on starboard tack, the boom where it was.
        let byTheLee = deg2rad(-170)
        let veer = try scriptedWindRace(
            wind: { t in Wind(direction: deg2rad(20) * ((t - 10) / 4).clamped(to: 0...1), speed: metresPerSecond(knots: 10)) },
            place: sailing(byTheLee))
        steps(veer, seconds: 5)
        let before = veer.boats[0]
        #expect(holds(before, byTheLee))
        var events: [RaceEvent.Kind] = []
        var deepest = 0.0
        steps(veer, seconds: 20) { boat in
            events += veer.drainEvents().map(\.kind)
            if boat.sailingAngle < 0 { deepest = max(deepest, self.degrees(.pi + boat.sailingAngle)) }
            #expect(boat.boomSide == .port)
        }
        #expect(!events.contains(.gybed(seat: 0)))
        #expect(deepest < 22.5 - 3, "went \(deepest)° by the lee")
        let turned = degrees(wrapAngle(veer.boats[0].heading - before.heading))
        #expect(abs(turned - 20) <= 1, "headed up \(turned)°")

        // 25° by the lee in 6 kn (limit 30°); the breeze builds to 16 kn (limit 15°). She heads up to the
        // by-the-lee margin short of the new limit instead of gybing, still holding her angle as the target.
        let deep = deg2rad(-155)
        let building = try scriptedWindRace(
            wind: { t in Wind(direction: 0, speed: metresPerSecond(knots: 6 + 10 * ((t - 10) / 10).clamped(to: 0...1))) },
            place: sailing(deep))
        steps(building, seconds: 5)
        #expect(abs(degrees(building.boats[0].sailingAngle - deep)) < 0.01)
        events = []
        steps(building, seconds: 30) { boat in
            events += building.drainEvents().map(\.kind)
            #expect(boat.boomSide == .port)
        }
        #expect(!events.contains(.gybed(seat: 0)))
        let limit = rad2deg(dinghy.polar.byTheLeeLimit(tws: metresPerSecond(knots: 16)) - dinghy.steering.autohelm.byTheLeeMargin)
        let now = degrees(.pi + building.boats[0].sailingAngle)
        #expect(abs(now - limit) <= 0.1, "\(now)° by the lee, clamped to \(limit)°")
        #expect(holds(building.boats[0], deep))
    }

    @Test func deadRunDoesNotFlipBoomSide() throws {
        // A 180° groove at 12 kn. The wind oscillates ±3° about the north, 12 s a cycle, for 60 s after 5 s.
        let wind = { (t: Double) in
            Wind(direction: t < 5 ? 0 : deg2rad(3) * RegattaCore.sin(2 * .pi * (t - 5) / 12), speed: metresPerSecond(knots: 12))
        }
        #expect(abs(dinghy.polar.bestDownwind(tws: metresPerSecond(knots: 12)).twa - .pi) < 1e-9)
        // Let go dead downwind, and 2° by the lee: both take the groove on the boom's side.
        for letGo in [Double.pi, deg2rad(-178)] {
            let race = try scriptedWindRace(wind: wind, place: sailing(letGo))
            steps(race, seconds: 5)
            #expect(race.boats[0].autohelm == Autohelm(target: .groove(.downwind)))
            var events: [RaceEvent.Kind] = []
            var byTheLeeTicks = 0
            var nearest = Double.infinity
            steps(race, seconds: 60) { boat in
                events += race.drainEvents().map(\.kind)
                #expect(boat.boomSide == .port)
                if boat.isByTheLee { byTheLeeTicks += 1 }
                nearest = min(nearest, 180 - abs(self.degrees(boat.sailingAngle)))
            }
            #expect(byTheLeeTicks == 0, "by the lee for \(byTheLeeTicks) ticks")
            #expect(nearest > 1, "came within \(nearest)° of dead downwind")
            #expect(!events.contains(.gybed(seat: 0)))
            #expect(race.boats[0].autohelm == Autohelm(target: .groove(.downwind)))
        }
    }

    // MARK: - The tap

    @Test func tackTapExitsAtGrooveOnNewTack() throws {
        // From the groove, and from a close reach: the tap tacks, and she settles in the groove on the new tack.
        for start in [upwindGroove(knots: 10), deg2rad(70)] {
            let race = try scriptedWindRace(wind: steadyWind(knots: 10), place: sailing(start))
            steps(race, seconds: 3)
            race.tap(.tackGybe, seat: 0, atTick: race.tick + 1)
            race.step()
            #expect(race.boats[0].autohelm == Autohelm(target: .groove(.upwind), isTapping: true))
            var events: [RaceEvent.Kind] = []
            var crossedTapping: Bool?
            steps(race, seconds: 15) { boat in
                let kinds = race.drainEvents().map(\.kind)
                if kinds.contains(.tacked(seat: 0)) { crossedTapping = boat.autohelm?.isTapping }
                events += kinds
            }
            #expect(events.filter { $0 == .tacked(seat: 0) || $0 == .gybed(seat: 0) } == [.tacked(seat: 0)])
            #expect(crossedTapping == false, "the tap ends on the tick the boom crosses")
            let boat = race.boats[0]
            #expect(boat.boomSide == .starboard && boat.tack == .port)
            #expect(boat.autohelm == Autohelm(target: .groove(.upwind)))
            #expect(abs(degrees(boat.sailingAngle - upwindGroove(knots: 10))) <= 1, "settled at \(degrees(boat.sailingAngle))°")
        }
    }

    @Test func gybeTapExitsAtTheDownwindGrooveOnTheNewTack() throws {
        let race = try scriptedWindRace(wind: steadyWind(knots: 12), place: sailing(deg2rad(150)))
        steps(race, seconds: 3)
        race.tap(.tackGybe, seat: 0, atTick: race.tick + 1)
        var events: [RaceEvent.Kind] = []
        steps(race, seconds: 15) { _ in events += race.drainEvents().map(\.kind) }
        #expect(events.filter { $0 == .tacked(seat: 0) || $0 == .gybed(seat: 0) } == [.gybed(seat: 0)])
        let boat = race.boats[0]
        #expect(boat.boomSide == .starboard)
        #expect(boat.autohelm == Autohelm(target: .groove(.downwind)))
        let deadRun = Double.pi - dinghy.steering.autohelm.deadRunMargin
        #expect(abs(degrees(boat.sailingAngle - deadRun)) <= 1, "settled at \(degrees(boat.sailingAngle))°")
    }

    @Test func rudderInputCancelsTheTap() throws {
        let race = try scriptedWindRace(wind: steadyWind(knots: 10), place: sailing(upwindGroove(knots: 10)))
        steps(race, seconds: 3)
        let t = race.tick + 1
        race.tap(.tackGybe, seat: 0, atTick: t)
        race.apply(BoatInput(rudder: -0.5), seat: 0, atTick: t + 5)
        steps(race, seconds: 5.0 / 30)
        #expect(race.boats[0].autohelm?.isTapping == true)
        race.step()
        #expect(race.boats[0].autohelm == nil)
        #expect(race.boats[0].desiredRudder == BoatInput(rudder: -0.5).rudderValue)
        #expect(race.boats[0].boomSide == .port, "cancelled before the boom crossed")
        // Centring again captures her angle: the tap doesn't come back.
        steps(race, seconds: 0.5)
        race.apply(.neutral, seat: 0, atTick: race.tick + 1)
        var events: [RaceEvent.Kind] = []
        steps(race, seconds: 10) { _ in events += race.drainEvents().map(\.kind) }
        let helm = try #require(race.boats[0].autohelm)
        #expect(!helm.isTapping)
        #expect(!events.contains(.tacked(seat: 0)))
        #expect(race.boats[0].boomSide == .port)
    }

    // MARK: - The snap

    @Test func grooveSnapEmitsAnEvent() throws {
        let groove = upwindGroove(knots: 10)
        let snapping = try scriptedWindRace(wind: steadyWind(knots: 10), place: sailing(groove + deg2rad(2)))
        snapping.step()
        #expect(snapping.drainEvents() == [RaceEvent(tick: snapping.tick, kind: .grooveSnap(seat: 0))])
        steps(snapping, seconds: 2)
        #expect(snapping.drainEvents().isEmpty, "once, on the tick she lets go")
        // Letting go again near the groove snaps again.
        snapping.apply(BoatInput(rudder: 0.2), seat: 0, atTick: snapping.tick + 1)
        snapping.step()
        snapping.apply(.neutral, seat: 0, atTick: snapping.tick + 1)
        snapping.step()
        #expect(snapping.drainEvents() == [RaceEvent(tick: snapping.tick, kind: .grooveSnap(seat: 0))])
        #expect(!RaceEvent.Kind.grooveSnap(seat: 0).isRuleEvent, "a prediction feels it too")

        // Outside the snap width, and inside the no-go zone (bearing away to the groove is no snap): none.
        for angle in [groove + deg2rad(5), deg2rad(15)] {
            let race = try scriptedWindRace(wind: steadyWind(knots: 10), place: sailing(angle))
            steps(race, seconds: 2)
            #expect(race.drainEvents().isEmpty)
        }
    }

    // MARK: - Pure pieces

    @Test func readingMeasuresTheAimFromTheGroove() throws {
        let tws = metresPerSecond(knots: 10)
        let groove = Autohelm.grooveAngle(.upwind, tws: tws, boatClass: dinghy)
        let pinching = Autohelm(target: .angle(groove - deg2rad(4))).reading(tws: tws, boatClass: dinghy)
        #expect(pinching.groove == .upwind && abs(degrees(pinching.offsetFromGroove) + 4) < 1e-9)
        let inGroove = Autohelm(target: .groove(.downwind)).reading(tws: tws, boatClass: dinghy)
        #expect(inGroove.offsetFromGroove == 0 && inGroove.aim == .pi - dinghy.steering.autohelm.deadRunMargin)
        // 10° by the lee is 13° deeper than the dead-run groove.
        let byTheLee = Autohelm(target: .angle(deg2rad(-170))).reading(tws: tws, boatClass: dinghy)
        #expect(byTheLee.groove == .downwind && abs(degrees(byTheLee.offsetFromGroove) - 13) < 1e-9)

        var boat = Boat(id: 0, isPlayer: true, colorIndex: 0, position: .zero, heading: 0, speed: 0)
        boat.sailingWind = Wind(direction: 0, speed: tws)
        #expect(boat.autohelmReading(in: dinghy) == nil)
        boat.autohelm = Autohelm(target: .groove(.upwind))
        #expect(boat.autohelmReading(in: dinghy) == Autohelm(target: .groove(.upwind)).reading(tws: tws, boatClass: dinghy))
    }

    @Test func tapTacksForwardOfTheBeamAndGybesAbaftIt() {
        #expect(Autohelm.tackOrGybe(sailingAngle: deg2rad(45)) == Autohelm(target: .groove(.upwind), isTapping: true))
        #expect(Autohelm.tackOrGybe(sailingAngle: deg2rad(89)) == Autohelm(target: .groove(.upwind), isTapping: true))
        #expect(Autohelm.tackOrGybe(sailingAngle: deg2rad(91)) == Autohelm(target: .groove(.downwind), isTapping: true))
        #expect(Autohelm.tackOrGybe(sailingAngle: deg2rad(-170)) == Autohelm(target: .groove(.downwind), isTapping: true))
    }
}
