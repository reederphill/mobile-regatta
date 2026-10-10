import Testing
@testable import RegattaCore
@testable import RegattaBots

/// A race for bot tests: `seats` (by default seat 0 human and seven bots) and the wind seed derived
/// from `seed`, as RegattaCoreTests does.
func botRace(seats: [SeatKind] = [.human] + Array(repeating: .bot, count: 7), laps: Int = 2,
             prestartSeconds: Int = 45, seed: UInt64, boatClass: FileRef = BotConductTests.waterClass) -> Race {
    let setup = try! RaceSetup(raceSeed: RaceSeed(seed), seats: seats, laps: laps,
                               startSequenceTicks: prestartSeconds * Race.tickRate, boatClass: boatClass)
    return Race(setup: setup, windSeed: WindSeed(seed &* 0x9E37_79B9_7F4A_7C15 &+ 1))
}

/// Runs a test with the bot tests' race builders (`botRace` and each suite's own, by `BotConductTests.waterClass`)
/// sailing another bundled skiff than the default class.
struct SkiffPin: TestTrait, TestScoping {
    var version: Int

    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        let ref = try BoatClassFile.bundled(id: "skiff", version: version).ref
        try await BotConductTests.$waterClass.withValue(ref) { try await function() }
    }
}

extension Trait where Self == SkiffPin {
    /// skiff@7, the default class from #437 to #461: every boat steers by hand, the autohelm sails the tack/gybe tap,
    /// the rudder's drag is linear and there is a roll tack. A scene fitted to the tap's turn, or one whose bots don't
    /// yet sail it on skiff@8's hand tacks, names it ("until #455": that ticket un-pins it).
    static var onSkiffSeven: Self { SkiffPin(version: 7) }
}

/// The rudder a bot turns a penalty turn with, to `direction` (-1 port, 1 starboard), on the default class:
/// `HandTackTable.penaltyFraction` of full on a class that turns by hand (skiff@8, #459), hard over on an older one.
func penaltyHelm(_ direction: Double = 1) -> BoatInput {
    let byHand = !RaceFiles.defaults.boatClass.content.steering.autohelm.sailsTap
    return BoatInput(rudder: direction * (byHand ? HandTackTable.penaltyFraction : 1))
}

/// Every seat sailed by a bot, as `-demo` sails yours.
func allBots(_ race: Race) -> SeatControllers {
    SeatControllers(race.boats.indices.map { .bot(BotDriver(seat: $0, raceSeed: race.setup.raceSeed)) })
}

/// Drives and steps `race` for `ticks` ticks, or until it's over.
func sail(_ race: Race, _ controllers: inout SeatControllers, ticks: Int, each: (Race) -> Void = { _ in }) {
    for _ in 0..<ticks where !race.isOver {
        controllers.drive(race)
        each(race)
        race.step()
    }
}

@Suite struct BotDriverTests {
    /// #19: bots decide at 10 Hz, so a bot makes a third as many decisions as there are ticks.
    @Test func decisionsPerBotAreTicksOverThree() throws {
        let race = botRace(seed: 5)
        var controllers = allBots(race)
        let ticks = 1_000
        sail(race, &controllers, ticks: ticks)
        #expect(!race.isOver)
        for controller in controllers.seats {
            let driver = try #require(controller.driver)
            #expect(abs(driver.decisions - ticks / 3) <= 1, "seat \(driver.seat) made \(driver.decisions) decisions in \(ticks) ticks")
        }
    }

    /// A decision taken at tick t is applied at t + 1, and the input is held until the next decision.
    @Test func decisionsApplyOnTheNextTickAndAreHeldBetween() throws {
        let race = botRace(seed: 6)
        var controllers = allBots(race)
        sail(race, &controllers, ticks: 900)
        let inputs = try #require(race.log).inputs
        #expect(inputs.count > 100)
        for record in inputs {
            let phase = record.seat % BotDriver.decisionInterval
            #expect((record.tick - 1 + phase).isMultiple(of: 3), "seat \(record.seat) changed input at tick \(record.tick), off its decision ticks")
        }
        // On the default class bots tack and gybe by hand (#459): no tap. (On an older class they tap:
        // `BotHandTackTests.skiffSevenBotsAreBitIdentical` holds those races.)
        #expect(!inputs.contains { if case .tap(.tackGybe) = $0.kind { true } else { false } }, "a bot tapped on a class that turns by hand")
    }

