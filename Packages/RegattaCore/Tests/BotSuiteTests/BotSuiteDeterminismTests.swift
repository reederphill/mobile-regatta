import BotSuite
import Foundation
import RegattaBots
import RegattaCore
import Testing

@Suite struct BotSuiteDeterminismTests {
    /// #97 acceptance: the same seed sailed twice on one platform gives the same JSON, but for the tick
    /// times. Bots draw only from their own seeds and never read the clock
    /// (`SourceScanTests.noWallClockInSources`, `noStdlibRandomnessInSources`).
    @Test func sameSeedTwiceGivesIdenticalReportExcludingTimings() throws {
        let matrix = BotMatrix(seeds: [5], fleetSizes: [5], tierMixes: [.mixed], laps: 1, capSecondsAfterGun: 240)
        let first = try BotSuite.run(matrix, thresholds: unmissableThresholds())
        let second = try BotSuite.run(matrix, thresholds: unmissableThresholds())
        #expect(try jsonWithoutTimings(first) == jsonWithoutTimings(second))
        #expect(first.races.map(\.timings.ticks) == second.races.map(\.timings.ticks))

        let other = try BotSuite.run(BotMatrix(seeds: [6], fleetSizes: [5], tierMixes: [.mixed], laps: 1, capSecondsAfterGun: 240),
                                     thresholds: unmissableThresholds())
        #expect(other.races.map(\.seats) != first.races.map(\.seats), "another seed sails another race")
    }

    /// `--jobs`: races sailed at once give the report sailed one after another, but for the tick times: each race is
    /// its own, and the results are pooled in the matrix's order whichever finishes first.
    @Test func parallelRacesGiveTheSerialReportExcludingTimings() throws {
        let matrix = BotMatrix(seeds: [5, 6, 7], fleetSizes: [2, 5], tierMixes: [.mixed, .national], laps: 1,
                               capSecondsAfterGun: 240)
        let serial = try BotSuite.run(matrix, thresholds: unmissableThresholds(), jobs: 1)
        let parallel = try BotSuite.run(matrix, thresholds: unmissableThresholds(), jobs: 4)
        #expect(serial.races.count > 4)
        #expect(parallel.races.map(\.cell) == matrix.cells)
        #expect(try jsonWithoutTimings(parallel) == jsonWithoutTimings(serial))
        #expect(parallel.races.map(\.timings.ticks) == serial.races.map(\.timings.ticks))
    }

    /// Since #81 a race is assembled from the files its setup names, so the conditions axis sails other
    /// wind: each cell's race is sailed with exactly the conditions it names.
    @Test func conditionsAxisVariesTheRace() throws {
        let cells = BotMatrix(seeds: [5], conditions: ["classic-oscillating@3", "gusty-offshore@3"], fleetSizes: [5]).cells
        let races = try cells.map { cell in
            let setup = try BotRaceHarness.raceSetup(for: cell)
            return try Race(setup: setup, files: RaceFiles(resolving: setup),
                            mode: .authoritative(windSeed: BotRaceHarness.windSeed(for: cell.seed)))
        }
        #expect(races.map { "\($0.files.conditions.ref.id)@\($0.files.conditions.ref.version)" } == cells.map(\.conditions))
        #expect(races[0].windSetup.baseStrength != races[1].windSetup.baseStrength)
    }

    /// Since #102 a tier is its skill band and nothing else (the orchestrator's ruling: weaknesses are continuous
    /// in skill, `BotWeaknesses`): a tier's bot is the bot of a skill inside its band, drawn from her own seed, with
    /// her style drawn from the same seed as any other bot's. A Mixed fleet (the app's default bot) draws each
    /// seat's tier and its skill in it from one draw of its seed.
    @Test func tiersAreSkillBands() throws {
        for raceSeed in (1...4).map(RaceSeed.init) {
            for seat in 0..<16 {
                let seed = botSeed(raceSeed: raceSeed, seat: seat)
                let drawn = BotTier.mixedFleetDraw(seed: seed)
                #expect(drawn.tier.skillBand.contains(drawn.skill))
                #expect(BotDriver(seat: seat, raceSeed: raceSeed).style.skill == drawn.skill)
                #expect(TierMix.mixed.driver(seat: seat, raceSeed: raceSeed).style == BotDriver(seat: seat, raceSeed: raceSeed).style)
                for tier in BotTier.allCases {
                    let driver = tier.driver(seat: seat, raceSeed: raceSeed)
                    #expect(tier.skillBand.contains(driver.style.skill), "\(tier) seat \(seat) skill \(driver.style.skill)")
                    var rng = SplitMix64(seed: seed)
                    #expect(driver.style == BotStyle(skill: driver.style.skill, rng: &rng), "a tier changes only the skill")
                    #expect(driver.seed == seed)
                }
            }
        }
    }

    @Test func mixedDrawsEachSeatsTierFromItsSeed() {
        let raceSeed = RaceSeed(3)
        let tiers = (0..<16).map { TierMix.mixed.tier(ofSeat: $0, raceSeed: raceSeed) }
        #expect(tiers == (0..<16).map { BotTier.mixedFleetDraw(seed: botSeed(raceSeed: raceSeed, seat: $0)).tier })
        #expect(TierMix.club.tier(ofSeat: 4, raceSeed: raceSeed) == .club)
        #expect(TierMix.national.tier(ofSeat: 0, raceSeed: raceSeed) == .national)
    }

    /// #367: a reference race with the stand-in in seat 0 sails the same result twice (it has no tick timings), and
    /// another stand-in sails another race. Capped 3 min after the gun to keep it quick: the whole race is the same
    /// function of the same keys and drivers.
    @Test func referenceRaceWithTheStandInSailsTheSameResultTwice() throws {
        let cap = 180
        let first = try BotRaceHarness.runReference(2, standIn: .tactician, capSecondsAfterGun: cap)
        let second = try BotRaceHarness.runReference(2, standIn: .tactician, capSecondsAfterGun: cap)
        #expect(first == second)
        #expect(first.finalTick == cap * Race.tickRate && first.places.count == 10)
        #expect(try BotRaceHarness.runReference(2, standIn: .club, capSecondsAfterGun: cap).digest != first.digest)
    }
}
