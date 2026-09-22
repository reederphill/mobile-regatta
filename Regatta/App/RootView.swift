import SwiftUI
import RegattaCore

struct RaceSettings {
    var opponents = 7
    var laps = 2
    var prestartSeconds = 60.0

    var config: Race.Config {
        Race.Config(opponents: opponents, laps: laps, prestartSeconds: prestartSeconds)
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
