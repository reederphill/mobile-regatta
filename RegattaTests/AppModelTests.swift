import Foundation
import SwiftUI
import Testing
import UIKit
import RegattaBots
import RegattaCore
@testable import Regatta

@MainActor @Suite struct AppModelTests {
    private static let config = RaceConfig(opponents: 1, prestartSeconds: 30, seed: 1, windSeed: RaceConfig.windSeed(pinnedTo: 1))

    @Test func startsOnTheHomeScreen() {
        let model = AppModel()
        #expect(model.phase == .home)
        #expect(model.path.isEmpty)
        #expect(model.sheet == nil)
        #expect(model.race == nil)
    }

    @Test func dismissAllClearsPathAndSheet() {
        let model = AppModel()
        model.path = [.practiceSetup, .myBoat]
        model.sheet = .signIn

        model.dismissAll()
        #expect(model.path.isEmpty)
        #expect(model.sheet == nil)
    }

    /// The phase drives `SceneState`, which drives the root controller's orientation lock (G5).
    @Test func raceSequencePhaseLocksOrientation() {
        let state = SceneState()
        let controller = RootHostingController(sceneState: state, screenSize: CGSize(width: 402, height: 874))
        let model = AppModel(sceneState: state)
        #expect(!controller.isOrientationLocked)

        model.startRaceSequence(GameSession(config: Self.config))
        #expect(model.phase == .raceSequence)
        #expect(state.isRaceSequenceShowing)
        #expect(controller.isOrientationLocked)
        if #available(iOS 26.0, *) { #expect(controller.prefersInterfaceOrientationLocked) }

        model.endRaceSequence()
        #expect(model.phase == .home)
        #expect(model.race == nil)
        #expect(!state.isRaceSequenceShowing)
        #expect(!controller.isOrientationLocked)
        if #available(iOS 26.0, *) { #expect(!controller.prefersInterfaceOrientationLocked) }
    }

    /// Starting a race dismisses the sheet but keeps the pushed pages, so quitting returns to practice setup.
    @Test func aRaceKeepsThePathUnderTheCover() {
        let model = AppModel()
        model.path = [.practiceSetup]
        model.sheet = .boatCard

        model.startRaceSequence(GameSession(config: Self.config))
        #expect(model.sheet == nil)
        #expect(model.path == [.practiceSetup])

        model.endRaceSequence()
        #expect(model.path == [.practiceSetup])
    }

    /// An online race (#68) goes through the same race sequence, and quitting it returns home.
    @Test func anOnlineRaceUsesTheRaceSequence() {
        let state = SceneState()
        let model = AppModel(sceneState: state)
        let launch = OnlineLaunch(server: RaceServer(address: RaceServer.defaultAddress)) { [] }

        model.startRaceSequence(.online(launch))
        #expect(model.phase == .raceSequence)
        #expect(state.isRaceSequenceShowing)
        #expect(model.session == nil)

        model.endRaceSequence()
        #expect(model.phase == .home)
        #expect(model.race == nil)
        #expect(!state.isRaceSequenceShowing)
    }

    /// Restart replays the practice race shown, a new session on the same setup and seed.
    @Test func restartReplaysThePracticeRace() throws {
        let options = LaunchOptions(arguments: ["/path/to/Regatta", "-uitesting", "-seed", "7"])
        let model = AppModel(launchOptions: options)
        model.practiceSetup.fleetSize = 4

        model.beginPractice()
        model.finishBriefing()
        let first = try #require(model.session)
        #expect(first.roster.entries.count == 4)

        model.restartPractice()
        let second = try #require(model.session)
        #expect(second !== first)
        #expect(second.roster.entries.count == 4)
        #expect(model.phase == .raceSequence)
    }

    /// The setup's Start goes to the briefing (#25, #130), which waits for Ready; Ready starts the race it briefed, on
    /// the same seed and files.
    @Test func beginPracticeBriefsThenReadyStartsThatRace() throws {
        let options = LaunchOptions(arguments: ["/path/to/Regatta", "-uitesting", "-seed", "7"])
        let model = AppModel(launchOptions: options)
        model.practiceSetup.fleetSize = 4

        model.beginPractice()
        #expect(model.phase == .raceSequence)
        #expect(model.session == nil)
        let briefing = try #require(model.briefing)
        #expect(briefing.mode == .practice)
        #expect(briefing.fleet.count == 4)
        #expect(briefing.laps == PracticeSetup.laps)
        #expect(briefing.setup.raceSeed == RaceSeed(7))

        model.finishBriefing()
        let session = try #require(model.session)
        #expect(model.briefing == nil)
        #expect(session.roster.entries.count == 4)
        #expect(model.phase == .raceSequence)

        model.finishBriefing()
        #expect(model.session === session, "no briefing, nothing to finish")
    }

    /// The briefing fades the menu music as it starts (#126, #130), through the model's injected music.
    @Test func briefingFadesTheAppsMenuMusic() throws {
        final class Music: MenuMusic {
            var fadeOuts = 0
            func fadeOut() { fadeOuts += 1 }
        }
        let model = AppModel(launchOptions: LaunchOptions(arguments: ["/path/to/Regatta", "-uitesting"]))
        let music = Music()
        model.menuMusic = music
        model.startBriefing(config: Self.config, mode: .online(seconds: 15))
        let briefing = try #require(model.briefing)
        #expect(music.fadeOuts == 0)
        briefing.begin()
        #expect(music.fadeOuts == 1)
        #expect(briefing.displayedSeconds == 15)
    }

