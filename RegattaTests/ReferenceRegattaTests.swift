import Testing
import RegattaBots
import RegattaCore
@testable import Regatta

#if DEBUG
/// #367: the app's half of the reference regatta. `-referenceRace <n>` sails the race the bot suite's
/// `BotRaceHarness.runReference(n, standIn:)` does, both built by `ReferenceRace` and nothing else; only the helm in seat 0
/// differs. The package's half (`Packages/RegattaCore/Tests/BotSuiteTests/ReferenceRegattaTests`) holds the harness to
/// the builder (`harnessSailsTheBuildersRace`) and the file to its rules (`fileValidates`).
@MainActor @Suite struct ReferenceRegattaTests {
    /// The launch race of `-referenceRace 3` is reference race 3: its setup, wind seed, untuned files, National tier and
    /// every bot seat's driver (skill and style) are the builder's. Sailed 80 s (the 60 s sequence and 20 s after the
    /// gun, as `app.tick(80)`) with the same stand-in in seat 0 on both sides, the app logs the race the harness builds.
    @Test func appAndHarnessBuildTheSameRace() throws {
        var config = try #require(LaunchOptions(arguments: ["/path/to/Regatta", "-referenceRace", "3"]).launchRaceConfig())
        let reference = ReferenceRegatta.race(3)
        #expect(config.reference == reference)
        #expect(config.setup == reference.setup)
        #expect(WindSeed(config.windSeed) == reference.windSeed)
        #expect(config.botTier == .national)
        #expect(config.rivalSkill == nil)
        #expect(!config.botSailsYourBoat, "you sail seat 0")
        #expect(!config.files.isTuned, "the file's untuned bundled files")
        #expect(config.setup.seats[0] == .human)

        let appSeats = config.seatControllers
        let harnessSeats = reference.controllers(standIn: nil)
        #expect(appSeats[0].isHuman)
        for seat in 1..<reference.setup.fleetSize {
            let app = try #require(appSeats[seat].driver)
            let harness = try #require(harnessSeats[seat].driver)
            #expect(app.style == harness.style, "seat \(seat)")
            #expect(app.style.skill == harness.style.skill, "seat \(seat)")
            #expect(BotTier.national.skillBand.contains(app.style.skill), "seat \(seat)")
            #expect(app.weaknesses == harness.weaknesses, "seat \(seat)")
        }

        // Sailed: the harness's race (`ReferenceRace.race()`, as `runReference` builds it) against the app's practice
        // race, the suite's stand-in sailing seat 0 on both.
        let harnessRace = try reference.race()
        var harnessControllers = reference.controllers(standIn: .tactician)
        for _ in 0..<(80 * Race.tickRate) {
            harnessControllers.drive(harnessRace)
            harnessRace.step()
        }
        config.botSailsYourBoat = true
        let app = PracticeDriver(config: config)
        #expect(!app.youSailYourBoat)
        _ = app.tick(80)
        #expect(app.log == harnessRace.log)
    }
}
#endif
