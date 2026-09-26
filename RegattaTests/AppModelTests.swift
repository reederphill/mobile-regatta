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
    }
}
