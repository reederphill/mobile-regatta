import Foundation
import Persistence
import Ratings
import RegattaCore
import RegattaServices
import Synchronization

// Delete my online data and the retention jobs (#160, #28, G8). A player who asks is shown what goes, confirms, and
// it goes: her profile, rating, livery, chat, the reports she filed and her terms acceptances, with her seats in race
// logs and her server analytics moved to one random id, so past races still replay and nobody else's results change.
// Penalties and reports against her stay for their retention (#153). Her Game Center leaderboard scores are blocked
// through App Store Connect, retried until they are. 730 days without an online session runs the same deletion (G8).
// The retention job also prunes the lobby at 30 days and reports and penalties at a year, or as long as a penalty
// lasts. Raw analytics have their own 90-day purge (#156); sessions their sweep (#146).
//
// #28's other rows: fair-play flags (1 year) are #155's to keep and prune; the server keeps no IP connection logs
// (14 days), so there is nothing to prune; race logs are kept.

/// A player's online data, as the deletion and the inactivity job read and erase it: Postgres in production
/// (`PlayerDataStore`, one transaction), memory for a dev server without a database and for tests.
public protocol OnlineDataStore: Sendable {
    func held(by playerID: String) async throws -> HeldOnlineData
    /// Erases the player's online data and records the deletion; her seats and server analytics become
    /// `anonymousID`'s. False when she isn't stored.
    func erase(_ playerID: String, as anonymousID: String, reason: DeletionReason, at time: Date) async throws -> Bool
    /// Players whose last online session was before `time`, oldest first.
    func inactivePlayers(lastSessionBefore time: Date, limit: Int) async throws -> [String]
    func pendingScoreBlocks(limit: Int) async throws -> [PendingScoreBlock]
    func scoresBlocked(_ id: Int64, count: Int, at time: Date) async throws
    func scoreBlockFailed(_ id: Int64) async throws
    /// The audit, newest first.
    func deletions(limit: Int) async throws -> [DeletionRecord]
}

extension PlayerDataStore: OnlineDataStore {}

/// The online data in the in-memory stores: whichever of them the server runs on memory.
public final class InMemoryOnlineData: OnlineDataStore {
    let accounts: InMemoryAccountStore
    let ratings: InMemoryRatingBook?
    let liveries: InMemoryLiveryStore?
    let lobby: InMemoryLobbyStore?
    let moderation: InMemoryModerationStore?
    let archive: InMemoryRaceArchive?
    let analytics: InMemoryAnalyticsStore?
    private let records = Mutex<(next: Int64, all: [DeletionRecord], failures: [Int64: Int])>((1, [], [:]))

    public init(accounts: InMemoryAccountStore, ratings: InMemoryRatingBook? = nil, liveries: InMemoryLiveryStore? = nil,
                lobby: InMemoryLobbyStore? = nil, moderation: InMemoryModerationStore? = nil, archive: InMemoryRaceArchive? = nil,
                analytics: InMemoryAnalyticsStore? = nil) {
        self.accounts = accounts
        self.ratings = ratings
        self.liveries = liveries
        self.lobby = lobby
        self.moderation = moderation
        self.archive = archive
        self.analytics = analytics
    }

    public func held(by playerID: String) async throws -> HeldOnlineData {
        var kinds: Set<StoredOnlineData> = []
        if let ratings {
            if let standing = try await ratings.standing(of: playerID), standing.completedRaces > 0 || standing.wins > 0 { kinds.insert(.profile) }
            if try await ratings.ratings(of: [playerID])[playerID] != nil { kinds.insert(.rating) }
            if ratings.mirroredRating(of: playerID) != nil { kinds.insert(.leaderboard) }
        }
        if let liveries, try await liveries.livery(of: playerID) != nil { kinds.insert(.livery) }
        if let lobby, lobby.allLines.contains(where: { $0.authorID == playerID }) { kinds.insert(.chat) }
        if let moderation, try await !moderation.reports(by: playerID).isEmpty { kinds.insert(.reportsFiled) }
        if await accounts.lastAcceptedTerms(playerID: playerID) != nil { kinds.insert(.terms) }
        return HeldOnlineData(kinds: kinds, hasRaced: archive?.hasRaced(playerID) ?? false)
    }

