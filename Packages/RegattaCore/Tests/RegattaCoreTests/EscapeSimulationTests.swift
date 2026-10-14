import Foundation
import Testing
@testable import RegattaCore

/// The escape simulation reading the class's autohelm setting (#434).
@Suite struct EscapeSimulationTests {
    /// A boat as the umpire records her, on a 70° reach to a wind from 0 at 10 kn on starboard tack, rudder centred
    /// and no autohelm.
    static func reaching(_ boatClass: BoatClass) -> RecordedBoat {
        let wind = Wind(direction: 0, speed: metresPerSecond(knots: 10))
        let angle = deg2rad(70)
        var boat = Boat(id: 0, isPlayer: true, colorIndex: 0, position: Vec2(0, 0),
                        heading: wrapAngle(wind.direction - BoomSide.port.windSign * angle),
                        speed: boatClass.polar.speed(twa: angle, tws: wind.speed), boomSide: .port)
        boat.sailingWind = wind
        boat.shadow = 1
        boat.averagedWindSpeed = wind.speed
        return RecordedBoat(boat, ease: false)
    }

    /// The keep-clear boat's centred candidate, sailed on through a 10° shift: off, a straight course, her heading
    /// unchanged; on (today), her autohelm turns her with the shift.
    @Test func centredRudderAutohelmOffPredictsStraight() throws {
        let rules = try RulesConfigFile.bundled(id: "fleet-rules", version: 5).content
        func headingChange(_ boatClass: BoatClass) throws -> Double {
            let now = Self.reaching(boatClass)
            let track = PairTrack(seats: SeatPair(0, 1), low: [now], high: [now], overlapped: [false])
            let simulation = try #require(EscapeSimulation(track: track, rules: rules, boatClass: boatClass))
            var shifted = now
            shifted.windDirection = deg2rad(10)
            var boat = simulation.holding(.neutral, from: now.boat(id: 0), in: now)
            for _ in 0..<(10 * Race.tickRate) { simulation.sail(&boat, ease: false, in: shifted) }
            if !boatClass.steering.autohelm.holdsWhenCentred { #expect(boat.autohelm == nil) }
            return rad2deg(wrapAngle(boat.heading - now.state.heading))
        }
        let off = try headingChange(AutohelmSettingFixtures.off().content)
        #expect(abs(off) < 1e-9, "the prediction turned \(off)° on a centred rudder")
        // skiff@6, the autohelm on (the default, skiff@7, has it off since #437).
        let on = try headingChange(BoatClassFile.bundled(id: SkiffFixtures.classID, version: SkiffFixtures.version).content)
        #expect(abs(abs(on) - 10) < 1, "the autohelm turned her \(on)° with a 10° shift")
    }

    // MARK: - Section A calls on fleet-rules@7 (#517)

    static func fleetRules(_ version: Int) throws -> RulesConfigFile { try .bundled(id: "fleet-rules", version: version) }

    /// Rule 21.2's look-back (fleet-rules@7) is rule 21.2's alone. A boat tacks by hand from port onto starboard two
    /// hull lengths ahead and 3 m to leeward of a port-tack boat, who hits her 0.6 s after the tack is complete: rule
    /// 15 on the tacker, the port boat exonerated, on fleet-rules@7 as on fleet-rules@6, on the same tick. By then
    /// the umpire on fleet-rules@7 holds more of the pair's track than the 62 ticks the call is judged on, the tack's
    /// start among them (fleet-rules@6 holds no more): the call doesn't read them.
    @Test func tackOntoStarboardAheadOfAPortBoatIsUnchangedOnRules7() throws {
        func outcome(_ version: Int) throws -> (outcome: EscapeFixture.Outcome, completed: Int, recorded: Int) {
            let race = try IncidentFixture.race(rules: Self.fleetRules(version))
            try EscapeFixture.tackOntoStarboard(race, ahead: 2, leeward: 3)
            var tacking = false, completed: Int?
            let outcome = try #require(EscapeFixture.sailToCall(race, within: 10 * Race.tickRate) { race in
                tacking = tacking || race.boats[1].isTacking
                if tacking, completed == nil, !race.boats[1].isTacking { completed = race.tick }
            })
            #expect(race.boats[0].boomSide == .starboard && race.boats[1].boomSide == .port, "port boat, starboard tacker")
            return (outcome, try #require(completed), try #require(race.umpire?.track(0, 1)?.count))
        }
        let (six, seven) = (try outcome(6), try outcome(7))
        #expect(six.outcome.contact && six.outcome.tick - six.completed <= Race.tickRate, "contact within a second of the tack")
        #expect(six.outcome.call.rule == .acquiringRightOfWay && six.outcome.call.offender == 1 && six.outcome.call.victim == 0)
        #expect(six.outcome.exonerated == [0])
        #expect(seven.outcome == six.outcome && seven.completed == six.completed)
        #expect(six.recorded == 62 && seven.recorded > six.recorded + Race.tickRate,
                "fleet-rules@7 records more than the window the call reads")
    }

    /// A leeward boat luffs, half her rudder, with 4 m between the hulls, and goes on luffing for 2.4 s until her
    /// near-miss sweep reaches the windward boat: longer than the horizon, so the 16.1 test reads her mid-luff course
    /// as the one she held, which meets the windward boat as well, and the luff took no room from her. Rule 11 on the
    /// windward boat, no one exonerated, on fleet-rules@7 as on fleet-rules@6: the look-back to where a turn began,
    /// which would make this luff the leeward boat's, is not for Section A.
    @Test func sustainedLuffIsUnchangedOnRules7() throws {
        func outcome(_ version: Int) throws -> (outcome: EscapeFixture.Outcome, luffed: Int) {
            let race = try IncidentFixture.race(rules: Self.fleetRules(version))
            let luffed = try EscapeFixture.luff(race, gap: 4, rudder: 0.5)
            let rate = EscapeFixture.TurnRate()
            let outcome = try #require(EscapeFixture.sailToCall(race, within: 8 * Race.tickRate, watch: rate.watch))
            #expect(rate.fastest > (try #require(race.rules.incidents.escape.changesCourse)), "a course change")
            #expect(outcome.tick - luffed > RulesConfig.ticks(race.rules.incidents.escape.horizon), "longer than the horizon")
            return (outcome, luffed)
        }
        let (six, seven) = (try outcome(6), try outcome(7))
        #expect(six.outcome.call.rule == .windwardLeeward && six.outcome.call.offender == 1 && six.outcome.call.victim == 0)
        #expect(six.outcome.exonerated.isEmpty)
        #expect(seven == six)
    }
}
