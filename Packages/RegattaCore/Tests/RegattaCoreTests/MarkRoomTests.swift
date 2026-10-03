import Foundation
import Testing
@testable import RegattaCore

/// Two boats put by a mark for rule 18's tests (#91): `IncidentFixture`'s two-seat race (ilca-dinghy@3, a
/// steady 10 kn wind from the course's axis, no current), each boat placed where a test says.
enum MarkRoomFixture {
    typealias F = IncidentFixture

    struct Spot {
        var position: Vec2
        var heading: Double
        var leg: Int
        var status = BoatStatus.racing
    }

    static let pair = SeatPair(0, 1)
    static let overlapped = WorldSnapshot.OverlapMemory(pair: .init(0, 1), isOverlapped: true, changeTicks: 0)

    /// Jumps `race` to `tick` with seat k at `spots[k]`, at `F.speed`, her boom to leeward in the race's wind,
    /// rudder centred and no autohelm (it takes her angle on the next step), owing nothing; `overlap` the
    /// pair's overlap memory (none: not overlapped and not changing). `edit` has the last word.
    static func place(_ race: Race, tick: Int, _ spots: [Spot], overlap: WorldSnapshot.OverlapMemory? = nil,
                      edit: (inout WorldSnapshot) -> Void = { _ in }) throws {
        let wind = race.course.axis
        try jump(race, to: tick) { snapshot in
            for (seat, spot) in spots.enumerated() {
                var boat = snapshot.seats[seat].boat
                placeRacing(&boat, leg: spot.leg, at: spot.position)
                boat.status = spot.status
                boat.heading = spot.heading
                boat.boomSide = .leeward(ofRelativeWind: wrapAngle(wind - spot.heading))
                boat.speed = F.speed
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
            snapshot.overlaps = overlap.map { [$0] } ?? []
            edit(&snapshot)
        }
    }

    static func notices(_ events: [RaceEvent]) -> [RaceEvent.Kind] {
        events.map(\.kind).filter { if case .markRoomNotice = $0 { true } else { false } }
    }

    static func record(_ race: Race) -> MarkRoomRecord? { race.umpire?.markRoom(pair) }

    /// Seat `seat`'s `MarkZone` now.
    static func zone(_ race: Race, _ seat: Int) -> MarkZone? {
        race.course.markZone(of: race.boats[seat], hull: race.boats[seat].hull(outline: race.boatClass.hull.outline))
    }

    static func windwardMark(_ race: Race) -> Vec2 { race.course.elements[CourseLayout.windwardIndex].marks[0].position }

    /// Port tack, `offWind` radians to her starboard side of the wind.
    static func port(_ race: Race, offWind: Double) -> Double { wrapAngle(race.course.axis + offWind) }
}

/// #91 acceptance: rule 18 from a per-pair zone-entry record (#9, RRS Section C in 2025 numbering).
@Suite struct MarkRoomTests {
    typealias F = IncidentFixture
    typealias M = MarkRoomFixture

    /// Case 2: the boat clear astern reaches the zone first, so she is entitled to mark-room (18.2(a)(2)); an
    /// overlap gained later, even inside her, changes nothing (18.2(b)).
    @Test func clearAsternBoatReachingZoneFirstIsEntitled() throws {
        let race = try F.race()
        let hull = race.boatClass.hull
        let mark = M.windwardMark(race)
        let heading = F.starboard(race, offWind: .pi / 4)
        let ahead = Vec2.heading(heading), toStarboard = ahead.rightPerp
        // Seat 1 sails straight at the mark, her bow 0.3 m inside the zone. Seat 0 is clear ahead of her, her
        // stern a metre past seat 1's bow, but 14 m to leeward: outside it.
        let astern = mark - ahead * (race.course.zoneRadius + hull.length / 2 - 0.3)
        let clearAhead = astern + ahead * (hull.length + 1) - toStarboard * 14
        try M.place(race, tick: 600, [M.Spot(position: clearAhead, heading: heading, leg: 0),
                                      M.Spot(position: astern, heading: heading, leg: 0)])
        #expect(Rules.isClearAstern(race.boats[1], of: race.boats[0], hull: hull))
        race.step()
        let record = try #require(M.record(race))
        #expect(record == MarkRoomRecord(mark: "windward mark", entitled: 1, owing: 0, rule: .givingMarkRoom,
                                         firstInZone: 1, overlappedAtZoneEntry: false))
        #expect(M.notices(race.drainEvents()) == [.markRoomNotice(boat: 1, entitledOver: 0, mark: "windward mark")])
        // The glow is the player's only cue (owner, 2026-10-03): the boat owing mark-room is the one that keeps clear,
        // whatever Section A says (seat 0 is clear ahead), and both boats agree.
        let seen = race.keepClearRelations(of: 0)[1]
        #expect(seen == RightOfWay(keepClear: 0, rule: .givingMarkRoom) && seen == race.keepClearRelations(of: 1)[0])