    /// The menu music (#126): playing from launch, faded by a practice or online race entered without a briefing
    /// (the briefing fades it itself), and back on returning home.
    @Test func menuMusicPlaysInTheMenusOnly() throws {
        let name = "AppModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let music = RecordingMusic()
        let model = AppModel(launchOptions: LaunchOptions(arguments: ["/path/to/Regatta", "-uitesting"]),
                             defaults: defaults, audio: AppAudio(effects: SilentSoundOutput(), music: music))
        #expect(music.calls == ["in"], "at launch")
        model.startBriefing(config: Self.config, mode: .practice)
        #expect(music.calls == ["in"], "the briefing fades it as it begins")
        model.briefing?.begin()
        #expect(music.calls == ["in", "out"])
        model.finishBriefing()
        model.leaveRace()
        #expect(music.calls == ["in", "out", "in"], "home again")
        model.startRaceSequence(model.practiceSession(config: Self.config))
        #expect(music.calls == ["in", "out", "in", "out"], "a race without a briefing")
        model.endRaceSequence()
        model.startRaceSequence(.online(OnlineLaunch(server: RaceServer(address: "localhost:1")) { [] }))
        #expect(music.calls == ["in", "out", "in", "out", "in", "out"], "an online race")
    }

    @Test func lobbyPanelFollowsConnectivityThenAccount() {
        var status = LobbyStatus()
        #expect(LobbyPanelState(isOnline: false, status: status) == .offline)
        #expect(LobbyPanelState(isOnline: true, status: status) == .signIn)
        status.isSignedIn = true
        #expect(LobbyPanelState(isOnline: true, status: status) == .acceptTerms)
        status.hasAcceptedTerms = true
        #expect(LobbyPanelState(isOnline: true, status: status) == .lobby)
        status.hidesChat = true
        status.queuedPlayers = 5
        #expect(LobbyPanelState(isOnline: true, status: status) == .chatHidden(queuedPlayers: 5))
        #expect(LobbyPanelState(isOnline: false, status: status) == .offline)
        // A player Game Center keeps from chatting sees the queue and leaderboard, whatever the setting (#34).
        status.hidesChat = false
        status.canChat = false
        #expect(LobbyPanelState(isOnline: true, status: status) == .chatHidden(queuedPlayers: 5))
    }
    /// A model on defaults of its own, so your livery is the test's.
    private static func isolatedModel() -> (AppModel, UserDefaults) {
        let name = "AppModelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (AppModel(launchOptions: LaunchOptions(), defaults: defaults), defaults)
    }

    /// My boat's saved livery (#136) is kept on the device and is what your boat wears in the briefing and the race.
    @Test func theSavedLiveryReachesTheBriefingAndTheRace() throws {
        let (model, defaults) = Self.isolatedModel()
        let mine = Livery(design: DesignID("skiff-stripe"),
                          colours: [SwatchID("lavender"), SwatchID("white"), SwatchID("charcoal")], sailNumber: 4321)
        #expect(model.myLivery != mine)
        model.myBoat.select(mine.design)
        model.myBoat.setColour(SwatchID("lavender"), for: .deck)
        model.myBoat.setColour(SwatchID("white"), for: .accent)
        model.myBoat.setColour(SwatchID("charcoal"), for: .sail)
        model.myBoat.numberText = "4321"
        model.myBoat.save()
        #expect(model.myLivery == mine)
        #expect(LiveryStore(defaults: defaults).load(boatClass: "skiff") == mine)

        let config = PracticeSetup().config(seed: 1, windSeed: 1)
        let briefing = model.briefingModel(config: config, mode: .practice)
        #expect(briefing.fleet[briefing.mySeat].livery == mine)
        let session = model.practiceSession(config: config)
        #expect(session.driver.liveries[session.driver.myBoatIndex] == mine)
    }

    /// Try it and `-myBoat` open My boat with the design tried on, the draft otherwise the saved livery; an undrawn
    /// design opens on the saved one (#169 draws it).
    @Test func openMyBoatTriesTheDesignOn() throws {
        let (model, _) = Self.isolatedModel()
        model.sheet = .lastRace
        let other = try #require(model.myBoat.listedDesigns.first { $0.id != model.myLivery.design }).id
        model.openMyBoat(trying: other)
        #expect(model.path == [.myBoat])
        #expect(model.sheet == nil)
        #expect(model.myBoat.design == other)
        #expect(model.myBoat.saved == model.myLivery)
        model.openMyBoat(trying: DesignID("skiff-tiger"))
        #expect(model.myBoat.design == model.myLivery.design, "an undrawn design isn't tried on")
    }

    /// Fleet lock (#140 sets it) makes My boat inert.
    @Test func liveryLockReachesMyBoat() {
        let (model, _) = Self.isolatedModel()
        model.isLiveryLocked = true
        #expect(model.myBoat.action == .fleetLocked)
    }
}
