import Foundation
import Testing
@testable import RegattaCore

/// Boats put together for rule 43.1(a) and 18.2(d) (#93): `IncidentFixture`'s race (ilca-dinghy@3 in a steady
/// 10 kn from the course's axis, no current, the default rules fleet-rules@5) with as many seats as a test needs,
/// each boat placed where it says. Placing imports a snapshot, so the umpire records their track from then on.
enum CompelledFixture {
    typealias F = IncidentFixture

    struct Spot {
        var position: Vec2
        var heading: Double
        var speed = F.speed
        var leg = 0
    }

    /// `seats` boats in `IncidentFixture`'s wind and water.
    static func race(seats: Int) throws -> Race {
        let probe = try placedRace(seats: seats, current: F.noCurrent) { _, _ in }
        let wind = F.wind(probe)
        return try placedRace(seats: seats, current: F.noCurrent, wind: { _ in wind }) { _, _ in }
    }

    static func overlapped(_ a: Int, _ b: Int) -> WorldSnapshot.OverlapMemory {
        WorldSnapshot.OverlapMemory(pair: .init(a, b), isOverlapped: true, changeTicks: 0)
    }

    /// Jumps `race` to `tick` with seat k at `spots[k]`, racing on its leg, her boom to leeward in the race's wind,
    /// rudder centred and no autohelm (it takes her angle on the next step), owing nothing, with `overlaps` the
    /// overlap memory and no contacts remembered. `edit` has the last word.
    static func place(_ race: Race, tick: Int, _ spots: [Spot], overlaps: [WorldSnapshot.OverlapMemory] = [],
                      edit: (inout WorldSnapshot) -> Void = { _ in }) throws {
        let wind = race.course.axis
        try jump(race, to: tick) { snapshot in
            for (seat, spot) in spots.enumerated() {
                var boat = snapshot.seats[seat].boat
                placeRacing(&boat, leg: spot.leg, at: spot.position)
                boat.heading = spot.heading
                boat.boomSide = .leeward(ofRelativeWind: wrapAngle(wind - spot.heading))
                boat.speed = spot.speed
                boat.rudder = 0
                boat.desiredRudder = 0
                boat.autohelm = nil
                boat.isTacking = false
                boat.penaltyTurnsOwed = 0
                boat.penaltyProgress = 0
                boat.penaltyClockTick = nil
                boat.queuedPenaltyCallTicks = []
                snapshot.seats[seat].boat = boat
                snapshot.seats[seat].heldInput = .neutral
            }
            snapshot.touchingBoats = []
            snapshot.touchingObstacles = []
            snapshot.overlaps = overlaps
            edit(&snapshot)
        }
        _ = race.drainEvents()
    }

    /// Steps `race` `ticks` times and returns every event.
    static func sail(_ race: Race, ticks: Int) -> [RaceEvent] {
        var events: [RaceEvent] = []
        for _ in 0..<ticks {
            race.step()
            events += race.drainEvents()
        }
        return events
    }
}

extension CompelledFixture {
    /// Three boats abreast on a starboard beam reach mid-beat (#93's squeeze): seat 2 (C) to leeward, seat 1 (B)
    /// 0.4 m to windward of her, and seat 0 (A) to windward of B, 0.5 m off and turned 20° down onto her, all at
    /// `IncidentFixture.speed`, every neighbour overlapped. A must keep clear of B (rule 11) and B of C. With
    /// `withA` false, A is far away up the beat, and B instead is turned `bConverging` radians down onto C. `seats`
    /// are A's, B's and C's seats, in that order.
    static func squeeze(_ race: Race, withA: Bool = true, bConverging: Double = 0, seats: [Int] = [0, 1, 2]) throws {
        let hull = race.boatClass.hull
        let heading = F.starboard(race, offWind: .pi / 2)
        let windward = Vec2.heading(heading).rightPerp
        let c = F.midBeat(race)
        let b = c + windward * F.abeam(gap: 0.4, converging: bConverging, hull: hull)
        let a = withA ? b + windward * F.abeam(gap: 0.5, converging: deg2rad(20), hull: hull)
            : c + race.course.upwind * 60
        let roles = [Spot(position: a, heading: heading - deg2rad(20)),
                     Spot(position: b, heading: heading - bConverging), Spot(position: c, heading: heading)]
        var spots = roles
        for (role, seat) in seats.enumerated() { spots[seat] = roles[role] }
        let (sa, sb, sc) = (seats[0], seats[1], seats[2])
        let pairs = withA ? [(sa, sb), (sb, sc)] : [(sb, sc)]
        let overlaps = pairs.map { (min($0, $1), max($0, $1)) }.sorted { $0 < $1 }.map { overlapped($0.0, $0.1) }
        try place(race, tick: 300, spots, overlaps: overlaps)
    }