    public func erase(_ playerID: String, as anonymousID: String, reason: DeletionReason, at time: Date) async throws -> Bool {
        guard let game = await accounts.gamePlayerID(of: playerID) else { return false }
        archive?.anonymise(playerID, as: anonymousID)
        analytics?.anonymise(playerID, as: anonymousID)
        _ = try await moderation?.deleteReports(by: playerID)
        _ = try await lobby?.deleteAll(of: playerID)
        try await liveries?.delete(of: playerID)
        ratings?.forget(playerID)
        await accounts.delete(playerID)
        records.withLock { records in
            records.all.append(DeletionRecord(id: records.next, reason: reason, deletedAt: time, gamePlayerID: game, scoresBlocked: nil))
            records.next += 1
        }
        return true
    }

    public func inactivePlayers(lastSessionBefore time: Date, limit: Int) async throws -> [String] {
        await accounts.inactivePlayers(lastSessionBefore: time, limit: limit)
    }

    public func pendingScoreBlocks(limit: Int) async throws -> [PendingScoreBlock] {
        records.withLock { records in
            Array(records.all.compactMap { record in
                record.gamePlayerID.map {
                    PendingScoreBlock(id: record.id, gamePlayerID: $0, deletedAt: record.deletedAt, failures: records.failures[record.id] ?? 0)
                }
            }.sorted { ($0.failures, $0.id) < ($1.failures, $1.id) }.prefix(limit))
        }
    }

    public func scoresBlocked(_ id: Int64, count: Int, at time: Date) async throws {
        records.withLock { records in
            guard let index = records.all.firstIndex(where: { $0.id == id }) else { return }
            records.all[index].gamePlayerID = nil
            records.all[index].scoresBlocked = count
        }
    }

    public func scoreBlockFailed(_ id: Int64) async throws { records.withLock { $0.failures[id, default: 0] += 1 } }

    public func deletions(limit: Int) async throws -> [DeletionRecord] { records.withLock { Array($0.all.reversed().prefix(limit)) } }

    /// Dev: `player` holds every kind of online data the stores can hold but chat and terms (the lobby and the sign-in
    /// arrange those): counts, a rating the leaderboard shows, a stored livery, a report she filed on `other`, a seat in
    /// a race.
    public func devHoldEverything(_ player: AccountPlayer, reporting other: String, at time: Date) async throws {
        ratings?.setStats(completedRaces: 1, wins: 0, for: player.teamPlayerID)
        ratings?.set(PlayerRating(), for: player.teamPlayerID)
        try await ratings?.mirrored(player.teamPlayerID, rating: PlayerRating().displayed)
        try await liveries?.save(try await StarterLiveries().livery(of: player), for: player.teamPlayerID, at: time)
        _ = try await moderation?.file(StoredReport(kind: .player, reporterID: player.teamPlayerID, subjectID: other, subjectNickname: "Contract Crew",
                                                    createdAt: time, dueAt: time + 86_400))
        try await archive?.register(UUID(), players: [RaceSeatHolder(playerID: player.teamPlayerID, seat: 0)])
    }
}

// MARK: - The leaderboard

/// Blocks deleted players' scores on the Game Center leaderboard (#160): blocking takes an entry off it.
public protocol ScoreBlocking: Sendable {
    /// Blocks, in one pass over the leaderboard, each player's scores not blocked yet that were submitted by her
    /// deletion (`players`: gamePlayerID → deletion time): a player who came back keeps her new ones. Returns how many
    /// it blocked of each.
    func blockScores(of players: [String: Date]) async throws -> [String: Int]
}

public enum HTTPSMethod: Sendable, Equatable {
    case get, patch
}

public struct HTTPSReply: Sendable, Equatable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

