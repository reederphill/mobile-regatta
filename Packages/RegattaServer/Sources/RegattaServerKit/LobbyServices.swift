import Foundation
import RegattaServices
import Synchronization

/// The lobby for one connection's player (#152), over the hub. The gate has already let her in: signed in, allowed
/// to chat by Game Center's restrictions, the current terms accepted (a connection it turns away gets
/// `ClosedLobbyService`). Its feeds end with the connection, and when the connection signs in as someone restricted.
///
/// A call that throws anything but a `LobbyError` (the store or moderation can't be read) has no answer on the wire:
/// the endpoint closes the connection and the client backs off.
public struct ServerLobbyService: LobbyService, ConnectionScoped {
    public let hub: LobbyHub
    public let player: AccountPlayer
    private let feeds = FeedTokens()

    public init(hub: LobbyHub, player: AccountPlayer) {
        self.hub = hub
        self.player = player
        hub.known(player)
    }

    public func state() async throws -> LobbyState { try await hub.state(of: player.teamPlayerID) }
    public func history() async throws -> [LobbyMessage] { try await hub.history(for: player.teamPlayerID) }

    public func feed() -> AsyncStream<LobbyEvent> {
        let (stream, token) = hub.openFeed(player)
        feeds.add(token)
        return stream
    }

    public func post(_ text: String) async throws -> LobbyMessage { try await hub.post(.text(text), by: player) }
    public func post(_ quickChat: QuickChat) async throws -> LobbyMessage { try await hub.post(.quickChat(quickChat), by: player) }

    public func block(_ other: GamePlayerID) async throws { try await hub.block(other, by: player) }
    public func unblock(_ other: GamePlayerID) async throws { try await hub.unblock(other, by: player) }
    public func blockedPlayers() async throws -> [BlockedPlayer] { try await hub.blockedPlayers(of: player.teamPlayerID) }

    public func report(message: MessageID) async throws { try await hub.report(message: message, by: player.teamPlayerID) }
    public func report(player other: GamePlayerID) async throws { try await hub.report(player: other, by: player) }
    public func report(race: RaceID, seat: Int, reason: RaceReportReason) async throws {
        try await hub.report(race: race, seat: seat, reason: reason, by: player.teamPlayerID)
    }

    public func boatCard(_ other: GamePlayerID) async throws -> BoatCard { try await hub.boatCard(other, for: player) }

    public func connectionEnded() async {
        hub.closeFeeds(feeds.take())
    }
}

/// The feeds one connection opened.
private final class FeedTokens: Sendable {
    private let tokens = Mutex<[UUID]>([])

    func add(_ token: UUID) {
        tokens.withLock { tokens in
            tokens.append(token)
            // The hub keeps a player's newest feeds only; so does this list.
            if tokens.count > 8 { tokens.removeFirst(tokens.count - 8) }
        }
    }

    func take() -> [UUID] {
        tokens.withLock { tokens in
            defer { tokens = [] }
            return tokens
        }
    }
}
