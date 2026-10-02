import Testing
import RegattaBots
import RegattaCore
import RegattaServices
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

    /// `-camera` overrides the device's camera (#113): `course` is course-up and `boat` boat-up; without it, Settings'.
    @Test func cameraOverridesTheDeviceCamera() {
        #expect(ControlSettings.camera(.boatUp, override: .course) == .courseUp)
        #expect(ControlSettings.camera(.courseUp, override: .boat) == .boatUp)
        #expect(ControlSettings.camera(.boatUp, override: nil) == .boatUp)
        #expect(ControlSettings.camera(.courseUp, override: nil) == .courseUp)
        var settings = DeviceSettings()
        settings.camera = .courseUp
        settings.autoZoom = false
        let controls = ControlSettings(settings, launchOptions: parse("-camera", "boat"))
        #expect(controls.camera == .boatUp && !controls.autoZoom)
        settings.autoZoom = true
        controls.update(settings, launchOptions: parse())
        #expect(controls.camera == .courseUp && controls.autoZoom)
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

    /// `-briefing practice|online` opens on the briefing (#130); anything else is ignored with a launch problem.
    @Test func parsesTheBriefing() {
        #expect(parse("-briefing", "practice").briefing == .practice)
        #expect(parse("-briefing", "online").briefing == .online)
        #expect(parse().briefing == nil)
        let bad = parse("-briefing", "lobby")
        #expect(bad.briefing == nil)
        #expect(bad.problems == ["-briefing lobby: expected practice or online"])
        let missing = parse("-briefing", "-seed", "3")
        #expect(missing.briefing == nil && missing.seed == 3)
        #expect(missing.problems == ["-briefing needs a value"])
        #expect(!parse("-briefing", "online").startsRace, "the briefing isn't a race launch")
    }

    /// `-fakeServices` names a scenario of scripted fakes for UI tests (#242); an unknown one is ignored with a
    /// launch problem, and so is a missing value.
    @Test func parsesFakeServicesScenario() {
        #expect(parse().fakeServices == nil)
        for scenario in FakeServiceScenario.allCases {
            let options = parse("-fakeServices", scenario.rawValue, "-autostart")
            #expect(options.fakeServices == scenario, "-fakeServices \(scenario.rawValue)")
            #expect(options.autostart && options.problems.isEmpty)
        }
        let unknown = parse("-fakeServices", "haunted")
        #expect(unknown.fakeServices == nil)
        #expect(unknown.problems == ["-fakeServices haunted: expected "
            + "signed-out, underage, communication-restricted, multiplayer-restricted, offline, queued, cancelled-race"])
        let missing = parse("-fakeServices", "-autostart")
        #expect(missing.fakeServices == nil && missing.autostart)
        #expect(missing.problems == ["-fakeServices needs a value"])
    }

    /// `-appearance` lets UI tests render the menus in light and dark (#108).
    @Test func parsesTheAppearance() {
        #expect(parse().appearance == nil)
        #expect(parse("-appearance", "light").appearance == .light)
        #expect(parse("-appearance", "dark", "-autostart").appearance == .dark)
        let bad = parse("-appearance", "sepia")
        #expect(bad.appearance == nil)
        #expect(bad.problems == ["-appearance sepia: expected light or dark"])
    }

    /// `-vision` (#111): the short names, and each filter's own; a race launched with one draws through it.
    @Test func parsesTheVisionFilter() {
        #expect(parse().vision == nil)
        #expect(parse().raceVision == .none)
        let short: [String: VisionFilter] = ["deut": .deuteranopia, "prot": .protanopia, "trit": .tritanopia,
                                             "grey": .greyscale, "sun": .washout]
        #expect(LaunchOptions.visionShortNames == short)
        for (name, filter) in short {
            #expect(parse("-vision", name).vision == filter, "-vision \(name)")
        }
        for filter in VisionFilter.allCases {
            let options = parse("-vision", filter.rawValue, "-autostart")
            #expect(options.vision == filter, "-vision \(filter.rawValue)")
            #if DEBUG
            #expect(options.raceVision == filter, "Debug builds draw a race through -vision \(filter.rawValue)")
            #endif
            #expect(options.autostart)
            #expect(options.problems.isEmpty)
        }
        let bad = parse("-vision", "sepia")
        #expect(bad.vision == nil)
        #expect(bad.problems == ["-vision sepia: expected deut, prot, trit, grey, sun, none, deuteranopia, protanopia, "
            + "tritanopia, greyscale or washout"])
        // The rejection names everything `-vision` takes, and takes everything it names.
        let named = LaunchOptions.visionNames.replacingOccurrences(of: " or ", with: ", ").components(separatedBy: ", ")
        #expect(Set(named) == Set(short.keys).union(VisionFilter.allCases.map(\.rawValue)))
        let missing = parse("-vision", "-autostart")
        #expect(missing.vision == nil && missing.autostart)
        #expect(missing.problems == ["-vision needs a value"])
    }

    @Test func aMissingValueDoesNotSwallowTheNextFlag() {
        let options = parse("-seed", "-autostart", "-fixture")
        #expect(options.seed == nil)
        #expect(options.fixture == nil)
        #expect(options.autostart)
        #expect(options.problems == ["-seed needs a value", "-fixture needs a value"])
    }

    /// The online dev race (#68): the flag, the server and the race-length overrides; not a practice race.
    @Test func parsesTheOnlineDevRace() {
        let options = parse("-online", "-onlineHost", "127.0.0.1:50123", "-startSeconds", "5", "-raceSeconds", "20")
        #expect(options.online)
        #expect(options.onlineHost == "127.0.0.1:50123")
        #expect(options.startSeconds == 5)
        #expect(options.raceSeconds == 20)
        #expect(options.problems.isEmpty)
        #expect(options.launchRaceConfig(from: RaceSettings()) == nil)
        #expect(RaceServer(address: options.onlineHost!).raceURL?.absoluteString == "ws://127.0.0.1:50123/race")
    }

    @Test func ignoresBadOnlineValues() {
        let options = parse("-onlineHost", "http://host/", "-startSeconds", "61", "-raceSeconds", "0")
        #expect(options.onlineHost == nil)
        #expect(options.startSeconds == nil)
        #expect(options.raceSeconds == nil)
        #expect(options.problems.count == 3)
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

    /// `-laps` sails every practice race that many laps (#354: the race-finish UI test sails one); bad values are
    /// refused and the settings' laps stand.
    @Test func lapsOverridesTheSettingsLaps() throws {
        let settings = RaceSettings()
        let config = try #require(parse("-autostart", "-seed", "1", "-laps", "1").launchRaceConfig(from: settings))
        #expect(config.laps == 1)
        #expect(config.setup.laps == 1)
        #expect(parse("-laps", "1").raceConfig(from: settings).laps == 1, "a restarted race too")
        #expect(parse().raceConfig(from: settings).laps == settings.laps)
        for bad in ["0", "10", "two"] {
            let options = parse("-laps", bad)
            #expect(options.laps == nil)
            #expect(options.problems.count == 1)
            #expect(options.raceConfig(from: settings).laps == settings.laps)
        }
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

    #if DEBUG
    /// `-tuning` opens the debug tuning panel (#232): a flag of its own, never another option's value, and
    /// Debug builds only (a Release build skips it as an unknown argument).
    @Test func tuningOpensTheTuningPanel() {
        #expect(parse("-tuning").tuning)
        #expect(!parse().tuning)
        #expect(!parse("-tuning").startsRace)
        let valueless = parse("-seed", "-tuning")
        #expect(valueless.tuning)
        #expect(valueless.problems == ["-seed needs a value"])
    }
    #endif
}