    /// The phase spreads the fleet's decisions over the three ticks.
    @Test func phaseSpreadsDecisionsOverTheThreeTicks() {
        let phases = (0..<6).map { BotDriver(seat: $0, raceSeed: RaceSeed(1)).phase }
        #expect(phases == [0, 1, 2, 0, 1, 2])
        let driver = BotDriver(seat: 1, raceSeed: RaceSeed(1))
        #expect(driver.decides(atTick: -1801) && driver.decides(atTick: 2) && !driver.decides(atTick: 0))
    }

    @Test func botFleetCompletesARace() {
        let race = botRace(seed: 42)
        var controllers = allBots(race)
        sail(race, &controllers, ticks: 1_500 * Race.tickRate)
        let finishers = race.boats.filter { $0.status == .finished }
        #expect(race.isOver)
        #expect(finishers.count >= 5, "finished: \(finishers.map(\.id)), statuses: \(race.boats.map(\.status))")
    }

    /// Bots draw from their own seeds, never the race's: a retuned style moves neither the placement
    /// nor the wind of the same race seed (and needs no simulation version bump, ADR 0002). Over the first 45 s of the
    /// sequence: seat 3's start spot and timing first steer her about 40 s in (#388 times the hull to the line, not
    /// the bow; it was about 22 s after #377's upwash run astern, 20 s was enough before that).
    @Test func changingAStyleLeavesPlacementAndWindUnchanged() throws {
        let a = botRace(seed: 11)
        let b = botRace(seed: 11)
        var tuned = BotDriver(seat: 3, raceSeed: b.setup.raceSeed).style
        tuned.startSpot = tuned.startSpot < 0.5 ? 0.9 : 0.1
        tuned.timingSlack += 4
        var original = SeatControllers(setup: a.setup)
        var retuned = SeatControllers(setup: b.setup)
        retuned[3] = .bot(BotDriver(seat: 3, raceSeed: b.setup.raceSeed, style: tuned))

        #expect(a.boats.map(\.position) == b.boats.map(\.position))
        #expect(a.boats.map(\.heading) == b.boats.map(\.heading))
        for _ in 0..<(45 * Race.tickRate) {
            sail(a, &original, ticks: 1)
            sail(b, &retuned, ticks: 1)
            #expect(a.wind == b.wind)
            #expect(a.windSetup == b.windSetup)
            #expect(a.course.axis == b.course.axis)
            for p in [Vec2.zero] + a.course.obstacles.map(\.position) {
                #expect(try a.wind.sample(p, tick: a.tick) == b.wind.sample(p, tick: b.tick))
            }
        }
        let (logA, logB) = (try #require(a.log), try #require(b.log))
        #expect(logA.inputs.filter { $0.seat == 3 } != logB.inputs.filter { $0.seat == 3 }, "the style changed how seat 3 sailed")
    }

    @Test func botSeedsDifferBySeatAndRaceSeed() {
        let seeds = (0..<16).map { botSeed(raceSeed: RaceSeed(7), seat: $0) }
        #expect(Set(seeds).count == 16)
        #expect(botSeed(raceSeed: RaceSeed(8), seat: 0) != seeds[0])
        #expect(BotDriver(seat: 2, raceSeed: RaceSeed(7)).seed == seeds[2])
        #expect(BotDriver(seat: 2, raceSeed: RaceSeed(7)).style == BotDriver(seat: 2, raceSeed: RaceSeed(7)).style)
    }

    /// Server and device must agree on every bot's seed, so its style and sailing name: pinned, so a
    /// change to `FNV1a` or the seed's inputs can't move them silently. Computed independently of Swift:
    /// FNV-1a 64 over the little-endian bytes of the race seed, the seat, the tag's length, then each tag byte.
    @Test func botSeedKnownAnswers() {
        #expect(botSeed(raceSeed: RaceSeed(7), seat: 0) == 0x749F_ACB9_8825_5498)
        #expect(botSeed(raceSeed: RaceSeed(7), seat: 5) == 0xDFAF_56EF_8D24_77FD)
    }
}

@Suite struct SeatControllerTests {
    @Test func setupSeatsGetBotsAndHumans() {
        let race = botRace(seats: [.human, .bot, .human, .bot], seed: 1)
        let controllers = SeatControllers(setup: race.setup)
        #expect(controllers.seats.map(\.isHuman) == [true, false, true, false])
        #expect(controllers[1].driver?.seat == 1)
    }

