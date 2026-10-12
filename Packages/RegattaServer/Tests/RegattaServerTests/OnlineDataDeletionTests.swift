import Crypto
import Foundation
import Persistence
import Ratings
import RegattaCore
@testable import RegattaServerKit
import RegattaServices
import Synchronization
import Testing

/// App Store Connect on a stub: the score moderations listed in pages, and each PATCH recorded.
final class StubAppStoreConnect: HTTPSRequesting, HTTPSPosting {
    struct Sent: Equatable {
        var method: HTTPSMethod
        var target: String
        var body: String?
    }

    private let state = Mutex<(sent: [Sent], pages: [String: String], patchStatus: Int)>(([], [:], 200))

    /// `pages`: each list target's JSON reply.
    init(pages: [String: String]) { state.withLock { $0.pages = pages } }

    var sent: [Sent] { state.withLock { $0.sent } }
    func patches(answer status: Int) { state.withLock { $0.patchStatus = status } }

    func request(_ method: HTTPSMethod, host: String, target: String, bearer: String, json: Data?) async throws -> HTTPSReply {
        #expect(host == "api.appstoreconnect.apple.com" && !bearer.isEmpty)
        return state.withLock { state in
            state.sent.append(Sent(method: method, target: target, body: json.map { String(decoding: $0, as: UTF8.self) }))
            switch method {
            case .get: return state.pages[target].map { HTTPSReply(status: 200, body: Data($0.utf8)) } ?? HTTPSReply(status: 404, body: Data())
            case .patch: return HTTPSReply(status: state.patchStatus, body: Data("{}".utf8))
            }
        }
    }

    func post(host: String, path: String, bearer: String, json: Data) async throws -> Int { 201 }
}

/// A score blocker that records whom it blocked, and can fail.
final class FakeScoreBlocker: ScoreBlocking {
    private let state = Mutex<(blocked: [String], failing: Bool)>(([], false))
    var blocked: [String] { state.withLock { $0.blocked } }
    func fail(_ failing: Bool) { state.withLock { $0.failing = failing } }

    struct Down: Error {}

    func blockScores(of players: [String: Date]) async throws -> [String: Int] {
        try state.withLock { state in
            if state.failing { throw Down() }
            state.blocked += players.keys.sorted()
            return players.mapValues { _ in 2 }
        }
    }
}

/// The deletion over every in-memory store, on a virtual clock.
struct DeletionRig {
    let clock = VirtualClock()
    let accounts = InMemoryAccountStore()
    let book = InMemoryRatingBook()
    let liveries = InMemoryLiveryStore()
    let lobbyStore = InMemoryLobbyStore()
    let moderation = InMemoryModerationStore()
    let archive = InMemoryRaceArchive()
    let analytics = InMemoryAnalyticsStore()
    let scores = FakeScoreBlocker()
    let memory: InMemoryOnlineData
    let deletion: OnlineDataDeletion
    let hub: LobbyHub
    let retention: RetentionJobs

    init() {
        let clock = clock
        memory = InMemoryOnlineData(accounts: accounts, ratings: book, liveries: liveries, lobby: lobbyStore, moderation: moderation,
                                    archive: archive, analytics: analytics)
        deletion = OnlineDataDeletion(store: memory, scores: scores, blocksAtOnce: false, now: { clock.now })
        hub = LobbyRig.hub(store: lobbyStore, book: book, moderation: NoModeration(), clock: clock)
        deletion.attach(hub)
        retention = RetentionJobs(deletion: deletion, moderation: moderation, lobby: hub, now: { clock.now })
    }

    func player(_ name: String) -> AccountPlayer { AccountPlayer(teamPlayerID: "T:\(name)", gamePlayerID: "G:\(name)", alias: name) }

    /// `name` signed in now, with terms, and everything `devHoldEverything` holds, and a lobby line.
    @discardableResult
    func holding(_ name: String) async throws -> AccountPlayer {
        let player = player(name)
        _ = try await accounts.signIn(teamPlayerID: player.teamPlayerID, gamePlayerID: player.gamePlayerID, alias: name)
        await accounts.touchSession(teamPlayerID: player.teamPlayerID, at: clock.now)
        await accounts.acceptTerms(playerID: player.teamPlayerID, version: 1, at: clock.now)
        try await memory.devHoldEverything(player, reporting: "T:other", at: clock.now)
        await hub.devPost("fair winds", by: player)
        return player
    }
}

