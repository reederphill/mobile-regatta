import Foundation
import Testing
@testable import RegattaCore

/// #90 acceptance: rule 31 penalises touching a mark of the leg (and a starting mark before starting) with one
/// turn; touching any other mark is an obstruction contact (slowed, no penalty); and a touch and a foul in one
/// open incident cost one turn between them (44.1(a)). Two boats in a steady wind with no current
/// (`IncidentFixture`), 2 laps: legs W, O, gate, W, O, finish.
@Suite struct Rule31Tests {
    typealias F = IncidentFixture

    static let beat2 = 3
    static let finalRun = 5

    /// The mark at `index` among those that begin, bound or end leg `leg` (`CourseLayout.marksOfLeg`).
    static func mark(_ race: Race, leg: Int, _ index: Int = 0) -> CourseLayout.Mark {
        race.course.marksOfLeg(race.course.legs[leg])[index]
    }

    /// Puts seat 0 on the mark named `name`, her centre on its centre, with `status` on leg `leg`, owing no
    /// penalty and with no touch remembered; seat 1 far away mid-beat. Steps once and returns the events.
    static func touch(_ race: Race, _ name: String, status: BoatStatus = .racing, leg: Int) throws -> [RaceEvent.Kind] {
        let obstacle = try #require(race.course.obstacles.first { $0.name == name })
        var snapshot = race.exportSnapshot()
        var boat = snapshot.seats[0].boat
        placeRacing(&boat, leg: leg, at: obstacle.position)
        boat.status = status
        boat.penaltyTurnsOwed = 0
        boat.penaltyProgress = 0
        boat.penaltyClockTick = nil
        boat.queuedPenaltyCallTicks = []
        snapshot.seats[0].boat = boat
        snapshot.seats[1].boat.position = F.midBeat(race)
        snapshot.touchingObstacles = []
        snapshot.touchingBoats = []
        try race.importSnapshot(snapshot)
        _ = race.drainEvents()
        race.step()
        return race.drainEvents().map(\.kind)
    }

    static func isMarkTouch(_ kind: RaceEvent.Kind, by seat: Int) -> Bool {
        if case .markTouch(seat, _) = kind { true } else { false }
    }

    /// A penalised touch: one `markTouch`, no obstruction contact, one turn owed.
    static func expectTurn(_ race: Race, _ events: [RaceEvent.Kind], seat: Int = 0, mark: String,
                           sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(events.filter { $0 == .markTouch(seat: seat, mark: mark) }.count == 1, sourceLocation: sourceLocation)
        #expect(!events.contains(.obstructionContact(seat: seat, kind: .mark)), sourceLocation: sourceLocation)
        #expect(race.boats[seat].penaltyTurnsOwed == 1, sourceLocation: sourceLocation)
    }

