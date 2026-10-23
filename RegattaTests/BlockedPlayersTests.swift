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
        #expect(fresh.state == .loaded([]))
    }

    /// A read that can't be made, or failed, is never "nobody blocked" (#142, G16): offline, signed out, or Try again.
    @Test func aFailedReadIsNotNobodyBlocked() async {
        let list = BlockedPlayersList(lobby: FailingBlockedList())
        await list.load(isOnline: false, isSignedIn: true)
        #expect(list.state == .offline)
        await list.load(isOnline: true, isSignedIn: false)
        #expect(list.state == .signedOut)
        await list.load()
        #expect(list.state == .unreachable)
        #expect(list.players.isEmpty && list.state != .loaded([]))
    }

    /// Delete my online data's seam (#166) leaves today's notice until the deletion service fills it.
    @Test func deletionSeamDefaultsToTheNotice() async {
        #expect(await SettingsView.deletionArrivesLater() == "Deleting online data arrives with online accounts.")
    }
}

/// A lobby whose blocked list can't be read.
private struct FailingBlockedList: LobbyService {
    let base = ServiceSet.fake(.joinable).lobby

    func state() async throws -> LobbyState { try await base.state() }
    func history() async throws -> [LobbyMessage] { try await base.history() }
    func feed() -> AsyncStream<LobbyEvent> { base.feed() }
    func post(_ text: String) async throws -> LobbyMessage { try await base.post(text) }
    func post(_ quickChat: QuickChat) async throws -> LobbyMessage { try await base.post(quickChat) }
    func block(_ player: GamePlayerID) async throws { try await base.block(player) }
    func unblock(_ player: GamePlayerID) async throws { try await base.unblock(player) }
    func blockedPlayers() async throws -> [BlockedPlayer] { throw LobbyError.closed(.notSignedIn) }
    func report(message: MessageID) async throws {}
    func report(player: GamePlayerID) async throws {}
    func report(race: RaceID, seat: Int, reason: RaceReportReason) async throws {}
    func boatCard(_ player: GamePlayerID) async throws -> BoatCard { try await base.boatCard(player) }
}
