import Observation
import RegattaServices
import SwiftUI

/// Settings → Blocked players' list (#110, #34): the lobby service's blocked players, each with Unblock.
@Observable
final class BlockedPlayersList {
    private(set) var players: [BlockedPlayer] = []
    /// Nil before the services are in the environment: nobody is blocked.
    @ObservationIgnored private let lobby: (any LobbyService)?

    init(lobby: (any LobbyService)?) {
        self.lobby = lobby
    }

    /// Reads the list from the lobby service; a failed read shows nobody.
    func load() async {
        players = (try? await lobby?.blockedPlayers()) ?? []
    }

    /// Unblocks `player`, then reads the list again.
    func unblock(_ player: BlockedPlayer) async {
        try? await lobby?.unblock(player.gamePlayerID)
        await load()
    }
}

/// Settings → Blocked players: the players the lobby service says are blocked, each with Unblock, or a line saying
/// nobody is.
struct BlockedPlayersPage: View {
    @Environment(\.lobbyService) private var lobby
    @State private var list: BlockedPlayersList?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                let players = list?.players ?? []
                if players.isEmpty {
                    Text("You haven't blocked anyone. Long-press a lobby message to block its sender.")
                        .font(MenuFont.body())
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                } else {
                    ForEach(players, id: \.gamePlayerID) { player in
                        HStack {
                            Text(player.nickname).font(MenuFont.body())
                            Spacer(minLength: 12)
                            Button("Unblock") {
                                Task { await list?.unblock(player) }
                            }
                            .accessibilityIdentifier("blockedPlayers-unblock-\(player.gamePlayerID.rawValue)")
                        }
                        .padding(16)
                        if player.gamePlayerID != players.last?.gamePlayerID { Divider() }
                    }
                    .background(ChromePalette.surface, in: .rect(cornerRadius: 16))
                }
            }
            .padding(.vertical, 20)
            .readableColumn()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("page-blockedPlayers")
        }
        .menuBackground()
        .navigationTitle("Blocked players")
        .task {
            let list = BlockedPlayersList(lobby: lobby)
            self.list = list
            await list.load()
        }
    }
}

extension EnvironmentValues {
    /// The lobby service (#242), for Settings → Blocked players.
    @Entry var lobbyService: (any LobbyService)? = nil
}