    /// A touch that costs no turn: an obstruction contact of kind `.mark`, announced and recorded this tick,
    /// no `markTouch`, and `owed` turns owed.
    static func expectObstruction(_ race: Race, _ events: [RaceEvent.Kind], seat: Int = 0, owed: Int = 0,
                                  sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(events.contains(.obstructionContact(seat: seat, kind: .mark)), sourceLocation: sourceLocation)
        #expect(!events.contains { isMarkTouch($0, by: seat) }, sourceLocation: sourceLocation)
        #expect(race.boats[seat].penaltyTurnsOwed == owed, sourceLocation: sourceLocation)
        let recorded = race.incidents.obstructionContacts.last
        #expect(recorded == ObstructionContact(tick: race.tick, leg: race.boats[seat].legIndex, seat: seat, kind: .mark),
                sourceLocation: sourceLocation)
    }

    /// The gate's marks bound the first run, not the second beat (#12): touching one on beat 2 is an
    /// obstruction contact, recorded, with no penalty and no `markTouch`, and it slows her.
    @Test func gateMarkOnBeat2IsAnObstruction() throws {
        let race = try F.race()
        let gate = race.course.marksOfLeg(race.course.legs[2])
        #expect(gate.count == 2)
        for mark in gate {
            #expect(!race.course.isRule31Mark(mark.name, status: .racing, legIndex: Self.beat2))
            let events = try Self.touch(race, mark.name, leg: Self.beat2)
            Self.expectObstruction(race, events)
        }
        #expect(race.incidents.obstructionContacts.map(\.kind) == [.mark, .mark])
        #expect(race.incidents.count == 0)
    }

    /// On the final run the gate marks aren't marks of the leg (#12): no penalty. On the first run they are.
    @Test func gateMarkOnFinalRunIsNoPenalty() throws {
        let race = try F.race()
        let gate = race.course.marksOfLeg(race.course.legs[2])
        for mark in gate {
            Self.expectObstruction(race, try Self.touch(race, mark.name, leg: Self.finalRun))
        }
        Self.expectTurn(race, try Self.touch(race, gate[0].name, leg: 2), mark: gate[0].name)
    }

    /// The windward mark costs one turn on the beats that round it, and none on the reach that leaves it.
    @Test func windwardMarkOnItsLegIsOneTurn() throws {
        let race = try F.race()
        let windward = Self.mark(race, leg: 0).name
        #expect(Self.mark(race, leg: Self.beat2).name == windward)
        for leg in [0, Self.beat2] {
            Self.expectTurn(race, try Self.touch(race, windward, leg: leg), mark: windward)
        }
        Self.expectObstruction(race, try Self.touch(race, windward, leg: 1))
    }

    /// The pin is a starting mark before she starts (in the sequence, or OCS) and a finishing mark on the final
    /// leg: one turn each time. Once started, on the legs between, it is an obstruction.
    @Test func pinBeforeStartingAndOnFinalLegIsOneTurn() throws {
        let race = try F.race()
        let pin = race.course.startLine.pin.name
        #expect(race.course.finishLine.pin.name == pin)
        Self.expectTurn(race, try Self.touch(race, pin, status: .prestart, leg: 0), mark: pin)
        Self.expectTurn(race, try Self.touch(race, pin, status: .ocs, leg: 0), mark: pin)
        Self.expectTurn(race, try Self.touch(race, pin, leg: Self.finalRun), mark: pin)
        let committee = race.course.startLine.committee.name
        Self.expectTurn(race, try Self.touch(race, committee, status: .prestart, leg: 0), mark: committee)
        Self.expectObstruction(race, try Self.touch(race, pin, leg: 0))
        Self.expectObstruction(race, try Self.touch(race, committee, leg: 1))
    }

    /// Shifts both boats so seat `seat`'s centre is on `mark`'s, with no obstacle touch remembered.
    static func moveOntoMark(_ race: Race, seat: Int, _ mark: CourseLayout.Mark) throws {
        var snapshot = race.exportSnapshot()
        let shift = mark.position - snapshot.seats[seat].boat.position
        for s in snapshot.seats.indices { snapshot.seats[s].boat.position += shift }
        snapshot.touchingObstacles = []
        try race.importSnapshot(snapshot)
        _ = race.drainEvents()
    }

    /// 44.1(a), foul first: seat 1 is called for a foul on seat 0 and owes one turn; touching a mark of her leg
    /// while that incident is open costs her nothing more (an obstruction contact, no `markTouch`). Once the
    /// pair have separated, a touch is a turn again.
    @Test func foulAndMarkTouchInOneOpenIncidentIsOneTurn() throws {
        let race = try F.race()
        let pair = SeatPair(0, 1)
        try F.touching(race, tick: 300)
        race.step()
        let call = try #require(F.calls(race.drainEvents()).first)
        #expect(call.offender == 1 && call.turnsOwed == 1)
        #expect(race.boats[1].penaltyTurnsOwed == 1)

        let windward = Self.mark(race, leg: 0)
        try Self.moveOntoMark(race, seat: 1, windward)
        race.step()
        let events = race.drainEvents()
        #expect(race.umpire?.openIncident(pair) == call.incidentId)
        Self.expectObstruction(race, events.map(\.kind), seat: 1, owed: 1)
        #expect(F.calls(events).isEmpty)

        // Three hull lengths apart: the incident closes, and a touch is a new turn.
        let length = race.boatClass.hull.length
        try F.apart(race, tick: race.tick, at: race.boats[0].position, gap: 3 * length)
        race.step()
        #expect(race.umpire?.openIncident(pair) == nil)
        try Self.moveOntoMark(race, seat: 1, windward)
        race.step()
        Self.expectTurn(race, race.drainEvents().map(\.kind), seat: 1, mark: windward.name)
    }

    /// Seat 1 on a mark of her leg (the windward mark, leg 0) with seat 0 a hull length to her port side:
    /// the touch costs her one turn, and seat 0 shares its incident.
    static func touchBesideSeat0(_ race: Race) throws -> CourseLayout.Mark {
        let windward = mark(race, leg: 0)
        try F.apart(race, tick: 300, at: F.midBeat(race), gap: race.boatClass.hull.length)
        try moveOntoMark(race, seat: 1, windward)
        race.step()
        let touch = race.drainEvents().map(\.kind)
        expectTurn(race, touch, seat: 1, mark: windward.name)
        #expect(!touch.contains(.markTouch(seat: 0, mark: windward.name)))
        #expect(race.umpire?.markTouchNeighbours(of: 1) == [0])
        return windward
    }

    /// 44.1(a), touch first: seat 1 touches a mark of her leg (one turn) within the separation of seat 0, then
    /// fouls her before they separate: the call owes no turn (`turnsOwed` 0, no deadlines), and she still owes
    /// one in all.
    @Test func markTouchThenFoulInOneOpenIncidentIsOneTurn() throws {
        let race = try F.race()
        _ = try Self.touchBesideSeat0(race)

        // The foul, with her penalty as the touch left it.
        let owed = race.boats[1]
        try F.touching(race, tick: race.tick, at: race.boats[0].position) { snapshot in
            snapshot.seats[1].boat.penaltyTurnsOwed = owed.penaltyTurnsOwed
            snapshot.seats[1].boat.penaltyProgress = owed.penaltyProgress
            snapshot.seats[1].boat.penaltyClockTick = owed.penaltyClockTick
            snapshot.seats[1].boat.queuedPenaltyCallTicks = owed.queuedPenaltyCallTicks
        }
        race.step()
        let call = try #require(F.calls(race.drainEvents()).first)
        #expect(call.offender == 1 && call.victim == 0)
        #expect(call.turnsOwed == 0 && call.startDeadlineTick == nil && call.completeDeadlineTick == nil)
        #expect(race.boats[1].penaltyTurnsOwed == 1)
        #expect(race.boats[1].queuedPenaltyCallTicks.isEmpty)
        #expect(race.umpire?.markTouchNeighbours(of: 1) == [])
    }

    /// A touch whose neighbour has separated from her before the foul is in another incident: the call owes
    /// its own turn.
    @Test func markTouchThenFoulAfterSeparatingIsTwoTurns() throws {
        let race = try F.race()
        _ = try Self.touchBesideSeat0(race)
        let length = race.boatClass.hull.length
        try F.apart(race, tick: race.tick, at: race.boats[0].position, gap: 3 * length)
        race.step()
        #expect(race.umpire?.markTouchNeighbours(of: 1) == [])
        _ = race.drainEvents()
        try F.touching(race, tick: race.tick, at: race.boats[0].position)
        race.step()
        let call = try #require(F.calls(race.drainEvents()).first)
        #expect(call.offender == 1 && call.turnsOwed == 1)
    }

    /// Stopped head to wind, holding a touch of rudder towards the wind so the autohelm stays off (ADR 0007):
    /// she doesn't steer, and inside the no-go zone she makes no speed.
    static func stopped(_ seat: inout WorldSnapshot.Seat) {
        seat.boat.speed = 0
        seat.boat.heading = seat.boat.windDirection
        seat.boat.rudder = 0
        seat.boat.desiredRudder = 0
        seat.boat.boomSide = .port
        seat.heldInput = BoatInput(rudder: Int8(8))
    }

    /// Swept by the current onto a gate mark on the first run, never sailing: one `markTouch`, one turn (#11).
    @Test func driftingOntoAMarkOfTheLegIsOneTurn() throws {
        let current = steadyCurrent(knots: 2, towards: .pi / 2)
        let east = Vec2(1, 0)
        let probe = try placedRace(current: current) { _, _ in }
        let mark = Self.mark(probe, leg: 2)
        let race = try placedRace(current: current) { snapshot, race in
            Self.stopped(&snapshot.seats[0])
            var boat = snapshot.seats[0].boat
            boat.status = .racing
            boat.legIndex = 2
            // Just up-current of the mark: her side 30 cm off it.
            boat.position = .zero
            let reach = boat.hull(outline: race.boatClass.hull.outline).map { $0.dot(east) }.max()!
            boat.position = mark.position - east * (mark.radius + reach + 0.3)
            snapshot.seats[0].boat = boat
            snapshot.seats[1].boat.position = F.midBeat(race)
        }
        _ = race.drainEvents()
        var events: [RaceEvent.Kind] = []
        for _ in 0..<(3 * Race.tickRate) {
            #expect(race.boats[0].speed == 0, "drifting, not sailing")
            race.step()
            events += race.drainEvents().map(\.kind)
        }
        #expect(events.filter { $0 == .markTouch(seat: 0, mark: mark.name) }.count == 1)
        #expect(!events.contains(.obstructionContact(seat: 0, kind: .mark)))
        #expect(race.boats[0].penaltyTurnsOwed == 1)
    }
}
