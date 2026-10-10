import Foundation
import Testing
import RegattaCore
@testable import RegattaBots

/// #100: a bot sails the course on the autohelm (ADR 0007): she tacks by the tap alone, and the tap exits at the
/// groove; turning a penalty, she keeps clear of every boat (rule 21.2).
@Suite struct BotNavigationTests {
    /// A race with the gun gone, seat 0 a bot beating up the first leg on starboard in the upwind groove at its
    /// speed, the autohelm holding it, `left` metres left of the course axis at a third of the beat; seat 1,
    /// nobody's, far off to the right. Bot or not, seat 0 is driven only by what a test sends it.
    static func beatingRace(seed: UInt64, left: Double) throws -> Race {
        // skiff@6: the tap exiting at the groove is the autohelm (#437); only `tackIsTheTapExitingAtTheGroove` uses this.
        let race = try botRace(seats: [.bot, .human], seed: seed, boatClass: BotHelmTests.autohelmOn().ref)
        for _ in 0..<(race.setup.startSequenceTicks + Race.tickRate) { race.step() }
        let c = race.course
        let lineCentre = (c.startLine.pin.position + c.startLine.committee.position) * 0.5
        let wind = race.seatView(for: 0).own.windSpeed
        let beat = race.boatClass.polar.bestUpwind(tws: wind)
        var snapshot = race.exportSnapshot()
        for seat in 0..<2 {
            snapshot.seats[seat].boat.status = .racing
            snapshot.seats[seat].boat.speed = beat.speed
            snapshot.seats[seat].boat.boomSide = .port
            snapshot.seats[seat].boat.heading = race.seatView(for: seat).own.windDirection - beat.twa
            snapshot.seats[seat].boat.autohelm = Autohelm(target: .groove(.upwind))
            snapshot.seats[seat].boat.rudder = 0
            snapshot.seats[seat].heldInput = .neutral
        }
        snapshot.seats[0].boat.position = lineCentre + c.upwind * (c.beat * 0.3) - c.right * left
        snapshot.seats[1].boat.position = lineCentre + c.upwind * (c.beat * 0.3) + c.right * 150
        try race.importSnapshot(snapshot)
        return race
    }

    /// One tick of seat 0 through a tack, read against the wind (ADR 0007): her sailing angle, her boom, what
    /// the autohelm holds, and the rudder held for her.
    struct Sample {
        let tick: Int
        let sailingAngle: Double
        let boomSide: BoomSide
        let autohelm: Autohelm?
        let heldRudder: Int8
        let position: Vec2
        let heading: Double
        let speed: Double
        /// The sailing wind at her: the direction it blows from, and its speed.
        let windDirection: Double
        let windSpeed: Double
        /// Her groove's sailing angle, as her autohelm reads it now.
        let grooveAngle: Double

        init(_ race: Race) {
            let boat = race.boats[0]
            tick = race.tick
            sailingAngle = boat.sailingAngle
            boomSide = boat.boomSide
            autohelm = boat.autohelm
            heldRudder = race.heldInputs[0].rudder
            position = boat.position
            heading = boat.heading
            speed = boat.speed
            windDirection = boat.windDirection
            windSpeed = boat.polarWindSpeed(in: race.boatClass)
            grooveAngle = Autohelm.grooveAngle(.upwind, tws: boat.grooveWindSpeed(in: race.boatClass), boatClass: race.boatClass)
        }
    }

