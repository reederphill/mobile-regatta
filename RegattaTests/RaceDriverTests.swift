import Foundation
import Testing
import RegattaBots
import RegattaCore
@testable import Regatta

@MainActor @Suite struct InterpolationTests {
    /// Halfway from −179° to 179° is ±180°, the short way round, not 0°.
    @Test func headingInterpolatesAcrossTheWrap() {
        let heading = Interpolation.angle(from: deg2rad(-179), to: deg2rad(179), 0.5)
        #expect(abs(abs(heading) - .pi) < 1e-9, "got \(rad2deg(heading))°")
        let other = Interpolation.angle(from: deg2rad(179), to: deg2rad(-179), 0.5)
        #expect(abs(abs(other) - .pi) < 1e-9, "got \(rad2deg(other))°")
    }

    @Test func headingInterpolatesTheShortWayRound() {
        let heading = Interpolation.angle(from: deg2rad(170), to: deg2rad(-170), 0.25)
        #expect(abs(rad2deg(heading) - 175) < 1e-9)
        #expect(abs(Interpolation.angle(from: deg2rad(10), to: deg2rad(30), 0.5) - deg2rad(20)) < 1e-12)
    }

    @Test func positionInterpolatesLinearly() {
        let p = Interpolation.position(from: Vec2(0, 0), to: Vec2(10, -4), 0.25)
        #expect(p == Vec2(2.5, -1))
    }

    /// The world is drawn between the last two ticks: position lerped, heading wrapped, the rest the latest tick's.
    @Test func renderWorldDrawsBetweenTheLastTwoTicks() {
        let driver = PracticeDriver(config: RaceDriverTests.config)
        driver.tick(1.5 / Double(Race.tickRate))
        let world = driver.renderWorld
        #expect(abs(driver.alpha - 0.5) < 1e-6)
        for (i, boat) in world.boats.enumerated() {
            let before = driver.previousFrame.boats[i], after = driver.currentFrame.boats[i]
            let midpoint = (before.position + after.position) * 0.5
            #expect((boat.position - midpoint).length < 1e-6)
            #expect(boat.status == after.status)
        }
        #expect(abs(world.time - (driver.previousFrame.time + driver.currentFrame.time) / 2) < 1e-6)
    }

    /// #230: the scene reads what each boat's autohelm holds (the angle or the groove, and how far off the
    /// groove) from the render world, for the vane (#122).
    @Test func renderWorldReadsEachSeatsAutohelm() {
        let driver = PracticeDriver(config: RaceDriverTests.config)
        driver.tick(2 / Double(Race.tickRate))
        let world = driver.renderWorld
        for seat in world.boats.indices {
            #expect(world.autohelm(ofSeat: seat) == world.boats[seat].autohelmReading(in: world.boatClass))
        }
        #expect(world.autohelm(ofSeat: driver.myBoatIndex) != nil, "your rudder is centred: the autohelm holds her")
    }

    /// #248: the scene reads each boat's planing and spinnaker from the render world, the latest tick's,
    /// for the wake and spray (#117, #121) and the spinnaker (#120).
    @Test func renderWorldReadsEachSeatsSails() {
        let driver = PracticeDriver(config: RaceDriverTests.config)
        driver.tick(2 / Double(Race.tickRate))
        let world = driver.renderWorld
        #expect(world.boatClass.planing != nil && world.boatClass.spinnaker != nil, "races sail the skiff")
        for seat in world.boats.indices {
            let latest = driver.currentFrame.boats[seat]
            #expect(world.sails(ofSeat: seat) == SailState(isPlaning: latest.isPlaning, spinnaker: latest.spinnaker,
                                                         isSpinnakerCollapsed: latest.isSpinnakerCollapsed(in: world.boatClass)))
        }
        // Every state reaches the scene from the latest tick, whatever the tick before had.
        let latest = driver.currentFrame
        var boats = latest.boats
        boats[1].isPlaning = true
        boats[1].spinnaker = .hoisting(remaining: 2.5)
        boats[2].spinnaker = .up
        boats[2].boomSide = .port
        boats[2].heading = wrapAngle(boats[2].windDirection + .pi - deg2rad(15)) // 15° by the lee: collapsed
        boats[3].spinnaker = .dropping(remaining: 1)
        let edited = TickFrame(tick: latest.tick, boats: boats, standings: latest.standings, wind: latest.wind, isOver: latest.isOver)
        let drawn = RenderWorld(course: world.course, boatClass: world.boatClass, myBoatIndex: driver.myBoatIndex,
                                previous: driver.previousFrame, current: edited, alpha: 0.5)
        #expect(drawn.sails(ofSeat: 1) == SailState(isPlaning: true, spinnaker: .hoisting(remaining: 2.5), isSpinnakerCollapsed: false))
        #expect(drawn.sails(ofSeat: 2).spinnaker == .up && drawn.sails(ofSeat: 2).isSpinnakerCollapsed)
        #expect(drawn.sails(ofSeat: 3).spinnaker == .dropping(remaining: 1))
    }
}