/// An HTTPS request with a bearer token and an optional JSON body: the seam App Store Connect's score moderation is
/// tested through. `target` is the path and query.
public protocol HTTPSRequesting: Sendable {
    func request(_ method: HTTPSMethod, host: String, target: String, bearer: String, json: Data?) async throws -> HTTPSReply
}

public enum ScoreBlockError: Error, Equatable, Sendable {
    case status(Int)
    /// A list page's `next` link pointed off App Store Connect.
    case badNextLink(String)
    case tooManyPages
}

/// App Store Connect's score moderation (API 4.5): `GET /v2/gameCenterLeaderboards/{id}/gameCenterScoreModerations`
/// lists a leaderboard's scores (`include=player`, `limit` up to 200, then the `links.next` pages), and
/// `PATCH /v1/gameCenterScoreModerations/{id}` with `{"data": {"type": "gameCenterScoreModerations", "id": …,
/// "attributes": {"blocked": true}}}` blocks one (200). Read 2026-10-12 from the API reference's endpoint and
/// `GameCenterScoreModeration`, `…Attributes` (`blocked`, `score`, `rank`, …), `…Relationships.Player.Data`
/// (`type` `gameCenterDetailPlayers`, `id`) and `GameCenterScoreModerationUpdateRequest` pages. The list has no
/// filter by player, so the whole leaderboard is paged.
///
/// Not from the reference, which doesn't say: that a score's player relationship `id` is the player's scoped
/// `gamePlayerID`, as the submission's `scopedPlayerId` is (#151). #55 confirms it with the first real deletion; until
/// then a deletion whose player matches no score blocks none, and the audit says 0. `leaderboardResourceID` is the
/// leaderboard's App Store Connect resource id (`GC_LEADERBOARD_RESOURCE_ID`), not its vendor identifier.
public struct AppStoreConnectScoreModeration: ScoreBlocking {
    public static let host = AppStoreConnectLeaderboard.host
    static let pageLimit = 200
    static let maxPages = 5000

    let tokens: AppStoreConnectLeaderboard
    let leaderboardResourceID: String
    let requester: any HTTPSRequesting
    let now: @Sendable () -> Date

    public init(tokens: AppStoreConnectLeaderboard, leaderboardResourceID: String, requester: any HTTPSRequesting,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.tokens = tokens
        self.leaderboardResourceID = leaderboardResourceID
        self.requester = requester
        self.now = now
    }

    struct Page: Decodable {
        struct Score: Decodable {
            struct Attributes: Decodable {
                var blocked: Bool?
                var submittedDate: String?
            }
            struct Relationships: Decodable {
                struct Player: Decodable {
                    struct Data: Decodable { var id: String }
                    var data: Data?
                }
                var player: Player?
            }
            var id: String
            var attributes: Attributes?
            var relationships: Relationships?
        }
        struct Links: Decodable { var next: String? }
        var data: [Score]
        var links: Links?
    }

    private struct Block: Encodable {
        struct Entry: Encodable {
            struct Attributes: Encodable { var blocked = true }
            var type = "gameCenterScoreModerations"
            var id: String
            var attributes = Attributes()
        }
        var data: Entry
    }

    /// The first page's path and query.
    var firstPage: String {
        let id = leaderboardResourceID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? leaderboardResourceID
        return "/v2/gameCenterLeaderboards/\(id)/gameCenterScoreModerations?include=player&limit=\(Self.pageLimit)"
    }

