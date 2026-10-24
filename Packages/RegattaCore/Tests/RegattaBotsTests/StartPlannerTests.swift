import Foundation
import Testing
@testable import RegattaCore
@testable import RegattaBots

/// #584 stage 4: the gap planner (`BotBrain.planStart`) picks a National bot's hole in the line from what her seat sees and
/// nothing more, and within the planner's per-tick budget (#583's, `PlannerTests`).
@Suite struct StartPlannerTests {
    /// #584 stage 4: information, not foresight (ADR 0001). Two keys-only races hold the same keys through the window
    /// holding T−20, when a National bot starts planning her hole, and different keys from the gun's window on. Every bot's
    /// view is the same in both until a view shows the next window's wind, and so is every decision she makes, holes and
    /// all: the planner reads the view, never a key it hasn't been shown.
    @Test func plannerNeverReadsAnUnrevealedWindKey() throws {
        let setup = try RaceSetup(raceSeed: RaceSeed(584), seats: Array(repeating: .bot, count: 10), laps: 1)
        let probe = Race(setup: setup, windSeed: WindSeed(1))
        let windows = probe.wind.windows
        let k = windows.window(containing: -Int(BotBrain.nationalFromSeconds) * Race.tickRate)
        let last = k + 3
        func keys(_ seed: UInt64) throws -> [WindKey] {
            var generator = try WindKeyGenerator(windSeed: WindSeed(seed), setup: probe.windSetup, windows: windows)
            return generator.keys(through: last)
        }
        let (mine, theirs) = (try keys(1), try keys(2))
        #expect(mine[k + 1] != theirs[k + 1])
        let a = Race(setup: setup, revealedWindKeys: mine)
        let b = Race(setup: setup, revealedWindKeys: Array(mine[...k]) + Array(theirs[(k + 1)...]))
        var driversA = setup.seats.indices.map { BotDriver(seat: $0, raceSeed: setup.raceSeed, tier: .national) }
        var driversB = driversA
        #expect(driversA.allSatisfy { $0.brain.startPlanning == BotBrain.StartPlanDepth(fromSeconds: 20, stride: 1) })
        var diverged: Int?
        while a.tick < windows.start(of: last) {
            guard a.boats.indices.allSatisfy({ a.seatView(for: $0) == b.seatView(for: $0) }) else {
                diverged = a.tick
                break
            }
            for seat in driversA.indices {
                #expect(driversA[seat].drive(a) == driversB[seat].drive(b), "seat \(seat) decided differently at tick \(a.tick)")
                #expect(driversA[seat].brain.plannedSpot == driversB[seat].brain.plannedSpot)
            }
            try a.tryStep()
            try b.tryStep()
        }
        let divergence = try #require(diverged, "the keys after window \(k) never reached a view")
        #expect(divergence >= windows.start(of: k + 1), "a view showed window \(k + 1)'s wind at tick \(divergence), before it began")
        #expect(driversA.map(\.brain.startPlans) == driversB.map(\.brain.startPlans))
        #expect(driversA.allSatisfy { $0.brain.startPlans > 0 }, "they planned their holes before the views parted")
    }

    /// #584 stage 4 ("CPU: ten bots planning at once in the last 20 s; measure first"): the hole planner within #583's
    /// budget (`PlannerTests`): at most 0.66 ms a planning bot on the worst tick, and 0.05 ms a bot a tick on average over
    /// the sequence. Ten National bots on four race seeds, from the start of the sequence to the gun; each plan
    /// a bot makes is timed again on a copy of her brain, the slowest ticks as the fastest of ten runs.
    @Test(.enabled(if: !_isDebugAssertConfiguration(), "debug timings prove nothing"))
    func plannerStaysWithinTheTickBudget() throws {
        let clock = ContinuousClock()
        let ms = { (d: Duration) in Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1e15 }
        var total = 0.0
        var botTicks = 0
        var plans = 0
        var worstTick = (ms: 0.0, planners: 1)
        for n in 0..<4 {
            let setup = try RaceSetup(raceSeed: RaceSeed(UInt64(584 + n)), seats: Array(repeating: .bot, count: 10), laps: 1)
            let race = Race(setup: setup, windSeed: WindSeed(UInt64(5_840 + n)))
            var drivers = setup.seats.indices.map { BotDriver(seat: $0, raceSeed: setup.raceSeed, tier: .national) }
            while race.tick < 0 {
                var tick = 0.0
                var planners = 0
                for k in drivers.indices {
                    let before = drivers[k].brain.startPlans
                    let brain = drivers[k].brain
                    drivers[k].drive(race)
                    guard drivers[k].brain.startPlans > before else { continue }
                    let view = race.seatView(for: k)
                    let cost = (0..<10).map { _ in
                        var copy = brain
                        let start = clock.now
                        copy.planStart(view.own, view)
                        return ms(start.duration(to: clock.now))
                    }.min() ?? 0
                    tick += cost
                    planners += 1
                }
                total += tick
                plans += planners
                botTicks += drivers.count
                if planners > 0, tick / Double(planners) > worstTick.ms / Double(worstTick.planners) {
                    worstTick = (tick, planners)
                }
                race.step()
            }
        }
        let mean = total / Double(botTicks)
        print("StartPlannerTests: \(plans) plans; worst tick \(worstTick.ms) ms for \(worstTick.planners) planning bots; "
              + "mean \(mean) ms a bot a tick")
        #expect(plans > 0)
        #expect(worstTick.ms <= PlannerTests.worstTickMillisecondsPerPlanningBot * Double(worstTick.planners))
        #expect(mean <= PlannerTests.meanMillisecondsPerBotPerTick)
    }
}