/// #117: a boat's pose reads her held ease and whether she is a ghost from the render world, the latest tick's.
@MainActor @Suite struct RenderWorldPoseInputTests {
    /// Your held ease reaches the tick frame (`Race.heldInputs`) and the render world's `ease(ofSeat:)`, every
    /// seat's as the race holds it (the bots ease in the prestart, #99), and a frame extrapolated a tick back (#68)
    /// keeps it.
    @Test func heldEaseReachesTheRenderWorld() {
        let driver = PracticeDriver(config: RaceDriverTests.config)
        let me = driver.myBoatIndex
        driver.submit(BoatInput(rudder: 0 as Int8, ease: true))
        driver.tick(3 / Double(Race.tickRate))
        let frame = driver.currentFrame
        #expect(frame.heldInputs.count == frame.boats.count)
        #expect(frame.heldInputs[me].ease)
        let world = driver.renderWorld
        for seat in world.boats.indices {
            #expect(world.ease(ofSeat: seat) == frame.heldInputs[seat].ease, "seat \(seat)")
        }
        let back = frame.extrapolatedBackOneTick()
        #expect(back.heldInputs == frame.heldInputs)
        let drawn = RenderWorld(course: world.course, boatClass: world.boatClass, myBoatIndex: me,
                                previous: back, current: back, alpha: 1)
        #expect(drawn.ease(ofSeat: me))
        // The five-argument frame holds every seat neutral; a seat past the inputs never eases.
        let neutral = TickFrame(tick: frame.tick, boats: frame.boats, standings: frame.standings, wind: frame.wind,
                                isOver: frame.isOver)
        #expect(neutral.heldInputs == Array(repeating: .neutral, count: frame.boats.count))
        #expect(!world.ease(ofSeat: frame.boats.count))

        driver.submit(.neutral)
        driver.tick(3 / Double(Race.tickRate))
        #expect(!driver.renderWorld.ease(ofSeat: me))
    }

    /// A ghost as `Race.isGhost(seat:)` has it: finished or DSQ at once, and an OCS boat or one that never started
    /// only once the race is over (#30, #86).
    @Test func ghostsIncludeOCSAndPrestartOnceOver() {
        let driver = PracticeDriver(config: RaceDriverTests.config)
        let latest = driver.currentFrame
        var boats = latest.boats
        boats[0].status = .racing
        boats[1].status = .ocs
        boats[2].status = .prestart
        boats[3].status = .finished
        func world(isOver: Bool) -> RenderWorld {
            let frame = TickFrame(tick: latest.tick, boats: boats, standings: latest.standings, wind: latest.wind,
                                  isOver: isOver)
            return RenderWorld(course: driver.course, boatClass: driver.boatClass, myBoatIndex: driver.myBoatIndex,
                               previous: frame, current: frame, alpha: 1)
        }
        let racing = world(isOver: false), over = world(isOver: true)
        #expect((0..<4).map { racing.isGhost(ofSeat: $0) } == [false, false, false, true])
        #expect((0..<4).map { over.isGhost(ofSeat: $0) } == [false, true, true, true])
        boats[0].status = .dsq
        #expect(world(isOver: false).isGhost(ofSeat: 0))
    }
}

