import SwiftUI
import RegattaCore

struct RaceSettings {
    var opponents = 7
    var laps = 2
    var prestartSeconds = 60.0

    var config: RaceConfig {
        // A practice race: you in seat 0, bots in the rest. The device picks both seeds; online races
        // get the race seed from the server, which keeps the wind seed to itself (ADR 0001).
        // The menu keeps opponents in 1...15, so the fleet is always a valid 2...16.
        let setup = try! RaceSetup(
            raceSeed: RaceSeed(UInt64.random(in: .min ... .max)),
            seats: [.human] + Array(repeating: .bot, count: opponents),
            laps: laps,
            startSequenceTicks: Int((prestartSeconds * Double(Race.tickRate)).rounded())
        )
        return RaceConfig(setup: setup, windSeed: WindSeed(UInt64.random(in: .min ... .max)))
    }
}

struct RootView: View {
    @State private var settings = RaceSettings()
    @State private var session: GameSession?
    @State private var checkedLaunchArguments = false

    var body: some View {
        if let session {
            RaceView(
                session: session,
                onRestart: { self.session = GameSession(config: settings.config) },
                onExit: { self.session = nil }
            )
            .id(ObjectIdentifier(session))
        } else {
            MenuView(settings: $settings) {
                session = GameSession(config: settings.config)
            }
            .onAppear(perform: autostartIfRequested)
        }
    }

    /// Development launch arguments: `-autostart` skips the menu, `-demo` also lets a bot sail your boat.
    private func autostartIfRequested() {
        guard !checkedLaunchArguments else { return }
        checkedLaunchArguments = true
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-autostart") || arguments.contains("-demo") else { return }
        var config = settings.config
        config.autopilotPlayer = arguments.contains("-demo")
        session = GameSession(config: config)
    }
}
