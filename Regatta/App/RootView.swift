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

struct RootView: View {
    @State private var settings = RaceSettings()
    @State private var session: GameSession?
    @State private var checkedLaunchArguments = false
    @Environment(\.sceneState) private var sceneState
    private let launchOptions = LaunchOptions.current

    var body: some View {
        content
            // #108's AppModel phase takes this over.
            .onChange(of: session != nil, initial: true) { _, racing in sceneState.isRaceSequenceShowing = racing }
    }

    @ViewBuilder private var content: some View {
        if let session {
            RaceView(
                session: session,
                onRestart: { self.session = makeSession(launchOptions.raceConfig(from: settings)) },
                onExit: { self.session = nil }
            )
            .id(ObjectIdentifier(session))
        } else {
            MenuView(settings: $settings) {
                session = makeSession(launchOptions.raceConfig(from: settings))
            }
            .onAppear(perform: autostartIfRequested)
        }
    }

    private func makeSession(_ config: RaceConfig) -> GameSession {
        GameSession(config: config, timescale: launchOptions.timescale)
    }

    /// Development launch arguments (`LaunchOptions`): `-autostart`, `-demo` and `-perf` skip the menu.
    private func autostartIfRequested() {
        guard !checkedLaunchArguments else { return }
        checkedLaunchArguments = true
        for problem in launchOptions.problems {
            Logger(subsystem: "com.phillreeder.regatta", category: "launch").warning("Ignoring launch argument \(problem, privacy: .public)")
        }
        guard let config = launchOptions.launchRaceConfig(from: settings) else { return }
        session = makeSession(config)
    }
}
