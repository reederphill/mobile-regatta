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

    /// The forward sail's cost a bot pays a tick, at most, averaged over a race: the owner's ceiling, a placeholder.
    /// 10 planning bots at 30 Hz is then at most 10 × this `BoatDynamics.advance` calls a tick, each well under a
    /// microsecond: a planner that ran away would show here first.
    static let stepsPerBotPerTick = 30.0

    /// #583 ("CPU budget first: 10 bots at 30 Hz"): a 10-boat all-National race, every bot planning at the full horizon,
    /// costs each bot no more than `stepsPerBotPerTick` forward-sail steps a tick, averaged over the race; and a plan
    /// costs what `BotPlanner.steps` says.
    @Test func plannerStaysWithinTheTickBudget() throws {
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
        let perBotPerTick = Double(steps.reduce(0, +)) / Double(drivers.count * racingTicks)
        #expect(perBotPerTick <= Self.stepsPerBotPerTick, "\(perBotPerTick) steps a bot a tick")
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