    /// A bot takes a dropped player's boat at any tick and hands it back; only then does it send inputs.
    @Test func controllersSwapAtAnyTick() throws {
        let race = botRace(seats: [.human, .bot, .bot], seed: 3)
        var controllers = SeatControllers(setup: race.setup)
        sail(race, &controllers, ticks: 301)
        let dropped = race.tick
        controllers[0] = .dropped(BotDriver(seat: 0, raceSeed: race.setup.raceSeed))
        sail(race, &controllers, ticks: 400)
        let rejoined = race.tick
        controllers[0] = .human
        sail(race, &controllers, ticks: 300)

        let seat0 = try #require(race.log).inputs.filter { $0.seat == 0 }
        #expect(!seat0.isEmpty)
        #expect(seat0.allSatisfy { $0.tick > dropped && $0.tick <= rejoined + 1 })
    }
}

@Suite struct BotReplayTests {
    /// ADR 0002: the log holds the inputs bots applied, so it replays with no brains to the same race.
    @Test func replayingTheAppliedInputLogWithNoBrainsGivesTheSameDigest() throws {
        let race = botRace(seed: 42)
        for seat in race.boats.indices { race.record(.joined(race.setup.seats[seat]), seat: seat) }
        var controllers = SeatControllers(setup: race.setup)
        var rng = SplitMix64(seed: 9)
        var step = 0
        sail(race, &controllers, ticks: Race.tickRate * 200) { race in
            // Seat 0 is a scripted human among the bots.
            if step % 40 == 0 {
                race.apply(BoatInput(rudder: Int8(rng.int(in: -60...60)), ease: step < 300), seat: 0, atTick: race.tick + 1)
            }
            if step == 1300 { race.tap(.protest(target: 3), seat: 0, atTick: race.tick + 1) }
            step += 1
        }
        race.record(.left, seat: 0)

        let log = try #require(race.log)
        #expect(log.inputs.contains { $0.seat == 4 }, "bot inputs are logged")
        let replayed = try Replayer.replay(log)
        #expect(replayed.digest() == race.digest())
        #expect(replayed.log == log)
        // scripts/linux-test.sh counts these lines: RegattaBots built and ran in both configurations.
        print("REGATTABOTS replay digest=\(hex64(race.digest()))")
    }

    /// Bots are predicted like anyone else, on their held inputs (ADR 0005): a race with no bots that
    /// imports a bot race's snapshot and is fed the inputs the bots applied follows it exactly. (From #63's
    /// WorldSnapshotTests, moved here when bots left `Race`.)
    @Test func aBotlessImportFedTheBotsAppliedInputsFollowsTheBotRace() throws {
        let botRace = botRace(seats: [.human] + Array(repeating: .bot, count: 9), prestartSeconds: 30, seed: 63)
        var bots = SeatControllers(setup: botRace.setup)
        sail(botRace, &bots, ticks: 1500)
        _ = botRace.drainEvents()
        let copy = Race(setup: botRace.setup, windSeed: try #require(botRace.windSeed))
        try copy.importSnapshot(botRace.exportSnapshot())
        // The umpire's memory is the authoritative race's own, never in a snapshot (#88): a snapshot continues bit
        // for bit only while no incident is open, and a fleet may have one open at any tick. The copy takes it too,
        // so what it follows the bot race on is the inputs alone.
        copy.umpire = botRace.umpire
        #expect(copy.digest() == botRace.digest())
        for _ in 0..<600 {
            sail(botRace, &bots, ticks: 1)
            for record in try #require(botRace.log).inputs where record.tick == copy.tick + 1 {
                switch record.kind {
                case .held(let input): copy.apply(input, seat: record.seat, atTick: record.tick)
                case .tap(let tap): copy.tap(tap, seat: record.seat, atTick: record.tick)
                }
            }
            copy.step()
            #expect(copy.digest() == botRace.digest())
        }
    }

