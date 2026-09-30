import Foundation
import Testing
@testable import RegattaCore

/// Races for measuring what a manoeuvre costs against a twin (#263): the default class (skiff@4 since #298) in still water and
/// a wind the same everywhere and always, so twin races differ only by what one of them does (the in-race "gap" #263
/// measured was wind shifts and a committee boat, not the sim). Seat 0 sails in open water to the right of the race
/// area's centre, clear of every mark; seat 1 sits out of the way, well to leeward of her.
enum OpenWater {
    static let boatClass = RaceFiles.defaults.boatClass.content
    static var hullLength: Double { boatClass.hull.length }
    static let still = CurrentField(current: nil, tideStateAtGun: 0)
    static let seed: UInt64 = 263

    /// The direction the wind blows from in every race here: up the course the seed draws.
    static func windDirection() throws -> Double {
        try placedRace(current: still, seed: seed, boatClass: RaceFiles.defaults.boatClass.ref) { _, _ in }.course.axis
    }

    /// A two-seat race in `knots` of steady wind with seat 0 close-hauled on starboard at her polar speed, her autohelm
    /// to engage on the groove on the first step; `place` edits the snapshot after that (seat 1 is already out of the way).
    static func race(knots: Double, place: (inout WorldSnapshot, Race) -> Void = { _, _ in }) throws -> Race {
        let wind = GroundWind(direction: try windDirection(), speed: metresPerSecond(knots: knots))
        return try placedRace(current: still, seed: seed, wind: { _ in wind }, boatClass: RaceFiles.defaults.boatClass.ref) { snapshot, race in
            let area = race.course.raceArea
            var boat = snapshot.seats[0].boat
            let best = boatClass.polar.bestUpwind(tws: wind.speed)
            boat.position = area.centre + race.course.right * (area.halfWidth * 0.4)
            boat.heading = wrapAngle(wind.direction - best.twa)
            boat.speed = best.speed
            boat.boomSide = .port
            boat.rudder = 0
            boat.desiredRudder = 0
            snapshot.seats[0].boat = boat
            snapshot.seats[0].heldInput = .neutral
            snapshot.seats[1].boat.position = area.centre - race.course.right * (area.halfWidth * 0.6)
            snapshot.seats[1].boat.speed = 0
            place(&snapshot, race)
        }
    }

    /// Metres seat `seat` of `race` has made good along `direction` since `from`.
    static func madeGood(_ race: Race, seat: Int = 0, from: Vec2, direction: Double) -> Double {
        (race.boats[seat].position - from).dot(.heading(direction))
    }
}

/// #263 acceptance: in a race, a tack tapped from close-hauled with the autohelm holding costs 0.7–1.3 hull lengths
/// made good upwind over 25 s against a twin that sails on, at 6, 10 and 14 kn (#14's "a tack costs about a hull
/// length"; `SkiffTests.tackCosts0_7To1_3LengthsAt6_10And14Knots` measures the same at the dynamics level).
@Suite struct TackCostTests {
    @Test(arguments: [6.0, 10, 14])
    func inRaceTackWithAutohelmLoses0_7To1_3Lengths(knots: Double) throws {
        let direction = try OpenWater.windDirection()
        let tacking = try OpenWater.race(knots: knots), sailingOn = try OpenWater.race(knots: knots)
        let start = tacking.boats[0].position
        #expect(start == sailingOn.boats[0].position)
        // One step so her autohelm engages on the groove, then the tap.
        tacking.step()
        sailingOn.step()
        tacking.tap(.tackGybe, seat: 0, atTick: tacking.tick + 1)
        for _ in 0..<(25 * Race.tickRate) {
            tacking.step()
            sailingOn.step()
        }
        let events = tacking.drainEvents()
        #expect(events.filter { $0.kind == .tacked(seat: 0) }.count == 1)
        #expect(!events.contains { if case .ruleCall = $0.kind { true } else { false } })
        #expect(tacking.boats[0].boomSide == .starboard && !tacking.boats[0].isTacking)
        #expect(sailingOn.boats[0].boomSide == .port)
        let lost = OpenWater.madeGood(sailingOn, from: start, direction: direction)
            - OpenWater.madeGood(tacking, from: start, direction: direction)
        let lengths = lost / OpenWater.hullLength
        #expect(lengths >= 0.7 && lengths <= 1.3, "\(knots) kn in-race tack lost \(lengths) L")
    }
}
