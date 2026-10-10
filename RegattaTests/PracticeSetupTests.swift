import Foundation
import Testing
import RegattaBots
import RegattaCore
@testable import Regatta

/// The practice setup (#131, #25, #19): its choices kept per device, the fixed laps and start sequence, the bot tier's
/// skill band, the venues and their conditions, and the practice race routes (Restart, Sail again, Change setup,
/// Leave race).
@MainActor @Suite struct PracticeSetupTests {
    /// A private defaults domain, removed after `body`.
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "PracticeSetupTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    private func options(_ arguments: String...) -> LaunchOptions {
        LaunchOptions(arguments: ["/path/to/Regatta"] + arguments)
    }

    /// A fresh install's setup is Hollin Bay, Random, Mixed and 10 boats; the model keeps every choice on the device
    /// and the next launch reads them back; a stored value it can't use reads as its default. Whatever the choices,
    /// the race sails the fixed laps (#245's three) and the 60 s start sequence.
    @Test func persistsChoicesDefaultFleet10LapsAndSequenceFixed() throws {
        try withDefaults { defaults in
            let fresh = PracticeSetup(defaults: defaults)
            #expect(fresh == PracticeSetup())
            #expect(fresh.venue == "hollin-bay" && fresh.conditions == .random && fresh.botTier == nil)
            #expect(fresh.fleetSize == 10)
            let config = fresh.config(seed: 1, windSeed: 2)
            #expect(config.opponents == 9)
            #expect(config.laps == RaceSetup.defaultLaps && config.prestartSeconds == 60)
            #expect(config.setup.startSequenceTicks == 60 * Race.tickRate)

            let model = AppModel(launchOptions: options(), defaults: defaults)
            #expect(model.practiceSetup == PracticeSetup())
            model.practiceSetup.venue = "saltings-reach"
            model.practiceSetup.conditions = .named("gusty-offshore")
            model.practiceSetup.botTier = .regional
            model.practiceSetup.fleetSize = 16

            let relaunched = AppModel(launchOptions: options(), defaults: defaults)
            #expect(relaunched.practiceSetup == model.practiceSetup, "the choices weren't kept")
            let chosen = relaunched.practiceSetup.config(seed: 3, windSeed: 4)
            #expect(chosen.opponents == 15 && chosen.botTier == .regional)
            #expect(chosen.laps == RaceSetup.defaultLaps && chosen.prestartSeconds == 60, "laps and the sequence are fixed")
            #expect(chosen.files.venue.id == "saltings-reach" && chosen.files.conditions.id == "gusty-offshore")

            // UI tests start from the defaults, whatever the device keeps.
            #expect(AppModel(launchOptions: options("-uitesting"), defaults: defaults).practiceSetup == PracticeSetup())

            defaults.set("atlantis", forKey: PracticeSetup.Key.venue.rawValue)
            defaults.set("dust-storm", forKey: PracticeSetup.Key.conditions.rawValue)
            defaults.set("olympic", forKey: PracticeSetup.Key.botTier.rawValue)
            defaults.set(17, forKey: PracticeSetup.Key.fleetSize.rawValue)
            #expect(PracticeSetup(defaults: defaults) == PracticeSetup())
            defaults.set(1, forKey: PracticeSetup.Key.fleetSize.rawValue)
            #expect(PracticeSetup(defaults: defaults).fleetSize == 10)
        }
    }

    /// A tier's bots all sail with a skill inside its band; you sail your own seat.
    @Test func aTiersBotsSailInsideItsSkillBand() {
        for tier in BotTier.allCases {
            var setup = PracticeSetup()
            setup.botTier = tier
            setup.fleetSize = 16
            for seed in UInt64(1)...4 {
                let config = setup.config(seed: seed, windSeed: seed)
                let controllers = config.seatControllers
                #expect(controllers[0].isHuman)
                for seat in 1..<16 {
                    let skill = controllers[seat].driver?.style.skill
                    #expect(skill.map(tier.skillBand.contains) == true, "\(tier) seat \(seat): skill \(String(describing: skill))")
                }
            }
        }
    }

    /// Mixed sails exactly today's fleet: the bots `SeatControllers(setup:)` draws from all three tiers.
    @Test func mixedIsTodaysSeatControllers() {
        let config = PracticeSetup().config(seed: 131, windSeed: 7)
        #expect(config.botTier == nil)
        let mixed = config.seatControllers
        let today = SeatControllers(setup: config.setup)
        #expect(mixed.seats.count == today.seats.count)
        for seat in today.seats.indices {
            #expect(mixed[seat].isHuman == today[seat].isHuman)
            #expect(mixed[seat].driver?.style == today[seat].driver?.style, "seat \(seat)")
        }
    }

    /// The three v1.0 venues by name, each with the conditions its pairings name; every venue on every option
    /// (Random among them) resolves to files the race can load. A venue change drops conditions it can't have.
    @Test func everyVenueAndConditionsResolves() throws {
        #expect(PracticeVenue.all.map(\.id) == ["hollin-bay", "saltings-reach", "fellmere"])
        for venue in PracticeVenue.all {
            #expect(!venue.name.isEmpty)
            #expect(venue.conditions.count == 2, "\(venue.id)")
            let choices = [PracticeSetup.ConditionsChoice.random] + venue.conditions.map { .named($0.id) }
            for choice in choices {
                var setup = PracticeSetup()
                setup.venue = venue.id
                setup.conditions = choice
                let config = setup.config(seed: 25, windSeed: 11)
                #expect(config.files.venue == venue.ref)
                if case .named(let id) = choice { #expect(config.files.conditions.id == id) }
                #expect(venue.conditions.contains { $0.ref == config.files.conditions })
                _ = try RaceFiles(resolving: config.setup)
            }
        }

        var setup = PracticeSetup()
        setup.venue = "hollin-bay"
        setup.conditions = .named("sea-breeze")
        setup.venue = "fellmere"
        #expect(setup.conditions == .random, "Fellmere has no sea breeze")
        setup.conditions = .named("gusty-offshore")
        setup.venue = "saltings-reach"
        #expect(setup.conditions == .named("gusty-offshore"), "a choice the new venue has stays")
    }

    /// Random draws the conditions from the race seed: the same seed, the same conditions, so `-seed` reproduces it,
    /// and over seeds both of the venue's.
    @Test func randomConditionsFollowTheRaceSeed() {
        let setup = PracticeSetup()
        #expect(setup.config(seed: 9, windSeed: 1).files.conditions == setup.config(seed: 9, windSeed: 2).files.conditions)
        let drawn = Set((UInt64(0)..<32).map { setup.config(seed: $0, windSeed: 0).files.conditions.id })
        #expect(drawn == Set(setup.practiceVenue.conditions.map(\.id)))
    }

    /// Restart replays the same race (same seeds and setup) with no briefing.
    @Test func restartReplaysTheSameConfig() throws {
        let model = AppModel(launchOptions: options("-uitesting"))
        model.practiceSetup.botTier = .club
        model.beginPractice()
        let briefed = try #require(model.practiceConfig)
        model.finishBriefing()
        let first = try #require(model.session)

        model.restartPractice()
        let second = try #require(model.session)
        #expect(second !== first)
        #expect(model.briefing == nil, "Restart went through the briefing")
        #expect(model.practiceConfig == briefed)
        let firstSetup = try #require(first.driver as? PracticeDriver).log.header.setup
        let secondSetup = try #require(second.driver as? PracticeDriver).log.header.setup
        #expect(secondSetup == firstSetup)
    }

    /// Sail again draws a new seed and goes through the briefing.
    @Test func sailAgainDrawsANewSeed() throws {
        let model = AppModel(launchOptions: options("-uitesting"))
        model.beginPractice()
        let first = try #require(model.practiceConfig)
        model.finishBriefing()

        model.sailAgain()
        let briefing = try #require(model.briefing, "Sail again skipped the briefing")
        let second = try #require(model.practiceConfig)
        #expect(second.seed != first.seed)
        #expect(briefing.setup.raceSeed == RaceSeed(second.seed))
    }

    /// Change setup returns to the practice setup page; Leave race goes home.
    @Test func changeSetupAndLeaveRaceRoutes() {
        let model = AppModel(launchOptions: options("-uitesting"))
        model.path = [.practiceSetup]
        model.beginPractice()
        model.finishBriefing()
        model.changeSetup()
        #expect(model.phase == .home && model.race == nil)
        #expect(model.path == [.practiceSetup])

        model.beginPractice()
        model.finishBriefing()
        model.leaveRace()
        #expect(model.phase == .home && model.race == nil)
        #expect(model.path.isEmpty)
    }

    /// The app going to the background pauses a practice race (#25), but not a finished one.
    @Test func backgroundPausesAPracticeRace() {
        let session = GameSession(config: PracticeSetup().config(seed: 1, windSeed: 1))
        session.pauseForBackground()
        #expect(session.isPaused)
        session.setPaused(false)
        session.playerDone = true
        session.pauseForBackground()
        #expect(!session.isPaused)
    }

    /// The setup page and the pause menu render as off-water galleries (`MenuGalleryView`).
    @Test func theMenuFixturesAreGalleries() throws {
        #expect(try RenderFixture.gallery(named: "practice-setup", in: RenderFixtureTests.fixtures) == .practiceSetup)
        #expect(try RenderFixture.gallery(named: "pause-menu", in: RenderFixtureTests.fixtures) == .pauseMenu)
    }

    /// My boat's fixtures (#136) carry their own livery, races and lock: a saved free design, and a starter after
    /// fleet lock. Paid and earned designs have no art until #169, which brings back a shop fixture.
    @Test func theMyBoatFixturesAreGalleries() throws {
        func model(_ name: String) throws -> MyBoatModel {
            guard case .myBoat(let fixture)? = try RenderFixture.gallery(named: name, in: RenderFixtureTests.fixtures) else {
                Issue.record("\(name) isn't a My boat gallery")
                throw CancellationError()
            }
            return fixture.model()
        }
        let saved = try model("my-boat")
        #expect(saved.action == .saved)
        #expect(saved.section == .colours)
        let locked = try model("my-boat-locked")
        #expect(locked.action == .fleetLocked)
        #expect(locked.section == .decal)
        #expect(locked.listedDesigns.contains { $0.id == locked.design }, "the starter is listed")
    }
}

