import RegattaCore
import RegattaServices
import SwiftUI
import UIKit

/// The one home screen (#25): Race online leading Practice, the lobby area below, and the toolbar's pages
/// pushed on top. No tab bar.
struct HomeView: View {
    @Bindable var model: AppModel
    /// Race online, the lobby's Sign in and the Terms of Use sheet: RootView's gate (#138).
    var online: HomeOnlineActions
    @Environment(\.isOnline) private var isOnline
    @Environment(\.lobbyStatus) private var lobbyStatus
    /// What the server and the session say beyond the gating matrix (#161): Race online's line and spinner, the lobby
    /// area's Try again, the terms sheet's line. Nil in previews and tests.
    @Environment(\.onlineStatus) private var onlineStatus
    /// The queue (#140): its bar stands in for Race online while you wait.
    private var queue: QueueController? { onlineStatus?.queue }
    /// The online race sequence (#141): its Rejoin race stands in for Race online while a race she dropped out of runs.
    private var sequence: OnlineRaceController? { onlineStatus?.race }
    /// A render fixture's Home (#141): a rejoin offer at a fixed moment, or a Last race row, in place of the app's.
    var fixture: HomeFixture? = nil

    /// What stands in Race online's place.
    enum RaceSlot: Equatable {
        case raceOnline
        /// A race she dropped out of still runs (#141): the way back, and no queue meanwhile.
        case rejoin(OnlineRaceController.RejoinEntry)
        /// Queued: the bar above is Race online's place, no second control, and Practice moves up.
        case none
    }

    static func raceSlot(rejoin: OnlineRaceController.RejoinEntry?, entry: RaceOnlineEntry?) -> RaceSlot {
        if let rejoin { return .rejoin(rejoin) }
        return entry == .queued ? .none : .raceOnline
    }

    private var lastRace: RaceResultViewModel? { fixture?.lastRace ?? model.lastRace }
    /// The lobby (#142): the feed and composer, held by the online status.
    private var lobby: LobbyModel? { onlineStatus?.lobby }
    @Environment(\.screenSize) private var screenSize

    /// What the lobby area shows (the brief's visibility matrix).
    private var lobbyState: LobbyPanelState {
        LobbyPanelState(isOnline: isOnline, status: lobbyStatus, retryLine: onlineStatus?.lobbyRetryLine, lobby: lobby?.phase ?? .open)
    }

    /// Typing in the lobby on a phone (G1): the on-screen keyboard leaves no room for Race online and Practice, so the
    /// lobby takes the window until the keyboard goes. An iPad keeps them, and so does a phone typing on a hardware
    /// keyboard: with no keyboard on screen the room is all there, and the lobby taking it would only stretch the feed.
    private var lobbyTakesTheWindow: Bool {
        lobby?.isFieldFocused == true && keyboardIsUp && (screenSize?.height ?? 0) < 900
    }
    /// Whether an on-screen keyboard is up: taller than a hardware keyboard's shortcut bar.
    @State private var keyboardIsUp = false