    /// Two boats on a starboard beam reach past the windward mark on the first beat, a mark of their leg (rule 31):
    /// seat 1 (B) with the mark 0.3 m off her leeward side, abeam of a point 2 m ahead of her centre, and seat 0 (A)
    /// to windward of B, 0.3 m off and turned 30° down onto her, overlapped. With `withA` false, A is far away down
    /// the beat, and B is turned `bConverging` radians down towards the mark.
    static func pastTheWindwardMark(_ race: Race, withA: Bool = true, bConverging: Double = 0) throws -> Obstacle {
        let hull = race.boatClass.hull
        let mark = try #require(race.course.obstacles.first { $0.name == "windward mark" })
        let heading = F.starboard(race, offWind: .pi / 2)
        let ahead = Vec2.heading(heading), windward = ahead.rightPerp
        let b = mark.position - ahead * 2 + windward * (mark.radius + hull.beam / 2 + 0.3)
        let a = withA ? b + windward * F.abeam(gap: 0.3, converging: deg2rad(30), hull: hull) : F.midBeat(race)
        try place(race, tick: 600, [Spot(position: a, heading: heading - deg2rad(30)),
                                    Spot(position: b, heading: heading - bConverging)],
                  overlaps: withA ? [overlapped(0, 1)] : [])
        return mark
    }

    /// Rule 18 at the leeward gate's left mark (rounded to port), both boats running on port tack 10° off dead
    /// downwind on the first run: seat 0 (O) at `IncidentFixture.speed`, `toMark` metres short of the mark along her
    /// heading and 3 m to its starboard side, and seat 1 (E) clear astern of her (her bow a metre behind O's stern)
    /// at 5 m/s, `lateral` metres between their sides on O's port side (inside, to windward), turned 2° in towards
    /// her. E sails into an inside overlap from clear astern, overlapped as O reaches the zone, so O owes her
    /// mark-room (18.2(a)); E, to windward, must keep clear (rule 11), and her speed carries her into O.
    static func intoTheGate(_ race: Race, toMark: Double, lateral: Double) throws {
        let hull = race.boatClass.hull
        let mark = race.course.elements[CourseLayout.gateIndex].marks[0]
        let heading = wrapAngle(race.course.axis + deg2rad(170))
        let ahead = Vec2.heading(heading), starboard = ahead.rightPerp
        let o = mark.position - ahead * toMark + starboard * 3
        let e = o - ahead * (hull.length + 1) - starboard * (hull.beam + lateral)
        try place(race, tick: 600, [Spot(position: o, heading: heading, leg: CourseLayout.gateIndex),
                                    Spot(position: e, heading: heading + deg2rad(2), speed: 5, leg: CourseLayout.gateIndex)])
    }

