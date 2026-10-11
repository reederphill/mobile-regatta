import Foundation
import Testing
@testable import RegattaCore

/// #489 acceptance: under fleet-rules@6 the penalty arc's two marks (the tack half and the gybe half, and the barb
/// showing the turn's way) are read off `OwedPenalty`: `hasTacked`, `hasGybed` and `direction` follow the counting
/// crossings as the race sails them, through a recross and a served turn.
@Suite struct OwedPenaltyTests {
    /// The races and helm of #487's tests: open water under fleet-rules@6, seat 0 on starboard tack.
    let sail = PenaltyTackGybeTests()

    func owedNow(_ race: Race) throws -> OwedPenalty { try #require(race.owedPenalty(ofSeat: 0)) }

    @Test func arcMarksFollowTheCrossings() throws {
        // Close-hauled, owing two turns: one countdown (no start deadline), both halves grey, no way yet.
        let race = try sail.race(angle: deg2rad(45))
        let call = race.tick
        race.penalize(0)
        race.penalize(0)
        var owed = try owedNow(race)
        #expect(owed.startDeadlineTick == owed.completeDeadlineTick)
        #expect(owed.completeDeadlineTick == call + PenaltyTackGybeTests.complete)
        #expect(!owed.hasTacked && !owed.hasGybed && owed.direction == 0 && !owed.isStarted)

        // Luffing (the heading increasing, clockwise on a north-up chart): the tack lights, the way +1.
        sail.helm(race, 1)
        let tack = sail.steps(race, limit: 10 * Race.tickRate, until: PenaltyTackGybeTests.crossed)
        #expect(tack.kinds.contains(PenaltyTackGybeTests.tacked) && tack.turned > 0)
        owed = try owedNow(race)
        #expect(owed.hasTacked && !owed.hasGybed && owed.direction == 1 && owed.isStarted)

        // Tacking back (the recross): the tack stays lit, the way turns round.
        sail.helm(race, -1)
        let back = sail.steps(race, limit: 10 * Race.tickRate, until: PenaltyTackGybeTests.crossed)
        #expect(back.kinds.contains(PenaltyTackGybeTests.tacked) && back.kinds.contains(PenaltyTackGybeTests.reset))
        #expect(back.turned < 0)
        owed = try owedNow(race)
        #expect(owed.hasTacked && !owed.hasGybed && owed.direction == -1)

        // On round to the gybe the same way: the first turn is served. The next turn's halves are grey again and it
        // goes the first's way, its countdown from the serve.
        let on = sail.steps(race, limit: 20 * Race.tickRate) { _, kinds in kinds.contains(PenaltyTackGybeTests.served) }
        #expect(on.stopped && on.kinds.contains(PenaltyTackGybeTests.gybed))
        owed = try owedNow(race)
        #expect(owed.turnsOwed == 1 && !owed.hasTacked && !owed.hasGybed)
        #expect(owed.direction == -1 && owed.isDirectionLocked)
        #expect(owed.completeDeadlineTick == race.tick + PenaltyTackGybeTests.complete)

        // The second turn served the same way: nothing owed, no arc.
        let second = sail.steps(race, limit: 30 * Race.tickRate) { _, kinds in kinds.contains(PenaltyTackGybeTests.served) }
        #expect(second.stopped)
        #expect(race.owedPenalty(ofSeat: 0) == nil)
    }

    /// From a run, bearing away (the heading decreasing): the gybe lights first, the way −1.
    @Test func gybeMarkLightsFirstFromARun() throws {
        let race = try sail.race(angle: deg2rad(150))
        race.penalize(0)
        sail.helm(race, -1)
        let gybe = sail.steps(race, limit: 10 * Race.tickRate, until: PenaltyTackGybeTests.crossed)
        #expect(gybe.kinds.contains(PenaltyTackGybeTests.gybed) && gybe.turned < 0)
        let owed = try owedNow(race)
        #expect(!owed.hasTacked && owed.hasGybed && owed.direction == -1)
    }
}
