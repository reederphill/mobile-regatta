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
                snapshot.seats[0].boat.penaltyClockTick = snapshot.tick
            }
        }
        let starting = try Self.call(offWind: .pi / 2, edit: penalised(progress: deg2rad(20)))
        #expect(starting?.rule == .windwardLeeward && starting?.offender == 1)
        let turning = try Self.call(offWind: .pi / 2, edit: penalised(progress: deg2rad(45)))
        #expect(turning?.rule == .takingAPenalty && turning?.offender == 0 && turning?.victim == 1)
    }

    /// Under a `tackAndGybe` penalty (#487, fleet-rules@6), 21.2 binds her from the turn's first counting crossing
    /// until it is served: owing a turn with no crossing made she keeps her rights; with its first crossing made she
    /// keeps clear; between owed turns (one served, its way kept for the next, no crossing yet) she keeps her rights
    /// again. `Boat.isTakingPenalty` reads the state, whatever the race's rules.
    @Test func takingAPenaltyFromTheFirstCrossingUntilServed() throws {
        func penalised(direction: Int, first: PenaltyCrossing?, locked: Bool = false) -> (inout WorldSnapshot) -> Void {
            { snapshot in
                snapshot.seats[0].boat.penaltyTurnsOwed = 1
                snapshot.seats[0].boat.penaltyClockTick = snapshot.tick
                snapshot.seats[0].boat.penaltyDirection = direction
                snapshot.seats[0].boat.penaltyFirstCrossing = first
                snapshot.seats[0].boat.penaltyDirectionLocked = locked
            }
        }
        let owing = try Self.call(offWind: .pi / 2, edit: penalised(direction: 0, first: nil))
        #expect(owing?.rule == .windwardLeeward && owing?.offender == 1)
        for first in PenaltyCrossing.allCases {
            let crossed = try Self.call(offWind: .pi / 2, edit: penalised(direction: -1, first: first))
            #expect(crossed?.rule == .takingAPenalty && crossed?.offender == 0 && crossed?.victim == 1, "\(first)")
        }
        let between = try Self.call(offWind: .pi / 2, edit: penalised(direction: 1, first: nil, locked: true))
        #expect(between?.rule == .windwardLeeward && between?.offender == 1)
    }

    // MARK: - Rule 16.1 towards a boat taking a penalty (#517)

    /// Seat 1's hand tack towards seat 0, who is taking a penalty (#517), sailed to a call.
    struct TackAtPenaltyBoat {
        let race: Race
        /// The tick seat 1's rudder goes over, and the tick her tack was complete by (nil if not yet at the call).
        let tackTick: Int
        let completedTick: Int?
        /// The first tick seat 0 was taking a penalty (rule 21.2 began to bind her), if she was by the call.
        let penaltyTick: Int?
        let outcome: EscapeFixture.Outcome?
    }

    /// Seat 0 mid-beat in irons, 3° off the wind on starboard and stopped, a touch of rudder towards the wind holding
    /// her there: under any helm she is still within a metre of there five seconds on. She owes a turn, its tack made
    /// (`crossed`, so rule 21.2 binds her and no later tack ends that), or not yet (rule 21.2 doesn't bind her). Seat
    /// 1 close-hauled on port, `below` metres down the course from her and `toPort` metres to port of the wind's axis
    /// through her, on a course that passes clear to leeward of her. After 5.5 s she puts her helm hard down for 88
    /// ticks, a hand tack onto starboard, then lets go (`tacking`; without it she holds her course). `crossingAfter`
    /// ticks after the helm goes down (before it, if negative), seat 0 puts hers hard over and crosses head to wind
    /// about two seconds later: the first crossing of her turn, if she had made none.
    ///
    /// For another turn than that tack, seat 1 starts `offWind` radians from the wind's axis (on port; on starboard
    /// if negative) at `speed`, and her rudder is `helm` for `helmDown` ticks. Left alone for longer than those five
    /// seconds, seat 0 falls off and sails slowly on, still taking her penalty. `watch` reads the race after each step.
    static func tackAtPenaltyBoat(rules: RulesConfigFile, below: Double, toPort: Double, crossed: Bool = true,
                                  crossingAfter: Int? = nil, tacking: Bool = true, offWind: Double = deg2rad(45),
                                  speed: Double = 2.9, helm: Double = -1, helmDown: Int = 88,
                                  watch: (Race) -> Void = { _ in }) throws -> TackAtPenaltyBoat {
        let race = try F.race(rules: rules)
        let at = F.midBeat(race)
        let lead = 11 * Race.tickRate / 2
        try jump(race, to: 300) { snapshot in
            for seat in 0..<2 {
                var boat = snapshot.seats[seat].boat
                placeRacing(&boat, leg: 0, at: at)
                boat.rudder = 0
                boat.desiredRudder = 0
                boat.autohelm = nil
                boat.isTacking = false
                boat.penaltyTurnsOwed = 0
                boat.penaltyProgress = 0
                boat.penaltyClockTick = nil
                boat.queuedPenaltyCallTicks = []
                if seat == 0 {
                    boat.boomSide = .port
                    boat.heading = F.starboard(race, offWind: deg2rad(3))
                    boat.speed = 0
                    boat.penaltyTurnsOwed = 1
                    boat.penaltyClockTick = snapshot.tick
                    boat.penaltyDirection = crossed ? -1 : 0
                    boat.penaltyFirstCrossing = crossed ? .tack : nil
                } else {
                    boat.position = at - race.course.upwind * below - race.course.upwind.rightPerp * toPort
                    boat.boomSide = offWind > 0 ? .starboard : .port
                    boat.heading = wrapAngle(race.course.axis + offWind)
                    boat.speed = speed
                }
                snapshot.seats[seat].boat = boat
                snapshot.seats[seat].heldInput = seat == 0 ? BoatInput(rudder: Int8(8)) : .neutral
            }
            snapshot.touchingBoats = []
            snapshot.overlaps = []
        }
        let tackTick = race.tick + lead
        if tacking {
            _ = race.apply(BoatInput(rudder: helm), seat: 1, atTick: tackTick)
            _ = race.apply(.neutral, seat: 1, atTick: tackTick + helmDown)
        }
        if let crossingAfter { _ = race.apply(BoatInput(rudder: 1.0), seat: 0, atTick: tackTick + crossingAfter) }
        var completed: Int?, penalty: Int?
        let outcome = EscapeFixture.sailToCall(race, within: 20 * Race.tickRate) { race in
            if completed == nil, race.tick > tackTick, race.boats[1].boomSide == .port, !race.boats[1].isTacking {
                completed = race.tick
            }
            if penalty == nil, race.boats[0].isTakingPenalty { penalty = race.tick }
            watch(race)
        }
        return TackAtPenaltyBoat(race: race, tackTick: tackTick, completedTick: completed, penaltyTick: penalty,
                                 outcome: outcome)
    }

    static func fleetRules(_ version: Int) throws -> RulesConfigFile { try .bundled(id: "fleet-rules", version: version) }

    /// The owner's incident (#517): a boat tacks by hand into a boat taking a penalty, stalled in irons, and hits her
    /// two and a half seconds into the tack, still tacking. The stalled boat was well clear when she began her
    /// penalty (rule 44.2, Case 149): held, the tacker's course before the tack passed clear of her. Rule 16.1 on the
    /// tacker, the boat taking the penalty exonerated: she owes no second turn. On fleet-rules@6 the 16.1 test looks
    /// only the 2 s horizon back, to the tacker's mid-tack heading, and rule 21.2 stands (`rules6CallsReplayUnchanged`).
    @Test func tackIntoABoatTakingAPenaltyIsRule16OnTheTacker() throws {
        let scene = try Self.tackAtPenaltyBoat(rules: Self.fleetRules(7), below: 19, toPort: 8.75)
        let (race, outcome) = (scene.race, try #require(scene.outcome))
        #expect(outcome.contact)
        #expect(outcome.tick - scene.tackTick > RulesConfig.ticks(race.rules.incidents.escape.horizon),
                "the tack began more than the horizon before the contact")
        #expect(scene.completedTick == nil && race.boats[1].isTacking, "still tacking")
        #expect(outcome.call.rule == .changingCourse && outcome.call.offender == 1 && outcome.call.victim == 0)
        #expect(outcome.exonerated == [0])
        #expect(race.boats[0].penaltyTurnsOwed == 1 && race.boats[1].penaltyTurnsOwed == 1)
    }

    /// The tack made further off: the tacker completes it and sails on for more than three seconds, straight at the
    /// boat taking a penalty, and hits her. Her turn is within the look-back, and her course before it passed clear:
    /// rule 16.1 on the tacker still, the boat taking the penalty exonerated. On fleet-rules@6 the tack is out of
    /// sight by then, and rule 21.2 stands.
    @Test func tackFinishedThenSailedIntoABoatTakingAPenaltyIsRule16OnTheTacker() throws {
        let scene = try Self.tackAtPenaltyBoat(rules: Self.fleetRules(7), below: 21, toPort: 5.5)
        let (race, outcome) = (scene.race, try #require(scene.outcome))
        let escape = race.rules.incidents.escape
        let completed = try #require(scene.completedTick)
        #expect(outcome.contact)
        #expect(outcome.tick - completed > RulesConfig.ticks(escape.horizon), "the tack was over more than the horizon before")
        #expect(outcome.tick - scene.tackTick < RulesConfig.ticks(try #require(escape.penaltyLookBack)), "within the look-back")
        #expect(outcome.call.rule == .changingCourse && outcome.call.offender == 1 && outcome.call.victim == 0)
        #expect(outcome.exonerated == [0])
        #expect(race.boats[0].penaltyTurnsOwed == 1 && race.boats[1].penaltyTurnsOwed == 1)

        let before = try #require(try Self.tackAtPenaltyBoat(rules: Self.fleetRules(6), below: 21, toPort: 5.5).outcome)
        #expect(before.tick == outcome.tick && before.contact)
        #expect(before.call.rule == .takingAPenalty && before.call.offender == 0 && before.exonerated.isEmpty)
    }

    /// No tack: the other boat holds her close-hauled course, and the stalled boat makes the first crossing of her
    /// turn in its path, a little over two seconds before they touch. She wasn't well clear when she began her
    /// penalty, and the other boat never turned: rule 21.2 on her, no one exonerated, and she owes a second turn.
    @Test func penaltyTurnBegunInThePathOfAHeldCourseStaysRule21() throws {
        let scene = try Self.tackAtPenaltyBoat(rules: Self.fleetRules(7), below: 13, toPort: 12, crossed: false,
                                               crossingAfter: -150, tacking: false)
        let (race, outcome) = (scene.race, try #require(scene.outcome))
        let began = try #require(scene.penaltyTick)
        #expect(began > 301 && outcome.tick - began > RulesConfig.ticks(race.rules.incidents.escape.horizon),
                "rule 21.2 began to bind on the recorded track, more than the horizon before the contact")
        #expect(outcome.contact)
        #expect(!race.boats[1].isTacking && race.boats[1].boomSide == .starboard, "the other boat held her course")
        #expect(outcome.call.rule == .takingAPenalty && outcome.call.offender == 0 && outcome.call.victim == 1)
        #expect(outcome.exonerated.isEmpty)
        #expect(race.boats[0].penaltyTurnsOwed == 2 && race.boats[1].penaltyTurnsOwed == 0)
    }

    /// The owner's incident again, but the stalled boat makes the first crossing of her turn half a second into the
    /// other boat's tack: the tack was under way when rule 21.2 began to bind her, so she wasn't well clear when she
    /// began her penalty. Rule 21.2 on her, no one exonerated. Had she made that crossing half a second before the
    /// tack instead, she was well clear, and the tack is the tacker's: rule 16.1.
    @Test func penaltyBegunWithABoatAlreadyTurningAtHerStaysRule21() throws {
        let scene = try Self.tackAtPenaltyBoat(rules: Self.fleetRules(7), below: 19, toPort: 8.75, crossed: false,
                                               crossingAfter: -60)
        let (race, outcome) = (scene.race, try #require(scene.outcome))
        let began = try #require(scene.penaltyTick)
        #expect(began > scene.tackTick && began < scene.tackTick + Race.tickRate, "the penalty began during the tack")
        #expect(outcome.contact)
        #expect(outcome.call.rule == .takingAPenalty && outcome.call.offender == 0 && outcome.call.victim == 1)
        #expect(outcome.exonerated.isEmpty)
        #expect(race.boats[0].penaltyTurnsOwed == 2 && race.boats[1].penaltyTurnsOwed == 0)

        let earlier = try Self.tackAtPenaltyBoat(rules: Self.fleetRules(7), below: 19, toPort: 8.75, crossed: false,
                                                 crossingAfter: -80)
        let clear = try #require(earlier.outcome)
        let first = try #require(earlier.penaltyTick)
        #expect(first < earlier.tackTick && first > earlier.tackTick - Race.tickRate, "the penalty began before the tack")
        #expect(clear.contact)
        #expect(clear.call.rule == .changingCourse && clear.call.offender == 1 && clear.exonerated == [0])
    }

    /// The other boat puts her helm hard down and keeps it there: she tacks, bears away, gybes and comes round into
    /// the boat taking a penalty (sailing slowly by then) more than nine seconds after her helm went down, turning
    /// all the while. Her turn is still running at the look-back's far end, so the course she held before it is out of
    /// sight: rule 21.2 stands, as it does for a turn wholly beyond the look-back, though the course she was on 8 s
    /// back would have passed clear.
    @Test func turnLongerThanTheLookBackStaysRule21() throws {
        let turned = TurnRates()
        let scene = try Self.tackAtPenaltyBoat(rules: Self.fleetRules(7), below: 2.5, toPort: 12.5, helmDown: 400,
                                               watch: turned.watch)
        let (race, outcome) = (scene.race, try #require(scene.outcome))
        let escape = race.rules.incidents.escape
        let lookBack = RulesConfig.ticks(try #require(escape.penaltyLookBack))
        #expect(outcome.contact)
        #expect(outcome.tick - scene.tackTick > lookBack + Race.tickRate, "her helm went down before the look-back")
        #expect(turned.slowest(over: (outcome.tick - lookBack)...outcome.tick) > (try #require(escape.changesCourse)),
                "turning on every tick of the look-back")
        #expect(outcome.call.rule == .takingAPenalty && outcome.call.offender == 0 && outcome.call.victim == 1)
        #expect(outcome.exonerated.isEmpty)
        #expect(race.boats[0].penaltyTurnsOwed == 2 && race.boats[1].penaltyTurnsOwed == 0)
    }

    /// A gybe: the other boat comes down on a broad reach on starboard, bearing away 9° a second, slower than a
    /// course change (`changesCourse`), gybes onto port, and goes on round into the boat taking a penalty (sailing
    /// slowly by then), 3.7 s after her boom crossed. Her turn is found by the boom crossing alone, and the course
    /// she held into the gybe passed clear: rule 16.1 on the gyber, the boat taking the penalty exonerated. On
    /// fleet-rules@6 she never changed course, and rule 21.2 stands.
    @Test func gybeIntoABoatTakingAPenaltyIsRule16OnTheGyber() throws {
        func scene(_ version: Int, watch: @escaping (Race) -> Void = { _ in }) throws -> TackAtPenaltyBoat {
            try Self.tackAtPenaltyBoat(rules: Self.fleetRules(version), below: -48, toPort: 3.5, offWind: deg2rad(-150),
                                       speed: 3, helm: -0.3, helmDown: 400, watch: watch)
        }
        let turned = TurnRates()
        var gybed: Int?
        let gybe = try scene(7) { race in
            turned.watch(race)
            if gybed == nil, race.boats[1].boomSide == .starboard { gybed = race.tick }
        }
        let (race, outcome) = (gybe.race, try #require(gybe.outcome))
        let escape = race.rules.incidents.escape
        let lookBack = RulesConfig.ticks(try #require(escape.penaltyLookBack))
        let boomCrossed = try #require(gybed)
        #expect(outcome.contact)
        #expect(outcome.tick - boomCrossed > RulesConfig.ticks(escape.horizon) && outcome.tick - boomCrossed < lookBack,
                "the gybe was more than the horizon before the contact, within the look-back")
        #expect(turned.fastest(over: (outcome.tick - lookBack)...outcome.tick) < (try #require(escape.changesCourse)),
                "never a course change by her turn rate")
        #expect(!race.boats[1].isTacking)
        #expect(outcome.call.rule == .changingCourse && outcome.call.offender == 1 && outcome.call.victim == 0)
        #expect(outcome.exonerated == [0])
        #expect(race.boats[0].penaltyTurnsOwed == 1 && race.boats[1].penaltyTurnsOwed == 1)

        let before = try #require(try scene(6).outcome)
        #expect(before.tick == outcome.tick && before.contact)
        #expect(before.call.rule == .takingAPenalty && before.call.offender == 0 && before.exonerated.isEmpty)
    }

    /// Seat 1's turn rate through the step to each tick, radians a second, as `watch` saw it.
    final class TurnRates {
        private var heading: Double?
        private var rates: [Int: Double] = [:]

        func watch(_ race: Race) {
            let now = race.boats[1].heading
            if let heading { rates[race.tick] = abs(wrapAngle(now - heading)) * Double(Race.tickRate) }
            heading = now
        }

        func slowest(over ticks: ClosedRange<Int>) -> Double { ticks.map { rates[$0] ?? 0 }.min() ?? 0 }
        func fastest(over ticks: ClosedRange<Int>) -> Double { ticks.map { rates[$0] ?? .infinity }.max() ?? .infinity }
    }

    /// The same tack on fleet-rules@6 is called as it was before #517: rule 21.2 on the boat taking the penalty on
    /// tick 539, 74 ticks into the tack, at the contact, no one exonerated, and she owes a second turn. The values
    /// were checked against main's simulation at 2f3107b (this test run on its sources).
    @Test func rules6CallsReplayUnchanged() throws {
        let scene = try Self.tackAtPenaltyBoat(rules: Self.fleetRules(6), below: 19, toPort: 8.75)
        let (race, outcome) = (scene.race, try #require(scene.outcome))
        #expect(race.rules.incidents.escape.penaltyLookBack == nil)
        #expect(outcome.tick == 539 && outcome.tick - scene.tackTick == 74 && outcome.contact)
        #expect(outcome.call.rule == .takingAPenalty && outcome.call.offender == 0 && outcome.call.victim == 1)
        #expect(outcome.exonerated.isEmpty)
        #expect(race.boats[0].penaltyTurnsOwed == 2 && race.boats[1].penaltyTurnsOwed == 0)
        #expect(race.umpire?.track(0, 1)?.count == 62, "the umpire records the 62 ticks it did")
    }
}