    /// Rule 18 at the leeward gate's left mark (rounded to port), both boats running on port tack 25° off dead
    /// downwind on the first run, overlapped (the overlap begun before the umpire's track, so not gained from clear
    /// astern): seat 0 (O) at `IncidentFixture.speed`, `toMark` metres short of the mark along her heading and
    /// `side` metres to its starboard side, turned `oTurn` radians to port, in towards E; seat 1 (E) abeam of her on
    /// her port side (inside, to windward), `lateral` metres between their sides, turned `eTurn` radians to starboard,
    /// in towards O. They reach the zone together, E inside, so O owes her mark-room (18.2(a)); E, to windward,
    /// must keep clear (rule 11).
    static func abreastIntoTheGate(_ race: Race, toMark: Double, side: Double = 3, lateral: Double,
                                   eTurn: Double = 0, oTurn: Double = 0) throws {
        let hull = race.boatClass.hull
        let mark = race.course.elements[CourseLayout.gateIndex].marks[0]
        let heading = wrapAngle(race.course.axis + deg2rad(155))
        let ahead = Vec2.heading(heading), starboard = ahead.rightPerp
        let o = mark.position - ahead * toMark + starboard * side
        let e = o - starboard * (hull.beam + lateral)
        try place(race, tick: 600, [Spot(position: o, heading: heading - oTurn, leg: CourseLayout.gateIndex),
                                    Spot(position: e, heading: heading + eTurn, leg: CourseLayout.gateIndex)],
                  overlaps: [overlapped(0, 1)])
    }

    /// Sails `race` until its first rule call and returns the events, with the pair (0, 1)'s recorded track and
    /// rule 18 record as the call read them: the track as the umpire holds it after that step, and the last record
    /// seen before the call or on its step.
    static func sailToCall(_ race: Race, within ticks: Int) -> (events: [RaceEvent], track: PairTrack?, record: MarkRoomRecord?) {
        var record: MarkRoomRecord?
        var events: [RaceEvent] = []
        for _ in 0..<ticks {
            record = race.umpire?.markRoom(SeatPair(0, 1)) ?? record
            race.step()
            events += race.drainEvents()
            record = race.umpire?.markRoom(SeatPair(0, 1)) ?? record
            if !calls(events).isEmpty { return (events, race.umpire?.track(0, 1), record) }
        }
        return (events, nil, record)
    }

    static func calls(_ events: [RaceEvent]) -> [RuleCall] { F.calls(events) }

    static func markTouches(_ events: [RaceEvent], seat: Int) -> Int {
        events.filter { if case .markTouch(seat, _) = $0.kind { true } else { false } }.count
    }
}

/// #93 acceptance: a boat compelled to break a rule by another's breach is exonerated (43.1(a)), and an owing boat
/// unable to give mark-room to an inside overlap gained from clear astern is exonerated (18.2(d)); both judged by
/// the escape simulation. Other boats' calls stand.
@Suite struct CompelledBreachTests {
    typealias F = IncidentFixture
    typealias C = CompelledFixture

    /// A fouls B (rule 11) and pushes her onto the windward mark, a mark of their leg: B's touch costs no rule 31
    /// turn. It is an obstruction contact, and B is exonerated on the A-B incident, whose call (on A) stands.
    @Test func foulPushingOntoMarkOfTheLegIsNoRule31Turn() throws {
        let race = try C.race(seats: 2)
        _ = try C.pastTheWindwardMark(race)
        let events = C.sail(race, ticks: 3 * Race.tickRate)
        let call = try #require(C.calls(events).first)
        #expect(C.calls(events).count == 1)
        #expect(call.rule == .windwardLeeward && call.offender == 0 && call.victim == 1)
        #expect(events.contains { $0.kind == .obstructionContact(seat: 1, kind: .mark) }, "B was put on the mark")
        #expect(C.markTouches(events, seat: 1) == 0)
        #expect(race.incidents.markTouches.isEmpty)
        #expect(race.incidents[call.incidentId]?.exonerated == [1])
        #expect(race.boats[1].penaltyTurnsOwed == 0 && race.boats[0].penaltyTurnsOwed == 1)
    }

    /// The control: no foul, B steering onto the mark herself, 10° down towards it. One rule 31 turn, as before.
    @Test func touchingMarkWithNoFoulIsOneTurn() throws {
        let race = try C.race(seats: 2)
        _ = try C.pastTheWindwardMark(race, withA: false, bConverging: deg2rad(10))
        let events = C.sail(race, ticks: 3 * Race.tickRate)
        #expect(C.calls(events).isEmpty)
        #expect(C.markTouches(events, seat: 1) == 1)
        #expect(race.boats[1].penaltyTurnsOwed == 1)
    }

