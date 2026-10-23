import Foundation
import Testing
@testable import RegattaCore
@testable import RegattaBots

/// #583 stage 3: the National helm plans her tacks and gybes (`BotPlanner`) on what her seat sees and nothing more, and
/// within a per-tick budget.
@Suite struct PlannerTests {
    /// The bundled tunables with the planner on at the ticket's horizon, 20 s at the top of the National band, from
    /// halfway through the Regional band at 8 s: whatever the bundled file plans.
    static let planning: BotTunables = {
        var tunables = BotTunables.bundled
        tunables.plannerHorizon = 20
        tunables.plannerStartHorizon = 8
        tunables.plannerStart = 0.5
        return tunables
    }()

    /// What ships (`bot-tunables@2`): every National bot plans, deeper the higher in the band; Club, Regional and the
    /// suite's profiles keep the heuristics (planning Regional too slowed it on the validation seeds, #583).
    @Test func theBundledSetPlansForNationalOnly() {
        let national = BotTier.national.skillBand
        let bottom = BotPlanner.depth(skill: national.lowerBound, tunables: .bundled)
        let top = BotPlanner.depth(skill: national.upperBound, tunables: .bundled)
        #expect(bottom != nil && top != nil)
        #expect((bottom?.horizon ?? 99) < (top?.horizon ?? 0))
        #expect(BotPlanner.depth(skill: BotTier.regional.skillBand.upperBound - 0.001, tunables: .bundled) == nil)
        for seat in 0..<8 {
            let raceSeed = RaceSeed(UInt64(seat) + 1)
            #expect(BotDriver(seat: seat, raceSeed: raceSeed, tier: .national).planningHorizon != nil)
            #expect(BotDriver(seat: seat, raceSeed: raceSeed, tier: .regional).planningHorizon == nil)
            #expect(BotDriver(seat: seat, raceSeed: raceSeed, tier: .club).planningHorizon == nil)
            #expect(BotDriver(seat: seat, raceSeed: raceSeed, skill: 1, profile: .tactician).planningHorizon == nil)
        }
    }

    /// #583 ("Information, not foresight"): two keys-only races holding every key from the start, the same through
    /// window k and different after it, sailed by planning National bots. Until window k + 1's wind reaches a view,
    /// every bot plans and decides the same in both: the keys past the present, there all along, are never read.
    /// (`SeatViewTests.botInputsIgnoreKeysPastThePresent` for the heuristics.)
    @Test func plannerNeverReadsAnUnrevealedWindKey() throws {
        let setup = try RaceSetup(raceSeed: RaceSeed(583), seats: Array(repeating: .bot, count: 6), laps: 1,
                                  startSequenceTicks: 30 * Race.tickRate)
        let probe = Race(setup: setup, windSeed: WindSeed(1))
        let windows = probe.wind.windows
        let k = windows.window(containing: 0) + 2
        let last = k + 4
        func keys(_ seed: UInt64) throws -> [WindKey] {
            var generator = try WindKeyGenerator(windSeed: WindSeed(seed), setup: probe.windSetup, windows: windows)
            return generator.keys(through: last)
        }
        let (mine, theirs) = (try keys(1), try keys(2))
        #expect(mine[k + 1] != theirs[k + 1])
        let a = Race(setup: setup, revealedWindKeys: mine)
        let b = Race(setup: setup, revealedWindKeys: Array(mine[...k]) + Array(theirs[(k + 1)...]))

        var driversA = setup.seats.indices.map { BotDriver(seat: $0, raceSeed: setup.raceSeed, tier: .national).tuned(Self.planning) }
        var driversB = driversA
        #expect(driversA.allSatisfy { $0.planningHorizon != nil }, "every National bot plans")
        var diverged: Int?
        while a.tick < windows.start(of: last) {
            guard a.boats.indices.allSatisfy({ a.seatView(for: $0) == b.seatView(for: $0) }) else {
                diverged = a.tick
                break
            }
            for seat in driversA.indices {
                #expect(driversA[seat].drive(a) == driversB[seat].drive(b), "seat \(seat) decided differently at tick \(a.tick)")
            }
            try a.tryStep()
            try b.tryStep()
        }
        let divergence = try #require(diverged, "the keys after window \(k) never reached a view")
        #expect(divergence >= windows.start(of: k + 1), "a view showed window \(k + 1)'s wind at tick \(divergence), before it began")
        #expect(driversA.map(\.planningSteps) == driversB.map(\.planningSteps))
        #expect(driversA.contains { $0.planningSteps > 0 }, "they planned before the views parted")
    }