    /// #100 acceptance (#219: "acceptance on angle traces rather than heading traces"): a bot beating on
    /// starboard, left of her corridor to the windward mark, tacks by herself, and the tack is the tap: nothing
    /// scripts it, she never touches the rudder through it, and the tap exits at the groove. Read as a wind-angle
    /// trace: out of the starboard groove, through head to wind with the boom crossing once, into the port groove
    /// the autohelm holds. Its cost is the physics' own: the same tap sent from the same state, with no bot at
    /// the helm, sails the same track tick for tick, and loses what the class's tap tack does (#244 §6.1: about 8 m).
    @Test func tackIsTheTapExitingAtTheGroove() throws {
        let race = try Self.beatingRace(seed: 5, left: 250)
        let start = race.exportSnapshot()
        // Skill 0.39: a bot that doesn't tack on headers, so the corridor alone turns her, and below the roll's skill
        // floor (#263), so the tack is the tap alone.
        let style = BotStyle(skill: 0.39, startSpot: 0.5, finishSpot: 0.7, timingSlack: 0, penaltyDirection: 1)
        var driver = BotDriver(seat: 0, raceSeed: race.setup.raceSeed, style: style,
                               weaknesses: .none(skill: style.skill)) // the mechanism alone, no misjudged grooves (#102)
        var decisions: [(tick: Int, decision: BotDecision)] = []
        var trace = [Sample(race)]
        for _ in 0..<(20 * Race.tickRate) {
            if let decision = driver.drive(race) { decisions.append((race.tick, decision)) }
            race.step()
            trace.append(Sample(race))
        }

        // She tacked by herself, once, by the tap, and held no rudder from start to end: the autohelm sailed it.
        let taps = decisions.filter { $0.decision.tap != nil }
        #expect(taps.count == 1 && taps.first?.decision.tap == .tackGybe, "\(taps.map(\.decision))")
        #expect(decisions.allSatisfy { $0.decision.input == .neutral }, "\(decisions.filter { $0.decision.input != .neutral })")
        #expect(trace.allSatisfy { $0.heldRudder == 0 })
        let tapTick = try #require(taps.first).tick + 1

        // The wind-angle trace: in the starboard groove until the tap...
        let before = trace.filter { $0.tick < tapTick }
        #expect(!before.isEmpty && before.allSatisfy { $0.boomSide == .port && $0.autohelm?.target == .groove(.upwind) })
        let snap = race.boatClass.steering.autohelm.upwindSnap
        #expect(before.allSatisfy { abs($0.sailingAngle - $0.grooveAngle) < snap }, "\(before.map { rad2deg($0.sailingAngle) })")
        // ...then up through head to wind, the boom crossing once...
        let crossings = zip(trace, trace.dropFirst()).filter { $0.boomSide != $1.boomSide }
        #expect(crossings.count == 1, "the boom crossed \(crossings.count) times")
        let crossing = try #require(crossings.first).1
        let during = trace.filter { $0.tick >= tapTick && $0.tick < crossing.tick }
        #expect(during.allSatisfy { $0.autohelm?.isTapping == true }, "the autohelm sails the tap")
        #expect(during.map(\.sailingAngle).min().map { $0 < deg2rad(5) } == true, "she came up through head to wind")
        // ...and out of it at the groove on port: the autohelm holds the groove, no longer tapping, and her angle
        // settles on it, the tap's exit, with no rudder from her.
        let after = trace.filter { $0.tick >= crossing.tick }
        #expect(after.allSatisfy { $0.boomSide == .starboard && $0.autohelm?.target == .groove(.upwind) && $0.autohelm?.isTapping == false })
        let settled = after.filter { $0.tick >= crossing.tick + 8 * Race.tickRate }
        #expect(!settled.isEmpty && settled.allSatisfy { abs($0.sailingAngle - $0.grooveAngle) < deg2rad(1) },
                "\(settled.map { rad2deg($0.sailingAngle - $0.grooveAngle) })")

