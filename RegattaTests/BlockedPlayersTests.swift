import RegattaServices
import Testing
@testable import Regatta

/// Settings → Blocked players (#110): the lobby service's list, with Unblock.
@MainActor @Suite struct BlockedPlayersTests {
    /// A player blocked in the lobby is listed by name; Unblock takes them off the list and out of the service's.
    @Test func listsTheLobbysBlockedPlayersAndUnblocks() async throws {
        let lobby = ServiceSet.fake(.queued).lobby
        let wren = GamePlayerID("G:fake-2")
        try await lobby.block(wren)

        let list = BlockedPlayersList(lobby: lobby)
        await list.load()
        #expect(list.players == [BlockedPlayer(gamePlayerID: wren, nickname: "Wren")])

        await list.unblock(try #require(list.players.first))
        #expect(list.players.isEmpty)
        #expect(try await lobby.blockedPlayers().isEmpty)
    }

    /// With no lobby service, or nobody blocked, the list is empty (the page shows its empty line).
    @Test func nobodyBlockedIsAnEmptyList() async {
        let none = BlockedPlayersList(lobby: nil)
        await none.load()
        #expect(none.players.isEmpty)
        let fresh = BlockedPlayersList(lobby: ServiceSet.fake(.queued).lobby)
        await fresh.load()
        #expect(fresh.players.isEmpty)
    }

    /// Delete my online data's seam (#166) leaves today's notice until the deletion service fills it.
    @Test func deletionSeamDefaultsToTheNotice() async {
        #expect(await SettingsView.deletionArrivesLater() == "Deleting online data arrives with online accounts.")
    }
}
