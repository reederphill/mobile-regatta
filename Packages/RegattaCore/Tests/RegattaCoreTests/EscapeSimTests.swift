import Foundation
import Testing
@testable import RegattaCore

/// Two boats set up for the escape simulation (#92): `IncidentFixture`'s two-seat race (ilca-dinghy@3 in a
/// steady 10 kn from the course's axis, no current, the default rules fleet-rules@5), placed mid-beat and sailed
/// on from there. Placing imports a snapshot, so the umpire records their track from the placing tick on.
enum EscapeFixture {
    typealias F = IncidentFixture

    /// What an incident came to: its rule call, the tick of it, whether the boats touched, and whom the
    /// incident exonerates.
    struct Outcome: Equatable {
        let call: RuleCall
        let tick: Int
        let contact: Bool
        let exonerated: [Int]
    }

    /// Steps `race` until a rule call, at most `ticks` steps, `watch` reading it after each step. Nil if none.
    static func sailToCall(_ race: Race, within ticks: Int, watch: (Race) -> Void = { _ in }) -> Outcome? {
        var contact = false
        for _ in 0..<ticks {
            race.step()
            watch(race)
            let events = race.drainEvents()
            contact = contact || !F.contacts(events).isEmpty
            if let call = F.calls(events).first {
                return Outcome(call: call, tick: race.tick, contact: contact,
                               exonerated: race.incidents[call.incidentId]?.exonerated ?? [])
            }
        }
        return nil
    }

    /// Seat 1 tacking from port onto starboard ahead and to leeward of seat 0 (#92's rule 15 scenario). Seat 0
    /// sails starboard 48° off the wind at 3 m/s: her rudder centred, so her autohelm holds that angle from the
    /// next step. Seat 1 is just past head to wind (15° off it on starboard, her boom across) at 1.5 m/s, rule
    /// 13 still hers, her autohelm bearing her away to the groove: her centre `ahead` hull lengths ahead of
    /// seat 0's and `leeward` metres to leeward of it, along and across a heading 45° off the wind. Not overlapped.
    static func tack(_ race: Race, ahead: Double, leeward: Double) throws {
        let hull = race.boatClass.hull
        let at = F.midBeat(race)
        let forward = Vec2.heading(F.starboard(race, offWind: deg2rad(45)))
        try jump(race, to: 300) { snapshot in
            for seat in 0..<2 {
                var boat = snapshot.seats[seat].boat
                placeRacing(&boat, leg: 0, at: at)
                boat.boomSide = .port
                boat.heading = F.starboard(race, offWind: deg2rad(48))
                boat.speed = 3
                boat.rudder = 0
                boat.desiredRudder = 0
                boat.autohelm = nil
                boat.isTacking = false
                boat.penaltyTurnsOwed = 0
                boat.penaltyProgress = 0
                boat.penaltyClockTick = nil
                boat.queuedPenaltyCallTicks = []
                if seat == 1 {
                    boat.position = at + forward * (ahead * hull.length) - forward.rightPerp * leeward
                    boat.heading = F.starboard(race, offWind: deg2rad(15))
                    boat.speed = 1.5
                    boat.isTacking = true
                    boat.autohelm = Autohelm(target: .groove(.upwind))
                }
                snapshot.seats[seat].boat = boat
                snapshot.seats[seat].heldInput = .neutral
            }
            snapshot.touchingBoats = []
            snapshot.overlaps = []
        }
    }

    /// Where seat 1 is from seat 0: hull lengths ahead along seat 0's heading, and metres to leeward of it
    /// (her port side, on starboard tack).
    static func tackerFromStarboardBoat(_ race: Race) -> (ahead: Double, leeward: Double) {
        let starboard = race.boats[0], offset = race.boats[1].position - starboard.position
        return (offset.dot(starboard.forward) / race.boatClass.hull.length, -offset.dot(starboard.forward.rightPerp))
    }

    /// Seat 0 on a beam reach on starboard with seat 1 to windward of her, `gap` metres between the hulls, seat 1
    /// turned `converging` radians towards her (parallel by default, away if negative), both on their autohelms
    /// for `ticks` steps (a second by default) with no call; then seat 0 holds `rudder` (towards the wind) from
    /// the next tick. Returns the tick the rudder is applied at.
    static func luff(_ race: Race, gap: Double, converging: Double = 0, rudder: Double,
                     after ticks: Int = Race.tickRate) throws -> Int {
        try F.place(race, tick: 300, at: F.midBeat(race), heading: F.starboard(race, offWind: .pi / 2),
                    abeam: F.abeam(gap: gap, converging: converging, hull: race.boatClass.hull), converging: converging)
        #expect(sailToCall(race, within: ticks) == nil, "sailing \(gap) m apart is no foul")
        let at = race.tick + 1
        _ = race.apply(BoatInput(rudder: rudder), seat: 0, atTick: at)
        return at
    }

