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
}
