import os
import SwiftUI
import RegattaCore
import RegattaServices

/// The home screen, with the race sequence as a full-screen cover over it (#25).
struct RootView: View {
    let model: AppModel
    @State private var checkedLaunchArguments = false
    /// Why the `-fixture` launch couldn't start, shown instead of the menu so a UI test sees it.
    @State private var fixtureError: String?
    /// The off-water gallery a `-fixture` launch shows in place of the menu (#119).
    @State private var fixtureGallery: RenderFixture.Gallery?
    @State private var showsOnlineStub = false
    /// The Terms of Use sheet came from Race online's gate for a player who can race: I agree goes on to the queue.
    @State private var racesAfterTerms = false
    /// I agree took; what waits on the sheet runs once it's gone (`termsSheetDismissed`).
    @State private var agreedToTerms = false
    /// The `-onlineResults` harness's results stream (#133), while it shows.
    @State private var harnessResults: OnlineResults?
    @Environment(\.sceneState) private var sceneState
    @Environment(\.screenSize) private var screenSize
    @Environment(\.maximumFramesPerSecond) private var maximumFramesPerSecond
    @Environment(\.lobbyService) private var lobbyService
    @Environment(\.onlineServices) private var services
    @Environment(\.onlineStatus) private var onlineStatus

    var body: some View {
        if let fixtureError {
            Text("Render fixture failed: \(fixtureError)")
                .padding()
                .accessibilityIdentifier("fixture-error")
        } else if let fixtureGallery {
            switch fixtureGallery {
            case .livery: LiveryGalleryView()
            case .briefing(let fixture): BriefingGalleryView(fixture: fixture)
            case .practiceSetup, .pauseMenu, .myBoat, .help: MenuGalleryView(gallery: fixtureGallery, model: model)
            case .results(let stage, let rivalSkill): ResultsGalleryView(stage: stage, rivalSkill: rivalSkill)
            }
        } else if let harnessResults, let scenario = model.launchOptions.fakeServices {
            OnlineResultsHarness(
                results: harnessResults,
                entrants: RaceResultViewModel.onlineSampleEntrants(roster: harnessResults.report?.roster ?? [],
                                                                    botSeats: scenario.raceBotSeats),
                livery: model.myLivery,
                raceAgain: { raceAgain(); self.harnessResults = nil },
                home: { self.harnessResults = nil },
                tryIt: { design in self.harnessResults = nil; model.openMyBoat(trying: design) })
        } else {
            HomeView(model: model, online: HomeOnlineActions(raceOnline: raceOnline, signIn: signIn, agreeToTerms: agreeToTerms,
                                                             sheetDismissed: termsSheetDismissed))
                .onAppear(perform: autostartIfRequested)
                .raceCover(isPresented: model.phase == .raceSequence && model.race != nil) { raceCover }
                // A stub past Race online's gate until the queue (#140); Debug builds on the real services join the dev
                // server's instant race instead (#68).
                .alert("Online racing is on its way", isPresented: $showsOnlineStub) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("Sail a practice race against bots in the meantime.")
                }
        }
    }

    /// The race sequence keeps its fixed look whatever the system appearance: dark, with no status bar, and it
    /// can't be swiped down (`RaceCoverController`, which also holds the iPad orientation lock). The cover is its
    /// own presentation, so it gets the scene's environment explicitly.
    @ViewBuilder private var raceCover: some View {
        if let race = model.race {
            Group {
                switch race {
                case .practice(let session):
                    RaceView(session: session, onRestart: model.restartPractice, onExit: model.leaveRace,
                             deviceSettings: Bindable(model).deviceSettings, onSailAgain: model.sailAgain,
                             onChangeSetup: model.changeSetup,
                             onRaceOnline: { model.leaveRace(); raceOnline() })
                        .id(ObjectIdentifier(session))
                case .online(let launch):
                    OnlineLaunchView(launch: launch, onRestart: startOnlineRace, onExit: model.endRaceSequence,
                                     onRaceAgain: raceAgain, onTryIt: model.tryEarnedDesign)
                        .id(ObjectIdentifier(launch))
                case .briefing(let briefing, _):
                    BriefingView(model: briefing, onAdvance: model.finishBriefing, onBack: model.endRaceSequence)
                        .id(ObjectIdentifier(briefing))
                }
            }
            // UI tests swipe on it and check it stays. A full-size element behind the race, not a container
            // around it: a container folds into the race view's own single element (`race-viewport`) and takes
            // over its identifier, and the viewport UI tests look the race rect up by it.
            .background {
                Color.clear
                    .ignoresSafeArea()
                    .accessibilityElement()
                    .accessibilityLabel("Race")
                    .accessibilityIdentifier("race-cover")
                    .accessibilitySortPriority(-1)
            }
            .environment(\.sceneState, sceneState)
            .environment(\.screenSize, screenSize)
            .environment(\.maximumFramesPerSecond, maximumFramesPerSecond)
            // The online results report through the lobby (#26, #133).
            .environment(\.lobbyService, lobbyService)
            .environment(\.colorScheme, .dark)
            #if DEBUG
            .environment(model.tuning)
            #endif
        }
    }

    /// Development launch arguments (`LaunchOptions`): `-autostart`, `-demo`, `-perf`, `-fixture`, `-online` and `-briefing` open
    /// on the race sequence, `-myBoat` on My boat, and `-tuning` on the tuning panel (Debug builds). The cover appears
    /// without its animation, so a render fixture's frame is the same as ever.
    private func autostartIfRequested() {
        guard !checkedLaunchArguments else { return }
        checkedLaunchArguments = true
        let launchOptions = model.launchOptions
        for problem in launchOptions.problems {
            Logger(subsystem: "com.phillreeder.regatta", category: "launch").warning("Ignoring launch argument \(problem, privacy: .public)")
        }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if let name = launchOptions.fixture {
                startFixture(named: name)
            } else if launchOptions.uiTesting, launchOptions.onlineResults, let services {
                harnessResults = model.onlineResults(service: services.raceSession, raceID: nil)
            } else if launchOptions.online {
                startOnlineRace()
            } else if let briefing = launchOptions.briefing {
                model.startBriefing(config: launchOptions.raceConfig(from: RaceConfig.launch()),
                                    mode: briefing == .online ? .online(seconds: BriefingModel.Mode.onlineSeconds) : .practice)
            } else if let config = launchOptions.launchRaceConfig() {
                model.startRaceSequence(model.practiceSession(config: config))
            } else if let design = launchOptions.myBoat {
                model.openMyBoat(trying: design)
            }
            #if DEBUG
            if launchOptions.tuning { model.path = [.tuning] }
            #endif
        }
    }

    /// Home's Race online, the one way in (#138): Game Center's sign-in when signed out, then the Terms of Use sheet
    /// when due, then the queue. The e2e launches (`-online`, `-onlineHost`) skip the gate.
    private func raceOnline() {
        model.analytics.log(.practiceToOnline(.raceOnlineTapped))
        #if DEBUG
        if model.launchOptions.online || model.launchOptions.onlineHost != nil { return startOnlineRace() }
        #endif
        guard let onlineStatus else { return enterQueue() }
        Task {
            switch await onlineStatus.passGate(analytics: model.analytics) {
            case .proceed: enterQueue()
            case .terms: showTerms(thenRace: onlineStatus.access.onlineAllowed)
            case .stopped: break
            }
        }
    }

    /// The lobby area's Sign in: Game Center's sign-in, then the Terms of Use sheet when due (question 7), but not
    /// the queue.
    private func signIn() {
        guard let onlineStatus else { return }
        Task {
            guard await onlineStatus.signIn(analytics: model.analytics), onlineStatus.access.termsDue else { return }
            showTerms(thenRace: false)
        }
    }

    private func showTerms(thenRace: Bool) {
        racesAfterTerms = thenRace
        agreedToTerms = false
        model.sheet = .terms
    }

    /// The sheet's I agree: records the acceptance, then closes the sheet. If it didn't take (a newer version), the
    /// sheet stays with the version now current.
    private func agreeToTerms() {
        guard let onlineStatus else { return model.sheet = nil }
        Task {
            guard await onlineStatus.acceptTerms(analytics: model.analytics) else { return }
            agreedToTerms = true
            model.sheet = nil
        }
    }

    /// Any of Home's sheets is gone. After the terms sheet's I agree from Race online, on to the queue; Close or a
    /// swipe declines, and the lobby area offers the sheet again.
    private func termsSheetDismissed() {
        let races = agreedToTerms && racesAfterTerms
        agreedToTerms = false
        racesAfterTerms = false
        if races { enterQueue() }
    }

    /// Past the gate: the stub alert until the queue (#140). A Debug build on the real services joins the dev server's
    /// instant race instead (#68).
    private func enterQueue() {
        #if DEBUG
        if model.launchOptions.fakeServices == nil, !model.launchOptions.uiTesting { return startOnlineRace() }
        #endif
        showsOnlineStub = true
    }

    /// The online results' Race again (#24, #133): joins the queue, then home.
    private func raceAgain() {
        guard let services else { return model.leaveRace() }
        model.raceAgain(queue: services.queue)
    }

    /// A new online race: in a Debug build, the dev server's instant race on the Settings page's host or
    /// `-onlineHost`, with `-raceSeconds` and `-startSeconds` if given.
    private func startOnlineRace() {
        #if DEBUG
        let launchOptions = model.launchOptions
        let server = RaceServer(address: launchOptions.onlineHost
            ?? UserDefaults.standard.string(forKey: RaceServer.addressDefaultsKey) ?? RaceServer.defaultAddress)
        let (raceSeconds, startSeconds) = (launchOptions.raceSeconds, launchOptions.startSeconds)
        let launch = OnlineLaunch(server: server, haptics: model.haptics, sound: model.sound, controls: model.controls,
                                  rulesSeen: model.rulesSeen, hints: model.hintEngine,
                                  onHintRetired: model.logsHintRetired) {
            try await DevInstantRace.ticket(server: server, raceSeconds: raceSeconds, startSeconds: startSeconds)
        }
        model.startRaceSequence(.online(launch))
        Task { await launch.start() }
        #endif
    }

    /// `-fixture <name>`: replays the fixture's log to its freeze tick and freezes the race there (#62).
    private func startFixture(named name: String) {
        do {
            if let gallery = try RenderFixture.gallery(named: name) {
                fixtureGallery = gallery
                return
            }
            let (fixture, log) = try RenderFixture.load(named: name)
            model.startRaceSequence(try GameSession(fixture: fixture, log: log))
        } catch {
            Logger(subsystem: "com.phillreeder.regatta", category: "launch").error("Render fixture \(name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            fixtureError = String(describing: error)
        }
    }
}
