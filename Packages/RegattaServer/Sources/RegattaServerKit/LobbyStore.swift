import Foundation
import Persistence
import RegattaServices
import Synchronization

// Where the lobby's lines and blocks are kept (#152, ADR 0013): Postgres in production (`LobbyMessageStore`, migration
// 0011), memory for a dev server without a database and for tests. The hub holds the last hour and the block graph in
// memory and writes through, so a restart loses neither.

public protocol LobbyStore: Sendable {
    /// Stores `line` and returns its id: ascending in the order stored, never reused.
    func append(_ line: StoredLobbyLine) async throws -> Int64
    /// The newest `limit` lines created at or after `since` that weren't taken down, oldest first.
    func recent(since: Date, limit: Int) async throws -> [StoredLobbyLine]
    /// Takes lines down (#153): kept, marked, until the prune. Returns the ids that were up.
    func remove(ids: [Int64], reason: String, at time: Date) async throws -> [Int64]
    /// Takes down every line the player posted (#153). Returns their ids.
    func removeAll(of playerID: String, reason: String, at time: Date) async throws -> [Int64]
    /// Deletes every line created before `time` (retention: 30 days, #28; #160 schedules it). Returns how many.
    func prune(before time: Date) async throws -> Int
    /// Deletes what the lobby holds of the player (#160): her lines, the winner's lines naming her, the blocks she
    /// made. Blocks against her stay (they are other players'). Returns the deleted lines' ids.
    func deleteAll(of playerID: String) async throws -> [Int64]
    /// Every block: who hides whom (teamPlayerIDs).
    func blocks() async throws -> [(blocker: String, blocked: String)]
    func block(_ blocked: LobbyPlayerRef, by blocker: String, at time: Date) async throws
    func unblock(_ blocked: String, by blocker: String) async throws
    /// The players `blocker` blocks, oldest block first.
    func blockedPlayers(of blocker: String) async throws -> [LobbyPlayerRef]
    /// The player bound to `gamePlayerID`, if the store knows her.
    func player(gamePlayerID: String) async throws -> LobbyPlayerRef?
}

extension LobbyMessageStore: LobbyStore {
    public func block(_ blocked: LobbyPlayerRef, by blocker: String, at time: Date) async throws {
        try await block(blocked.teamPlayerID, by: blocker, at: time)
    }
}

/// The lobby in memory. It knows a player by her lines and by the blocks on her. Lost on restart.
public final class InMemoryLobbyStore: LobbyStore {
    private struct State {
        var nextID: Int64 = 1
        var lines: [StoredLobbyLine] = []
        var removed: [Int64: String] = [:]
        var blocks: [(blocker: String, blocked: LobbyPlayerRef, at: Date)] = []
        var players: [String: LobbyPlayerRef] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    public func append(_ line: StoredLobbyLine) async throws -> Int64 {
        state.withLock { state in
            var stored = line
            stored.id = state.nextID
            state.nextID += 1
            state.lines.append(stored)
            if let author = line.author, let id = line.authorID {
                state.players[author.gamePlayerID] = LobbyPlayerRef(teamPlayerID: id, gamePlayerID: author.gamePlayerID, nickname: author.nickname)
            }
            return stored.id
        }
    }

    public func recent(since: Date, limit: Int) async throws -> [StoredLobbyLine] {
        state.withLock { state in
            Array(state.lines.filter { state.removed[$0.id] == nil && $0.createdAt >= since }.suffix(limit))
        }
    }

    public func remove(ids: [Int64], reason: String, at time: Date) async throws -> [Int64] {
        state.withLock { state in
            let up = state.lines.map(\.id).filter { ids.contains($0) && state.removed[$0] == nil }
            for id in up { state.removed[id] = reason }
            return up
        }
    }

    public func removeAll(of playerID: String, reason: String, at time: Date) async throws -> [Int64] {
        state.withLock { state in
            let up = state.lines.filter { $0.authorID == playerID && state.removed[$0.id] == nil }.map(\.id)
            for id in up { state.removed[id] = reason }
            return up
        }
    }

    public func prune(before time: Date) async throws -> Int {
        state.withLock { state in
            let old = state.lines.filter { $0.createdAt < time }.map(\.id)
            state.lines.removeAll { $0.createdAt < time }
            for id in old { state.removed[id] = nil }
            return old.count
        }
    }

