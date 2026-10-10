import RegattaServices
import SwiftUI

/// The one home screen (#25): Race online leading Practice, the lobby area below, and the toolbar's pages
/// pushed on top. No tab bar.
struct HomeView: View {
    @Bindable var model: AppModel
    /// Race online, the lobby's Sign in and the Terms of Use sheet: RootView's gate (#138).
    var online: HomeOnlineActions
    @Environment(\.isOnline) private var isOnline
    @Environment(\.lobbyStatus) private var lobbyStatus

    var body: some View {
        NavigationStack(path: $model.path) {
            ScrollView {
                VStack(spacing: 20) {
                    if let notice = model.notice {
                        NoticeRow(notice: notice)
                    }
                    raceOnline
                    practice
                    #if DEBUG
                    tuning
                    #endif
                    if let lastRace = model.lastRace {
                        LastRaceRow(lastRace: lastRace) { model.sheet = .lastRace }
                    }
                    LobbyPanel(state: LobbyPanelState(isOnline: isOnline, status: lobbyStatus), onSignIn: online.signIn,
                               onReviewTerms: { model.sheet = .terms })
                }
                .padding(.vertical, 20)
                .readableColumn()
                // UI tests check the home screen is up.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("home")
            }
            #if DEBUG
            .safeAreaInset(edge: .bottom) {
                if model.launchOptions.showsBuildIdentity { buildIdentity }
            }
            #endif
            .menuBackground()
            .navigationTitle("Regatta")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .navigationDestination(for: AppModel.Page.self) { page in
                MenuPageView(page: page, model: model)
            }
        }
        .tint(ChromePalette.tint)
        .sheet(item: $model.sheet, onDismiss: online.sheetDismissed) { sheet in
            if sheet == .terms {
                TermsSheet(version: lobbyStatus.termsVersion, agree: online.agreeToTerms, close: { model.sheet = nil })
            } else if sheet == .lastRace, let lastRace = model.lastRace {
                // Your last race's results, reopened (#24, #132): large, with Close only.
                ResultsView(model: lastRace, buttons: .reopened(close: { model.sheet = nil }), presentation: .page)
                    .environment(\.colorScheme, .dark)
                    .presentationDetents([.large])
            } else {
                MenuSheetView(sheet: sheet)
            }
        }
    }

