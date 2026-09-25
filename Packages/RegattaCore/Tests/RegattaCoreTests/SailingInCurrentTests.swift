import Foundation
import Testing
@testable import RegattaCore

/// A current of `knots` flowing towards `bearing` over the whole race area, never changing: a still
/// tide clock at peak flood, one depth everywhere, no eddies.
func steadyCurrent(knots: Double, towards bearing: Double) -> CurrentField {
    let grid = Venue.Grid(origin: Vec2(-5_000, -5_000), cellSize: 10_000, orientation: 0, columns: 2, rows: 2)
    let current = Venue.Current(
        peak: metresPerSecond(knots: knots), isTidal: false, tideClockRate: 0,
        allowedTideStatesAtGun: .init(from: .pi / 2, to: .pi / 2), grid: grid, depths: [5, 5, 5, 5],
        floodDirections: [bearing, bearing, bearing, bearing], strengthExponent: 2.0 / 3, shallowsLead: 0,
        eddies: [], maxDepth: 5)
    return CurrentField(current: current, tideStateAtGun: .pi / 2)
}

/// A race of `seats` humans in `current`, stepped 10 ticks into its sequence so every boat has her
/// winds, then with its world edited by `place`.
func placedRace(seats: Int = 2, current: CurrentField, seed: UInt64 = 3,
                _ place: (inout WorldSnapshot, Race) -> Void) throws -> Race {
    let setup = try RaceSetup(raceSeed: RaceSeed(seed), seats: Array(repeating: .human, count: seats), laps: 2,
                              startSequenceTicks: 60 * Race.tickRate)
    let race = Race(setup: setup, windSeed: WindSeed(seed &* 0x9E37_79B9_7F4A_7C15 &+ 1), current: current)
    for _ in 0..<10 { race.step() }
    var snapshot = race.exportSnapshot()
    place(&snapshot, race)
    try race.importSnapshot(snapshot)
    return race
}

/// #79 acceptance: boats sail in the wind over the water, and the current carries every one of them.
@Suite struct SailingInCurrentTests {
    let dt = Race.dt
    /// 2 kn towards the east.
    let current = steadyCurrent(knots: 2, towards: .pi / 2)

    /// Stopped head to wind: she falls off slowly, and inside the no-go zone her speed stays 0.
    func stopped(_ boat: inout Boat) {
        boat.speed = 0
        boat.heading = boat.windDirection
        boat.rudder = 0
        boat.desiredRudder = 0
        boat.boomSide = .port
    }

    @Test func stoppedBoatMovesExactlyByTheCurrentEachTick() throws {
        let race = try placedRace(current: current) { snapshot, _ in
            stopped(&snapshot.seats[0].boat)
            snapshot.seats[1].boat.position = snapshot.seats[0].boat.position + Vec2(0, -300)
        }
        for _ in 0..<(2 * Race.tickRate) {
            let before = race.boats[0]
            race.step()
            let after = race.boats[0]
            #expect(after.speed == 0 && after.speedThroughWater == 0)
            #expect(after.current == race.current.sample(before.position, tick: race.tick))
            #expect(after.current.length > 1)
            #expect(after.velocityOverGround == after.current)
            #expect(((after.position - before.position) - after.current * dt).length < 1e-12)
        }
    }