    /// No exceptions for bots (#19): a scripted seat that sends a bot's applied inputs sails the same boat.
    @Test func scriptedSeatReplayingABotsInputsSailsTheSameBoat() throws {
        let ticks = Race.tickRate * 150
        let botSailed = botRace(seed: 17)
        var bots = SeatControllers(setup: botSailed.setup)
        sail(botSailed, &bots, ticks: ticks)
        let script = try #require(botSailed.log).inputs.filter { $0.seat == 2 }
        #expect(script.count > 50)

        let scripted = botRace(seed: 17)
        var controllers = SeatControllers(setup: scripted.setup)
        controllers[2] = .human
        var next = 0
        sail(scripted, &controllers, ticks: ticks) { race in
            while next < script.count && script[next].tick == race.tick + 1 {
                switch script[next].kind {
                case .held(let input): race.apply(input, seat: 2, atTick: race.tick + 1)
                case .tap(let tap): race.tap(tap, seat: 2, atTick: race.tick + 1)
                }
                next += 1
            }
        }
        #expect(next == script.count)
        #expect(scripted.digest() == botSailed.digest())
        #expect(scripted.boats[2].position == botSailed.boats[2].position)
        #expect(scripted.boats[2].heading == botSailed.boats[2].heading)
    }
}

@Suite struct FleetRosterTests {
    @Test func botsHaveDistinctSailingNamesAndPlayersNone() throws {
        let setup = try RaceSetup(raceSeed: RaceSeed(3), seats: [.human] + Array(repeating: .bot, count: 15))
        let roster = FleetRoster(setup: setup)
        #expect(roster[0] == .init(seat: 0, isBot: false, sailingName: nil))
        let names = roster.entries.dropFirst().compactMap(\.sailingName)
        #expect(names.count == 15)
        #expect(Set(names).count == 15)
        #expect(roster.entries.dropFirst().allSatisfy { $0.isBot })
        #expect(FleetRoster(setup: setup) == roster)
    }

    @Test func namesComeFromTheBotSeed() throws {
        let one = FleetRoster(setup: try RaceSetup(raceSeed: RaceSeed(1), seats: [.human, .bot]))
        let seed = botSeed(raceSeed: RaceSeed(1), seat: 1)
        #expect(one[1].sailingName == FleetRoster.sailingNames[Int(seed % UInt64(FleetRoster.sailingNames.count))])
    }
}

@Suite struct BotPenaltyTurnTests {
    /// The bot's penalty-turn rudder to `direction` (−1 port, 1 starboard), as a held input: hard over on a class whose
    /// tap sails her turns, 70 % of it on the default class (`penaltyHelm`).
    static func hardOver(_ direction: Double) -> Int8 { penaltyHelm(direction).rudder }

    /// Seat 0 at `offset` from the windward mark, 20 s into the sequence, owing a turn with `turned` of it already
    /// turned (60° unless given: her rounding counts towards it) whose clock started `since` seconds ago, and seat 1
    /// at `other` from her (far off unless given): the rudder her brain answers with, given the side she turns
    /// penalties to, and the race.
    func decide(atOffset offset: Vec2, penaltyDirection: Double, since: Double = 0, turned: Double = deg2rad(60),
                other: Vec2? = nil, inOpenWater: Bool = false, skill: Double = 0.8) throws -> (rudder: Int8, race: Race) {
        let race = botRace(seats: [.bot, .bot], seed: 5)
        for _ in 0..<(20 * Race.tickRate) { race.step() }
        var snapshot = race.exportSnapshot()
        // Open water: up the first beat, off to one side, offset ignored.
        let position = inOpenWater ? race.course.startLine.centre + race.course.upwind * 150 + race.course.right * 60
            : race.course.obstacles[CourseLayout.windwardIndex].position + offset
        snapshot.seats[0].boat.position = position
        snapshot.seats[0].boat.status = .racing
        snapshot.seats[0].boat.penaltyTurnsOwed = 1
        snapshot.seats[0].boat.penaltyProgress = turned
        snapshot.seats[0].boat.penaltyClockTick = snapshot.tick - Int(since * Double(Race.tickRate))
        if let other {
            snapshot.seats[1].boat.position = position + other
            snapshot.seats[1].boat.status = .racing
        }
        try race.importSnapshot(snapshot)
        #expect(race.boats[0].isTakingPenalty == (turned > deg2rad(30)))
        var brain = BotBrain(style: BotStyle(skill: skill, startSpot: 0.5, finishSpot: 0.7, timingSlack: 0,
                                             penaltyDirection: penaltyDirection))
        return (brain.decide(race.seatView(for: 0)).input.rudder, race)
    }