extension PracticeSetupTests {
    /// #235: the setup's rivals' skill comes from your practice history, clamped to its tier's band (the Mixed union
    /// for a Mixed fleet); none without a history. A config with a rival skill has two rivals among its bots, sailing
    /// exactly that skill; one without has none and its bots are the setup's draw.
    @Test func rivalSkillFromHistoryClampedToTheTier() throws {
        var setup = PracticeSetup()
        #expect(setup.rivalSkill(history: []) == nil)
        let wins = (0..<5).map { _ in PracticeFinish(place: 1, fleetSize: 10, tier: nil) }
        #expect(setup.rivalSkill(history: wins) == BotTier.mixedBand.upperBound)
        setup.botTier = .club
        #expect(setup.rivalSkill(history: wins) == BotTier.club.skillBand.upperBound)
        let lasts = (0..<5).map { _ in PracticeFinish(place: 10, fleetSize: 10, tier: nil) }
        setup.botTier = .national
        #expect(setup.rivalSkill(history: lasts) == BotTier.national.skillBand.lowerBound)

        let plain = setup.config(seed: 4, windSeed: 5)
        #expect(plain.rivalSkill == nil && plain.rivalSeats.isEmpty && plain.roster.rivals.isEmpty)
        let config = setup.config(seed: 4, windSeed: 5, rivalSkill: 0.85)
        #expect(config.rivalSkill == 0.85)
        #expect(config.rivalSeats.count == 2)
        #expect(config.roster.rivals == config.rivalSeats)
        let setupOfRace = config.setup
        for seat in setupOfRace.seats.indices where setupOfRace.seats[seat] == .bot {
            let style = config.seatControllers[seat].driver?.style
            if config.rivalSeats.contains(seat) {
                #expect(style == BotDriver(seat: seat, raceSeed: setupOfRace.raceSeed, skill: 0.85).style)
            } else {
                #expect(style == plain.seatControllers[seat].driver?.style)
            }
        }
        #expect(options().raceConfig(from: setup, rivalSkill: 0.7).rivalSkill == 0.7)
        #expect(options().raceConfig(from: setup).rivalSkill == nil)
    }

