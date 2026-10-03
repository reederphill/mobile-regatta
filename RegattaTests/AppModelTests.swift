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

    /// Practice and restarts use the setup, on the pinned seed when there is one.
    @Test func practiceUsesTheSetup() throws {
        let options = LaunchOptions(arguments: ["/path/to/Regatta", "-seed", "7"])
        let model = AppModel(launchOptions: options)
        model.settings.opponents = 3
        model.settings.laps = 1

        model.startPractice()
        let first = try #require(model.session)
        #expect(first.roster.entries.count == 4)

        model.startPractice()
        let second = try #require(model.session)
        #expect(second !== first)
        #expect(model.phase == .raceSequence)
    }

    /// The setup's Start goes to the briefing (#25, #130), which waits for Ready; Ready starts the race it briefed, on
    /// the same seed and files.
    @Test func beginPracticeBriefsThenReadyStartsThatRace() throws {
        let options = LaunchOptions(arguments: ["/path/to/Regatta", "-uitesting", "-seed", "7"])
        let model = AppModel(launchOptions: options)
        model.settings.opponents = 3
        model.settings.laps = 1

        model.beginPractice()
        #expect(model.phase == .raceSequence)
        #expect(model.session == nil)
        let briefing = try #require(model.briefing)
        #expect(briefing.mode == .practice)
        #expect(briefing.fleet.count == 4)
        #expect(briefing.laps == 1)
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
}
