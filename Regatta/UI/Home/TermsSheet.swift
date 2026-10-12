import RegattaServices
import SwiftUI

/// The Terms of Use the app asks the player to accept (#34): placeholders until the real text and its lawyer pass
/// (#171). A material change to the text bumps `version`, and the sheet asks again.
nonisolated enum TermsOfUse {
    /// The version of the text below. With no server, the device's `LocalTermsService` asks for it; with one, the
    /// server says which version is current, and one newer than this asks for an update, not for an "I agree" to
    /// text the player can't see (#161). `-termsVersion` stands in for a build with newer text (Debug).
    static let version: TermsVersion = {
        #if DEBUG
        // Read from the arguments here (`LaunchOptions`, which checks them, is the main actor's).
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "-termsVersion"), arguments.indices.contains(flag + 1),
           let version = Int(arguments[flag + 1]), version >= 1 {
            return TermsVersion(version)
        }
        #endif
        return TermsVersion(1)
    }()

    static let lines = [
        // TODO-COPY (#171)
        "Sail fair. Follow the racing rules and serve your penalties.",
        // TODO-COPY (#171)
        "Be kind in the lobby. Chat is for sailing talk.",
        // TODO-COPY (#171)
        "Players can report a race. We review reports and may suspend online racing.",
        // TODO-COPY (#171)
        "Game Center keeps your online profile and rating.",
        // TODO-COPY (#171)
        "Practice races need none of this.",
    ]
}

/// The Terms of Use sheet (#34, #138): after Game Center sign-in, before the lobby or the queue first appears, and
/// reopened from the lobby area. An explicit I agree; Close (or swiping down) declines.
struct TermsSheet: View {
    /// The version shown and accepted.
    let version: TermsVersion?
    /// The last I agree couldn't be saved (#161): the sheet stays, with a short line.
    var saveFailed = false
    var agree: () -> Void
    var close: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(TermsOfUse.lines, id: \.self) { line in
                        Text(line).font(MenuFont.body())
                    }
                    if let version {
                        Text("Version \(version.rawValue)")
                            .font(MenuFont.body(.footnote))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("terms-version")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    if saveFailed {
                        // TODO-COPY (#171)
                        Text("Couldn't save. Try again.")
                            .font(MenuFont.body(.footnote))
                            .foregroundStyle(ChromePalette.flagRed)
                            .accessibilityIdentifier("terms-save-failed")
                    }
                    Button(action: agree) {
                        // The page's `menuBackground` text colour would otherwise reach the label: navy on the navy fill.
                        Text("I agree").font(MenuFont.heading(.headline)).foregroundStyle(ChromePalette.onTint)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("terms-agree")
                    Button(action: close) {
                        Text("Close").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityIdentifier("terms-close")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.bar)
            }
            .menuBackground()
            .navigationTitle("Terms of Use")
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(ChromePalette.tint)
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("sheet-terms")
    }
}
