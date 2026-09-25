import SwiftUI

/// The one home screen (#25): Race online leading Practice, the lobby area below, and the toolbar's pages
/// pushed on top. No tab bar.
struct HomeView: View {
    @Bindable var model: AppModel
    /// Race online. A stub until online racing lands (#68).
    var onRaceOnline: () -> Void
    @Environment(\.connectivity) private var connectivity
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
                    if let lastRace = model.lastRace {
                        LastRaceRow(lastRace: lastRace)
                    }
                    LobbyPanel(state: LobbyPanelState(isOnline: connectivity.isOnline, status: lobbyStatus)) {
                        model.sheet = .signIn
                    }
                }
                .padding(.vertical, 20)
                .readableColumn()
                // UI tests check the home screen is up.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("home")
            }
            .menuBackground()
            .navigationTitle("Regatta")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .navigationDestination(for: AppModel.Page.self) { page in
                MenuPageView(page: page, model: model)
            }
        }
        .tint(ChromePalette.tint)
        .sheet(item: $model.sheet) { sheet in
            MenuSheetView(sheet: sheet)
        }
    }

    private var raceOnline: some View {
        Button(action: onRaceOnline) {
            VStack(spacing: 2) {
                Text("Race online").font(MenuFont.heading(.title2))
                if !connectivity.isOnline {
                    Text("Offline").font(MenuFont.body(.subheadline))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!connectivity.isOnline)
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

/// What the lobby area shows, from connectivity and the player's account (#25).
enum LobbyPanelState: Equatable {
    case offline
    case signIn
    case acceptTerms
    /// Hide lobby chat is on: the queue's size and the leaderboard instead of the chat.
    case chatHidden(queuedPlayers: Int?)
    case lobby

    init(isOnline: Bool, status: LobbyStatus) {
        if !isOnline {
            self = .offline
        } else if !status.isSignedIn {
            self = .signIn
        } else if !status.hasAcceptedTerms {
            self = .acceptTerms
        } else if status.hidesChat {
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
            detail("Practice races work without a connection. Race online and the lobby come back when you're online.")
        case .signIn:
            heading("Sign in to race online", systemImage: "person.crop.circle.badge.checkmark")
            detail("Game Center signs you in. Practice races need no account.")
            Button("Sign in", action: onSignIn)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("lobby-sign-in")
        case .acceptTerms:
            heading("Accept the terms", systemImage: "doc.text")
            detail("Accept the terms to race online and chat in the lobby.")
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

/// The last race's entry on the home screen (#24).
private struct LastRaceRow: View {
    let lastRace: AppModel.LastRace

    var body: some View {
        HStack {
            Text("Last race").font(MenuFont.heading(.headline))
            Spacer()
            Text("\(lastRace.place) of \(lastRace.fleetSize)").font(MenuFont.number(.headline))
        }
        .padding(16)
        .background(ChromePalette.surface, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("last-race")
    }
}