    /// How fast seat 0 turned through each step `watch` saw, radians a second.
    final class TurnRate {
        private var heading: Double?
        private var rates: [(tick: Int, rate: Double)] = []

        /// The fastest.
        var fastest: Double { rates.map(\.rate).max() ?? 0 }

        /// The first tick she turned faster than `rate` through the step to it, if any.
        func firstTick(above rate: Double) -> Int? { rates.first { $0.rate > rate }?.tick }

        func watch(_ race: Race) {
            let now = race.boats[0].heading
            if let heading { rates.append((race.tick, abs(wrapAngle(now - heading)) * Double(Race.tickRate))) }
            heading = now
        }
    }
}

/// #92 acceptance: room under rules 15 and 16.1 judged by the escape simulation (#9): the keep-clear boat's
/// best manoeuvre with the real boat dynamics over the 2 s horizon, against the right-of-way boat's recorded
/// track. With no escape, the right-of-way boat breaks the rule and the other is exonerated (43.1(b)).
@Suite struct EscapeSimTests {
    typealias E = EscapeFixture
    typealias F = IncidentFixture

    /// The port boat completes her tack about a hull length ahead and to leeward of the starboard boat, who
    /// hits her within a second: too soon to keep clear. Rule 15 on the tacker, the starboard boat exonerated.
    @Test func tackTooCloseBreaksRule15() throws {
        let race = try F.race()
        try E.tack(race, ahead: 1.5, leeward: 1.5)
        var completed: (tick: Int, ahead: Double, leeward: Double)?
        let outcome = try #require(E.sailToCall(race, within: 10 * Race.tickRate) { race in
            if completed == nil, !race.boats[1].isTacking {
                let at = E.tackerFromStarboardBoat(race)
                completed = (race.tick, at.ahead, at.leeward)
            }
        })
        let completion = try #require(completed)
        #expect(abs(completion.ahead - 1) < 0.25 && completion.leeward > 0, "\(completion)")
        #expect(outcome.contact)
        #expect(outcome.tick - completion.tick <= Race.tickRate, "contact within a second of the tack")
        #expect(outcome.call.rule == .acquiringRightOfWay && outcome.call.offender == 1 && outcome.call.victim == 0)
        #expect(outcome.exonerated == [0])
        #expect(race.incidents[outcome.call.incidentId]?.outcome == .called(outcome.call))
        #expect(race.boats[1].penaltyTurnsOwed == 1 && race.boats[0].penaltyTurnsOwed == 0)
    }

    /// The same tack two hull lengths ahead and further to leeward: four seconds after it the starboard boat's
    /// near-miss sweep reaches her (the call is a near miss, not contact), with time to have kept clear. Rule 11 on the windward boat, no one exonerated.
    @Test func tackWithTimeToRespondIsRule11() throws {
        let race = try F.race()
        try E.tack(race, ahead: 2.4, leeward: 2.5)
        var completed: Int?
        let outcome = try #require(E.sailToCall(race, within: 10 * Race.tickRate) { race in
            if completed == nil, !race.boats[1].isTacking { completed = race.tick }
        })
        let completion = try #require(completed)
        let gap = outcome.tick - completion
        #expect(gap > RulesConfig.ticks(race.rules.incidents.escape.initially))
        #expect((7 * Race.tickRate / 2)...(5 * Race.tickRate) ~= gap, "about 4 s after the tack: \(gap) ticks")
        #expect(outcome.call.rule == .windwardLeeward && outcome.call.offender == 0 && outcome.call.victim == 1)
        #expect(outcome.exonerated.isEmpty)
        #expect(race.boats[0].penaltyTurnsOwed == 1 && race.boats[1].penaltyTurnsOwed == 0)
    }

    /// The leeward boat luffs hard with the windward boat 0.5 m off: nothing the windward boat can do keeps her
    /// clear, and had the leeward boat held her course she was clear. Rule 16.1 on the leeward boat, the
    /// windward boat exonerated.
    @Test func hardLuffBreaks16_1() throws {
        let race = try F.race()
        let luffed = try E.luff(race, gap: 0.5, rudder: 1)
        let rate = E.TurnRate()
        let outcome = try #require(E.sailToCall(race, within: 3 * Race.tickRate, watch: rate.watch))
        #expect(outcome.tick - luffed < Race.tickRate)
        #expect(rate.fastest > (try #require(race.rules.incidents.escape.changesCourse)))
        #expect(outcome.call.rule == .changingCourse && outcome.call.offender == 0 && outcome.call.victim == 1)
        #expect(outcome.exonerated == [1])
        #expect(race.boats[0].penaltyTurnsOwed == 1 && race.boats[1].penaltyTurnsOwed == 0)
    }

    /// A gentler luff, half the rudder, with 1.5 m between the hulls: still a course change (she turns faster
    /// than the rules' "changes course" rate), but the windward boat, holding her course, had room to keep clear
    /// and didn't. Rule 11 on her, no one exonerated.
    @Test func gentleLuffWithRoomIsRule11() throws {
        let race = try F.race()
        _ = try E.luff(race, gap: 1.5, rudder: 0.5)
        let rate = E.TurnRate()
        let outcome = try #require(E.sailToCall(race, within: 5 * Race.tickRate, watch: rate.watch))
        #expect(rate.fastest > (try #require(race.rules.incidents.escape.changesCourse)), "a course change")
        #expect(outcome.call.rule == .windwardLeeward && outcome.call.offender == 1 && outcome.call.victim == 0)
        #expect(outcome.exonerated.isEmpty)
        #expect(race.boats[1].penaltyTurnsOwed == 1 && race.boats[0].penaltyTurnsOwed == 0)
    }

    /// Seat 0 luffing hard (or, `rudder` 0, holding her course) after `E.luff`'s placing, sailed to a call: how
    /// fast she turned through each step from the luff, and the call, if any, within 3 s.
    private func luff(gap: Double, converging: Double, after ticks: Int,
                      rudder: Double) throws -> (race: Race, rate: E.TurnRate, outcome: E.Outcome?) {
        let race = try F.race()
        _ = try E.luff(race, gap: gap, converging: converging, rudder: rudder, after: ticks)
        let rate = E.TurnRate()
        rate.watch(race)
        return (race, rate, E.sailToCall(race, within: 3 * Race.tickRate, watch: rate.watch))
    }

    /// #273: the windward boat sails half a degree higher than the leeward boat, 0.28 m off and opening, clear of
    /// the leeward boat's sweep. The leeward boat luffs hard, and her sweep reaches the windward boat on the very
    /// tick her turn first counts as a course change: the windward boat has no tick to answer in before it. Held,
    /// the leeward boat's course left the windward boat clear then and room to stay clear after, so the luff took
    /// her room: rule 16.1 on the leeward boat, the windward boat exonerated.
    @Test func sameTickLuffIntoTheKeepClearBoatIs16_1() throws {
        let changesCourse = try #require(try F.race().rules.incidents.escape.changesCourse)
        let (gap, converging, after) = (0.276, deg2rad(-0.5), 10)
        let held = try luff(gap: gap, converging: converging, after: after, rudder: 0)
        #expect(held.outcome == nil, "holding her course, no incident")

        let (race, rate, luffed) = try luff(gap: gap, converging: converging, after: after, rudder: 1)
        let outcome = try #require(luffed)
        #expect(rate.firstTick(above: changesCourse) == outcome.tick, "the course change is first seen on the incident's tick")
        #expect(outcome.call.rule == .changingCourse && outcome.call.offender == 0 && outcome.call.victim == 1)
        #expect(outcome.exonerated == [1])
        #expect(race.boats[0].penaltyTurnsOwed == 1 && race.boats[1].penaltyTurnsOwed == 0)
    }

    /// #273: the windward boat bears down on the leeward boat, 6° towards her, 1.2 m off. The leeward boat luffs
    /// hard, and her sweep reaches the windward boat on the very tick her turn first counts as a course change;
    /// but holding her course, the leeward boat's sweep hits the windward boat anyway two ticks later, too soon for
    /// any escape from the incident's tick. The windward boat was failing to keep clear, and the luff took nothing
    /// from her: the Section A call stands, rule 11 on the windward boat, no one exonerated.
    @Test func sameTickLuffIntoABoatAlreadyFailingToKeepClearIsTheObligation() throws {
        let changesCourse = try #require(try F.race().rules.incidents.escape.changesCourse)
        let (gap, converging, after) = (1.2, deg2rad(6), 66)

        let (race, rate, luffed) = try luff(gap: gap, converging: converging, after: after, rudder: 1)
        let outcome = try #require(luffed)
        #expect(rate.firstTick(above: changesCourse) == outcome.tick, "the course change is first seen on the incident's tick")
        #expect(outcome.call.rule == .windwardLeeward && outcome.call.offender == 1 && outcome.call.victim == 0)
        #expect(outcome.exonerated.isEmpty)
        #expect(race.boats[1].penaltyTurnsOwed == 1 && race.boats[0].penaltyTurnsOwed == 0)

        let held = try #require(try luff(gap: gap, converging: converging, after: after, rudder: 0).outcome,
                                "holding her course, the windward boat is swept anyway")
        #expect(held.call.rule == .windwardLeeward && held.call.offender == 1 && held.call.victim == 0)
        #expect(held.tick - outcome.tick == 2, "\(held.tick - outcome.tick) ticks later")
    }

    /// #273: no edge in the timing. The windward boat bears down on the leeward boat, 6° towards her, 1.22 m off,
    /// and the leeward boat luffs hard: after 66 ticks' approach her sweep reaches the windward boat a tick after
    /// her turn first counts as a course change, after 67 on that very tick. Either way the windward boat answers
    /// from the tick the change is first seen, against the leeward boat's held course, and an escape candidate
    /// gets her clear: rule 16.1 on the leeward boat both times, the windward boat exonerated. She did have to
    /// answer: sailing on as she was, the held course sweeps her.
    @Test func sameTickAndOneTickEarlierLuffsGetTheSameCall() throws {
        let changesCourse = try #require(try F.race().rules.incidents.escape.changesCourse)
        let (gap, converging) = (1.22, deg2rad(6))
        for (after, early) in [(66, 1), (67, 0)] {
            let (race, rate, luffed) = try luff(gap: gap, converging: converging, after: after, rudder: 1)
            let outcome = try #require(luffed)
            #expect(rate.firstTick(above: changesCourse) == outcome.tick - early,
                    "after \(after): the course change is first seen \(early) ticks before the incident's")
            #expect(outcome.call.rule == .changingCourse && outcome.call.offender == 0 && outcome.call.victim == 1,
                    "after \(after)")
            #expect(outcome.exonerated == [1])
            #expect(race.boats[0].penaltyTurnsOwed == 1 && race.boats[1].penaltyTurnsOwed == 0)
        }

        let held = try #require(try luff(gap: gap, converging: converging, after: 67, rudder: 0).outcome,
                                "holding her course, the windward boat is swept")
        #expect(held.call.rule == .windwardLeeward && held.call.offender == 1 && held.call.victim == 0)
    }

    /// ADR 0002: the same world and umpire memory, sailed on 100 times, make the same call, the same incident
    /// and the same race, bit for bit: the candidates in the rules' fixed order, the first escape winning, and
    /// the umpire's track filled in seat order.
    @Test func identicalAcross100Replays() throws {
        struct Run: Equatable {
            let outcome: EscapeFixture.Outcome?
            let digest: UInt64
            let incidents: IncidentIndex
            let umpire: UmpireState?
        }
        let tack = try F.race()
        try E.tack(tack, ahead: 1.5, leeward: 1.5)
        let luff = try F.race()
        _ = try E.luff(luff, gap: 0.5, rudder: 1)
        luff.step() // the rudder goes over
        for (race, expected) in [(tack, RacingRule.acquiringRightOfWay), (luff, .changingCourse)] {
            let world = race.exportSnapshot()
            let umpire = race.umpire
            func run() throws -> Run {
                try race.importSnapshot(world)
                race.umpire = umpire
                let outcome = E.sailToCall(race, within: 10 * Race.tickRate)
                return Run(outcome: outcome, digest: race.digest(), incidents: race.incidents, umpire: race.umpire)
            }
            let first = try run()
            #expect(first.outcome?.call.rule == expected && first.outcome?.exonerated.count == 1)
            for replay in 1..<100 {
                let again = try run()
                guard again == first else {
                    Issue.record("\(expected.rawValue): replay \(replay) differs")
                    break
                }
            }
        }
    }
}