    /// The players' scores not blocked yet and submitted by their deadlines, by moderation id and player, from every
    /// page. A score without a readable submission date is taken as hers.
    func scores(of players: [String: Date]) async throws -> [(id: String, player: String)] {
        var target: String? = firstPage
        var found: [(id: String, player: String)] = []
        let dates = ISO8601DateFormatter(), fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var pages = 0
        while let current = target {
            pages += 1
            guard pages <= Self.maxPages else { throw ScoreBlockError.tooManyPages }
            let reply = try await requester.request(.get, host: Self.host, target: current, bearer: try tokens.bearer(at: now()), json: nil)
            guard reply.status == 200 else { throw ScoreBlockError.status(reply.status) }
            let page = try JSONDecoder().decode(Page.self, from: reply.body)
            for score in page.data where score.attributes?.blocked != true {
                guard let player = score.relationships?.player?.data?.id, let deadline = players[player] else { continue }
                let submitted = score.attributes?.submittedDate.flatMap { dates.date(from: $0) ?? fractional.date(from: $0) }
                if submitted.map({ $0 <= deadline }) ?? true { found.append((score.id, player)) }
            }
            target = try page.links?.next.map(Self.target)
        }
        return found
    }

    /// A `next` link's path and query, if it is App Store Connect's.
    static func target(_ link: String) throws -> String {
        guard let url = URLComponents(string: link), url.scheme == "https", url.host == host, !url.percentEncodedPath.isEmpty else {
            throw ScoreBlockError.badNextLink(link)
        }
        let target = url.percentEncodedPath + (url.percentEncodedQuery.map { "?" + $0 } ?? "")
        guard target.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }) else { throw ScoreBlockError.badNextLink(link) }
        return target
    }

    public func blockScores(of players: [String: Date]) async throws -> [String: Int] {
        guard !players.isEmpty else { return [:] }
        let found = try await scores(of: players)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var blocked = players.mapValues { _ in 0 }
        for (id, player) in found {
            let path = "/v1/gameCenterScoreModerations/" + (id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id)
            let reply = try await requester.request(.patch, host: Self.host, target: path, bearer: try tokens.bearer(at: now()),
                                                    json: try encoder.encode(Block(data: .init(id: id))))
            guard reply.status == 200 else { throw ScoreBlockError.status(reply.status) }
            blocked[player, default: 0] += 1
        }
        return blocked
    }
}

// MARK: - Deleting

public struct DeletionSettings: Sendable, Equatable {
    /// How long a plan's confirmation is good for.
    public var confirmationLifetime: TimeInterval = 10 * 60
    /// G8: the inactivity job deletes a player this long after her last online session.
    public var inactiveAfterDays = 730
    /// The retention job's period.
    public var interval: Duration = .seconds(3600)
    /// #28: lobby lines are kept 30 days; reports and penalties a year, or as long as a penalty lasts.
    public var chatDays = 30
    public var moderationDays = 365
    /// Players deleted, and deletions whose scores are blocked, per run.
    public var batch = 100

    public init() {}
}

/// Delete my online data (#160): the plan and its confirmation, the deletion, the inactivity job and the leaderboard.
public final class OnlineDataDeletion: Sendable {
    public let store: any OnlineDataStore
    public let settings: DeletionSettings
    let scores: (any ScoreBlocking)?
    let now: @Sendable () -> Date
    /// The lobby's memory of her (the ring, her feeds) goes too.
    private let lobby = LateBound<LobbyHub>()
    /// The confirmation each player was last given, and when.
    private let confirmations = Mutex<[String: (token: String, issued: Date)]>([:])
    /// Whether a deletion starts blocking its scores at once (else the retention job's next run does).
    let blocksAtOnce: Bool
    /// Before her data goes: the queue lets her go (her place, and any seat she holds), so no race registers her after.
    let beforeErase: @Sendable (String) async -> Void
    /// One block run at a time: two would block the same scores twice.
    private let blocking = Mutex(false)

    public init(store: any OnlineDataStore, settings: DeletionSettings = DeletionSettings(), scores: (any ScoreBlocking)? = nil,
                blocksAtOnce: Bool = true, beforeErase: @escaping @Sendable (String) async -> Void = { _ in },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.settings = settings
        self.scores = scores
        self.blocksAtOnce = blocksAtOnce
        self.beforeErase = beforeErase
        self.now = now
    }

    public func attach(_ hub: LobbyHub) { lobby.set(hub) }

