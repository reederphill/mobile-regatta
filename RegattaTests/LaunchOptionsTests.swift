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
        #expect(options.launchRaceConfig() == nil)
    }

    @Test func parsesEveryOption() {
        let options = parse("-autostart", "-seed", "1", "-fixture", "windward-mark", "-timescale", "4",
                            "-scheme", "tiller", "-camera", "boat", "-demo", "-perf", "-thermal", "serious")
        #expect(options.autostart && options.demo && options.perf)
        #expect(options.thermal == .serious)
        #expect(options.seed == 1)
        #expect(options.fixture == "windward-mark")
        #expect(options.timescale == 4)
        #expect(options.steeringScheme == .tiller)
        #expect(options.camera == .boat)
        #expect(options.problems.isEmpty)
        #expect(!options.resetSettings)
        #expect(parse("-uitesting", "-resetSettings").resetSettings)
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

    /// `-thermal nominal|fair|serious|critical` pins the thermal state a race draws at (#127, Debug builds); a bad or
    /// missing value is a launch problem. `-cuesOnly` counts only with `-uitesting`.
    @Test func parsesTheThermalState() {
        #expect(parse().thermal == nil)
        for thermal in LaunchOptions.Thermal.allCases {
            let options = parse("-thermal", thermal.rawValue, "-autostart")
            #expect(options.thermal == thermal && options.autostart && options.problems.isEmpty)
            #if DEBUG
            #expect(options.renderThermalState == thermal.state)
            #endif
        }
        #expect(LaunchOptions.Thermal.allCases.map(\.state) == [.nominal, .fair, .serious, .critical])
        let bad = parse("-thermal", "hot")
        #expect(bad.thermal == nil)
        #expect(bad.problems == ["-thermal hot: expected nominal, fair, serious or critical"])
        let missing = parse("-thermal", "-uitesting")
        #expect(missing.thermal == nil && missing.uiTesting)
        #expect(missing.problems == ["-thermal needs a value"])

        #expect(parse("-uitesting", "-cuesOnly").drawsCuesOnly)
        #expect(!parse("-cuesOnly").drawsCuesOnly)
        #expect(!parse("-uitesting").drawsCuesOnly)
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
            + "signed-out, underage, communication-restricted, multiplayer-restricted, offline, queued, cancelled-race, "
            + "online-results, online-results-unrated, terms-bump"])
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

    /// `-fixtures` (#62's render job): the first fixture shows at launch, the rest wait their turn.
    @Test func parsesAFixtureSequence() {
        let options = parse("-uitesting", "-fixtures", "hud-prestart,hud-racing,hud-ocs")
        #expect(options.fixture == "hud-prestart")
        #expect(options.fixtureSequence == ["hud-prestart", "hud-racing", "hud-ocs"])
        #expect(options.showingFixture("hud-ocs").fixture == "hud-ocs")
        #expect(options.showingFixture("hud-ocs").fixtureSequence == options.fixtureSequence)
        #expect(options.problems.isEmpty)
        #expect(parse("-fixture", "prestart").fixtureSequence.isEmpty)
        #expect(parse("-fixtures", ",").problems == ["-fixtures ,: expected fixture names separated by commas"])
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
        #expect(options.launchRaceConfig() == nil)
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
        let first = options.raceConfig(from: PracticeSetup())
        let second = options.raceConfig(from: PracticeSetup())
        #expect(first.seed == 1)
        #expect(second.seed == 1)
        #expect(first.windSeed == second.windSeed, "the wind seed is pinned too")
        #expect(first.windSeed == RaceConfig.windSeed(pinnedTo: 1))
    }

    /// `-laps` sails every practice race that many laps (#354: the race-finish UI test sails one); bad values are
    /// refused and the setup's fixed laps stand.
    @Test func lapsOverridesTheSettingsLaps() throws {
        let setup = PracticeSetup()
        let config = try #require(parse("-autostart", "-seed", "1", "-laps", "1").launchRaceConfig())
        #expect(config.laps == 1)
        #expect(config.setup.laps == 1)
        #expect(parse("-laps", "1").raceConfig(from: setup).laps == 1, "a practice race too")
        #expect(parse().raceConfig(from: setup).laps == PracticeSetup.laps)
        for bad in ["0", "10", "two"] {
            let options = parse("-laps", bad)
            #expect(options.laps == nil)
            #expect(options.problems.count == 1)
            #expect(options.raceConfig(from: setup).laps == PracticeSetup.laps)
        }
    }

    /// `-startSeconds` (#361) gives a practice race its start sequence too, as it does an online dev race.
    @Test func startSecondsOverridesThePracticeStartSequence() throws {
        let setup = PracticeSetup()
        let config = try #require(parse("-autostart", "-seed", "1", "-startSeconds", "10").launchRaceConfig())
        #expect(config.prestartSeconds == 10)
        #expect(config.setup.startSequenceTicks == 10 * Race.tickRate)
        #expect(parse("-startSeconds", "10").raceConfig(from: setup).prestartSeconds == 10, "a practice race too")
        #expect(parse().raceConfig(from: setup).prestartSeconds == PracticeSetup.prestartSeconds)
        for bad in ["0", "61", "ten"] {
            let options = parse("-startSeconds", bad)
            #expect(options.startSeconds == nil)
            #expect(options.problems.count == 1)
            #expect(options.raceConfig(from: setup).prestartSeconds == PracticeSetup.prestartSeconds)
        }
    }

    /// `-hideScene` (#361) is a flag: it takes no value, and the argument after it is parsed as its own.
    @Test func hideSceneIsAFlag() {
        #expect(!parse().hidesScene)
        let options = parse("-hideScene", "-seed", "1")
        #expect(options.hidesScene)
        #expect(options.seed == 1)
        #expect(options.problems.isEmpty)
        let missing = parse("-laps", "-hideScene")
        #expect(missing.hidesScene && missing.laps == nil)
        #expect(missing.problems == ["-laps needs a value"])
    }

    /// `-autostart` sails the frozen launch race, whatever the practice setup: seven Mixed bots, two laps, the
    /// bundled default files (the UI tests' eight-boat, seed-1 numbers count on it).
    @Test func autostartSailsTheSettingsRace() throws {
        let config = try #require(parse("-autostart", "-seed", "1").launchRaceConfig())
        #expect(config.seed == 1)
        #expect(config.opponents == 7)
        #expect(config.laps == 2)
        #expect(config.botTier == nil)
        #expect(config.files == .defaults)
        #expect(!config.botSailsYourBoat)
    }

    @Test func demoLetsABotSailThePlayer() throws {
        let config = try #require(parse("-demo").launchRaceConfig())
        #expect(config.botSailsYourBoat)
        #expect(config.seatControllers[0].driver?.seat == 0, "a bot controller is attached to seat 0")
        #expect(config.seatControllers.seats.allSatisfy { !$0.isHuman })
        #expect(config.setup.seats[0] == .human, "it's still your seat")
    }

    /// The race `regatta-botsuite results-seed` probes for the UI tests' seed table (#404, `scripts/pick-ui-seeds.sh`)
    /// is the `-demo -seed <n> -laps 1` launch race: seven opponents, a 60 s sequence, the bundled files, the wind
    /// pinned to the seed, a default bot sailing your boat. If this moves, so must the probe (`ResultsSeedProbe.sail`),
    /// or the table picks for another race. The probe can't import the app, so it copies the wind derivation and builds
    /// its own controllers; the literals and the probe's construction below are the only link between the two.
    @Test func theDemoRaceIsTheOneTheSeedProbeSails() throws {
        let config = try #require(parse("-demo", "-seed", "12", "-laps", "1").launchRaceConfig())
        // What the probe's `SplitMix64(seed: seed ^ 0x5749_4E44_5345_4544).next()` gives for seed 12.
        let probeWindSeed: UInt64 = 0x0011_9BE7_B9FE_E27B
        #expect(config == RaceConfig(opponents: 7, laps: 1, prestartSeconds: 60, seed: 12,
                                     windSeed: probeWindSeed, botSailsYourBoat: true))
        let probeSetup = try RaceSetup(raceSeed: RaceSeed(12), seats: [.human] + Array(repeating: .bot, count: 7),
                                       laps: 1, startSequenceTicks: 60 * Race.tickRate)
        #expect(config.setup == probeSetup)

        // The controllers: the probe's (the setup's defaults, a default bot on seat 0) against the app's practice
        // race, sailed through the start; any other bot on any seat logs other inputs.
        var probeControllers = SeatControllers(setup: probeSetup)
        probeControllers[0] = .bot(BotDriver(seat: 0, raceSeed: probeSetup.raceSeed))
        let probeRace = Race(setup: probeSetup, windSeed: WindSeed(probeWindSeed))
        for _ in 0..<(80 * Race.tickRate) { // the 60 s sequence and 20 s after the gun, as `app.tick(80)`
            probeControllers.drive(probeRace)
            probeRace.step()
        }
        let app = PracticeDriver(config: config)
        app.tick(80)
        #expect(app.log == probeRace.log)
    }

    @Test func perfIsASixteenBoatDemoRace() throws {
        let config = try #require(parse("-perf").launchRaceConfig())
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

    /// `-fps120` (#127) lets a cool ProMotion screen draw at 120: a flag of its own, Debug builds only, so a Release
    /// build always draws at 60 or less.
    @Test func fps120IsADebugFlag() {
        #expect(parse("-fps120").fps120)
        #expect(!parse().fps120)
        let valueless = parse("-thermal", "-fps120")
        #expect(valueless.fps120 && valueless.thermal == nil)
        #expect(valueless.problems == ["-thermal needs a value"])
        #expect(RenderQualityMonitor(options: parse("-fps120", "-thermal", "nominal")).policy(maxFPS: 120).fps == 120)
        #expect(RenderQualityMonitor(options: parse("-thermal", "nominal")).policy(maxFPS: 120).fps == 60)
    }
    #endif
    /// My boat's launch arguments (#136): `-myBoat` stands in for Try it's deep link.
    @Test func parsesMyBoat() {
        let options = parse("-uitesting", "-myBoat", "skiff-stars", "-keepMyBoat", "-completedRaces", "3")
        #expect(options.myBoat == DesignID("skiff-stars"))
        #expect(options.keepMyBoat)
        #expect(options.completedRaces == 3)
        // `-onlineResults` (#133): the online results harness.
        #expect(parse("-uitesting", "-fakeServices", "online-results", "-onlineResults", "-completedRaces", "9").onlineResults)
        #expect(!options.onlineResults)
        #expect(parse("-onlineResults", "-autostart").autostart, "-onlineResults takes no value")
        #expect(options.problems.isEmpty)
        #expect(!options.startsRace)
        let bad = parse("-myBoat", "skiff-gone", "-completedRaces", "-1")
        #expect(bad.myBoat == nil && bad.completedRaces == nil)
        #expect(bad.problems.count == 2)
        #expect(parse("-myBoat", "ilca-dinghy-plain").myBoat == nil, "another class's design")
        #expect(parse("-myBoat", "-keepMyBoat").problems == ["-myBoat needs a value"])
    }

}
