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
    @Test(.onFiveRules) func penaltyTurningBotKeepsClearUnder21_2() throws {
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
    /// she is disqualified. Tried again after #471's step C: the same (a turn by hand from 60° in takes her over 12 s,
    /// and she is called 21.2 on the way).
    @Test(.onFiveRules, .onSkiffSeven) func penaltyTurnNearItsDeadlineIsNotGivenUp() throws {
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

    // MARK: - The windward mark's final approach (#508)

    /// Seat 0 posed on the windward mark's final approach, and a bot for her helm.
    struct FinalApproach {
        let race: Race
        var brain: BotBrain
        /// Metres a boat's close-hauled board must leave the mark to port (`windwardFinalAim`'s room).
        let room: Double
        var view: SeatView { race.seatView(for: 0) }

        /// Metres the starboard close-hauled board from `position`, in her wind and by her groove, leaves the mark to
        /// port, more than `room`: the reckoning the brain makes, made again here.
        func over(from position: Vec2) -> Double {
            let view = view
            let mark = view.course.elements[CourseLayout.windwardIndex].marks[0]
            let board = Vec2.heading(view.own.windDirection - brain.grooveAngle(.upwind, view.own, view))
            return -(mark.position - position).dot(board.rightPerp) - room
        }

        /// Where the tack onto starboard leaves her (`BotBrain.tackAdvanceSeconds`).
        var exit: Vec2 {
            let own = view.own
            return own.position + Vec2.heading(own.windDirection) * (max(own.speed, 1) * BotBrain.tackAdvanceSeconds)
        }
    }

    /// Seat 0 beating to the windward mark on `tack` in her groove at `speedShare` of her speed, `along` metres short
    /// of the mark down the starboard close-hauled board that passes it `over` metres clear of its room: her own board
    /// on starboard; on port, the board from where her tack would leave her. Seat 1 far off. Her bot is the baseline,
    /// judging its laylines true, the cautious bot with `caution`; `edit` the snapshot further.
    static func finalApproach(tack: Tack, over: Double, along: Double = 40, seed: UInt64 = 3, speedShare: Double = 1,
                              caution: BotBrain.Caution? = nil,
                              edit: @escaping (inout WorldSnapshot) -> Void = { _ in }) throws -> FinalApproach {
        let water = BotConductTests.Water(seed: seed)
        let course = water.race.course
        let mark = course.elements[CourseLayout.windwardIndex].marks[0]
        let room = mark.radius + water.race.boatClass.hull.beam + BotBrain.markClearance + BotBrain.layMargin
        var brain = BotBrain(style: BotConductTests.skill1, profile: .baseline, seed: 1, caution: caution)
        brain.tactics.headerThreshold = nil
        brain.tactics.corridor = 100
        brain.plannedTack = tack
        brain.laylineError = (water.leg, 0)
        let speed = water.up.speed * speedShare
        var wind = water.race.groundWind(at: mark.position).direction
        var groove = water.up.twa
        var posed: FinalApproach?
        // The wind bends over the water, so she is placed by the wind where she is: thrice over, to the centimetre.
        for _ in 0..<3 {
            let board = Vec2.heading(wind - groove)
            var position = mark.position - board * along + board.rightPerp * (room + over)
            if tack == .port { position = position - Vec2.heading(wind) * (max(speed, 1) * BotBrain.tackAdvanceSeconds) }
            let heading = tack == .starboard ? wind - groove : wind + groove
            let race = try BotConductTests.place(water, [
                .init(position: position, heading: heading, speed: speed),
                .init(position: mark.position - course.upwind * 300 + course.right * 150, heading: water.beat(.starboard),
                      speed: water.up.speed),
            ], edit: edit)
            let approach = FinalApproach(race: race, brain: brain, room: room)
            let own = approach.view.own
            wind = own.windDirection
            groove = brain.grooveAngle(.upwind, own, approach.view)
            posed = approach
        }
        let approach = try #require(posed)
        let own = approach.view.own
        try #require(own.tack == tack)
        try #require(abs(approach.over(from: tack == .starboard ? own.position : approach.exit) - over) < 0.2)
        return approach
    }

    /// #508 acceptance: on the final approach a starboard boat whose close-hauled board no longer clears the windward
    /// mark by its room tacks away to port (before #508 nothing inside `tacticalRange` did, and she passed the mark on
    /// its wrong side, #464); one whose board clears it holds her board; one well overstood is the beat's to reach in.
    @Test func starboardBoardThatCannotLayTheWindwardMarkTacksAway() throws {
        // Her board runs 3 m inside the mark's room: at the mark itself.
        var short = try Self.finalApproach(tack: .starboard, over: -3)
        var view = short.view
        var decides = short.brain
        #expect(short.brain.windwardFinalAim(view.own, view)?.tack == .port)
        #expect(short.brain.plannedTack == .port)
        // And so she plans at the helm: the final approach is asked before the beat's corridor.
        _ = decides.decide(view)
        #expect(decides.plannedTack == .port)

        var laying = try Self.finalApproach(tack: .starboard, over: 1)
        view = laying.view
        decides = laying.brain
        let held = laying.brain.windwardFinalAim(view.own, view)
        let aim = try #require(held)
        #expect(aim.tack == .starboard && abs(aim.angle - laying.brain.grooveAngle(.upwind, view.own, view)) < 1e-9)
        #expect(laying.brain.plannedTack == .starboard)
        _ = decides.decide(view)
        #expect(decides.plannedTack == .starboard)

        // Past the fetch point and `overstandReach` more, it is no longer the final approach's: the beat reaches her in.
        let reach = BotBrain.layBoardMargin + BotBrain.overstandReach + BotBrain.windwardFetchOffset
        var overstood = try Self.finalApproach(tack: .starboard, over: reach + 2)
        view = overstood.view
        #expect(overstood.brain.windwardFinalAim(view.own, view) == nil)
        var justUnder = try Self.finalApproach(tack: .starboard, over: reach - 2)
        view = justUnder.view
        #expect(justUnder.brain.windwardFinalAim(view.own, view)?.tack == .starboard)
    }

    /// #508 acceptance: on port she tacks onto starboard only once the board from where her tack leaves her clears the
    /// mark by `layBoardMargin` more than its room; a board that would only just clear it, or not at all, she holds
    /// port for.
    @Test func portApproachTacksOntoStarboardOnlyWhenTheBoardClearsTheMark() throws {
        var clears = try Self.finalApproach(tack: .port, over: BotBrain.layBoardMargin + 1)
        var view = clears.view
        var decides = clears.brain
        #expect(clears.brain.windwardFinalAim(view.own, view)?.tack == .starboard)
        #expect(clears.brain.plannedTack == .starboard)
        _ = decides.decide(view)
        #expect(decides.plannedTack == .starboard)

        // Clear of the mark's room, but not by the margin a hand tack's exit needs.
        var bare = try Self.finalApproach(tack: .port, over: BotBrain.layBoardMargin - 1)
        view = bare.view
        decides = bare.brain
        #expect(bare.brain.windwardFinalAim(view.own, view)?.tack == .port)
        #expect(bare.brain.plannedTack == .port)
        _ = decides.decide(view)
        #expect(decides.plannedTack == .port)

        var short = try Self.finalApproach(tack: .port, over: -4)
        view = short.view
        #expect(short.brain.windwardFinalAim(view.own, view)?.tack == .port)
        #expect(short.brain.plannedTack == .port)
    }

    /// #508 acceptance: a small header on the final approach leaves her board be. A starboard board headed to half a
    /// metre under the mark's room (at 40 m, a header of under a degree from a board that just cleared it) is inside
    /// `dropBoardMargin`'s slack and she holds it; headed to 2 m under, she tacks away.
    @Test func smallHeaderOnTheFinalApproachLeavesHerBoardBe() throws {
        var headed = try Self.finalApproach(tack: .starboard, over: -0.5)
        var view = headed.view
        #expect(headed.brain.windwardFinalAim(view.own, view)?.tack == .starboard)
        #expect(headed.brain.plannedTack == .starboard)

        var gone = try Self.finalApproach(tack: .starboard, over: -2)
        view = gone.view
        #expect(gone.brain.windwardFinalAim(view.own, view)?.tack == .port)
        #expect(BotBrain.dropBoardMargin == 1)
    }

    /// #508 acceptance: the final approach is hers only below the windward mark, between `finalTackRange` and
    /// `finalApproachRange` of it, beating to it and yet to round it.
    @Test func finalApproachAppliesBelowTheMarkBetweenItsRanges() throws {
        /// Whether a starboard boat whose board no longer lays the mark is the final approach's to tack away.
        func applies(along: Double, edit: @escaping (inout WorldSnapshot) -> Void = { _ in }) throws -> Bool {
            var approach = try Self.finalApproach(tack: .starboard, over: -3, along: along, edit: edit)
            let view = approach.view
            let mark = view.course.elements[CourseLayout.windwardIndex].marks[0]
            let distance = (mark.position - view.own.position).length
            try #require(abs(distance - along) < 1, "\(distance) m from the mark, not \(along)")
            return approach.brain.windwardFinalAim(view.own, view) != nil
        }
        #expect(BotBrain.finalApproachRange == 60 && BotBrain.finalTackRange == 14)
        #expect(try !applies(along: 63))
        #expect(try applies(along: 57))
        #expect(try applies(along: 40))
        #expect(try applies(along: 17))
        #expect(try !applies(along: 11))
        // Round the mark's first stage, or on another leg within its range, it is not her approach.
        #expect(try !applies(along: 40) { $0.seats[0].boat.roundingStage = 1 })
        #expect(try !applies(along: 40) { $0.seats[0].boat.legIndex = 1 })
        #expect(try !applies(along: 40) { $0.seats[0].boat.status = .prestart })

        // Above the mark the beat's own recovery sails her back down.
        var above = try Self.finalApproach(tack: .starboard, over: -3)
        var snapshot = above.race.exportSnapshot()
        let below = snapshot.seats[0].boat.position
        let upwind = above.race.course.upwind
        let windward = above.race.course.elements[CourseLayout.windwardIndex].marks[0]
        snapshot.seats[0].boat.position = below - upwind * (2 * (below - windward.position).dot(upwind))
        try above.race.importSnapshot(snapshot)
        let view = above.view
        let mark = view.course.elements[CourseLayout.windwardIndex].marks[0]
        try #require((view.own.position - mark.position).dot(view.course.upwind) > 10)
        #expect(above.brain.windwardFinalAim(view.own, view) == nil)
    }

    /// #508 acceptance: the cautious bot (#104) sails the final approach as every bot does: she tacks away from a
    /// board that cannot lay the mark, holds one that does, and comes onto starboard from port when the board clears.
    @Test func cautiousBotSailsTheFinalApproach() throws {
        var short = try Self.finalApproach(tack: .starboard, over: -3, caution: .standard)
        var view = short.view
        var decides = short.brain
        try #require(short.brain.caution != nil)
        #expect(short.brain.windwardFinalAim(view.own, view)?.tack == .port)
        _ = decides.decide(view)
        #expect(decides.plannedTack == .port)

        var laying = try Self.finalApproach(tack: .starboard, over: 1, caution: .standard)
        view = laying.view
        #expect(laying.brain.windwardFinalAim(view.own, view)?.tack == .starboard)

        var clears = try Self.finalApproach(tack: .port, over: BotBrain.layBoardMargin + 1, caution: .standard)
        view = clears.view
        decides = clears.brain
        #expect(clears.brain.windwardFinalAim(view.own, view)?.tack == .starboard)
        _ = decides.decide(view)
        #expect(decides.plannedTack == .starboard)
    }

    // MARK: - A turn refused near her mark (#509)

    /// Seat 0 posed on the reach to the offset mark with the mark on the other side of the wind, and a bot for her helm.
    struct RefusedTurn {
        let race: Race
        var brain: BotBrain
        let mark: Vec2
        var view: SeatView { race.seatView(for: 0) }

        /// Her aim at the mark itself: what `navigate` makes of it, noting how near she is (`isNearHerMark`).
        mutating func aim() -> Aim {
            let view = view
            return brain.navigate(view.own, to: mark, view)
        }
    }

    /// Seat 0 on the offset mark's leg on starboard, `metres` from the offset mark, which bears `reach` radians off the
    /// wind on its port side: hers only after a tack or gybe. She sails halfway between that reach mirrored onto
    /// starboard and the end of her own tack's range that points nearest the mark (her upwind groove when she `luffs`
    /// for it, her downwind one when not), so the two ask for opposite rudder; at `speedShare` of her close-hauled
    /// speed. Seat 1 far off, or as `other` places her from seat 0's pose. The baseline bot on the water's class.
    static func refusedTurn(reach: Double, luffs: Bool, metres: Double = 40, speedShare: Double = 1, seed: UInt64 = 3,
                            other: ((BotConductTests.Placement, BotConductTests.Water) -> BotConductTests.Placement)? = nil,
                            edit: @escaping (inout WorldSnapshot) -> Void = { _ in }) throws -> RefusedTurn {
        let water = BotConductTests.Water(seed: seed)
        let course = water.race.course
        let mark = course.elements[CourseLayout.offsetIndex].marks[0].position
        var brain = BotBrain(style: BotConductTests.skill1, profile: .baseline, seed: 1)
        brain.tactics.headerThreshold = nil
        brain.tactics.downwindShiftThreshold = nil
        brain.tactics.corridor = 100
        brain.laylineError = (1, 0)
        var wind = water.race.groundWind(at: mark).direction
        var up = water.up.twa
        var down = water.down.twa
        var posed: RefusedTurn?
        // The wind bends over the water, so she is placed by the wind where she is, as `finalApproach` is.
        for _ in 0..<3 {
            let position = mark - Vec2.heading(wind + reach) * metres
            let own = BotConductTests.Placement(position: position, heading: wind - (reach + (luffs ? up : down)) / 2,
                                                speed: water.up.speed * speedShare, legIndex: 1)
            let far = BotConductTests.Placement(position: mark - course.upwind * 300 + course.right * 150,
                                                heading: water.beat(.starboard), speed: water.up.speed)
            let race = try BotConductTests.place(water, [own, other?(own, water) ?? far]) { snapshot in
                snapshot.seats[0].boat.penaltyTurnsOwed = 0
                snapshot.seats[0].boat.penaltyProgress = 0
                snapshot.seats[0].boat.penaltyClockTick = nil
                edit(&snapshot)
            }
            let turn = RefusedTurn(race: race, brain: brain, mark: mark)
            let view = turn.view
            wind = view.own.windDirection
            up = brain.grooveAngle(.upwind, view.own, view)
            down = brain.grooveAngle(.downwind, view.own, view)
            posed = turn
        }
        let turn = try #require(posed)
        try #require(turn.view.own.tack == .starboard)
        return turn
    }

    /// #509 acceptance: refused the tack or gybe onto a reach back at her mark within `PlaningTable.markRange` of it,
    /// she holds the end of her own tack's range that points nearest the mark (her upwind groove for a close reach, her
    /// downwind one for a broad one) rather than the reach mirrored onto her tack, which sailed her away from it
    /// (#464: 143 of 276 tail roundings); whatever refused it, by hand and by the tap.
    @Test func refusedTurnNearHerMarkReachesBackTowardsIt() throws {
        let classes = [("by hand, skiff@8", BotHandTackTests.skiffEight.ref), ("by the tap, skiff@6", try BotHelmTests.autohelmOn().ref)]
        for (name, boatClass) in classes {
            try BotConductTests.$waterClass.withValue(boatClass) {
                // A close reach back at it (65° off the wind) is nearest through the wind; a broad one, through dead downwind.
                for (reach, luffs) in [(deg2rad(65), true), (deg2rad(125), false)] {
                    let label = "\(name), mark \(Int(rad2deg(reach).rounded()))° off the wind"
                    var turn = try Self.refusedTurn(reach: reach, luffs: luffs)
                    let view = turn.view
                    let own = view.own
                    let aim = turn.aim()
                    try #require(aim.tack == .port && aim.groove == nil && turn.brain.isNearHerMark, "\(label): \(aim)")
                    try #require(abs(aim.angle - reach) < deg2rad(1), "\(label)")
                    let up = turn.brain.grooveAngle(.upwind, own, view)
                    let down = turn.brain.grooveAngle(.downwind, own, view)

                    let held = try #require(turn.brain.refusedTurnAim(aim, own, view), "\(label)")
                    #expect(held.tack == own.tack && held.groove == nil && held.tolerance == aim.tolerance, "\(label)")
                    #expect(held.angle == (luffs ? up : down), "\(label): holds \(rad2deg(held.angle))°")
                    // Nearer the mark's bearing than the mirror, and than her tack's other end.
                    let bearing = aim.heading(wind: own.windDirection)
                    func off(_ angle: Double) -> Double { abs(wrapAngle(own.windDirection - angle - bearing)) }
                    #expect(off(held.angle) < off(aim.angle) - deg2rad(5), "\(label): \(rad2deg(off(held.angle)))° off against the mirror's \(rad2deg(off(aim.angle)))°")
                    #expect(off(held.angle) <= off(luffs ? down : up), "\(label)")

                    // Posed between the two, the hold and the mirror ask for opposite rudder.
                    let towards = wrapAngle(held.heading(wind: own.windDirection) - own.heading)
                    let mirrored = wrapAngle(own.windDirection - aim.angle - own.heading)
                    try #require(towards * mirrored < 0 && abs(towards) > deg2rad(3), "\(label)")

                    // Free to turn, she turns for the mark.
                    var free = turn.brain
                    let turned = free.decide(view)
                    #expect(turned.tap == .tackGybe || free.handTurn != nil, "\(label): free to turn she did not, groove \(rad2deg(up))° to \(rad2deg(down))°, \(turned.input)")

                    // A turn just made (`tapInterval`).
                    var waiting = turn.brain
                    waiting.lastTapTime = view.time
                    try #require(!waiting.canTap(own, view, byHand: BotBrain.turnsByHand(view)), "\(label)")
                    let decision = waiting.decide(view)
                    #expect(decision.tap == nil && waiting.handTurn == nil, "\(label)")
                    #expect(decision.input.rudderValue * towards > 0,
                            "\(label): rudder \(decision.input.rudderValue), the hold is \(rad2deg(towards))° off her bow")

                    // A boat where the turn would take her (`tapIsClear`): refused, and the hold is the same.
                    var crossed = try Self.refusedTurn(reach: reach, luffs: luffs, other: { own, water in
                        let after = 2 * water.wind - own.heading
                        return .init(position: own.position + Vec2.heading(after) * (water.length * 2), heading: own.heading,
                                     speed: 0, legIndex: 1)
                    })
                    let crossing = crossed.view
                    let reaching = crossed.aim()
                    #expect(!crossed.brain.tapIsClear(crossing.own, crossing), "\(label)")
                    #expect(!crossed.brain.canTap(crossing.own, crossing, byHand: BotBrain.turnsByHand(crossing)), "\(label)")
                    #expect(crossed.brain.refusedTurnAim(reaching, crossing.own, crossing)?.angle == held.angle, "\(label)")

                    // Too slow to tack: half her close-hauled speed.
                    guard luffs else { continue }
                    var slow = try Self.refusedTurn(reach: reach, luffs: luffs, speedShare: 0.5)
                    let slowView = slow.view
                    let slowAim = slow.aim()
                    try #require(!slow.brain.canTap(slowView.own, slowView, byHand: BotBrain.turnsByHand(slowView)), "\(label)")
                    let slowHeld = try #require(slow.brain.refusedTurnAim(slowAim, slowView.own, slowView), "\(label)")
                    let slowDecision = slow.brain.decide(slowView)
                    #expect(slowDecision.tap == nil && slow.brain.handTurn == nil, "\(label)")
                    #expect(slowDecision.input.rudderValue * wrapAngle(slowHeld.heading(wind: slowView.own.windDirection) - slowView.own.heading) > 0,
                            "\(label): slow, rudder \(slowDecision.input.rudderValue)")
                }
            }
        }
    }

    /// #509: held on her downwind end, the hold is a downwind aim like any other and keeps the planing floor
    /// (`downwindAim`, `floorAim`): on skiff@9, on the plane but slow for her angle just round a mark, she is held no
    /// deeper than keeps her planing, not on the bare groove; off the plane, where there is no floor to keep, the groove.
    @Test func refusedTurnHeldDownwindKeepsThePlaningFloor() throws {
        try BotConductTests.$waterClass.withValue(BotPlaningTests.skiffNine.ref) {
            var floored = 0
            for seed in UInt64(1)...6 {
                var turn = try Self.refusedTurn(reach: deg2rad(125), luffs: false, speedShare: 0.6, seed: seed)
                turn.brain.senses.planing = true
                let view = turn.view
                let own = view.own
                let aim = turn.aim()
                try #require(aim.tack == .port && aim.groove == nil && turn.brain.isNearHerMark, "seed \(seed): \(aim)")
                let down = turn.brain.grooveAngle(.downwind, own, view)
                let kept = turn.brain.floorAim(own, view, aim: Aim(angle: down, tack: own.tack, tolerance: aim.tolerance, ease: aim.ease))
                let held = try #require(turn.brain.refusedTurnAim(aim, own, view), "seed \(seed)")
                #expect(held.tack == own.tack && held.angle == kept.angle,
                        "seed \(seed): holds \(rad2deg(held.angle))°, the floor is \(rad2deg(kept.angle))° and her groove \(rad2deg(down))°")
                if held.angle < down - deg2rad(1) { floored += 1 }

                turn.brain.senses.planing = false
                let off = turn.aim()
                #expect(turn.brain.refusedTurnAim(off, own, view)?.angle == down, "seed \(seed): off the plane")
            }
            #expect(floored >= 3, "held above her groove in \(floored) waters of 6")
        }
    }

    /// #509: away from her marks, and where `isNearHerMark` is no mark of her course (before her start, returning to
    /// it, on the finish leg), a refused turn is sailed as before, the plan's angle on her own tack; and a refused tack
    /// on the beat is her own groove, near her mark too.
    @Test func refusedTurnAwayFromMarksStillSailsHerGroove() throws {
        let classes = [("by hand, skiff@8", BotHandTackTests.skiffEight.ref), ("by the tap, skiff@6", try BotHelmTests.autohelmOn().ref)]
        for (name, boatClass) in classes {
            try BotConductTests.$waterClass.withValue(boatClass) {
                // 90 m out: the same reach, the same refusals, the mirror.
                for speedShare in [1, 0.5] {
                    var far = try Self.refusedTurn(reach: deg2rad(55), luffs: true, metres: 90, speedShare: speedShare)
                    let view = far.view
                    let aim = far.aim()
                    try #require(aim.tack == .port && aim.groove == nil && !far.brain.isNearHerMark, "\(name)")
                    far.brain.lastTapTime = view.time
                    #expect(far.brain.refusedTurnAim(aim, view.own, view) == nil, "\(name), 90 m out at \(speedShare)")
                }

                // Near a point that is no mark of her course.
                let finishLeg = try #require(BotConductTests.Water(seed: 3).race.course.legs.lastIndex { if case .finish = $0 { true } else { false } })
                let elsewhere: [(String, (inout WorldSnapshot) -> Void)] = [
                    ("before her start", { $0.seats[0].boat.status = .prestart }),
                    ("returning to her start", { $0.seats[0].boat.status = .ocs }),
                    ("on the finish leg", { $0.seats[0].boat.legIndex = finishLeg }),
                ]
                for (place, pose) in elsewhere {
                    var near = try Self.refusedTurn(reach: deg2rad(55), luffs: true, edit: pose)
                    let view = near.view
                    let aim = near.aim()
                    try #require(aim.tack == .port && aim.groove == nil && near.brain.isNearHerMark, "\(name) \(place)")
                    #expect(near.brain.refusedTurnAim(aim, view.own, view) == nil, "\(name) \(place)")
                }

                // Near her mark: a groove on the other tack is her own groove, and an aim on her own tack is hers.
                var near = try Self.refusedTurn(reach: deg2rad(55), luffs: true)
                let nearView = near.view
                let reach = near.aim()
                try #require(near.brain.refusedTurnAim(reach, nearView.own, nearView) != nil)
                for groove in [Autohelm.Groove.upwind, .downwind] {
                    let other = Aim.groove(groove, tack: .port, angle: near.brain.grooveAngle(groove, nearView.own, nearView))
                    #expect(near.brain.refusedTurnAim(other, nearView.own, nearView) == nil, "\(name) \(groove)")
                }
                #expect(near.brain.refusedTurnAim(Aim(angle: reach.angle, tack: .starboard), nearView.own, nearView) == nil, "\(name)")

                // At the helm: on port on the windward mark's final approach, too slow for the tack her plan wants, she
                // steers her own tack's upwind groove.
                let beat = try Self.finalApproach(tack: .port, over: 4, speedShare: 0.5)
                let view = beat.view
                var brain = beat.brain
                let decision = brain.decide(view)
                #expect(brain.plannedTack == .starboard && brain.isNearHerMark && decision.tap == nil && brain.handTurn == nil, "\(name)")
                let groove = Aim.groove(.upwind, tack: .port, angle: brain.grooveAngle(.upwind, view.own, view))
                #expect(decision.input == brain.helm(view.own, to: groove, view), "\(name): \(decision.input)")
                // Off her groove she steers back to it, not on to anything else.
                let footed = try Self.finalApproach(tack: .port, over: 4, speedShare: 0.5) {
                    $0.seats[0].boat.heading += deg2rad(8)
                    $0.seats[0].boat.autohelm = Autohelm(target: .angle(beat.view.own.relativeWind.magnitude + deg2rad(8)))
                }
                let footedView = footed.view
                brain = footed.brain
                let luffing = brain.decide(footedView)
                #expect(brain.plannedTack == .starboard && luffing.tap == nil && brain.handTurn == nil, "\(name)")
                // On port a luff turns her to port: rudder negative.
                #expect(luffing.input.rudderValue < 0, "\(name): footed 8°, rudder \(luffing.input.rudderValue)")
            }
        }
    }
}
