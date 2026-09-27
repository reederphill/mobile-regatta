import Foundation
import Testing
@testable import RegattaCore

/// #86 acceptance: a boat that has stopped racing is a ghost (CONTEXT.md, #30): from the tick she crosses the
/// finish line she casts no wind shadow or backwind and can't be touched.
@Suite struct GhostTests {
    let steady = GroundWind(direction: 0, speed: metresPerSecond(knots: 10))
    let noCurrent = CurrentField(current: nil, tideStateAtGun: 0)

    /// After the gun, in a steady wind with no current: seat 0 reaching across the course mid-beat with
    /// `status`, and seat 1 racing on her heading at her speed where `place` puts her, from seat 0's position,
    /// the way her shadow streams (downwind along her apparent wind) and her hull length.
    func pair(_ status: BoatStatus, place: (_ at: Vec2, _ downwind: Vec2, _ abeam: Vec2, _ hullLength: Double) -> Vec2) throws -> Race {
        let race = try placedRace(current: noCurrent, wind: { _ in steady }) { _, _ in }
        let course = race.course
        let polar = race.boatClass.polar
        try jump(race, to: 300) { snapshot in
            var caster = snapshot.seats[0].boat
            placeRacing(&caster, leg: 0, at: course.startLine.centre + course.upwind * (course.beat / 2))
            caster.status = status
            if status == .finished {
                caster.place = 1
                caster.finishTime = 5
                snapshot.firstFinishTime = 5
            }
            caster.heading = wrapAngle(caster.windDirection - .pi / 2)
            caster.speed = polar.speed(twa: .pi / 2, tws: caster.windSpeed)
            caster.boomSide = .port
            caster.rudder = 0
            caster.desiredRudder = 0
            let apparent = BoatWinds.resolve(ground: caster.windOverGround, current: .zero,
                                             velocityThroughWater: caster.velocity).apparent
            var other = snapshot.seats[1].boat
            placeRacing(&other, leg: 0, at: place(caster.position, -Vec2.heading(apparent.direction),
                                                  caster.forward.rightPerp, race.boatClass.hull.length))
            other.heading = caster.heading
            other.speed = caster.speed
            other.boomSide = caster.boomSide
            snapshot.seats[0].boat = caster
            snapshot.seats[1].boat = other
        }
        return race
    }

    @Test func finishedBoatCastsNoShadowAndPassesThrough() throws {
        // She becomes a ghost on the tick she crosses the line, after her finish is announced.
        let race = try placedRace(current: noCurrent, wind: { _ in steady }) { _, _ in }
        try jump(race, to: 299) { placeToFinish(&$0.seats[0].boat, in: race) }
        #expect(!race.isGhost(seat: 0) && race.shadowCone(ofSeat: 0) != nil)
        race.step()
        let crossing = race.drainEvents().filter { $0.tick == 300 }.map(\.kind)
        #expect(Array(crossing.suffix(3)) == [.finished(seat: 0, place: 1), .firstFinish(closeTick: 300 + 120 * Race.tickRate),
                                              .becameGhost(seat: 0)])
        #expect(race.boats[0].isGhost && race.isGhost(seat: 0))
        #expect(race.shadowCone(ofSeat: 0) == nil)
        #expect(race.seatView(for: 1).others[0].isGhost)

        // Two lengths down her cone: shadowed by her racing, clean air behind her finished.
        let shadowed = try pair(.racing) { at, downwind, _, length in at + downwind * 2 * length }
        let clean = try pair(.finished) { at, downwind, _, length in at + downwind * 2 * length }
        shadowed.step()
        clean.step()
        #expect(shadowed.boats[1].shadow < 1)
        #expect(clean.boats[1].shadow == 1, "a ghost casts no shadow")
        #expect(clean.boats[0].shadow == 1, "and takes none")

        // Hulls overlapping side by side: a contact with her racing, none with her finished.
        let touching = try pair(.racing) { at, _, abeam, _ in at + abeam * 0.3 }
        let passing = try pair(.finished) { at, _, abeam, _ in at + abeam * 0.3 }
        _ = passing.drainEvents()
        touching.step()
        passing.step()
        #expect(touching.exportSnapshot().touchingBoats == [.init(0, 1)])
        #expect(passing.exportSnapshot().touchingBoats.isEmpty, "a ghost can't be touched")
        #expect(!passing.drainEvents().contains { if case .ruleCall = $0.kind { true } else { false } })
        #expect(passing.boats[1].speed > touching.boats[1].speed, "no speed lost to a contact")
    }
}
