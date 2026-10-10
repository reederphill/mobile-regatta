import Foundation
import Testing
@testable import RegattaCore

/// The bundled default race files (`RaceFiles.defaults`).
@Suite struct RaceFilesTests {
    /// #461: the default class is skiff@8, which tacks and gybes by hand (`SkiffEightTests` holds what it changes from
    /// skiff@7). Like skiff@7 (#437: skiff@6 with the autohelm off a centred rudder and nothing else changed, still
    /// bundled) every default race steers by hand: let go on a beat through a 10° shift, her heading holds and the
    /// autohelm never engages.
    @Test func defaultClassHandSteers() throws {
        let defaults = RaceFiles.defaults.boatClass
        let skiff7 = try BoatClassFile.bundled(id: SkiffFixtures.classID, version: 7)
        let skiff6 = try BoatClassFile.bundled(id: SkiffFixtures.classID, version: 6)
        #expect(defaults.ref == (try BoatClassFile.bundled(id: SkiffFixtures.classID, version: 8)).ref)
        #expect(defaults.schemaVersion == 4 && skiff7.schemaVersion == 4)
        #expect(!defaults.content.steering.autohelm.holdsWhenCentred)
        #expect(!defaults.content.steering.autohelm.sailsTap && defaults.content.steering.rudderDragExponent == 3)
        #expect(BoatClassFile.bundledKeys().contains(skiff7.ref.key), "skiff@7 stays bundled")
        #expect(!skiff7.content.steering.autohelm.holdsWhenCentred && skiff7.content.steering.autohelm.sailsTap)
        #expect(skiff6.content.steering.autohelm.holdsWhenCentred, "skiff@6 stays bundled with the autohelm on")
        var steering = skiff7.content.steering
        steering.autohelm.holdsWhenCentred = true
        var content = skiff7.content
        content.steering = steering
        #expect(content == skiff6.content, "only the autohelm's hold differs from skiff@6")

        let groove = defaults.content.polar.bestUpwind(tws: metresPerSecond(knots: 10)).twa
        let race = try scriptedWindRace(
            boatClass: defaults.ref,
            wind: { t in Wind(direction: t < 10 ? 0 : deg2rad(10), speed: metresPerSecond(knots: 10)) },
            place: { boat, boatClass in
                boat.boomSide = .port
                boat.heading = wrapAngle(boat.windDirection - BoomSide.port.windSign * groove)
                boat.speed = boatClass.polar.speed(twa: groove, tws: boat.windSpeed)
            })
        let heading = race.boats[0].heading
        var engaged = false
        for _ in 0..<(20 * Race.tickRate) {
            race.step()
            engaged = engaged || race.boats[0].autohelm != nil
        }
        #expect(!engaged, "the autohelm engaged on a centred rudder")
        #expect(abs(wrapAngle(race.boats[0].heading - heading)) < 1e-12)
    }
}