    @Test func ghostDriftsWithTheCurrentAndCastsNoShadow() throws {
        func race(ghost: Bool) throws -> Race {
            try placedRace(current: current) { snapshot, _ in
                var caster = snapshot.seats[0].boat
                stopped(&caster)
                if ghost {
                    caster.status = .finished
                    caster.place = 1
                    caster.finishTime = 0
                }
                snapshot.seats[0].boat = caster
                // Seat 1 one and a half lengths straight downwind of her.
                let downwind = -Vec2.heading(caster.windDirection)
                snapshot.seats[1].boat.position = caster.position + downwind * 1.5 * 4.2
            }
        }
        let sailing = try race(ghost: false)
        sailing.step()
        #expect(sailing.shadowCone(ofSeat: 0) != nil)
        #expect(sailing.boats[1].shadow < 1, "on the course she shadows the boat behind her")

        let ghostRace = try race(ghost: true)
        #expect(ghostRace.shadowCone(ofSeat: 0) == nil)
        for _ in 0..<(3 * Race.tickRate) {
            let before = ghostRace.boats[0]
            ghostRace.step()
            let ghost = ghostRace.boats[0]
            #expect(!ghost.isOnCourse && ghost.speed == 0)
            #expect(ghost.current.length > 1)
            #expect(((ghost.position - before.position) - ghost.current * dt).length < 1e-12)
            #expect(ghostRace.boats[1].shadow == 1)
            #expect(ghostRace.shadowCone(ofSeat: 0) == nil)
        }
    }

    /// Ground velocity is velocity through the water plus the current, whatever the boat is doing.
    @Test func everyBoatMovesAtHerVelocityOverTheGround() throws {
        let race = try placedRace(seats: 4, current: steadyCurrent(knots: 1.5, towards: deg2rad(200))) { snapshot, race in
            let origin = snapshot.seats[0].boat.position
            for seat in 0..<4 { snapshot.seats[seat].boat.position = origin + Vec2(Double(seat) * 60, 0) }
            stopped(&snapshot.seats[0].boat) // stopped, before the start
            var sailing = snapshot.seats[1].boat // sailing close-hauled, before the start
            let best = race.boatClass.polar.bestUpwind(tws: sailing.windSpeed)
            sailing.heading = wrapAngle(sailing.windDirection - best.twa)
            sailing.speed = best.speed
            sailing.boomSide = .port
            snapshot.seats[1].boat = sailing
            snapshot.seats[2].boat.speed = 2 // turning a penalty, hard over
            snapshot.seats[2].boat.status = .racing
            snapshot.seats[2].boat.penaltyTurnsOwed = 1
            snapshot.seats[2].heldInput = BoatInput(rudder: Int8(127))
            snapshot.seats[3].boat.status = .finished // a ghost
            snapshot.seats[3].boat.place = 1
            snapshot.seats[3].boat.finishTime = 0
        }
        for _ in 0..<(4 * Race.tickRate) {
            let before = race.boats
            race.step()
            for (seat, boat) in race.boats.enumerated() {
                #expect(boat.current == race.current.sample(before[seat].position, tick: race.tick))
                #expect(boat.velocityOverGround == boat.velocity + boat.current)
                let moved = (boat.position - before[seat].position) / dt
                #expect((moved - boat.velocityOverGround).length < 1e-9, "seat \(seat)")
            }
        }
        #expect(race.boats[2].penaltyProgress != 0)
    }

    @Test func threeWindsResolveFromTheGroundTheCurrentAndTheBoat() throws {
        let ground = Wind(direction: 0, speed: 5)
        // Current with the wind: the sailing wind is lighter, from the same way.
        let withTheWind = BoatWinds.resolve(ground: ground, current: Vec2(0, -1), velocityThroughWater: .zero)
        #expect(withTheWind.overGround == ground)
        #expect(abs(withTheWind.sailing.speed - 4) < 1e-12 && abs(withTheWind.sailing.direction) < 1e-12)
        #expect(withTheWind.apparent == withTheWind.sailing)
        // Current across it: the sailing wind swings towards where the current comes from.
        let across = BoatWinds.resolve(ground: ground, current: Vec2(1, 0), velocityThroughWater: Vec2(2, 0))
        #expect(abs(across.sailing.direction - atan2(1, 5)) < 1e-12)
        #expect(((across.sailing.velocity) - (ground.velocity - Vec2(1, 0))).length < 1e-12)
        #expect(((across.apparent.velocity) - (across.sailing.velocity - Vec2(2, 0))).length < 1e-12)
        #expect(abs(across.apparent.direction - atan2(3, 5)) < 1e-12)
        // No current: the sailing wind is the ground wind exactly.
        let still = BoatWinds.resolve(ground: Wind(direction: 1.234, speed: 6.7), current: .zero, velocityThroughWater: Vec2(1, 1))
        #expect(still.sailing == still.overGround)

        // In a race, each boat's winds are these, from the ground wind and current at her.
        let race = try placedRace(current: current) { _, _ in }
        let before = race.boats
        race.step()
        for (seat, boat) in race.boats.enumerated() {
            let expected = BoatWinds.resolve(ground: Wind(race.groundWind(at: before[seat].position)),
                                             current: race.current.sample(before[seat].position, tick: race.tick),
                                             velocityThroughWater: before[seat].velocity)
            #expect(boat.windOverGround == expected.overGround)
            #expect(boat.sailingWind == expected.sailing && boat.windDirection == expected.sailing.direction)
            #expect(boat.apparentWind == expected.apparent)
            #expect(boat.sailingWind != boat.windOverGround)
        }
    }