    /// The #79 smoke breach: a bot that touched a mark spun hard over beside it on `isTakingPenalty`,
    /// touching it again and owing another turn each time round (up to 15 mark contacts a race). Beside
    /// the mark she sails (the same rudder whichever side she turns penalties to); clear, she turns.
    @Test func aBotOwingATurnBesideAMarkSailsClearBeforeTurning() throws {
        let beside = Vec2(3, -3)
        #expect(try decide(atOffset: beside, penaltyDirection: 1).rudder == decide(atOffset: beside, penaltyDirection: -1).rudder)
        let clear = Vec2(30, -30)
        #expect(try decide(atOffset: clear, penaltyDirection: 1).rudder == Self.hardOver(1))
        #expect(try decide(atOffset: clear, penaltyDirection: -1).rudder == Self.hardOver(-1))
    }

    /// #89, #351: racing in the water she would sail to her next mark while putting her turn off, she starts it at
    /// once whoever is near, away from the nearest boat: put off, it came due beside the mark
    /// (`BotBrain.putOffEndsAtAMark`). (Until she is 30° into it she keeps her rights; from there she keeps clear of
    /// them, rule 21.2: `BotNavigationTests.penaltyTurningBotKeepsClearUnder21_2`.)
    @Test func nearHerNextMarkABotStartsItsTurnAtOnceWhateverBoatsAreNear() throws {
        let clear = Vec2(30, -30), other = Vec2(3, 4)
        for direction in [1.0, -1.0] {
            let (rudder, race) = try decide(atOffset: clear, penaltyDirection: direction, turned: 0, other: other)
            #expect((race.boats[1].position - race.boats[0].position).length == 5)
            let away: Double = other.dot(race.boats[0].forward.rightPerp) > 0 ? -1 : 1
            #expect(rudder == Self.hardOver(away), "hard over away from the boat")
        }
    }

    /// #351: below `penaltyPutOffSkill` (a Club or Regional bot) she starts her turn at once in the pack, her own way,
    /// as before #351.
    @Test func belowNationalSkillABotStartsItsTurnAtOnceInThePack() throws {
        for direction in [1.0, -1.0] {
            let (rudder, _) = try decide(atOffset: .zero, penaltyDirection: direction, turned: 0, other: Vec2(3, 4),
                                         inOpenWater: true, skill: BotBrain.penaltyPutOffSkill - 0.01)
            #expect(rudder == Self.hardOver(direction))
        }
    }

    /// #351: racing in open water (not on the last leg) with a boat within `penaltyBoatClearance`, she puts her turn
    /// off and sails on (the same rudder whichever side she turns penalties to), until `penaltyStartMargin` before the
    /// start deadline; then she turns hard over away from that boat.
    @Test func inOpenWaterABotPutsHerTurnOffInThePackUntilItsDeadline() throws {
        let start = RaceFiles.defaults.rulesConfiguration.content.raceFormat.penalty.start
        let late = start - BotBrain.penaltyStartMargin
        let other = Vec2(3, 4)
        let (rudder, race) = try decide(atOffset: .zero, penaltyDirection: 1, turned: 0, other: other, inOpenWater: true)
        let boat = race.boats[0]
        let windward = race.course.obstacles[CourseLayout.windwardIndex].position
        #expect((windward - boat.position).length > 120, "her next mark is out of reach")
        #expect(try decide(atOffset: .zero, penaltyDirection: -1, turned: 0, other: other, inOpenWater: true).rudder
                == rudder, "she sails on, putting the turn off")
        let away: Double = other.dot(boat.forward.rightPerp) > 0 ? -1 : 1
        for direction in [1.0, -1.0] {
            let due = try decide(atOffset: .zero, penaltyDirection: direction, since: late, turned: 0, other: other,
                                 inOpenWater: true)
            #expect(due.rudder == Self.hardOver(away), "at its deadline, hard over away from the boat")
        }
    }

