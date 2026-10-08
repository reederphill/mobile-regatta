import BotSuite
import Foundation
import RegattaBots
import RegattaCore
import Testing

/// #367: the reference regatta's file and its one builder, `ReferenceRace`. The app's half
/// (`RegattaTests/ReferenceRegattaTests`) holds the app's `-referenceRace` launch to the same race.
@Suite struct ReferenceRegattaTests {
    /// The bundled file loads with every race built: each names bundled files its venue can host, a fleet `RaceSetup`
    /// takes, a tier the bot-tier file knows; its seeds are distinct; and each @7 conditions file has four races.
    @Test func fileValidates() throws {
        let regatta = try ReferenceRegatta.load(version: ReferenceRegatta.currentVersion)
        #expect(regatta.races.count == 16)
        #expect(ReferenceRegatta.count == regatta.races.count)
        for (index, race) in regatta.races.enumerated() {
            #expect(race.number == index + 1)
            #expect(RaceSetup.fleetSizes.contains(race.setup.fleetSize))
            #expect(race.setup.fleetSize == 10)
            #expect(race.setup.seats == [.human] + Array(repeating: .bot, count: 9))
            #expect(race.tier == .national)
            #expect(BotTier.allCases.contains(race.tier))
            #expect(!BotTierFile.bundled[race.tier].skillBand.isEmpty)
            #expect(race.setup.laps == 2 && race.setup.startSequenceTicks == 60 * Race.tickRate, "owner, 2026-10-08")
            let files = try race.files()
            #expect(files.venue.ref.key == DataFileKey(id: "dev-venue", version: 7))
            #expect(files.boatClass.ref == RaceFiles.defaults.boatClass.ref)
            #expect(files.rulesConfiguration.ref == RaceFiles.defaults.rulesConfiguration.ref)
            #expect([race.setup.boatClass, race.setup.venue, race.setup.conditions, race.setup.rulesConfiguration]
                .allSatisfy { $0.tune == nil }, "untuned bundled files")
        }
        let raceSeeds = regatta.races.map(\.setup.raceSeed.value)
        let windSeeds = regatta.races.map(\.windSeed.value)
        #expect(Set(raceSeeds + windSeeds).count == raceSeeds.count + windSeeds.count, "every seed distinct")
        let byConditions = Dictionary(grouping: regatta.races, by: { $0.setup.conditions.key })
        #expect(Set(byConditions.keys) == Set(["classic-oscillating", "gusty-offshore", "light-and-patchy", "sea-breeze"]
            .map { DataFileKey(id: $0, version: 7) }))
        #expect(byConditions.values.allSatisfy { $0.count == 4 })
    }

    /// The package's half of `appAndHarnessBuildTheSameRace`: the harness sails the race the builder gives, its setup,
    /// wind seed and bots, and nothing of its own (the matrix's `windSeed(for:)` and tier mixes play no part). Sailed
    /// for 80 s against the race built by hand from `ReferenceRace`, the digests match.
    @Test func harnessSailsTheBuildersRace() throws {
        let reference = ReferenceRegatta.race(3)
        let race = try reference.race()
        #expect(race.setup == reference.setup)
        var controllers = reference.controllers(standIn: .tactician)
        for seat in 1..<reference.setup.fleetSize {
            let driver = try #require(controllers[seat].driver)
            #expect(driver.style == BotDriver(seat: seat, raceSeed: reference.setup.raceSeed, tier: .national).style)
            #expect(BotTier.national.skillBand.contains(driver.style.skill))
        }
        #expect(controllers[0].driver?.profile == .tactician)
        #expect(controllers[0].driver?.style.skill == 1)
        #expect(reference.controllers(standIn: nil)[0].isHuman)
        let capSeconds = 20
        while race.tick < capSeconds * Race.tickRate {
            controllers.drive(race)
            race.step()
        }
        let harness = try BotRaceHarness.runReference(3, standIn: .tactician, capSecondsAfterGun: capSeconds)
        #expect(harness.capped && harness.finalTick == race.tick)
        #expect(harness.digest == race.digest())
    }
}