    var body: some View {
        NavigationStack(path: $model.path) {
            // Home's top stays put; the lobby fills the rest of the window with its own scroll, the composer pinned at
            // its bottom (G1), and the keyboard pushes it up.
            VStack(spacing: 20) {
                if !lobbyTakesTheWindow {
                    if let notice = model.notice {
                        NoticeRow(notice: notice)
                    }
                    switch Self.raceSlot(rejoin: fixture?.rejoin ?? sequence?.rejoinEntry, entry: queue?.entry) {
                    case .rejoin(let entry): rejoin(entry)
                    case .raceOnline: raceOnline
                    case .none: EmptyView()
                    }
                    practice
                    #if DEBUG
                    tuning
                    #endif
                    if let lastRace {
                        LastRaceRow(lastRace: lastRace) { model.sheet = .lastRace }
                    }
                }
                LobbyView(state: lobbyState, model: lobby, leaderboardTop: onlineStatus?.leaderboardTop,
                          onSignIn: online.signIn, onReviewTerms: { model.sheet = .terms },
                          onShowLeaderboard: { onlineStatus?.leaderboard.showLeaderboard() },
                          onOpenCard: { model.sheet = .boatCard($0) })
                if !lobbyState.fillsHome { Spacer(minLength: 0) }
            }
            .padding(.top, lobbyTakesTheWindow ? 8 : 20)
            .padding(.bottom, 12)
            .readableColumn()
            .animation(.default, value: lobbyTakesTheWindow)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                keyboardIsUp = Self.keyboardIsUp(note)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardIsUp = false
            }
            // UI tests check the home screen is up.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home")
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
                MenuPageView(page: page, model: model, online: online)
            }
        }
        // Outside the stack, so every pushed page has it, above the navigation bar; a half-height sheet sits below it.
        .queueBar(queue)
        .tint(ChromePalette.tint)
        .sheet(item: $model.sheet, onDismiss: online.sheetDismissed) { sheet in
            if sheet == .terms {
                TermsSheet(version: lobbyStatus.termsVersion, saveFailed: onlineStatus?.termsSaveFailed ?? false,
                           agree: online.agreeToTerms, close: { model.sheet = nil })
            } else if case .boatCard(let author) = sheet {
                BoatCardSheet(author: author, model: lobby, close: { model.sheet = nil })
            } else if sheet == .lastRace, let lastRace = model.lastRace {
                // Your last race's results, reopened (#24, #132): large, with Close only.
                ResultsView(model: lastRace, buttons: .reopened(close: { model.sheet = nil }), presentation: .page)
                    // A large sheet covers Home's bar: it carries its own.
                    .queueBar(queue)
                    .environment(\.colorScheme, .dark)
                    .presentationDetents([.large])
            } else {
                MenuSheetView(sheet: sheet)
            }
        }
    }

    /// Whether a keyboard frame change leaves an on-screen keyboard up: more than a hardware keyboard's shortcut bar
    /// showing above the screen's bottom.
    static func keyboardIsUp(_ note: Notification) -> Bool {
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let screen = (note.object as? UIScreen) ?? UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.screen }).first else { return false }
        return screen.bounds.intersection(frame).height > 150
    }

    /// Rejoin race, with the race clock counted on each second (#141): straight back to the water.
    private func rejoin(_ entry: OnlineRaceController.RejoinEntry) -> some View {
        Button {
            Task { await sequence?.rejoin() }
        } label: {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                // A fixture's clock stands still at the moment its offer was read.
                let date = fixture == nil ? context.date : entry.readAt
                VStack(spacing: 2) {
                    // TODO-COPY (#171)
                    Text("Rejoin race").font(MenuFont.heading(.title2))
                    Text(entry.clock(at: date)).font(MenuFont.body(.subheadline)).monospacedDigit()
                }
                .foregroundStyle(ChromePalette.onTint)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(entry.spoken(at: date))
                .accessibilityValue(entry.clock(at: date))
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .accessibilityIdentifier("race-rejoin")
    }

    private var raceOnline: some View {
        var availability = RaceOnlineAvailability(isOnline: isOnline, lobbyStatus: lobbyStatus, line: onlineStatus?.restrictionLine,
                                                  isConnecting: onlineStatus?.isOpeningSession ?? false)
        // Just out of a locked fleet (#140): off, with no words, until the server says where she stands.
        if queue?.entry == .settling { availability = RaceOnlineAvailability(isEnabled: false, reason: "…") }
        // On the tint fill, or on the grey the system draws a disabled button in.
        let ink = availability.isEnabled ? ChromePalette.onTint : ChromePalette.onDisabled
        return Button(action: online.raceOnline) {
            VStack(spacing: 2) {
                Text("Race online").font(MenuFont.heading(.title2))
                if availability.isConnecting {
                    // Waiting for the session after a tap (#161): a small spinner, no words.
                    ProgressView()
                        .controlSize(.small)
                        .tint(ink)
                        .accessibilityIdentifier("race-online-connecting")
                } else if case .cooldown = availability.line {
                    // The one number on Home: the cooldown, counted down each second.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(availability.text(now: context.date) ?? "").font(MenuFont.body(.subheadline)).monospacedDigit()
                    }
                } else if let reason = availability.text(now: .now) {
                    Text(reason).font(MenuFont.body(.subheadline))
                }
            }
            // The page's `menuBackground` text colour would otherwise reach the label: navy on the navy fill.
            .foregroundStyle(ink)
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
            profileButton
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            pageButton(.myBoat, "My boat", systemImage: "sailboat", id: "toolbar-myboat")
            pageButton(.help, "Help", systemImage: "questionmark.circle", id: "toolbar-help")
            pageButton(.settings, "Settings", systemImage: "gearshape", id: "toolbar-settings")
        }
    }

    /// Profile, as her Game Center photo once it's loaded (#25, #139 G6); the symbol until then, or with none.
    @ViewBuilder private var profileButton: some View {
        if let photo = onlineStatus?.playerPhoto {
            Button {
                model.path.append(.profile)
            } label: {
                Label {
                    Text("Profile")
                } icon: {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 28, height: 28)
                        .clipShape(.circle)
                }
            }
            .accessibilityIdentifier("toolbar-profile")
        } else {
            pageButton(.profile, "Profile", systemImage: "person.crop.circle", id: "toolbar-profile")
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
/// What a render fixture puts on Home (#141, `MenuGalleryView`).
struct HomeFixture {
    var rejoin: OnlineRaceController.RejoinEntry?
    var lastRace: RaceResultViewModel?

    /// 12 minutes 41 seconds into a race.
    static let rejoin = HomeFixture(rejoin: OnlineRaceController.RejoinEntry(tick: 761 * Race.tickRate,
                                                                              readAt: RenderFixture.QueueFixture.moment))

    /// The fake services' rated online race, closed, its rating in: third of six, "+12".
    @MainActor static var lastRaceRating: HomeFixture {
        let last = FakeServiceScenario.onlineRace(rated: true).lastRace
        return HomeFixture(lastRace: last.map { RaceResultViewModel(lastRace: $0, livery: FleetLiveries.yours) })
    }
}

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
    /// Game Center has her on the phone but there is no session (#161): the server didn't answer her last tap, or
    /// wouldn't sign her in. The line under Race online, with Try again.
    case tryAgain(RestrictionLine)
    case signIn
    case acceptTerms
    /// Hide lobby chat is on, or Game Center restricts the player's chat (#17, #34): the queue's size and the
    /// leaderboard instead of the chat. No lobby call.
    case chatHidden(queuedPlayers: Int?)
    /// Past Home's gates, the lobby's history read is out (#142).
    case loading
    /// The read failed, or the lobby said closed for a reason Home's gates don't: "Can't reach the lobby".
    case unreachable
    /// The silence window, from her fleet lock until she finishes (#17).
    case silent
    /// The lobby is open: the feed and the composer.
    case lobby

    /// `retryLine`: Game Center has her on the phone, and the server didn't answer her last tap or refused the
    /// sign-in (#161). `lobby`: where the lobby's reads stand, once Home's gates pass; the service's answer never
    /// overrides the gates.
    init(isOnline: Bool, status: LobbyStatus, retryLine: RestrictionLine? = nil, lobby: LobbyModel.Phase = .open) {
        let access = status.access(isOnline: isOnline)
        if !isOnline {
            self = .offline
        } else if !status.isSignedIn {
            self = retryLine.map(LobbyPanelState.tryAgain) ?? .signIn
        } else if access.termsDue {
            self = .acceptTerms
        } else if status.hidesChat || !access.chatVisible {
            self = .chatHidden(queuedPlayers: status.queuedPlayers)
        } else {
            switch lobby {
            case .closed, .loading: self = .loading
            case .unreachable: self = .unreachable
            case .silent: self = .silent
            case .open: self = .lobby
            }
        }
    }

    /// The open lobby fills the rest of Home (G1); every other panel is as tall as it needs.
    var fillsHome: Bool { self == .lobby }
}