    /// The owner's budget (#583, 2026-10-23), by rule: the whole fleet's planning at most a fifth of a tick on its worst
    /// tick, 6.6 ms of the 33.3 ms for ten bots, so 0.66 ms a planning bot; and on average 0.05 ms a bot a tick, what
    /// the server, running many races, pays. The budget, not a target.
    static let worstTickMillisecondsPerPlanningBot = 0.66
    static let meanMillisecondsPerBotPerTick = 0.05

    /// #583 ("CPU budget first"): the planner's own benchmark. Every reference race (`ReferenceRegatta`: ten National
    /// bots, two laps, the bundled set) sailed in full; on each tick, each plan a bot made is timed again from its inputs
    /// (`BotPlanner.Request`: the bot reads no clock), and the fleet's planning summed for the tick. The mean, over every
    /// bot and tick, is under `meanMillisecondsPerBotPerTick`. The worst ticks so timed (the `kept` slowest) are timed
    /// again at the end, each plan the fastest of `retimes` runs, so a tick the scheduler took the core from (the
    /// suite's other tests share it) doesn't stand for the planner's cost: the worst of them is under
    /// `worstTickMillisecondsPerPlanningBot` a planning bot. Release only: debug timings prove nothing.
    @Test(.enabled(if: !_isDebugAssertConfiguration(), "debug timings prove nothing"))
    func plannerStaysWithinTheTickBudget() throws {
        let kept = 200
        let retimes = 10
        let clock = ContinuousClock()
        let ms = { (d: Duration) in Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1e15 }
        func time(_ request: BotPlanner.Request) -> Double {
            let start = clock.now
            let gain = request.gain()
            let spent = ms(start.duration(to: clock.now))
            #expect(gain.isFinite)
            return spent
        }
        var total = 0.0
        var botTicks = 0
        var plans = 0
        var slowest: [(ms: Double, requests: [BotPlanner.Request])] = []
        for n in 1...ReferenceRegatta.count {
            let reference = ReferenceRegatta.race(n)
            let race = try reference.race()
            var drivers = reference.setup.seats.indices.map { reference.driver(seat: $0) }
            #expect(drivers.allSatisfy { $0.planningHorizon != nil }, "race \(n): every National bot plans")
            while !race.isOver && race.tick < 1_500 * Race.tickRate {
                var requests: [BotPlanner.Request] = []
                for k in drivers.indices {
                    let before = drivers[k].plans
                    drivers[k].drive(race)
                    if drivers[k].plans > before, let request = drivers[k].lastPlanRequest { requests.append(request) }
                }
                let tick = requests.reduce(0) { $0 + time($1) }
                total += tick
                plans += requests.count
                botTicks += drivers.count
                if !requests.isEmpty, slowest.count < kept || tick > slowest[slowest.count - 1].ms {
                    slowest.append((tick, requests))
                    slowest.sort { $0.ms > $1.ms }
                    if slowest.count > kept { slowest.removeLast() }
                }
                race.step()
            }
        }
        var worstTick = (ms: 0.0, planners: 1)
        var worstPlan = 0.0
        for candidate in slowest {
            let costs = candidate.requests.map { request in (0..<retimes).map { _ in time(request) }.min() ?? 0 }
            let tick = costs.reduce(0, +)
            worstPlan = max(worstPlan, costs.max() ?? 0)
            if tick / Double(costs.count) > worstTick.ms / Double(worstTick.planners) { worstTick = (tick, costs.count) }
        }
        let mean = total / Double(botTicks)
        print("PlannerTests: \(plans) plans over \(ReferenceRegatta.count) reference races; worst tick \(worstTick.ms) ms for "
              + "\(worstTick.planners) planning bots, worst plan \(worstPlan) ms (first timed \(slowest.first?.ms ?? 0) ms); "
              + "mean \(mean) ms a bot a tick")
        #expect(plans > 0)
        #expect(worstTick.ms <= Self.worstTickMillisecondsPerPlanningBot * Double(worstTick.planners))
        #expect(worstPlan <= Self.worstTickMillisecondsPerPlanningBot)
        #expect(worstTick.ms <= Self.worstTickMillisecondsPerPlanningBot * 10, "the fleet's worst tick, a fifth of one")
        #expect(mean <= Self.meanMillisecondsPerBotPerTick)
    }