@Suite(.timeLimit(.minutes(1))) struct OnlineDataDeletionTests {
    // MARK: The plan and the deletion

    @Test func planConfirmDeleteAndNothingAfter() async throws {
        let rig = DeletionRig()
        let wren = try await rig.holding("wren")
        try await rig.archive.register(UUID(), players: [RaceSeatHolder(playerID: "T:wren", seat: 0), RaceSeatHolder(playerID: "T:gull", seat: 1)])
        _ = try await rig.moderation.file(StoredReport(kind: .player, reporterID: "T:gull", subjectID: "T:wren", subjectNickname: "wren",
                                                       createdAt: rig.clock.now, dueAt: rig.clock.now + 86_400))
        try await rig.analytics.recordServer(StoredAnalyticsEvent(source: .server, playerID: "T:wren", name: "earned_unlock",
                                                                  day: StoredAnalyticsEvent.day(of: rig.clock.now), occurredAt: rig.clock.now,
                                                                  receivedAt: rig.clock.now))
        let service = ServerDataDeletionService(deletion: rig.deletion, player: wren)
        let plan = try await service.plan()
        #expect(plan.deletes == Set(OnlineData.allCases) && plan.anonymisesRaceLogs)
        await #expect(throws: DataDeletionError.invalidConfirmation) { try await service.delete(confirmedBy: DeletionConfirmation(token: "forged")) }
        // A newer plan voids the older confirmation.
        let newer = try await service.plan()
        await #expect(throws: DataDeletionError.invalidConfirmation) { try await service.delete(confirmedBy: plan.confirmation) }
        try await service.delete(confirmedBy: newer.confirmation)
        await #expect(throws: DataDeletionError.nothingToDelete) { _ = try await service.plan() }
        await #expect(throws: DataDeletionError.nothingToDelete) { try await service.delete(confirmedBy: newer.confirmation) }

        #expect(try await rig.memory.held(by: "T:wren").isEmpty)
        #expect(await rig.accounts.player(teamPlayerID: "T:wren") == nil)
        #expect(try await rig.liveries.livery(of: "T:wren") == nil)
        #expect(try await rig.book.ratings(of: ["T:wren"]).isEmpty && rig.book.mirroredRating(of: "T:wren") == nil)
        #expect(try await rig.moderation.reports(by: "T:wren").isEmpty)
        #expect(try await rig.moderation.reports(against: "T:wren", since: .distantPast).count == 1)
        #expect(try await rig.hub.history(for: "T:gull").isEmpty)
        // Her seats and server events are one anonymous id's; the other player's seat is as it was.
        let seats = rig.archive.hasRaced("T:gull")
        #expect(seats && !rig.archive.hasRaced("T:wren"))
        let audit = try await rig.memory.deletions(limit: 10)
        #expect(audit.count == 1 && audit[0].reason == .request)
    }

    @Test func aConfirmationExpires() async throws {
        let rig = DeletionRig()
        let wren = try await rig.holding("wren")
        let plan = try await rig.deletion.plan(for: wren.teamPlayerID)
        rig.clock.advance(10 * 60 + 1)
        await #expect(throws: DataDeletionError.invalidConfirmation) { try await rig.deletion.delete("T:wren", confirmedBy: plan.confirmation) }
    }

    @Test func nothingHeldIsNothingToDelete() async throws {
        let rig = DeletionRig()
        _ = try await rig.accounts.signIn(teamPlayerID: "T:new", gamePlayerID: "G:new", alias: "new")
        await #expect(throws: DataDeletionError.nothingToDelete) { _ = try await rig.deletion.plan(for: "T:new") }
        await #expect(throws: DataDeletionError.notSignedIn) { _ = try await SignedOutDeletionService().plan() }
    }

    // MARK: The leaderboard

    @Test func scoresAreBlockedAndRetriedUntilTheyAre() async throws {
        let rig = DeletionRig()
        rig.scores.fail(true)
        let wren = try await rig.holding("wren")
        try await rig.deletion.delete(wren.teamPlayerID, confirmedBy: try await rig.deletion.plan(for: wren.teamPlayerID).confirmation)
        #expect(await rig.deletion.blockPendingScores() == 0)
        #expect(try await rig.memory.pendingScoreBlocks(limit: 10).map(\.failures) == [1])
        rig.scores.fail(false)
        #expect(await rig.retention.runOnce().scoreBlocks == 1)
        #expect(rig.scores.blocked.last == "G:wren")
        #expect(try await rig.memory.pendingScoreBlocks(limit: 10).isEmpty)
        let audit = try #require(try await rig.memory.deletions(limit: 1).first)
        #expect(audit.gamePlayerID == nil && audit.scoresBlocked == 2)
    }

    /// Acceptance (mocked App Store Connect): deletion lists the leaderboard's scores, page by page, and blocks hers.
    @Test func appStoreConnectListsAndBlocksHerScores() async throws {
        let first = "/v2/gameCenterLeaderboards/lb-1/gameCenterScoreModerations?include=player&limit=200"
        let second = "/v2/gameCenterLeaderboards/lb-1/gameCenterScoreModerations?cursor=Mg&include=player&limit=200"
        func score(_ id: String, _ player: String, blocked: Bool = false, at date: String = "2026-10-01T12:00:00Z") -> String {
            #"{"type":"gameCenterScoreModerations","id":"\#(id)","attributes":{"score":1500,"blocked":\#(blocked),"submittedDate":"\#(date)"},"#
                + #""relationships":{"player":{"data":{"type":"gameCenterDetailPlayers","id":"\#(player)"}}}}"#
        }
        let stub = StubAppStoreConnect(pages: [
            first: #"{"data":[\#(score("s1", "G:wren")),\#(score("s2", "G:gull"))],"links":{"self":"x","next":"https://api.appstoreconnect.apple.com\#(second)"}}"#,
            second: #"{"data":[\#(score("s3", "G:wren", at: "2026-10-02T08:00:00.250Z")),\#(score("s4", "G:wren", blocked: true)),"#
                + #"\#(score("s5", "G:wren", at: "2026-10-20T00:00:00Z")),\#(score("s6", "G:tern"))],"links":{"self":"y"}}"#,
        ])
        let key = AppStoreConnectConfig(keyID: "K", issuerID: "I", privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation,
                                        leaderboardID: "rating", bundleID: "com.example", leaderboardResourceID: "lb-1")
        let moderation = AppStoreConnectScoreModeration(tokens: try AppStoreConnectLeaderboard(config: key, poster: stub),
                                                        leaderboardResourceID: "lb-1", requester: stub)
        // Wren's two scores from before her deletion, not the one she earned after coming back, nor anyone else's.
        let deleted = Date(timeIntervalSince1970: 1_791_590_400) // 2026-10-10
        #expect(try await moderation.blockScores(of: ["G:wren": deleted, "G:skua": deleted]) == ["G:wren": 2, "G:skua": 0])
        #expect(stub.sent.map(\.method) == [.get, .get, .patch, .patch])
        #expect(stub.sent.map(\.target) == [first, second, "/v1/gameCenterScoreModerations/s1", "/v1/gameCenterScoreModerations/s3"])
        #expect(stub.sent[2].body == #"{"data":{"attributes":{"blocked":true},"id":"s1","type":"gameCenterScoreModerations"}}"#)

        stub.patches(answer: 409)
        await #expect(throws: ScoreBlockError.status(409)) { _ = try await moderation.blockScores(of: ["G:wren": deleted]) }
        #expect(throws: ScoreBlockError.badNextLink("https://evil.example/v2/x")) { _ = try AppStoreConnectScoreModeration.target("https://evil.example/v2/x") }
        let unknown = AppStoreConnectScoreModeration(tokens: try AppStoreConnectLeaderboard(config: key, poster: stub),
                                                     leaderboardResourceID: "missing", requester: stub)
        await #expect(throws: ScoreBlockError.status(404)) { _ = try await unknown.blockScores(of: ["G:wren": deleted]) }
    }

    /// A queued player who deletes her data leaves the queue first, so no fleet registers her after her row is gone.
    @Test func deletingLetsTheQueueGoOfHer() async throws {
        let rig = DeletionRig()
        let clock = rig.clock
        let matchmaker = QueueMatchmaker(settings: QueueSettings(), registry: RaceRegistry(),
                                         draw: RaceDraw(pairings: OnlinePairing.bundled(), seeds: FixtureWindSeedPools(poolSize: 8)),
                                         tokenKey: QueueMatchmakerTests.key, tokenLifetime: 600, now: { clock.now })
        let deletion = OnlineDataDeletion(store: rig.memory, blocksAtOnce: false, beforeErase: { await matchmaker.forget($0) }, now: { clock.now })
        let wren = try await rig.holding("wren")
        try await matchmaker.join(wren)
        try await deletion.delete(wren.teamPlayerID, confirmedBy: try await deletion.plan(for: wren.teamPlayerID).confirmation)
        let state = await matchmaker.state(of: wren.teamPlayerID), queued = await matchmaker.queuedCount
        #expect(state == .idle && queued == 0)
    }

    /// Race reports filed after a deletion can't reach the anonymous seat.
    @Test func anAnonymousSeatIsNoOnesToReport() {
        let seating = RaceSeating(humans: [RaceSeatHolder(playerID: "deleted:x", seat: 1), RaceSeatHolder(playerID: "T:gull", seat: 2)])
        #expect(seating.human(at: 1) == nil && seating.human(at: 2) == "T:gull")
    }

    // MARK: Retention (#28), on a fake clock

    @Test func theLobbyIsPrunedAt30Days() async throws {
        let rig = DeletionRig()
        _ = try await rig.holding("wren")
        rig.clock.advance(30 * 86_400 - 1)
        #expect(await rig.retention.runOnce().chatLines == 0)
        rig.clock.advance(2)
        #expect(await rig.retention.runOnce().chatLines == 1)
        #expect(rig.lobbyStore.allLines.isEmpty)
    }

    @Test func reportsAndPenaltiesArePrunedAtAYearOrThePenaltysLength() async throws {
        let rig = DeletionRig()
        let start = rig.clock.now
        let report = try await rig.moderation.file(StoredReport(kind: .player, reporterID: "T:a", subjectID: "T:b", subjectNickname: "b",
                                                                createdAt: start, dueAt: start + 86_400))
        _ = try await rig.moderation.file(StoredReport(kind: .player, reporterID: "T:c", subjectID: "T:b", subjectNickname: "b",
                                                       createdAt: start, dueAt: start + 86_400))
        _ = try await rig.moderation.add(StoredPenalty(playerID: "T:b", kind: .chatBan, actorID: "admin", reportID: report.id, startsAt: start))
        let week = try await rig.moderation.add(StoredPenalty(playerID: "T:b", kind: .racingSuspension, actorID: "admin", startsAt: start,
                                                              endsAt: start + 7 * 86_400))
        _ = try await rig.moderation.add(StoredPenalty(playerID: "T:b", kind: .racingWarning, actorID: "admin", startsAt: start))
        rig.clock.advance(365 * 86_400 - 1)
        var run = await rig.retention.runOnce()
        #expect(run.penalties == 0 && run.reports == 0)
        rig.clock.advance(2)
        run = await rig.retention.runOnce()
        // The week's suspension, the warning and the undecided report go; the ban, in force, keeps itself and its report.
        #expect(run.penalties == 2 && run.reports == 1)
        #expect(try await rig.moderation.penalties(of: "T:b").map(\.kind) == [.chatBan])
        #expect(try await rig.moderation.report(report.id) != nil)
        _ = week
    }

    /// G8: 730 days without an online session runs the same deletion; profile, rating, livery and terms are kept while
    /// she is active.
    @Test func inactivePlayersAreDeletedAfter730Days() async throws {
        let rig = DeletionRig()
        try await rig.holding("wren")
        rig.clock.advance(400 * 86_400)
        try await rig.holding("gull")
        rig.clock.advance(330 * 86_400 - 1)
        #expect(await rig.retention.runOnce().inactivePlayers == 0)
        rig.clock.advance(2)
        #expect(await rig.retention.runOnce().inactivePlayers == 1)
        #expect(try await rig.memory.held(by: "T:wren").isEmpty)
        // Hers stay, but her lobby line, older than 30 days, went with the lobby prune.
        #expect(try await rig.memory.held(by: "T:gull").kinds == Set(StoredOnlineData.allCases).subtracting([.chat]))
        let audit = try #require(try await rig.memory.deletions(limit: 1).first)
        #expect(audit.reason == .inactive)
    }

    /// Race logs are kept: a deletion moves her seat to an anonymous id and leaves the closed race as it was.
    @Test func raceLogsAreKept() async throws {
        let rig = DeletionRig()
        let wren = try await rig.holding("wren")
        let race = UUID()
        try await rig.archive.register(race, players: [RaceSeatHolder(playerID: "T:wren", seat: 0), RaceSeatHolder(playerID: "T:gull", seat: 1)])
        let record = ClosedRaceRecord(id: race, log: Data("log".utf8), digest: 7, simulationVersion: "sim", toolchain: "t", results: Data("r".utf8),
                                      incidents: Data(), rated: false)
        try await rig.archive.close(record)
        try await rig.deletion.delete(wren.teamPlayerID, confirmedBy: try await rig.deletion.plan(for: wren.teamPlayerID).confirmation)
        #expect(try await rig.archive.closedRace(race) == record)
        let seats = try #require(try await rig.archive.seats(of: race))
        #expect(seats.humans.map(\.seat) == [0, 1] && seats.humans[0].playerID.hasPrefix("deleted:") && seats.humans[1].playerID == "T:gull")
    }
}