/// A notice at the top of the home screen, such as an update or maintenance message, or of the profile (its racing
/// suspension, #139).
struct NoticeRow: View {
    let title: String
    var message = ""
    var id = "home-notice"

    init(notice: AppModel.Notice) {
        self.init(title: notice.title, message: notice.message)
    }

    init(title: String, message: String = "", id: String = "home-notice") {
        self.title = title
        self.message = message
        self.id = id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(MenuFont.heading(.headline))
            if !message.isEmpty {
                Text(message).font(MenuFont.body(.subheadline)).foregroundStyle(.secondary)
            }
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
        .accessibilityIdentifier(id)
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
                if let badge = lastRace.ratingBadge {
                    // The rating change only (#141): nothing for an unrated or a pending race.
                    Text(badge.text)
                        .font(MenuFont.number(.subheadline))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(ChromePalette.tint.opacity(0.18), in: .capsule)
                        .accessibilityLabel(badge.spoken)
                        .accessibilityIdentifier("last-race-rating")
                }
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
/// can: the tap signs in (#25). Past the matrix, what the server and the session say (#161): a suspension, the
/// cooldown, an update, a refusal, each with its line and no tap; an unreachable server or a sign-in that failed,
/// with its line under a button that tries again; and a tap waiting for the session, a spinner and no tap.
struct RaceOnlineAvailability: Equatable {
    var isEnabled: Bool
    /// The gating matrix's line.
    var reason: String?
    /// The server's or the session's line, shown when the matrix has none.
    var line: RestrictionLine?
    var isConnecting = false

    init(isOnline: Bool, lobbyStatus: LobbyStatus, line: RestrictionLine? = nil, isConnecting: Bool = false) {
        let access = lobbyStatus.access(isOnline: isOnline)
        self.init(isEnabled: access.onlineAllowed && !isConnecting && line?.allowsTap != false, reason: access.reason)
        self.isConnecting = isConnecting
        if access.reason == nil { self.line = line }
    }

    init(isEnabled: Bool, reason: String?) {
        self.isEnabled = isEnabled
        self.reason = reason
    }

    /// The line under Race online at `now`: the cooldown counts down.
    func text(now: Date) -> String? { reason ?? line?.text(now: now) }
}