    /// 9 kn in a 0.75 lull is 6.75 kn over the ground; 2 kn of current running down the course leaves
    /// 4.75 kn to sail in, and she has to beat the current too.
    @Test func closeHauledVMGOverTheGroundAgainstTheCurrent() throws {
        let dinghy = try Fixtures.boatClass()
        let ground = Wind(direction: 0, speed: metresPerSecond(knots: 9 * 0.75))
        let current = -Vec2.heading(ground.direction) * metresPerSecond(knots: 2)
        var s = BoatDynamics.State(heading: -deg2rad(45), speed: 0, boomSide: .port)
        var start = s.position
        let settle = 60 * Race.tickRate, measure = 60 * Race.tickRate
        for tick in 0..<(settle + measure) {
            if tick == settle { start = s.position }
            let winds = BoatWinds.resolve(ground: ground, current: current, velocityThroughWater: .heading(s.heading) * s.speed)
            // Close-hauled on starboard in the wind she sails in.
            s.heading = wrapAngle(winds.sailing.direction - dinghy.polar.bestUpwind(tws: winds.sailing.speed).twa)
            s = BoatDynamics.advance(
                s, control: .init(rudder: 0),
                env: .init(windDirection: winds.sailing.direction, windSpeed: winds.sailing.speed, current: current),
                boatClass: dinghy, dt: dt)
        }
        let vmg = knots(metresPerSecond: (s.position - start).dot(.heading(ground.direction)) / (Double(measure) * dt))
        #expect(abs(vmg - 0.2) <= 0.15, "VMG over the ground \(vmg) kn")
    }

    @Test func boatDriftingOntoAMarkOfTheLegTouchesIt() throws {
        let setupRace = try placedRace(current: current) { _, _ in }
        guard case .round(let m) = setupRace.course.legs[0] else { Issue.record("leg 0 rounds no mark"); return }
        let mark = setupRace.course.marks[m]
        let east = Vec2(1, 0)
        let race = try placedRace(current: current) { snapshot, race in
            var boat = snapshot.seats[0].boat
            stopped(&boat)
            boat.status = .racing
            boat.legIndex = 0
            // Just up-current of the mark: her side 30 cm off it.
            boat.position = .zero
            let reach = boat.hull(outline: race.boatClass.hull.outline).map { $0.dot(east) }.max()!
            boat.position = mark.position - east * (mark.radius + reach + 0.3)
            snapshot.seats[0].boat = boat
            snapshot.seats[1].boat.position = mark.position + Vec2(0, -300)
        }
        _ = race.drainEvents()
        var touched = false
        for _ in 0..<(2 * Race.tickRate) where !touched {
            #expect(race.boats[0].speed == 0, "drifting, not sailing")
            race.step()
            touched = race.drainEvents().contains { $0.kind == .markTouch(seat: 0, mark: mark.name) }
        }
        #expect(touched)
    }
}