    static func kind(_ stored: StoredOnlineData) -> OnlineData {
        switch stored {
        case .profile: .profile
        case .rating: .rating
        case .livery: .livery
        case .chat: .chatHistory
        case .reportsFiled: .reportsFiled
        case .leaderboard: .leaderboardEntry
        case .terms: .termsAcceptance
        }
    }

    /// What deleting would take now, and a confirmation for it: the newest voids any earlier one.
    public func plan(for playerID: String) async throws -> DeletionPlan {
        let held = try await store.held(by: playerID)
        guard !held.isEmpty else { throw DataDeletionError.nothingToDelete }
        let token = UUID().uuidString, time = now()
        let lifetime = settings.confirmationLifetime
        confirmations.withLock { confirmations in
            confirmations = confirmations.filter { time.timeIntervalSince($0.value.issued) <= lifetime }
            confirmations[playerID] = (token, time)
        }
        return DeletionPlan(deletes: Set(held.kinds.map(Self.kind)), anonymisesRaceLogs: held.hasRaced,
                            confirmation: DeletionConfirmation(token: token))
    }

    /// Deletes her online data, once she has confirmed her newest plan.
    public func delete(_ playerID: String, confirmedBy confirmation: DeletionConfirmation) async throws {
        guard try await !store.held(by: playerID).isEmpty else { throw DataDeletionError.nothingToDelete }
        let time = now()
        let valid = confirmations.withLock { confirmations in
            guard let issued = confirmations[playerID], issued.token == confirmation.token,
                  time.timeIntervalSince(issued.issued) <= settings.confirmationLifetime else { return false }
            return true
        }
        guard valid else { throw DataDeletionError.invalidConfirmation }
        guard try await erase(playerID, reason: .request) else { throw DataDeletionError.nothingToDelete }
        confirmations.withLock { $0[playerID] = nil }
        if blocksAtOnce { Task { await self.blockPendingScores() } }
    }

    /// Erases the player under a new anonymous id, then clears the lobby's memory of her.
    func erase(_ playerID: String, reason: DeletionReason) async throws -> Bool {
        let anonymous = PlayerDataStore.anonymousPrefix + UUID().uuidString.lowercased()
        await beforeErase(playerID)
        guard try await store.erase(playerID, as: anonymous, reason: reason, at: now()) else { return false }
        do {
            try await lobby.value?.deleteAll(of: playerID)
        } catch {
            Self.log("the lobby can't forget \(playerID) now (her lines are gone from the store): \(error)")
        }
        return true
    }

    /// G8: deletes, as Delete my online data does, every player without an online session for `inactiveAfterDays`.
    /// Returns how many.
    @discardableResult
    public func eraseInactive() async -> Int {
        let cutoff = now() - TimeInterval(settings.inactiveAfterDays) * 86_400
        var erased = 0
        do {
            for player in try await store.inactivePlayers(lastSessionBefore: cutoff, limit: settings.batch) {
                if try await erase(player, reason: .inactive) { erased += 1 }
            }
        } catch {
            Self.log("the inactivity job failed after \(erased): \(error)")
        }
        return erased
    }

    /// Blocks the scores of deletions not blocked yet. Returns how many deletions it finished (none while another run
    /// is under way).
    @discardableResult
    public func blockPendingScores() async -> Int {
        guard let scores, blocking.withLock({ running in
            defer { running = true }
            return !running
        }) else { return 0 }
        defer { blocking.withLock { $0 = false } }
        var finished = 0
        do {
            let pending = try await store.pendingScoreBlocks(limit: settings.batch)
            guard !pending.isEmpty else { return 0 }
            // One pass for them all; a player deleted twice is blocked up to her latest deletion.
            let players = Dictionary(pending.map { ($0.gamePlayerID, $0.deletedAt) }, uniquingKeysWith: max)
            let blocked: [String: Int]
            do {
                blocked = try await scores.blockScores(of: players)
            } catch {
                Self.log("can't block \(pending.count) deletions' scores: \(error)")
                for each in pending { try await store.scoreBlockFailed(each.id) }
                return 0
            }
            for each in pending {
                try await store.scoresBlocked(each.id, count: blocked[each.gamePlayerID] ?? 0, at: now())
                finished += 1
            }
        } catch {
            Self.log("can't read or record the scores to block: \(error)")
        }
        return finished
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("RegattaServer: data deletion: \(message)\n".utf8))
    }
}

