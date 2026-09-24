import Testing
import RegattaCore
@testable import RegattaBots

/// A race for bot tests: `seats` (by default seat 0 human and seven bots) and the wind seed derived
/// from `seed`, as RegattaCoreTests does.
func botRace(seats: [SeatKind] = [.human] + Array(repeating: .bot, count: 7), laps: Int = 2,
             prestartSeconds: Int = 45, seed: UInt64) -> Race {
    let setup = try! RaceSetup(raceSeed: RaceSeed(seed), seats: seats, laps: laps,
                               startSequenceTicks: prestartSeconds * Race.tickRate)
    return Race(setup: setup, windSeed: WindSeed(seed &* 0x9E37_79B9_7F4A_7C15 &+ 1))
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
    @Test func decisionsApplyOnTheNextTickAndAreHeldBetween() {
        let race = botRace(seed: 6)
        var controllers = allBots(race)
        sail(race, &controllers, ticks: 900)
        let inputs = race.log.inputs
        #expect(inputs.count > 100)
        for record in inputs {
            let phase = record.seat % BotDriver.decisionInterval
            #expect((record.tick - 1 + phase).isMultiple(of: 3), "seat \(record.seat) changed input at tick \(record.tick), off its decision ticks")
        }
        #expect(inputs.contains { if case .tap(.tackGybe) = $0.kind { true } else { false } }, "bots tack and gybe with the tap")
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
    /// nor the wind of the same race seed (and needs no simulation version bump, ADR 0002).
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
        for _ in 0..<600 {
            sail(a, &original, ticks: 1)
            sail(b, &retuned, ticks: 1)
            #expect(a.wind == b.wind)
            #expect(a.windSetup == b.windSetup)
            #expect(a.course.axis == b.course.axis)
            for p in [Vec2.zero, a.course.pin, a.course.committee, a.course.marks[0].position] {
                #expect(try a.wind.sample(p, tick: a.tick) == b.wind.sample(p, tick: b.tick))
            }
        }
        #expect(a.log.inputs.filter { $0.seat == 3 } != b.log.inputs.filter { $0.seat == 3 }, "the style changed how seat 3 sailed")
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
    @Test func controllersSwapAtAnyTick() {
        let race = botRace(seats: [.human, .bot, .bot], seed: 3)
        var controllers = SeatControllers(setup: race.setup)
        sail(race, &controllers, ticks: 301)
        let dropped = race.tick
        controllers[0] = .dropped(BotDriver(seat: 0, raceSeed: race.setup.raceSeed))
        sail(race, &controllers, ticks: 400)
        let rejoined = race.tick
        controllers[0] = .human
        sail(race, &controllers, ticks: 300)

        let seat0 = race.log.inputs.filter { $0.seat == 0 }
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

        let log = race.log
        #expect(log.inputs.contains { $0.seat == 4 }, "bot inputs are logged")
        let replayed = try Replayer.replay(log)
        #expect(replayed.digest() == race.digest())
        #expect(replayed.log == log)
        // scripts/linux-test.sh counts these lines: RegattaBots built and ran in both configurations.
        print("REGATTABOTS replay digest=\(hex64(race.digest()))")
    }

    /// No exceptions for bots (#19): a scripted seat that sends a bot's applied inputs sails the same boat.
    @Test func scriptedSeatReplayingABotsInputsSailsTheSameBoat() {
        let ticks = Race.tickRate * 150
        let botSailed = botRace(seed: 17)
        var bots = SeatControllers(setup: botSailed.setup)
        sail(botSailed, &bots, ticks: ticks)
        let script = botSailed.log.inputs.filter { $0.seat == 2 }
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