        // Seat 0 comes alongside, to leeward and so inside her at a mark left to port, a metre off: once the
        // overlap has held for the last point of certainty the pair are overlapped, and the record is still
        // the one the zone entry made.
        var snapshot = race.exportSnapshot()
        snapshot.seats[0].boat.position = snapshot.seats[1].boat.position - toStarboard * (hull.beam + 1)
        try race.importSnapshot(snapshot)
        #expect(!race.isOverlapped(0, 1))
        for _ in 0..<20 { race.step() }
        #expect(race.isOverlapped(0, 1))
        #expect(M.zone(race, 0)?.isIn == true && M.zone(race, 1)?.isIn == true)
        #expect(M.record(race) == record)
        #expect(M.notices(race.drainEvents()).isEmpty)
    }

    /// Rule 18.1(a): on opposite tacks on a beat to the windward mark, rule 18 doesn't apply: no record, no
    /// notice, and the overlap terms don't reach across the tacks. The same two boats on one tack have one.
    @Test func beatAtWindwardOnOppositeTacksIsOff() throws {
        func sail(secondOnPort: Bool) throws -> (race: Race, events: [RaceEvent]) {
            let race = try F.race()
            let mark = M.windwardMark(race)
            let (up, right) = (race.course.upwind, race.course.right)
            // Both close-hauled 8 m below the mark, 8 m apart, sailing apart: in the zone.
            try M.place(race, tick: 600, [
                M.Spot(position: mark - up * 8 - right * 4, heading: F.starboard(race, offWind: .pi / 4), leg: 0),
                M.Spot(position: mark - up * 8 + right * 4,
                       heading: secondOnPort ? M.port(race, offWind: .pi / 4) : F.starboard(race, offWind: .pi / 4), leg: 0),
            ])
            var events: [RaceEvent] = []
            for _ in 0..<20 {
                race.step()
                events += race.drainEvents()
            }
            #expect(M.zone(race, 0)?.isIn == true && M.zone(race, 1)?.isIn == true)
            return (race, events)
        }

        let opposite = try sail(secondOnPort: true)
        let (a, b) = (opposite.race.boats[0], opposite.race.boats[1])
        #expect(a.tack == .starboard && b.tack == .port)
        #expect(opposite.race.rules.onABeat.holds(for: a, in: opposite.race.course)
            && opposite.race.rules.onABeat.holds(for: b, in: opposite.race.course))
        #expect(!Rules.markRoomApplies(a, b, zones: M.zone(opposite.race, 0), M.zone(opposite.race, 1),
                                       course: opposite.race.course, onABeat: opposite.race.rules.onABeat))
        #expect(M.record(opposite.race) == nil)
        #expect(M.notices(opposite.events).isEmpty)
        #expect(!opposite.race.isOverlapped(0, 1))

        let sameTack = try sail(secondOnPort: false)
        #expect(M.record(sameTack.race) != nil)
        #expect(M.notices(sameTack.events).count == 1)
    }

    /// At the leeward gate, running on opposite tacks after one has gybed, rule 18 applies (it is off only on a
    /// beat): the inside boat, overlapped as the first reaches the zone, is entitled, and both are told. While
    /// it applies the overlap terms reach across the tacks, even with one boat heading up past the beam, where
    /// without rule 18 they wouldn't.
    @Test func gybingAtGateOnOppositeTacksIsOn() throws {
        let race = try F.race()
        let course = race.course
        let hull = race.boatClass.hull
        let gateLeft = course.elements[CourseLayout.gateIndex].marks[0]
        let (up, right) = (course.upwind, course.right)
        // 10° either side of dead downwind and sailing apart, above the gate's left mark (rounded to port):
        // seat 1 on port, 9 m above it, and seat 0 on starboard, 3.5 m further up and 2 m further from it. Seat 1,
        // on seat 0's port side, is inside.
        let inside = gateLeft.position + up * 9 - right * 1.5
        try M.place(race, tick: 600, [
            M.Spot(position: inside + up * 3.5 - right * 2, heading: wrapAngle(course.axis - deg2rad(170)),
                   leg: CourseLayout.gateIndex),
            M.Spot(position: inside, heading: wrapAngle(course.axis + deg2rad(170)), leg: CourseLayout.gateIndex),
        ], overlap: M.overlapped)
        race.step()
        #expect(race.boats[0].tack == .starboard && race.boats[1].tack == .port)
        let record = try #require(M.record(race))
        #expect(record == MarkRoomRecord(mark: "gate left", entitled: 1, owing: 0, rule: .givingMarkRoom,
                                         firstInZone: 1, overlappedAtZoneEntry: true))
        let events = race.drainEvents()
        #expect(M.notices(events) == [.markRoomNotice(boat: 1, entitledOver: 0, mark: "gate left")])
        let notice = try #require(events.first { if case .markRoomNotice = $0.kind { true } else { false } })
        #expect(notice.kind.isRuleEvent)

        // Seat 1 heads up to 80° from the wind, still on port, both slowed to 0.5 m/s: the terms alone no
        // longer apply between them, but rule 18 does, so past the last point of certainty they are still
        // overlapped, and the record holds.
        var snapshot = race.exportSnapshot()
        snapshot.seats[1].boat.heading = M.port(race, offWind: deg2rad(80))
        snapshot.seats[1].boat.autohelm = nil
        for seat in 0..<2 { snapshot.seats[seat].boat.speed = 0.5 }
        try race.importSnapshot(snapshot)
        #expect(!Rules.overlapTermsApply(race.boats[0], race.boats[1]))
        for _ in 0...RulesConfig.ticks(race.rules.incidents.lastPointOfCertainty) { race.step() }
        #expect(race.boats[1].twa < .pi / 2 && race.boats[1].tack == .port)
        #expect(Rules.markRoomApplies(race.boats[0], race.boats[1], zones: M.zone(race, 0), M.zone(race, 1),
                                      course: course, onABeat: race.rules.onABeat))
        #expect(Rules.geometricOverlaps(race.boats, hull: hull) == [false])
        #expect(Rules.geometricOverlaps(race.boats, hull: hull, markRoomApplies: [true]) == [true])
        #expect(race.isOverlapped(0, 1))
        #expect(F.contacts(race.drainEvents()).isEmpty)
        #expect(M.record(race) == record)
    }

    /// 18.2(b): the entitled boat's record ends once she has left the zone, all of her hull out of it for the
    /// last point of certainty, though the other boat is still in it.
    @Test func entitledBoatLeavingZoneClearsRecord() throws {
        let race = try F.race()
        let hull = race.boatClass.hull
        let mark = M.windwardMark(race)
        let heading = F.starboard(race, offWind: .pi / 4)
        let ahead = Vec2.heading(heading), toStarboard = ahead.rightPerp
        // Seat 1 reaches the zone first, seat 0 far to leeward: seat 1 is entitled.
        let first = mark - ahead * (race.course.zoneRadius + hull.length / 2 - 0.3)
        try M.place(race, tick: 600, [M.Spot(position: first - toStarboard * 14, heading: heading, leg: 0),
                                      M.Spot(position: first, heading: heading, leg: 0)])
        race.step()
        #expect(M.record(race)?.entitled == 1)

        // Seat 1 is put 30 m below the mark, seat 0 8 m below it.
        var snapshot = race.exportSnapshot()
        snapshot.seats[1].boat.position = mark - race.course.upwind * 30
        snapshot.seats[0].boat.position = mark - race.course.upwind * 8 - race.course.right * 3
        try race.importSnapshot(snapshot)
        let margin = RulesConfig.ticks(race.rules.incidents.lastPointOfCertainty)
        for _ in 0..<(margin - 1) { race.step() }
        #expect(M.zone(race, 1)?.isIn == false && M.zone(race, 0)?.isIn == true)
        #expect(M.record(race)?.entitled == 1, "out of the zone for less than the last point of certainty")
        race.step()
        #expect(M.record(race) == nil)
        #expect(M.zone(race, 0)?.isIn == true)
        _ = race.drainEvents()
        for _ in 0..<5 { race.step() }
        #expect(M.record(race) == nil)
        #expect(M.notices(race.drainEvents()).isEmpty)
    }

    /// Case 25: mark-room is not right of way. The inside windward boat is entitled to mark-room; once it has
    /// been given (the rules configuration's test: she has passed the mark within a hull length of it, with a
    /// quarter of a hull between them) the record has ended, and when she sails down onto the leeward boat
    /// rule 11 is called on her.
    @Test func afterRecordEndsRule11Applies() throws {
        let race = try F.race()
        let hull = race.boatClass.hull
        let mark = M.windwardMark(race)
        let heading = M.port(race, offWind: .pi / 4)
        let ahead = Vec2.heading(heading), toStarboard = ahead.rightPerp
        // Port tack, a metre apart and overlapped, below and to starboard of the mark (left to port): seat 0, to
        // windward (her port side), is inside.
        let leeward = mark - ahead * 8 + toStarboard * 3
        try M.place(race, tick: 600, [M.Spot(position: leeward - toStarboard * (hull.beam + 1), heading: heading, leg: 0),
                                      M.Spot(position: leeward, heading: heading, leg: 0)], overlap: M.overlapped)
        race.step()
        #expect(race.rightOfWay(0, 1) == RightOfWay(keepClear: 0, rule: .windwardLeeward))
        #expect(M.record(race) == MarkRoomRecord(mark: "windward mark", entitled: 0, owing: 1, rule: .givingMarkRoom,
                                                 firstInZone: 0, overlappedAtZoneEntry: true))
        #expect(F.calls(race.drainEvents()).isEmpty)

        // Seat 0 has passed the mark (its first rounding stage) 1.5 m off it, seat 1 two metres off her.
        var snapshot = race.exportSnapshot()
        snapshot.seats[0].boat.roundingStage = 1
        snapshot.seats[0].boat.position = mark + toStarboard * (hull.beam / 2 + 1.5)
        snapshot.seats[1].boat.position = snapshot.seats[0].boat.position + toStarboard * (hull.beam + 2)
        try race.importSnapshot(snapshot)
        race.step()
        #expect(M.record(race) == nil)
        #expect(F.calls(race.drainEvents()).isEmpty)

        // She sails down onto seat 1, still overlapped by the mark: rule 11, and no new record.
        snapshot = race.exportSnapshot()
        snapshot.seats[1].boat.position = snapshot.seats[0].boat.position + toStarboard * (hull.beam - 0.3)
        snapshot.overlaps = [M.overlapped]
        try race.importSnapshot(snapshot)
        race.step()
        let events = race.drainEvents()
        #expect(F.contacts(events) == [M.pair])
        let calls = F.calls(events)
        #expect(calls.count == 1)
        #expect(calls.first?.rule == .windwardLeeward && calls.first?.offender == 0 && calls.first?.victim == 1)
        #expect(M.record(race) == nil)
        #expect(M.notices(events).isEmpty)
    }

    /// 18.2(e): an overlap established only 0.3 s before the first boat reaches the zone, inside the last point
    /// of certainty (0.5 s), isn't one: the outside boat, first into the zone, is entitled. Established 0.5 s
    /// before, it is, and the inside boat is.
    @Test func overlapInsideLastPointOfCertaintyIsNotOverlapped() throws {
        func entry(overlapHeldTicks: Int) throws -> MarkRoomRecord? {
            let race = try F.race()
            let hull = race.boatClass.hull
            let gateLeft = race.course.elements[CourseLayout.gateIndex].marks[0].position
            // Both on starboard, running at 160°, towards the gate's left mark (rounded to port), which is 3 m
            // to port of seat 1's track. Seat 0 is outside her, a metre off, and ahead: seat 1's bow is only
            // 0.3 m past seat 0's stern. Seat 0's hull is 3 cm outside the zone: she reaches it on the next step,
            // seat 1 well after.
            let heading = F.starboard(race, offWind: deg2rad(160))
            let ahead = Vec2.heading(heading), toStarboard = ahead.rightPerp
            let outline = hull.outline
            func outsideAt(_ back: Double) -> Vec2 { gateLeft + toStarboard * (3 + hull.beam + 1) - ahead * back }
            func hullDistance(_ back: Double) -> Double {
                let boat = Boat(id: 0, isPlayer: false, colorIndex: 0, position: outsideAt(back), heading: heading, speed: 0)
                return Collision.distance(convex: boat.hull(outline: outline), to: gateLeft)
            }
            var (lo, hi) = (0.0, 40.0)
            for _ in 0..<60 {
                let mid = (lo + hi) / 2
                if hullDistance(mid) < race.course.zoneRadius + 0.03 { lo = mid } else { hi = mid }
            }
            let outside = outsideAt(hi)
            let inside = outside - toStarboard * (hull.beam + 1) - ahead * (hull.length - 0.3)
            // The hulls have shown the overlap for `overlapHeldTicks` ticks by the step on which seat 0 enters.
            let memory = WorldSnapshot.OverlapMemory(pair: .init(0, 1), isOverlapped: false, changeTicks: overlapHeldTicks - 1)
            try M.place(race, tick: 600, [M.Spot(position: outside, heading: heading, leg: CourseLayout.gateIndex),
                                          M.Spot(position: inside, heading: heading, leg: CourseLayout.gateIndex)],
                        overlap: memory)
            #expect(Rules.geometricOverlaps(race.boats, hull: hull) == [true])
            race.step()
            #expect(M.zone(race, 0)?.isIn == true && M.zone(race, 1)?.isIn == false)
            return M.record(race)
        }

        let lpc = RulesConfig.ticks(try F.race().rules.incidents.lastPointOfCertainty)
        #expect(lpc == 15)
        let doubtful = try #require(try entry(overlapHeldTicks: 9))
        #expect(doubtful == MarkRoomRecord(mark: "gate left", entitled: 0, owing: 1, rule: .givingMarkRoom,
                                           firstInZone: 0, overlappedAtZoneEntry: false))
        let certain = try #require(try entry(overlapHeldTicks: lpc))
        #expect(certain == MarkRoomRecord(mark: "gate left", entitled: 1, owing: 0, rule: .givingMarkRoom,
                                          firstInZone: 0, overlappedAtZoneEntry: true))
    }

    /// Section C's preamble: rule 18 is off at a starting mark while boats approach it to start (before the gun,
    /// and OCS boats returning), and on at a finishing mark (the same pin, on the finish leg).
    @Test func startingMarkOffFinishingMarkOn() throws {
        func sail(tick: Int, status: BoatStatus, leg: Int, above: Bool, heading: (Race) -> Double) throws -> (Race, [RaceEvent]) {
            let race = try F.race()
            let pin = race.course.startLine.pin.position
            let (up, right) = (race.course.upwind, race.course.right)
            let h = heading(race)
            let toPort = -Vec2.heading(h).rightPerp
            let at = pin + up * (above ? 7 : -7) + right * 3
            try M.place(race, tick: tick, [M.Spot(position: at, heading: h, leg: leg, status: status),
                                           M.Spot(position: at + toPort * (race.boatClass.hull.beam + 1), heading: h, leg: leg,
                                                  status: status)], overlap: M.overlapped)
            var events: [RaceEvent] = []
            race.step()
            events += race.drainEvents()
            #expect(Collision.distance(convex: race.boats[0].hull(outline: race.boatClass.hull.outline), to: pin)
                <= race.course.zoneRadius)
            return (race, events)
        }
        let upwind = { (race: Race) in F.starboard(race, offWind: .pi / 4) }
        let downwind = { (race: Race) in M.port(race, offWind: deg2rad(160)) }

        // Before the gun, approaching the pin to start.
        let starting = try sail(tick: -300, status: .prestart, leg: 0, above: false, heading: upwind)
        #expect(M.zone(starting.0, 0) == nil)
        #expect(M.record(starting.0) == nil && M.notices(starting.1).isEmpty)
        // OCS after the gun, sailing back to the line past the pin.
        let returning = try sail(tick: 60, status: .ocs, leg: 0, above: true, heading: downwind)
        #expect(returning.0.course.isReturning(returning.0.boats[0]))
        #expect(M.record(returning.0) == nil && M.notices(returning.1).isEmpty)

        // Finishing past the same pin, which is left to starboard: seat 0, on seat 1's starboard side, is inside.
        let finishLeg = try F.race().course.legs.count - 1
        let finishing = try sail(tick: 3000, status: .racing, leg: finishLeg, above: true, heading: downwind)
        #expect(finishing.0.course.legs[finishLeg] == .finish)
        #expect(M.record(finishing.0) == MarkRoomRecord(mark: "pin", entitled: 0, owing: 1, rule: .givingMarkRoom,
                                                        firstInZone: 0, overlappedAtZoneEntry: true))
        #expect(M.notices(finishing.1) == [.markRoomNotice(boat: 0, entitledOver: 1, mark: "pin")])
    }

    /// 18.3: a boat that tacks from port to starboard in the zone of the windward mark (left to port) loses
    /// 18.2 against a starboard boat fetching it. Inside her, she gets no mark-room (18.2(c) would have given
    /// her it). Outside her, she owes the starboard boat mark-room, since that boat has been on starboard since
    /// she entered the zone and has the inside overlap.
    @Test func tackingOntoStarboardInTheZoneLosesMarkRoom() throws {
        func tack(inside: Bool) throws -> (race: Race, events: [RaceEvent]) {
            let race = try F.race()
            let mark = M.windwardMark(race)
            let starboard = F.starboard(race, offWind: .pi / 4)
            let ahead = Vec2.heading(starboard), toStarboard = ahead.rightPerp
            // Seat 1 on starboard, fetching: the mark 2 m to port of her track. Seat 0, abreast of her 4 m to
            // port (inside) or to starboard (outside), on port just short of head to wind, the helm hard over.
            let fetching = mark - ahead * 8 + toStarboard * 2
            let tacker = fetching + toStarboard * (inside ? -4 : 4)
            try M.place(race, tick: 600, [M.Spot(position: tacker, heading: M.port(race, offWind: deg2rad(3)), leg: 0),
                                          M.Spot(position: fetching, heading: starboard, leg: 0)],
                        overlap: M.overlapped) { snapshot in
                snapshot.seats[0].heldInput = BoatInput(rudder: -127 as Int8)
                snapshot.seats[0].boat.rudder = -1
                snapshot.seats[0].boat.desiredRudder = -1
            }
            #expect(Rules.isFetchingOnStarboard(race.boats[1], mark: mark, boatClass: race.boatClass))
            var events: [RaceEvent] = []
            for _ in 0..<30 where race.boats[0].tack == .port {
                race.step()
                events += race.drainEvents()
            }
            #expect(race.boats[0].tack == .starboard && race.boats[1].tack == .starboard)
            #expect(events.contains { $0.kind == .tacked(seat: 0) })
            #expect(M.zone(race, 0)?.isIn == true && M.zone(race, 1)?.isIn == true)
            #expect(race.isOverlapped(0, 1))
            return (race, events)
        }

        let tackedInside = try tack(inside: true)
        #expect(M.record(tackedInside.race) == nil)
        #expect(M.notices(tackedInside.events).isEmpty)

        let tackedOutside = try tack(inside: false)
        #expect(M.record(tackedOutside.race) == MarkRoomRecord(mark: "windward mark", entitled: 1, owing: 0,
                                                               rule: .tackingInTheZone, firstInZone: 1,
                                                               overlappedAtZoneEntry: true))
        #expect(M.notices(tackedOutside.events) == [.markRoomNotice(boat: 1, entitledOver: 0, mark: "windward mark")])
    }
}
