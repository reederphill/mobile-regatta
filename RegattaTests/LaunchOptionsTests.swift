import Testing
import RegattaBots
import RegattaCore
@testable import Regatta

@MainActor @Suite struct LaunchOptionsTests {
    private func parse(_ arguments: String...) -> LaunchOptions {
        LaunchOptions(arguments: ["/path/to/Regatta"] + arguments)
    }

    @Test func noArgumentsMeansTheMenuAndDefaults() {
        let options = parse()
        #expect(options == LaunchOptions())
        #expect(!options.startsRace)
        #expect(options.timescale == 1)
        #expect(options.launchRaceConfig(from: RaceSettings()) == nil)
    }

    @Test func parsesEveryOption() {
        let options = parse("-autostart", "-seed", "1", "-fixture", "windward-mark", "-timescale", "4",
                            "-scheme", "tiller", "-camera", "boat", "-demo", "-perf")
        #expect(options.autostart && options.demo && options.perf)
        #expect(options.seed == 1)
        #expect(options.fixture == "windward-mark")
        #expect(options.timescale == 4)
        #expect(options.steeringScheme == .tiller)
        #expect(options.camera == .boat)
        #expect(options.problems.isEmpty)
    }

    @Test func parsesTheOtherSchemeAndCamera() {
        let options = parse("-scheme", "halves", "-camera", "course")
        #expect(options.steeringScheme == .halves)
        #expect(options.camera == .course)
    }

    @Test func skipsArgumentsItDoesNotKnow() {
        let options = parse("-NSTreatUnknownArgumentsAsOpen", "NO", "-ApplePersistenceIgnoreState", "YES", "-autostart")
        #expect(options.autostart)
        #expect(options.problems.isEmpty)
    }

    @Test func ignoresBadValues() {
        let options = parse("-seed", "-3", "-timescale", "0", "-scheme", "dial", "-camera", "chase", "-autostart")
        #expect(options.seed == nil)
        #expect(options.timescale == 1)
        #expect(options.steeringScheme == nil)
        #expect(options.camera == nil)
        #expect(options.autostart)
        #expect(options.problems.count == 4)
    }

    @Test func aMissingValueDoesNotSwallowTheNextFlag() {
        let options = parse("-seed", "-autostart", "-fixture")
        #expect(options.seed == nil)
        #expect(options.fixture == nil)
        #expect(options.autostart)
        #expect(options.problems == ["-seed needs a value", "-fixture needs a value"])
    }

    @Test func uiTestsAndFixturesHideTheDebugStats() {
        #expect(parse("-autostart").showsDebugStats)
        #expect(!parse("-uitesting", "-autostart").showsDebugStats)
        #expect(!parse("-fixture", "start").showsDebugStats)
    }

    @Test func aPinnedSeedSailsEveryRace() {
        let options = parse("-seed", "1")
        let first = options.raceConfig(from: RaceSettings())
        let second = options.raceConfig(from: RaceSettings())
        #expect(first.seed == 1)
        #expect(second.seed == 1)
        #expect(first.windSeed == second.windSeed, "the wind seed is pinned too")
        #expect(first.windSeed == RaceConfig.windSeed(pinnedTo: 1))
    }

    @Test func autostartSailsTheSettingsRace() throws {
        let settings = RaceSettings()
        let config = try #require(parse("-autostart", "-seed", "1").launchRaceConfig(from: settings))
        #expect(config.seed == 1)
        #expect(config.opponents == settings.opponents)
        #expect(!config.botSailsYourBoat)
    }

    @Test func demoLetsABotSailThePlayer() throws {
        let config = try #require(parse("-demo").launchRaceConfig(from: RaceSettings()))
        #expect(config.botSailsYourBoat)
        #expect(config.seatControllers[0].driver?.seat == 0, "a bot controller is attached to seat 0")
        #expect(config.seatControllers.seats.allSatisfy { !$0.isHuman })
        #expect(config.setup.seats[0] == .human, "it's still your seat")
    }

    @Test func perfIsASixteenBoatDemoRace() throws {
        let config = try #require(parse("-perf").launchRaceConfig(from: RaceSettings()))
        #expect(config.botSailsYourBoat)
        #expect(PracticeDriver(config: config).currentFrame.boats.count == 16)
    }
}