    private var raceOnline: some View {
        let availability = RaceOnlineAvailability(isOnline: isOnline, lobbyStatus: lobbyStatus)
        return Button(action: online.raceOnline) {
            VStack(spacing: 2) {
                Text("Race online").font(MenuFont.heading(.title2))
                if let reason = availability.reason {
                    Text(reason).font(MenuFont.body(.subheadline))
                }
            }
            // The page's `menuBackground` text colour would otherwise reach the label: navy on the navy fill.
            .foregroundStyle(ChromePalette.onTint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!availability.isEnabled)
        .accessibilityIdentifier("race-online")
    }

    private var practice: some View {
        Button {
            model.path.append(.practiceSetup)
        } label: {
            Text("Practice")
                .font(MenuFont.heading(.title3))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .accessibilityIdentifier("practice")
    }

    #if DEBUG
    /// The debug tuning panel (#232), Debug builds only, marked TUNED while anything differs from the files.
    private var tuning: some View {
        Button {
            model.path.append(.tuning)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3").accessibilityHidden(true)
                Text("Tuning").font(MenuFont.heading(.headline))
                if model.tuning.tuning.isTuned { TunedBadge(onChrome: true) }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("tuning")
    }

    /// Which commit this build is (#473), Debug builds only and never in a UI test or a render fixture.
    private var buildIdentity: some View {
        Text(BuildIdentity.current.label)
            .font(MenuFont.body(.caption2))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
            .accessibilityIdentifier("build-id")
    }
    #endif

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: 6) {
                Image(systemName: "flag.fill")
                    .foregroundStyle(ChromePalette.flagRed)
                    .accessibilityHidden(true)
                Text("REGATTA")
                    .font(MenuFont.heading(.headline))
                    .tracking(2)
                    .foregroundStyle(ChromePalette.text)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
        ToolbarItem(placement: .topBarLeading) {
            pageButton(.profile, "Profile", systemImage: "person.crop.circle", id: "toolbar-profile")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            pageButton(.myBoat, "My boat", systemImage: "sailboat", id: "toolbar-myboat")
            pageButton(.help, "Help", systemImage: "questionmark.circle", id: "toolbar-help")
            pageButton(.settings, "Settings", systemImage: "gearshape", id: "toolbar-settings")
        }
    }

    private func pageButton(_ page: AppModel.Page, _ title: String, systemImage: String, id: String) -> some View {
        Button {
            model.path.append(page)
        } label: {
            Label(title, systemImage: systemImage)
        }
        .accessibilityIdentifier(id)
    }
}

/// What Home's online controls do (#138): RootView runs Race online's gate, Game Center's sign-in and the terms.
struct HomeOnlineActions {
    var raceOnline: () -> Void = {}
    /// The lobby area's Sign in.
    var signIn: () -> Void = {}
    /// The Terms of Use sheet's I agree.
    var agreeToTerms: () -> Void = {}
    /// A sheet went away, however it was closed: what waits on the Terms of Use sheet runs here.
    var sheetDismissed: () -> Void = {}
}

/// What the lobby area shows, from connectivity and the player's account (#25), by the gating matrix (#138).
enum LobbyPanelState: Equatable {
    case offline
    case signIn
    case acceptTerms
    /// Hide lobby chat is on, or Game Center restricts the player's chat (#17, #34): the queue's size and the
    /// leaderboard instead of the chat.
    case chatHidden(queuedPlayers: Int?)
    case lobby

    init(isOnline: Bool, status: LobbyStatus) {
        let access = status.access(isOnline: isOnline)
        if !isOnline {
            self = .offline
        } else if !status.isSignedIn {
            self = .signIn
        } else if access.termsDue {
            self = .acceptTerms
        } else if status.hidesChat || !access.chatVisible {
            self = .chatHidden(queuedPlayers: status.queuedPlayers)
        } else {
            self = .lobby
        }
    }
}

/// The lobby area: static panels until the lobby (#109 and later) fills it.
private struct LobbyPanel: View {
    let state: LobbyPanelState
    var onSignIn: () -> Void
    var onReviewTerms: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(ChromePalette.surface, in: .rect(cornerRadius: 16))
        // UI tests check it fits the window.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lobby-panel")
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .offline:
            heading("You're offline", systemImage: "wifi.slash")
            detail("Practice races work offline.")
        case .signIn:
            heading("Sign in to Game Center to chat", systemImage: "person.crop.circle.badge.checkmark")
            Button("Sign in", action: onSignIn)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("lobby-sign-in")
        case .acceptTerms:
            heading("Accept the terms to chat and race online", systemImage: "doc.text")
            Button("Review terms", action: onReviewTerms)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("lobby-terms")
        case .chatHidden(let queuedPlayers):
            heading("Queue", systemImage: "person.3")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(queuedPlayers.map { "\($0)" } ?? "–").font(MenuFont.number(.largeTitle))
                detail("in the queue")
            }
            heading("Leaderboard", systemImage: "list.number")
            detail("The leaderboard arrives here.")
        case .lobby:
            heading("Lobby", systemImage: "bubble.left.and.bubble.right")
            detail("Chat with other sailors between races. The lobby arrives here.")
        }
    }

    private func heading(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(MenuFont.heading(.headline))
            .accessibilityAddTraits(.isHeader)
    }

    private func detail(_ text: String) -> some View {
        Text(text)
            .font(MenuFont.body(.subheadline))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A notice at the top of the home screen, such as an update or maintenance message.
private struct NoticeRow: View {
    let notice: AppModel.Notice

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(notice.title).font(MenuFont.heading(.headline))
            Text(notice.message).font(MenuFont.body(.subheadline)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(ChromePalette.surface, in: .rect(cornerRadius: 16))
        .overlay(alignment: .leading) {
            // A flag-yellow edge marks it as a notice; decorative only.
            UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16)
                .fill(ChromePalette.flagYellow)
                .frame(width: 6)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("home-notice")
    }
}

/// The last race's entry on the home screen (#24): your place, and a tap reopens the results (#132).
private struct LastRaceRow: View {
    let lastRace: RaceResultViewModel
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack {
                // TODO-COPY (#171)
                Text("Last race").font(MenuFont.heading(.headline))
                Spacer()
                Text(lastRace.summary).font(MenuFont.number(.headline))
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .padding(16)
            .background(ChromePalette.surface, in: .rect(cornerRadius: 16))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("last-race")
    }
}

/// Whether Home's Race online can be tapped, and the one line under it when it can't (#242, #314): "Offline", or
/// "Practice races only" for Game Center's multiplayer restriction (#34), by the gating matrix (#138). Signed out it
/// can: the tap signs in (#25).
struct RaceOnlineAvailability: Equatable {
    var isEnabled: Bool
    var reason: String?

    init(isOnline: Bool, lobbyStatus: LobbyStatus) {
        let access = lobbyStatus.access(isOnline: isOnline)
        self.init(isEnabled: access.onlineAllowed, reason: access.reason)
    }

    init(isEnabled: Bool, reason: String?) {
        self.isEnabled = isEnabled
        self.reason = reason
    }
}
