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

    /// Until #102, a tier is its skill band: the bot's own drawn style, its skill rescaled into the band
    /// and nothing else changed. `seeded` is today's bot.
    @Test func tiersRescaleSkillIntoTheirBands() throws {
        for raceSeed in (1...4).map(RaceSeed.init) {
            for seat in 0..<16 {
                let seeded = BotDriver(seat: seat, raceSeed: raceSeed)
                #expect(BotTier.seeded.driver(seat: seat, raceSeed: raceSeed).style == seeded.style)
                for tier in [BotTier.club, .regional, .national] {
                    let driver = tier.driver(seat: seat, raceSeed: raceSeed)
                    let band = try #require(tier.skillBand)
                    #expect(band.contains(driver.style.skill), "\(tier) seat \(seat) skill \(driver.style.skill)")
                    var style = driver.style
                    style.skill = seeded.style.skill
                    #expect(style == seeded.style, "a tier changes only the skill")
                    #expect(driver.seed == seeded.seed)
                }
            }
        }
    }

    @Test func mixedRoundRobinsTheTiersBySeat() {
        #expect((0..<6).map { TierMix.mixed.tier(ofSeat: $0) } == [.club, .regional, .national, .club, .regional, .national])
        #expect(TierMix.seeded.tier(ofSeat: 4) == .seeded)
        #expect(TierMix.national.tier(ofSeat: 0) == .national)
    }
}
