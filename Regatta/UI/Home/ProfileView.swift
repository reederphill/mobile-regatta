import RegattaCore
import RegattaServices
import SwiftUI

/// The profile (#25, #139), pushed from Home's toolbar: Game Center's name and photo, the rating with its
/// provisional badge, online races and wins, the next earned design, your livery and the leaderboard. Signed out, only
/// Game Center's sign-in prompt. No rating graph, history or achievements (#25, #36).
///
/// A scroll view and a column, like the other pages; UI tests find it by `page-profile`.
struct ProfileView: View {
    @Bindable var model: AppModel
    /// The services' state; nil in previews and tests, where the page is signed out.
    let status: OnlineStatus?
    /// The lobby area's Sign in and Try again (#138): Game Center's sheet, then the terms when due, never the queue.
    var online: HomeOnlineActions
    @State private var profile: ProfileModel
    /// Try again's taps: each reads the profile again.
    @State private var attempts = 0

    init(model: AppModel, status: OnlineStatus?, online: HomeOnlineActions) {
        self.model = model
        self.status = status
        self.online = online
        _profile = State(initialValue: ProfileModel(profile: status?.services.profile,
                                                    mayAskService: { [weak status] in status?.mayAskService ?? false },
                                                    adoptCount: { [weak model] in model?.adoptServerCount($0) }))
    }

    /// What reads the profile again: the page appearing, the gate moving (sign-in, the terms, the session), Try again.
    private struct ReadKey: Hashable {
        var mayAsk: Bool
        var isOnline: Bool
        var isSignedIn: Bool
        var hasAcceptedTerms: Bool
        var attempts: Int
    }

    private var readKey: ReadKey {
        ReadKey(mayAsk: status?.mayAskService ?? false, isOnline: status?.isOnline ?? true,
                isSignedIn: status?.lobbyStatus.isSignedIn ?? false, hasAcceptedTerms: status?.lobbyStatus.hasAcceptedTerms ?? false,
                attempts: attempts)
    }

    private var state: ProfilePageState {
        guard let status else { return .signIn }
        return profile.state(isOnline: status.isOnline, status: status.lobbyStatus, retryLine: status.lobbyRetryLine)
    }

    var body: some View {
        let state = state
        ScrollView {
            VStack(spacing: 20) {
                if case .loaded(let loaded) = state, let suspension = ProfileModel.suspensionText(loaded) {
                    NoticeRow(title: suspension, id: "profile-suspension")
                }
                if state.showsHeader { header(state) }
                content(state)
            }
            .padding(.vertical, 20)
            .readableColumn()
            // UI tests check the page was pushed.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("page-profile")
        }
        .menuBackground()
        .navigationTitle("Profile")
        .task(id: readKey) { await profile.refresh() }
    }