/// #79 (#15): the HUD's wind readouts show the wind over the ground, not the wind she sails in.
@MainActor @Suite struct HUDWindTests {
    @Test func windReadoutsShowTheWindOverTheGround() {
        let driver = PracticeDriver(config: RaceDriverTests.config)
        let frame = driver.currentFrame
        let me = driver.myBoatIndex
        var boats = frame.boats
        boats[me].windOverGround = Wind(direction: deg2rad(20), speed: 5)
        boats[me].sailingWind = Wind(direction: deg2rad(-10), speed: 3)
        boats[me].apparentWind = Wind(direction: deg2rad(-40), speed: 4)
        // Another boat's shadow doesn't reach the readout (#15): you read it from the wakes.
        boats[me].shadow = 0.6
        let moved = TickFrame(tick: frame.tick, boats: boats, standings: frame.standings, wind: frame.wind, isOver: frame.isOver)
        let world = RenderWorld(course: driver.course, boatClass: driver.boatClass, myBoatIndex: me,
                                previous: moved, current: moved, alpha: 1)
        let hud = HUDState(world: world)
        #expect(abs(hud.windDirection - deg2rad(20)) < 1e-12)
        #expect(abs(hud.windKnots - knots(metresPerSecond: 5)) < 1e-9)
        // Her wind angle is the one she sails at: the sailing wind's.
        #expect(abs(hud.twaDegrees - rad2deg(boats[me].twa)) < 1e-9)
    }
}

@MainActor @Suite struct TickClockTests {
    /// Ticks run for `seconds` of real time at `fps`.
    private func ticks(fps: Int, seconds: Int, timescale: Double = 1) -> Int {
        let driver = PracticeDriver(config: RaceDriverTests.config, timescale: timescale)
        let start = driver.currentFrame.tick
        var returned = 0
        for _ in 0..<(fps * seconds) { returned += driver.tick(1 / Double(fps)).count }
        #expect(returned == driver.currentFrame.tick - start, "every tick run comes back as a frame")
        return driver.currentFrame.tick - start
    }

    @Test(arguments: [60, 120])
    func stepsThirtyTicksPerSimulatedSecond(fps: Int) {
        #expect(ticks(fps: fps, seconds: 1) == 30)
        #expect(ticks(fps: fps, seconds: 5) == 150)
    }

    @Test(arguments: [60, 120])
    func timescaleRunsTheSimulationFaster(fps: Int) {
        #expect(ticks(fps: fps, seconds: 2, timescale: 4) == 240)
    }

    /// Every frame between two ticks runs none; the one that reaches a tick runs exactly one.
    @Test func sixtyHertzRunsATickEveryOtherFrame() {
        var clock = TickClock()
        let perFrame = (0..<8).map { _ in clock.advance(by: 1.0 / 60) }
        #expect(perFrame == [0, 1, 0, 1, 0, 1, 0, 1])
    }

    @Test func aLongFrameRunsSeveralTicksNeverALongerOne() {
        var clock = TickClock()
        #expect(clock.advance(by: 0.1) == 3)
        #expect(clock.advance(by: 0) == 0)
        #expect(clock.advance(by: -1) == 0)
    }

    /// A spent budget still runs one tick, and the ticks it skipped are dropped, not owed to the next frame.
    @Test func aSpentBudgetRunsOneTickAndDropsTheRest() {
        let driver = PracticeDriver(config: RaceDriverTests.config, timescale: 8)
        let start = driver.currentFrame.tick
        #expect(driver.tick(0.1, within: .zero).count == 1, "0.1 s at 8× owes 24 ticks")
        #expect(driver.tick(1.0 / 240, within: .zero).count == 1, "one tick's worth runs one tick, no backlog")
        #expect(driver.currentFrame.tick == start + 2)
        #expect(driver.tick(0.1, within: .seconds(60)).count == 24, "a budget that isn't spent runs them all")
    }

