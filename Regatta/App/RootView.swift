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
    /// An online race, from joining to its close (#68).
    @State private var online: OnlineLaunch?
    @State private var checkedLaunchArguments = false
    /// Why the `-fixture` launch couldn't start, shown instead of the menu so a UI test sees it.
    @State private var fixtureError: String?
    @Environment(\.sceneState) private var sceneState
    private let launchOptions = LaunchOptions.current

    var body: some View {
        content
            // #108's AppModel phase takes this over.
            .onChange(of: session != nil || online != nil, initial: true) { _, racing in sceneState.isRaceSequenceShowing = racing }
    }

    @ViewBuilder private var content: some View {
        if let fixtureError {
            Text("Render fixture failed: \(fixtureError)")
                .padding()
                .accessibilityIdentifier("fixture-error")
        } else if let session {
            RaceView(
                session: session,
                onRestart: { self.session = makeSession(launchOptions.raceConfig(from: settings)) },
                onExit: { self.session = nil }
            )
            .id(ObjectIdentifier(session))
        } else if let online {
            OnlineLaunchView(launch: online, onRestart: startOnlineRace, onExit: { self.online = nil })
                .id(ObjectIdentifier(online))
        } else {
            MenuView(settings: $settings, onStart: {
                session = makeSession(launchOptions.raceConfig(from: settings))
            }, onRaceOnline: onlineRaceStarter)
            .onAppear(perform: autostartIfRequested)
        }
    }

    /// The menu's "Race online (dev)" (#68): Debug builds only, until there is matchmaking.
    private var onlineRaceStarter: (() -> Void)? {
        #if DEBUG
        startOnlineRace
        #else
        nil
        #endif
    }

    /// A new online race: in a Debug build, the dev server's instant race on the menu's host or
    /// `-onlineHost`, with `-raceSeconds` and `-startSeconds` if given.
    private func startOnlineRace() {
        #if DEBUG
        let server = RaceServer(address: launchOptions.onlineHost
            ?? UserDefaults.standard.string(forKey: RaceServer.addressDefaultsKey) ?? RaceServer.defaultAddress)
        let (raceSeconds, startSeconds) = (launchOptions.raceSeconds, launchOptions.startSeconds)
        let launch = OnlineLaunch(server: server) {
            try await DevInstantRace.ticket(server: server, raceSeconds: raceSeconds, startSeconds: startSeconds)
        }
        online = launch
        Task { await launch.start() }
        #endif
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
        if let name = launchOptions.fixture {
            startFixture(named: name)
            return
        }
        if launchOptions.online {
            startOnlineRace()
            return
        }
        guard let config = launchOptions.launchRaceConfig(from: settings) else { return }
        session = makeSession(config)
    }

    /// `-fixture <name>`: replays the fixture's log to its freeze tick and freezes the race there (#62).
    private func startFixture(named name: String) {
        do {
            let (fixture, log) = try RenderFixture.load(named: name)
            session = try GameSession(fixture: fixture, log: log)
        } catch {
            Logger(subsystem: "com.phillreeder.regatta", category: "launch").error("Render fixture \(name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            fixtureError = String(describing: error)
        }
    }
}