        // The physics' own tack: the same state, nobody at the helm, the same tap at the same tick.
        let physics = try botRace(seats: [.bot, .human], seed: 5, boatClass: BotHelmTests.autohelmOn().ref)
        try physics.importSnapshot(start)
        var physicsTrace = [Sample(physics)]
        while physics.tick < race.tick {
            if physics.tick + 1 == tapTick { physics.tap(.tackGybe, seat: 0, atTick: tapTick) }
            physics.step()
            physicsTrace.append(Sample(physics))
        }
        #expect(physicsTrace.count == trace.count)
        for (bot, tap) in zip(trace, physicsTrace) {
            #expect(bot.tick == tap.tick && bot.position == tap.position && bot.heading == tap.heading && bot.speed == tap.speed,
                    "tick \(bot.tick): the bot's tack left the physics' track")
        }

        // What the tack cost: metres made good to windward from the tap until back at speed on port, against
        // holding her entry speed at the groove angle for as long.
        let entry = try #require(trace.last { $0.tick < tapTick })
        let recovered = try #require(after.first { $0.speed >= 0.99 * entry.speed && $0.tick > crossing.tick })
        let seconds = Double(recovered.tick - entry.tick) / Double(Race.tickRate)
        let upwind = Vec2.heading(entry.windDirection)
        let madeGood = (recovered.position - entry.position).dot(upwind)
        let lost = entry.speed * Foundation.cos(entry.sailingAngle) * seconds - madeGood
        // The class's own tap tack loses 0.7–1.3 hull lengths (`SkiffTests.tackCosts0_7To1_3LengthsAt6_10And14Knots`,
        // #263); measured to back at speed rather than over 25 s, and in the race's wind, which shifts under her as she
        // tacks, a little looser.
        let lengths = lost / race.boatClass.hull.length
        #expect(lengths >= 0.5 && lengths <= 1.5, "the tack lost \(lengths) L over \(seconds) s in \(entry.windSpeed) m/s")
    }

    // MARK: - Rule 21.2

    /// Seat 0 in open water after the gun, reaching on starboard, `turned` radians into a penalty turn to
    /// starboard whose clock started now, hard over; seat 1, nobody's, sailing a reach on port `ahead` metres
    /// ahead of her and `across` metres to her starboard, heading back past her (the autohelm holding its angle),
    /// or, with `ahead` nil, far off.
    static func penaltyRace(turned: Double, ahead: Double?, across: Double = 0) throws -> Race {
        let race = botRace(seats: [.bot, .human], seed: 5)
        for _ in 0..<(race.setup.startSequenceTicks + Race.tickRate) { race.step() }
        let c = race.course
        let open = c.startLine.centre + c.upwind * 150 + c.right * 60
        let wind = race.seatView(for: 0).own.windDirection
        let heading = wind - .pi / 2
        var snapshot = race.exportSnapshot()
        for seat in 0..<2 {
            snapshot.seats[seat].boat.status = .racing
            snapshot.seats[seat].boat.speed = 4
        }
        snapshot.seats[0].boat.position = open
        snapshot.seats[0].boat.heading = heading
        snapshot.seats[0].boat.boomSide = .port
        snapshot.seats[0].boat.autohelm = nil
        snapshot.seats[0].boat.rudder = 1
        snapshot.seats[0].heldInput = BoatInput(rudder: 1.0)
        snapshot.seats[0].boat.penaltyTurnsOwed = 1
        snapshot.seats[0].boat.penaltyProgress = turned
        snapshot.seats[0].boat.penaltyClockTick = snapshot.tick
        let forward = Vec2.heading(heading)
        snapshot.seats[1].boat.position = ahead.map { open + forward * $0 + forward.rightPerp * across } ?? open + c.right * 300
        snapshot.seats[1].boat.heading = heading + .pi
        snapshot.seats[1].boat.boomSide = .starboard
        snapshot.seats[1].boat.autohelm = Autohelm(target: .angle(.pi / 2))
        snapshot.seats[1].boat.rudder = 0
        snapshot.seats[1].heldInput = .neutral
        try race.importSnapshot(snapshot)
        _ = race.drainEvents()
        return race
    }

    /// #100, rule 21.2: a boat turning a penalty keeps clear of every boat once she is 30° into her turn, whatever
    /// rules 10–13 would give her (#89 built the turns; this is keeping clear while she turns them). Seat 0, on
    /// starboard and so right of way over seat 1 on port by rule 10, is 60° into her turn when seat 1 comes back
    /// past her on the side she is turning to: she breaks off the turn to keep clear, turning it again the other way,
    /// hard over away from seat 1 (turning back gives the first up), touches nobody and is called for nothing, and
    /// serves it inside its deadlines. With nobody near she holds her turn hard over, as ever.
    @Test func penaltyTurningBotKeepsClearUnder21_2() throws {
        let style = BotStyle(skill: 0.8, startSpot: 0.5, finishSpot: 0.7, timingSlack: 0, penaltyDirection: 1)
        let hardOver = penaltyHelm(1)

        // Nobody near: hard over (her penalty rudder, `penaltyHelm`), her turn's way.
        let alone = try Self.penaltyRace(turned: deg2rad(60), ahead: nil)
        #expect(alone.boats[0].isTakingPenalty)
        var brain = BotBrain(style: style)
        #expect(brain.decide(alone.seatView(for: 0)).input == hardOver)

        // Seat 1 coming back past her, to starboard, where she is turning: clear of her course now, but not of her
        // turn. Held hard over as #89 turned it, she hit seat 1 and was called under 21.2.
        let race = try Self.penaltyRace(turned: deg2rad(60), ahead: 14, across: 7)
        let view = race.seatView(for: 0)
        #expect(race.boats[0].isTakingPenalty && view.others[0].rightOfWay?.keepClear == 1, "rule 10 has seat 1 keep clear")

        var driver = BotDriver(seat: 0, raceSeed: race.setup.raceSeed, style: style)
        var kinds: [RaceEvent.Kind] = []
        var inputs: [BoatInput] = []
        let complete = RulesConfig.ticks(race.rules.raceFormat.penalty.complete)
        for _ in 0..<(complete + Race.tickRate) {
            if let decision = driver.drive(race), race.boats[0].penaltyTurnsOwed > 0 { inputs.append(decision.input) }
            race.step()
            kinds += race.drainEvents().map(\.kind)
        }
        #expect(kinds.contains(.penaltyReset(seat: 0)), "she broke off her turn to keep clear")
        #expect(inputs.first == hardOver && inputs.last == penaltyHelm(-1),
                "she turned it again to port, away from seat 1: \(inputs.map(\.rudder))")
        #expect(!kinds.contains(.contact(SeatPair(0, 1))), "she touched seat 1")
        let calls = kinds.compactMap { if case .ruleCall(let call) = $0 { call } else { nil } }
        #expect(calls.isEmpty, "\(calls.map { "\($0.rule) on \($0.offender)" })")
        #expect(kinds.contains(.penaltyServed(seat: 0)), "she served her turn")
        #expect(!kinds.contains { if case .disqualified = $0 { true } else { false } })
        #expect(race.boats[0].penaltyTurnsOwed == 0 && race.boats[0].status == .racing)
    }

    /// #337 round 3: the boat a penalised boat keeps clear of sees her keep clear (rule 21.2), whatever rules 10–13
    /// would give her, so she holds her course for her as for any boat keeping clear; the penalised boat's own view
    /// keeps rules 10–13 (`penaltyTurningBotKeepsClearUnder21_2`). Read by rules 10–13 alone, the cautious bot, clear
    /// astern of a boat turning a penalty, bore away to keep clear of her onto another penalised boat and was called
    /// under 16.1 (seed 26 of `CautiousBotSuiteTests`). Seat 0, on starboard, 60° into her turn; seat 1 on port.
    @Test func aBoatTurningAPenaltyKeepsClearInTheOtherBoatsView() throws {
        let race = try Self.penaltyRace(turned: deg2rad(60), ahead: 14, across: 7)
        #expect(race.boats[0].isTakingPenalty)
        #expect(race.rightOfWay(0, 1)?.keepClear == 1, "rule 10 alone has seat 1 keep clear")
        #expect(race.seatView(for: 1).others[0].rightOfWay == RightOfWay(keepClear: 0, rule: .takingAPenalty))
        #expect(race.seatView(for: 0).others[0].rightOfWay?.keepClear == 1)
    }

    /// #337 round 4: before her start, a bot gives a boat turning a penalty close aboard berth (`startKeepClear`,
    /// `penalisedBerthLengths`), though it keeps clear of her under rule 21 in her view. Thirty seconds before the gun,
    /// well below the line: seat 0, 60° into her turn, two hull lengths dead ahead of seat 1 (a bot reaching on
    /// starboard, right of way under rule 10 too): seat 1 bears off it. Six lengths ahead, outside the berth, she holds on.
    @Test func beforeTheStartABotGivesABoatTurningAPenaltyBerth() throws {
        func keepClear(ahead lengths: Double) throws -> (Double?, RightOfWay?) {
            let race = botRace(seats: [.human, .bot], seed: 5)
            while race.tick < -30 * Race.tickRate { race.step() }
            let c = race.course
            let length = race.boatClass.hull.length
            let at = c.startLine.centre - c.upwind * 80
            let wind = race.seatView(for: 1).own.windDirection
            let heading = wind - .pi / 2
            let forward = Vec2.heading(heading)
            var snapshot = race.exportSnapshot()
            snapshot.seats[0].boat.position = at + forward * (length * lengths)
            snapshot.seats[0].boat.heading = heading + .pi / 3
            snapshot.seats[0].boat.boomSide = .port
            snapshot.seats[0].boat.speed = 0.5
            snapshot.seats[0].boat.autohelm = nil
            snapshot.seats[0].boat.rudder = 1
            snapshot.seats[0].heldInput = BoatInput(rudder: 1.0)
            snapshot.seats[0].boat.penaltyTurnsOwed = 1
            snapshot.seats[0].boat.penaltyProgress = deg2rad(60)
            snapshot.seats[0].boat.penaltyClockTick = snapshot.tick
            snapshot.seats[1].boat.position = at
            snapshot.seats[1].boat.heading = heading
            snapshot.seats[1].boat.boomSide = .port
            snapshot.seats[1].boat.speed = 4
            snapshot.seats[1].boat.autohelm = Autohelm(target: .angle(.pi / 2))
            snapshot.seats[1].boat.rudder = 0
            snapshot.seats[1].heldInput = .neutral
            snapshot.touchingBoats = []
            try race.importSnapshot(snapshot)
            _ = race.drainEvents()
            #expect(race.boats[0].isTakingPenalty && race.boats[1].status == .prestart && race.tick < 0)
            let view = race.seatView(for: 1)
            let pilot = BotConductTests.Pilot(seat: 1, plannedTack: nil, race: race)
            return (pilot.brain.startKeepClear(view.own, view, desired: heading, lookahead: 3), view.others[0].rightOfWay)
        }
        let (close, right) = try keepClear(ahead: 2)
        #expect(right == RightOfWay(keepClear: 0, rule: .takingAPenalty))
        #expect(close != nil, "two lengths off: she bears off the boat turning her penalty")
        let (far, _) = try keepClear(ahead: 6)
        #expect(far == nil, "six lengths off: she holds on")
    }

    /// #337 review: the suite's hunter hunts no boat keeping clear of her under rule 21 (`quarry`): seat 0, 60° into
    /// her penalty turn, keeps clear of seat 1 in seat 1's view, within range and ahead of her, but is no quarry.
    @Test func theHunterHuntsNoBoatTurningAPenalty() throws {
        let race = try Self.penaltyRace(turned: deg2rad(60), ahead: 14, across: 7)
        let view = race.seatView(for: 1)
        #expect(view.others[0].rightOfWay == RightOfWay(keepClear: 0, rule: .takingAPenalty))
        let hunter = BotConductTests.Pilot(seat: 1, plannedTack: nil, race: race, profile: .hunter)
        #expect(hunter.brain.hasKeepClearBoatInRange(view.own, view), "she is in range")
        #expect(hunter.brain.quarry(view.own, view) == nil)
    }

    /// #337 review: the cautious bot's look before she leaps (`guarded`) reads a boat keeping clear of her under rule 21
    /// as her view does: seat 0, 60° into her penalty turn, passing seat 1 (the cautious bot) seven metres off is no
    /// intrusion, though rules 10–13 on the boats alone would have seat 1 keep clear (port). 10° into it, not yet under
    /// rule 21.2, the same boat is one she keeps clear of.
    @Test func theCautiousLookReadsRule21AsHerViewDoes() throws {
        func guarded(turned: Double) throws -> BoatInput? {
            let race = try Self.penaltyRace(turned: turned, ahead: 14, across: 7)
            let view = race.seatView(for: 1)
            let pilot = BotConductTests.Pilot(seat: 1, plannedTack: nil, race: race, caution: .standard)
            return pilot.brain.guarded(view, .neutral)
        }
        let penalised = try Self.penaltyRace(turned: deg2rad(60), ahead: 14, across: 7)
        #expect(penalised.boats[0].isTakingPenalty && penalised.rightOfWay(0, 1)?.keepClear == 1)
        #expect(try guarded(turned: deg2rad(60)) == nil, "rule 21: seat 0 keeps clear of her")
        let early = try Self.penaltyRace(turned: deg2rad(10), ahead: 14, across: 7)
        #expect(!early.boats[0].isTakingPenalty)
        #expect(try guarded(turned: deg2rad(10)) != nil, "rule 10: she keeps clear of seat 0")
    }

    /// #100's review nit, #101: a penalised bot close to her turn's complete deadline turns on rather than give the turn
    /// up to keep clear (`canGiveUpTurn`: never inside `penaltyCompleteMargin` of it). The encounter of
    /// `penaltyTurningBotKeepsClearUnder21_2`, seat 1 coming back past her on the side she turns to, with the turn's
    /// clock started long enough ago that its complete deadline is 12 s off: she holds her turn hard over, gives nothing
    /// up, and serves it inside the deadline. With the deadline far off she gives it up, as ever.
    /// skiff@7 until #455: on skiff@8 her turn at 70 % rudder doesn't finish inside the 12 s this scene leaves her, and
    /// she is disqualified.
    @Test(.onSkiffSeven) func penaltyTurnNearItsDeadlineIsNotGivenUp() throws {
        let style = BotStyle(skill: 0.8, startSpot: 0.5, finishSpot: 0.7, timingSlack: 0, penaltyDirection: 1)
        let hardOver = BoatInput(rudder: 1.0)
        func sail(completeIn seconds: Double) throws -> (kinds: [RaceEvent.Kind], inputs: [BoatInput], race: Race) {
            let race = try Self.penaltyRace(turned: deg2rad(60), ahead: 14, across: 7)
            let complete = race.rules.raceFormat.penalty.complete
            var snapshot = race.exportSnapshot()
            snapshot.seats[0].boat.penaltyClockTick = snapshot.tick - RulesConfig.ticks(complete - seconds)
            try race.importSnapshot(snapshot)
            _ = race.drainEvents()
            let owed = try #require(race.owedPenalty(ofSeat: 0))
            #expect(owed.isStarted && owed.completeDeadlineTick - race.tick == RulesConfig.ticks(seconds))
            var driver = BotDriver(seat: 0, raceSeed: race.setup.raceSeed, style: style)
            var kinds: [RaceEvent.Kind] = []
            var inputs: [BoatInput] = []
            for _ in 0..<RulesConfig.ticks(seconds + 1) {
                let owing = race.boats[0].penaltyTurnsOwed > 0 && !kinds.contains(.penaltyServed(seat: 0))
                if let decision = driver.drive(race), owing { inputs.append(decision.input) }
                race.step()
                kinds += race.drainEvents().map(\.kind)
            }
            return (kinds, inputs, race)
        }

        let late = try sail(completeIn: 12)
        #expect(BotBrain.penaltyCompleteMargin > 12)
        #expect(!late.kinds.contains(.penaltyReset(seat: 0)), "she gave her turn up with 12 s to its deadline")
        #expect(!late.inputs.isEmpty && late.inputs.allSatisfy { $0 == hardOver }, "\(late.inputs.map(\.rudder))")
        #expect(late.kinds.contains(.penaltyServed(seat: 0)), "she served her turn")
        #expect(!late.kinds.contains { if case .disqualified = $0 { true } else { false } })

        let early = try sail(completeIn: 30)
        #expect(early.kinds.contains(.penaltyReset(seat: 0)), "with 30 s to go she gives it up to keep clear")
    }
}