    /// The budget only changes when ticks run: the race it sails is the same, tick for tick. A spent
    /// budget runs one tick a frame, so the budgeted race takes a frame per tick to get as far.
    @Test func aBudgetSailsTheSameRace() {
        let unbudgeted = PracticeDriver(config: RaceDriverTests.config, timescale: 8)
        let budgeted = PracticeDriver(config: RaceDriverTests.config, timescale: 8)
        for _ in 0..<10 { unbudgeted.tick(0.1) }
        let ticks = unbudgeted.currentFrame.tick - budgeted.currentFrame.tick
        #expect(ticks == 240, "10 frames of 0.1 s at 8× are 240 ticks")
        for _ in 0..<ticks { budgeted.tick(0.1, within: .zero) }
        #expect(budgeted.currentFrame.tick == unbudgeted.currentFrame.tick)
        #expect(budgeted.digest() == unbudgeted.digest())
    }
}

@MainActor @Suite struct PracticeDriverTests {
    /// A bot in both seats, one lap: cheap enough to sail headless to the close on the main actor in a Debug build.
    static let headlessRace = RaceConfig(opponents: 1, laps: 1, prestartSeconds: 30, seed: 7,
                                         windSeed: RaceConfig.windSeed(pinnedTo: 7), botSailsYourBoat: true)

    /// A bot sails every seat (`-demo`), so the race runs headless to its finish; its log replays to the same world.
    /// Kept small, since the suite holds the main actor and a Debug tick is slow (in CI the 8-boat, 3-lap race of
    /// #377 took ~250 s before its replay and timed the app's other tests out): `headlessRace`, one opponent, one lap,
    /// a 30 s sequence. Seed 7: your bot finishes at tick 6,000 and the race closes at 7,450 (with the ribbon wake,
    /// #377), well inside the finish window, so she doesn't hang on a seed where she's still racing at the close.
    @Test func runsHeadlessToTheFinishAndReplaysToTheSameDigest() throws {
        let config = Self.headlessRace
        let driver = PracticeDriver(config: config)
        var seconds = 0
        while !driver.currentFrame.isOver && seconds < 1_500 {
            driver.tick(1)
            seconds += 1
        }
        #expect(driver.currentFrame.isOver)
        #expect(driver.currentFrame.boats[driver.myBoatIndex].status == .finished)
        #expect(driver.drainEvents().contains { if case .raceClosed = $0.kind { true } else { false } })

        let log = driver.log
        #expect(log.inputs.contains { $0.seat == driver.myBoatIndex }, "the bot's inputs went through the input API")
        let replayed = try Replayer.replay(log)
        #expect(replayed.tick == driver.currentFrame.tick)
        #expect(replayed.digest() == driver.digest())
    }

    /// Once the race is over the clock stops: display frames run no ticks and the drawn world stays at the
    /// last tick, so the fleet doesn't wobble between the last two ticks behind the results.
    /// Sails `headlessRace` to its close.
    @Test func aFinishedRaceStandsStill() {
        let config = Self.headlessRace
        let driver = PracticeDriver(config: config)
        var seconds = 0
        while !driver.currentFrame.isOver && seconds < 1_500 {
            driver.tick(1)
            seconds += 1
        }
        #expect(driver.currentFrame.isOver)
        let finalTick = driver.currentFrame.tick
        let world = driver.renderWorld
        #expect(driver.alpha == 1)
        #expect(zip(world.boats, driver.currentFrame.boats).allSatisfy { $0.position == $1.position && $0.heading == $1.heading },
                "drawn at the last tick")

