import os
import SwiftUI
import RegattaCore

struct RaceSettings {
    var opponents = 7
    var laps = 2
    var prestartSeconds = 60.0

    var config: RaceConfig {
        // A practice race draws both seeds on the device, independently; online races get the race
        // seed from the server, which keeps the wind seed to itself (ADR 0001).
        RaceConfig(opponents: opponents, laps: laps, prestartSeconds: prestartSeconds,
                   seed: .random(in: .min ... .max), windSeed: .random(in: .min ... .max))
    }
}

/// The home screen, with the race sequence as a full-screen cover over it (#25).
struct RootView: View {
    let model: AppModel
    @State private var checkedLaunchArguments = false
    /// Why the `-fixture` launch couldn't start, shown instead of the menu so a UI test sees it.
    @State private var fixtureError: String?
    @State private var showsOnlineStub = false
    @Environment(\.sceneState) private var sceneState
    @Environment(\.screenSize) private var screenSize

    var body: some View {
        if let fixtureError {
            Text("Render fixture failed: \(fixtureError)")
                .padding()
                .accessibilityIdentifier("fixture-error")
        } else {
            HomeView(model: model, onRaceOnline: { showsOnlineStub = true })
                .onAppear(perform: autostartIfRequested)
                .fullScreenCover(isPresented: isRaceSequenceShowing) { raceCover }
                // A stub until online racing lands (#68).
                .alert("Online racing is on its way", isPresented: $showsOnlineStub) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("Sail a practice race against bots in the meantime.")
                }
        }
    }

    private var isRaceSequenceShowing: Binding<Bool> {
        Binding(get: { model.phase == .raceSequence && model.session != nil },
                set: { showing in if !showing { model.endRaceSequence() } })
    }

    /// The race sequence keeps its fixed look whatever the system appearance: dark, with no status bar, and it
    /// can't be swiped down. The cover is its own presentation, so it gets the scene's environment explicitly.
    @ViewBuilder private var raceCover: some View {
        if let session = model.session {
            RaceView(session: session, onRestart: model.startPractice, onExit: model.endRaceSequence)
                .id(ObjectIdentifier(session))
                // UI tests swipe on it and check it stays.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("race-cover")
                .environment(\.sceneState, sceneState)
                .environment(\.screenSize, screenSize)
                .preferredColorScheme(.dark)
                .statusBarHidden()
                .interactiveDismissDisabled()
        }
    }

    /// Development launch arguments (`LaunchOptions`): `-autostart`, `-demo`, `-perf` and `-fixture` open on the
    /// race sequence. The cover appears without its animation, so a render fixture's frame is the same as ever.
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
            } else if let config = launchOptions.launchRaceConfig(from: model.settings) {
                model.startRaceSequence(GameSession(config: config, timescale: launchOptions.timescale))
            }
        }
    }

    /// `-fixture <name>`: replays the fixture's log to its freeze tick and freezes the race there (#62).
    private func startFixture(named name: String) {
        do {
            let (fixture, log) = try RenderFixture.load(named: name)
            model.startRaceSequence(try GameSession(fixture: fixture, log: log))
        } catch {
            Logger(subsystem: "com.phillreeder.regatta", category: "launch").error("Render fixture \(name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            fixtureError = String(describing: error)
        }
    }
}
