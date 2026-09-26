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

    /// The budget only changes when ticks run: the race it sails is the same, tick for tick.
    @Test func aBudgetSailsTheSameRace() {
        let unbudgeted = PracticeDriver(config: RaceDriverTests.config, timescale: 8)
        let budgeted = PracticeDriver(config: RaceDriverTests.config, timescale: 8)
        for _ in 0..<50 { unbudgeted.tick(0.1) }
        while budgeted.currentFrame.tick < unbudgeted.currentFrame.tick { budgeted.tick(0.1, within: .zero) }
        #expect(budgeted.currentFrame.tick == unbudgeted.currentFrame.tick)
        #expect(budgeted.digest() == unbudgeted.digest())
    }
}

@MainActor @Suite struct PracticeDriverTests {
    /// A bot sails every seat (`-demo`), so the race runs headless to its finish; its log replays to the same world.
    @Test func runsHeadlessToTheFinishAndReplaysToTheSameDigest() throws {
        let config = RaceConfig(opponents: 7, seed: 1, windSeed: RaceConfig.windSeed(pinnedTo: 1), botSailsYourBoat: true)
        let driver = PracticeDriver(config: config)
        var seconds = 0
        while !driver.currentFrame.isOver && seconds < 1_500 {
            driver.tick(1)
            seconds += 1
        }
        #expect(driver.currentFrame.isOver)
        #expect(driver.currentFrame.boats[driver.myBoatIndex].status == .finished)
        #expect(driver.drainEvents().contains { $0.kind == .raceClosed })

        let log = driver.log
        #expect(log.inputs.contains { $0.seat == driver.myBoatIndex }, "the bot's inputs went through the input API")
        let replayed = try Replayer.replay(log)
        #expect(replayed.tick == driver.currentFrame.tick)
        #expect(replayed.digest() == driver.digest())
    }

    /// Once the race is over the clock stops: display frames run no ticks and the drawn world stays at the
    /// last tick, so the fleet doesn't wobble between the last two ticks behind the results.
    @Test func aFinishedRaceStandsStill() {
        let config = RaceConfig(opponents: 3, seed: 1, windSeed: RaceConfig.windSeed(pinnedTo: 1), botSailsYourBoat: true)
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

    /// Under `-demo` a bot sails your seat: your input and taps don't reach the race.
    @Test func aBotSailedSeatIgnoresYourInput() {
        let driver = PracticeDriver(config: RaceConfig(opponents: 3, seed: 1, windSeed: 2, botSailsYourBoat: true))
        driver.submit(BoatInput(rudder: 1.0))
        #expect(!driver.tap(.tackGybe))
        driver.tick(1.0 / Double(Race.tickRate))
        #expect(!driver.log.inputs.contains { $0.seat == driver.myBoatIndex && $0.kind == .held(BoatInput(rudder: 1.0)) })
        #expect(!driver.log.inputs.contains { $0.seat == driver.myBoatIndex && $0.kind == .tap(.tackGybe) })
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