        for frame in 0..<600 {
            #expect(driver.tick(1.0 / 60).isEmpty, "frame \(frame) ran a tick")
            let now = driver.renderWorld
            #expect(driver.alpha == 1)
            #expect(now.time == world.time)
            #expect(zip(now.boats, world.boats).allSatisfy { $0.position == $1.position && $0.heading == $1.heading },
                    "frame \(frame) moved the fleet")
        }
        #expect(driver.currentFrame.tick == finalTick)
    }

    /// Inputs submitted between ticks are latched: only the last one before a tick is applied, at that tick.
    @Test func inputIsLatchedPerTick() {
        let driver = PracticeDriver(config: RaceDriverTests.config)
        let next = driver.currentFrame.tick + 1
        driver.submit(BoatInput(rudder: 0.2))
        driver.submit(BoatInput(rudder: -0.5))
        driver.submit(BoatInput(rudder: 0.7))
        #expect(driver.tick(0.4 / Double(Race.tickRate)).isEmpty, "no tick yet")
        driver.submit(BoatInput(rudder: 0.9))
        #expect(driver.tick(0.6 / Double(Race.tickRate)).count == 1)
        let mine = driver.log.inputs.filter { $0.seat == driver.myBoatIndex }
        #expect(mine == [InputRecord(tick: next, seat: driver.myBoatIndex, kind: .held(BoatInput(rudder: 0.9)))])

        // Held, not resent: the same input over many ticks logs nothing more.
        for _ in 0..<30 {
            driver.submit(BoatInput(rudder: 0.9))
            driver.tick(1.0 / 60)
        }
        #expect(driver.log.inputs.filter { $0.seat == driver.myBoatIndex }.count == 1)
    }

    @Test func tapGoesInAtTheNextTick() {
        let driver = PracticeDriver(config: RaceDriverTests.config)
        let next = driver.currentFrame.tick + 1
        #expect(driver.tap(.tackGybe))
        driver.tick(1.0 / Double(Race.tickRate))
        #expect(driver.log.inputs.contains(InputRecord(tick: next, seat: driver.myBoatIndex, kind: .tap(.tackGybe))))
    }

    /// Under `-demo` a bot sails your seat: your input and taps don't reach the race. The bot steers and taps
    /// that seat itself (#231), so the proof is the same race sailed without them: input for input the same
    /// log, and the same state. (`inputIsLatchedPerTick` and `tapGoesInAtTheNextTick` show they do reach a
    /// seat you sail.)
    @Test func aBotSailedSeatIgnoresYourInput() {
        let config = RaceConfig(opponents: 3, seed: 1, windSeed: 2, botSailsYourBoat: true)
        let driver = PracticeDriver(config: config)
        let untouched = PracticeDriver(config: config)
        driver.submit(BoatInput(rudder: 1.0))
        #expect(!driver.tap(.tackGybe))
        for race in [driver, untouched] { race.tick(1) }
        #expect(driver.log.inputs.contains { $0.seat == driver.myBoatIndex }, "the bot sails your seat")
        #expect(driver.log == untouched.log)
        #expect(driver.digest() == untouched.digest())
    }

    @Test func myBoatIsTheSetupsHumanSeat() {
        let driver = PracticeDriver(config: RaceDriverTests.config)
        #expect(driver.myBoatIndex == RaceDriverTests.config.setup.seats.firstIndex(of: .human))
        #expect(driver.isPausable)
    }
}

/// The scene never drives the race itself (#61): it reads `RenderWorld` and sends input through the driver.
@MainActor @Suite struct GameSceneSourceTests {
    /// Reads the scene's source from the checkout on the host: `#filePath` is this test file's path at build
    /// time, and the simulator shares the Mac's filesystem, so the hosted test can open it directly.
    @Test func sceneNeverStepsOrSteersTheRace() throws {
        let source = try String(contentsOf: RaceDriverTests.repoRoot.appending(path: "Regatta/Game/GameScene.swift"), encoding: .utf8)
        #expect(!source.contains("race.step"))
        #expect(!source.contains("setPlayerRudder"))
        #expect(!source.contains("Race("))
    }
}

@MainActor enum RaceDriverTests {
    static let config = RaceConfig(opponents: 3, prestartSeconds: 60, seed: 1, windSeed: RaceConfig.windSeed(pinnedTo: 1))
    /// The repository, from this file's path at build time (the simulator can read the host's files).
    static let repoRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
}