    /// A fouls B (rule 11) and pushes her down into C, whom B had to keep clear of: B is exonerated (43.1(a)), with
    /// no call and no penalty; A is penalised for her foul on B.
    @Test func pushedIntoThirdBoatIsExoneratedAndPusherPenalised() throws {
        let race = try C.race(seats: 3)
        try C.squeeze(race)
        let events = C.sail(race, ticks: 4 * Race.tickRate)
        #expect(events.contains { $0.kind == .contact(SeatPair(1, 2)) }, "B was pushed into C")
        let calls = C.calls(events)
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.rule == .windwardLeeward && call.offender == 0 && call.victim == 1)
        let squeezed = try #require(race.incidents.latest(between: 1, and: 2))
        #expect(squeezed.outcome == .noCall)
        #expect(squeezed.exonerated == [1])
        #expect(race.boats.map(\.penaltyTurnsOwed) == [1, 0, 0])
    }

    /// The control: A away, B sailing down into C herself, 5° towards her. Rule 11 on B, as before.
    @Test func sailingIntoThirdBoatWithNoFoulIsRule11() throws {
        let race = try C.race(seats: 3)
        try C.squeeze(race, withA: false, bConverging: deg2rad(5))
        let events = C.sail(race, ticks: 4 * Race.tickRate)
        let call = try #require(C.calls(events).first)
        #expect(call.rule == .windwardLeeward && call.offender == 1 && call.victim == 2)
        #expect(race.incidents[call.incidentId]?.exonerated == [])
        #expect(race.boats.map(\.penaltyTurnsOwed) == [0, 1, 0])
    }

    /// 18.2(d): E comes from clear astern into an inside overlap 0.3 m off O and hits her soon after: O, owing her
    /// mark-room, could never have kept clear of her from the moment the overlap began. No call on O, who is
    /// exonerated; E, who had to keep clear (rule 11) and gained no entitlement, is called.
    @Test func markRoomThatCannotBeGivenIsNoCallOnTheOwingBoat() throws {
        let race = try C.race(seats: 2)
        try C.intoTheGate(race, toMark: 17.5, lateral: 0.3)
        var record: MarkRoomRecord?
        var events: [RaceEvent] = []
        for _ in 0..<(3 * Race.tickRate) {
            race.step()
            events += race.drainEvents()
            if C.calls(events).isEmpty { record = race.umpire?.markRoom(SeatPair(0, 1)) ?? record }
        }
        #expect(record?.entitled == 1 && record?.owing == 0 && record?.rule == .givingMarkRoom)
        let calls = C.calls(events)
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.offender != 0, "no call on the owing boat")
        #expect(call.rule == .windwardLeeward && call.offender == 1 && call.victim == 0)
        #expect(race.incidents[call.incidentId]?.exonerated == [0])
        #expect(race.boats[0].penaltyTurnsOwed == 0 && race.boats[1].penaltyTurnsOwed == 1)
    }

    /// The control: E's overlap begins half a metre off, and O had room to keep clear of her then. O fails to give
    /// mark-room (18.2) and E, sailing within it, is exonerated (43.1(b)).
    @Test func markRoomThatCouldBeGivenIsRule18_2() throws {
        let race = try C.race(seats: 2)
        try C.intoTheGate(race, toMark: 18, lateral: 0.5)
        let events = C.sail(race, ticks: 3 * Race.tickRate)
        let call = try #require(C.calls(events).first)
        #expect(call.rule == .givingMarkRoom && call.offender == 0 && call.victim == 1)
        #expect(race.incidents[call.incidentId]?.exonerated == [1])
        #expect(race.boats[0].penaltyTurnsOwed == 1 && race.boats[1].penaltyTurnsOwed == 0)
    }

    /// The control with both boats part way into a penalty turn (`Boat.isTakingPenalty`), so rule 21.2 is off between
    /// them: E, taking a penalty, is neither sailing to the mark nor rounding it, so mark-room gives her nothing and
    /// Section A stands (rule 11 on E, the windward boat), with no one exonerated.
    @Test func markRoomGivesNothingToABoatTakingAPenalty() throws {
        let race = try C.race(seats: 2)
        try C.intoTheGate(race, toMark: 18, lateral: 0.5)
        try jump(race, to: race.tick) { snapshot in
            for seat in 0..<2 {
                snapshot.seats[seat].boat.penaltyTurnsOwed = 1
                snapshot.seats[seat].boat.penaltyProgress = 1
                snapshot.seats[seat].boat.penaltyClockTick = race.tick
            }
        }
        _ = race.drainEvents()
        #expect(race.boats.allSatisfy { $0.isTakingPenalty })
        let events = C.sail(race, ticks: 3 * Race.tickRate)
        let call = try #require(C.calls(events).first)
        #expect(call.rule == .windwardLeeward && call.offender == 1 && call.victim == 0)
        #expect(race.incidents[call.incidentId]?.exonerated == [])
    }

    /// 43.1(a) only for a boat the breach left no way out of that she'd have had without it: A fouls B (rule 11) while
    /// B, turned 20° down towards the windward mark, is already bound to hit it whether A is there or not. B's touch
    /// costs her a rule 31 turn, as it does with A away, and she isn't exonerated on the A-B incident.
    @Test func doomedWithoutTheFoulIsNotExonerated() throws {
        let alone = try C.race(seats: 2)
        _ = try C.pastTheWindwardMark(alone, withA: false, bConverging: deg2rad(20))
        #expect(C.markTouches(C.sail(alone, ticks: 3 * Race.tickRate), seat: 1) == 1, "B hits the mark with A away")

        let race = try C.race(seats: 2)
        _ = try C.pastTheWindwardMark(race, bConverging: deg2rad(20))
        let events = C.sail(race, ticks: 3 * Race.tickRate)
        let call = try #require(C.calls(events).first)
        #expect(call.rule == .windwardLeeward && call.offender == 0 && call.victim == 1)
        let touch = try #require(events.first { if case .markTouch(1, _) = $0.kind { true } else { false } })
        #expect(touch.tick > call.tick, "the touch comes after A's breach")
        #expect(race.incidents[call.incidentId]?.exonerated == [])
        #expect(race.boats.map(\.penaltyTurnsOwed) == [1, 1])
    }

    /// 43.1(a) whatever the seats' order: the squeeze with A in seat 2, B in seat 0 and C in seat 1, so the B-C pair
    /// (0, 1) is judged before A-B (0, 2). B is exonerated on B-C, with no call and no penalty; A is penalised.
    @Test func compelledWhicheverPairComesFirstInSeatOrder() throws {
        let race = try C.race(seats: 3)
        try C.squeeze(race, seats: [2, 0, 1])
        let events = C.sail(race, ticks: 4 * Race.tickRate)
        #expect(events.contains { $0.kind == .contact(SeatPair(0, 1)) }, "B was pushed into C")
        let calls = C.calls(events)
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.rule == .windwardLeeward && call.offender == 2 && call.victim == 0)
        let squeezed = try #require(race.incidents.latest(between: 0, and: 1))
        #expect(squeezed.outcome == .noCall)
        #expect(squeezed.exonerated == [0])
        #expect(race.boats.map(\.penaltyTurnsOwed) == [0, 0, 1])
    }

    /// 43.1(b) covers the entitled boat only within her mark-room: E, overlapped inside O since before the zone,
    /// turns 20° down into her, and O, holding her course, has no way out of her path. Rule 11 on E stands, and O,
    /// who could not have given the room E took, is neither called nor exonerated.
    @Test func entitledBoatSailingBeyondHerMarkRoomIsCalled() throws {
        let race = try C.race(seats: 2)
        try C.abreastIntoTheGate(race, toMark: 14, lateral: 1, eTurn: deg2rad(20))
        let (events, _, record) = C.sailToCall(race, within: 3 * Race.tickRate)
        #expect(record?.entitled == 1 && record?.owing == 0 && record?.rule == .givingMarkRoom)
        let call = try #require(C.calls(events).first)
        #expect(call.rule == .windwardLeeward && call.offender == 1 && call.victim == 0)
        #expect(race.incidents[call.incidentId]?.exonerated == [])
        #expect(race.boats.map(\.penaltyTurnsOwed) == [0, 1])
    }

    /// The control: the same overlap, E holding her course and O turned 10° in towards her. O could have kept clear
    /// of E (given her mark-room), so O breaks 18.2 and E, sailing within her mark-room, is exonerated (43.1(b)).
    @Test func owingBoatThatCouldGiveRoomIsRule18_2() throws {
        let race = try C.race(seats: 2)
        try C.abreastIntoTheGate(race, toMark: 14, lateral: 1, oTurn: deg2rad(10))
        let (events, _, record) = C.sailToCall(race, within: 3 * Race.tickRate)
        #expect(record?.entitled == 1 && record?.owing == 0)
        let call = try #require(C.calls(events).first)
        #expect(call.rule == .givingMarkRoom && call.offender == 0 && call.victim == 1)
        #expect(race.incidents[call.incidentId]?.exonerated == [1])
        #expect(race.boats.map(\.penaltyTurnsOwed) == [1, 0])
    }

    /// Case 95: O, owing E mark-room at the gate mark, squeezes her (18.2), and E is then forced onto that mark, the
    /// incident still open: her touch costs no rule 31 turn (43.1(b): she was sailing within her mark-room; too late
    /// after the breach for 43.1(a)'s escape simulation to call her compelled). It is an obstruction contact, and E
    /// is exonerated on the incident with O.
    @Test func forcedOntoTheMarkSheIsOwedRoomAtIsNoRule31Turn() throws {
        let race = try C.race(seats: 2)
        try C.abreastIntoTheGate(race, toMark: 10, side: 4, lateral: 1, oTurn: deg2rad(10))
        let events = C.sail(race, ticks: 3 * Race.tickRate)
        let call = try #require(C.calls(events).first)
        #expect(C.calls(events).count == 1)
        #expect(call.rule == .givingMarkRoom && call.offender == 0 && call.victim == 1)
        let touch = try #require(events.first { $0.kind == .obstructionContact(seat: 1, kind: .mark) }, "E was put on the mark")
        #expect(touch.tick > call.tick)
        #expect(C.markTouches(events, seat: 1) == 0)
        #expect(race.incidents[call.incidentId]?.exonerated == [1])
        #expect(race.boats.map(\.penaltyTurnsOwed) == [1, 0])
    }

    /// The control: O squeezes E more gently (5°), and E touches the mark before O's breach is called. Her touch
    /// comes before the incident, so it costs her a rule 31 turn, and O's later 18.2 call still exonerates her only
    /// for the contact between them.
    @Test func touchingTheMarkBeforeTheBreachIsOneTurn() throws {
        let race = try C.race(seats: 2)
        try C.abreastIntoTheGate(race, toMark: 8, side: 3.5, lateral: 1, oTurn: deg2rad(5))
        let events = C.sail(race, ticks: 3 * Race.tickRate)
        let call = try #require(C.calls(events).first)
        #expect(call.rule == .givingMarkRoom && call.offender == 0 && call.victim == 1)
        let touch = try #require(events.first { if case .markTouch(1, _) = $0.kind { true } else { false } })
        #expect(touch.tick < call.tick)
        #expect(race.boats.map(\.penaltyTurnsOwed) == [1, 1])
    }

    /// 18.2(d)'s "by tacking to windward", on the 18.2(d) scenario's track with E no longer clear astern when the
    /// overlap began (moved up abeam of O on that tick): her overlap counts as gained by tacking only if she was
    /// tacking then and the tack left her to windward of O. Then O, unable to give room since, is exonerated;
    /// without the tack, or with a tack that leaves her to leeward, the overlap keeps its entitlement.
    @Test func overlapGainedByTackingToWindwardGivesNoEntitlement() throws {
        let race = try C.race(seats: 2)
        try C.intoTheGate(race, toMark: 17.5, lateral: 0.3)
        let (_, recorded, found) = C.sailToCall(race, within: 3 * Race.tickRate)
        let track = try #require(recorded), record = try #require(found)
        let hull = race.boatClass.hull
        let probe = try #require(EscapeSimulation(track: track, rules: race.rules, boatClass: race.boatClass, markRoom: record))
        let last = track.count - 1
        var certain = last
        while certain > 0, track.overlapped[certain - 1] { certain -= 1 }
        let before = certain - probe.lastPointOfCertaintyTicks
        try #require(before >= 0 && certain > 0)
        let obligation = Verdict(rule: .windwardLeeward, offender: 1, victim: 0)
        func verdict(tacking: Bool, toLeeward: Bool = false) throws -> Verdict {
            var edited = track
            let o = track.boat(0, before)
            // E abeam of O on her port side (to windward), as far off as she was.
            let side = o.forward.rightPerp
            edited.high[before].state.position = o.position + side * (track.boat(1, before).position - o.position).dot(side)
            edited.high[before].isTacking = tacking
            if toLeeward {
                let after = track.boat(0, before + 1)
                edited.high[before + 1].state.position = after.position + after.forward.rightPerp * (hull.beam + 0.3)
            }
            #expect(!Rules.isClearAstern(edited.boat(1, before), of: edited.boat(0, before), hull: hull))
            let sim = try #require(EscapeSimulation(track: edited, rules: race.rules, boatClass: race.boatClass, markRoom: record))
            return sim.verdict(obligation, course: race.course)
        }
        #expect(probe.verdict(obligation, course: race.course).exonerated == [0], "from clear astern: 18.2(d)")
        #expect(try verdict(tacking: true).exonerated == [0], "tacked to windward: 18.2(d)")
        #expect(try verdict(tacking: false).exonerated != [0], "no tack: entitled")
        #expect(try verdict(tacking: true, toLeeward: true).exonerated != [0], "tacked to leeward: entitled")
    }

    /// ADR 0002: each scenario, from the same world and umpire memory, sailed 100 times, makes the same events,
    /// incidents, umpire memory and race, bit for bit.
    @Test func identicalAcross100Replays() throws {
        struct Run: Equatable {
            let events: [RaceEvent]
            let digest: UInt64
            let incidents: IncidentIndex
            let umpire: UmpireState?
        }
        let mark = try C.race(seats: 2)
        _ = try C.pastTheWindwardMark(mark)
        let squeeze = try C.race(seats: 3)
        try C.squeeze(squeeze)
        let gate = try C.race(seats: 2)
        try C.intoTheGate(gate, toMark: 17.5, lateral: 0.3)
        let case95 = try C.race(seats: 2)
        try C.abreastIntoTheGate(case95, toMark: 10, side: 4, lateral: 1, oTurn: deg2rad(10))
        for (name, race) in [("mark", mark), ("squeeze", squeeze), ("18.2(d)", gate), ("Case 95", case95)] {
            let world = race.exportSnapshot()
            let umpire = race.umpire
            func run() throws -> Run {
                try race.importSnapshot(world)
                race.umpire = umpire
                _ = race.drainEvents()
                let events = C.sail(race, ticks: 4 * Race.tickRate)
                return Run(events: events, digest: race.digest(), incidents: race.incidents, umpire: race.umpire)
            }
            let first = try run()
            #expect(first.incidents.incidents.contains { !$0.exonerated.isEmpty }, "\(name): someone exonerated")
            for replay in 1..<100 {
                guard try run() == first else {
                    Issue.record("\(name): replay \(replay) differs")
                    break
                }
            }
        }
    }
}