    /// Her photo and name: Game Center's alias before the read, the server's name (a nickname override's) after.
    private func header(_ state: ProfilePageState) -> some View {
        let name: String? = if case .loaded(let loaded) = state { loaded.nickname } else { status?.signedInAlias }
        return VStack(spacing: 10) {
            avatar
            if let name {
                Text(name)
                    .font(MenuFont.heading(.title2))
                    .accessibilityIdentifier("profile-nickname")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var avatar: some View {
        Group {
            if let photo = status?.playerPhoto {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundStyle(ChromePalette.tint)
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(.circle)
        .accessibilityElement()
        .accessibilityLabel("Game Center photo")
        .accessibilityIdentifier("profile-avatar")
    }

    @ViewBuilder private func content(_ state: ProfilePageState) -> some View {
        switch state {
        case .signIn:
            VStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.largeTitle)
                    .foregroundStyle(ChromePalette.tint)
                    .accessibilityHidden(true)
                // TODO-COPY (#171)
                Text("Sign in to Game Center to see your rating")
                    .font(MenuFont.body())
                    .multilineTextAlignment(.center)
                Button("Sign in", action: online.signIn)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("profile-sign-in")
            }
            .padding(.vertical, 20)
        case .offline:
            // TODO-COPY (#171)
            message("You're offline", systemImage: "wifi.slash")
        case .retry(let line):
            message(line.text(now: .now),
                    systemImage: line == .couldNotSignIn ? "person.crop.circle.badge.exclamationmark" : "icloud.slash") {
                // TODO-COPY (#171)
                Button("Try again") {
                    attempts += 1
                    online.signIn()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("profile-retry")
            }
        case .practiceOnly:
            // TODO-COPY (#171)
            message("Practice races only", systemImage: "sailboat")
        case .termsDue:
            // TODO-COPY (#171)
            message("Accept the terms to see your rating", systemImage: "doc.text") {
                Button("Review terms") { model.sheet = .terms }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("profile-terms")
            }
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 150)
                .background(ChromePalette.surface, in: .rect(cornerRadius: 16))
                .accessibilityIdentifier("profile-loading")
        case .loaded(let loaded):
            stats(loaded)
            boat(loaded)
            leaderboard
        }
    }

    /// One line in a card, and its button if any: the lobby area's look.
    private func message(_ title: String, systemImage: String, @ViewBuilder button: () -> some View = { EmptyView() }) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(MenuFont.heading(.headline))
                .fixedSize(horizontal: false, vertical: true)
            button()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(ChromePalette.surface, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("profile-message")
    }

    /// Rating, races and wins.
    private func stats(_ loaded: Profile) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                // TODO-COPY (#171)
                Text("Rating").font(MenuFont.body()).accessibilityHidden(true)
                Spacer(minLength: 12)
                // Verbatim: a rating is never grouped ("1586", not "1,586").
                Text(verbatim: "\(loaded.rating.value)")
                    .font(MenuFont.number(.title3))
                    .accessibilityLabel("Rating")
                    .accessibilityValue("\(loaded.rating.value)")
                    .accessibilityIdentifier("profile-rating")
                if loaded.rating.isProvisional {
                    // TODO-COPY (#171)
                    Text("Provisional")
                        .font(MenuFont.body(.subheadline))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(ChromePalette.tint.opacity(0.18), in: .capsule)
                        .accessibilityIdentifier("profile-provisional")
                }
            }
            .padding(16)
            Divider()
            // TODO-COPY (#171)
            numberRow("Races", loaded.completedRaces, id: "profile-races")
            Divider()
            // TODO-COPY (#171)
            numberRow("Wins", loaded.wins, id: "profile-wins")
        }
        .background(ChromePalette.surface, in: .rect(cornerRadius: 16))
    }

    private func numberRow(_ title: String, _ value: Int, id: String) -> some View {
        HStack {
            Text(title).font(MenuFont.body())
            Spacer(minLength: 12)
            Text(verbatim: "\(value)").font(MenuFont.number(.body))
        }
        .padding(16)
        // UI tests read the number off the row itself, as `practice-fleet`'s.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(value)")
        .accessibilityIdentifier(id)
    }

    /// Your livery, and the next earned design: each opens My boat over the profile, the design tried on.
    private func boat(_ loaded: Profile) -> some View {
        VStack(spacing: 0) {
            Button { openMyBoat(trying: nil) } label: {
                LiveryRenderView(livery: model.myBoat.saved)
                    .frame(maxWidth: .infinity)
                    .padding(16)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("profile-render")
            if let progress = ProfileModel.progressText(loaded), let next = loaded.progress.next {
                Divider()
                Button { openMyBoat(trying: next.design) } label: {
                    HStack {
                        // TODO-COPY (#171)
                        Text("Next design").font(MenuFont.body())
                        Spacer(minLength: 12)
                        Text(progress).font(MenuFont.number(.body))
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Next design")
                .accessibilityValue(progress)
                .accessibilityIdentifier("profile-progress")
            }
        }
        .background(ChromePalette.surface, in: .rect(cornerRadius: 16))
    }

    private var leaderboard: some View {
        Button { status?.leaderboard.showLeaderboard() } label: {
            HStack {
                // TODO-COPY (#171)
                Text("Leaderboard").font(MenuFont.body())
                Spacer(minLength: 12)
                Image(systemName: "arrow.up.right").foregroundStyle(.secondary)
            }
            .padding(16)
            .background(ChromePalette.surface, in: .rect(cornerRadius: 16))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Leaderboard")
        .accessibilityIdentifier("profile-leaderboard")
    }

    /// My boat pushed over the profile, so Back comes here.
    private func openMyBoat(trying design: DesignID?) {
        model.myBoat.open(trying: design)
        model.path.append(.myBoat)
    }
}