    #if DEBUG
    /// The race `PracticeUITests.testFifteenBotRaceRunsFullLength` launches, sailed here without the UI (#473): sixteen
    /// boats from the setup on seed 1, one lap from a 10 s start on a 120 m beat (`-beatMetres 120`), nobody touching
    /// the screen. It closes 6,713 ticks in on skiff@8 (the first finish at 3,113, then the 120 s finish window in
    /// full: your boat never starts); on the rules' 360 m beat it took 10,498 (10,531 on skiff@7). The UI test's
    /// watch is sized for `sixteenBoatTickBudget`, so a sim or bot change that makes the race longer fails here,
    /// where it says so, and not as a watch that ran out in CI.
    @Test func sixteenBoatUITestRaceClosesInsideItsTickBudget() throws {
        let model = AppModel(launchOptions: options("-uitesting", "-seed", "1", "-laps", "1", "-startSeconds", "10",
                                                    "-beatMetres", "120"))
        model.practiceSetup.fleetSize = 16
        model.beginPractice()
        model.finishBriefing()
        defer { model.leaveRace() }
        let driver = try #require(model.session?.driver as? PracticeDriver)
        #expect(driver.course.beat == 120)
        #expect(driver.currentFrame.boats.count == 16)
        var ticks = 0
        var firstFinish: Int?
        while !driver.currentFrame.isOver {
            let frames = driver.tick(1)
            try #require(!frames.isEmpty, "the race stopped before its close")
            for frame in frames {
                ticks += 1
                if firstFinish == nil, frame.boats.contains(where: { $0.status == .finished }) { firstFinish = ticks }
            }
        }
        #expect(try #require(firstFinish) + 120 * Race.tickRate == ticks, "the finish window ran in full")
        #expect(ticks <= Self.sixteenBoatTickBudget, "the race took \(ticks) ticks: PracticeUITests' watch is sized for \(Self.sixteenBoatTickBudget)")
    }

    /// The ticks `PracticeUITests.testFifteenBotRaceRunsFullLength` sizes its watch for, the start sequence included:
    /// at the slowest pace CI has run the race at, 28 ticks a second, they take 254 s of its 330 s watch.
    static let sixteenBoatTickBudget = 7100
    #endif
}
