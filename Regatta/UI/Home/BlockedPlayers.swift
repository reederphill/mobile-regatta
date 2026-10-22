import Observation
import RegattaServices
import SwiftUI

/// Settings → Blocked players' list (#110, #34): the lobby service's blocked players, each with Unblock.
@Observable
final class BlockedPlayersList {
    /// Where the list stands (#142, G16): a read that failed is never "nobody blocked".
    enum State: Equatable {
        case loading
        case loaded([BlockedPlayer])
        /// No connection: no read.
        case offline
        /// Signed out of Game Center: no read.
        case signedOut
        /// The read failed: Try again.
        case unreachable
    }

    private(set) var state = State.loading
    /// Nil before the services are in the environment: nobody is blocked.
    @ObservationIgnored private let lobby: (any LobbyService)?

    init(lobby: (any LobbyService)?) {
        self.lobby = lobby
    }

    /// The players listed: none until a read gives them.
    var players: [BlockedPlayer] {
        if case .loaded(let players) = state { players } else { [] }
    }

    /// Reads the list from the lobby service, unless Home's gates already say it can't be read.
    func load(isOnline: Bool = true, isSignedIn: Bool = true) async {
        guard isOnline else { return state = .offline }
        guard isSignedIn else { return state = .signedOut }
        guard let lobby else { return state = .loaded([]) }
        do {
            state = .loaded(try await lobby.blockedPlayers())
        } catch {
            state = .unreachable
        }
    }

    /// Unblocks `player`, then reads the list again.
    func unblock(_ player: BlockedPlayer) async {
        try? await lobby?.unblock(player.gamePlayerID)
        await load()
    }
}

/// Settings → Blocked players: the players the lobby service says are blocked, each with Unblock, or a line saying
/// nobody is, or why the list can't be read.
struct BlockedPlayersPage: View {
    @Environment(\.lobbyService) private var lobby
    @Environment(\.isOnline) private var isOnline
    @Environment(\.lobbyStatus) private var lobbyStatus
    @State private var list: BlockedPlayersList?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                switch list?.state ?? .loading {
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                case .loaded(let players) where players.isEmpty:
                    // TODO-COPY (#171)
                    line("You haven't blocked anyone. Long-press a lobby message to block its sender.")
                case .loaded(let players):
                    rows(players)
                case .offline:
                    // TODO-COPY (#171)
                    line("Lobby needs a connection")
                case .signedOut:
                    // TODO-COPY (#171)
                    line("Sign in to Game Center to see who you blocked")
                case .unreachable:
                    VStack(spacing: 12) {
                        // TODO-COPY (#171)
                        line("Can't reach the lobby", padded: false)
                        // TODO-COPY (#171)
                        Button("Try again") { Task { await load() } }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("blockedPlayers-retry")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                }
            }
            .padding(.vertical, 20)
            .readableColumn()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("page-blockedPlayers")
        }
        .menuBackground()
        // TODO-COPY (#171)
        .navigationTitle("Blocked players")
        .task {
            list = BlockedPlayersList(lobby: lobby)
            await load()
        }
    }

    private func load() async {
        await list?.load(isOnline: isOnline, isSignedIn: lobbyStatus.isSignedIn)
    }

    private func line(_ text: String, padded: Bool = true) -> some View {
        Text(text)
            .font(MenuFont.body())
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, padded ? 40 : 0)
    }

    private func rows(_ players: [BlockedPlayer]) -> some View {
        VStack(spacing: 0) {
            ForEach(players, id: \.gamePlayerID) { player in
                HStack {
                    Text(player.nickname).font(MenuFont.body())
                    Spacer(minLength: 12)
                    // TODO-COPY (#171)
                    Button("Unblock") {
                        Task { await list?.unblock(player) }
                    }
                    .accessibilityIdentifier("blockedPlayers-unblock-\(player.gamePlayerID.rawValue)")
                }
                .padding(16)
                if player.gamePlayerID != players.last?.gamePlayerID { Divider() }
            }
        }
        .background(ChromePalette.surface, in: .rect(cornerRadius: 16))
    }
}

extension EnvironmentValues {
    /// The lobby service (#242), for Settings → Blocked players.
    @Entry var lobbyService: (any LobbyService)? = nil
}