    /// #89: beside a mark she sails on to get clear of it, but never past her turn's start deadline:
    /// `penaltyStartMargin` before it she turns wherever she is, away from the mark, whichever side she
    /// turns penalties to.
    @Test func besideAMarkABotStillStartsItsTurnBeforeTheStartDeadline() throws {
        let beside = Vec2(3, -3)
        let start = RaceFiles.defaults.rulesConfiguration.content.raceFormat.penalty.start
        let late = start - BotBrain.penaltyStartMargin
        let (rudder, race) = try decide(atOffset: beside, penaltyDirection: 1, since: late)
        #expect(try decide(atOffset: beside, penaltyDirection: -1, since: late).rudder == rudder)
        let boat = race.boats[0]
        let mark = race.course.obstacles[CourseLayout.windwardIndex].position
        let markIsToStarboard = (mark - boat.position).dot(boat.forward.rightPerp) > 0
        #expect(rudder == Self.hardOver(markIsToStarboard ? -1 : 1), "hard over away from the mark")
        // A moment earlier she was still sailing on.
        #expect(try decide(atOffset: beside, penaltyDirection: 1, since: late - 1).rudder
                == decide(atOffset: beside, penaltyDirection: -1, since: late - 1).rudder)
    }

    /// #89: a bot owing two turns in open water serves both inside their deadlines, hard over the same way
    /// from the moment she starts until she owes none: through head to wind and on into the second turn,
    /// never giving one up.
    @Test func aBotServesOwedTurnsHardOverOneWayInsideTheDeadlines() throws {
        let race = botRace(seats: [.bot, .bot], seed: 5)
        var controllers = allBots(race)
        sail(race, &controllers, ticks: race.setup.startSequenceTicks + 60 * Race.tickRate)
        var snapshot = race.exportSnapshot()
        let open = race.course.startLine.centre + race.course.upwind * 150 + race.course.right * 60
        snapshot.seats[0].boat.position = open
        snapshot.seats[0].boat.penaltyTurnsOwed = 2
        snapshot.seats[0].boat.penaltyProgress = 0
        snapshot.seats[0].boat.penaltyClockTick = snapshot.tick
        snapshot.seats[0].boat.queuedPenaltyCallTicks = [snapshot.tick]
        snapshot.seats[0].heldInput = .neutral
        snapshot.seats[1].boat.position = open + race.course.right * 200
        try race.importSnapshot(snapshot)
        _ = race.drainEvents()
        #expect(race.boats[0].status == .racing && race.boats[0].penaltyTurnsOwed == 2)

        var kinds: [RaceEvent.Kind] = []
        var held: Set<Int8> = []
        let complete = RulesConfig.ticks(race.rules.raceFormat.penalty.complete)
        sail(race, &controllers, ticks: 2 * complete) { race in
            kinds += race.drainEvents().map(\.kind)
            let rudder = race.heldInputs[0].rudder
            if race.boats[0].penaltyTurnsOwed > 0 && (!held.isEmpty || abs(rudder) == Self.hardOver(1)) { held.insert(rudder) }
        }
        #expect(kinds.filter { $0 == .penaltyServed(seat: 0) }.count == 2)
        #expect(!kinds.contains(.penaltyReset(seat: 0)))
        #expect(!kinds.contains { if case .disqualified(seat: 0, _) = $0 { true } else { false } })
        #expect(race.boats[0].penaltyTurnsOwed == 0 && race.boats[0].status == .racing)
        #expect(held.count == 1 && held.allSatisfy { abs($0) == Self.hardOver(1) }, "\(held)")
    }
}