/// Delete my online data for a signed-in player.
struct ServerDataDeletionService: DataDeletionService {
    let deletion: OnlineDataDeletion
    let player: AccountPlayer

    func plan() async throws -> DeletionPlan { try await deletion.plan(for: player.teamPlayerID) }
    func delete(confirmedBy confirmation: DeletionConfirmation) async throws {
        try await deletion.delete(player.teamPlayerID, confirmedBy: confirmation)
    }
}

/// Delete my online data on a connection nobody is signed in on: `notSignedIn`, as the contract says.
struct SignedOutDeletionService: DataDeletionService {
    func plan() async throws -> DeletionPlan { throw DataDeletionError.notSignedIn }
    func delete(confirmedBy confirmation: DeletionConfirmation) async throws { throw DataDeletionError.notSignedIn }
}

// MARK: - Retention

/// What one run of the retention job did.
public struct RetentionRun: Sendable, Equatable {
    public var chatLines = 0
    public var penalties = 0
    public var reports = 0
    public var inactivePlayers = 0
    public var scoreBlocks = 0
    /// App Attest keys unused for `inactiveAfterDays` (#158).
    public var appAttestKeys = 0
}

/// The retention job (#160, #28): the lobby at 30 days, reports and penalties at a year (or the penalty's length), the
/// inactivity deletion (G8), the leaderboard blocks still owed and App Attest keys unused as long as an inactive player
/// (#158), every `interval` while the server listens.
public final class RetentionJobs: Sendable {
    let deletion: OnlineDataDeletion
    let moderation: any ModerationStore
    let lobby: LobbyHub?
    let appAttestKeys: (any AppAttestKeyStore)?
    let now: @Sendable () -> Date
    private let loop = Mutex<Task<Void, Never>?>(nil)

    public init(deletion: OnlineDataDeletion, moderation: any ModerationStore, lobby: LobbyHub?, appAttestKeys: (any AppAttestKeyStore)? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.deletion = deletion
        self.moderation = moderation
        self.lobby = lobby
        self.appAttestKeys = appAttestKeys
        self.now = now
    }

    @discardableResult
    public func runOnce() async -> RetentionRun {
        var run = RetentionRun()
        let time = now(), settings = deletion.settings
        if let lobby {
            do {
                run.chatLines = try await lobby.prune(before: time - TimeInterval(settings.chatDays) * 86_400)
            } catch {
                OnlineDataDeletion.log("the lobby prune failed: \(error)")
            }
        }
        do {
            (run.penalties, run.reports) = try await moderation.prune(before: time - TimeInterval(settings.moderationDays) * 86_400, at: time)
        } catch {
            OnlineDataDeletion.log("the moderation prune failed: \(error)")
        }
        run.inactivePlayers = await deletion.eraseInactive()
        run.scoreBlocks = await deletion.blockPendingScores()
        if let appAttestKeys {
            do {
                run.appAttestKeys = try await appAttestKeys.purge(unusedSince: time - TimeInterval(settings.inactiveAfterDays) * 86_400)
            } catch {
                OnlineDataDeletion.log("the App Attest key purge failed: \(error)")
            }
        }
        return run
    }

    public func start() {
        let interval = deletion.settings.interval
        loop.withLock { loop in
            guard loop == nil else { return }
            loop = Task { [self] in
                while !Task.isCancelled {
                    await runOnce()
                    try? await Task.sleep(for: interval)
                }
            }
        }
    }

    public func stop() {
        loop.withLock { loop in
            loop?.cancel()
            loop = nil
        }
    }
}