    public func deleteAll(of playerID: String) async throws -> [Int64] {
        state.withLock { state in
            let gone = state.lines.filter { $0.authorID == playerID || $0.subjectID == playerID }.map(\.id)
            state.lines.removeAll { $0.authorID == playerID || $0.subjectID == playerID }
            for id in gone { state.removed[id] = nil }
            state.blocks.removeAll { $0.blocker == playerID }
            state.players = state.players.filter { $0.value.teamPlayerID != playerID }
            return gone
        }
    }

    public func blocks() async throws -> [(blocker: String, blocked: String)] {
        state.withLock { $0.blocks.map { ($0.blocker, $0.blocked.teamPlayerID) } }
    }

    public func block(_ blocked: LobbyPlayerRef, by blocker: String, at time: Date) async throws {
        state.withLock { state in
            guard !state.blocks.contains(where: { $0.blocker == blocker && $0.blocked.teamPlayerID == blocked.teamPlayerID }) else { return }
            state.blocks.append((blocker, blocked, time))
            state.players[blocked.gamePlayerID] = blocked
        }
    }

    public func unblock(_ blocked: String, by blocker: String) async throws {
        state.withLock { $0.blocks.removeAll { $0.blocker == blocker && $0.blocked.teamPlayerID == blocked } }
    }

    public func blockedPlayers(of blocker: String) async throws -> [LobbyPlayerRef] {
        state.withLock { $0.blocks.filter { $0.blocker == blocker }.map(\.blocked) }
    }

    public func player(gamePlayerID: String) async throws -> LobbyPlayerRef? {
        state.withLock { $0.players[gamePlayerID] }
    }

    /// Every stored line, taken down or not, for tests.
    public var allLines: [StoredLobbyLine] { state.withLock { $0.lines } }
}

// MARK: - Moderation's seam (#153)

/// A line a player reports, as moderation is handed it: #153 snapshots it into its own record.
public struct ReportedLine: Sendable, Equatable {
    public var id: Int64
    /// The author's teamPlayerID.
    public var authorID: String
    public var message: LobbyMessage
    public var postedAt: Date
}

/// What chat moderation decides for the lobby (#153 implements it; #152 ships the seam and `NoModeration`).
///
/// `standing` is read before every post and for every state: a failure or a slow answer fails closed (the post isn't
/// sent). `hiddenMessages` are the lines a player reported, hidden from her alone. The `report` calls throw
/// `LobbyError` for what the player got wrong; the lobby has already checked that a reported line is one she can see,
/// isn't her own and isn't a system line. After any change to a player's standing, #153 calls
/// `LobbyHub.refresh(players:)` so her open feeds are told (no shadow mutes); after an upheld report,
/// `LobbyHub.remove(ids:reason:)` or `remove(allOf:reason:)`.
public protocol LobbyModeration: Sendable {
    func standing(of playerID: String) async throws -> ChatStanding
    /// The ids of the lines hidden from `playerID` alone.
    func hiddenMessages(for playerID: String) async throws -> Set<Int64>
    func report(line: ReportedLine, by playerID: String) async throws
    func report(player: LobbyPlayerRef, by playerID: String) async throws
    func report(race: RaceID, seat: Int, reason: RaceReportReason, by playerID: String) async throws
}

/// No moderation (#152's default; never shipped: #153 precedes any build). Everyone stands clear and nothing can be
/// reported. A dev server sets standings on it for the contract's `muted` and `banned` situations.
public final class NoModeration: LobbyModeration {
    private let standings = Mutex<[String: ChatStanding]>([:])

    public init() {}

    /// Dev and tests: `playerID`'s standing from now on (`.clear` forgets it).
    public func set(_ standing: ChatStanding, for playerID: String) {
        standings.withLock { $0[playerID] = standing == .clear ? nil : standing }
    }

    public func standing(of playerID: String) async throws -> ChatStanding { standings.withLock { $0[playerID] ?? .clear } }
    public func hiddenMessages(for playerID: String) async throws -> Set<Int64> { [] }
    public func report(line: ReportedLine, by playerID: String) async throws { throw LobbyError.notReportable }
    public func report(player: LobbyPlayerRef, by playerID: String) async throws { throw LobbyError.notReportable }
    public func report(race: RaceID, seat: Int, reason: RaceReportReason, by playerID: String) async throws { throw LobbyError.notReportable }
}
