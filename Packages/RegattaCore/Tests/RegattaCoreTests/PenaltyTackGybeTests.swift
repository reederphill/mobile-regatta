import Foundation
import Testing
@testable import RegattaCore

/// fleet-rules@6 (a `tackAndGybe` penalty) in open water, as `openWaterPenaltyRules` is fleet-rules@3.
let openWaterTackGybeRules: RulesConfigFile = {
    var text = String(decoding: try! RulesConfigFile.bundledData(id: "fleet-rules", version: 6)!, as: UTF8.self)
    for (old, new) in [(#""acrossAxisBeatFraction": 0.75"#, #""acrossAxisBeatFraction": 20"#),
                       (#""belowLineLineLengths": 1"#, #""belowLineLineLengths": 30"#),
                       (#""aboveWindwardBeatFraction": 0.25"#, #""aboveWindwardBeatFraction": 5"#)] {
        precondition(text.components(separatedBy: old).count == 2, "fleet-rules@6's \(old) has moved")
        text = text.replacingOccurrences(of: old, with: new)
    }
    return try! RulesConfigFile(data: Data(text.utf8))
}()

/// #487 acceptance: under fleet-rules@6 a penalty turn is one tack and one gybe made turning the same way (RRS 44.2),
/// counted at the boom's crossings, with one limit, 40 s from the turn's clock.
@Suite struct PenaltyTackGybeTests {
    static let penalty = openWaterTackGybeRules.content.raceFormat.penalty
    static let complete = RulesConfig.ticks(penalty.complete)

    /// A wind direction a test can shift mid-race.
    final class Shift: @unchecked Sendable { var radians = 0.0 }

    /// A two-boat race in open water under fleet-rules@6 (`scriptedWindRace`), in 10 kn from the north (plus `shift`),
    /// sailing `boatClass` (by default ilca-dinghy@3): seat 0 on starboard tack (boom to port) at `angle` off the
    /// wind, at the polar's speed, far from every mark and edge. One step in, owing nothing.
    func race(angle: Double, boatClass: FileRef? = nil, shift: Shift = Shift()) throws -> Race {
        let race = try scriptedWindRace(boatClass: boatClass, rules: openWaterTackGybeRules, wind: { _ in
            Wind(direction: shift.radians, speed: metresPerSecond(knots: 10))
        }) { boat, boatClass in
            boat.boomSide = .port
            boat.heading = wrapAngle(boat.windDirection - angle)
            boat.speed = boatClass.polar.speed(twa: angle, tws: boat.windSpeed)
        }
        race.step()
        #expect(race.rules.raceFormat.penalty.turn == .tackAndGybe)
        _ = race.drainEvents()
        return race
    }

    /// Close-hauled: the polar's best upwind angle in 10 kn.
    func closeHauled(_ race: Race) -> Double { race.boatClass.polar.bestUpwind(tws: metresPerSecond(knots: 10)).twa }

    func helm(_ race: Race, _ rudder: Double) {
        #expect(race.apply(BoatInput(rudder: rudder), seat: 0, atTick: race.tick + 1) != nil)
    }

    /// One step: the events, and the heading turned on it.
    func step(_ race: Race) -> (kinds: [RaceEvent.Kind], turn: Double) {
        let heading = race.boats[0].heading
        race.step()
        return (race.drainEvents().map(\.kind), wrapAngle(race.boats[0].heading - heading))
    }

    /// Steps until `until` holds (at most `limit` ticks): the events on the way, in order, and the heading turned.
    @discardableResult
    func steps(_ race: Race, limit: Int, until: (Race, [RaceEvent.Kind]) -> Bool = { _, _ in false })
        -> (kinds: [RaceEvent.Kind], turned: Double, stopped: Bool) {
        var kinds: [RaceEvent.Kind] = [], turned = 0.0
        for _ in 0..<limit {
            let one = step(race)
            kinds += one.kinds
            turned += one.turn
            if until(race, one.kinds) { return (kinds, turned, true) }
        }
        return (kinds, turned, false)
    }

    static let started = RaceEvent.Kind.penaltyStarted(seat: 0)
    static let served = RaceEvent.Kind.penaltyServed(seat: 0)
    static let reset = RaceEvent.Kind.penaltyReset(seat: 0)
    static let tacked = RaceEvent.Kind.tacked(seat: 0)
    static let gybed = RaceEvent.Kind.gybed(seat: 0)
    static func disqualified(_ kinds: [RaceEvent.Kind]) -> Bool {
        kinds.contains { if case .disqualified(seat: 0, _) = $0 { true } else { false } }
    }
    static func crossed(_: Race, _ kinds: [RaceEvent.Kind]) -> Bool { kinds.contains(tacked) || kinds.contains(gybed) }

    /// Close-hauled on starboard, luffing hard: the tack starts the turn, and the gybe on the way round serves it, at
    /// about 180° plus her angle off the wind turned (≈ 225°), not 360°.
    @Test func luffingFromCloseHauledServesAtTheGybe() throws {
        let race = try race(angle: deg2rad(45))
        race.penalize(0)
        helm(race, 1)
        let tack = steps(race, limit: 10 * Race.tickRate, until: Self.crossed)
        #expect(tack.kinds.contains(Self.tacked) && tack.kinds.contains(Self.started))
        #expect(race.boats[0].penaltyFirstCrossing == .tack && race.boats[0].penaltyDirection == 1)
        #expect(race.boats[0].isTakingPenalty && race.owedPenalty(ofSeat: 0)?.hasTacked == true)
        let gybe = steps(race, limit: 20 * Race.tickRate) { _, kinds in kinds.contains(Self.served) }
        #expect(gybe.stopped && gybe.kinds.contains(Self.gybed))
        let turned = rad2deg(tack.turned + gybe.turned)
        #expect(turned > 200 && turned < 260, "served at \(turned)° turned")
        #expect(!(tack.kinds + gybe.kinds).contains(Self.reset))
        let boat = race.boats[0]
        #expect(boat.penaltyTurnsOwed == 0 && boat.penaltyFirstCrossing == nil && boat.penaltyDirection == 0)
        #expect(!boat.isTakingPenalty && race.owedPenalty(ofSeat: 0) == nil)
    }

    /// On a run on starboard, bearing away hard: the gybe starts the turn, the tack on the way round serves it.
    @Test func bearingAwayFromARunServesAtTheTack() throws {
        let race = try race(angle: deg2rad(150))
        race.penalize(0)
        helm(race, -1)
        let gybe = steps(race, limit: 10 * Race.tickRate, until: Self.crossed)
        #expect(gybe.kinds.contains(Self.gybed) && gybe.kinds.contains(Self.started))
        #expect(race.boats[0].penaltyFirstCrossing == .gybe && race.boats[0].penaltyDirection == -1)
        let tack = steps(race, limit: 20 * Race.tickRate) { _, kinds in kinds.contains(Self.served) }
        #expect(tack.stopped && tack.kinds.contains(Self.tacked))
        let turned = -rad2deg(gybe.turned + tack.turned)
        #expect(turned > 180 && turned < 270, "served at \(turned)° turned")
        #expect(race.boats[0].penaltyTurnsOwed == 0)
    }

    /// After the tack, bearing away and then luffing back without crossing the wind costs nothing: the tack stands,
    /// and the gybe the same way serves the turn.
    @Test func turningBackWithoutCrossingKeepsTheCrossing() throws {
        let race = try race(angle: deg2rad(45))
        race.penalize(0)
        helm(race, 1)
        steps(race, limit: 10 * Race.tickRate, until: Self.crossed)
        #expect(race.boats[0].penaltyFirstCrossing == .tack)
        // On round to a beam reach on port, then back up towards close-hauled, short of head to wind.
        steps(race, limit: 2 * Race.tickRate)
        helm(race, -1)
        let back = steps(race, limit: Race.tickRate)
        #expect(back.turned < -deg2rad(10), "she turned back \(rad2deg(back.turned))°")
        #expect(!Self.crossed(race, back.kinds) && !back.kinds.contains(Self.reset))
        #expect(race.boats[0].penaltyFirstCrossing == .tack && race.boats[0].penaltyDirection == 1)
        #expect(race.boats[0].isTakingPenalty)
        helm(race, 1)
        let on = steps(race, limit: 20 * Race.tickRate) { _, kinds in kinds.contains(Self.served) }
        #expect(on.stopped && on.kinds.contains(Self.gybed) && !on.kinds.contains(Self.reset))
    }

    /// Tack to port, tack back to starboard (the recross: `penaltyReset`, the turn now going the other way), then
    /// bear away to the gybe: served.
    @Test func recrossStartsTheTurnTheOtherWay() throws {
        let race = try race(angle: deg2rad(45))
        race.penalize(0)
        helm(race, 1)
        steps(race, limit: 10 * Race.tickRate, until: Self.crossed)
        #expect(race.boats[0].penaltyFirstCrossing == .tack && race.boats[0].penaltyDirection == 1)
        helm(race, -1)
        let back = steps(race, limit: 10 * Race.tickRate, until: Self.crossed)
        #expect(back.kinds.contains(Self.tacked) && back.kinds.contains(Self.reset))
        #expect(race.boats[0].boomSide == .port, "back on starboard tack")
        #expect(race.boats[0].penaltyFirstCrossing == .tack && race.boats[0].penaltyDirection == -1)
        #expect(race.boats[0].isTakingPenalty && race.boats[0].penaltyTurnsOwed == 1)
        let on = steps(race, limit: 20 * Race.tickRate) { _, kinds in kinds.contains(Self.served) }
        #expect(on.stopped && on.kinds.contains(Self.gybed))
        #expect(race.boats[0].penaltyTurnsOwed == 0)
    }

    /// A wind shift that flips the boom while her heading holds (a skiff's centred rudder holds her heading) is a
    /// crossing on a tick she didn't turn: it counts for nothing.
    @Test func windShiftBoomFlipDoesNotCount() throws {
        let shift = Shift()
        let skiff = try BoatClassFile.bundled(id: SkiffFixtures.classID, version: SkiffFixtures.defaultVersion).ref
        let race = try race(angle: deg2rad(170), boatClass: skiff, shift: shift)
        #expect(race.boats[0].autohelm == nil)
        race.penalize(0)
        // Veering 60°, the wind comes 50° by the lee: the boom flips.
        shift.radians = deg2rad(60)
        var flip: (kinds: [RaceEvent.Kind], turn: Double)?
        for _ in 0..<Race.tickRate {
            let one = step(race)
            if one.kinds.contains(Self.gybed) {
                flip = one
                break
            }
        }
        let gybe = try #require(flip, "the shift flips the boom")
        #expect(gybe.turn == 0)
        #expect(!gybe.kinds.contains(Self.started))
        #expect(race.boats[0].penaltyFirstCrossing == nil && race.boats[0].penaltyDirection == 0)
        #expect(!race.boats[0].isTakingPenalty && race.boats[0].penaltyTurnsOwed == 1)
    }

    /// In the zone of the mark of her leg, or of the one she has just rounded, a tack counts for nothing.
    @Test(arguments: [0, 1])
    func crossingsWhileRoundingDoNotCount(leg: Int) throws {
        let race = try race(angle: deg2rad(45))
        let mark = try #require(race.course.elements[CourseLayout.windwardIndex].marks.first)
        try jump(race, to: race.tick) { snapshot in
            var boat = snapshot.seats[0].boat
            placeRacing(&boat, leg: leg, at: mark.position - Vec2.heading(boat.heading) * 6)
            snapshot.seats[0].boat = boat
        }
        race.penalize(0)
        helm(race, 1)
        let tack = steps(race, limit: 10 * Race.tickRate, until: Self.crossed)
        #expect(tack.kinds.contains(Self.tacked))
        let zone = try #require(race.course.markZone(of: race.boats[0], hull: race.boats[0].hull(outline: race.boatClass.hull.outline)))
        #expect(leg == 1 || zone.isIn, "still in the zone")
        #expect(race.boats[0].legIndex == leg)
        #expect(!tack.kinds.contains(Self.started))
        #expect(race.boats[0].penaltyFirstCrossing == nil && race.boats[0].penaltyDirection == 0)
        #expect(!race.boats[0].isTakingPenalty)
    }

    /// Completing a rounding stage between the crossings (the tack onto the layline, round, gybe) voids the first:
    /// `penaltyReset`, and the turn's way unset again.
    @Test func roundingBetweenTheCrossingsVoidsTheFirst() throws {
        let race = try race(angle: deg2rad(45))
        race.penalize(0)
        helm(race, 1)
        steps(race, limit: 10 * Race.tickRate, until: Self.crossed)
        #expect(race.boats[0].penaltyFirstCrossing == .tack && race.boats[0].penaltyDirection == 1)
        helm(race, 0)
        // Racing on leg 0, a few centimetres short of the windward mark's first rounding ray, sailing across it.
        let ray = try #require(race.course.roundingStages(of: race.course.legs[0]).first?.first)
        let mid = (ray.a + ray.b) * 0.5, along = (ray.b - ray.a).normalized
        let left = Vec2(-along.y, along.x)
        try jump(race, to: race.tick) { snapshot in
            var boat = snapshot.seats[0].boat
            placeRacing(&boat, leg: 0, at: mid - left * 0.02)
            boat.heading = atan2(left.x, left.y)
            #expect((Vec2.heading(boat.heading) - left).length < 1e-9, "heading across the ray, to its left")
            boat.speed = 3
            snapshot.seats[0].boat = boat
        }
        let kinds = step(race).kinds
        #expect(race.boats[0].roundingStage == 1)
        #expect(kinds.contains(Self.reset))
        #expect(race.boats[0].penaltyFirstCrossing == nil && race.boats[0].penaltyDirection == 0)
        #expect(race.boats[0].penaltyTurnsOwed == 1 && !race.boats[0].isTakingPenalty)
    }

    /// Let go after the tack, the autohelm holds her on the new tack: it neither tacks nor gybes, so it can't undo
    /// the turn. Taking the helm again, the gybe the same way serves it.
    @Test func autohelmLetGoNeverUndoesATurn() throws {
        let race = try race(angle: deg2rad(45))
        race.penalize(0)
        helm(race, 1)
        steps(race, limit: 10 * Race.tickRate, until: Self.crossed)
        #expect(race.boats[0].penaltyFirstCrossing == .tack)
        helm(race, 0)
        let held = steps(race, limit: 5 * Race.tickRate)
        #expect(race.boats[0].autohelm != nil)
        #expect(!Self.crossed(race, held.kinds) && !held.kinds.contains(Self.reset))
        #expect(race.boats[0].penaltyFirstCrossing == .tack && race.boats[0].penaltyDirection == 1)
        helm(race, 1)
        let on = steps(race, limit: 20 * Race.tickRate) { _, kinds in kinds.contains(Self.served) }
        #expect(on.stopped && on.kinds.contains(Self.gybed))
    }

    /// Owing two turns, after the first is served every crossing the other way counts for nothing (RRS 44.2: the
    /// turns go the same way); turning the first one's way again serves the second.
    @Test func furtherTurnsGoTheFirstTurnsWay() throws {
        let race = try race(angle: deg2rad(45))
        race.penalize(0)
        race.penalize(0)
        helm(race, 1)
        let first = steps(race, limit: 20 * Race.tickRate) { _, kinds in kinds.contains(Self.served) }
        #expect(first.stopped)
        let servedAt = race.tick
        #expect(race.boats[0].penaltyTurnsOwed == 1 && race.boats[0].penaltyClockTick == servedAt)
        #expect(race.boats[0].penaltyDirection == 1 && race.boats[0].penaltyDirectionLocked)
        #expect(race.boats[0].penaltyFirstCrossing == nil && !race.boats[0].isTakingPenalty)
        // A full circle the other way: a gybe back, a tack, a gybe: none counts.
        helm(race, -1)
        let other = steps(race, limit: 14 * Race.tickRate)
        #expect(other.kinds.filter { $0 == Self.tacked || $0 == Self.gybed }.count >= 3)
        #expect(!other.kinds.contains(Self.started) && !other.kinds.contains(Self.served) && !other.kinds.contains(Self.reset))
        #expect(race.boats[0].penaltyFirstCrossing == nil && race.boats[0].penaltyTurnsOwed == 1)
        // The first one's way again.
        helm(race, 1)
        let again = steps(race, limit: 20 * Race.tickRate) { _, kinds in kinds.contains(Self.served) }
        #expect(again.stopped && again.kinds.contains(Self.started))
        #expect(race.tick < servedAt + Self.complete && !Self.disqualified(again.kinds))
        #expect(race.boats[0].penaltyTurnsOwed == 0 && !race.boats[0].penaltyDirectionLocked && race.boats[0].penaltyDirection == 0)
    }

    /// Holding her course, she is not disqualified at 20 s (no start deadline): only at the turn's 40 s, `missedComplete`.
    @Test func disqualifiedAtFortySecondsWithNoStartDeadline() throws {
        let race = try race(angle: deg2rad(60))
        let call = race.tick
        #expect(race.penalize(0) == call)
        #expect(race.owedPenalty(ofSeat: 0) == OwedPenalty(turnsOwed: 1, startDeadlineTick: call + Self.complete,
                                                           completeDeadlineTick: call + Self.complete, progress: 0,
                                                           isStarted: false))
        let held = steps(race, limit: Self.complete - 1)
        #expect(!Self.disqualified(held.kinds) && race.boats[0].status != .dsq)
        #expect(race.tick == call + Self.complete - 1)
        let kinds = step(race).kinds
        #expect(kinds.contains(.disqualified(seat: 0, reason: Race.missedComplete)))
        #expect(race.boats[0].status == .dsq && race.boats[0].penaltyTurnsOwed == 0)
    }

    /// The clock starts when she is clear of the mark (fleet-rules@6, the owner's rule of 2026-10-11): a turn that
    /// becomes current while she is rounding (`Race.isRounding`) has no clock, and no deadline, however long she stays
    /// in the zone; its clock starts on the first tick she is clear of it, with the whole limit to run. A turn whose clock
    /// started before a rounding keeps running through it.
    @Test func clockStartsWhenClearOfTheMark() throws {
        let race = try race(angle: deg2rad(45))
        let mark = try #require(race.course.elements[CourseLayout.windwardIndex].marks.first)
        let heading = race.boats[0].heading
        /// Some of her hull in the windward mark's zone, on leg 0: rounding (`Race.isRounding`).
        func inZone() -> Bool {
            let hull = race.boats[0].hull(outline: race.boatClass.hull.outline)
            return race.boats[0].legIndex == 0 && Collision.distance(convex: hull, to: mark.position) <= race.course.zoneRadius
        }
        /// Holds her in the windward mark's zone, 6 m short of it and stopped, for `seconds` or until she is disqualified:
        /// the events on the way.
        func holdInTheZone(seconds: Int) throws -> [RaceEvent.Kind] {
            var kinds: [RaceEvent.Kind] = []
            for _ in 0..<(seconds * 2) {
                try jump(race, to: race.tick) { snapshot in
                    var boat = snapshot.seats[0].boat
                    placeRacing(&boat, leg: 0, at: mark.position - Vec2.heading(heading) * 6)
                    boat.heading = heading
                    boat.speed = 0
                    snapshot.seats[0].boat = boat
                }
                kinds += steps(race, limit: Race.tickRate / 2).kinds
                if Self.disqualified(kinds) { break }
                #expect(inZone())
            }
            return kinds
        }

        // Called while rounding: no clock, the whole limit shown from now, and no DSQ in 50 s of rounding.
        try jump(race, to: race.tick) { snapshot in
            placeRacing(&snapshot.seats[0].boat, leg: 0, at: mark.position - Vec2.heading(heading) * 6)
        }
        #expect(inZone())
        #expect(race.penalize(0) == nil, "a call while rounding fixes no deadline")
        #expect(race.boats[0].penaltyClockTick == nil)
        let pending = try #require(race.owedPenalty(ofSeat: 0))
        #expect(pending.isClockPending && pending.completeDeadlineTick == race.tick + Self.complete)
        let rounding = try holdInTheZone(seconds: 50)
        #expect(!Self.disqualified(rounding) && race.boats[0].status == .racing)
        #expect(race.boats[0].penaltyTurnsOwed == 1 && race.boats[0].penaltyClockTick == nil)

        // Clear of the mark: the clock starts at that tick's end, and the limit runs from there.
        try jump(race, to: race.tick) { snapshot in
            placeRacing(&snapshot.seats[0].boat, leg: 0, at: mark.position - Vec2.heading(heading) * 200)
        }
        race.step()
        _ = race.drainEvents()
        let clock = race.tick
        #expect(!inZone() && race.boats[0].penaltyClockTick == clock)
        #expect(race.owedPenalty(ofSeat: 0)?.isClockPending == false)
        #expect(race.owedPenalty(ofSeat: 0)?.completeDeadlineTick == clock + Self.complete)

        // Back in the zone, the clock runs on: DSQ at its limit.
        let through = try holdInTheZone(seconds: 50)
        #expect(Self.disqualified(through) && race.boats[0].status == .dsq)
        #expect(through.contains(.disqualified(seat: 0, reason: Race.missedComplete)))
    }

    /// A snapshot's crossings must be ones a race can have (#487): a way of ±1 or 0, none while she owes nothing, a
    /// crossing or a lock only with a way, a held crossing only after a first.
    @Test func snapshotsRefuseCrossingsNoRaceHas() throws {
        let race = try race(angle: deg2rad(45))
        race.penalize(0)
        let good = race.exportSnapshot()
        for (field, edit) in [
            ("penaltyDirection", { (b: inout Boat) in b.penaltyDirection = 2 }),
            ("penaltyDirection", { (b: inout Boat) in b.penaltyTurnsOwed = 0; b.penaltyClockTick = nil; b.penaltyDirection = 1 }),
            ("penaltyFirstCrossing", { (b: inout Boat) in b.penaltyFirstCrossing = .tack }),
            ("penaltyDirectionLocked", { (b: inout Boat) in b.penaltyDirectionLocked = true }),
            ("penaltyCrossingHeld", { (b: inout Boat) in b.penaltyDirection = 1; b.penaltyCrossingHeld = true }),
        ] as [(String, (inout Boat) -> Void)] {
            var snapshot = good
            edit(&snapshot.seats[0].boat)
            #expect(throws: WorldSnapshotError.invalidBoat(seat: 0, field: field)) { try race.importSnapshot(snapshot) }
        }
        var turning = good
        turning.seats[0].boat.penaltyDirection = -1
        turning.seats[0].boat.penaltyFirstCrossing = .gybe
        turning.seats[0].boat.penaltyDirectionLocked = true
        try race.importSnapshot(turning)
        #expect(race.boats[0].isTakingPenalty && race.owedPenalty(ofSeat: 0)?.hasGybed == true)
    }
}
