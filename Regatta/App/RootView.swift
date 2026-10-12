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
    /// The terms' version the sheet opened with: what its I agree accepts (#161).
    @State private var termsShown: TermsVersion?
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The fleet-lock takeover is showing (#140): the locked fleet's briefing.
    private var isTakeover: Bool { model.briefing?.isFleetLocked == true }

    var body: some View {
        if let fixtureError {
            Text("Render fixture failed: \(fixtureError)")
                .padding()
                .accessibilityIdentifier("fixture-error")
        } else if let fixtureGallery {
            switch fixtureGallery {
            case .livery: LiveryGalleryView()
            case .briefing(let fixture): BriefingGalleryView(fixture: fixture)
            case .briefingLocked: BriefingGalleryView(fixture: nil)
            case .practiceSetup, .pauseMenu, .myBoat, .help, .queueBar: MenuGalleryView(gallery: fixtureGallery, model: model)
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
                // The takeover cross-fades in over whatever was up (0.25 s), where a race you chose slides in.
                .raceCover(isPresented: model.phase == .raceSequence && model.race != nil,
                           fadesIn: isTakeover && !reduceMotion) { raceCover }
                // A stub past Race online's gate while the queue has no service to join (#162); Debug builds on the real
                // services join the dev server's instant race instead (#68). On the fakes, the queue (#140).
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
            // A stack, so a practice race or its briefing fades out under the takeover's briefing fading in.
            ZStack {
                switch race {
                case .practice(let session):
                    // Queued, the chip rides over the practice race (#140); a render fixture draws its own.
                    RaceView(session: session, onRestart: model.restartPractice, onExit: model.leaveRace,
                             deviceSettings: Bindable(model).deviceSettings, onSailAgain: model.sailAgain,
                             onChangeSetup: model.changeSetup,
                             onRaceOnline: { model.leaveRace(); raceOnline() },
                             queueChip: session.fixtureQueueChip.map {
                                 QueueChip(state: $0.state, moment: RenderFixture.QueueFixture.moment, leave: {})
                             } ?? queueChip)
                        .id(ObjectIdentifier(session))
                case .online(let launch):
                    OnlineLaunchView(launch: launch, onRestart: startOnlineRace, onExit: model.endRaceSequence,
                                     onRaceAgain: raceAgain, onTryIt: model.tryEarnedDesign)
                        .id(ObjectIdentifier(launch))
                case .briefing(let briefing, _):
                    if briefing.isFleetLocked, let queue = onlineStatus?.queue {
                        // The takeover (#140): the locked fleet's briefing, with Leave; its end is the queue's.
                        BriefingView(model: briefing, onAdvance: queue.briefingEnded, onBack: {},
                                     leave: BriefingLeave(isConfirming: queue.takeover?.isConfirmingLeave ?? false,
                                                          isReconnecting: queue.takeover?.isReconnecting ?? false,
                                                          ask: queue.askToLeave, confirm: queue.leaveRace, stay: queue.stay))
                            .id(ObjectIdentifier(briefing))
                    } else {
                        BriefingView(model: briefing, onAdvance: model.finishBriefing, onBack: model.endRaceSequence)
                            .id(ObjectIdentifier(briefing))
                            // Queued, the chip rides over the practice briefing too (#140).
                            .safeAreaInset(edge: .top, spacing: 0) {
                                if let chip = queueChip {
                                    chip.frame(maxWidth: .infinity).background(ChromePalette.background)
                                }
                            }
                    }
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: RaceCoverController.fadeDuration), value: isTakeover)
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

    /// The queue's chip, while queued over a practice race or its briefing (#140).
    private var queueChip: QueueChip? {
        guard let queue = onlineStatus?.queue, queue.showsChip, let bar = queue.bar else { return nil }
        return QueueChip(state: bar, leave: queue.leave)
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
        #if DEBUG
        if !launchOptions.taps.isEmpty { Task { await play(launchOptions.taps) } }
        #endif
    }

    #if DEBUG
    /// `-tap`: Home's controls tapped at launch, for a local screenshot of a state only a tap reaches (#161). I agree
    /// waits for the sheet Race online's gate puts up, and gives up if none comes.
    private func play(_ taps: [LaunchOptions.LaunchTap]) async {
        for tap in taps {
            // Home is up, and the launch's own reads (the player, the terms, the session's first try) are in.
            try? await Task.sleep(for: .seconds(1))
            switch tap {
            case .raceOnline: raceOnline()
            case .termsAgree:
                let sheetUp = ContinuousClock.now + .seconds(5)
                while model.sheet != .terms, ContinuousClock.now < sheetUp { try? await Task.sleep(for: .milliseconds(100)) }
                if model.sheet == .terms { agreeToTerms() }
            case .settings: model.path = [.settings]
            case .practiceSetup: model.path = [.practiceSetup]
            case .startPractice: model.beginPractice()
            case .ready: model.finishBriefing()
            case .takeover:
                let lockedBy = ContinuousClock.now + .seconds(300)
                while onlineStatus?.queue.takeover == nil, ContinuousClock.now < lockedBy { try? await Task.sleep(for: .milliseconds(100)) }
            case .briefingLeave: onlineStatus?.queue.askToLeave()
            case .home:
                let homeBy = ContinuousClock.now + .seconds(300)
                while model.phase != .home, ContinuousClock.now < homeBy { try? await Task.sleep(for: .milliseconds(100)) }
            case .connectionLost: onlineStatus?.queue.connectionChanged(isOnline: false)
            case .connectionRegained: onlineStatus?.queue.connectionChanged(isOnline: true)
            }
        }
    }
    #endif

    /// Home's Race online, the one way in (#138): Game Center's sign-in when signed out, then the Terms of Use sheet
    /// when due, then the queue. The e2e launches (`-online`, `-onlineHost`) skip the gate.
    private func raceOnline() {
        model.analytics.log(.practiceToOnline(.raceOnlineTapped))
        // The last notice was about the last try.
        model.notice = nil
        #if DEBUG
        // A dev identity (#161) goes through the gate like a player.
        let skipsGate = model.launchOptions.online || (model.launchOptions.onlineHost != nil && model.launchOptions.devIdentity == nil)
        if skipsGate { return startOnlineRace() }
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
        termsShown = onlineStatus?.lobbyStatus.termsVersion
        model.sheet = .terms
    }

    /// The sheet's I agree: records the acceptance, then closes the sheet. If it didn't take (a newer version), the
    /// sheet stays with the version now current.
    private func agreeToTerms() {
        guard let onlineStatus else { return model.sheet = nil }
        Task {
            // The version the sheet showed, not whatever is current by the tap (#161).
            guard await onlineStatus.acceptTerms(termsShown, analytics: model.analytics) else {
                termsShown = onlineStatus.lobbyStatus.termsVersion
                return
            }
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
        onlineStatus?.termsSheetClosed()
        if races { enterQueue() }
    }

    /// Past the gate: the queue (#140), whose bar shows the wait. The queue's service can't be joined until #162, so
    /// off the fakes it is still the stub alert, and a Debug build on the real services joins the dev server's instant
    /// race instead (#68).
    private func enterQueue() {
        guard model.launchOptions.fakeServices != nil, let queue = onlineStatus?.queue else {
            #if DEBUG
            if model.launchOptions.fakeServices == nil, !model.launchOptions.uiTesting { return startOnlineRace() }
            #endif
            showsOnlineStub = true
            return
        }
        Task { await queue.join() }
    }

    /// The online results' Race again (#24, #133): home, with the queue joining.
    private func raceAgain() {
        guard let queue = onlineStatus?.queue else { return model.leaveRace() }
        model.raceAgain(queue: queue)
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
