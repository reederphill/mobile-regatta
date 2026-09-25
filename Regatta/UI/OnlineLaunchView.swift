import RegattaProtocol
import SwiftUI

/// An online race from joining to the close (#68): connecting, the update prompt, a failure to retry,
/// then the race itself. `onRestart` asks for another race; `onExit` goes back to the menu.
struct OnlineLaunchView: View {
    let launch: OnlineLaunch
    var onRestart: () -> Void
    var onExit: () -> Void

    var body: some View {
        switch launch.phase {
        case .racing(let session):
            RaceView(session: session, onRestart: onRestart, onExit: onExit)
                .id(ObjectIdentifier(session))
        case .connecting:
            panel {
                ProgressView()
                Text("Joining a race on \(launch.server.address)…")
                    .accessibilityIdentifier("online-connecting")
                Button("Cancel", role: .cancel, action: onExit).buttonStyle(.bordered)
            }
        case .updateRequired(let reason):
            panel {
                Image(systemName: "arrow.down.app").font(.largeTitle)
                Text("Update required").font(.title2.bold())
                Text(Self.explanation(reason))
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("online-update-required")
                Button("Back to menu", action: onExit).buttonStyle(.borderedProminent)
            }
        case .failed(let reason):
            panel {
                Image(systemName: "wifi.exclamationmark").font(.largeTitle)
                Text("Couldn't join the race").font(.title2.bold())
                Text(reason)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("online-failed")
                Button("Try again", action: onRestart).buttonStyle(.borderedProminent)
                Button("Back to menu", action: onExit).buttonStyle(.bordered)
            }
        }
    }

    /// The update prompt's text for the server's reason.
    static func explanation(_ reason: UpdateRequired.Reason) -> String {
        switch reason {
        case .protocolVersion, .simulationVersion, .clientBuild:
            "This version of Regatta can't race online any more. Update it from the App Store to keep racing."
        case .dataFiles:
            "This version of Regatta is missing the latest boats or courses. Update it from the App Store to race online."
        case .unknown:
            "A newer version of Regatta is needed to race online. Update it from the App Store."
        }
    }

    private func panel(@ViewBuilder _ content: () -> some View) -> some View {
        ZStack {
            Color(uiColor: Palette.water).ignoresSafeArea()
            VStack(spacing: 16, content: content)
                .foregroundStyle(.white)
                .padding(28)
                .background(.ultraThinMaterial, in: .rect(cornerRadius: 24))
                .padding(24)
        }
    }
}