    /// A plan costs what `BotPlanner.steps` says: two options at her horizon in 0.1 s steps, and she plans at most once
    /// a `BotPlanner.replanSeconds` a tack: a 10-boat race at the full horizon costs each bot a bounded number of forward
    /// steps a tick, however the clock reads.
    @Test func aPlanCostsItsSteps() throws {
        var full = Self.planning
        full.plannerStartHorizon = full.plannerHorizon
        let setup = try RaceSetup(raceSeed: RaceSeed(29), seats: Array(repeating: .bot, count: 10), laps: 1)
        let race = Race(setup: setup, windSeed: WindSeed(30))
        var drivers = setup.seats.indices.map { BotDriver(seat: $0, raceSeed: setup.raceSeed, tier: .national).tuned(full) }
        #expect(drivers.allSatisfy { $0.planningHorizon == 20 })
        var racingTicks = 0
        while !race.isOver && race.tick < 300 * Race.tickRate {
            for k in drivers.indices { drivers[k].drive(race) }
            race.step()
            if race.tick > 0 { racingTicks += 1 }
        }
        let steps = drivers.map(\.planningSteps)
        #expect(steps.allSatisfy { $0 > 0 }, "every bot planned: \(steps)")
        #expect(Double(steps.reduce(0, +)) / Double(drivers.count * racingTicks) <= Double(BotPlanner.steps(BotPlanner.Depth(horizon: 20))) / Double(Race.tickRate) * 2)
        #expect(BotPlanner.steps(BotPlanner.Depth(horizon: 20)) == 400)
    }

    /// Skill is depth: Club never plans, a Regional bot only high in her band and shallower, National deepest at the top,
    /// and nobody when the horizon is 0 (the bundled `bot-tunables@1`, the bots as they were).
    @Test func skillIsDepth() {
        let regional = BotTier.regional.skillBand
        let national = BotTier.national.skillBand
        #expect(BotPlanner.depth(skill: BotTier.club.skillBand.upperBound - 0.01, tunables: Self.planning) == nil)
        #expect(BotPlanner.depth(skill: regional.lowerBound, tunables: Self.planning) == nil)
        let high = BotPlanner.depth(skill: regional.upperBound - 0.001, tunables: Self.planning)
        let top = BotPlanner.depth(skill: national.upperBound, tunables: Self.planning)
        #expect(high != nil && top?.horizon == 20)
        #expect((high?.horizon ?? 99) < (top?.horizon ?? 0))
        #expect(BotPlanner.depth(skill: 1, tunables: .original) == nil)
    }

    /// The planner's wind is the seat's: the wind at her, scaled by the pressure map and the puffs she sees; with no
    /// perception (range 0) the wind at her everywhere.
    @Test func perceivedWindIsTheSeatsWind() throws {
        let setup = try RaceSetup(raceSeed: RaceSeed(7), seats: [.bot, .bot], laps: 1)
        let race = Race(setup: setup, windSeed: WindSeed(8))
        while race.tick < 60 * Race.tickRate { race.step() }
        let view = race.seatView(for: 0)
        let blind = BotPlanner.PerceivedWind(view, range: 0)
        let far = view.own.position + view.course.upwind * 300
        #expect(blind.at(far, after: 10).speed == view.own.polarWindSpeed)
        #expect(blind.at(far, after: 10).direction == wrapAngle(view.own.windDirection))
        let seeing = BotPlanner.PerceivedWind(view, range: BotWeaknesses.fullPuffPerception)
        let here = seeing.at(view.own.position, after: 0)
        #expect(abs(here.speed - view.own.polarWindSpeed) < 1e-9, "at her, the wind she has")
    }
}
