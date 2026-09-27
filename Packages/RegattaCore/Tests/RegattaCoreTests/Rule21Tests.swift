import Foundation
import Testing
@testable import RegattaCore

/// #88 acceptance: rule 21 overrides Section A in the umpire's calls (#9). 21.1 binds an OCS boat only
/// while she sails back towards the line; 21.2 binds a penalised boat once she is 30° into her turn.
@Suite struct Rule21Tests {
    typealias F = IncidentFixture

    /// The rule call when seat 0, to leeward, touches seat 1 side by side on starboard, both `offWind`
    /// radians off the wind, 2 s after the gun just above the line's centre, `edit` applied. Section A alone
    /// makes seat 1, to windward, keep clear (rule 11).
    static func call(offWind: Double, edit: (inout WorldSnapshot) -> Void) throws -> RuleCall? {
        let race = try F.race()
        let at = race.course.startLine.centre + race.course.upwind * 6
        try F.touching(race, tick: 2 * Race.tickRate, at: at) { snapshot in
            for seat in 0..<2 { snapshot.seats[seat].boat.heading = F.starboard(race, offWind: offWind) }
            snapshot.seats[1].boat.position = at + Vec2.heading(snapshot.seats[0].boat.heading).rightPerp
                * (race.boatClass.hull.beam - 0.3)
            edit(&snapshot)
        }
        race.step()
        let events = race.drainEvents()
        #expect(F.contacts(events) == [SeatPair(0, 1)])
        #expect(F.calls(events).count <= 1)
        return F.calls(events).first
    }

    /// OCS and sailing on up the course, she keeps her rights: Section A decides. OCS and sailing back
    /// towards the line, she keeps clear under 21.1.
    @Test func onlyAReturningOCSBoatIsUnder21_1() throws {
        let course = try F.race().course
        func ocs(_ snapshot: inout WorldSnapshot) { snapshot.seats[0].boat.status = .ocs }

        // Close-hauled: sailing away from the line.
        let away = try Self.call(offWind: .pi / 4) { snapshot in
            ocs(&snapshot)
            #expect(!course.isReturning(snapshot.seats[0].boat))
        }
        #expect(away?.rule == .windwardLeeward && away?.offender == 1 && away?.victim == 0)

        // A broad reach on the same tack: sailing back.
        let back = try Self.call(offWind: 3 * .pi / 4) { snapshot in
            ocs(&snapshot)
            #expect(course.isReturning(snapshot.seats[0].boat))
        }
        #expect(back?.rule == .returningToStart && back?.offender == 0 && back?.victim == 1)

        // Racing (started), sailing the same way, she is not returning: Section A again.
        let started = try Self.call(offWind: 3 * .pi / 4) { _ in }
        #expect(started?.rule == .windwardLeeward && started?.offender == 1)
    }

    /// Owing a penalty but less than 30° into her turn, she keeps her rights; past 30°, she keeps clear
    /// under 21.2.
    @Test func aPenalisedBoatIsUnder21_2OnceThirtyDegreesIntoHerTurn() throws {
        func penalised(progress: Double) -> (inout WorldSnapshot) -> Void {
            { snapshot in
                snapshot.seats[0].boat.penaltyTurnsOwed = 1
                snapshot.seats[0].boat.penaltyProgress = progress
            }
        }
        let starting = try Self.call(offWind: .pi / 2, edit: penalised(progress: deg2rad(20)))
        #expect(starting?.rule == .windwardLeeward && starting?.offender == 1)
        let turning = try Self.call(offWind: .pi / 2, edit: penalised(progress: deg2rad(45)))
        #expect(turning?.rule == .takingAPenalty && turning?.offender == 0 && turning?.victim == 1)
    }
}
